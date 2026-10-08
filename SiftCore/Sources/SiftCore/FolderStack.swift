import Foundation
import Observation

/// A tossed folder holding files you chose to keep.
public struct KeptInsideTossed: Identifiable, Sendable {
    public let folder: FileItem
    public let kept: [FileItem]
    public var id: URL { folder.id }
}

/// A sift that can step into subfolders. Each folder keeps its own decisions, so stepping
/// back out and in again resumes where you left off.
@MainActor @Observable
public final class FolderStack {
    /// From the folder you started in down to the one you are sifting now.
    public private(set) var path: [SiftSession]
    /// Every folder visited so far, the most recently active last.
    public private(set) var visited: [SiftSession]
    /// Remembered decisions for a folder, applied when you first step into it.
    public var recall: ((URL) -> [String: Decision])?
    /// The order each newly opened folder is sorted in.
    public var order: FolderScanner.Order = .newest

    public init(root: SiftSession) {
        path = [root]
        visited = [root]
    }

    /// Every visited folder's decisions, ready to remember.
    public var memories: [(folder: URL, memory: [String: Decision])] {
        visited.map { ($0.folder, $0.memory) }
    }

    /// The folder holding the most recent step Undo can take back, wherever it was made.
    private var undoSession: SiftSession? {
        visited.filter(\.canUndo).max { ($0.lastStepNumber ?? 0) < ($1.lastStepNumber ?? 0) }
    }

    /// How many items Undo would take back.
    public var lastStepSize: Int { undoSession?.lastStepSize ?? 0 }

    public var root: SiftSession { path[0] }
    public var current: SiftSession { path[path.count - 1] }
    public var canLeave: Bool { path.count > 1 }

    /// Saved and ditched items across every folder, in the order they were decided.
    public var kept: [FileItem] { inDecisionOrder(visited.flatMap(\.kept)) }
    public var tossed: [FileItem] { inDecisionOrder(visited.flatMap(\.tossed)) }
    public var trashed: [TrashedFile] { visited.flatMap(\.trashed) }
    public var failed: [FailedFile] { visited.flatMap(\.failed) }
    public var decidedCount: Int { visited.reduce(0) { $0 + $1.decidedCount } }
    public var canUndo: Bool { undoSession != nil }
    /// The decision Undo would take back, wherever it was made.
    public var lastDecision: Decision? { undoSession?.lastDecision }

    /// Decides the highlighted item in the current folder.
    public func decide(_ decision: Decision) {
        current.decide(decision)
    }

    /// Decides everything still open in the current folder as one Undo. Returns how many.
    @discardableResult
    public func decideRest(_ decision: Decision, skipping skip: (FileItem) -> Bool = { _ in false }) -> Int {
        current.decideRest(decision, skipping: skip)
    }

    /// Re-sorts every visited folder, keeping each highlight where it was.
    public func reorder(_ order: FolderScanner.Order) {
        self.order = order
        for session in visited { session.reorder(order) }
    }

    /// Takes back the most recent decision in any folder, reopening that folder if you have
    /// moved away from it. Returns the item that is highlighted again.
    @discardableResult
    public func undo() -> FileItem? {
        guard let session = undoSession else { return nil }
        show(session)
        return session.undo()
    }

    /// Opens whichever visited folder holds `id` and highlights it.
    public func reveal(_ id: FileItem.ID) {
        guard let session = visited.first(where: { $0.items.contains { $0.id == id } }) else { return }
        show(session)
        session.select(id)
    }

    /// Makes a visited folder current, rebuilding the path down to it from the starting folder.
    func show(_ session: SiftSession) {
        guard session !== current else { return }
        path = visited
            .filter { $0 === session || session.folder.isInside($0.folder) }
            .sorted { $0.folder.pathComponents.count < $1.folder.pathComponents.count }
        markActive(session)
    }

    /// Steps into a folder, reusing earlier decisions there if you have been in before.
    public func enter(_ folder: FileItem) throws(ScanError) {
        guard folder.isDirectory else { return }
        if hasVisited(folder) {
            enter(folder, items: [])
        } else {
            enter(folder, items: try FolderScanner.scan(folder.url, order: order))
        }
    }

