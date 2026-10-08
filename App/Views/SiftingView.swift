import AppKit
import SiftCore
import SwiftUI

/// The core loop: a live preview between the Saved and Ditched trays, with the column view above.
/// Left hand decides: S saves, D ditches, E examines (⌥S and ⌥D for everything left).
/// Right hand moves, Finder style: up and down, N for the next undecided, right opens a folder,
/// left goes back up.
struct SiftingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var scale
    @AppStorage("showColumns") private var showColumns = true
    let stack: FolderStack

    @State private var dragOffset: CGFloat = 0
    @State private var pastThreshold = false
    @State private var outgoing: Outgoing?
    /// A package's or archive's contents fill the card.
    @State private var isInspecting = false
    /// Whether Quick Look can draw each file, found by asking it for a thumbnail.
    @State private var drawable: [URL: Bool] = [:]
    /// Archives bsdtar can't read inside, which get the info card instead.
    @State private var unreadableArchives: Set<URL> = []
    /// Where trackpad swipes count: the trays and the card, not the column view.
    @State private var swipeRegion: CGRect?
    /// The card's frame, so Quick Look can open over it.
    @State private var cardFrame: CGRect = .zero
    @State private var facts: FileFacts?
    @State private var findMissed = false
    @FocusState private var findFocused: Bool

    private var session: SiftSession { stack.current }
    private var canDecide: Bool { session.current != nil && !model.isConfirming }
    private var parentName: String? {
        stack.canLeave ? stack.path[stack.path.count - 2].folder.lastPathComponent : nil
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Theme.Space.l) {
            if showColumns && !isInspecting {
                ColumnBrowser(stack: stack)
                    .transition(slide(from: .top))
            }
            HStack(spacing: Theme.Space.l) {
                if !isInspecting {
                    Tray(
                        title: "Saved", entries: stack.kept.map(entry), symbol: "checkmark", tint: Theme.keep,
                        pick: { model.reveal($0) })
                    .transition(slide(from: .leading))
                }
                stage
                if !isInspecting {
                    Tray(
                        title: "Ditched", entries: stack.tossed.map(entry), symbol: "trash", tint: Theme.toss,
                        pick: { model.reveal($0) })
                    .transition(slide(from: .trailing))
                }
            }
            .contentShape(Rectangle())
            .gesture(drag)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { swipeRegion = $0 }
            footer
        }
        .animation(reduceMotion ? Theme.Motion.fast : Theme.Motion.base, value: showColumns)
        .animation(reduceMotion ? Theme.Motion.fast : Theme.Motion.base, value: isInspecting)
        .animation(Theme.Motion.fast, value: model.isFinding)
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, Theme.Space.l)
        .onHorizontalSwipe(
            isEnabled: canDecide && !isInspecting, region: swipeRegion,
            onChange: track, onEnd: release)
        // Typing in the find field passes through on its own, so the keys stay on while it is open.
        .onSiftKeys(isEnabled: !model.isConfirming, handle)
        .onChange(of: model.commandCount) { if let command = model.command { _ = handle(command) } }
        // Undo during a card's exit would show it twice, so the flying copy goes.
        .onChange(of: model.undoCount) { outgoing = nil }
        .onChange(of: session.current?.id) {
            if let item = session.current, kind(of: item).examinesInCard { return }
            isInspecting = false
        }
        .onChange(of: session.current?.url) {
            QuickLookPanel.shared.follow(session.current?.url, over: screenCardFrame)
        }
        .onAppear { model.watchCurrentFolder() }
        .onDisappear {
            QuickLookPanel.shared.close()
            model.stopWatching(for: stack)
        }
        .task(id: session.current?.id) { await prepare() }
        .task(id: session.current?.id) {
            facts = nil
            guard let item = session.current else { return }
            let loaded = await FileFacts.load(item, siblings: session.items)
            if !Task.isCancelled { facts = loaded }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.isConfirming) {
            ConfirmSheet(stack: stack).environment(model)
        }
        .alert(ditchRestTitle, isPresented: $model.isAskingToDitchRest) {
            Button("Ditch \(model.ditchRestIDs.count)") { model.decideRest(.toss) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing moves until you confirm, and ⌘Z takes it back.")
        }
    }

    private var ditchRestTitle: String {
        let count = model.ditchRestIDs.count
        return "Ditch the \(count == 1 ? "last item" : "other \(count)") in \(session.folder.lastPathComponent)?"
    }

    private func entry(_ item: FileItem) -> TrayEntry {
        TrayEntry(id: item.id, name: item.name, thumbnail: item.url, size: item.size)
    }

    // MARK: Stage

    private var stage: some View {
        GeometryReader { proxy in
            let travel = proxy.size.width / 2 + Theme.Space.l + Theme.Size.trayWidth / 2
            ZStack {
                let upcoming = Array(session.upcoming(2))
                ForEach(Array(upcoming.enumerated().reversed()), id: \.element.id) { depth, item in
                    BackCard(item: item, depth: depth + 1)
                }
                .opacity(isInspecting ? 0 : 1)

                if let item = session.current {
                    LiveCard(
                        item: item, kind: kind(of: item), facts: facts, isInspecting: isInspecting,
                        offset: dragOffset,
                        decisions: stack.visited.first { $0.folder == item.url }?.decisions ?? [:],
                        open: { _ = openFolder() },
                        order: model.order,
                        openAt: { id in _ = model.enter(item, selecting: id) },
                        examine: { _ = examine() })
                    .id(item.id)
                    .transition(.asymmetric(insertion: insertion(travel), removal: reduceMotion ? .opacity : .identity))
                    .contextMenu { fileMenu }
                } else {
                    statusPanel
                }

                if let outgoing {
                    OutgoingCard(outgoing: outgoing, travel: travel) {
                        if self.outgoing?.id == outgoing.id { self.outgoing = nil }
                    }
                    .id(outgoing.id)
                }
            }
            .frame(maxWidth: isInspecting ? .infinity : Theme.Size.cardMaxWidth)
            // Measured here, the card itself, so Quick Look zooms out of the card, not the stage.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let notice = model.notice {
                    NoticeLine(text: notice)
                        .padding(.bottom, Theme.Space.m)
                        .transition(.opacity)
                }
            }
        }
    }

    /// Shown when the current folder has nothing left to decide.
    @ViewBuilder private var statusPanel: some View {
        let name = session.folder.lastPathComponent
        if let parentName {
            StatusPanel(
                symbol: session.items.isEmpty ? "tray" : "checkmark.circle",
                title: session.items.isEmpty ? "Nothing in \(name)" : "All \(session.items.count) sorted in \(name)",
                message: session.items.isEmpty
                    ? "This folder has no visible files. Press ← to go back."
                    : "Press ← to keep sifting \(parentName), or ↑ to look back here. Undo still works.",
                actionTitle: "Go back to \(parentName)") { model.leave() }
        } else {
            StatusPanel(
                symbol: "checkmark.circle",
                title: stack.canUndo ? "All \(session.items.count) sorted" : "Nothing new in \(name)",
                message: stack.canUndo
                    ? "Press ↑ to look back, Undo to change your mind, or finish to review what goes to the Bin."
                    : "Everything here was sorted in an earlier sift. Press ↑ to look back, or choose Start this folder over in the Sifting menu.",
                actionTitle: "Finish") { model.finish() }
        }
    }

    private var footer: some View {
        VStack(spacing: Theme.Space.m) {
            FileCaption(item: session.current, facts: facts)
                .contextMenu { fileMenu }
            DecisionBar(
                canDecide: canDecide,
                canUndo: model.canUndo,
                undoTitle: model.undoTitle,
                save: { decide(.keep) },
                undo: { model.undo() },
                ditch: { decide(.toss) })
            // The find field and the ditched-folder banner take the key hint's place.
            if model.isFinding {
                findField
            } else if let folder = tossedFolderAround, !isInspecting {
                TossedFolderBanner(folder: folder) {
                    withAnimation(Theme.Motion.fast) { model.rescue(folder) }
                }
                .transition(.opacity)
            } else {
                KeyHint(
                    examine: examineHint,
                    canOpen: session.current?.isDirectory == true,
                    back: isInspecting ? "Close" : parentName.map { "Back to \($0)" })
            }
        }
    }

    private var examineHint: String? {
        guard let item = session.current else { return nil }
        if isInspecting { return "Close" }
        let kind = kind(of: item)
        return kind == .folder ? nil : kind.examineLabel
    }

    /// The same actions as the keys, on a right-click.
    @ViewBuilder private var fileMenu: some View {
        if let item = session.current {
            Button("Save") { decide(.keep) }
            Button("Ditch") { decide(.toss) }
            Button(kind(of: item).examineLabel) { _ = examine() }
            Divider()
            Button(item.isDirectory ? "Open in Finder" : "Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy path") { copyPath(item) }
        }
    }

    // MARK: Find

    @ViewBuilder private var findField: some View {
        if model.isFinding {
            @Bindable var model = model
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondary)
                TextField("Find by name", text: $model.findText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.text)
                    .focused($findFocused)
                    .onSubmit {
                        findMissed = !model.find(model.findText, next: true)
                        findFocused = true
                    }
                    .onChange(of: model.findText) { _, text in
                        findMissed = !text.isEmpty && !model.find(text)
                    }
                    .onExitCommand { closeFind() }
                if findMissed {
                    Text("No match")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                }
                Button(action: closeFind) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: Theme.Size.rowHitHeight, height: Theme.Size.rowHitHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("Close find")
                .help("Close (Esc)")
            }
            .padding(.leading, Theme.Space.m)
            .padding(.trailing, Theme.Space.xs)
            .frame(width: Theme.Size.findWidth)
            .warmGlass(in: Capsule())
            .transition(.opacity)
            .onAppear { findFocused = true }
        }
    }

    private func closeFind() {
        model.isFinding = false
        model.findText = ""
        findMissed = false
        findFocused = false
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Go back", systemImage: "chevron.backward") { model.leave() }
                .disabled(!stack.canLeave || model.isConfirming)
                .help(parentName.map { "Go back to \($0) (left arrow)" } ?? "Go back")
            Button(showColumns ? "Hide columns" : "Show columns", systemImage: "rectangle.split.3x1") {
                showColumns.toggle()
            }
            .help(showColumns ? "Hide the column view" : "Show the column view")
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: Theme.Space.s) {
                Menu {
                    ForEach(Array(stack.path.enumerated()), id: \.offset) { _, level in
                        Button(level.folder.lastPathComponent) { model.leave(to: level) }
                    }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.folder]) }
                } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "folder")
                        Text(pathLabel)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(maxWidth: Theme.Size.pathWidth)
                .help("Jump to a folder on this path")
                Divider().frame(height: Theme.Size.ring)
                ProgressRing(done: session.decidedCount, total: session.items.count)
                Text(session.remainingCount == 0 ? "All sorted" : "\(session.remainingCount) left")
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, Theme.Space.s)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Order", selection: Binding(get: { model.order }, set: { model.order = $0 })) {
                    ForEach(FolderScanner.Order.allCases, id: \.self) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Order", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Order")
            .help("Order: \(model.order.title)")
            Button {
                model.finish()
            } label: {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "checkmark.circle")
                    if !stack.tossed.isEmpty { Text("\(stack.tossed.count)").monospacedDigit() }
                }
            }
            .disabled(stack.decidedCount == 0 || model.isConfirming)
            .accessibilityLabel(stack.tossed.isEmpty ? "Finish" : "Finish, \(stack.tossed.count) waiting for the Bin")
            .help(stack.tossed.isEmpty
                  ? "Finish (⌘↩)"
                  : "Finish and review the \(stack.tossed.count) waiting to go to the Bin (⌘↩)")
        }
    }

    /// "Downloads › Projects › Final", shortened to the last three folders when deeper, so the
    /// toolbar never overflows.
    private var pathLabel: String {
        let names = stack.path.map(\.folder.lastPathComponent)
        guard names.count > 3 else { return names.joined(separator: " › ") }
        return (["…"] + names.suffix(3)).joined(separator: " › ")
    }

    /// The folder you are inside (or one above it) when you have already ditched it.
    private var tossedFolderAround: FileItem? {
        let path = stack.path
        for level in path.indices.dropFirst() {
            let parent = path[level - 1]
            if parent.decisions[path[level].folder] == .toss {
                return parent.items.first { $0.id == path[level].folder }
            }
        }
        return nil
    }

    private func slide(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private func kind(of item: FileItem) -> CardKind {
        switch item.quickKind {
        case .package:
            return drawable[item.url] == true ? .preview : .package
        case .preview:
            return drawable[item.url] == false && !item.isPlayable ? .info : .preview
        case .archive:
            return unreadableArchives.contains(item.url) ? .info : .archive
        case let other:
            return other
        }
    }

    /// The card's frame on screen, for Quick Look to open over.
    private var screenCardFrame: CGRect? {
        guard let window = MainWindow.window, let content = window.contentView, cardFrame.width > 0 else { return nil }
        let inWindow = NSRect(
            x: cardFrame.minX, y: content.bounds.height - cardFrame.maxY,
            width: cardFrame.width, height: cardFrame.height)
        return window.convertToScreen(inWindow)
    }

    // MARK: Input

    private func handle(_ key: SiftKey) -> Bool {
        // A sift that is fading out ignores keys meant for the one fading in.
        guard model.stack === stack else { return false }
        // With the find bar open but not focused, a letter is a search, not a decision: the field
        // takes focus back and nothing is decided.
        if model.isFinding && !findFocused {
            switch key {
            case .save, .ditch, .examine, .saveRest, .ditchRest, .nextUndecided, .previousUndecided:
                findFocused = true
                return true
            default:
                break
            }
        }
        switch key {
        case .save:
            decide(.keep)
            return true
        case .ditch:
            decide(.toss)
            return true
        case .saveRest:
            model.askToDecideRest(.keep)
            return true
        case .ditchRest:
            model.askToDecideRest(.toss)
            return true
        case .examine, .space:
            return examine()
        case .up: return moving { model.move(by: -1) }
        case .down: return moving { model.move(by: 1) }
        case .pageUp: return moving { model.move(by: -10) }
        case .pageDown: return moving { model.move(by: 10) }
        case .first: return moving { model.moveToEdge(first: true) }
        case .last: return moving { model.moveToEdge(first: false) }
        case .nextUndecided: return moving { model.moveToUndecided(forward: true) }
        case .previousUndecided: return moving { model.moveToUndecided(forward: false) }
        case .right:
            return openFolder()
        case .left:
            return closeExamine() || model.leave()
        case .escape:
            return closeExamine()
        case .find:
            model.isFinding = true
            findFocused = true
            return true
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([session.current?.url ?? session.folder])
            return true
        case .copyPath:
            if let item = session.current { copyPath(item) }
            return true
        }
    }

    private func moving(_ action: () -> Bool) -> Bool {
        withAnimation(Theme.Motion.fast) { action() }
    }

    private func copyPath(_ item: FileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
        model.show(notice: "Copied the path of \(item.name)")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { if canDecide && !isInspecting { track($0.translation.width) } }
            .onEnded { if !isInspecting { release($0.translation.width) } }
    }

    /// Follows the finger, with a haptic tick on the trackpad as the card crosses the decide line.
    private func track(_ offset: CGFloat) {
        guard model.stack === stack else { return }
        dragOffset = offset
        let past = abs(offset) >= Theme.Swipe.threshold
        guard past != pastThreshold else { return }
        pastThreshold = past
        if past { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func release(_ offset: CGFloat) {
        pastThreshold = false
        guard model.stack === stack else { return }
        if offset <= -Theme.Swipe.threshold {
            decide(.keep)
        } else if offset >= Theme.Swipe.threshold {
            decide(.toss)
        } else {
            withAnimation(Theme.Motion.fast) { dragOffset = 0 }
        }
    }

    private func decide(_ decision: Decision) {
        guard canDecide, let item = session.current else { return }
        let start = dragOffset
        let decided = withAnimation(Theme.Motion.base) { model.decide(decision) }
        withAnimation(decided ? nil : Theme.Motion.fast) { dragOffset = 0 }
        pastThreshold = false
        if decided, !reduceMotion, !isInspecting {
            outgoing = Outgoing(item: item, decision: decision, start: start)
        }
    }

    /// Right arrow: opens the folder on the current card. Anything else passes through.
    private func openFolder() -> Bool {
        guard canDecide, let item = session.current, item.isDirectory else { return false }
        dragOffset = 0
        return model.enter(item)
    }

    /// E or Space: the closest look at the current item. Quick Look for anything it can draw,
    /// contents for packages and archives, and a folder opens. Pressed again, it closes.
    private func examine() -> Bool {
        if closeExamine() { return true }
        guard canDecide, let item = session.current else { return false }
        switch kind(of: item) {
        case .folder:
            return openFolder()
        case .package, .archive:
            dragOffset = 0
            isInspecting = true
        case .preview, .info:
            QuickLookPanel.shared.show(item.url, over: screenCardFrame)
        }
        return true
    }

    /// Closes Quick Look or the contents view. Returns false when neither was open.
    private func closeExamine() -> Bool {
        if QuickLookPanel.shared.isVisible {
            QuickLookPanel.shared.close()
            return true
        }
        guard isInspecting else { return false }
        isInspecting = false
        return true
    }

    private func insertion(_ travel: CGFloat) -> AnyTransition {
        guard !reduceMotion, let undone = model.undoneDecision else { return .opacity }
        return .offset(x: undone == .keep ? -travel : travel).combined(with: .opacity)
    }

    /// Asks Quick Look which nearby files it can draw, and warms the thumbnail cache so the
    /// next card can fly off sharp.
    private func prepare() async {
        let cache = ThumbnailCache.shared
        let nearby = [session.current].compactMap { $0 } + session.upcoming(2)
        for item in nearby where item.quickKind == .archive {
            if await ArchiveCache.listing(for: item.url) == nil { unreadableArchives.insert(item.url) }
        }
        for item in nearby where drawable[item.url] == nil && !item.isDirectory {
            drawable[item.url] = await cache.canPreview(item.url, scale: scale)
        }
        for item in nearby {
            await cache.load(item.url, side: CardThumb.side, scale: scale)
        }
    }
}

enum CardThumb {
    static let side: CGFloat = 320
}

extension FolderScanner.Order {
    var title: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .largest: "Largest first"
        case .name: "Name"
        case .kind: "Kind"
        }
    }
}

