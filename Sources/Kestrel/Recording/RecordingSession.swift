import AVFoundation
import CoreMedia
import VideoToolbox
import AudioToolbox

final class RecordingSession {
    struct Configuration {
        let url: URL
        let width: Int
        let height: Int
        let frameRate: Int
        let bitrateBps: Int
        let fragmentSeconds: Double
        let includeAudio: Bool
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let config: Configuration

    private var sessionStarted = false
    private let serial = DispatchQueue(label: "dev.dgr8akki.Kestrel.recording.session")

    init(configuration: Configuration) throws {
        self.config = configuration

        let writer = try AVAssetWriter(outputURL: configuration.url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let fragSeconds = max(0.5, configuration.fragmentSeconds)
        writer.movieFragmentInterval = CMTime(
            seconds: fragSeconds,
            preferredTimescale: CMTimeScale(configuration.frameRate)
        )

        let videoCompression: [String: Any] = [
            AVVideoAverageBitRateKey: configuration.bitrateBps,
            AVVideoMaxKeyFrameIntervalKey: configuration.frameRate,
            AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoAllowFrameReorderingKey: false
        ]

        // Tag the track explicitly as BT.709 so players (and ffprobe) don't fall
        // back to the AVAssetWriter default of `smpte240m`, which makes colours
        // look slightly off vs OBS's clean BT.709 / sRGB tagging.
        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: videoCompression,
            AVVideoColorPropertiesKey: colorProperties
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw RecordingError.cannotAddVideoInput
        }
        writer.add(videoInput)

        var audio: AVAssetWriterInput? = nil
        if configuration.includeAudio {
            // 2ch / 48 kHz / AAC LC @ 320 kbps. AVAssetWriter inside an .mp4 container
            // does not expose a lossless option, so AAC LC at the high end of useful
            // bitrate is the practical match for what OBS exports as ALAC.
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 320_000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audio = aInput
            } else {
                NSLog("Kestrel: writer rejected audio input; recording video only.")
            }
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audio
    }

    var hasAudioInput: Bool { audioInput != nil }

    func start() throws {
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.writerFailedToStart
        }
    }

    func appendVideo(sampleBuffer: CMSampleBuffer) {
        serial.async { [weak self] in
            guard let self else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: pts)
                self.sessionStarted = true
            }

            if self.videoInput.isReadyForMoreMediaData {
                if !self.videoInput.append(sampleBuffer) {
                    NSLog("Kestrel: failed to append video sample: \(String(describing: self.writer.error))")
                }
            }
        }
    }

    func appendAudio(sampleBuffer: CMSampleBuffer) {
        serial.async { [weak self] in
            guard let self,
                  let audioInput = self.audioInput,
                  self.sessionStarted else {
                // Drop audio frames that arrive before the first video frame so the
                // movie timeline is anchored on video PTS.
                return
            }
            if audioInput.isReadyForMoreMediaData {
                if !audioInput.append(sampleBuffer) {
                    NSLog("Kestrel: failed to append audio sample: \(String(describing: self.writer.error))")
                }
            }
        }
    }

    func finish() async {
        let box = UnsafeBox(writer: writer, video: videoInput, audio: audioInput)
        let queue = serial
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                box.video.markAsFinished()
                box.audio?.markAsFinished()
                box.writer.finishWriting {
                    continuation.resume()
                }
            }
        }
    }

    private struct UnsafeBox: @unchecked Sendable {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput?
    }

    var outputURL: URL { config.url }
    var writerStatus: AVAssetWriter.Status { writer.status }
    var writerError: Error? { writer.error }

    enum RecordingError: LocalizedError {
        case cannotAddVideoInput
        case writerFailedToStart

        var errorDescription: String? {
            switch self {
            case .cannotAddVideoInput: return "Could not add video input to the writer."
            case .writerFailedToStart: return "Asset writer failed to start."
            }
        }
    }
}