    /// Steps into a folder whose items were scanned elsewhere, e.g. off the main thread.
    /// A folder visited before keeps its own items and decisions.
    public func enter(_ folder: FileItem, items: [FileItem]) {
        guard folder.isDirectory else { return }
        let session: SiftSession
        if let earlier = visited.first(where: { $0.folder == folder.url }) {
            session = earlier
        } else {
            session = SiftSession(folder: folder.url, items: items)
            if let recall { session.recall(recall(folder.url)) }
        }
        path.append(session)
        markActive(session)
    }

    /// Whether `folder` already has a sift of its own, so stepping in needs no scan.
    public func hasVisited(_ folder: FileItem) -> Bool {
        visited.contains { $0.folder == folder.url }
    }

    /// Steps back up one level.
    public func leave() {
        guard canLeave else { return }
        path.removeLast()
        markActive(current)
    }

    /// Steps back up to `session`, which must be on the current path.
    public func leave(to session: SiftSession) {
        guard let index = path.firstIndex(where: { $0 === session }) else { return }
        path.removeSubrange((index + 1)...)
        markActive(current)
    }

    /// Brings a visited folder up to date with the disk. A subfolder that has gone takes its own
    /// sift with it, so nothing inside it is counted, listed or sent to the Trash.
    @discardableResult
    public func sync(_ session: SiftSession, with scanned: [FileItem]) -> (added: Int, removed: Int) {
        let foldersBefore = Set(session.items.filter(\.isDirectory).map(\.url))
        let result = session.sync(with: scanned)
        let gone = foldersBefore.subtracting(session.items.map(\.url))
        guard !gone.isEmpty else { return result }
        let isGone = { (other: SiftSession) in gone.contains { other.folder == $0 || other.folder.isInside($0) } }
        if path.contains(where: isGone) { path = Array(path.prefix { !isGone($0) }) }
        visited.removeAll(where: isGone)
        return result
    }

    /// Changes a decision in whichever folder made it.
    public func change(_ id: FileItem.ID, to decision: Decision) {
        visited.first { $0.decisions[id] != nil }?.change(id, to: decision)
    }

