import Foundation
import Testing
@testable import SiftCore

/// Moves "trashed" files into a scratch folder so tests never touch the real Trash.
struct FolderTrasher: Trasher {
    let bin: URL
    var failing: Set<String> = []

    func trash(_ url: URL) throws -> URL? {
        if failing.contains(url.lastPathComponent) { throw CocoaError(.fileWriteNoPermission) }
        let destination = bin.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func restore(_ trashURL: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashURL, to: original)
    }
}

/// Creates a scratch folder. Names ending in "/" become subfolders.
func makeFolder(_ names: [String]) throws -> URL {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("sift-tests-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in names {
        let url = dir.appendingPathComponent(name)
        if name.hasSuffix("/") {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try Data("x".utf8).write(to: url)
        }
    }
    return dir
}

func names(in folder: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
}

@Suite struct FolderScannerTests {
    @Test func skipsHiddenFilesAndMarksFolders() throws {
        let dir = try makeFolder(["a.txt", ".DS_Store", "Photos/", "b.pdf"])
        let items = try FolderScanner.scan(dir)
        #expect(Set(items.map(\.name)) == ["a.txt", "Photos", "b.pdf"])
        let photos = try #require(items.first { $0.name == "Photos" })
        #expect(photos.isDirectory)
        #expect(photos.size == nil)
        #expect(items.first { $0.name == "a.txt" }?.size == 1)
    }

    @Test func appBundlesArePackagesNotFolders() throws {
        let dir = try makeFolder(["Tool.app/", "Tool.app/Contents/", "Plain/"])
        let items = try FolderScanner.scan(dir)
        let app = try #require(items.first { $0.name == "Tool.app" })
        #expect(app.isPackage)
        #expect(!app.isDirectory)
        let plain = try #require(items.first { $0.name == "Plain" })
        #expect(plain.isDirectory)
        #expect(!plain.isPackage)
    }

    @Test func sortsNewestFirstThenByName() {
        let now = Date()
        let items = [
            FileItem(url: URL(fileURLWithPath: "/x/old.txt"), added: now.addingTimeInterval(-100)),
            FileItem(url: URL(fileURLWithPath: "/x/b.txt"), added: now),
            FileItem(url: URL(fileURLWithPath: "/x/a.txt"), added: now),
            FileItem(url: URL(fileURLWithPath: "/x/fallback.txt"), modified: now.addingTimeInterval(-50)),
        ]
        #expect(FolderScanner.sorted(items).map(\.name) == ["a.txt", "b.txt", "fallback.txt", "old.txt"])
    }

    @Test func missingFolderIsUnreadable() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("sift-missing-\(UUID())")
        do {
            _ = try FolderScanner.scan(missing)
            Issue.record("expected an error")
        } catch {
            guard case .unreadable = error else { Issue.record("got \(error)"); return }
        }
    }

    @Test func lockedFolderIsAccessDenied() throws {
        let dir = try makeFolder(["a.txt"])
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        do {
            _ = try FolderScanner.scan(dir)
            Issue.record("expected an error")
        } catch {
            #expect(error == .accessDenied)
        }
    }
}

@MainActor @Suite struct SiftSessionTests {
    func session(_ names: [String]) -> SiftSession {
        SiftSession(
            folder: URL(fileURLWithPath: "/x"),
            items: names.map { FileItem(url: URL(fileURLWithPath: "/x/\($0)")) })
    }

    @Test func decisionsAdvanceAndCount() {
        let s = session(["a", "b", "c"])
        s.decide(.keep)
        s.decide(.toss)
        #expect(s.kept.map(\.name) == ["a"])
        #expect(s.tossed.map(\.name) == ["b"])
        #expect(s.remainingCount == 1)
        #expect(s.current?.name == "c")
        #expect(s.upcoming(3).isEmpty)
    }

    @Test func undoStepsBackAndClearsTheDecision() {
        let s = session(["a", "b"])
        #expect(s.undo() == nil)
        s.decide(.keep)
        s.decide(.toss)
        #expect(s.undo()?.name == "b")
        #expect(s.current?.name == "b")
        #expect(s.tossed.isEmpty)
        #expect(s.kept.map(\.name) == ["a"])
    }

    @Test func finishesAfterTheLastItemAndIgnoresExtraDecisions() {
        let s = session(["a"])
        s.decide(.toss)
        #expect(s.isFinished)
        #expect(s.current == nil)
        s.decide(.keep)
        #expect(s.tossed.map(\.name) == ["a"])
    }

    @Test func changeRescuesATossedFileButNotAnUndecidedOne() {
        let s = session(["a", "b"])
        s.decide(.toss)
        s.change(URL(fileURLWithPath: "/x/a"), to: .keep)
        s.change(URL(fileURLWithPath: "/x/b"), to: .toss)
        #expect(s.kept.map(\.name) == ["a"])
        #expect(s.tossed.isEmpty)
    }

    @Test func moveTossedToTrashMovesOnlyTossedFiles() async throws {
        let dir = try makeFolder(["keep.txt", "toss1.txt", "toss2.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        while let item = s.current { s.decide(item.name == "keep.txt" ? .keep : .toss) }

        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(try names(in: dir) == ["keep.txt"])
        #expect(try names(in: bin) == ["toss1.txt", "toss2.txt"])
        #expect(s.trashed.count == 2)
        #expect(s.failed.isEmpty)

        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))
        #expect(s.trashed.count == 2)
    }

    @Test func failuresStayPutAndAreReported() async throws {
        let dir = try makeFolder(["ok.txt", "stuck.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        while s.current != nil { s.decide(.toss) }

        await s.moveTossedToTrash(using: FolderTrasher(bin: bin, failing: ["stuck.txt"]))

        #expect(try names(in: dir) == ["stuck.txt"])
        #expect(s.trashed.map(\.item.name) == ["ok.txt"])
        #expect(s.failed.map(\.item.name) == ["stuck.txt"])
    }

    @Test func putBackRestoresTheFileAndMarksItKept() async throws {
        let dir = try makeFolder(["oops.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)
        await s.moveTossedToTrash(using: trasher)

        try s.putBack(try #require(s.trashed.first), using: trasher)

        #expect(try names(in: dir) == ["oops.txt"])
        #expect(s.trashed.isEmpty)
        #expect(s.kept.map(\.name) == ["oops.txt"])
    }
}
