import Quartz

/// macOS's own Quick Look window, the full preview E opens: zoom, full screen, page
/// thumbnails and playback, exactly as Space shows in Finder. It follows the highlight,
/// so up, down, S and D keep working while it is open.
@MainActor
final class QuickLookPanel: NSObject {
    static let shared = QuickLookPanel()
    private(set) var url: URL?
    /// The card's frame on screen, so the panel zooms out of the card and back into it.
    private var sourceFrame: CGRect?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Opens the preview. `keepingKey` leaves the keyboard with the current window, so a
    /// sheet's own keys keep working while the preview follows along.
    func show(_ url: URL, over frame: CGRect? = nil, keepingKey: Bool = false) {
        self.url = url
        sourceFrame = frame
        guard let panel = QLPreviewPanel.shared() else { return }
        let keyWindow = NSApp.keyWindow
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        keepLarge(panel)
        if keepingKey { keyWindow?.makeKey() }
    }

    /// Shows a different file if the window is open. Nil closes it.
    func follow(_ url: URL?, over frame: CGRect? = nil) {
        guard isVisible else { return }
        guard let url else { return close() }
        guard url != self.url else { return }
        self.url = url
        sourceFrame = frame
        let panel = QLPreviewPanel.shared()!
        panel.reloadData()
        keepLarge(panel)
    }

    /// Quick Look re-fits itself to each file. Hold it at one large size over most of Sift's
    /// window instead, so it never jumps while you flip through files.
    private func keepLarge(_ panel: QLPreviewPanel) {
        guard let window = MainWindow.window else { return }
        let frame = window.frame
        panel.setFrame(frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.08), display: true)
    }

    func close() {
        if isVisible { QLPreviewPanel.shared().orderOut(nil) }
    }
}

extension QuickLookPanel: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}

extension QuickLookPanel: @preconcurrency QLPreviewPanelDelegate {
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        sourceFrame ?? .zero
    }
}
