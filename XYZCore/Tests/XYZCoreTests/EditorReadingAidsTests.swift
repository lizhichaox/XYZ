import XCTest
@testable import XYZCore

final class EditorReadingAidsTests: XCTestCase {
    func testFindsEnclosingParenthesesForward() {
        let text = "call(alpha, beta)" as NSString
        let pair = BracketMatching.pair(in: text, caretOffset: 4)
        XCTAssertEqual(pair?.opener, NSRange(location: 4, length: 1))
        XCTAssertEqual(pair?.closer, NSRange(location: 16, length: 1))
    }

    func testFindsClosingBracketBackwards() {
        let text = "if (alpha) { return }" as NSString
        let pair = BracketMatching.pair(in: text, caretOffset: 10)
        XCTAssertEqual(pair?.opener, NSRange(location: 3, length: 1))
        XCTAssertEqual(pair?.closer, NSRange(location: 9, length: 1))
    }

    func testHandlesNesting() {
        let text = "{ a { b } c }" as NSString
        let pair = BracketMatching.pair(in: text, caretOffset: 0)
        XCTAssertEqual(pair?.opener, NSRange(location: 0, length: 1))
        XCTAssertEqual(pair?.closer, NSRange(location: 12, length: 1))
    }

    func testUnbalancedReturnsNil() {
        XCTAssertNil(BracketMatching.pair(in: "((alpha" as NSString, caretOffset: 0))
        XCTAssertNil(BracketMatching.pair(in: "plain" as NSString, caretOffset: 2))
    }

    func testWordRangeAtCaretAndInside() {
        let text = "let value = otherValue" as NSString
        XCTAssertEqual(WordOccurrences.wordRange(in: text, at: 5), NSRange(location: 4, length: 5))
        XCTAssertEqual(WordOccurrences.wordRange(in: text, at: 7), NSRange(location: 4, length: 5))
        // The caret just after a word still selects that word, as in most editors.
        XCTAssertEqual(WordOccurrences.wordRange(in: text, at: 3), NSRange(location: 0, length: 3))
    }

    func testMatchesOnlyWholeWords() {
        let text = "value otherValue value_value value" as NSString
        let word = NSRange(location: 0, length: 5)
        let found = WordOccurrences.matches(
            of: word,
            in: text,
            within: NSRange(location: 0, length: text.length),
            limit: 10,
            excluding: [word]
        )
        XCTAssertEqual(found, [NSRange(location: 29, length: 5)])
    }

    func testMatchLimit() {
        let text = "a a a a a" as NSString
        let found = WordOccurrences.matches(
            of: NSRange(location: 0, length: 1),
            in: text,
            within: NSRange(location: 0, length: text.length),
            limit: 2,
            excluding: [NSRange(location: 0, length: 1)]
        )
        XCTAssertEqual(found.count, 2)
    }
}
