import AppKit
import SwiftUI

/// Turns two-finger horizontal trackpad swipes into a drag offset. Vertical scrolls pass
/// through untouched, so a multi-page PDF in the preview still scrolls. Mouse wheels have
/// no gesture phase and always pass through, and so does any swipe that starts outside
/// `region`, so the column view above the card can still scroll sideways.
@MainActor
final class HorizontalSwipeMonitor {
    var isEnabled = true
    /// Where a swipe may start, in SwiftUI window coordinates (origin top left). Nil means anywhere.
    var region: CGRect?
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }

    private enum Axis { case undecided, horizontal, vertical }
    private var monitor: Any?
    private var axis: Axis?
    private var offset: CGFloat = 0
    private var swallowingMomentum = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.shouldConsume(event) ?? false }
            return consume ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func shouldConsume(_ event: NSEvent) -> Bool {
        // Fingers touching down start a new gesture, so any leftover momentum flag is stale.
        if event.phase == .mayBegin || event.phase == .began { swallowingMomentum = false }

        // After a swipe ends, the trackpad keeps sending momentum. Eat it so nothing else scrolls.
        if !event.momentumPhase.isEmpty {
            guard swallowingMomentum else { return false }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                swallowingMomentum = false
            }
            return true
        }
        guard isEnabled, event.isForMainWindowAlone else { return false }

        switch event.phase {
        case .began:
            offset = 0
            axis = startsInRegion(event) ? .undecided : .vertical
            return claim(event)
        case .changed:
            return claim(event)
        case .ended, .cancelled:
            defer { axis = nil }
            guard axis == .horizontal else { return false }
            swallowingMomentum = true
            onEnd(event.phase == .cancelled ? 0 : offset)
            offset = 0
            return true
        default:
            return axis == .horizontal
        }
    }

    private func startsInRegion(_ event: NSEvent) -> Bool {
        guard let region else { return true }
        let height = event.window?.contentView?.bounds.height ?? 0
        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        return region.contains(point)
    }

    /// Picks the axis from the first movement, then tracks horizontal movement only.
    private func claim(_ event: NSEvent) -> Bool {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if axis == .undecided, dx != 0 || dy != 0 {
            axis = abs(dx) > abs(dy) ? .horizontal : .vertical
        }
        guard axis == .horizontal else { return false }
        offset += dx
        onChange(offset)
        return true
    }
}

extension NSEvent {
    /// True when the event belongs to Sift's own window with no sheet or modal panel
    /// (such as the Open panel) in front, so monitors never act behind a dialog.
    @MainActor var isForMainWindowAlone: Bool {
        guard let window, window === MainWindow.window, window.attachedSheet == nil else { return false }
        return NSApp.modalWindow == nil
    }
}

extension View {
    /// Reports a running horizontal trackpad offset, then the final offset when the fingers lift.
    func onHorizontalSwipe(
        isEnabled: Bool,
        region: CGRect?,
        onChange: @escaping (CGFloat) -> Void,
        onEnd: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(HorizontalSwipeModifier(isEnabled: isEnabled, region: region, onChange: onChange, onEnd: onEnd))
    }
}

private struct HorizontalSwipeModifier: ViewModifier {
    let isEnabled: Bool
    let region: CGRect?
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    @State private var monitor = HorizontalSwipeMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.onChange = onChange
                monitor.onEnd = onEnd
                monitor.isEnabled = isEnabled
                monitor.region = region
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: isEnabled) { _, enabled in monitor.isEnabled = enabled }
            .onChange(of: region) { _, region in monitor.region = region }
    }
}
