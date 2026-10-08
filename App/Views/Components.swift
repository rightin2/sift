import SiftCore
import SwiftUI
import UniformTypeIdentifiers

/// What the card shows, and what Examine (E) does for it.
enum CardKind: Equatable {
    /// Right arrow (or E) opens the folder and sifts inside.
    case folder
    /// E opens the full Quick Look window.
    case preview
    /// A file Quick Look cannot draw, such as a disk image. The card shows its details.
    case info
    /// An app or other bundle Quick Look cannot preview. E shows its package contents.
    case package
    /// A zip, tar, pkg and so on. E lists what is inside.
    case archive

    var examineLabel: String {
        switch self {
        case .folder: "Sift inside"
        case .preview, .info: "Examine"
        case .package: "Show package contents"
        case .archive: "Show archive contents"
        }
    }

    /// Package and archive contents open inside the card; everything else uses Quick Look.
    var examinesInCard: Bool { self == .package || self == .archive }
}

extension FileItem {
    /// The kind from the file alone. Probing Quick Look can turn `.preview` into `.info`,
    /// and `.package` into `.preview` when it can draw the package.
    var quickKind: CardKind {
        if isDirectory { return .folder }
        if isPackage { return .package }
        if let type = typeIdentifier.flatMap(UTType.init) {
            // Disk images are archives to the system, but bsdtar can't read inside them.
            if type.identifier.hasPrefix("com.apple.disk-image") { return .info }
            if type.conforms(to: .archive) { return .archive }
        }
        return .preview
    }

    /// Sound and video always preview: Quick Look plays them even without a thumbnail.
    var isPlayable: Bool {
        typeIdentifier.flatMap(UTType.init)?.conforms(to: .audiovisualContent) ?? false
    }
    /// "2.4 MB · Modified 3 Oct 2026", or "Folder · Modified 3 Oct 2026".
    var detail: String {
        var parts: [String] = []
        if isDirectory {
            parts.append("Folder")
        } else if let size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if let modified {
            parts.append("Modified \(modified.formatted(.dateTime.day().month(.abbreviated).year()))")
        }
        return parts.joined(separator: " · ")
    }
}

/// The solid surface every file card sits on. Reading surfaces are never glass.
struct CardSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .shadow(color: Theme.Shadow.card, radius: Theme.Shadow.cardRadius, y: Theme.Shadow.cardY)
    }
}

/// A warm glass panel for short messages on the start and empty screens.
struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Space.xxl)
            .warmGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}


/// One file shown in a tray and its list.
struct TrayEntry: Identifiable {
    let id: URL
    let name: String
    /// Where to draw the thumbnail from (a ditched file's place in the Trash, once moved).
    let thumbnail: URL
    let size: Int64?
}

/// A glass tray holding a small pile of the latest thumbnails, a label, a count and the space
/// it adds up to. Click it to see everything in it.
struct Tray: View {
    let title: String
    /// Oldest first. Only the last three are drawn on the pile.
    let entries: [TrayEntry]
    let symbol: String
    let tint: Color
    var large = false
    /// Clicking a file in the list, e.g. to jump to it.
    var pick: ((URL) -> Void)?

    @State private var isListing = false

    private var thumbSide: CGFloat { large ? Theme.Size.trayThumbLarge : Theme.Size.trayThumb }
    private var bytes: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }

    var body: some View {
        Button { isListing = true } label: { tray }
            .buttonStyle(TrayButtonStyle())
            .disabled(entries.isEmpty)
            .help(entries.isEmpty ? title : "Show everything \(title.lowercased())")
            .popover(isPresented: $isListing, arrowEdge: .bottom) {
                TrayList(title: title, entries: entries) { id in
                    isListing = false
                    pick?(id)
                }
            }
            .accessibilityLabel("\(title): \(entries.count)")
    }

    private var tray: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack {
                if entries.isEmpty {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .frame(width: thumbSide, height: thumbSide)
                        .overlay(Image(systemName: symbol).font(.title2).foregroundStyle(tint))
                } else {
                    let pile = Array(entries.suffix(3))
                    ForEach(Array(pile.enumerated()), id: \.element.id) { index, entry in
                        let step = CGFloat(index - pile.count + 1)
                        FileThumbnail(url: entry.thumbnail, side: thumbSide)
                            .padding(Theme.Space.xs)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .shadow(color: Theme.Shadow.thumb, radius: Theme.Shadow.thumbRadius, y: Theme.Shadow.thumbY)
                            .offset(x: step * -6, y: step * -6)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .frame(height: thumbSide + Theme.Space.l)
            .animation(Theme.Motion.base, value: entries.last?.id)

            Text(title)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            Text(entries.count, format: .number)
                .font(large ? Theme.Font.bigCount : Theme.Font.count)
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Theme.Motion.fast, value: entries.count)
            Text(bytes > 0 ? bytes.formatted(.byteCount(style: .file)) : " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, Theme.Space.l)
        .padding(.horizontal, Theme.Space.m)
        .frame(width: large ? Theme.Size.trayWidthLarge : Theme.Size.trayWidth)
        .warmGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.tray, style: .continuous))
    }
}

