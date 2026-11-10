import XCTest
import XYZCore

final class BracketColorizerTests: XCTestCase {
    func testNestedDepths() {
        let spans = BracketColorizer.spans(in: "([{}])")
        XCTAssertEqual(spans.map(\.depth), [0, 1, 2, 2, 1, 0])
        XCTAssertEqual(spans.map(\.location), [0, 1, 2, 3, 4, 5])
    }

    func testExcludedRangesAreSkipped() {
        let text = "\"(\" + (x)"
        let stringRange = 0..<3
        let spans = BracketColorizer.spans(in: text, excluding: [stringRange])
        XCTAssertEqual(spans.map(\.location), [6, 8])
        XCTAssertEqual(spans.map(\.depth), [0, 0])
    }

    func testUnmatchedClosingIsIgnored() {
        let spans = BracketColorizer.spans(in: ")(")
        XCTAssertEqual(spans.map(\.location), [1])
        XCTAssertEqual(spans.map(\.depth), [0])
    }

    func testUnicodeBeforeBracketsKeepsOffsets() {
        let spans = BracketColorizer.spans(in: "😀(x)")
        XCTAssertEqual(spans.map(\.location), [2, 4])
    }
}
