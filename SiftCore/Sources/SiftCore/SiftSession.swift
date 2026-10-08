import Foundation
import Observation

public enum Decision: String, Sendable, Equatable, Codable {
    case keep, toss
}

public struct TrashedFile: Identifiable, Hashable, Sendable {
    public let item: FileItem
    /// Where the file now sits in the Trash, used to put it back. Nil when macOS did not report it.
    public let trashURL: URL?
    public var id: URL { item.id }
}

public struct FailedFile: Identifiable, Hashable, Sendable {
    public let item: FileItem
    public let reason: String
    public var id: URL { item.id }
}

public enum PutBackError: Error, Equatable, Sendable {
    case notInTrash
}

/// Numbers every decision across all folders, so Undo and the trays know which came last.
@MainActor
enum DecisionClock {
    private static var now = 0
    static func tick() -> Int {
        now += 1
        return now
    }
}

/// One folder's items, a highlight that can move freely among them, and the decisions made.
/// Decisions are only recorded here; nothing on disk changes until `moveTossedToTrash`.
@MainActor @Observable
public final class SiftSession {
    public let folder: URL
    public private(set) var items: [FileItem]
    /// Index of the highlighted item. Equals `items.count` once the last open item is decided.
    public private(set) var cursor = 0
    public private(set) var decisions: [FileItem.ID: Decision] = [:]
    public private(set) var trashed: [TrashedFile] = []
    public private(set) var failed: [FailedFile] = []
    /// When each decision was made, by `DecisionClock`, so trays list files in the order decided.
    public private(set) var decidedAt: [FileItem.ID: Int] = [:]
    /// Files put back under a different name or into a folder that came back renamed.
    public private(set) var restored: [FileItem.ID: URL] = [:]

    /// One Undo: a single decision, or a whole "decide the rest".
    private struct Step {
        /// Each item's decision, and when it was made, before this step.
        let changes: [(id: FileItem.ID, previous: Decision?, previousTime: Int?)]
        /// The item highlighted when the step was taken, highlighted again on Undo.
        let focus: FileItem.ID
        /// From `DecisionClock`, so the most recent step across folders can be found.
        let number: Int
    }
    private var history: [Step] = []

    public init(folder: URL, items: [FileItem]) {
        self.folder = folder
        self.items = items
    }

    public var current: FileItem? { items.indices.contains(cursor) ? items[cursor] : nil }
    public var isFinished: Bool { remainingCount == 0 }
    public var canUndo: Bool { !history.isEmpty }
    public var decidedCount: Int { items.count - remainingCount }
    public var remainingCount: Int { items.count { decisions[$0.id] == nil } }
    public var kept: [FileItem] { items.filter { decisions[$0.id] == .keep } }
    public var tossed: [FileItem] { items.filter { decisions[$0.id] == .toss } }
    /// The decision Undo would take back.
    public var lastDecision: Decision? { history.last.flatMap { $0.changes.first }.flatMap { decisions[$0.id] } }
    /// How many items Undo would take back.
    public var lastStepSize: Int { history.last?.changes.count ?? 0 }
    /// When the step Undo would take back was made, to compare folders.
    public var lastStepNumber: Int? { history.last?.number }

    /// The next few items deciding will move to, for the card stack behind the current one.
    /// Follows the same path as `decide`: open items after the highlight, wrapping round.
    public func upcoming(_ count: Int) -> [FileItem] {
        let start = min(cursor + 1, items.count)
        let order = Array(items.indices.dropFirst(start)) + Array(items.indices.prefix(min(cursor, items.count)))
        return Array(order.lazy.map { self.items[$0] }.filter { self.decisions[$0.id] == nil }.prefix(count))
    }

    // MARK: Deciding

    /// Decides the highlighted item, then moves on to the next item without a decision,
    /// wrapping round to any skipped earlier. Deciding a decided item changes it.
    public func decide(_ decision: Decision) {
        guard let item = current else { return }
        let number = DecisionClock.tick()
        history.append(Step(changes: [(item.id, decisions[item.id], decidedAt[item.id])], focus: item.id, number: number))
        decisions[item.id] = decision
        decidedAt[item.id] = number
        cursor = nextUndecided(after: cursor) ?? items.count
    }

    /// Decides every item still without a decision, as a single Undo. Items `skip` picks out
    /// stay undecided. Returns how many were decided.
    @discardableResult
    public func decideRest(_ decision: Decision, skipping skip: (FileItem) -> Bool = { _ in false }) -> Int {
        let targets = items.filter { decisions[$0.id] == nil && !skip($0) }
        guard let first = targets.first else { return 0 }
        let number = DecisionClock.tick()
        history.append(Step(changes: targets.map { ($0.id, nil, nil) }, focus: current?.id ?? first.id, number: number))
        for item in targets {
            decisions[item.id] = decision
            decidedAt[item.id] = number
        }
        cursor = nextUndecided(after: cursor) ?? items.count
        return targets.count
    }

