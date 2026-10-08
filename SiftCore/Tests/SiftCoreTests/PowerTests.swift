import Foundation
import Testing
@testable import SiftCore

/// Deciding in bulk, jumping, re-ordering, keeping up with the folder, and memory between sifts.
@MainActor @Suite struct PowerTests {
    func session(_ names: [String], sizes: [Int64]? = nil) -> SiftSession {
        SiftSession(
            folder: URL(fileURLWithPath: "/x"),
            items: names.enumerated().map { index, name in
                FileItem(url: URL(fileURLWithPath: "/x/\(name)"), size: sizes?[index], fileNumber: UInt64(index + 1))
            })
    }

    func item(_ name: String, number: UInt64) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/x/\(name)"), fileNumber: number)
    }

    @Test func decidingTheRestIsOneUndo() {
        let s = session(["a", "b", "c", "d"])
        s.decide(.keep)
        #expect(s.decideRest(.toss) == 3)
        #expect(s.isFinished)
        #expect(s.lastStepSize == 3)

        s.undo()

        #expect(s.kept.map(\.name) == ["a"])
        #expect(s.tossed.isEmpty)
        #expect(s.current?.name == "b")
    }

    @Test func decidingTheRestCanSkipItems() {
        let s = session(["a", "b", "c"])
        #expect(s.restCount(skipping: { $0.name == "b" }) == 2)
        s.decideRest(.toss, skipping: { $0.name == "b" })
        #expect(s.tossed.map(\.name) == ["a", "c"])
        #expect(s.current?.name == "b")
    }

    @Test func jumpingBetweenUndecidedItems() {
        let s = session(["a", "b", "c", "d"])
        s.decide(.keep)
        s.move(by: 2)
        #expect(s.current?.name == "d")
        #expect(s.moveToUndecided(forward: false))
        #expect(s.current?.name == "c")
        #expect(s.moveToUndecided(forward: true))
        #expect(s.current?.name == "d")
        #expect(!s.moveToUndecided(forward: true))
        #expect(s.moveToEdge(first: true))
        #expect(s.current?.name == "a")
        #expect(!s.moveToEdge(first: true))
    }

    @Test func reorderingKeepsTheHighlight() {
        let s = session(["a", "b", "c"], sizes: [1, 3, 2])
        s.select(URL(fileURLWithPath: "/x/c"))
        s.reorder(.largest)
        #expect(s.items.map(\.name) == ["b", "c", "a"])
        #expect(s.current?.name == "c")
    }

    @Test func syncAddsNewFilesAtTheEndAndDropsGoneOnes() {
        let s = session(["a", "b", "c"])
        s.decide(.toss)
        let result = s.sync(with: [item("b", number: 2), item("c", number: 3), item("d", number: 4)])
        #expect(result.added == 1)
        #expect(result.removed == 1)
        #expect(s.items.map(\.name) == ["b", "c", "d"])
        #expect(s.tossed.isEmpty)
        #expect(s.current?.name == "b")
        #expect(!s.canUndo)
    }

    @Test func aNewFileWakesAFinishedFolder() {
        let s = session(["a"])
        s.decide(.keep)
        #expect(s.current == nil)
        s.sync(with: [item("a", number: 1), item("new", number: 9)])
        #expect(s.current?.name == "new")
    }

    @Test func memoryCarriesDecisionsToTheSameFilesOnly() {
        let first = session(["a", "b", "c"])
        first.decide(.keep)
        first.decide(.toss)
        let memory = first.memory
        #expect(memory.count == 2)

        // "b" was replaced by a different file with the same name.
        let later = SiftSession(folder: URL(fileURLWithPath: "/x"), items: [
            item("a", number: 1), item("b", number: 99), item("c", number: 3),
        ])
        later.recall(memory)

        #expect(later.kept.map(\.name) == ["a"])
        #expect(later.tossed.isEmpty)
        #expect(later.current?.name == "b")
    }

    @Test func memoryIsStoredPerFolderAndCanBeForgotten() throws {
        let dir = try makeFolder([])
        let store = SiftMemory(file: dir.appendingPathComponent("memory.json"))
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads")
        let inside = downloads.appendingPathComponent("Projects")
        store.save([(downloads, ["a|1": .keep]), (inside, ["b|2": .toss])])

        #expect(store.load(folder: downloads) == ["a|1": .keep])
        #expect(store.count(folder: inside) == 1)

        store.forget(folder: downloads)

        #expect(store.load(folder: downloads).isEmpty)
        #expect(store.load(folder: inside).isEmpty)
    }

    @Test func putBackUsesAFreeNameWhenTheOldOneIsTaken() async throws {
        let dir = try makeFolder(["notes.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)
        await s.moveTossedToTrash(using: trasher)
        try Data("newer".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let landed = try s.putBack(try #require(s.trashed.first), using: trasher)

        #expect(landed.lastPathComponent == "notes 2.txt")
        #expect(try names(in: dir) == ["notes.txt", "notes 2.txt"])
    }

    @Test func putBackRecreatesAFolderThatHasGone() async throws {
        let dir = try makeFolder(["Sub/", "Sub/a.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let sub = dir.appendingPathComponent("Sub")
        let s = SiftSession(folder: sub, items: try FolderScanner.scan(sub))
        s.decide(.toss)
        await s.moveTossedToTrash(using: trasher)
        try FileManager.default.removeItem(at: sub)

        try s.putBack(try #require(s.trashed.first), using: trasher)

        #expect(try names(in: sub) == ["a.txt"])
    }

    @Test func movingReportsProgressForEveryFile() async throws {
        let dir = try makeFolder(["a.txt", "b.txt", "c.txt"])
        let bin = try makeFolder([])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        stack.decideRest(.toss)
        var reports: [String] = []

        await stack.moveTossedToTrash(using: FolderTrasher(bin: bin)) { done, total in reports.append("\(done)/\(total)") }

        #expect(reports == ["1/3", "2/3", "3/3"])
        #expect(stack.trashed.count == 3)
    }

    @Test func putBackAllBringsEverythingHome() async throws {
        let dir = try makeFolder(["a.txt", "b.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        stack.decideRest(.toss)
        await stack.moveTossedToTrash(using: trasher)

        #expect(stack.putBackAll(using: trasher).isEmpty)
        #expect(try names(in: dir) == ["a.txt", "b.txt"])
        #expect(stack.trashed.isEmpty)
    }

    @Test func browserPlaceholdersAreUnfinishedDownloads() {
        #expect(FileItem(url: URL(fileURLWithPath: "/x/movie.mp4.crdownload")).isUnfinishedDownload)
        #expect(!FileItem(url: URL(fileURLWithPath: "/x/movie.mp4")).isUnfinishedDownload)
    }
}
