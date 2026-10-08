import Foundation
import Testing
@testable import SiftCore

@MainActor @Suite struct FolderStackTests {
    /// A root with one loose file and a subfolder holding two files and a deeper folder.
    func makeStack() throws -> (FolderStack, URL) {
        let dir = try makeFolder(["loose.txt", "Sub/", "Sub/a.txt", "Sub/b.txt", "Sub/Deeper/", "Sub/Deeper/c.txt"])
        let root = SiftSession(folder: dir, items: try FolderScanner.scan(dir))
        return (FolderStack(root: root), dir)
    }

    func item(_ name: String, in session: SiftSession) throws -> FileItem {
        try #require(session.items.first { $0.name == name })
    }

    /// Decides the current session's items in order until the named one is current.
    func advance(to name: String, in session: SiftSession) {
        while let current = session.current, current.name != name { session.decide(.keep) }
    }

    @Test func enteringAFolderSiftsItsContents() throws {
        let (stack, _) = try makeStack()
        try stack.enter(try item("Sub", in: stack.root))
        #expect(stack.current.folder.lastPathComponent == "Sub")
        #expect(Set(stack.current.items.map(\.name)) == ["a.txt", "b.txt", "Deeper"])
        #expect(stack.canLeave)
    }

    @Test func enteringAFileDoesNothing() throws {
        let (stack, _) = try makeStack()
        try stack.enter(try item("loose.txt", in: stack.root))
        #expect(stack.path.count == 1)
    }

    @Test func leavingAndReturningKeepsDecisions() throws {
        let (stack, _) = try makeStack()
        let sub = try item("Sub", in: stack.root)
        try stack.enter(sub)
        stack.current.decide(.toss)
        stack.leave()
        #expect(stack.current === stack.root)
        try stack.enter(sub)
        #expect(stack.current.decidedCount == 1)
        #expect(stack.visited.count == 2)
    }

    @Test func leaveToJumpsUpSeveralLevels() throws {
        let (stack, _) = try makeStack()
        try stack.enter(try item("Sub", in: stack.root))
        try stack.enter(try item("Deeper", in: stack.current))
        #expect(stack.path.count == 3)
        stack.leave(to: stack.root)
        #expect(stack.path.count == 1)
        #expect(stack.visited.last === stack.root)
    }

    @Test func totalsSpanEveryFolderVisited() throws {
        let (stack, _) = try makeStack()
        advance(to: "loose.txt", in: stack.root)
        stack.root.decide(.toss)
        try stack.enter(try item("Sub", in: stack.root))
        advance(to: "a.txt", in: stack.current)
        stack.current.decide(.toss)
        #expect(Set(stack.tossed.map(\.name)) == ["loose.txt", "a.txt"])
        #expect(stack.decidedCount == stack.root.decidedCount + stack.current.decidedCount)
    }

    @Test func undoReopensTheFolderOfTheLastDecision() throws {
        let (stack, _) = try makeStack()
        try stack.enter(try item("Sub", in: stack.root))
        try stack.enter(try item("Deeper", in: stack.current))
        stack.decide(.toss)
        stack.leave(to: stack.root)
        #expect(stack.path.count == 1)

        let undone = stack.undo()

        #expect(undone?.name == "c.txt")
        #expect(stack.current.folder.lastPathComponent == "Deeper")
        #expect(stack.path.map(\.folder.lastPathComponent) == [stack.root.folder.lastPathComponent, "Sub", "Deeper"])
        #expect(stack.tossed.isEmpty)
        #expect(!stack.canUndo)
    }

    @Test func changeFindsTheFolderThatDecided() throws {
        let (stack, _) = try makeStack()
        try stack.enter(try item("Sub", in: stack.root))
        let first = try #require(stack.current.current)
        stack.current.decide(.toss)
        stack.leave()
        stack.change(first.id, to: .keep)
        #expect(stack.tossed.isEmpty)
        #expect(stack.kept.map(\.id) == [first.id])
    }

    @Test func tossedFolderAndTossedFileInsideItBothReachTheTrash() async throws {
        let (stack, _) = try makeStack()
        let bin = try makeFolder([])
        let sub = try item("Sub", in: stack.root)
        try stack.enter(sub)
        advance(to: "a.txt", in: stack.current)
        stack.current.decide(.toss)
        stack.leave()
        advance(to: "Sub", in: stack.root)
        stack.root.decide(.toss)

        await stack.moveTossedToTrash(using: FolderTrasher(bin: bin))

        #expect(stack.failed.isEmpty)
        #expect(Set(stack.trashed.map(\.item.name)) == ["Sub", "a.txt"])
        #expect(try names(in: bin) == ["Sub", "a.txt"])
    }

    @Test func putBackWorksForAFileInASubfolder() async throws {
        let (stack, dir) = try makeStack()
        let bin = try makeFolder([])
        let trasher = FolderTrasher(bin: bin)
        try stack.enter(try item("Sub", in: stack.root))
        advance(to: "b.txt", in: stack.current)
        stack.current.decide(.toss)
        await stack.moveTossedToTrash(using: trasher)

        try stack.putBack(try #require(stack.trashed.first), using: trasher)

        #expect(try names(in: dir.appendingPathComponent("Sub")).contains("b.txt"))
        #expect(stack.trashed.isEmpty)
    }
}
