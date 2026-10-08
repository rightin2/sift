import AppKit
import SwiftUI

/// A calm full-window message with one main action, for states where there is nothing to sift.
struct MessageView: View {
    let symbol: String
    let badge: String?
    let title: String
    let message: String
    let primary: (title: String, action: @MainActor () -> Void)
    let secondary: [(title: String, action: @MainActor () -> Void)]

    var body: some View {
        GlassPanel {
            VStack(spacing: Theme.Space.l) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Symbol.message, weight: .light))
                    .foregroundStyle(Theme.secondary)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: Theme.Symbol.badge, weight: .semibold))
                                .foregroundStyle(Theme.text)
                                .offset(x: Theme.Space.s, y: Theme.Space.xs)
                        }
                    }

                VStack(spacing: Theme.Space.s) {
                    Text(title)
                        .font(Theme.Font.sheetTitle)
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                }
                .multilineTextAlignment(.center)

                VStack(spacing: Theme.Space.s) {
                    Button(primary.title, action: primary.action)
                        .buttonStyle(.glassProminent)
                        .tint(Theme.actionFill)
                    // Bordered, not glass: glass on the glass panel loses its backing.
                    HStack(spacing: Theme.Space.s) {
                        ForEach(secondary.indices, id: \.self) { index in
                            Button(secondary[index].title, action: secondary[index].action)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.large)
            }
            .frame(maxWidth: Theme.Size.readingWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MessageView {
    @MainActor static func accessNeeded(_ folder: URL) -> some View {
        AccessNeeded(folder: folder)
    }

    @MainActor static func empty(_ folder: URL) -> some View {
        EmptyFolder(folder: folder)
    }
}

private struct AccessNeeded: View {
    @Environment(AppModel.self) private var model
    let folder: URL

    var body: some View {
        let name = folder.lastPathComponent
        MessageView(
            symbol: "folder",
            badge: "lock.fill",
            title: "Sift can't read \(name)",
            message: "In System Settings, open Privacy & Security, then Files and Folders, and turn on \(name) under Sift. Sift tries again when you come back.",
            primary: ("Open System Settings", { model.openPrivacySettings() }),
            secondary: [
                ("Try again", { model.open(folder) }),
                ("Choose another folder", { model.chooseFolder() }),
            ])
        // Coming back from System Settings tries again on its own, but only while the folder is
        // still there; a folder that has gone gets one alert, from Try again, not one per switch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Not while another folder the user just chose is opening.
            if model.opening == nil, FileManager.default.fileExists(atPath: folder.path) { model.open(folder) }
        }
    }
}

/// A folder with nothing in it is a small win, with the next folder one click away.
private struct EmptyFolder: View {
    @Environment(AppModel.self) private var model
    let folder: URL

    private var next: URL? {
        let here = folder.standardizedFileURL
        return [AppModel.downloads, AppModel.desktop]
            .map(\.standardizedFileURL)
            .first { $0 != here }
    }

    var body: some View {
        let model = model
        if let next {
            MessageView(
                symbol: "checkmark.circle",
                badge: nil,
                title: "\(folder.lastPathComponent) is clear",
                message: "There's nothing in it to sift.",
                primary: ("Sift \(next.lastPathComponent)", { model.open(next) }),
                secondary: [
                    ("Choose another folder", { model.chooseFolder() }),
                    ("Go back", { model.startOver() }),
                ])
        } else {
            MessageView(
                symbol: "checkmark.circle",
                badge: nil,
                title: "\(folder.lastPathComponent) is clear",
                message: "There's nothing in it to sift.",
                primary: ("Choose another folder", { model.chooseFolder() }),
                secondary: [("Go back", { model.startOver() })])
        }
    }
}