    /// Moves every tossed file to the Trash, deepest folders first, so a tossed folder
    /// never carries a separately tossed file inside it. The whole list is fixed before
    /// anything moves, so nothing decided after the confirmation can join it.
    /// `progress` hears how many have been handled out of the whole list.
    public func moveTossedToTrash(
        using trasher: some Trasher, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async {
        let plan = visited
            .sorted { $0.folder.pathComponents.count > $1.folder.pathComponents.count }
            .map { (session: $0, batch: $0.pendingTrash) }
        let total = plan.reduce(0) { $0 + $1.batch.count }
        var finished = 0
        for step in plan where !step.batch.isEmpty {
            let before = finished
            await step.session.moveToTrash(step.batch, using: trasher) { progress(before + $0, total) }
            finished += step.batch.count
        }
    }

    /// Space the tossed files take up, for "Frees 1.2 GB". Folders are not measured.
    public var tossedSize: Int64 { tossed.reduce(0) { $0 + ($1.size ?? 0) } }
    public var trashedSize: Int64 { trashed.reduce(0) { $0 + ($1.item.size ?? 0) } }

    /// Files you kept that sit inside a folder you tossed. They would go to the Trash with the folder.
    public var keptInsideTossedFolders: [KeptInsideTossed] {
        let kept = self.kept
        return tossed.filter(\.isDirectory).compactMap { folder in
            let inside = kept.filter { $0.url.isInside(folder.url) }
            return inside.isEmpty ? nil : KeptInsideTossed(folder: folder, kept: inside)
        }
    }

    /// Kept files still in place, leaving out any that went to the Trash inside a tossed folder.
    public var keptInPlace: [FileItem] {
        let trashedFolders = trashed.filter(\.item.isDirectory).map(\.item.url)
        return kept.filter { item in !trashedFolders.contains { item.url.isInside($0) } }
    }

    /// Failures that really stayed put. A file inside a folder that reached the Trash went with it.
    public var failedInPlace: [FailedFile] {
        let trashedFolders = trashed.filter(\.item.isDirectory).map(\.item.url)
        return failed.filter { file in !trashedFolders.contains { file.item.url.isInside($0) } }
    }

    /// Puts one file back and returns where it landed (its old name, or "name 2" beside it).
    /// If a folder it lived in also went to the Trash, that folder comes back first and the
    /// file goes back inside it, even when the folder had to take a new name.
    @discardableResult
    public func putBack(_ file: TrashedFile, using trasher: some Trasher) throws -> URL {
        guard let session = visited.first(where: { $0.trashed.contains { $0.id == file.id } }) else {
            throw PutBackError.notInTrash
        }
        // The nearest folder above it that is in the Bin comes back first, and it brings back
        // its own folders the same way, so every level returns in one piece. If one can't come
        // back (say Finder put it back already), the file still goes home on its own.
        let folderAbove = trashed
            .filter { $0.item.isDirectory && $0.trashURL != nil && file.item.url.isInside($0.item.url) }
            .max { $0.item.url.pathComponents.count < $1.item.url.pathComponents.count }
        if let folderAbove { _ = try? putBack(folderAbove, using: trasher) }
        return try session.putBack(file, using: trasher, home: home(for: file.item.url))
    }

    /// Where a file now belongs: its old place, or inside the new name of a folder above it
    /// that came back renamed.
    private func home(for url: URL) -> URL {
        let renamedFolders = visited.flatMap { session in
            session.restored.compactMap { id, landed in
                session.items.first { $0.id == id && $0.isDirectory }.map { (old: $0.url, new: landed) }
            }
        }
        guard let folder = renamedFolders
            .filter({ url.isInside($0.old) })
            .max(by: { $0.old.pathComponents.count < $1.old.pathComponents.count })
        else { return url }
        return url.pathComponents.dropFirst(folder.old.pathComponents.count)
            .reduce(folder.new) { $0.appendingPathComponent($1) }
    }

    /// Where a put-back file is now, when it came back under a different name.
    public func restoredURL(of id: FileItem.ID) -> URL? {
        visited.lazy.compactMap { $0.restored[id] }.first
    }

    /// Where an item is now: where it was put back, inside a folder that came back renamed, or
    /// where it always was.
    public func currentURL(of item: FileItem) -> URL {
        restoredURL(of: item.id) ?? home(for: item.url)
    }

    /// Puts back everything from this sift. Returns the names that couldn't come back.
    /// `landed` hears where each file went.
    @discardableResult
    public func putBackAll(
        using trasher: some Trasher, landed: (TrashedFile, URL) -> Void = { _, _ in }
    ) -> [String] {
        // Folders first, so files that lived inside them have somewhere to return to.
        let files = trashed.sorted { $0.item.url.pathComponents.count < $1.item.url.pathComponents.count }
        var stuck: [String] = []
        for file in files {
            // A file whose folder came back first may already be home.
            guard trashed.contains(where: { $0.id == file.id }) else { continue }
            do { landed(file, try putBack(file, using: trasher)) } catch { stuck.append(file.item.name) }
        }
        return stuck
    }

    /// Ditched folders holding files saved in an earlier sift, at any depth, in folders not
    /// opened this sift. They would go to the Bin with the folder, so the confirm sheet warns
    /// about them too. A saved file counts even if it was edited since. `remembered` gives every
    /// remembered folder at or inside a folder. Reads the disk, so call it once when the sheet
    /// opens, not from a view's body.
    public func rememberedKeptInsideTossedFolders(
        remembered: (URL) -> [(folder: URL, memory: [String: Decision])]
    ) -> [KeptInsideTossed] {
        let opened = Set(visited.map(\.folder.comparablePath))
        return tossed.filter(\.isDirectory).compactMap { ditched in
            let kept = remembered(ditched.url)
                .filter { !opened.contains($0.folder.comparablePath) && $0.memory.values.contains(.keep) }
                .flatMap { entry in
                    ((try? FolderScanner.scan(entry.folder)) ?? []).filter { $0.wasSaved(in: entry.memory) }
                }
            return kept.isEmpty ? nil : KeptInsideTossed(folder: ditched, kept: kept)
        }
    }

    private func inDecisionOrder(_ items: [FileItem]) -> [FileItem] {
        let order = visited.reduce(into: [FileItem.ID: Int]()) { all, session in
            all.merge(session.decidedAt) { first, _ in first }
        }
        // Decisions recalled from an earlier sift have no time, so they come first, in list order.
        return items.enumerated()
            .sorted { (order[$0.element.id] ?? 0, $0.offset) < (order[$1.element.id] ?? 0, $1.offset) }
            .map(\.element)
    }

    private func markActive(_ session: SiftSession) {
        visited.removeAll { $0 === session }
        visited.append(session)
    }
}
