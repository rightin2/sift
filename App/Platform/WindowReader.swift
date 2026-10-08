import AppKit
import SwiftUI

/// Hands back the NSWindow a view lives in, so key and swipe handling can be limited to
/// Sift's own window (not Settings, sheets or other panels).
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { found(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { found(window) }
    }
}

/// Sift's main window, once it exists.
@MainActor
enum MainWindow {
    static weak var window: NSWindow?
}
