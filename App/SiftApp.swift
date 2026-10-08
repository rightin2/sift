import AppKit
import Quartz
import SiftCore
import SwiftUI

@main
struct SiftApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()
    @AppStorage(Prefs.remindersOn) private var remindersOn = false

    init() {
        Prefs.register()
    }

    var body: some Scene {
        Window("Sift", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: Theme.Size.windowMinWidth, minHeight: Theme.Size.windowMinHeight)
        }
        // Open generously: about three quarters of the screen, never smaller than the
        // comfortable size, never bigger than the screen.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            let width = min(screen.width - 80, min(1680, max(1120, screen.width * 0.78)))
            let height = min(screen.height - 40, min(1200, max(860, screen.height * 0.86)))
            return WindowPlacement(.center, size: CGSize(width: width, height: height))
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose a folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                // In a text field, such as find, ⌘Z undoes the typing, not the last decision.
                // While finding, the title stays plain: ⌘Z may be undoing typing rather than a decision.
                Button(model.isFinding ? "Undo" : model.undoTitle) {
                    if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
                        text.undoManager?.undo()
                    } else {
                        model.undo()
                    }
                }
                .keyboardShortcut("z")
                .disabled(!model.canUndo && !model.isFinding)
            }
            CommandMenu("Sifting") { SiftCommands().environment(model) }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        // While reminders are on, Sift keeps watching from the menu bar.
        MenuBarExtra(isInserted: $remindersOn) {
            MenuBarMenu().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
    }
}

/// The Sifting menu: every key, so each one can be found, plus order and starting over.
/// Single-letter commands only work while the main window is in front.
private struct SiftCommands: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let order = Binding(get: { model.order }, set: { model.order = $0 })
        let keys = model.canUseSiftKeys
        let sifting = model.activeStack != nil
        Group {
            Button("Save") { model.send(.save) }.keyboardShortcut("s", modifiers: [])
            Button("Ditch") { model.send(.ditch) }.keyboardShortcut("d", modifiers: [])
            Button("Examine") { model.send(.examine) }.keyboardShortcut("e", modifiers: [])
        }
        .disabled(!keys)
        Group {
            Button("Save the rest") { model.send(.saveRest) }.keyboardShortcut("s", modifiers: .option)
            Button("Ditch the rest…") { model.send(.ditchRest) }.keyboardShortcut("d", modifiers: .option)
        }
        .disabled(!keys)
        Divider()
        Group {
            Button("Go to next undecided") { model.send(.nextUndecided) }.keyboardShortcut("n", modifiers: [])
            Button("Go to previous undecided") { model.send(.previousUndecided) }.keyboardShortcut("n", modifiers: .shift)
        }
        .disabled(!keys)
        Button("Find…") { model.send(.find) }
            .keyboardShortcut("f")
            .disabled(!sifting)
        Button("Find next") { model.find(model.findText, next: true) }
            .keyboardShortcut("g")
            .disabled(!sifting || model.findText.isEmpty)
        Divider()
        Button("Show in Finder") { model.send(.showInFinder) }
            .keyboardShortcut("r")
            .disabled(!sifting)
        Button("Copy path") { model.send(.copyPath) }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!sifting)
        Divider()
        Picker("Order", selection: order) {
            ForEach(FolderScanner.Order.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Button("Start this folder over…") { model.isAskingToStartOver = true }
            .disabled(model.stack == nil || model.isTrashing)
        Divider()
        Button("Finish") { model.finish() }
            .keyboardShortcut(.return)
            .disabled(!sifting || (model.stack?.decidedCount ?? 0) == 0)
    }
}

/// The menu bar icon, with today's count once it reaches the reminder limit.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.dailyLimit) private var dailyLimit = 10

    var body: some View {
        let newToday = DownloadWatcher.shared.newToday
        HStack(spacing: 2) {
            Image(systemName: newToday >= dailyLimit ? "tray.full.fill" : "tray.full")
            if newToday >= dailyLimit { Text("\(newToday)") }
        }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let watcher = DownloadWatcher.shared
        let name = Prefs.watchedFolderURL.lastPathComponent
        Text("\(watcher.newToday) new in \(name) today")
        Text("\(watcher.total) items in \(name)")
        Divider()
        Button("Sift \(name) now") {
            model.openMainWindow = { openWindow(id: "main") }
            model.siftWatchedFolder()
        }
        Button("Open Sift") {
            model.openMainWindow = { openWindow(id: "main") }
            model.showWindow()
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Sift") { NSApp.terminate(nil) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    /// A folder opened with Sift from Finder, or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { AppModel.shared?.openFromFinder(url) }
    }

    /// Right-click the Dock icon to sift Downloads, Desktop or a recent folder.
    @MainActor func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        var seen: Set<URL> = []
        let folders = ([AppModel.downloads, AppModel.desktop] + (AppModel.shared?.recentFolders ?? []))
            .map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
            .prefix(8)
        for (index, folder) in folders.enumerated() {
            // Downloads and Desktop first, then recent folders.
            if index == 2 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "Sift \(folder.lastPathComponent)", action: #selector(siftFromDock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = folder
            menu.addItem(item)
        }
        return menu
    }

    @objc private func siftFromDock(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL else { return }
        MainActor.assumeIsolated {
            AppModel.shared?.open(folder)
            AppModel.shared?.showWindow()
        }
    }

    /// Quitting while files move to the Bin waits until they have all moved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared?.shouldQuit() ?? .terminateNow }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared?.rememberNow() }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // `-SiftAppearance light` or `dark` on launch forces one appearance, for testing both.
            switch UserDefaults.standard.string(forKey: "SiftAppearance") {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
            Reminders.shared.setUp()
            AppModel.shared?.applyReminderSettings()
            // Opened at login with reminders on: start quietly in the menu bar.
            if launchedAtLogin && UserDefaults.standard.bool(forKey: Prefs.remindersOn) {
                NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// With reminders on, closing the window leaves Sift watching from the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: Prefs.remindersOn)
    }

    /// Opening Sift again (Dock, Finder, Spotlight) while it watches from the menu bar brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated { AppModel.shared?.showWindow() }
        }
        return true
    }

    // The Quick Look window looks along the responder chain for a controller; the app
    // delegate is always on it, so Sift's preview source is found from any window.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPanel.shared
            panel.delegate = QuickLookPanel.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
