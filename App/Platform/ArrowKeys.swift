import AppKit
import Quartz
import SwiftUI

/// The keys and commands Sift answers while sifting. Letters sit under the left hand,
/// arrows under the right, so nothing needs the mouse. The Sift menu sends the same commands.
enum SiftKey: Equatable {
    case save, ditch, examine
    case saveRest, ditchRest
    case up, down, left, right
    case nextUndecided, previousUndecided
    case first, last, pageUp, pageDown
    case space, escape
    case find, showInFinder, copyPath
}

/// Catches Sift's keys in its main window, even when the Quick Look preview has focus, and in
/// the Quick Look window too. A handler returns false to let a key through, so unhandled keys
/// still reach the preview. Keys typed into a text field always pass through.
@MainActor
final class SiftKeyMonitor {
    var isEnabled = true
    var onKey: (SiftKey) -> Bool = { _ in false }
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consume ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isEnabled,
              event.isForSiftKeys,
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !(event.window?.firstResponder is NSText),
              let key = Self.key(for: event)
        else { return false }
        // A held letter decides once; its repeats are swallowed. Held arrows keep moving.
        if event.isARepeat {
            switch key {
            case .up, .down, .pageUp, .pageDown, .nextUndecided, .previousUndecided: break
            default: return true
            }
        }
        return onKey(key)
    }

    private static func key(for event: NSEvent) -> SiftKey? {
        let option = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126: return option ? .first : (shift ? nil : .up)
        case 125: return option ? .last : (shift ? nil : .down)
        case 123: return option || shift ? nil : .left
        case 124: return option || shift ? nil : .right
        case 115: return .first      // Home
        case 119: return .last       // End
        case 116: return .pageUp
        case 121: return .pageDown
        case 49: return option || shift ? nil : .space
        case 53: return .escape
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s" where !shift: return option ? .saveRest : .save
        case "d" where !shift: return option ? .ditchRest : .ditch
        case "e" where !option && !shift: return .examine
        case "n" where !option: return shift ? .previousUndecided : .nextUndecided
        default: return nil
        }
    }
}

extension NSEvent {
    /// True for Sift's main window or the Quick Look window, with no sheet or other panel in front.
    @MainActor var isForSiftKeys: Bool {
        guard let window, NSApp.modalWindow == nil else { return false }
        // Quick Look counts only while the main window has nothing on top, such as the confirm sheet.
        if window is QLPreviewPanel { return MainWindow.window?.attachedSheet == nil }
        return window === MainWindow.window && window.attachedSheet == nil
    }
}

extension View {
    func onSiftKeys(isEnabled: Bool, _ handle: @escaping (SiftKey) -> Bool) -> some View {
        modifier(SiftKeyModifier(isEnabled: isEnabled, handle: handle))
    }
}

private struct SiftKeyModifier: ViewModifier {
    let isEnabled: Bool
    let handle: (SiftKey) -> Bool
    @State private var monitor = SiftKeyMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.onKey = handle
                monitor.isEnabled = isEnabled
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: isEnabled) { _, enabled in monitor.isEnabled = enabled }
    }
}