    /// How many items "decide the rest" would decide.
    public func restCount(skipping skip: (FileItem) -> Bool = { _ in false }) -> Int {
        items.count { decisions[$0.id] == nil && !skip($0) }
    }

    /// Takes back the most recent decision, or a whole "decide the rest", and highlights
    /// that item again. Returns the item.
    @discardableResult
    public func undo() -> FileItem? {
        guard let step = history.popLast() else { return nil }
        for change in step.changes {
            decisions[change.id] = change.previous
            decidedAt[change.id] = change.previousTime
        }
        cursor = items.firstIndex { $0.id == step.focus } ?? min(cursor, items.count)
        return current
    }

    /// Changes a decision already made, e.g. rescuing a file from the tossed list before confirming.
    public func change(_ id: FileItem.ID, to decision: Decision) {
        guard decisions[id] != nil else { return }
        decisions[id] = decision
        decidedAt[id] = DecisionClock.tick()
    }

    // MARK: Moving the highlight

    /// Moves the highlight up or down without deciding. Returns false when it cannot move.
    @discardableResult
    public func move(by offset: Int) -> Bool {
        guard !items.isEmpty, !(cursor >= items.count && offset > 0) else { return false }
        let target = min(max(cursor + offset, 0), items.count - 1)
        guard target != cursor else { return false }
        cursor = target
        return true
    }

    /// Jumps to the next (or previous) item with no decision. Returns false when there is none.
    @discardableResult
    public func moveToUndecided(forward: Bool) -> Bool {
        let order = forward
            ? Array(items.indices.dropFirst(min(cursor + 1, items.count)))
            : Array(items.indices.prefix(min(cursor, items.count)).reversed())
        guard let index = order.first(where: { decisions[items[$0].id] == nil }) else { return false }
        cursor = index
        return true
    }

    /// Jumps to the first or last item. Returns false when already there.
    @discardableResult
    public func moveToEdge(first: Bool) -> Bool {
        guard !items.isEmpty else { return false }
        let target = first ? 0 : items.count - 1
        guard target != cursor else { return false }
        cursor = target
        return true
    }

    /// Highlights one item, e.g. a row clicked in the column view.
    public func select(_ id: FileItem.ID) {
        if let index = items.firstIndex(where: { $0.id == id }) { cursor = index }
    }

    private func nextUndecided(after index: Int) -> Int? {
        let start = min(max(index + 1, 0), items.count)
        let order = Array(items.indices.dropFirst(start)) + Array(items.indices.prefix(start))
        return order.first { decisions[items[$0].id] == nil }
    }

    // MARK: Keeping up with the folder

    /// Puts the items in a new order, keeping the highlighted item highlighted.
    public func reorder(_ order: FolderScanner.Order) {
        let focus = current?.id
        items = FolderScanner.sorted(items, by: order)
        if let focus { cursor = items.firstIndex { $0.id == focus } ?? 0 }
    }

    /// Brings the list up to date with the folder on disk. Items that have gone drop out with
    /// their decisions; new ones join at the end. Returns how many joined and how many left.
    /// A decided item keeps the snapshot the user saw, so if the file is replaced or edited
    /// afterwards, the check before trashing still notices and leaves it alone.
    @discardableResult
    public func sync(with scanned: [FileItem]) -> (added: Int, removed: Int) {
        let fresh = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stillHere = items.compactMap { old in fresh[old.id].map { decisions[old.id] == nil ? $0 : old } }
        let known = Set(items.map(\.id))
        let added = scanned.filter { !known.contains($0.id) }
        let removed = known.subtracting(fresh.keys)
        guard !added.isEmpty || !removed.isEmpty || stillHere != items else { return (0, 0) }

        let focus = current?.id
        // How many items above the highlight stay, so the highlight can carry on from there.
        let keptAbove = items.prefix(cursor).count { fresh[$0.id] != nil }
        items = stillHere + added
        for id in removed {
            decisions[id] = nil
            decidedAt[id] = nil
        }
        history = history.compactMap { step in
            let changes = step.changes.filter { !removed.contains($0.id) }
            guard let first = changes.first else { return nil }
            return Step(changes: changes, focus: removed.contains(step.focus) ? first.id : step.focus, number: step.number)
        }
        if let focus, let index = items.firstIndex(where: { $0.id == focus }) {
            cursor = index
        } else {
            // The highlighted item went, or everything was done: go to the next open item.
            cursor = nextUndecided(after: keptAbove - 1) ?? items.count
        }
        return (added.count, removed.count)
    }

    // MARK: Memory between sifts

