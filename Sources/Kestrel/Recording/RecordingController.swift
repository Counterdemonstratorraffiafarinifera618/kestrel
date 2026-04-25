import Foundation
import AppKit
import AVFoundation
import CoreMedia

@MainActor
final class RecordingController {

    enum State {
        case idle
        case starting
        case previewing(VideoCaptureInfo)
        case recordingStarting(VideoCaptureInfo)
        case recording(VideoCaptureInfo, URL)
        case stopping
        case error(String)
    }

    var onStateChange: ((State) -> Void)?

    private let capturer = CaptureCardCapturer()
    private var session: RecordingSession?
    private var previewWindow: PreviewWindowController?

    /// `ProcessInfo.beginActivity` token held for the lifetime of an active capture
    /// session. Prevents macOS from idle-sleeping the system while we're pulling
    /// frames off the capture card. Without this, App Nap and the system idle timer
    /// will sleep the Mac after the user-configured idle interval even though the
    /// USB device and AVCaptureSession are still busy.
    private var sleepAssertion: NSObjectProtocol?

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    var isPreviewVisible: Bool { previewWindow != nil }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Toggle preview window. Starts the AVCaptureSession on demand and tears it down
    /// when both preview and recording are off.
    func togglePreview() {
        if previewWindow != nil {
            hidePreview()
        } else {
            showPreview()
        }
    }

    func showPreview() {
        switch state {
        case .recording(let info, _), .previewing(let info):
            presentPreviewWindow(for: info)
        case .idle, .error:
            startCaptureSessionIfNeeded { [weak self] info in
                guard let self else { return }
                self.state = .previewing(info)
                self.presentPreviewWindow(for: info)
            }
        case .starting, .recordingStarting, .stopping:
            return
        }
    }

    func hidePreview() {
        previewWindow?.window?.orderOut(nil)
        previewWindow = nil

        // If not recording, stop the underlying session to release the device.
        if case .recording = state { return }
        Task {
            await capturer.stopSession()
            endSleepAssertion()
            state = .idle
        }
    }

    func startRecording() {
        switch state {
        case .idle, .error:
            state = .starting
            startCaptureSessionIfNeeded { [weak self] info in
                self?.beginRecordingFlow(previewInfo: info)
            }
        case .previewing(let info):
            beginRecordingFlow(previewInfo: info)
        case .starting, .recordingStarting, .recording, .stopping:
            return
        }
    }

