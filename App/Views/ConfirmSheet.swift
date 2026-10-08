import SiftCore
import SwiftUI

/// The one confirmation before anything moves. Covers every folder visited, grouped by folder.
/// Rows stay put when you change your mind, so the list never jumps under the pointer.
/// ↑↓ move, S saves, D ditches, Space looks closer, Return confirms.
/// Once the move starts, the sheet locks until it finishes.
/// macOS in Australian English calls the Trash the Bin, so the copy does too.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let stack: FolderStack

    /// Everything that was ditched when the sheet opened, in the order shown.
    @State private var rows: [FileItem] = []
    @State private var highlighted: URL?
    @FocusState private var listFocused: Bool

    var body: some View {
        let tossed = stack.tossed
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(title(tossed.count, folders: tossed.contains { $0.isDirectory || $0.isPackage }))
                    .font(Theme.Font.sheetTitle)
                    .foregroundStyle(Theme.text)
                Text(subtitle(tossed))
                    .foregroundStyle(Theme.secondary)
            }

            if !rows.isEmpty { list }

            HStack(spacing: Theme.Space.s) {
                if let progress = model.trashProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: Theme.Size.progressWidth)
                    Text("Moving \(progress.done) of \(progress.total)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                } else if !rows.isEmpty {
                    Text("S saves, D ditches, Space takes a closer look")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Cancel") { model.isConfirming = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .disabled(model.isTrashing)
                Button(tossed.isEmpty ? "Finish" : "Move to Bin") {
                    QuickLookPanel.shared.close()
                    Task { await model.confirmTrash() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(tossed.isEmpty ? Theme.actionFill : Theme.tossFill)
                .disabled(model.isTrashing)
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xl)
        .frame(width: Theme.Size.sheetWidth)
        .interactiveDismissDisabled(model.isTrashing)
        .onAppear {
            rows = groups(of: stack.tossed).flatMap(\.items)
            highlighted = rows.first?.id
            listFocused = true
        }
        .onDisappear { QuickLookPanel.shared.close() }
    }

    /// Folders that would take saved files with them: saved this sift, or in an earlier one.
    private var warnings: [KeptInsideTossed] {
        let tossed = Set(stack.tossed.map(\.id))
        let now = stack.keptInsideTossedFolders
        let shown = Set(now.map(\.id))
        return now + model.rememberedWarnings.filter { tossed.contains($0.id) && !shown.contains($0.id) }
    }

    private var list: some View {
        let groups = groups(of: rows)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Warnings scroll with the list, so many of them never push the buttons away.
                    // Keyed by path, so a warning can never share a scroll target with its folder's row.
                    ForEach(warnings, id: \.folder.url.path) { warning in
                        FolderWarning(warning: warning) {
                            withAnimation(Theme.Motion.fast) { model.rescue(warning.folder) }
                        }
                        .padding(.bottom, Theme.Space.s)
                    }
                    ForEach(groups, id: \.folder) { group in
                        if groups.count > 1 {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                                .padding(.top, Theme.Space.s)
                                .padding(.horizontal, Theme.Space.s)
                        }
                        ForEach(group.items) { item in
                            ConfirmRow(
                                item: item,
                                isDitched: stack.tossed.contains { $0.id == item.id },
                                isHighlighted: highlighted == item.id,
                                save: { set(item, ditched: false) },
                                ditch: { set(item, ditched: true) })
                            .id(item.id)
                            .onTapGesture { highlighted = item.id }
                        }
                    }
                }
                .padding(Theme.Space.xs)
            }
            .frame(minHeight: Theme.Size.sheetListMin, maxHeight: Theme.Size.sheetListMax)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { step(-1, proxy) }
            .onKeyPress(.downArrow) { step(1, proxy) }
            .onKeyPress(characters: .init(charactersIn: "sSdD ")) { press in
                guard !model.isTrashing, let item = rows.first(where: { $0.id == highlighted }) else { return .ignored }
                switch press.characters.lowercased() {
                case "s": set(item, ditched: false)
                case "d": set(item, ditched: true)
                default:
                    if QuickLookPanel.shared.isVisible {
                        QuickLookPanel.shared.close()
                    } else {
                        QuickLookPanel.shared.show(item.url, keepingKey: true)
                    }
                }
                return .handled
            }
            .disabled(model.isTrashing)
        }
    }

    private func step(_ offset: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = rows.firstIndex { $0.id == highlighted } ?? -1
        let next = rows[min(max(index + offset, 0), rows.count - 1)]
        highlighted = next.id
        proxy.scrollTo(next.id)
        QuickLookPanel.shared.follow(next.url)
        return .handled
    }

    private func set(_ item: FileItem, ditched: Bool) {
        highlighted = item.id
        withAnimation(Theme.Motion.fast) {
            if ditched { model.reDitch(item) } else { model.rescue(item) }
        }
    }

    /// "files" for plain files, "items" once a folder or package is among them.
    private func title(_ count: Int, folders: Bool) -> String {
        let noun = folders ? "item" : "file"
        switch count {
        case 0: return "Nothing to ditch"
        case 1: return "Move 1 \(noun) to the Bin?"
        default: return "Move \(count) \(noun)s to the Bin?"
        }
    }

    /// "Frees 1.2 GB. You can put them back from Finder until you empty the Bin."
    private func subtitle(_ tossed: [FileItem]) -> String {
        guard !tossed.isEmpty else { return "You saved everything, so nothing goes to the Bin." }
        let back = "You can put \(tossed.count == 1 ? "it" : "them") back from Finder \(AppModel.recoverableUntil)."
        let bytes = stack.tossedSize
        guard bytes > 0 else { return back }
        let atLeast = tossed.contains { $0.isDirectory || $0.isPackage } ? "at least " : ""
        return "Frees \(atLeast)\(bytes.formatted(.byteCount(style: .file))). \(back)"
    }

    private struct Group {
        let folder: URL
        let title: String
        let items: [FileItem]
    }

    /// Ditched items by the folder they sit in, the starting folder first.
    private func groups(of items: [FileItem]) -> [Group] {
        let root = stack.root.folder
        var order: [URL] = []
        var byFolder: [URL: [FileItem]] = [:]
        for item in items {
            let folder = item.url.deletingLastPathComponent().standardizedFileURL
            if byFolder[folder] == nil { order.append(folder) }
            byFolder[folder, default: []].append(item)
        }
        return order
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
            .map { folder in
                let inside = folder.pathComponents.dropFirst(root.pathComponents.count)
                let title = ([root.lastPathComponent] + inside).joined(separator: " › ")
                return Group(folder: folder, title: title, items: byFolder[folder] ?? [])
            }
    }
}

