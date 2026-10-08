import SiftCore
import SwiftUI

/// The end of a sift: what was saved, what went to the Bin and the space it freed,
/// with a way to review and the next folder one click (or Return) away.
struct DoneView: View {
    @Environment(AppModel.self) private var model
    let stack: FolderStack
    @State private var isReviewing = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.s) {
                Text(heading)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                if stack.trashedSize > 0 {
                    Text("Freed \(stack.trashedSize.formatted(.byteCount(style: .file)))")
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                }
            }

            HStack(spacing: Theme.Space.l) {
                Tray(
                    title: "Saved",
                    // A file put back under a new name is shown, and revealed, where it is now.
                    entries: stack.keptInPlace.map { item in
                        let url = stack.currentURL(of: item)
                        return TrayEntry(id: url, name: url.lastPathComponent, thumbnail: url, size: item.size)
                    },
                    symbol: "checkmark", tint: Theme.keep, large: true,
                    pick: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
                Tray(
                    title: "Ditched",
                    entries: stack.trashed.map {
                        TrayEntry(id: $0.trashURL ?? $0.item.url, name: $0.item.name, thumbnail: $0.trashURL ?? $0.item.url, size: $0.item.size)
                    },
                    symbol: "trash", tint: Theme.toss, large: true,
                    pick: { _ in isReviewing = true })
            }

            if !stack.failedInPlace.isEmpty {
                let count = stack.failedInPlace.count
                Label(
                    "\(count) \(count == 1 ? "file" : "files") didn't go to the Bin. Review ditched shows why.",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.text)
            }

            VStack(spacing: Theme.Space.m) {
                GlassEffectContainer(spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        Button {
                            isReviewing = true
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Text("Review ditched")
                                KeyCap("R")
                            }
                        }
                        .buttonStyle(.glass)
                        .keyboardShortcut("r", modifiers: [])
                        .disabled(stack.trashed.isEmpty && stack.failedInPlace.isEmpty)
                        Button("Sift another folder") { model.startOver() }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.actionFill)
                            .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.extraLarge)
                }
                if !nextFolders.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        Text("Or go straight to")
                            .foregroundStyle(Theme.secondary)
                        ForEach(nextFolders, id: \.self) { folder in
                            Button {
                                model.open(folder)
                            } label: {
                                Label(folder.lastPathComponent, systemImage: "folder")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .help("Sift \(folder.path)")
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isReviewing) {
            ReviewTossedSheet(stack: stack).environment(model)
        }
    }

    /// Up to three other folders worth sifting next: recent ones first, then Downloads and Desktop.
    private var nextFolders: [URL] {
        let here = stack.root.folder
        var seen: Set<URL> = [here]
        return (model.recentFolders + [AppModel.downloads, AppModel.desktop])
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0.path) }
            .prefix(3)
            .map { $0 }
    }

    private var heading: String {
        let decided = stack.decidedCount
        // "files" for plain files, "items" once a folder or package was decided.
        let hasFolders = stack.visited.contains { session in
            session.items.contains { ($0.isDirectory || $0.isPackage) && session.decisions[$0.id] != nil }
        }
        let noun = (hasFolders ? "item" : "file") + (decided == 1 ? "" : "s")
        // Only folders where something was decided count, not ones you just looked into.
        let folders = stack.visited.count { $0.decidedCount > 0 }
        if folders > 1 {
            return "Sifted \(decided) \(noun) across \(folders) folders"
        }
        let total = stack.root.items.count
        return decided == total ? "Sifted \(total) \(noun)" : "Sifted \(decided) of \(total) \(hasFolders ? "items" : "files")"
    }
}

/// Everything ditched this sift, each with a way back. Rows stay in place as you put things
/// back, so the list never jumps.
private struct ReviewTossedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let stack: FolderStack

    /// Everything in the Trash when the sheet opened.
    @State private var rows: [TrashedFile] = []
    /// Where each put-back file landed.
    @State private var landed: [URL: URL] = [:]

    var body: some View {
        let stillInTrash = Set(stack.trashed.map(\.id))
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Review ditched")
                    .font(Theme.Font.sheetTitle)
                    .foregroundStyle(Theme.text)
                Text("Put back anything you still need. It returns to the folder it came from.")
                    .foregroundStyle(Theme.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("Nothing from this sift is in the Bin.")
                            .foregroundStyle(Theme.secondary)
                            .padding(.vertical, Theme.Space.s)
                    }
                    ForEach(rows) { file in
                        let isBack = !stillInTrash.contains(file.id)
                        FileRow(
                            item: file.item,
                            thumbnailURL: isBack ? whereNow(file) ?? file.item.url : file.trashURL,
                            caption: isBack ? backCaption(file) : nil
                        ) {
                            if isBack {
                                Label("Returned", systemImage: "checkmark")
                                    .font(.callout)
                                    .foregroundStyle(Theme.keep)
                            } else {
                                Button("Put back") {
                                    if let url = withAnimation(Theme.Motion.fast, { model.putBack(file) }) {
                                        landed[file.id] = url
                                    }
                                }
                                .buttonStyle(.glass)
                                .controlSize(.large)
                                .disabled(file.trashURL == nil)
                            }
                        }
                        Divider()
                    }
                    if !stack.failedInPlace.isEmpty {
                        Text("Not moved")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                            .padding(.top, Theme.Space.m)
                        ForEach(stack.failedInPlace) { file in
                            FileRow(item: file.item, caption: file.reason) { EmptyView() }
                        }
                    }
                }
            }
            .frame(minHeight: Theme.Size.sheetListMin, maxHeight: Theme.Size.sheetListMax)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            HStack {
                Button("Put back all") {
                    let landings = withAnimation(Theme.Motion.fast) { model.putBackAll() }
                    landed.merge(landings) { _, new in new }
                }
                .buttonStyle(.glass)
                .disabled(stack.trashed.isEmpty)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.actionFill)
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Size.sheetWidth)
        .onAppear { rows = stack.trashed }
    }

    /// Where a put-back file landed, including a folder brought back so a file could go inside it.
    private func whereNow(_ file: TrashedFile) -> URL? {
        landed[file.id] ?? stack.restoredURL(of: file.id)
    }

    /// "Back in Downloads", or "Back as Report 2.pdf" when the old name was taken.
    private func backCaption(_ file: TrashedFile) -> String {
        guard let url = whereNow(file) else { return "Back where it was" }
        if url.lastPathComponent != file.item.name {
            return "Back as \(url.lastPathComponent), since the old name was taken"
        }
        return "Back in \(url.deletingLastPathComponent().lastPathComponent)"
    }
}
