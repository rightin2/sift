import Foundation
import Testing
@testable import SiftCore

/// The rules that keep Sift from trashing anything the user did not see and confirm.
@MainActor @Suite struct SafetyTests {
    @Test func aFileReplacedAfterTheScanIsLeftAlone() async throws {
        let dir = try makeFolder(["invoice.pdf"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)

        // Someone moves the file away and a new download takes its name.
        let path = dir.appendingPathComponent("invoice.pdf")
        try FileManager.default.removeItem(at: path)
        try Data("a different file".utf8).write(to: path)

        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(try names(in: dir) == ["invoice.pdf"])
        #expect(try names(in: bin).isEmpty)
        #expect(s.trashed.isEmpty)
        #expect(s.failed.count == 1)
    }

    @Test func aFileThatIsGoneIsReportedNotTrashed() async throws {
        let dir = try makeFolder(["old.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("old.txt"))

        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(s.failed.map(\.reason) == ["It's no longer there."])
    }

    @Test func whateverReachesTheTrashCountsAsTossed() async throws {
        let dir = try makeFolder(["a.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)
        let batch = s.pendingTrash
        // A rescue that lands while the batch is already moving.
        s.change(try #require(batch.first).id, to: .keep)

        await s.moveToTrash(batch, using: FolderTrasher(bin: bin))

        #expect(s.tossed.map(\.name) == ["a.txt"])
        #expect(s.kept.isEmpty)
    }

    @Test func keptFilesInsideATossedFolderAreFlaggedAndNotCountedAsKept() async throws {
        let dir = try makeFolder(["Sub/", "Sub/keep-me.txt"])
        let bin = try makeFolder([])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        let sub = try #require(stack.root.current)
        try stack.enter(sub)
        stack.current.decide(.keep)
        stack.leave()
        stack.root.decide(.toss)

        let warning = try #require(stack.keptInsideTossedFolders.first)
        #expect(warning.folder.name == "Sub")
        #expect(warning.kept.map(\.name) == ["keep-me.txt"])

        await stack.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(try names(in: bin) == ["Sub"])
        #expect(stack.kept.map(\.name) == ["keep-me.txt"])
        #expect(stack.keptInPlace.isEmpty)
    }

    @Test func plainReasonsReplaceSystemErrors() {
        #expect(SiftSession.plainReason(CocoaError(.fileWriteNoPermission)) == "Sift isn't allowed to move it. It may be locked.")
        #expect(SiftSession.plainReason(CocoaError(.fileNoSuchFile)) == "It's no longer there.")
        #expect(SiftSession.plainReason(URLError(.badURL)) == "macOS wouldn't move it to the Bin.")
    }
}
