import SiftCore
import SwiftUI

/// What is inside a folder, since Quick Look shows a blank card for one.
/// The header and the way in stay put; only the grid scrolls when space is tight.
/// Click a thumbnail to step in with that file highlighted.
struct FolderPreview: View {
    let url: URL
    /// The sift's order, so the grid matches what you see once inside.
    var order: FolderScanner.Order = .newest
    /// Decisions already made inside, if you have been in, shown as small badges.
    let decisions: [FileItem.ID: Decision]
    let open: () -> Void
    let openAt: (URL) -> Void

    private enum Load {
        case loading
        case ready([FileItem])
        case unreadable
    }

    @State private var load: Load = .loading

    private static let shown = 24

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: Theme.Symbol.message, height: Theme.Symbol.message)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(summary)
                        .font(.title3)
                        .foregroundStyle(Theme.secondary)
                    if let progress {
                        Text(progress)
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            if case .ready(let items) = load, !items.isEmpty {
                let shown = Array(items.prefix(Self.shown))
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Theme.Size.gridCell), spacing: Theme.Space.m)],
                        spacing: Theme.Space.m
                    ) {
                        ForEach(shown) { item in
                            Button { openAt(item.id) } label: {
                                VStack(spacing: Theme.Space.xs) {
                                    FileThumbnail(url: item.url, side: Theme.Size.gridThumb)
                                        .overlay(alignment: .bottomTrailing) { badge(for: item) }
                                    Text(item.name)
                                        .font(.caption)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(Theme.Space.xs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(RowButtonStyle())
                            .help("Sift inside, starting at \(item.name)")
                        }
                    }
                    // Narrow the grid for a handful of items so it sits centred.
                    .frame(maxWidth: min(Theme.Size.gridMaxWidth, CGFloat(shown.count) * (Theme.Size.gridCell + Theme.Space.m)))
                    .frame(maxWidth: .infinity)
                    if items.count > shown.count {
                        Text("And \(items.count - shown.count) more")
                            .font(.callout)
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, Theme.Space.s)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Button(action: open) {
                Label("Sift inside", systemImage: "arrow.right")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Sift the files in this folder (right arrow)")
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(url.path)|\(order.rawValue)") {
            let url = url
            let order = order
            let scanned = await Task.detached { try? FolderScanner.scan(url, order: order) }.value
            load = scanned.map(Load.ready) ?? .unreadable
        }
    }

    @ViewBuilder private func badge(for item: FileItem) -> some View {
        if let decision = decisions[item.id] {
            Image(systemName: decision == .keep ? "checkmark.circle.fill" : "trash.circle.fill")
                .font(.body)
                .foregroundStyle(Theme.onAccent, decision == .keep ? Theme.keepFill : Theme.tossFill)
                .accessibilityLabel(decision == .keep ? "Saved" : "Ditched")
                .offset(x: Theme.Space.xs, y: Theme.Space.xs)
        }
    }

    private var summary: String {
        switch load {
        case .loading:
            return " "
        case .unreadable:
            return "Sift can't read this folder"
        case .ready(let items):
            let count = items.isEmpty ? "Empty folder" : items.count == 1 ? "1 item" : "\(items.count) items"
            let bytes = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            return bytes > 0 ? "\(count), \(bytes.formatted(.byteCount(style: .file)))" : count
        }
    }

    /// "12 of 30 sorted" once you have been inside.
    private var progress: String? {
        guard case .ready(let items) = load, !decisions.isEmpty else { return nil }
        let sorted = items.count { decisions[$0.id] != nil }
        return sorted == items.count ? "All sorted" : "\(sorted) of \(items.count) sorted"
    }
}
