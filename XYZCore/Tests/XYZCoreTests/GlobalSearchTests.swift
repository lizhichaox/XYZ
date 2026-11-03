import XCTest
@testable import XYZCore

final class GlobalSearchTests: XCTestCase {
    func testEmptyQueryMatchesNothing() {
        let result = GlobalFileSearch.match(entries: [file("Readme.md", "docs/Readme.md")], query: "  ", showsHidden: true)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.more, 0)
    }

    func testNameMatchOutranksAPathOnlyMatchAndSkipsDirectories() {
        let entries = [
            file("notes.txt", "notes.txt"),
            WorkspacePathEntry(name: "src", relativePath: "src", isDirectory: true, isHidden: false),
            file("other.md", "src/readme/other.md"),
        ]
        let result = GlobalFileSearch.match(entries: entries, query: "note", showsHidden: true)
        XCTAssertEqual(result.hits.map(\.relativePath), ["notes.txt"])
        XCTAssertFalse(result.hits[0].nameIndices.isEmpty)
    }

    func testHiddenFilesStayOutUntilShownAndTheRestIsCounted() {
        var entries: [WorkspacePathEntry] = [
            WorkspacePathEntry(name: ".env", relativePath: ".env", isDirectory: false, isHidden: true),
        ]
        for index in 0..<10 {
            entries.append(file("n\(index).txt", "n\(index).txt"))
        }
        let hidden = GlobalFileSearch.match(entries: entries, query: "n", showsHidden: false)
        XCTAssertFalse(hidden.hits.contains { $0.name == ".env" })
        XCTAssertEqual(hidden.hits.count, 10)
        XCTAssertEqual(hidden.more, 0)
        let shown = GlobalFileSearch.match(entries: entries, query: ".env", showsHidden: true)
        XCTAssertEqual(shown.hits.map(\.name), [".env"])
    }

    func testOpenTabOutranksAStrongerName() {
        let entries = [
            file("alpha.md", "alpha.md"),
            file("beta.md", "beta.md"),
        ]
        let plain = GlobalFileSearch.match(entries: entries, query: "a", showsHidden: true)
        XCTAssertEqual(plain.hits.first?.relativePath, "alpha.md")
        let boosted = GlobalFileSearch.match(
            entries: entries,
            query: "a",
            showsHidden: true,
            boost: ["beta.md": 500]
        )
        XCTAssertEqual(boosted.hits.first?.relativePath, "beta.md")
    }

    func testExcerptKeepsTheMatchInView() {
        let line = String(repeating: "word ", count: 40) + "needle" + String(repeating: " tail", count: 20)
        let excerpt = WorkspaceContentSearch.excerpt(line, around: "needle")
        XCTAssertTrue(excerpt.contains("needle"))
        XCTAssertTrue(excerpt.hasPrefix("…"))
        XCTAssertLessThan(excerpt.count, line.count)
    }

    func testDoubleClickFitKeepsTheEditorAndStaysPut() {
        let wide = SidebarFit.sidebar(content: 640, window: 1100, outline: 220, outlineShown: true)
        XCTAssertEqual(wide, SidebarFit.sidebar(content: 640, window: 1100, outline: 220, outlineShown: true))
        XCTAssertLessThanOrEqual(wide + 220 + SidebarFit.editorMinimum, 1100)
        XCTAssertGreaterThanOrEqual(wide, SidebarFit.sidebarMinimum)
        let tight = SidebarFit.sidebar(content: 800, window: 880, outline: 220, outlineShown: true)
        XCTAssertEqual(tight, SidebarFit.sidebarMinimum)
        let empty = SidebarFit.sidebar(content: 0, window: 1100, outline: 0, outlineShown: false)
        XCTAssertEqual(empty, SidebarFit.sidebarMinimum)
        let outline = SidebarFit.outline(content: 500, window: 1100, sidebar: 260, sidebarShown: true)
        XCTAssertEqual(outline, SidebarFit.outline(content: 500, window: 1100, sidebar: 260, sidebarShown: true))
        XCTAssertLessThanOrEqual(260 + outline + SidebarFit.editorMinimum, 1100 + 0.5)
        XCTAssertEqual(SidebarFit.outline(content: 0, window: 1100, sidebar: 260, sidebarShown: true), SidebarFit.outlineMinimum)
        let nested = SidebarFit.sidebar(content: 480, window: 1400, outline: 0, outlineShown: false)
        XCTAssertEqual(nested, 480)
    }

    func testLevelZeroDisclosureStaysOnScreen() {
        XCTAssertEqual(OutlineDisclosure.originX(-16), 8 as CGFloat)
        XCTAssertGreaterThanOrEqual(OutlineDisclosure.originX(-13), OutlineDisclosure.minimumX)
        XCTAssertEqual(OutlineDisclosure.originX(16), 36 as CGFloat)
        XCTAssertEqual(OutlineDisclosure.shift(proposedX: 16), OutlineDisclosure.inset)
    }

    func testCollapseStaysCollapsedWhileAChildIsOpen() {
        let nested = "Notes/Day/note.md"
        XCTAssertEqual(
            SidebarReveal.ancestorsToExpand(of: nested, explicitReveal: false),
            []
        )
        XCTAssertEqual(
            SidebarReveal.ancestorsToExpand(of: nested, explicitReveal: true),
            ["Notes", "Notes/Day"]
        )
        XCTAssertTrue(SidebarReveal.ancestorsToExpand(of: "", explicitReveal: true).isEmpty)
    }

    func testExplorerSectionCollapsesAndCountsFiles() {
        XCTAssertFalse(ExplorerSection.toggle(true))
        XCTAssertTrue(ExplorerSection.toggle(false))
        let entries = [
            WorkspacePathEntry(name: "Notes", relativePath: "Notes", isDirectory: true, isHidden: false),
            file("a.md", "Notes/a.md"),
            file(".secret.md", "Notes/.secret.md"),
        ]
        var hidden = entries
        hidden[2] = WorkspacePathEntry(name: ".secret.md", relativePath: "Notes/.secret.md", isDirectory: false, isHidden: true)
        XCTAssertEqual(ExplorerSection.fileCount(entries: hidden, showsHidden: false), 1)
        XCTAssertEqual(ExplorerSection.fileCount(entries: hidden, showsHidden: true), 2)
        XCTAssertEqual(ExplorerSection.creationParent(selectedPath: nil, isDirectory: false), "")
        XCTAssertEqual(ExplorerSection.creationParent(selectedPath: "Notes", isDirectory: true), "Notes")
        XCTAssertEqual(ExplorerSection.creationParent(selectedPath: "Notes/a.md", isDirectory: false), "Notes")
    }

    private func file(_ name: String, _ path: String) -> WorkspacePathEntry {
        WorkspacePathEntry(name: name, relativePath: path, isDirectory: false, isHidden: false)
    }
}
