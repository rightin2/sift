import Foundation
import Testing
@testable import SiftCore

/// Cases found in the 8 Oct review of the curated plan: keeping up with the folder, Undo across
/// folders, memory, the trays and putting things back.
@MainActor @Suite struct ReviewFixTests {
    func item(_ name: String, in session: SiftSession) throws -> FileItem {
        try #require(session.items.first { $0.name == name })
    }

    /// Highlights `name` and decides it.
    func decide(_ name: String, _ decision: Decision, in stack: FolderStack) throws {
        stack.current.select(try item(name, in: stack.current).id)
        stack.decide(decision)
    }

    // MARK: Keeping up with the folder

    @Test func aFileReplacedBeforeASyncIsStillLeftAlone() async throws {
        let dir = try makeFolder(["invoice.pdf"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)

        let path = dir.appendingPathComponent("invoice.pdf")
        try FileManager.default.removeItem(at: path)
        try Data("a different invoice".utf8).write(to: path)
        s.sync(with: try FolderScanner.scan(dir))
        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(s.trashed.isEmpty)
        #expect(s.failed.count == 1)
        #expect(try names(in: bin).isEmpty)
    }

    @Test func aFileEditedBeforeASyncIsStillLeftAlone() async throws {
        let dir = try makeFolder(["notes.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decide(.toss)

        let path = dir.appendingPathComponent("notes.txt")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: path.path)
        try Data("x".utf8).write(to: dir.appendingPathComponent("new download.txt"))
        s.sync(with: try FolderScanner.scan(dir))
        await s.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(s.trashed.isEmpty)
        #expect(s.failed.map(\.item.name) == ["notes.txt"])
    }

    @Test func syncMovesToTheNextOpenItemWhenTheHighlightGoes() {
        let folder = URL(fileURLWithPath: "/x")
        let all = ["a", "b", "c", "d"].map { FileItem(url: folder.appendingPathComponent($0)) }
        let s = SiftSession(folder: folder, items: all)
        s.select(all[2].id)

        s.sync(with: [all[1], all[3]])

        #expect(s.current?.name == "d")
    }

    @Test func aSubfolderThatGoesTakesItsDecisionsWithIt() throws {
        let dir = try makeFolder(["loose.txt", "Sub/", "Sub/a.txt"])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try stack.enter(try item("Sub", in: stack.root))
        stack.decide(.toss)
        stack.leave()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("Sub"))
        stack.sync(stack.root, with: try FolderScanner.scan(dir))

        #expect(stack.tossed.isEmpty)
        #expect(stack.visited.count == 1)
        #expect(!stack.canUndo)
    }

    // MARK: Undo across folders

    @Test func undoKeepsItsOrderWhenASyncDropsADecision() throws {
        let dir = try makeFolder(["a.txt", "b.txt", "Sub/", "Sub/x.txt"])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try decide("a.txt", .keep, in: stack)
        try stack.enter(try item("Sub", in: stack.root))
        try decide("x.txt", .toss, in: stack)
        stack.leave()
        try decide("b.txt", .keep, in: stack)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.txt"))
        stack.sync(stack.root, with: try FolderScanner.scan(dir))

        #expect(stack.lastDecision == .toss)
        #expect(stack.undo()?.name == "x.txt")
        #expect(stack.current.folder.lastPathComponent == "Sub")
        #expect(stack.undo()?.name == "a.txt")
        #expect(!stack.canUndo)
    }

    // MARK: Memory

    @Test func memoryTreatsAFileRewrittenInPlaceAsNew() {
        let folder = URL(fileURLWithPath: "/x")
        let then = Date(timeIntervalSince1970: 1_000_000)
        let first = SiftSession(folder: folder, items: [
            FileItem(url: folder.appendingPathComponent("report.csv"), modified: then, fileNumber: 7),
        ])
        first.decide(.toss)

        let later = SiftSession(folder: folder, items: [
            FileItem(url: folder.appendingPathComponent("report.csv"), modified: then.addingTimeInterval(60), fileNumber: 7),
        ])
        later.recall(first.memory)

        #expect(later.tossed.isEmpty)
    }

    @Test func aRememberedDitchIsNotAppliedToAFolder() {
        let folder = URL(fileURLWithPath: "/x")
        let course = FileItem(url: folder.appendingPathComponent("Course"), isDirectory: true, fileNumber: 3)
        let first = SiftSession(folder: folder, items: [course])
        first.decide(.toss)

        let later = SiftSession(folder: folder, items: [course])
        later.recall(first.memory)

        #expect(later.tossed.isEmpty)
        #expect(later.current?.name == "Course")
    }

    @Test func savesRememberedInsideADitchedFolderAreFlagged() throws {
        let dir = try makeFolder(["Course/", "Course/notes.txt", "Course/Week 1/", "Course/Week 1/certificate.pdf"])
        let course = dir.appendingPathComponent("Course")
        let week = course.appendingPathComponent("Week 1")
        let earlier = SiftSession(folder: week, items: try FolderScanner.scan(week))
        earlier.decide(.keep)
        let remembered = earlier.memory
        // The saved file was edited after that sift; it is still the file that was saved.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(300)], ofItemAtPath: week.appendingPathComponent("certificate.pdf").path)

        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        stack.decide(.toss)
        let warnings = stack.rememberedKeptInsideTossedFolders { folder in
            folder.resolvingSymlinksInPath().path == course.resolvingSymlinksInPath().path ? [(week, remembered)] : []
        }

        #expect(warnings.map(\.folder.name) == ["Course"])
        #expect(warnings.first?.kept.map(\.name) == ["certificate.pdf"])
    }

    @Test func aRememberedDitchIsNotAppliedToAPackage() {
        let folder = URL(fileURLWithPath: "/x")
        let song = FileItem(url: folder.appendingPathComponent("Song.logicx"), isPackage: true, fileNumber: 4)
        let first = SiftSession(folder: folder, items: [song])
        first.decide(.toss)

        let later = SiftSession(folder: folder, items: [song])
        later.recall(first.memory)

        #expect(later.tossed.isEmpty)
    }

    @Test func decisionsRememberedBeforeModifiedTimesStillCount() {
        let folder = URL(fileURLWithPath: "/x")
        let file = FileItem(url: folder.appendingPathComponent("a.txt"), modified: Date(timeIntervalSince1970: 5_000), fileNumber: 9)
        let later = SiftSession(folder: folder, items: [file])

        later.recall(["a.txt|9": .keep])

        #expect(later.kept.map(\.name) == ["a.txt"])
    }

    // MARK: The card stack and the trays

    @Test func upcomingFollowsThePathDecidingTakes() {
        let folder = URL(fileURLWithPath: "/x")
        let all = ["a", "b", "c", "d"].map { FileItem(url: folder.appendingPathComponent($0)) }
        let s = SiftSession(folder: folder, items: all)
        s.select(all[1].id)
        s.decide(.keep)
        s.select(all[0].id)

        #expect(s.upcoming(2).map(\.name) == ["c", "d"])
        s.select(all[3].id)
        #expect(s.upcoming(3).map(\.name) == ["a", "c"])
    }

    @Test func traysListFilesInTheOrderDecided() throws {
        let dir = try makeFolder(["a.txt", "b.txt", "c.txt"])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try decide("c.txt", .keep, in: stack)
        try decide("a.txt", .keep, in: stack)

        #expect(stack.kept.map(\.name) == ["c.txt", "a.txt"])
    }

    @Test func undoingAChangedDecisionRestoresItsPlaceInTheTray() throws {
        let dir = try makeFolder(["a.txt", "b.txt"])
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try decide("a.txt", .keep, in: stack)
        try decide("b.txt", .keep, in: stack)
        try decide("a.txt", .toss, in: stack)

        stack.undo()

        #expect(stack.kept.map(\.name) == ["a.txt", "b.txt"])
    }

    // MARK: The Trash and putting back

    @Test func filesAreRecordedAsTheyMove() async throws {
        let dir = try makeFolder(["a.txt", "b.txt", "c.txt"])
        let bin = try makeFolder([])
        let s = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        s.decideRest(.toss)
        var seen: [Int] = []

        await s.moveToTrash(s.pendingTrash, using: FolderTrasher(bin: bin)) { _ in seen.append(s.trashed.count) }

        #expect(seen == [1, 2, 3])
    }

    @Test func aFileComesBackInsideItsFolderEvenUnderANewName() async throws {
        let dir = try makeFolder(["Photos/", "Photos/a.jpg", "Photos/b.jpg"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        let photos = try item("Photos", in: stack.root)
        try stack.enter(photos)
        try decide("a.jpg", .toss, in: stack)
        stack.leave()
        stack.decide(.toss)
        await stack.moveTossedToTrash(using: trasher)
        #expect(stack.trashed.count == 2)

        // A new, unrelated Photos folder appears.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Photos"), withIntermediateDirectories: false)
        let picture = try #require(stack.trashed.first { $0.item.name == "a.jpg" })
        let landed = try stack.putBack(picture, using: trasher)

        #expect(landed.deletingLastPathComponent().lastPathComponent == "Photos 2")
        #expect(try names(in: dir.appendingPathComponent("Photos 2")) == ["a.jpg", "b.jpg"])
        #expect(try names(in: dir.appendingPathComponent("Photos")).isEmpty)
        #expect(stack.trashed.isEmpty)
        #expect(stack.restoredURL(of: photos.id)?.lastPathComponent == "Photos 2")
    }

    @Test func putBackAllKeepsFilesWithTheirRenamedFolder() async throws {
        let dir = try makeFolder(["Sub/", "Sub/a.txt", "Sub/b.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try stack.enter(try item("Sub", in: stack.root))
        try decide("a.txt", .toss, in: stack)
        stack.leave()
        stack.decide(.toss)
        await stack.moveTossedToTrash(using: trasher)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: false)

        var landings: [String: String] = [:]
        let stuck = stack.putBackAll(using: trasher) { file, url in
            landings[file.item.name] = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        }

        #expect(stuck.isEmpty)
        #expect(landings["a.txt"] == "Sub 2/a.txt")
        #expect(try names(in: dir.appendingPathComponent("Sub 2")) == ["a.txt", "b.txt"])
    }

    @Test func puttingBackAFileBringsBackEveryFolderAboveIt() async throws {
        let dir = try makeFolder(["A/", "A/B/", "A/B/f.txt", "A/B/g.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try stack.enter(try item("A", in: stack.root))
        let a = stack.current
        try stack.enter(try item("B", in: a))
        try decide("f.txt", .toss, in: stack)
        stack.leave()
        stack.decide(.toss)
        stack.leave()
        stack.decide(.toss)
        await stack.moveTossedToTrash(using: trasher)
        #expect(stack.trashed.count == 3)

        let file = try #require(stack.trashed.first { $0.item.name == "f.txt" })
        try stack.putBack(file, using: trasher)

        #expect(try names(in: dir.appendingPathComponent("A")) == ["B"])
        #expect(try names(in: dir.appendingPathComponent("A/B")) == ["f.txt", "g.txt"])
        #expect(stack.trashed.isEmpty)
    }

    @Test func aSavedFileFollowsItsFolderWhenItComesBackRenamed() async throws {
        let dir = try makeFolder(["Sub/", "Sub/keep.txt", "Sub/old.txt"])
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        let stack = FolderStack(root: SiftSession(folder: dir, items: try FolderScanner.scan(dir)))
        try stack.enter(try item("Sub", in: stack.root))
        try decide("keep.txt", .keep, in: stack)
        stack.leave()
        stack.decide(.toss)
        await stack.moveTossedToTrash(using: trasher)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: false)

        try stack.putBack(try #require(stack.trashed.first), using: trasher)

        let kept = try #require(stack.keptInPlace.first { $0.name == "keep.txt" })
        #expect(stack.currentURL(of: kept).deletingLastPathComponent().lastPathComponent == "Sub 2")
    }
}
