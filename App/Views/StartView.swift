import SwiftUI

/// Where every sift begins: choose a folder, or pick Downloads, Desktop or a recent folder.
/// Each shows how many items are new since you last sifted it. Return reopens the last one.
struct StartView: View {
    @Environment(AppModel.self) private var model
    /// Items with no remembered decision, per folder.
    @State private var newCounts: [URL: Int] = [:]

    private var recents: [URL] {
        let fixed: Set<URL> = [AppModel.downloads.standardizedFileURL, AppModel.desktop.standardizedFileURL]
        return model.recentFolders
            .filter { !fixed.contains($0.standardizedFileURL) && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(4)
            .map { $0 }
    }

    private var lastFolder: URL? {
        model.recentFolders.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        GlassPanel {
            VStack(spacing: Theme.Space.xl) {
                VStack(spacing: Theme.Space.s) {
                    Text("Sift")
                        .font(Theme.Font.hero)
                        .foregroundStyle(Theme.text)
                    Text("Work through a folder one file at a time.")
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                }

                VStack(spacing: Theme.Space.m) {
                    Button { model.chooseFolder() } label: {
                        Label("Choose a folder", systemImage: "folder").frame(minWidth: Theme.Size.primaryButtonMinWidth)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.actionFill)
                    .controlSize(.extraLarge)

                    // Bordered, not glass: glass on the glass panel loses its backing.
                    HStack(spacing: Theme.Space.s) {
                        folderButton(AppModel.downloads, symbol: "arrow.down.circle", key: "1")
                        folderButton(AppModel.desktop, symbol: "menubar.dock.rectangle", key: "2")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Recent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, Theme.Space.s)
                        ForEach(recents, id: \.self) { folder in
                            Button { model.open(folder) } label: {
                                HStack(spacing: Theme.Space.s) {
                                    FinderIcon(url: folder)
                                    Text(folder.lastPathComponent)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: Theme.Space.m)
                                    Text(newLabel(folder) ?? "")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.secondary)
                                }
                                .font(.callout)
                                .padding(.horizontal, Theme.Space.s)
                                .frame(height: Theme.Size.rowHeight)
                            }
                            .buttonStyle(RowButtonStyle())
                            .help("Sift \(folder.path)")
                        }
                    }
                    .frame(width: Theme.Size.startListWidth)
                }

                VStack(spacing: Theme.Space.xs) {
                    if let lastFolder {
                        HStack(spacing: Theme.Space.xs) {
                            KeyCap("↩")
                            Text("sifts \(lastFolder.lastPathComponent) again")
                        }
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                    }
                    Text("Nothing is deleted. Ditched files go to the Bin.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Return reopens the last folder without a default button tinting the panel.
            if let lastFolder {
                Button("Sift \(lastFolder.lastPathComponent) again") { model.open(lastFolder) }
                    .keyboardShortcut(.defaultAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .task { await loadCounts() }
    }

    private func folderButton(_ folder: URL, symbol: String, key: KeyEquivalent) -> some View {
        Button { model.open(folder) } label: {
            HStack(spacing: Theme.Space.s) {
                Label(folder.lastPathComponent, systemImage: symbol)
                if let label = newLabel(folder) {
                    Text(label)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .keyboardShortcut(key)
        .help("Sift \(folder.lastPathComponent) (⌘\(String(key.character)))")
    }

    /// "12 new", "Nothing new", or nothing while counting.
    private func newLabel(_ folder: URL) -> String? {
        guard let count = newCounts[folder.standardizedFileURL] else { return nil }
        return count == 0 ? "Nothing new" : "\(count) new"
    }

    /// Counts only folders Sift has opened before, so the start screen never asks for access
    /// to a folder you haven't chosen. Each folder counts on its own, so a big one doesn't hold
    /// up the rest.
    private func loadCounts() async {
        let opened = Set(model.recentFolders.map(\.standardizedFileURL))
        let folders = ([AppModel.downloads, AppModel.desktop] + recents)
            .map(\.standardizedFileURL)
            .filter { opened.contains($0) }
        await withTaskGroup(of: (URL, Int?).self) { group in
            for folder in folders {
                group.addTask { (folder, await model.newCount(in: folder)) }
            }
            for await (folder, count) in group {
                if let count { newCounts[folder] = count }
            }
        }
    }
}