/// Hover and press for a whole tray.
private struct TrayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TrayBody(configuration: configuration)
    }

    private struct TrayBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.tray, style: .continuous)
            configuration.label
                .overlay(shape.fill(fill).allowsHitTesting(false))
                .contentShape(shape)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Theme.rowPressed }
            return isHovering ? Theme.rowHover : .clear
        }
    }
}

/// Everything in a tray, newest last, solid for reading.
private struct TrayList: View {
    let title: String
    let entries: [TrayEntry]
    let pick: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) · \(entries.count)")
                .font(.headline)
                .padding(Theme.Space.m)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.reversed()) { entry in
                        Button { pick(entry.id) } label: {
                            HStack(spacing: Theme.Space.s) {
                                FileThumbnail(url: entry.thumbnail, side: Theme.Size.rowIcon + Theme.Space.s)
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: Theme.Space.s)
                                if let size = entry.size {
                                    Text(size.formatted(.byteCount(style: .file)))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.secondary)
                                }
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .frame(height: Theme.Size.listRowHeight)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .padding(Theme.Space.xs)
            }
        }
        .frame(
            width: Theme.Size.popoverWidth,
            // Each row is its label plus the row style's padding; the header takes about two rows.
            height: min(
                Theme.Size.popoverMaxHeight,
                CGFloat(entries.count) * (Theme.Size.listRowHeight + Theme.Size.rowHitHeight - Theme.Size.rowHeight)
                    + Theme.Size.listRowHeight * 2 + Theme.Space.m))
        .background(Theme.card)
    }
}

/// Save, Undo and Ditch, grouped so the glass flows together. Each carries its key.
struct DecisionBar: View {
    let canDecide: Bool
    let canUndo: Bool
    let undoTitle: String
    let save: () -> Void
    let undo: () -> Void
    let ditch: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Button(action: save) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "checkmark")
                        Text("Save")
                        KeyCap("S", onAccent: true)
                    }
                    .frame(minWidth: Theme.Size.decisionButtonMinWidth)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.keepFill)
                .disabled(!canDecide)
                .help("Save this file (S). ⌥S saves everything left here.")

                Button(action: undo) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Undo")
                    }
                }
                .buttonStyle(.glass)
                .disabled(!canUndo)
                .help("\(undoTitle) (⌘Z)")

                Button(action: ditch) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "trash")
                        Text("Ditch")
                        KeyCap("D", onAccent: true)
                    }
                    .frame(minWidth: Theme.Size.decisionButtonMinWidth)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.tossFill)
                .disabled(!canDecide)
                .help("Ditch this file (D). ⌥D ditches everything left here.")
            }
            .controlSize(.extraLarge)
        }
    }
}

/// The label that fades in on a card while it is dragged.
struct DecisionStamp: View {
    let decision: Decision

    var body: some View {
        let fill = decision == .keep ? Theme.keepFill : Theme.tossFill
        Label(decision == .keep ? "Save" : "Ditch", systemImage: decision == .keep ? "checkmark" : "trash")
            .font(.headline)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            // A solid fill under the glass keeps the label at 5:1 or better over any card.
            .background(fill, in: .capsule)
            .glassEffect(.regular.tint(fill), in: .capsule)
    }
}

