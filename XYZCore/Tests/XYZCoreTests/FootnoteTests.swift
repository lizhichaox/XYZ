import XCTest
@testable import XYZCore

final class FootnoteTests: XCTestCase {
    func testReferenceAndSection() {
        let html = MarkdownHTML.render("Text[^1].\n\n[^1]: First note.\n")
        XCTAssertTrue(html.contains("<sup class=\"footnote-ref\" id=\"fnref-1\"><a href=\"#fn-1\">1</a></sup>"))
        XCTAssertTrue(html.contains("<section class=\"footnotes\">"))
        XCTAssertTrue(html.contains("<li id=\"fn-1\">"))
        XCTAssertTrue(html.contains("First note."))
        XCTAssertFalse(html.contains("[^1]"))
    }

    func testNumberingFollowsFirstReference() {
        let html = MarkdownHTML.render("A[^b] B[^a].\n\n[^a]: Alpha.\n[^b]: Beta.\n")
        XCTAssertTrue(html.contains("href=\"#fn-1\">1</a></sup>"))
        XCTAssertTrue(html.contains("href=\"#fn-2\">2</a></sup>"))
        guard let beta = html.range(of: "Beta.")?.lowerBound,
              let alpha = html.range(of: "Alpha.")?.lowerBound else {
            return XCTFail("the definitions are missing")
        }
        XCTAssertLessThan(beta, alpha)
    }

    func testRepeatedReferenceSharesNumber() {
        let html = MarkdownHTML.render("A[^1] B[^1].\n\n[^1]: Note.\n")
        XCTAssertEqual(html.components(separatedBy: "href=\"#fn-1\">1</a></sup>").count - 1, 2)
        XCTAssertEqual(html.components(separatedBy: "<li id=\"fn-1\">").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "id=\"fnref-1\"").count - 1, 1)
    }

    func testMissingDefinitionStaysLiteral() {
        let html = MarkdownHTML.render("Text[^missing].\n")
        XCTAssertTrue(html.contains("[^missing]"))
        XCTAssertFalse(html.contains("footnotes"))
    }

    func testCodeKeepsLiteral() {
        let html = MarkdownHTML.render("`[^1]`\n\n```\n[^1]\n```\n\n[^1]: Note.\n")
        XCTAssertTrue(html.contains("[^1]"))
        XCTAssertFalse(html.contains("footnote-ref"))
        XCTAssertFalse(html.contains("footnotes"))
    }

    func testDefinitionLineNumbersDoNotMove() {
        let html = MarkdownHTML.render("Text[^1].\n\n[^1]: Note.\n\n# Heading\n")
        XCTAssertTrue(html.contains("<h1 id=\"heading\" data-line=\"5\" data-end=\"5\">"))
    }

    func testMultiLineDefinition() {
        let html = MarkdownHTML.render("Text[^1].\n\n[^1]: First line.\n    Second line.\n")
        XCTAssertTrue(html.contains("First line."))
        XCTAssertTrue(html.contains("Second line."))
    }

    func testUnreferencedDefinitionIsNotRendered() {
        let html = MarkdownHTML.render("Text.\n\n[^1]: Unused.\n")
        XCTAssertFalse(html.contains("Unused."))
        XCTAssertFalse(html.contains("footnotes"))
    }

    func testDefinitionKeepsFormatting() {
        let html = MarkdownHTML.render("Text[^1].\n\n[^1]: **Bold** and [link](https://example.com).\n")
        XCTAssertTrue(html.contains("<strong>Bold</strong>"))
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
    }

    func testCRLF() {
        let html = MarkdownHTML.render("Text[^1].\r\n\r\n[^1]: Note.\r\n")
        XCTAssertTrue(html.contains("footnote-ref"))
        XCTAssertTrue(html.contains("Note."))
    }

    func testDefinitionInsideFenceIsNotExtracted() {
        let html = MarkdownHTML.render("```\n[^1]: not a definition\n```\n\nText[^1].\n")
        XCTAssertTrue(html.contains("[^1]"))
        XCTAssertFalse(html.contains("footnotes"))
    }

    func testOutlineSkipsFootnoteDefinitions() {
        let markdown = "# Title[^1]\n\n[^1]: Note.\n\n## Section\n"
        let headings = MarkdownOutline.headings(in: markdown)
        XCTAssertEqual(headings.map(\.title), ["Title", "Section"])
        XCTAssertEqual(headings.map(\.line), [1, 5])
    }

    func testFootnoteInHeadingKeepsHeadingAnchor() {
        let html = MarkdownHTML.render("# Title[^1]\n\n[^1]: Note.\n")
        XCTAssertTrue(html.contains("<h1 id=\"title\""))
        XCTAssertTrue(html.contains("footnote-ref"))
    }
}
