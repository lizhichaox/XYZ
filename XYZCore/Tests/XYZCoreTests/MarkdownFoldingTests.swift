import XCTest
@testable import XYZCore

final class MarkdownFoldingTests: XCTestCase {
    private func folds(_ text: String) -> [CodeFolding.Fold] {
        MarkdownFolding.folds(in: text)
    }

    func testHeadingFoldsToNextSameLevel() {
        let result = folds("# Alpha\nbody one\nbody two\n# Beta\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.headerLine, 1)
        XCTAssertEqual(result.first?.lastLine, 3)
        XCTAssertEqual(result.first?.lineCount, 2)
    }

    func testNestedHeadingFoldsInsideOuter() {
        let result = folds("# Alpha\n## Beta\nbody\n# Gamma\n")
        XCTAssertEqual(result.map(\.headerLine), [1, 2])
        XCTAssertEqual(result[0].lastLine, 3)
        XCTAssertEqual(result[1].lastLine, 3)
    }

    func testHeadingWithNoBodyHasNoFold() {
        XCTAssertTrue(folds("# Alpha\n# Beta\n").isEmpty)
        XCTAssertTrue(folds("# Alpha\n\n\n").isEmpty)
        XCTAssertTrue(folds("# Alpha\n").isEmpty)
    }

    func testFencedCodeIsNotAHeading() {
        let result = folds("# Alpha\n```\n# not a heading\n```\nbody\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.headerLine, 1)
        XCTAssertEqual(result.first?.lastLine, 5)
    }

    func testTildeFenceIsSkipped() {
        let result = folds("# Alpha\n~~~\n# not a heading\n~~~\nbody\n")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lastLine, 5)
    }

    func testIndentedHashIsNotAHeading() {
        XCTAssertTrue(folds("    # code\n    body\n").isEmpty)
    }

    func testSevenHashesIsNotAHeading() {
        XCTAssertTrue(folds("####### seven\nbody\n").isEmpty)
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertTrue(folds("#nospace\nbody\n").isEmpty)
    }

    func testTrailingBlanksAreNotFolded() {
        let result = folds("# Alpha\nbody\n\n\n# Beta\n")
        XCTAssertEqual(result.first?.lastLine, 2)
        XCTAssertEqual(result.first?.lineCount, 1)
    }

    func testCRLFInnerRange() {
        let text = "# Alpha\r\nbody\r\n# Beta\r\n"
        let result = folds(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].innerRange, NSRange(location: 9, length: 6))
        XCTAssertEqual((text as NSString).substring(with: result[0].innerRange), "body\r\n")
    }

    func testSetextHeadingHasNoFold() {
        XCTAssertTrue(folds("Alpha\n=====\nbody\n").isEmpty)
    }

    func testFrontMatterCommentsAreNotHeadings() {
        let result = folds("---\ntitle: Note\n# yaml comment\n---\n# Real\nbody\n")
        XCTAssertEqual(result.map(\.headerLine), [5])
        XCTAssertEqual(result.first?.lastLine, 6)
    }

    func testUnclosedLeadingRuleIsNotFrontMatter() {
        let result = folds("---\n# Real\nbody\n")
        XCTAssertEqual(result.map(\.headerLine), [2])
        XCTAssertEqual(result.first?.lastLine, 3)
    }

    func testFrontMatterWithDotsDelimiter() {
        let result = folds("---\ntitle: Note\n# yaml comment\n...\n# Real\nbody\n")
        XCTAssertEqual(result.map(\.headerLine), [5])
    }

    func testHeadingLevelsStopAtShallowerHeading() {
        let result = folds("## Beta\nbody\n### Deep\ndeep body\n## Next\nnext body\n")
        XCTAssertEqual(result.map(\.headerLine), [1, 3, 5])
        XCTAssertEqual(result[0].lastLine, 4)
        XCTAssertEqual(result[1].lastLine, 4)
        XCTAssertEqual(result[2].lastLine, 6)
    }
}
