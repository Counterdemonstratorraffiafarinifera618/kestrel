import AppKit
import AVFoundation

/// NSView that hosts and stretches an `AVCaptureVideoPreviewLayer` to its bounds.
final class PreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the user closes the window via the red button or Cmd+W.
    var onClose: (() -> Void)?

    convenience init(session: AVCaptureSession, title: String) {
        let view = PreviewView(session: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = NSSize(width: 320, height: 180)
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func updateTitle(_ title: String) {
        window?.title = title
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
