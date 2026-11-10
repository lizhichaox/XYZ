import XCTest
import XYZCore

final class AutoIndentTests: XCTestCase {
    func testKeepsCodeIndent() {
        let text = "    let value = 1"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(17), language: .swift)
        XCTAssertEqual(apply(edit, to: text)?.text, "    let value = 1\n    ")
    }

    func testOpensALevelAfterAnOpeningBracket() {
        let text = "func run() {"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(12), language: .swift)
        XCTAssertEqual(apply(edit, to: text)?.text, "func run() {\n    ")
    }

    func testOutdentsBeforeAClosingBracket() {
        let text = "    }"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(4), language: .swift)
        XCTAssertEqual(apply(edit, to: text)?.text, "    \n}")
    }

    func testUsesTabsWhenTheLineUsesTabs() {
        let text = "\tlet value = 1"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(14), language: .swift)
        XCTAssertEqual(apply(edit, to: text)?.text, "\tlet value = 1\n\t")
    }

    func testIndentsAfterAColonInPython() {
        let text = "if ready:"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(9), language: .python)
        XCTAssertEqual(apply(edit, to: text)?.text, "if ready:\n    ")
    }

    func testReturnBetweenAutoClosedBraces() {
        let text = "{}"
        let edit = SourceEditing.autoIndent(in: text, selection: caret(1), language: .swift)
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "{\n    \n}")
        XCTAssertEqual(applied?.selection, caret(6))
    }

    func testIgnoresProseAndMarkdown() {
        XCTAssertNil(SourceEditing.autoIndent(in: "    text", selection: caret(8), language: .plain))
        XCTAssertNil(SourceEditing.autoIndent(in: "    text", selection: caret(8), language: .markdown))
    }

    func testDoesNotTouchACaretInsideTheIndent() {
        XCTAssertNil(SourceEditing.autoIndent(in: "    code", selection: caret(2), language: .swift))
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
