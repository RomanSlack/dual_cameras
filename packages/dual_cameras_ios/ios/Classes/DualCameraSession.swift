import AVFoundation
import CoreVideo
import UIKit

/// Drives `AVCaptureMultiCamSession`: front+back with manual connection wiring,
/// the AVMultiCamPiP latch (compose on the back frame using the latest front
/// frame), Metal compositing, and fan-out to the writer + Flutter texture
/// (ARCHITECTURE.md §5).
final class DualCameraSession: NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "dcr.session")
    private let dataQueue = DispatchQueue(label: "dcr.data")

    private let compositor: MetalCompositor
    private var layout: CompositeLayout
    private let recordAudio: Bool

    private let backOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var backDevice: AVCaptureDevice?
    private var frontDevice: AVCaptureDevice?

    private var latestFront: CVPixelBuffer?
    private var writer: MovieWriter?
    private var latestComposite: CVPixelBuffer?

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onThermal: ((ProcessInfo.ThermalState) -> Void)?
    var onError: ((String) -> Void)?

    init(compositor: MetalCompositor, layout: CompositeLayout, recordAudio: Bool) {
        self.compositor = compositor
        self.layout = layout
        self.recordAudio = recordAudio
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    func setLayout(_ layout: CompositeLayout) {
        dataQueue.async { self.layout = layout }
    }

    // Debug tuning (IOS_HANDOFF §6): forward to the compositor on the data queue,
    // where its orientation state is read during compose().
    func setRotationOffset(isFront: Bool, degrees: Int) {
        dataQueue.async { self.compositor.setRotationOffset(isFront: isFront, degrees: degrees) }
    }

    func setAspectOverride(isFront: Bool, aspect: Float) {
        dataQueue.async { self.compositor.setAspectOverride(isFront: isFront, aspect: aspect) }
    }

    func configureAndStart() {
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                self.onError?("multicam unsupported"); return
            }
            self.session.beginConfiguration()
            // Honor the activeFormat we pick per device (multicam can't use a
            // shared preset) — MASTER_PLAN §5.1.
            self.session.sessionPreset = .inputPriority

            guard self.addCamera(.back, output: self.backOutput),
                  self.addCamera(.front, output: self.frontOutput) else {
                self.session.commitConfiguration()
                self.onError?("failed to wire cameras"); return
            }
            self.backOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
            self.frontOutput.setSampleBufferDelegate(self, queue: self.dataQueue)

            if self.recordAudio,
               let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(micInput) {
                self.session.addInputWithNoConnections(micInput)
                if self.session.canAddOutput(self.audioOutput) {
                    self.session.addOutputWithNoConnections(self.audioOutput)
                    if let port = micInput.ports.first {
                        let conn = AVCaptureConnection(inputPorts: [port], output: self.audioOutput)
                        if self.session.canAddConnection(conn) { self.session.addConnection(conn) }
                    }
                    self.audioOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
                }
            }
            self.session.commitConfiguration()

            // The hardwareCost wall (MASTER_PLAN §5.1): at >= 1.0 the session
            // refuses to run. Our binned <=720p formats should clear it, but cap
            // fps as a fallback if a given device is still over budget.
            self.relieveHardwareCostIfNeeded()
            if self.session.hardwareCost > 1.0 {
                self.onError?(String(
                    format: "hardwareCost %.2f too high; session may not run",
                    self.session.hardwareCost))
            }
            self.session.startRunning()
        }
    }

    /// If the committed session is over the hardwareCost budget, cap each
    /// camera's frame rate (cheapest lever before dropping resolution).
    private func relieveHardwareCostIfNeeded() {
        var fps: Int32 = 30
        while session.hardwareCost > 1.0 && fps > 15 {
            fps -= 5
            let dur = CMTime(value: 1, timescale: fps)
            for device in [backDevice, frontDevice] {
                guard let device = device, (try? device.lockForConfiguration()) != nil else { continue }
                // Clamp into a supported range so the setter doesn't throw.
                if device.activeFormat.videoSupportedFrameRateRanges
                    .contains(where: { $0.maxFrameRate >= Double(fps) }) {
                    device.activeVideoMinFrameDuration = dur
                }
                device.unlockForConfiguration()
            }
        }
    }

    private func addCamera(_ position: AVCaptureDevice.Position, output: AVCaptureVideoDataOutput) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)

        // Pick a multicam-legal, low-cost format (prefer binned, <=720p) and set
        // it manually — leaving the default risks hardwareCost >= 1.0.
        if let fmt = bestMultiCamFormat(device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = fmt
            device.unlockForConfiguration()
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(output) else { return false }
        session.addOutputWithNoConnections(output)
        let ports = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                sourceDevicePosition: position)
        guard let port = ports.first else { return false }
        let conn = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(conn) else { return false }
        session.addConnection(conn)
        if position == .back { backDevice = device } else { frontDevice = device }
        return true
    }

    /// Lowest-cost multicam-supported format: must be multicam-legal; prefer
    /// binned (lower bandwidth/heat); among those pick the smallest width that is
    /// still >= 640 (keeps a usable resolution while staying under hardwareCost).
    private func bestMultiCamFormat(_ device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let multicam = device.formats.filter { $0.isMultiCamSupported }
        guard !multicam.isEmpty else { return nil }
        func width(_ f: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
        }
        let binned = multicam.filter { $0.isVideoBinned }
        let pool = binned.isEmpty ? multicam : binned
        let usable = pool.filter { width($0) >= 640 }
        let candidates = usable.isEmpty ? pool : usable
        return candidates.min { width($0) < width($1) }
    }

    // MARK: - Sample delivery

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            writer?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if output === frontOutput {
            latestFront = pixelBuffer // latch
            return
        }
        // Back frame drives the composite cadence and the PTS.
        let primary = layout.primaryFront ? (latestFront ?? pixelBuffer) : pixelBuffer
        let secondary = layout.primaryFront ? pixelBuffer : latestFront
        guard let composed = compositor.compose(primary: primary, secondary: secondary, layout: layout) else { return }
        latestComposite = composed
        onFrame?(composed)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer?.appendVideo(composed, pts: pts)
    }

    // MARK: - Recording

    func startRecording(url: URL, hevc: Bool) {
        dataQueue.async {
            self.writer = MovieWriter(
                url: url, width: self.compositor.width, height: self.compositor.height,
                hevc: hevc, recordAudio: self.recordAudio)
        }
    }

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        dataQueue.async {
            let w = self.writer
            self.writer = nil
            if let w = w { w.finish(completion) } else { completion(nil) }
        }
    }

    func takePhoto(url: URL, completion: @escaping (Bool) -> Void) {
        dataQueue.async {
            guard let composite = self.latestComposite else { completion(false); return }
            let ci = CIImage(cvPixelBuffer: composite)
            let context = CIContext()
            guard let cg = context.createCGImage(ci, from: ci.extent) else { completion(false); return }
            let image = UIImage(cgImage: cg)
            if let data = image.jpegData(compressionQuality: 0.92),
               (try? data.write(to: url)) != nil {
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func thermalChanged() {
        onThermal?(ProcessInfo.processInfo.thermalState)
    }
}