/// One file in the confirm list. A saved row stays where it is and recedes.
private struct ConfirmRow: View {
    let item: FileItem
    let isDitched: Bool
    let isHighlighted: Bool
    let save: () -> Void
    let ditch: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: isDitched ? "trash" : "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(isDitched ? Theme.toss : Theme.keep)
                .frame(width: Theme.Space.m)
                .accessibilityLabel(isDitched ? "Ditched" : "Saved")
            FileThumbnail(url: item.url, side: Theme.Size.listThumb)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(isDitched || isHighlighted ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: Theme.Space.xs) {
                    Text(isDitched ? item.detail : "Saved, stays where it is")
                    if item.isLocked { flag("lock.fill", "Locked") }
                    if item.isInCloud { flag("icloud", "In iCloud") }
                    if !item.tags.isEmpty { flag("tag", item.tags.joined(separator: ", ")) }
                }
                .font(.caption)
                // Full text colour on the highlight keeps the caption above 4.5:1.
                .foregroundStyle(isHighlighted ? Theme.text : Theme.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            Button(isDitched ? "Save" : "Ditch", action: isDitched ? save : ditch)
                .buttonStyle(.glass)
                .controlSize(.large)
                .help(isDitched ? "Save this instead (S)" : "Ditch this after all (D)")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(
            isHighlighted ? Theme.rowOnPath : isHovering ? Theme.rowHover : .clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func flag(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .help(text)
    }
}

/// A heads-up that a ditched folder holds files you saved, which would go to the Trash with it.
private struct FolderWarning: View {
    let warning: KeptInsideTossed
    let keepFolder: () -> Void

    var body: some View {
        let count = warning.kept.count
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("\(warning.folder.name) holds \(count) \(count == 1 ? "file" : "files") you saved")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text("\(count == 1 ? "It goes" : "They go") to the Bin with the folder unless you save the folder.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Save folder", action: keepFolder)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding(Theme.Space.m)
        .background(Theme.notice, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
