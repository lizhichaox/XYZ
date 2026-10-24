import XCTest
import XYZCore

final class TextMarkupTests: XCTestCase {
    func testUntitledAndMarkdownAllowMarkers() {
        XCTAssertTrue(TextMarkup.allows(fileExtension: nil))
        XCTAssertTrue(TextMarkup.allows(fileExtension: "md"))
        XCTAssertTrue(TextMarkup.allows(fileExtension: "Markdown"))
        XCTAssertFalse(TextMarkup.allows(fileExtension: "txt"))
        XCTAssertFalse(TextMarkup.allows(fileExtension: ""))
        XCTAssertFalse(TextMarkup.allows(fileExtension: "swift"))
    }
}

final class SourceEditingTests: XCTestCase {
    func testReturnContinuesABullet() {
        let edit = SourceEditing.newline(in: "- 你好", selection: caret(4))
        let applied = apply(edit, to: "- 你好")
        XCTAssertEqual(applied?.text, "- 你好\n- ")
        XCTAssertEqual(applied?.selection, caret(7))
    }

    func testReturnSplitsABullet() {
        let edit = SourceEditing.newline(in: "- hello world", selection: caret(7))
        let applied = apply(edit, to: "- hello world")
        XCTAssertEqual(applied?.text, "- hello\n- world")
        XCTAssertEqual(applied?.selection, caret(10))
    }

    func testReturnIncrementsAnOrderedItem() {
        let edit = SourceEditing.newline(in: "9. item", selection: caret(7))
        XCTAssertEqual(apply(edit, to: "9. item")?.text, "9. item\n10. ")
        let padded = SourceEditing.newline(in: "01) item", selection: caret(8))
        XCTAssertEqual(apply(padded, to: "01) item")?.text, "01) item\n02) ")
    }

    func testReturnContinuesAnUncheckedTask() {
        let edit = SourceEditing.newline(in: "- [x] done", selection: caret(10))
        XCTAssertEqual(apply(edit, to: "- [x] done")?.text, "- [x] done\n- [ ] ")
    }

    func testReturnOnAnEmptyItemLeavesTheList() {
        let edit = SourceEditing.newline(in: "- ", selection: caret(2))
        let applied = apply(edit, to: "- ")
        XCTAssertEqual(applied?.text, "")
        XCTAssertEqual(applied?.selection, caret(0))
    }

    func testReturnOnAnIndentedEmptyItemOutdentsOnce() {
        let edit = SourceEditing.newline(in: "    - ", selection: caret(6))
        let applied = apply(edit, to: "    - ")
        XCTAssertEqual(applied?.text, "  - ")
        XCTAssertEqual(applied?.selection, caret(4))
    }

    func testReturnIgnoresAPlainLineAndAFence() {
        XCTAssertNil(SourceEditing.newline(in: "hello", selection: caret(5)))
        let fenced = "```\n- item\n```\n"
        let caretInFence = caret(("```\n- item" as NSString).length)
        XCTAssertNil(SourceEditing.newline(in: fenced, selection: caretInFence))
    }

    func testReturnIgnoresTheMarkerItself() {
        XCTAssertNil(SourceEditing.newline(in: "- item", selection: caret(1)))
    }

    func testTabIndentsListLines() {
        let text = "- one\n- two"
        let edit = SourceEditing.indent(in: text, selection: SourceRange(location: 2, length: 6))
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "  - one\n  - two")
        XCTAssertEqual(applied?.selection, SourceRange(location: 4, length: 8))
    }

    func testTabOnPlainTextDoesNothing() {
        XCTAssertNil(SourceEditing.indent(in: "hello", selection: caret(2)))
    }

    func testShiftTabRemovesOneIndent() {
        let text = "  - one"
        let edit = SourceEditing.outdent(in: text, selection: caret(6))
        XCTAssertEqual(apply(edit, to: text)?.text, "- one")
        XCTAssertNil(SourceEditing.outdent(in: "- one", selection: caret(2)))
    }

    func testBoldWrapsAndUnwraps() {
        let wrapped = SourceEditing.toggleBold(in: "hello", selection: SourceRange(location: 0, length: 5))
        XCTAssertEqual(apply(wrapped, to: "hello")?.text, "**hello**")
        XCTAssertEqual(apply(wrapped, to: "hello")?.selection, SourceRange(location: 2, length: 5))
        let again = SourceEditing.toggleBold(in: "**hello**", selection: SourceRange(location: 2, length: 5))
        XCTAssertEqual(apply(again, to: "**hello**")?.text, "hello")
    }

    func testEmptyBoldPlacesTheCaretInside() {
        let edit = SourceEditing.toggleBold(in: "ab", selection: caret(1))
        let applied = apply(edit, to: "ab")
        XCTAssertEqual(applied?.text, "a****b")
        XCTAssertEqual(applied?.selection, caret(3))
    }

    func testItalicDoesNotStripBold() {
        let edit = SourceEditing.toggleItalic(in: "**hi**", selection: SourceRange(location: 2, length: 2))
        XCTAssertEqual(apply(edit, to: "**hi**")?.text, "***hi***")
        let marked = SourceEditing.toggleItalic(in: "*hi*", selection: SourceRange(location: 0, length: 4))
        XCTAssertEqual(apply(marked, to: "*hi*")?.text, "hi")
    }

    private func caret(_ location: Int) -> SourceRange {
        SourceRange(location: location, length: 0)
    }

    private func apply(_ edit: SourceReplacement?, to text: String) -> (text: String, selection: SourceRange)? {
        guard let edit else { return nil }
        let ns = text as NSString
        let next = ns.replacingCharacters(
            in: NSRange(location: edit.range.location, length: edit.range.length),
            with: edit.text
        )
        return (next, edit.selection)
    }
}