    /// Today's decisions, keyed so a later sift can match them to the same files. Files that
    /// already went to the Trash are left out, so one put back later starts fresh.
    public var memory: [String: Decision] {
        let gone = Set(trashed.map(\.id))
        return Dictionary(
            items.compactMap { item in
                gone.contains(item.id) ? nil : decisions[item.id].map { (item.memoryKey, $0) }
            },
            uniquingKeysWith: { first, _ in first })
    }

    /// Applies decisions remembered from an earlier sift to the files that are still the same
    /// files, then highlights the first item without a decision.
    public func recall(_ memory: [String: Decision]) {
        guard !memory.isEmpty else { return }
        for item in items where decisions[item.id] == nil {
            guard let decision = item.remembered(in: memory) else { continue }
            // A folder or package can change inside after it was ditched, so it is shown again
            // rather than ditched unseen.
            if decision == .toss && (item.isDirectory || item.isPackage) { continue }
            decisions[item.id] = decision
        }
        cursor = nextUndecided(after: -1) ?? items.count
    }

    // MARK: The Trash

    /// Tossed files that are not in the Trash yet.
    public var pendingTrash: [FileItem] {
        let alreadyTrashed = Set(trashed.map(\.id))
        return tossed.filter { !alreadyTrashed.contains($0.id) }
    }

    /// Moves every tossed file that is not already in the Trash. Files that fail stay put and are listed in `failed`.
    public func moveTossedToTrash(using trasher: some Trasher) async {
        await moveToTrash(pendingTrash, using: trasher)
    }

    /// Moves exactly `batch` to the Trash, a list fixed before anything moves. Each file is
    /// checked first, and anything replaced, edited or gone since the scan is left alone.
    /// `progress` hears how many have been handled so far.
    public func moveToTrash(
        _ batch: [FileItem], using trasher: some Trasher, progress: (Int) -> Void = { _ in }
    ) async {
        var failures: [FailedFile] = []
        for (index, item) in batch.enumerated() {
            let outcome = await Task.detached { Self.trash([item], with: trasher) }.value
            // Recorded straight away, so memory is right even if Sift quits partway.
            trashed += outcome.0
            // Whatever reached the Trash counts as tossed, so the trays always match the disk.
            for file in outcome.0 { decisions[file.id] = .toss }
            failures += outcome.1
            progress(index + 1)
        }
        failed = failures
    }

    nonisolated static func trash(_ items: [FileItem], with trasher: some Trasher) -> ([TrashedFile], [FailedFile]) {
        var done: [TrashedFile] = []
        var failures: [FailedFile] = []
        for item in items {
            if let change = changeSinceScan(item) {
                failures.append(FailedFile(item: item, reason: change))
                continue
            }
            do {
                done.append(TrashedFile(item: item, trashURL: try trasher.trash(item.url)))
            } catch {
                failures.append(FailedFile(item: item, reason: plainReason(error)))
            }
        }
        return (done, failures)
    }

    /// Why a file must be left alone because it is not the one the user saw, or nil when it is unchanged.
    nonisolated static func changeSinceScan(_ item: FileItem) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path) else {
            return "It's no longer there."
        }
        if let expected = item.fileNumber,
           let now = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value, now != expected {
            return "A different file has this name now, so Sift left it alone."
        }
        // A folder changes whenever Sift trashes something inside it first, so only files are checked for edits.
        if !item.isDirectory, !item.isPackage, let expected = item.modified,
           let now = attributes[.modificationDate] as? Date, abs(now.timeIntervalSince(expected)) > 1 {
            return "It changed after you sifted it, so Sift left it alone."
        }
        return nil
    }

    nonisolated static func plainReason(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return "macOS wouldn't move it to the Bin." }
        switch error.code {
        case CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue:
            return "Sift isn't allowed to move it. It may be locked."
        case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
            return "It's no longer there."
        case CocoaError.fileWriteVolumeReadOnly.rawValue:
            return "It's on a disk that can't be changed."
        default:
            return "macOS wouldn't move it to the Bin."
        }
    }

    /// Moves a trashed file back: to its old name if that is free, otherwise "name 2" beside it,
    /// recreating its folder if that has gone. `home` replaces the old place, e.g. inside a
    /// folder that came back under a new name. Marks it kept and returns where it landed.
    @discardableResult
    public func putBack(_ file: TrashedFile, using trasher: some Trasher, home: URL? = nil) throws -> URL {
        guard let trashURL = file.trashURL else { throw PutBackError.notInTrash }
        let home = home ?? file.item.url
        try FileManager.default.createDirectory(
            at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = Self.freeURL(near: home)
        try trasher.restore(trashURL, to: destination)
        trashed.removeAll { $0.id == file.id }
        decisions[file.id] = .keep
        decidedAt[file.id] = DecisionClock.tick()
        if destination != file.item.url { restored[file.id] = destination }
        return destination
    }

    /// `url` if nothing is there, otherwise the first free "name 2", "name 3" beside it.
    nonisolated static func freeURL(near url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for number in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