/// How much of this folder is decided, as a small ring.
private struct ProgressRing: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.rowOnPath, lineWidth: Theme.Size.ringLine)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                // Neutral: progress counts saves and ditches alike.
                .stroke(Theme.secondary, style: StrokeStyle(lineWidth: Theme.Size.ringLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Theme.Size.ring, height: Theme.Size.ring)
        .animation(Theme.Motion.base, value: done)
        .accessibilityLabel("\(done) of \(total) sorted")
    }
}

private struct Outgoing: Identifiable {
    let id = UUID()
    let item: FileItem
    let decision: Decision
    let start: CGFloat
}

/// The live card: a real preview that follows your finger. What it shows depends on the kind of file.
private struct LiveCard: View {
    let item: FileItem
    let kind: CardKind
    let facts: FileFacts?
    let isInspecting: Bool
    let offset: CGFloat
    /// Decisions already made inside this folder, if you have been in.
    let decisions: [FileItem.ID: Decision]
    let open: () -> Void
    /// The sift's order, so the folder card lists files the way they come once inside.
    let order: FolderScanner.Order
    let openAt: (URL) -> Void
    let examine: () -> Void

    @State private var showThumbnail = true

    var body: some View {
        CardSurface {
            switch kind {
            case .folder:
                FolderPreview(url: item.url, order: order, decisions: decisions, open: open, openAt: openAt)
            case .preview:
                QuickLookPreview(url: item.url)
                    .padding(Theme.Space.s)
                    // The thumbnail covers the moment Quick Look takes to draw, so the card is never blank.
                    .overlay {
                        if showThumbnail {
                            FileThumbnail(url: item.url, side: CardThumb.side)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Theme.card)
                                .transition(.opacity)
                        }
                    }
                    .task {
                        try? await Task.sleep(for: .milliseconds(450))
                        withAnimation(Theme.Motion.fast) { showThumbnail = false }
                    }
            case .info:
                InfoCard(item: item, facts: facts)
            case .package, .archive:
                if isInspecting {
                    ContentsView(item: item, kind: kind, close: examine)
                } else {
                    ContentsCard(item: item, kind: kind, facts: facts, show: examine)
                }
            }
        }
        .overlay(alignment: offset < 0 ? .topTrailing : .topLeading) {
            if offset != 0 {
                DecisionStamp(decision: offset < 0 ? .keep : .toss)
                    .opacity(min(1, abs(offset) / Theme.Swipe.threshold))
                    .padding(Theme.Space.m)
            }
        }
        .offset(x: offset)
    }
}

