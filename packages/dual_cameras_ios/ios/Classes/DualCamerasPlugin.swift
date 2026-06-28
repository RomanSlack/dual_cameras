import AVFoundation
import Flutter

/// iOS implementation of dual_cameras: AVCaptureMultiCamSession + Metal
/// compositor + AVAssetWriter, unified for preview / video / photo
/// (ARCHITECTURE.md §5). Cannot be compiled on Linux CI; verified by review and
/// on-device.
public final class DualCamerasPlugin: NSObject, FlutterPlugin, DualCameraHostApi {

    private let textureRegistry: FlutterTextureRegistry
    private let flutterApi: DualCameraFlutterApi

    private var previewTexture: DualCameraTexture?
    private var textureId: Int64?
    private var compositor: MetalCompositor?
    private var session: DualCameraSession?
    private var layout = CompositeLayout(
        pictureInPicture: true, primaryFront: false,
        insetRect: CGRect(x: 0.7, y: 0.68, width: 0.28, height: 0.28),
        cornerRadiusPx: 18, mirrorFront: true, splitVertical: false)
    private var hevc = false

    init(textureRegistry: FlutterTextureRegistry, flutterApi: DualCameraFlutterApi) {
        self.textureRegistry = textureRegistry
        self.flutterApi = flutterApi
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let messenger = registrar.messenger()
        let instance = DualCamerasPlugin(
            textureRegistry: registrar.textures(),
            flutterApi: DualCameraFlutterApi(binaryMessenger: messenger))
        DualCameraHostApiSetup.setUp(binaryMessenger: messenger, api: instance)
        // Debug-tuning channel (IOS_HANDOFF §6) — mirrors the Android
        // `dual_cameras/debug` channel; the shared example panel drives
        // it. Gate behind kDebugMode / strip before pub.dev publish.
        let debug = FlutterMethodChannel(
            name: "dual_cameras/debug", binaryMessenger: messenger)
        debug.setMethodCallHandler { [weak instance] call, result in
            instance?.handleDebug(call, result) ?? result(FlutterMethodNotImplemented)
        }
        registrar.publish(instance)
    }

