import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

struct VideoCaptureInfo {
    let pixelWidth: Int
    let pixelHeight: Int
    let frameRate: Int
    let deviceName: String
    let deviceUniqueID: String
    let audioDeviceName: String?
}

/// Wraps an `AVCaptureSession` configured for a USB / external video device
/// (capture cards on macOS show up as `AVCaptureDevice.DeviceType.external`).
/// Optionally adds an audio input — capture cards typically expose HDMI audio
/// as a separate UVC audio device.
///
/// The session is exposed so an `AVCaptureVideoPreviewLayer` can attach to it
/// for live preview, while data outputs simultaneously deliver `CMSampleBuffer`s
/// to the `RecordingSession` for HEVC/AAC encode.
final class CaptureCardCapturer: NSObject {

    /// Selected audio device for the next session start.
    enum AudioPreference {
        case auto                       // first connected external audio device
        case none                       // explicitly disabled
        case device(uniqueID: String)   // pin a specific device
    }

    var videoSampleHandler: ((CMSampleBuffer) -> Void)?
    var audioSampleHandler: ((CMSampleBuffer) -> Void)?

    // Diagnostics: rolling per-second video frame counter, logged to NSLog.
    private var diagFrameCount: Int = 0
    private var diagWindowStart: Date = Date()

    let session = AVCaptureSession()
    private(set) var info: VideoCaptureInfo?

    private let videoQueue = DispatchQueue(label: "dev.dgr8akki.Kestrel.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "dev.dgr8akki.Kestrel.capture.audio", qos: .userInitiated)

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    /// OBS keeps `lockForConfiguration` held for the entire capture session lifetime.
    /// Releasing the lock gives the system permission to re-negotiate the device's
    /// active format / frame rate behind our back (e.g. when adding an output or
    /// reacting to USB renegotiation). On the MS213x we observed throughput
    /// collapse to ~20 fps when we unlocked. Mirror OBS and hold the lock.
    private var lockedDevice: AVCaptureDevice?

    // MARK: Device discovery

    /// External / USB video devices available right now (capture cards, USB cameras).
    /// Excludes the built-in FaceTime camera so the picker stays focused on capture cards.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .deskViewCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// All video devices including the built-in camera (used as a last-resort fallback).
    static func allVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .deskViewCamera, .continuityCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// All audio capture devices (external USB audio, HDMI capture cards' audio side, etc.).
    static func allAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// External (non-built-in) audio devices.
    static func externalAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func videoDevice(withUniqueID uniqueID: String?) -> AVCaptureDevice? {
        guard let uniqueID, !uniqueID.isEmpty else { return nil }
        return AVCaptureDevice(uniqueID: uniqueID)
    }

    static func audioDevice(withUniqueID uniqueID: String?) -> AVCaptureDevice? {
        guard let uniqueID, !uniqueID.isEmpty, uniqueID != Settings.audioDisabledID else { return nil }
        return AVCaptureDevice(uniqueID: uniqueID)
    }

    // MARK: Lifecycle

    /// Recording profile applied when `reconfigureForRecording` / `reconfigureForPreview`
    /// is called. We remember the active video device so we can re-configure it without
    /// tearing down the whole AVCaptureSession.
    private var videoDevice: AVCaptureDevice?
    private var lastPreviewTargetFps: Int = 60

    func startSession(
        preferredVideoDeviceID: String?,
        audioPreference: AudioPreference,
        targetFrameRate: Int = 60
    ) async throws -> VideoCaptureInfo {
        try await ensureCameraPermission()

        let videoDevice = Self.videoDevice(withUniqueID: preferredVideoDeviceID)
            ?? Self.availableDevices().first
            ?? Self.allVideoDevices().first

        guard let videoDevice else {
            throw CapturerError.noDevice
        }

        // Resolve audio device. Permission is requested only if audio is wanted.
        let audioDevice: AVCaptureDevice? = try await {
            switch audioPreference {
            case .none:
                return nil
            case .auto:
                try await ensureMicrophonePermission()
                return Self.externalAudioDevices().first ?? Self.allAudioDevices().first
            case .device(let id):
                try await ensureMicrophonePermission()
                return Self.audioDevice(withUniqueID: id)
            }
        }()

        let format = bestFormat(for: videoDevice, maxFrameRate: targetFrameRate)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let (frameDuration, achievedFps) = pickFrameDuration(for: format, target: targetFrameRate)
        self.videoDevice = videoDevice
        self.lastPreviewTargetFps = targetFrameRate

        session.beginConfiguration()
        var committed = false
        defer {
            if !committed { session.commitConfiguration() }
        }

        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        // Video input + output
        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard session.canAddInput(videoInput) else {
            throw CapturerError.cannotAddInput
        }
        session.addInput(videoInput)

        // CRITICAL: configure activeFormat *after* `addInput`. On macOS the
        // session resets the device to a preset-compatible format during
        // `addInput`; on this capture card that landed on the 20 fps 4K mode
        // instead of the 60 fps one we picked. Setting `activeFormat` while the
        // device is already in the session implicitly switches the session to
        // input-priority and the device keeps the format we set.
        //
        // We deliberately KEEP the device locked for the lifetime of the capture
        // session (matching OBS's `mac-avcapture` plugin). Unlocking lets the
        // system re-negotiate the active format under us — that is what was
        // throttling us to ~20 fps on the MS213x.
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = format
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            self.lockedDevice = videoDevice
            let actMin = videoDevice.activeVideoMinFrameDuration
            let actMax = videoDevice.activeVideoMaxFrameDuration
            let actDim = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            NSLog("Kestrel: post-config activeFormat=\(actDim.width)x\(actDim.height) min=\(actMin.value)/\(actMin.timescale) max=\(actMax.value)/\(actMax.timescale)")
        } catch {
            throw CapturerError.cannotConfigureDevice(underlying: error)
        }

        let videoOut = AVCaptureVideoDataOutput()
        // Drop late frames at the *capture* stage rather than the encoder so we don't
        // accumulate latency when the encoder hiccups.
        videoOut.alwaysDiscardsLateVideoFrames = true
        // Match OBS: leave `videoSettings = nil` so AVFoundation delivers the
        // device's native pixel buffers without inserting a pixel-format
        // converter. Forcing a specific FourCC here (even one the device claims
        // to deliver natively) was forcing a CPU conversion path that throttled
        // throughput for high-resolution NV12 frames coming off cheap UVC chips.
        videoOut.videoSettings = nil
        videoOut.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOut) else {
            throw CapturerError.cannotAddOutput
        }
        session.addOutput(videoOut)
        self.videoOutput = videoOut

