import AppKit
import SwiftUI

/// The translucent warm window, and the screen inside it. Screens cross-fade so nothing blinks into place.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.transparency) private var transparency = 0.5
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.surface
                .opacity(reduceTransparency ? 1 : Theme.windowTint(transparency: transparency))
                .ignoresSafeArea()
                .animation(Theme.Motion.fast, value: transparency)
            screen
                .id(model.screenKey)
                .transition(.opacity)
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(Theme.secondary, lineWidth: Theme.Size.dropLine)
                    .padding(Theme.Space.s)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let folder = model.opening {
                OpeningNote(folder: folder)
                    .padding(.bottom, Theme.Space.xl)
            }
        }
        // Drop a folder anywhere on the window to sift it, unless a sift is under way.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isSifting, !model.isTrashing else { return false }
            model.openFromFinder(url)
            return true
        } isTargeted: { isDropTarget = $0 && !model.isSifting }
        .background {
            WindowReader { window in
                guard MainWindow.window !== window else { return }
                MainWindow.window = window
                model.isMainWindowKey = window.isKeyWindow
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as? NSWindow === MainWindow.window { model.isMainWindowKey = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object as? NSWindow === MainWindow.window { model.isMainWindowKey = false }
        }
        .animation(Theme.Motion.base, value: model.screenKey)
        .containerBackground(
            reduceTransparency ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(.thinMaterial),
            for: .window)
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            // With reminders on, Sift lives on in the menu bar without a Dock icon.
            if UserDefaults.standard.bool(forKey: Prefs.remindersOn) { NSApp.setActivationPolicy(.accessory) }
        }
        .toolbar {
            // An invisible item keeps the title bar the same height on every screen,
            // so the window does not jump when sifting starts or ends.
            if !model.isSifting {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .alert(model.problem ?? "", isPresented: problemShown) {
            Button("Close") {}
        }
        .alert(startOverTitle, isPresented: $model.isAskingToStartOver) {
            Button("Start over") { model.startFolderOver() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sift forgets every decision for this folder, including ones from earlier sifts. Nothing moves.")
        }
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .start:
            StartView()
        case .sifting(let stack):
            SiftingView(stack: stack)
        case .done(let stack):
            DoneView(stack: stack)
        case .empty(let folder):
            MessageView.empty(folder)
        case .accessNeeded(let folder):
            MessageView.accessNeeded(folder)
        }
    }

    private var startOverTitle: String {
        "Start \(model.stack?.root.folder.lastPathComponent ?? "this folder") over?"
    }

    private var problemShown: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    }
}

/// "Opening Downloads" while a big folder is scanned. Waits a moment, so a quick open never flickers.
private struct OpeningNote: View {
    let folder: URL
    @State private var isShown = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView().controlSize(.small)
            Text("Opening \(folder.lastPathComponent)")
                .font(.callout)
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .warmGlass(in: Capsule())
        .opacity(isShown ? 1 : 0)
        .animation(Theme.Motion.fast, value: isShown)
        .task(id: folder) {
            isShown = false
            try? await Task.sleep(for: .milliseconds(300))
            isShown = true
        }
    }
}
