import SiftCore
import SwiftUI
import UniformTypeIdentifiers

/// One entry inside a package or an archive, for the read-only contents browser.
@MainActor
final class ContentsNode: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
    /// The real file, for package contents. Nil inside an archive, which is never extracted.
    let url: URL?
    private var cached: [ContentsNode]?

    init(id: String, name: String, isFolder: Bool, url: URL?, children: [ContentsNode]? = nil) {
        self.id = id
        self.name = name
        self.isFolder = isFolder
        self.url = url
        self.cached = children
    }

    convenience init(_ entry: ArchiveReader.Entry) {
        self.init(
            id: entry.path, name: entry.name, isFolder: entry.isFolder, url: nil,
            children: entry.children.map(ContentsNode.init))
    }

    /// Folders inside a package are read from disk the first time they are opened.
    var children: [ContentsNode] {
        if let cached { return cached }
        guard isFolder, let url else { return [] }
        let found = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let loaded = found
            .map { child in
                ContentsNode(
                    id: "\(id)/\(child.lastPathComponent)",
                    name: child.lastPathComponent,
                    isFolder: (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                    url: child)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached = loaded
        return loaded
    }

    var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        if isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

/// The card for a package or archive that Quick Look cannot preview: its icon, its kind,
/// a glimpse of what is inside and the way in.
struct ContentsCard: View {
    let item: FileItem
    let kind: CardKind
    let facts: FileFacts?
    let show: () -> Void

    @State private var glimpse: String?

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            // The icon gives up height first, so a small window never clips the card.
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Theme.Symbol.fileIcon, maxHeight: Theme.Symbol.fileIcon)
                .layoutPriority(-1)
            VStack(spacing: Theme.Space.xs) {
                Text(item.typeIdentifier.flatMap(UTType.init)?.localizedDescription?.capitalizedFirst ?? "Package")
                    .font(.title3)
                    .foregroundStyle(Theme.secondary)
                if let glimpse {
                    Text(glimpse)
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: Theme.Size.readingWidth)
                }
            }
            if facts?.alreadyUnzipped == true {
                Label("Already unzipped beside it", systemImage: "archivebox")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            }
            Button(action: show) {
                Label(kind.examineLabel, systemImage: "eye")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("\(kind.examineLabel) (E)")
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.url) {
            guard kind == .archive, let listing = await ArchiveCache.listing(for: item.url) else { return }
            let names = listing.entries.prefix(3).map(\.name)
            let more = listing.entries.count > names.count ? ", and more" : ""
            let count = listing.truncated ? "Over \(ArchiveReader.limit.formatted()) items" : listing.count == 1 ? "1 item" : "\(listing.count.formatted()) items"
            glimpse = names.isEmpty ? count : "\(count): \(names.joined(separator: ", "))\(more)"
        }
    }
}

/// Loads a package or archive and shows it in columns. Read-only: nothing inside can be tossed.
struct ContentsView: View {
    let item: FileItem
    let kind: CardKind
    let close: () -> Void

    private enum Load {
        case loading
        case ready(ContentsNode, count: Int?, truncated: Bool)
        case failed
    }

    @State private var load: Load = .loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView("Reading \(item.name)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let root, let count, let truncated):
                ContentsBrowser(
                    title: kind == .archive ? "Archive contents" : "Package contents",
                    root: root, count: count, truncated: truncated, close: close)
            case .failed:
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: Theme.Symbol.status, weight: .light))
                        .foregroundStyle(Theme.secondary)
                    Text("Sift can't read inside \(item.name)")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text("Open it in Finder to see what's inside.")
                        .foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.url) { await read() }
    }

    private func read() async {
        if kind == .package {
            load = .ready(ContentsNode(id: "", name: item.name, isFolder: true, url: item.url), count: nil, truncated: false)
            return
        }
        guard let listing = await ArchiveCache.listing(for: item.url) else {
            load = .failed
            return
        }
        let root = ContentsNode(id: "", name: item.name, isFolder: true, url: nil,
                                children: listing.entries.map(ContentsNode.init))
        load = .ready(root, count: listing.count, truncated: listing.truncated)
    }
}

/// Finder-style columns over a package or archive. Click a folder to open the next column.
struct ContentsBrowser: View {
    let title: String
    let root: ContentsNode
    let count: Int?
    let truncated: Bool
    let close: () -> Void

    /// Folders opened below the root, in order.
    @State private var opened: [ContentsNode] = []
    /// The file picked in the last column.
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "shippingbox")
                Text(title).font(.headline)
                Text(root.name)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                if let count {
                    Text(truncated ? "First \(ArchiveReader.limit.formatted()) items" : "\(count.formatted()) items")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondary)
                }
                Text("Read only")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Button("Close", action: close)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Close the contents (E or Esc)")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Size.headerHeight)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.level) { column in
                            ContentsColumn(node: column.node, highlighted: column.highlighted) { child in
                                open(child, from: column.level)
                            }
                            Divider()
                        }
                        Color.clear.frame(width: 1).id("end")
                    }
                }
                .onChange(of: opened.count) {
                    withAnimation(Theme.Motion.base) { proxy.scrollTo("end", anchor: .trailing) }
                }
            }
        }
    }

    private struct Column {
        let level: Int
        let node: ContentsNode
        let highlighted: String?
    }

    /// One snapshot, so no column indexes a level that has just closed.
    private var columns: [Column] {
        let nodes = [root] + opened
        return nodes.indices.map { level in
            Column(
                level: level, node: nodes[level],
                highlighted: level + 1 < nodes.count ? nodes[level + 1].id : picked)
        }
    }

    private func open(_ child: ContentsNode, from level: Int) {
        opened = Array(opened.prefix(level))
        if child.isFolder {
            opened.append(child)
            picked = nil
        } else {
            picked = child.id
        }
    }
}

private struct ContentsColumn: View {
    let node: ContentsNode
    let highlighted: String?
    let pick: (ContentsNode) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let children = node.children
                if children.isEmpty {
                    Text("Empty folder")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .padding(Theme.Space.s)
                }
                ForEach(children) { child in
                    ContentsRow(node: child, isHighlighted: child.id == highlighted) { pick(child) }
                }
            }
            .padding(.horizontal, Theme.Space.xs)
        }
        .frame(width: Theme.Size.columnWidth)
    }
}

private struct ContentsRow: View {
    let node: ContentsNode
    let isHighlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(nsImage: node.icon)
                    .resizable()
                    .frame(width: Theme.Size.rowIcon, height: Theme.Size.rowIcon)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                if node.isFolder {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHighlighted ? Theme.onAccent : Theme.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(isHighlighted ? Theme.onAccent : Theme.text)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.rowHeight)
        }
        .buttonStyle(RowButtonStyle(selection: isHighlighted ? Theme.rowSelected : nil))
    }
}

private extension String {
    /// "ZIP archive" stays as is; "application" becomes "Application".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
