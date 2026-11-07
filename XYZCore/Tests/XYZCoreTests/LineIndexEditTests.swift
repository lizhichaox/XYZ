import XCTest
@testable import XYZCore

final class LineIndexEditTests: XCTestCase {
    func testTypingASpaceKeepsTheLineCount() {
        let index = LineIndex("one\ntwo\nthree")
        let next = index.applyingEdit(at: 5, removedLength: 0, replacement: "X")
        XCTAssertEqual(next.starts, [0, 4, 9])
        XCTAssertEqual(next.count, 3)
        XCTAssertEqual(next.line(at: 9), 3)
    }

    func testTypingANewlineAddsALine() {
        let index = LineIndex("one\ntwo")
        let next = index.applyingEdit(at: 3, removedLength: 0, replacement: "\n")
        XCTAssertEqual(next.starts, [0, 4, 5])
        XCTAssertEqual(next.line(at: 4), 2)
        XCTAssertEqual(next.line(at: 5), 3)
        XCTAssertEqual(next.count, 3)
    }

    func testDeletingANewlineMergesTwoLines() {
        let index = LineIndex("one\ntwo\nthree")
        let next = index.applyingEdit(at: 3, removedLength: 1, replacement: "")
        XCTAssertEqual(next.starts, [0, 7])
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next.line(at: 7), 2)
    }

    func testDeletingTheLastCharacterOfALineKeepsLaterLines() {
        let index = LineIndex("aa\nbb\ncc")
        let next = index.applyingEdit(at: 2, removedLength: 0, replacement: "z")
        XCTAssertEqual(next.starts, [0, 4, 7])
        XCTAssertEqual(next.line(at: 7), 3)
    }

    func testPastingABlockAddsAStartForEveryBreak() {
        let index = LineIndex("head\ntail")
        let next = index.applyingEdit(at: 4, removedLength: 0, replacement: " a\n b\n c")
        XCTAssertEqual(next.starts, [0, 7, 10, 13])
        XCTAssertEqual(next.count, 4)
        XCTAssertEqual(next.line(at: 13), 4)
    }

    func testReplacingALineWithNothingRemovesItsStart() {
        let index = LineIndex("a\nb\nc\n")
        // Replace "b\n" (offsets 2...4) with "".
        let next = index.applyingEdit(at: 2, removedLength: 2, replacement: "")
        XCTAssertEqual(next.starts, [0, 2, 4])
        XCTAssertEqual(next.count, 3)
    }

    func testCRLFPasteCountsOneBreak() {
        let index = LineIndex("x")
        let next = index.applyingEdit(at: 0, removedLength: 0, replacement: "a\r\nb")
        XCTAssertEqual(next.starts, [0, 3])
        XCTAssertEqual(next.count, 2)
    }

    func testAnEditThatRemovesEverythingLeavesOneEmptyLine() {
        let index = LineIndex("a\nb\nc")
        let next = index.applyingEdit(at: 0, removedLength: 5, replacement: "")
        XCTAssertEqual(next.starts, [0])
        XCTAssertEqual(next.count, 1)
    }
}