/// The name, one line of facts, and a few chips only when something matters. The chip row
/// keeps its space when empty, so nothing below it jumps.
struct FileCaption: View {
    let item: FileItem?
    let facts: FileFacts?

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(item?.name ?? " ")
                .font(Theme.Font.fileName)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .onDrag { dragProvider() }
                .help(item == nil ? "" : "Drag the name to put a copy somewhere else")
            Text(factsLine)
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: Theme.Space.xs) {
                ForEach(chips, id: \.text) { chip in
                    Label(chip.text, systemImage: chip.symbol)
                        .font(.caption)
                        // A warning reads in full text colour; green and amber stay for save and ditch.
                        .foregroundStyle(chip.warn ? Theme.text : Theme.secondary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.Size.chipHeight)
                        .background(Theme.notice, in: Capsule())
                }
            }
            .frame(height: Theme.Size.chipHeight)
        }
        .opacity(item == nil ? 0 : 1)
    }

    private var factsLine: String {
        guard let item else { return " " }
        var parts: [String] = []
        if item.isDirectory {
            parts.append("Folder")
        } else if let size = item.size {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if let added = item.addedPhrase { parts.append(added) }
        if let site = facts?.sourceSite { parts.append("from \(site)") }
        if let opened = facts?.openedPhrase { parts.append(opened) }
        if let shape = facts?.shape { parts.append(shape) }
        return parts.joined(separator: " · ")
    }

    private struct Chip {
        let text: String
        let symbol: String
        var warn = false
    }

    private var chips: [Chip] {
        guard let item else { return [] }
        var chips: [Chip] = []
        if AppModel.isDownloading(item) {
            chips.append(Chip(text: "Still downloading", symbol: "arrow.down.circle", warn: true))
        } else if item.isUnfinishedDownload {
            chips.append(Chip(text: "Unfinished download", symbol: "exclamationmark.circle"))
        }
        if let twin = facts?.duplicateOf { chips.append(Chip(text: "Same as \(twin)", symbol: "square.on.square")) }
        if facts?.alreadyUnzipped == true { chips.append(Chip(text: "Already unzipped", symbol: "archivebox")) }
        if item.isLocked { chips.append(Chip(text: "Locked", symbol: "lock.fill")) }
        if item.isInCloud { chips.append(Chip(text: "In iCloud", symbol: "icloud")) }
        for tag in item.tags.prefix(3) { chips.append(Chip(text: tag, symbol: "tag")) }
        return chips
    }

    /// A copy for whatever the name is dropped on, so the original stays where Sift expects it.
    private func dragProvider() -> NSItemProvider {
        guard let item else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = item.typeIdentifier.flatMap(UTType.init) ?? .data
        let url = item.url
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }
}

/// A quiet one-line note that floats above the buttons for a few seconds.
struct NoticeLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .warmGlass(in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The few keys that change with the card. Save, Ditch and Undo carry their own keys.
struct KeyHint: View {
    /// What E does for the current card.
    var examine: String?
    /// The current card is a folder, so the right arrow opens it.
    var canOpen = false
    /// What the left arrow does: close the contents, or go back to the parent folder.
    var back: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let examine { hint("E", examine) }
            hint("↑↓", "Move")
            hint("N", "Next undecided")
            if canOpen { hint("→", "Sift inside") }
            if let back {
                hint("←", back)
                    .layoutPriority(-1)
            }
        }
        .lineLimit(1)
        .font(.callout)
        .foregroundStyle(Theme.secondary)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            KeyCap(key)
            Text(action).truncationMode(.middle)
        }
    }
}

/// A key drawn as a small keycap.
struct KeyCap: View {
    let key: String
    var onAccent = false

    init(_ key: String, onAccent: Bool = false) {
        self.key = key
        self.onAccent = onAccent
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        Text(key)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(onAccent ? Theme.onAccent : Theme.text)
            .padding(.horizontal, Theme.Space.xs)
            .frame(minWidth: Theme.Size.keyCap, minHeight: Theme.Size.keyCap)
            // On a Save or Ditch fill, an outline keeps the letter on the bare fill (6.4:1 and 5:1).
            .background {
                if onAccent {
                    shape.strokeBorder(Theme.onAccent, lineWidth: 1)
                } else {
                    shape.fill(Theme.rowOnPath)
                }
            }
    }
}

/// One file in a sheet list: thumbnail, name, detail and a trailing action.
struct FileRow<Trailing: View>: View {
    let item: FileItem
    var thumbnailURL: URL?
    /// Replaces the size and date line, e.g. to say which subfolder the file is in.
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            FileThumbnail(url: thumbnailURL ?? item.url, side: Theme.Size.listRowHeight)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(caption ?? item.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.m)
            trailing
        }
        .padding(.vertical, Theme.Space.s)
    }
}
