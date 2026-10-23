import Markdown
import UniformTypeIdentifiers
import XCTest
@testable import XYZCore

final class MarkdownHTMLTests: XCTestCase {
    func testEmptySource() {
        XCTAssertEqual(MarkdownHTML.render(""), "")
    }

    func testHeading() {
        XCTAssertEqual(MarkdownHTML.render("# Hello\n"), "<h1>Hello</h1>\n")
        XCTAssertEqual(MarkdownHTML.render("###### Deep\n"), "<h6>Deep</h6>\n")
    }

    func testParagraphEmphasisAndStrong() {
        let html = MarkdownHTML.render("Hello *em* and **bold**\n")
        XCTAssertEqual(html, "<p>Hello <em>em</em> and <strong>bold</strong></p>\n")
    }

    func testStrikethrough() {
        let html = MarkdownHTML.render("~~gone~~\n")
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testLists() {
        let html = MarkdownHTML.render("- one\n- two\n\n1. first\n2. second\n")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>"))
        XCTAssertTrue(html.contains("one"))
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertTrue(html.contains("second"))
    }

    func testOrderedListStart() {
        let html = MarkdownHTML.render("3. third\n")
        XCTAssertTrue(html.contains("<ol start=\"3\">"))
        XCTAssertTrue(html.contains("third"))
    }

    func testTaskList() {
        let html = MarkdownHTML.render("- [x] done\n- [ ] open\n")
        XCTAssertEqual(html.components(separatedBy: "class=\"task\"").count - 1, 2)
        XCTAssertTrue(html.contains("type=\"checkbox\" disabled checked"))
        XCTAssertTrue(html.contains("type=\"checkbox\" disabled>"))
        XCTAssertTrue(html.contains("done"))
        XCTAssertTrue(html.contains("open"))
    }

    func testLink() {
        let html = MarkdownHTML.render("[Docs](https://example.com/docs \"Docs\")\n")
        XCTAssertTrue(html.contains("<a href=\"https://example.com/docs\" title=\"Docs\">Docs</a>"))
    }

    func testUnsafeLinkIsNotEmitted() {
        let html = MarkdownHTML.render("[x](javascript:alert(1))\n")
        XCTAssertFalse(html.lowercased().contains("javascript:"))
        XCTAssertFalse(html.contains("<a "))
        XCTAssertTrue(html.contains("x"))

        let dataURL = MarkdownHTML.render("[x](data:text/html,hi)\n")
        XCTAssertFalse(dataURL.contains("data:"))
    }

    func testInlineCodeAndCodeBlock() {
        let html = MarkdownHTML.render("Use `a < b`.\n\n```swift\nlet x = 1\n```\n")
        XCTAssertTrue(html.contains("<code>a &lt; b</code>"))
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">let x = 1</code></pre>"))
    }

    func testBlockquote() {
        let html = MarkdownHTML.render("> quoted *text*\n")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<em>text</em>"))
        XCTAssertTrue(html.contains("quoted"))
    }

    func testTable() {
        let markdown = """
        | Name | Score |
        | --- | ---: |
        | Ada | 10 |

        """
        let html = MarkdownHTML.render(markdown)
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<thead>"))
        XCTAssertTrue(html.contains(">Name</th>"))
        XCTAssertTrue(html.contains(">Ada</td>"))
        XCTAssertTrue(html.contains("text-align:right"))
        XCTAssertTrue(html.contains(">10</td>"))
    }

    func testEscapesRawHTML() {
        let html = MarkdownHTML.render("<script>alert(1)</script>\n")
        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("alert(1)"))
    }

    func testEscapesText() {
        XCTAssertEqual(
            MarkdownHTML.render("a < b & c\n"),
            "<p>a &lt; b &amp; c</p>\n"
        )
    }

    func testThematicBreak() {
        XCTAssertTrue(MarkdownHTML.render("a\n\n---\n\nb\n").contains("<hr>"))
    }

    func testImage() {
        let html = MarkdownHTML.render("![A & B](https://example.com/a.png \"Pic\")\n")
        XCTAssertTrue(html.contains("<img alt=\"A &amp; B\" src=\"https://example.com/a.png\" title=\"Pic\">"))
    }

    func testUnsafeImageDropsSource() {
        let html = MarkdownHTML.render("![diagram](javascript:alert(1))\n")
        XCTAssertFalse(html.lowercased().contains("javascript:"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertTrue(html.contains("diagram"))
    }

    func testSmartPunctuationStaysLiteral() {
        let html = MarkdownHTML.render("a -- b \"quote\"\n")
        XCTAssertTrue(html.contains("a -- b \"quote\""))
        XCTAssertFalse(html.contains("—"))
    }

    func testNestedList() {
        let html = MarkdownHTML.render("- outer\n  - inner\n")
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 2)
        XCTAssertTrue(html.contains("inner"))
    }

    func testHardLineBreak() {
        let html = MarkdownHTML.render("hello  \nworld\n")
        XCTAssertTrue(html.contains("<br>"))
        XCTAssertTrue(html.contains("hello"))
        XCTAssertTrue(html.contains("world"))
    }

    func testParserProducesHeadingNode() {
        let document = MarkdownParser.parse("# Title\n")
        let heading = document.child(at: 0) as? Heading
        XCTAssertEqual(heading?.level, 1)
        let text = heading?.child(at: 0) as? Text
        XCTAssertEqual(text?.string, "Title")
    }

    func testFacadeMatchesDecoupledRenderer() {
        let source = "# Hi\n\n- a\n- b\n\n> quote\n"
        let viaFacade = MarkdownHTML.render(source)
        let viaPieces = HTMLRenderer().render(MarkdownParser.parse(source))
        XCTAssertEqual(viaFacade, viaPieces)
        XCTAssertTrue(viaPieces.contains("<h1>Hi</h1>"))
        XCTAssertTrue(viaPieces.contains("<blockquote>"))
    }

    func testManyBlocks() {
        var source = ""
        for index in 0..<400 {
            source.append("- item \(index)\n")
        }
        let html = MarkdownHTML.render(source)
        XCTAssertTrue(html.contains("item 0"))
        XCTAssertTrue(html.contains("item 399"))
        XCTAssertFalse(html.contains("<script"))
    }
}

final class MarkdownFileDocumentTests: XCTestCase {
    func testNewDocumentSnapshotRoundTrip() throws {
        let document = MarkdownFileDocument()
        XCTAssertEqual(document.text, "")
        document.storeEditorText("# Hello\n")
        let snapshot = try document.snapshot(contentType: .markdown)
        XCTAssertEqual(snapshot, "# Hello\n")
        XCTAssertEqual(TextDocument(text: snapshot).data(), Data("# Hello\n".utf8))
        XCTAssertEqual(document.text, snapshot)
    }

    func testStoreReplacesPreviousText() throws {
        let document = MarkdownFileDocument()
        document.storeEditorText("one")
        document.storeEditorText("two")
        XCTAssertEqual(try document.snapshot(contentType: .plainText), "two")
    }

    func testReadableTypesPreferMarkdown() {
        XCTAssertEqual(MarkdownFileDocument.readableContentTypes.first, .markdown)
        XCTAssertTrue(MarkdownFileDocument.readableContentTypes.contains(.plainText))
        XCTAssertEqual(
            MarkdownFileDocument.writableContentTypes,
            MarkdownFileDocument.readableContentTypes
        )
    }
}
