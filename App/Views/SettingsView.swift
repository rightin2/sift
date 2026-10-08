import AppKit
import ServiceManagement
import SwiftUI

/// Sift's Settings window (⌘,): how see-through the window is, and "time to sift" reminders.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Reminders", systemImage: "bell.badge") { ReminderSettings() }
        }
        .frame(width: Theme.Size.settingsWidth)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.transparency) private var transparency = 0.5
    @AppStorage("showColumns") private var showColumns = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval

    var body: some View {
        Form {
            Section {
                LabeledContent("Window") {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Slider(value: $transparency, in: 0...1, step: 0.25) {
                            Text("Transparency")
                        } minimumValueLabel: {
                            Text("Solid")
                        } maximumValueLabel: {
                            Text("See-through")
                        }
                        .labelsHidden()
                        Text(reduceTransparency
                             ? "Reduce transparency is on in System Settings, so the window stays solid."
                             : "Your wallpaper shows softly through the window. File previews always stay solid.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            Section {
                Toggle("Show the column view while sifting", isOn: $showColumns)
            }
            Section {
                Toggle("Open Sift at login", isOn: $openAtLogin)
                if loginNeedsApproval {
                    HStack {
                        Text("macOS needs your OK in Login Items.")
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: Theme.Size.settingsGeneralHeight)
        .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

private struct ReminderSettings: View {
    @AppStorage(Prefs.remindersOn) private var remindersOn = false
    @AppStorage(Prefs.dailyOn) private var dailyOn = true
    @AppStorage(Prefs.dailyLimit) private var dailyLimit = 10
    @AppStorage(Prefs.totalOn) private var totalOn = false
    @AppStorage(Prefs.totalLimit) private var totalLimit = 50
    @AppStorage(Prefs.watchedFolder) private var watchedFolder = ""

    @State private var allowed = true
    @State private var notAskedYet = false

    private let watcher = DownloadWatcher.shared

    var body: some View {
        Form {
            Section {
                Toggle("Remind me when it's time to sift", isOn: $remindersOn)
                Text("Sift stays in the menu bar while reminders are on, so it can watch the folder with its window closed.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                if remindersOn && !allowed {
                    if notAskedYet {
                        HStack {
                            Text("Sift needs your OK to send notifications.")
                            Spacer()
                            Button("Allow notifications") {
                                Task { await updatePermission(asking: true) }
                            }
                        }
                        .font(.callout)
                    } else {
                        HStack {
                            Text("Notifications are off for Sift.")
                            Spacer()
                            Button("Open notification settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            }

            Section("Remind me") {
                Toggle(isOn: $dailyOn) {
                    Stepper("When \(dailyLimit) or more files arrive in a day", value: $dailyLimit, in: 1...500)
                }
                Toggle(isOn: $totalOn) {
                    Stepper("When the folder holds more than \(totalLimit) items", value: $totalLimit, in: 5...5000, step: 5)
                }
            }
            .disabled(!remindersOn)

            Section("Folder") {
                LabeledContent("Watching") {
                    HStack {
                        Text(Prefs.watchedFolderURL.lastPathComponent)
                        Button("Change…", action: chooseFolder)
                        if !watchedFolder.isEmpty {
                            Button("Use Downloads") { watchedFolder = "" }
                        }
                    }
                }
                if remindersOn {
                    LabeledContent("Right now") {
                        Text(watcher.canRead
                             ? "\(watcher.newToday) new today · \(watcher.total) items"
                             : "Sift can't read this folder. Allow access in System Settings.")
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            .disabled(!remindersOn)

            Section {
                Button("Send a test reminder") {
                    Task {
                        if await updatePermission(asking: true) {
                            Reminders.shared.sendTest(
                                folder: Prefs.watchedFolderURL, newToday: watcher.newToday, total: watcher.total)
                        }
                    }
                }
                .disabled(!remindersOn)
            }
        }
        .formStyle(.grouped)
        .frame(height: Theme.Size.settingsRemindersHeight)
        .onChange(of: remindersOn) { _, on in
            Task {
                if on { await updatePermission(asking: true) }
                AppModel.shared?.applyReminderSettings()
            }
        }
        .onChange(of: watchedFolder) { AppModel.shared?.applyReminderSettings() }
        .onChange(of: dailyLimit) { watcher.refresh() }
        .onChange(of: totalLimit) { watcher.refresh() }
        .task { await updatePermission(asking: false) }
    }

    /// Reads (or first asks for) notification permission and updates the message shown.
    @discardableResult
    private func updatePermission(asking: Bool) async -> Bool {
        if asking {
            await Reminders.shared.requestPermission()
        } else {
            await Reminders.shared.refreshPermission()
        }
        allowed = Reminders.shared.isAllowed
        notAskedYet = Reminders.shared.notAskedYet
        // The folder may have crossed a limit while permission was missing.
        if allowed { watcher.refresh() }
        return allowed
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.directoryURL = Prefs.watchedFolderURL
        if panel.runModal() == .OK, let url = panel.url { watchedFolder = url.path }
    }
}
