import Foundation
import Testing
@testable import SiftCore

/// Moving the highlight freely, Finder style, while decisions skip to the next open item.
@MainActor @Suite struct NavigationTests {
    func session(_ names: [String]) -> SiftSession {
        SiftSession(
            folder: URL(fileURLWithPath: "/x"),
            items: names.map { FileItem(url: URL(fileURLWithPath: "/x/\($0)")) })
    }

    @Test func movingDoesNotDecide() {
        let s = session(["a", "b", "c"])
        #expect(s.move(by: 1))
        #expect(s.current?.name == "b")
        #expect(s.decidedCount == 0)
        #expect(s.move(by: -1))
        #expect(s.current?.name == "a")
    }

    @Test func movingStopsAtBothEnds() {
        let s = session(["a", "b"])
        #expect(!s.move(by: -1))
        s.move(by: 1)
        #expect(!s.move(by: 1))
        #expect(s.current?.name == "b")
    }

    @Test func decidingWrapsBackToSkippedItems() {
        let s = session(["a", "b", "c"])
        s.move(by: 1)
        s.decide(.keep)
        #expect(s.current?.name == "c")
        s.decide(.toss)
        #expect(s.current?.name == "a")
        s.decide(.keep)
        #expect(s.isFinished)
        #expect(s.current == nil)
    }

    @Test func fromTheEndUpReturnsToTheLastItemAndDownStays() {
        let s = session(["a"])
        s.decide(.keep)
        #expect(s.current == nil)
        #expect(!s.move(by: 1))
        #expect(s.move(by: -1))
        #expect(s.current?.name == "a")
    }

    @Test func redecidingChangesItAndUndoRestoresTheEarlierDecision() {
        let s = session(["a", "b"])
        s.decide(.keep)
        s.move(by: -1)
        s.decide(.toss)
        #expect(s.tossed.map(\.name) == ["a"])
        #expect(s.current?.name == "b")

        s.undo()

        #expect(s.kept.map(\.name) == ["a"])
        #expect(s.current?.name == "a")
    }

    @Test func selectHighlightsAClickedItem() {
        let s = session(["a", "b", "c"])
        s.select(URL(fileURLWithPath: "/x/c"))
        #expect(s.current?.name == "c")
    }
}
