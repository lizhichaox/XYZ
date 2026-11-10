import XCTest
import XYZCore

final class BacklinkIndexTests: XCTestCase {
    func testWikiLinkResolvesByBasename() {
        let known: Set<String> = ["Notes/Target.md", "Other.md"]
        XCTAssertEqual(BacklinkIndex.resolve("Target", from: "Other.md", knownPaths: known), "Notes/Target.md")
        XCTAssertEqual(BacklinkIndex.resolve("Target#Heading", from: "Other.md", knownPaths: known), "Notes/Target.md")
        XCTAssertEqual(BacklinkIndex.resolve("Target|Alias", from: "Other.md", knownPaths: known), "Notes/Target.md")
    }

    func testMarkdownLinkResolvesRelativeToTheSource() {
        let known: Set<String> = ["Notes/Target.md", "Notes/Other.md"]
        XCTAssertEqual(
            BacklinkIndex.resolve("Target.md", from: "Notes/Other.md", knownPaths: known),
            "Notes/Target.md"
        )
        XCTAssertEqual(
            BacklinkIndex.resolve("../Notes/Target.md", from: "Notes/Other.md", knownPaths: known),
            "Notes/Target.md"
        )
    }

    func testCodeFenceAndInlineCodeAreIgnored() {
        let text = """
        [[Target]]
        `[[Target]]`
        ```
        [[Target]]
        ```
        """
        let links = BacklinkIndex.links(in: text, relativePath: "Other.md")
        XCTAssertEqual(links.map(\.target), ["Target"])
    }

    func testBacklinksCarryHrefLineAndExcerpt() {
        let files = [
            (relativePath: "Notes/Target.md", text: "# Target\n"),
            (relativePath: "Notes/Source.md", text: "Intro\nSee [[Target]].\n"),
        ]
        let backlinks = BacklinkIndex.backlinks(to: "Notes/Target.md", in: files)
        XCTAssertEqual(backlinks.count, 1)
        XCTAssertEqual(backlinks.first?.relativePath, "Notes/Source.md")
        XCTAssertEqual(backlinks.first?.href, "Source.md")
        XCTAssertEqual(backlinks.first?.line, 2)
        XCTAssertEqual(backlinks.first?.excerpt, "See [[Target]].")
    }

    func testRelativeLinkUsesParentSegments() {
        XCTAssertEqual(WorkspacePaths.relativeLink(from: "Notes", to: "Notes/Source.md"), "Source.md")
        XCTAssertEqual(WorkspacePaths.relativeLink(from: "Notes/Deep", to: "Notes/Source.md"), "../Source.md")
        XCTAssertEqual(WorkspacePaths.relativeLink(from: "", to: "Notes/Source.md"), "Notes/Source.md")
    }

    func testBacklinkHTMLIsEscaped() {
        let html = BacklinkHTML.render([
            Backlink(relativePath: "A&B.md", href: "A&B.md", title: "A&B.md", line: 3, excerpt: "<tag>")
        ])
        XCTAssertTrue(html.contains("href=\"A&amp;B.md\""))
        XCTAssertTrue(html.contains("A&amp;B.md"))
        XCTAssertTrue(html.contains("&lt;tag&gt;"))
        XCTAssertTrue(html.contains("Ln 3"))
    }
}
