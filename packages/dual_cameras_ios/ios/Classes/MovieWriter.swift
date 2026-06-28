import AVFoundation
import CoreVideo

/// Wraps `AVAssetWriter` for the composited video + mic audio (ARCHITECTURE.md
/// §5.3). Video PTS comes from the primary camera sample buffer; audio is
/// passed through on the same capture clock, so A/V stay in sync for free.
final class MovieWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    let url: URL

    init?(url: URL, width: Int, height: Int, hevc: Bool, recordAudio: Bool) {
        self.url = url
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        self.writer = writer

        let codec: AVVideoCodecType = hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        if recordAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input) }
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            started = true
        }
        guard started, videoInput.isReadyForMoreMediaData else { return } // drop = back-pressure
        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard started, let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        guard started else { completion(nil); return }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let url = self.url
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? url : nil)
        }
    }
}
