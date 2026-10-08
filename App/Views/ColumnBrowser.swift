import SiftCore
import SwiftUI

/// A Finder-style column view of where you are: one column per folder on the path,
/// with the folder you are inside (or the current card) highlighted and every decision marked.
struct ColumnBrowser: View {
    @Environment(AppModel.self) private var model
    let stack: FolderStack

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(columns) { column in
                        Column(
                            session: column.session,
                            highlighted: column.highlighted,
                            isDeepest: column.isDeepest,
                            openFolder: { model.open($0, from: column.session) },
                            selectItem: { model.select($0, in: column.session) },
                            showFolder: { model.leave(to: column.session) })
                        Divider()
                    }
                    if let next = stack.current.current, next.isDirectory {
                        PeekColumn(
                            folder: next,
                            order: stack.order,
                            decisions: stack.visited.first { $0.folder == next.url }?.decisions ?? [:],
                            open: { _ = model.enter(next) },
                            openAt: { id in _ = model.enter(next, selecting: id) })
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
            .scrollIndicators(.automatic)
            .onChange(of: stack.path.count) { scrollToEnd(proxy) }
            .onChange(of: stack.current.current?.id) { scrollToEnd(proxy) }
        }
        .frame(height: Theme.Size.columnsHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tray, style: .continuous))
        .warmGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.tray, style: .continuous))
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(Theme.Motion.base) { proxy.scrollTo("end", anchor: .trailing) }
    }

    /// One snapshot of the path, so no column ever indexes a level that has just gone.
    private var columns: [ColumnModel] {
        let path = stack.path
        return path.indices.map { level in
            let isDeepest = level == path.count - 1
            return ColumnModel(
                id: path[level].folder,
                session: path[level],
                highlighted: isDeepest ? path[level].current?.id : path[level + 1].folder,
                isDeepest: isDeepest)
        }
    }
}

private struct ColumnModel: Identifiable {
    /// The column's folder.
    let id: URL
    let session: SiftSession
    /// The folder this level leads into, or the current card in the deepest column.
    let highlighted: URL?
    let isDeepest: Bool
}

/// A column's title row: the folder name and how much is left. Clicking it sifts that folder.
private struct ColumnHeader: View {
    let title: String
    let detail: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "folder")
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.rowHeight)
        }
        .buttonStyle(RowButtonStyle())
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: Theme.Size.headerHeight)
        .help(help)
    }
}

private struct Column: View {
    let session: SiftSession
    let highlighted: URL?
    let isDeepest: Bool
    let openFolder: (FileItem) -> Void
    let selectItem: (FileItem) -> Void
    let showFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                title: session.folder.lastPathComponent,
                detail: session.remainingCount == 0 ? "All sorted" : "\(session.remainingCount) left",
                help: "Sift \(session.folder.lastPathComponent)",
                action: showFolder)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if session.items.isEmpty {
                            Text("Empty folder")
                                .font(.callout)
                                .foregroundStyle(Theme.secondary)
                                .padding(Theme.Space.s)
                        }
                        ForEach(session.items) { item in
                            ColumnRow(
                                item: item,
                                decision: session.decisions[item.id],
                                selection: item.id == highlighted ? (isDeepest ? .current : .path) : .none,
                                action: item.isDirectory ? { openFolder(item) } : { selectItem(item) })
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, Theme.Space.xs)
                }
                .onAppear { proxy.scrollTo(highlighted, anchor: .center) }
                .onChange(of: highlighted) { _, id in
                    withAnimation(Theme.Motion.fast) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(width: Theme.Size.columnWidth)
    }
}

private struct ColumnRow: View {
    enum Selection { case none, path, current }

    let item: FileItem
    let decision: Decision?
    let selection: Selection
    /// A folder opens; a file becomes the current card.
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(RowButtonStyle(selection: selectionFill))
            .help(item.isDirectory ? "Sift inside \(item.name)" : "Show \(item.name)")
    }

    private var label: some View {
        HStack(spacing: Theme.Space.s) {
            FinderIcon(url: item.url)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            if let decision {
                Image(systemName: decision == .keep ? "checkmark" : "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selection == .current ? Theme.onAccent : (decision == .keep ? Theme.keep : Theme.toss))
                    .accessibilityLabel(decision == .keep ? "Saved" : "Ditched")
            }
            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selection == .current ? Theme.onAccent : Theme.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(textColor)
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.rowHeight)
    }

    /// Ditched rows recede so what is left stands out, except on the path, where secondary
    /// text on the path fill would drop below 4.5:1.
    private var textColor: Color {
        if selection == .current { return Theme.onAccent }
        return decision == .toss && selection == .none ? Theme.secondary : Theme.text
    }

    private var selectionFill: Color? {
        switch selection {
        case .current: Theme.rowSelected
        case .path: Theme.rowOnPath
        case .none: nil
        }
    }
}

/// What is inside the folder on the current card, the way Finder previews the next column.
private struct PeekColumn: View {
    let folder: FileItem
    /// The sift's order, so the rows don't jump when you step in.
    let order: FolderScanner.Order
    /// Decisions already made inside, if you have been in before.
    let decisions: [FileItem.ID: Decision]
    let open: () -> Void
    /// Steps in with one file highlighted.
    let openAt: (URL) -> Void

    @State private var children: [FileItem]?
    @State private var unreadable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnHeader(
                title: folder.name,
                detail: "→ Sift inside",
                help: "Sift inside \(folder.name) (right arrow)",
                action: open)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if unreadable {
                        note("Sift can't read this folder")
                    } else if children?.isEmpty == true {
                        note("Empty folder")
                    }
                    ForEach(children ?? []) { child in
                        Button { openAt(child.id) } label: {
                            HStack(spacing: Theme.Space.s) {
                                FinderIcon(url: child.url)
                                Text(child.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: Theme.Space.xs)
                                if let decision = decisions[child.id] {
                                    Image(systemName: decision == .keep ? "checkmark" : "trash")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(decision == .keep ? Theme.keep : Theme.toss)
                                        .accessibilityLabel(decision == .keep ? "Saved" : "Ditched")
                                }
                                if child.isDirectory {
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: Theme.Size.rowHeight)
                        }
                        .buttonStyle(RowButtonStyle())
                        .help("Sift inside \(folder.name), starting at \(child.name)")
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
            }
        }
        .frame(width: Theme.Size.columnWidth)
        .task(id: "\(folder.url.path)|\(order.rawValue)") {
            let url = folder.url
            let order = order
            let scanned = await Task.detached { try? FolderScanner.scan(url, order: order) }.value
            unreadable = scanned == nil
            children = scanned ?? []
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.secondary)
            .padding(Theme.Space.s)
    }
}

/// The small Finder icon for a file or folder, as in Finder's column view.
struct FinderIcon: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
    }
}
