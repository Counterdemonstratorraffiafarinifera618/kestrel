import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let recordingController = RecordingController()
    private var settingsWindow: SettingsWindowController?

    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    private var statusInfoItem: NSMenuItem!

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton(recording: false)
        buildMenu()

        recordingController.onStateChange = { [weak self] state in
            Task { @MainActor in self?.applyState(state) }
        }
        applyState(recordingController.state)
    }

    func shutdown() {
        recordingController.stopEverything()
    }

    private func configureButton(recording: Bool) {
        guard let button = statusItem.button else { return }
        let symbol = recording ? "record.circle.fill" : "record.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Kestrel")
        image?.isTemplate = !recording
        button.image = image
        button.toolTip = recording ? "Kestrel — Recording" : "Kestrel"
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        statusInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusInfoItem.isEnabled = false
        menu.addItem(statusInfoItem)
        menu.addItem(.separator())

        previewItem = NSMenuItem(title: "Show Preview", action: #selector(togglePreview), keyEquivalent: "p")
        previewItem.target = self
        menu.addItem(previewItem)

        menu.addItem(.separator())

        startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "r")
        startItem.target = self
        menu.addItem(startItem)

        stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "s")
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kestrel", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func togglePreview() {
        recordingController.togglePreview()
    }

    @objc private func startRecording() {
        recordingController.startRecording()
    }

    @objc private func stopRecording() {
        recordingController.stopRecording()
    }

    @objc private func openFolder() {
        try? Settings.shared.ensureOutputDirectoryExists()
        NSWorkspace.shared.open(Settings.shared.outputDirectory)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }

    @objc private func quit() {
        recordingController.stopEverything()
        NSApp.terminate(nil)
    }

    private func applyState(_ state: RecordingController.State) {
        let previewVisible = recordingController.isPreviewVisible
        previewItem.title = previewVisible ? "Hide Preview" : "Show Preview"

        switch state {
        case .idle:
            startItem.isEnabled = true
            stopItem.isEnabled = false
            previewItem.isEnabled = true
            statusInfoItem.title = "Idle"
            configureButton(recording: false)

        case .starting:
            startItem.isEnabled = false
            stopItem.isEnabled = false
            previewItem.isEnabled = false
            statusInfoItem.title = "Starting capture…"

        case .previewing(let info):
            startItem.isEnabled = true
            stopItem.isEnabled = false
            previewItem.isEnabled = true
            statusInfoItem.title = "Preview: \(info.deviceName) — \(info.pixelWidth)×\(info.pixelHeight)@\(info.frameRate)"
            configureButton(recording: false)

        case .recordingStarting(let info):
            startItem.isEnabled = false
            stopItem.isEnabled = false
            previewItem.isEnabled = true
            statusInfoItem.title = "Starting recording — \(info.deviceName)"

        case .recording(let info, let url):
            startItem.isEnabled = false
            stopItem.isEnabled = true
            previewItem.isEnabled = true
            statusInfoItem.title = "Recording \(info.pixelWidth)×\(info.pixelHeight)@\(info.frameRate) → \(url.lastPathComponent)"
            configureButton(recording: true)

        case .stopping:
            startItem.isEnabled = false
            stopItem.isEnabled = false
            previewItem.isEnabled = false
            statusInfoItem.title = "Stopping…"

        case .error(let message):
            startItem.isEnabled = true
            stopItem.isEnabled = false
            previewItem.isEnabled = true
            statusInfoItem.title = "Error"
            configureButton(recording: false)
            showAlert(title: "Kestrel", message: message)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        let needsCameraSettings = message.localizedCaseInsensitiveContains("camera")
        let needsScreenSettings = message.localizedCaseInsensitiveContains("screen recording")
        if needsCameraSettings || needsScreenSettings {
            alert.addButton(withTitle: "Open System Settings")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let urlString = needsCameraSettings
                ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
                : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