    /// Switches to the recording-time capture profile (if the user has chosen one),
    /// then opens the writer with the resulting format.
    private func beginRecordingFlow(previewInfo: VideoCaptureInfo) {
        switch Settings.shared.recordingProfile {
        case .matchPreview:
            beginWriter(info: previewInfo)
        case .maxResolution4K30:
            state = .recordingStarting(previewInfo)
            Task { @MainActor in
                do {
                    let recInfo = try await capturer.reconfigureForRecording()
                    beginWriter(info: recInfo)
                } catch {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    func stopRecording() {
        guard case .recording = state else { return }
        state = .stopping

        Task {
            capturer.videoSampleHandler = nil
            capturer.audioSampleHandler = nil
            if let session = self.session {
                await session.finish()
            }
            self.session = nil

            if previewWindow != nil {
                // Restore the smoother preview profile if we swapped formats for recording.
                let restoredInfo: VideoCaptureInfo
                if Settings.shared.recordingProfile == .maxResolution4K30 {
                    do {
                        restoredInfo = try await capturer.reconfigureForPreview()
                    } catch {
                        restoredInfo = capturer.info ?? VideoCaptureInfo(
                            pixelWidth: 0, pixelHeight: 0, frameRate: 0,
                            deviceName: "", deviceUniqueID: "", audioDeviceName: nil
                        )
                    }
                } else {
                    restoredInfo = capturer.info ?? VideoCaptureInfo(
                        pixelWidth: 0, pixelHeight: 0, frameRate: 0,
                        deviceName: "", deviceUniqueID: "", audioDeviceName: nil
                    )
                }
                state = .previewing(restoredInfo)
                if let win = previewWindow {
                    win.updateTitle(previewTitle(for: restoredInfo))
                }
            } else {
                await capturer.stopSession()
                endSleepAssertion()
                state = .idle
            }
        }
    }

    func stopEverything() {
        Task {
            capturer.videoSampleHandler = nil
            capturer.audioSampleHandler = nil
            if let session = self.session {
                await session.finish()
            }
            self.session = nil
            previewWindow?.window?.orderOut(nil)
            previewWindow = nil
            await capturer.stopSession()
            endSleepAssertion()
            state = .idle
        }
    }

    // MARK: Internals

    private func startCaptureSessionIfNeeded(then continuation: @escaping (VideoCaptureInfo) -> Void) {
        if let info = capturer.info, capturer.isRunning {
            continuation(info)
            return
        }
        Task { @MainActor in
            do {
                let info = try await capturer.startSession(
                    preferredVideoDeviceID: Settings.shared.preferredVideoDeviceID,
                    audioPreference: currentAudioPreference(),
                    targetFrameRate: Settings.shared.targetFrameRate
                )
                beginSleepAssertion()
                continuation(info)
            } catch {
                await capturer.stopSession()
                endSleepAssertion()
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Acquire the sleep assertion (idempotent). Held only while the capture session
    /// is actively running — preview hidden + recording stopped releases it via the
    /// matching `endSleepAssertion()` calls below.
    ///
    /// Uses `.idleSystemSleepDisabled` only — display sleep is still allowed, so the
    /// user can dim their screen and walk away while a long capture continues.
    private func beginSleepAssertion() {
        guard sleepAssertion == nil else { return }
        sleepAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Kestrel is capturing from a USB capture card"
        )
        NSLog("Kestrel: acquired sleep assertion (system idle sleep blocked)")
    }

    private func endSleepAssertion() {
        guard let token = sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(token)
        sleepAssertion = nil
        NSLog("Kestrel: released sleep assertion")
    }

    private func currentAudioPreference() -> CaptureCardCapturer.AudioPreference {
        let stored = Settings.shared.preferredAudioDeviceID
        if stored == Settings.audioDisabledID { return .none }
        if let id = stored, !id.isEmpty { return .device(uniqueID: id) }
        return .auto
    }

    private func beginWriter(info: VideoCaptureInfo) {
        state = .recordingStarting(info)
        do {
            try Settings.shared.ensureOutputDirectoryExists()
            let url = Settings.shared.nextRecordingURL()

            let cfg = RecordingSession.Configuration(
                url: url,
                width: info.pixelWidth,
                height: info.pixelHeight,
                frameRate: info.frameRate,
                bitrateBps: Settings.shared.bitrateBps,
                fragmentSeconds: Settings.shared.fragmentSeconds,
                includeAudio: capturer.hasAudio
            )

            let session = try RecordingSession(configuration: cfg)
            try session.start()
            self.session = session

            capturer.videoSampleHandler = { [weak session] sb in
                session?.appendVideo(sampleBuffer: sb)
            }
            if session.hasAudioInput {
                capturer.audioSampleHandler = { [weak session] sb in
                    session?.appendAudio(sampleBuffer: sb)
                }
            } else {
                capturer.audioSampleHandler = nil
            }

            state = .recording(info, url)
        } catch {
            capturer.videoSampleHandler = nil
            capturer.audioSampleHandler = nil
            self.session = nil
            state = .error(error.localizedDescription)
        }
    }

    private func presentPreviewWindow(for info: VideoCaptureInfo) {
        if let existing = previewWindow {
            existing.updateTitle(previewTitle(for: info))
            existing.show()
            return
        }
        let win = PreviewWindowController(session: capturer.session, title: previewTitle(for: info))
        win.onClose = { [weak self] in
            Task { @MainActor in self?.handlePreviewClosed() }
        }
        previewWindow = win
        win.show()
    }

    private func handlePreviewClosed() {
        previewWindow = nil
        // If we're still recording, keep the session running. Otherwise release it.
        if case .recording = state { return }
        Task {
            await capturer.stopSession()
            endSleepAssertion()
            state = .idle
        }
    }

    private func previewTitle(for info: VideoCaptureInfo) -> String {
        "\(info.deviceName) — \(info.pixelWidth)×\(info.pixelHeight) @ \(info.frameRate)fps"
    }
}
