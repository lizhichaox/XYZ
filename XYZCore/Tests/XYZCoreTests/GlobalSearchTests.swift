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

    private func file(_ name: String, _ path: String) -> WorkspacePathEntry {
        WorkspacePathEntry(name: name, relativePath: path, isDirectory: false, isHidden: false)
    }
}
