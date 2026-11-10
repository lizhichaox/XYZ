import XCTest
import XYZCore

final class AutoCloseTests: XCTestCase {
    func testAutoClosesAnOpeningBracket() {
        let text = "let value = "
        let edit = SourceEditing.autoClose(in: text, selection: caret(12), inserted: "(")
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "let value = ()")
        XCTAssertEqual(applied?.selection, caret(13))
    }

    func testWrapsASelection() {
        let text = "hello"
        let edit = SourceEditing.autoClose(in: text, selection: SourceRange(location: 0, length: 5), inserted: "(")
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "(hello)")
        XCTAssertEqual(applied?.selection, SourceRange(location: 1, length: 5))
    }

    func testStepsOverAClosingBracket() {
        let text = "()"
        let edit = SourceEditing.autoClose(in: text, selection: caret(1), inserted: ")")
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "()")
        XCTAssertEqual(applied?.selection, caret(2))
    }

    func testPairsAQuoteAtABoundary() {
        let text = "let value = "
        let edit = SourceEditing.autoClose(in: text, selection: caret(12), inserted: "\"")
        let applied = apply(edit, to: text)
        XCTAssertEqual(applied?.text, "let value = \"\"")
        XCTAssertEqual(applied?.selection, caret(13))
    }

    func testDoesNotPairAnApostropheInsideAWord() {
        XCTAssertNil(SourceEditing.autoClose(in: "don", selection: caret(3), inserted: "'"))
    }

    func testDoesNotPairAQuoteBeforeAWord() {
        XCTAssertNil(SourceEditing.autoClose(in: "word", selection: caret(0), inserted: "\""))
    }

    func testIgnoresOtherText() {
        XCTAssertNil(SourceEditing.autoClose(in: "a", selection: caret(1), inserted: "b"))
    }

    func testDoesNotStepOverAMismatchedBracket() {
        XCTAssertNil(SourceEditing.autoClose(in: "(]", selection: caret(1), inserted: ")"))
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