        // Audio input + output (best-effort: log and continue if it fails)
        var audioName: String? = nil
        if let audioDevice {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)

                    let audioOut = AVCaptureAudioDataOutput()
                    audioOut.setSampleBufferDelegate(self, queue: audioQueue)
                    if session.canAddOutput(audioOut) {
                        session.addOutput(audioOut)
                        self.audioOutput = audioOut
                        audioName = audioDevice.localizedName
                    } else {
                        NSLog("Kestrel: cannot add audio output; continuing without audio.")
                        session.removeInput(audioInput)
                    }
                } else {
                    NSLog("Kestrel: cannot add audio input \(audioDevice.localizedName); continuing without audio.")
                }
            } catch {
                NSLog("Kestrel: failed to attach audio device: \(error.localizedDescription)")
            }
        }

        session.commitConfiguration()
        committed = true

        // Start running off the main thread; AVCaptureSession.startRunning is blocking.
        await Task.detached(priority: .userInitiated) { [session] in
            session.startRunning()
        }.value

        let info = VideoCaptureInfo(
            pixelWidth: Int(dimensions.width),
            pixelHeight: Int(dimensions.height),
            frameRate: achievedFps,
            deviceName: videoDevice.localizedName,
            deviceUniqueID: videoDevice.uniqueID,
            audioDeviceName: audioName
        )
        self.info = info
        return info
    }

    /// Choose a frame duration that the device's active format will actually accept.
    /// The setter validates against `videoSupportedFrameRateRanges` exactly, so we
    /// must hand it a value inside one of those ranges — `CMTime(1, 60)` is rejected
    /// by devices that report e.g. `CMTime(1001, 60000)` (~59.94 fps).
    private func pickFrameDuration(for format: AVCaptureDevice.Format, target: Int) -> (CMTime, Int) {
        let ranges = format.videoSupportedFrameRateRanges
        let desired = CMTime(value: 1, timescale: CMTimeScale(max(1, target)))

        // 1) If `desired` falls inside any range, use it as-is.
        if ranges.contains(where: { range in
            CMTimeCompare(desired, range.minFrameDuration) >= 0 &&
            CMTimeCompare(desired, range.maxFrameDuration) <= 0
        }) {
            return (desired, target)
        }

        // 2) Otherwise pick the range whose maxFrameRate is closest-but-not-over the target,
        //    then fall back to the highest available fps if the target is unreachable.
        let underTarget = ranges.filter { $0.maxFrameRate <= Double(target) + 0.001 }
        if let best = underTarget.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            return (best.minFrameDuration, Int(best.maxFrameRate.rounded()))
        }
        if let highest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            return (highest.minFrameDuration, Int(highest.maxFrameRate.rounded()))
        }
        return (CMTime(value: 1, timescale: 30), 30)
    }

    func stopSession() async {
        let s = session
        await Task.detached(priority: .userInitiated) {
            if s.isRunning { s.stopRunning() }
        }.value
        // Release the long-lived configuration lock (see `lockedDevice` doc).
        if let locked = lockedDevice {
            locked.unlockForConfiguration()
            lockedDevice = nil
        }
        videoOutput = nil
        audioOutput = nil
        videoDevice = nil
        info = nil
    }

    var isRunning: Bool { session.isRunning }
    var hasAudio: Bool { audioOutput != nil }

    // MARK: Permissions

    private func ensureCameraPermission() async throws {
        try await ensureMediaPermission(.video, denied: CapturerError.cameraPermissionDenied)
    }

    private func ensureMicrophonePermission() async throws {
        try await ensureMediaPermission(.audio, denied: CapturerError.microphonePermissionDenied)
    }

    private func ensureMediaPermission(_ media: AVMediaType, denied: CapturerError) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: media)
            if !granted { throw denied }
        case .denied, .restricted:
            throw denied
        @unknown default:
            throw denied
        }
    }

    // MARK: Format selection

    /// Pick the best NV12 format the device advertises that can hit the user's target
    /// frame rate. Strategy:
    ///   * Prefer 16:9 over DCI (3840×2160 over 4096×2160 — consumer sources output UHD).
    ///   * In `prefersMaxArea` mode (recording profile that pins area) maximise area,
    ///     then frame rate. Otherwise maximise frame rate, then area.
    ///   * Always require the achievable fps to be ≥ the target (clamped at the
    ///     device max). A format whose ceiling is below the target is heavily
    ///     penalised so we never silently downgrade.
    ///
    /// We used to gate on a pixel-throughput budget (capped at ~4K30) on the
    /// assumption that cheap UVC chips couldn't actually push 4K60 in NV12. That
    /// assumption was wrong for our setup — the throttle was actually our own
    /// pipeline (forcing `videoSettings` and not holding `lockForConfiguration`).
    /// With both fixed, the MS213x family delivers 4K60 NV12 fine, so we trust the
    /// device's advertised ranges. The throughput estimate is still logged for
    /// diagnostics so an under-performing card is easy to spot in `/tmp/lo.err`.
    private func bestFormat(
        for device: AVCaptureDevice,
        maxFrameRate: Int,
        prefersMaxArea: Bool = false
    ) -> AVCaptureDevice.Format {
        let target = Double(maxFrameRate)

        struct Score: Comparable {
            let meetsTarget: Bool   // device range ≥ requested fps
            let widescreen: Bool    // 16:9 (UHD) over DCI / odd ratios
            let primary: Double     // area-first or fps-first depending on caller
            let secondary: Double
            static func < (l: Score, r: Score) -> Bool {
                if l.meetsTarget != r.meetsTarget { return !l.meetsTarget && r.meetsTarget }
                if l.widescreen != r.widescreen { return !l.widescreen && r.widescreen }
                if l.primary != r.primary { return l.primary < r.primary }
                return l.secondary < r.secondary
            }
        }

        func score(_ f: AVCaptureDevice.Format) -> Score {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let area = Int(d.width) * Int(d.height)
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let achievable = min(target, maxFps)
            let aspect = Double(d.width) / Double(max(d.height, 1))
            let widescreen = abs(aspect - (16.0 / 9.0)) < 0.02
            let primary: Double = prefersMaxArea ? Double(area) : achievable
            let secondary: Double = prefersMaxArea ? achievable : Double(area)
            return Score(meetsTarget: maxFps + 0.001 >= target, widescreen: widescreen, primary: primary, secondary: secondary)
        }

        logAvailableFormats(device: device)

        // Prefer NV12 (`420v`) — the chip's native delivery format on macOS.
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let nv12Formats = device.formats.filter {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == nv12
        }
        let candidates = nv12Formats.isEmpty ? device.formats : nv12Formats

        if let best = candidates.max(by: { score($0) < score($1) }) {
            let dim = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let bestMaxFps = best.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let achievable = Int(min(target, bestMaxFps).rounded())
            // Diagnostic-only throughput estimate. A typical USB-3 UVC chip can
            // sustain ~480 Mpx/s in NV12 in good conditions; below ~250 Mpx/s
            // is comfortable. If the recorded fps comes in well under `achievable`,
            // this is the first place to look.
            let pxPerSec = Int(Double(Int(dim.width) * Int(dim.height)) * Double(achievable))
            let mode = prefersMaxArea ? "max-area" : "max-fps"
            NSLog("Kestrel: picked format \(dim.width)x\(dim.height) up to \(achievable) fps (target \(maxFrameRate), mode \(mode)) — ~\(pxPerSec / 1_000_000) Mpx/s")
            return best
        }
        return device.activeFormat
    }

    // MARK: Live reconfiguration

    /// Switch the active video format to the highest-area NV12 mode within the chip's
    /// safe budget at ≤30 fps. Used at the moment a recording starts so we capture at
    /// max resolution even when the preview was running at smooth 1440p60.
    /// Returns updated `VideoCaptureInfo`.
    func reconfigureForRecording() async throws -> VideoCaptureInfo {
        try await reconfigure(targetFrameRate: 30, prefersMaxArea: true)
    }

    /// Restore the smoother preview profile after recording has stopped.
    func reconfigureForPreview() async throws -> VideoCaptureInfo {
        try await reconfigure(targetFrameRate: lastPreviewTargetFps, prefersMaxArea: false)
    }

    private func reconfigure(targetFrameRate: Int, prefersMaxArea: Bool) async throws -> VideoCaptureInfo {
        guard let device = videoDevice else { throw CapturerError.noDevice }

        let format = bestFormat(for: device, maxFrameRate: targetFrameRate, prefersMaxArea: prefersMaxArea)
        let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let (frameDuration, achievedFps) = pickFrameDuration(for: format, target: targetFrameRate)

        // beginConfiguration / commit ensures the session re-creates its outputs cleanly
        // around the format swap; without this, AVFoundation can deliver a few frames
        // with the old timing metadata after the new format is set.
        //
        // The device is already locked for the lifetime of the session (see
        // `lockedDevice`), so we don't take the lock again here — that would
        // be re-entrant and we want OBS-style continuous configuration ownership.
        session.beginConfiguration()
        let needsLock = (lockedDevice !== device)
        if needsLock {
            do {
                try device.lockForConfiguration()
                lockedDevice = device
            } catch {
                session.commitConfiguration()
                throw CapturerError.cannotConfigureDevice(underlying: error)
            }
        }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        let actMin = device.activeVideoMinFrameDuration
        let actMax = device.activeVideoMaxFrameDuration
        let actDim = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        NSLog("Kestrel: reconfigured activeFormat=\(actDim.width)x\(actDim.height) min=\(actMin.value)/\(actMin.timescale) max=\(actMax.value)/\(actMax.timescale)")
        session.commitConfiguration()

        let info = VideoCaptureInfo(
            pixelWidth: Int(dim.width),
            pixelHeight: Int(dim.height),
            frameRate: achievedFps,
            deviceName: device.localizedName,
            deviceUniqueID: device.uniqueID,
            audioDeviceName: self.info?.audioDeviceName
        )
        self.info = info
        return info
    }

    private func logAvailableFormats(device: AVCaptureDevice) {
        NSLog("Kestrel: \(device.localizedName) advertises \(device.formats.count) formats:")
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let st = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let bytes: [UInt8] = [
                UInt8((st >> 24) & 0xff),
                UInt8((st >> 16) & 0xff),
                UInt8((st >> 8) & 0xff),
                UInt8(st & 0xff)
            ]
            let sub = String(bytes: bytes, encoding: .ascii) ?? "????"
            let ranges = f.videoSupportedFrameRateRanges
                .map { String(format: "%.2f-%.2f", $0.minFrameRate, $0.maxFrameRate) }
                .joined(separator: ",")
            NSLog("  - \(d.width)x\(d.height) \(sub) fps=\(ranges)")
        }
    }

    // MARK: Errors

    enum CapturerError: LocalizedError {
        case noDevice
        case cameraPermissionDenied
        case microphonePermissionDenied
        case cannotConfigureDevice(underlying: Error)
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noDevice:
                return "No external video device found. Plug in your capture card via USB-C and try again."
            case .cameraPermissionDenied:
                return "Camera permission is required to read from the capture card. Open System Settings › Privacy & Security › Camera and enable Kestrel."
            case .microphonePermissionDenied:
                return "Microphone permission is required to record audio. Open System Settings › Privacy & Security › Microphone and enable Kestrel, or set audio to None in Settings."
            case .cannotConfigureDevice(let underlying):
                return "Could not configure the capture device: \(underlying.localizedDescription)"
            case .cannotAddInput:
                return "Could not add the capture device as a session input."
            case .cannotAddOutput:
                return "Could not add the video data output to the session."
            }
        }
    }
}

extension CaptureCardCapturer: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            audioSampleHandler?(sampleBuffer)
        } else {
            diagFrameCount += 1
            let now = Date()
            if now.timeIntervalSince(diagWindowStart) >= 1.0 {
                NSLog("Kestrel: captured \(diagFrameCount) video frames in last \(String(format: "%.2f", now.timeIntervalSince(diagWindowStart)))s")
                diagFrameCount = 0
                diagWindowStart = now
            }
            videoSampleHandler?(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Fires whenever the capture pipeline drops a video frame (encoder back-pressure,
        // queue full, USB hiccup, etc.).
        NSLog("Kestrel: captureOutput dropped a frame (alwaysDiscardsLateVideoFrames is true)")
    }
}