    private func handleDebug(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let session = session else {
            result(FlutterError(code: "not_init", message: "initialize() first", details: nil))
            return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "setRotationOffset":
            let front = args["front"] as? Bool ?? true
            let offset = args["offset"] as? Int ?? 0
            session.setRotationOffset(isFront: front, degrees: offset)
            result(nil)
        case "setAspectOverride":
            let front = args["front"] as? Bool ?? true
            let aspect = Float(args["aspect"] as? Double ?? 0)
            session.setAspectOverride(isFront: front, aspect: aspect)
            result(nil)
        case "setMirrorFront":
            let on = args["on"] as? Bool ?? true
            layout.mirrorFront = on
            session.setLayout(layout)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - DualCameraHostApi

    func probeSupport(completion: @escaping (Result<CameraCapabilities, Error>) -> Void) {
        completion(.success(detectCapabilities()))
    }

    func initialize(config: RecordingConfig,
                    completion: @escaping (Result<InitResult, Error>) -> Void) {
        let caps = detectCapabilities()
        let (w, h) = resolution(config.resolution)
        hevc = config.codec == .hevc
        layout = toLayout(config.layout, width: w, height: h)

        guard let compositor = MetalCompositor(width: w, height: h) else {
            completion(.failure(NSError(domain: "dual_cameras", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Metal init failed"])))
            return
        }
        self.compositor = compositor

        let texture = DualCameraTexture()
        let id = textureRegistry.register(texture)
        previewTexture = texture
        textureId = id

        let session = DualCameraSession(
            compositor: compositor, layout: layout, recordAudio: config.recordAudio)
        session.onFrame = { [weak self] buffer in
            guard let self = self, let id = self.textureId else { return }
            self.previewTexture?.push(buffer)
            self.textureRegistry.textureFrameAvailable(id)
        }
        session.onThermal = { [weak self] state in
            self?.flutterApi.onThermal(level: Self.mapThermal(state)) { _ in }
        }
        session.onError = { [weak self] message in
            self?.flutterApi.onError(code: "session", message: message) { _ in }
        }
        self.session = session
        session.configureAndStart()

        flutterApi.onReady(textureId: id) { _ in }
        completion(.success(InitResult(textureId: id, capabilities: caps)))
    }

    func startRecording(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let session = session else { return completion(notReady()) }
        let url = tempURL("mp4")
        session.startRecording(url: url, hevc: hevc)
        flutterApi.onRecordingStarted { _ in }
        completion(.success(()))
    }

    func stopRecording(completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else { return completion(notReady()) }
        session.stopRecording { [weak self] url in
            if let url = url {
                self?.flutterApi.onRecordingStopped(path: url.path) { _ in }
                completion(.success(url.path))
            } else {
                completion(.failure(NSError(domain: "dual_cameras", code: 3)))
            }
        }
    }

    func takePhoto(completion: @escaping (Result<String, Error>) -> Void) {
        guard let session = session else { return completion(notReady()) }
        let url = tempURL("jpg")
        session.takePhoto(url: url) { ok in
            ok ? completion(.success(url.path))
               : completion(.failure(NSError(domain: "dual_cameras", code: 4)))
        }
    }

    func swapPrimary(completion: @escaping (Result<Void, Error>) -> Void) {
        layout.primaryFront.toggle()
        session?.setLayout(layout)
        completion(.success(()))
    }

    func setLayout(layout: LayoutConfig, completion: @escaping (Result<Void, Error>) -> Void) {
        let w = compositor?.width ?? 1280
        let h = compositor?.height ?? 720
        self.layout = toLayout(layout, width: w, height: h)
        session?.setLayout(self.layout)
        completion(.success(()))
    }

    func dispose(completion: @escaping (Result<Void, Error>) -> Void) {
        session?.stop()
        session = nil
        compositor = nil
        if let id = textureId { textureRegistry.unregisterTexture(id) }
        previewTexture = nil
        textureId = nil
        completion(.success(()))
    }

    // MARK: - helpers

    private func notReady<T>() -> Result<T, Error> {
        .failure(NSError(domain: "dual_cameras", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "not initialized"]))
    }

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dcr_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)")
    }

    /// Portrait canvas (vertical video): width < height. The cameras deliver
    /// landscape buffers; the Metal compositor rotates them upright into this
    /// portrait canvas (matches Android's `resolutionFor`).
    private func resolution(_ r: DualResolution) -> (Int, Int) {
        switch r {
        case .sd480: return (480, 854)
        case .hd720: return (720, 1280)
        case .hd1080: return (1080, 1920)
        }
    }

    private func toLayout(_ l: LayoutConfig, width: Int, height: Int) -> CompositeLayout {
        let scale = CGFloat(l.insetScale)
        let mx = CGFloat(l.margin) / CGFloat(width)
        let my = CGFloat(l.margin) / CGFloat(height)
        var rect: CGRect
        switch l.insetCorner {
        case .topLeft: rect = CGRect(x: mx, y: my, width: scale, height: scale)
        case .topRight: rect = CGRect(x: 1 - mx - scale, y: my, width: scale, height: scale)
        case .bottomLeft: rect = CGRect(x: mx, y: 1 - my - scale, width: scale, height: scale)
        case .bottomRight: rect = CGRect(x: 1 - mx - scale, y: 1 - my - scale, width: scale, height: scale)
        }
        return CompositeLayout(
            pictureInPicture: l.mode == .pictureInPicture,
            primaryFront: l.primary == .front,
            insetRect: rect,
            cornerRadiusPx: Float(l.cornerRadius),
            mirrorFront: l.mirrorFront,
            splitVertical: l.mode == .splitVertical)
    }

    private static func mapThermal(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    private func detectCapabilities() -> CameraCapabilities {
        if #available(iOS 13.0, *) {
            if AVCaptureMultiCamSession.isMultiCamSupported {
                return CameraCapabilities(isSupported: true, maxWidth: 1920, maxHeight: 1080)
            }
            return CameraCapabilities(isSupported: false, reason: .noConcurrentCamera)
        }
        return CameraCapabilities(isSupported: false, reason: .osTooOld)
    }
}
