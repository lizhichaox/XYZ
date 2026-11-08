import XCTest
@testable import XYZCore

final class CodeFoldingTests: XCTestCase {
    private func folds(_ text: String) -> [CodeFolding.Fold] {
        CodeFolding.folds(in: text, language: .swift)
    }

    func testSimpleBlock() {
        let text = """
        func a() {
            one()
            two()
        }
        third()
        """
        let result = folds(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.headerLine, 1)
        // The closing brace is hidden with the block, as VS Code does.
        XCTAssertEqual(result.first?.lastLine, 4)
        XCTAssertEqual(result.first?.lineCount, 3)
    }

    func testNestedBlocksCloseInnerFirst() {
        let text = """
        class A {
            func b() {
                work()
            }
            after()
        }
        """
        let result = folds(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.headerLine), [1, 2])
        XCTAssertEqual(result.first(where: { $0.headerLine == 2 })?.lastLine, 4)
        XCTAssertEqual(result.first(where: { $0.headerLine == 1 })?.lastLine, 6)
    }

    func testBlankLinesDoNotCloseBlock() {
        let text = """
        func a() {
            one()

            two()
        }
        """
        let result = folds(text)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lastLine, 5)
        XCTAssertEqual(result.first?.lineCount, 4)
    }

    func testSameIndentSiblingsDoNotFold() {
        XCTAssertTrue(folds("a()\nb()\nc()\n").isEmpty)
    }

    func testTabsCountAsFour() {
        let text = "func a() {\n\tone()\n}\n"
        XCTAssertEqual(folds(text).count, 1)
    }

    func testMarkdownIsNotFoldedHere() {
        XCTAssertTrue(CodeFolding.folds(in: "- a\n  - b\n", language: .markdown).isEmpty)
    }

    func testTrailingBlankLinesAreNotPartOfFold() {
        let text = "func a() {\n    one()\n\n\nnext()\n"
        let fold = folds(text).first
        XCTAssertEqual(fold?.lastLine, 2)
    }

    func testInnerRangeMatchesHiddenLines() {
        let text = "func a() {\n    one()\n}\n"
        let fold = folds(text).first!
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: fold.innerRange), "    one()\n}\n")
    }
}
