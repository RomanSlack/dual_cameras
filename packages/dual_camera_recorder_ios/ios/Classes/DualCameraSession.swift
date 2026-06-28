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

    func configureAndStart() {
        sessionQueue.async {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                self.onError?("multicam unsupported"); return
            }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }

            guard self.addCamera(.back, output: self.backOutput),
                  self.addCamera(.front, output: self.frontOutput) else {
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
            self.session.startRunning()
        }
    }

    private func addCamera(_ position: AVCaptureDevice.Position, output: AVCaptureVideoDataOutput) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)
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
        return true
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