/// The edge of a card waiting underneath the live one.
private struct BackCard: View {
    let item: FileItem
    let depth: Int

    var body: some View {
        CardSurface {
            Color.clear
        }
        .scaleEffect(1 - CGFloat(depth) * 0.04, anchor: .bottom)
        .offset(y: CGFloat(depth) * Theme.Size.backCardStep)
        .allowsHitTesting(false)
    }
}

/// A decided card shrinking into its tray.
private struct OutgoingCard: View {
    let outgoing: Outgoing
    let travel: CGFloat
    let onFinished: () -> Void
    @State private var gone = false

    var body: some View {
        let direction: CGFloat = outgoing.decision == .keep ? -1 : 1
        CardSurface {
            FileThumbnail(url: outgoing.item.url, side: CardThumb.side)
        }
        .overlay(alignment: direction < 0 ? .topTrailing : .topLeading) {
            DecisionStamp(decision: outgoing.decision).padding(Theme.Space.m)
        }
        .scaleEffect(gone ? 0.16 : 1)
        .offset(x: gone ? direction * travel : outgoing.start)
        .opacity(gone ? 0 : 1)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(Theme.Motion.base) { gone = true } completion: { onFinished() }
        }
    }
}

/// A reminder that you are inside a folder you ditched, so everything here goes with it.
/// It takes the key hint's place rather than adding a line.
private struct TossedFolderBanner: View {
    let folder: FileItem
    let keepFolder: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "trash")
                .foregroundStyle(Theme.toss)
            Text("You ditched \(folder.name). Everything in it goes to the Bin unless you save the folder.")
                .font(.callout)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.s)
            Button("Save folder", action: keepFolder)
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.notice, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// A short message in the card's place when a folder has nothing left to decide.
private struct StatusPanel: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        GlassPanel {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: Theme.Symbol.status, weight: .light))
                    .foregroundStyle(Theme.secondary)
                Text(title)
                    .font(Theme.Font.sheetTitle)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text(message)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.actionFill)
                    .controlSize(.large)
            }
            .frame(maxWidth: Theme.Size.readingWidth)
        }
    }
}
