import XCTest
@testable import XYZCore

final class CommandPaletteTests: XCTestCase {
    func testFuzzyHighlightsSubsequenceAndPrefersRuns() {
        let readme = FuzzyMatcher.match(query: "rdm", candidate: "README.md")
        XCTAssertEqual(readme?.characterIndices, [0, 3, 4])

        let packed = FuzzyMatcher.match(query: "abc", candidate: "abc")
        let scattered = FuzzyMatcher.match(query: "abc", candidate: "a-b-c")
        XCTAssertNotNil(packed)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(packed?.score ?? 0, scattered?.score ?? 0)
        XCTAssertNil(FuzzyMatcher.match(query: "zzz", candidate: "README.md"))
    }

    func testEmptyQueryListsRecentFilesFirst() {
        let files = [
            PaletteFile(name: "a.md", relativePath: "a.md", recency: 1),
            PaletteFile(name: "b.md", relativePath: "b.md", recency: 9),
            PaletteFile(name: "c.md", relativePath: "c.md", recency: 0),
        ]
        let rows = CommandPalette.rows(rawQuery: "", files: files, registry: PaletteCommandRegistry())
        let paths = rows.compactMap { row -> String? in
            if case .file(let file, _) = row { return file.relativePath }
            return nil
        }
        XCTAssertEqual(paths, ["b.md", "a.md", "c.md"])
    }

    func testEqualMatchesBreakTiesByRecency() {
        let files = [
            PaletteFile(name: "note-a.md", relativePath: "note-a.md", recency: 1),
            PaletteFile(name: "note-b.md", relativePath: "note-b.md", recency: 4),
        ]
        let rows = CommandPalette.rows(rawQuery: "note", files: files, registry: PaletteCommandRegistry())
        guard case .file(let first, let match) = rows.first else {
            return XCTFail("expected a file")
        }
        XCTAssertEqual(first.relativePath, "note-b.md")
        XCTAssertFalse(match.characterIndices.isEmpty)
    }

    func testGreaterThanSwitchesToCommands() {
        let files = [PaletteFile(name: "Coding.md", relativePath: "Coding.md", recency: 3)]
        let registry = PaletteCommandRegistry()
        let rows = CommandPalette.rows(rawQuery: ">", files: files, registry: registry)
        XCTAssertEqual(rows.count, PaletteCommand.builtIn.count)
        XCTAssertTrue(rows.allSatisfy { row in
            if case .command = row { return true }
            return false
        })

        let coding = CommandPalette.rows(rawQuery: ">cod", files: files, registry: registry)
        let ids = coding.compactMap { row -> String? in
            if case .command(let command, _) = row { return command.id }
            return nil
        }
        XCTAssertTrue(ids.contains("view.coding"))
        XCTAssertFalse(ids.contains("file.new"))

        let reading = CommandPalette.rows(rawQuery: "> reading", files: [], registry: registry)
        let readingIDs = reading.compactMap { row -> String? in
            if case .command(let command, _) = row { return command.id }
            return nil
        }
        XCTAssertTrue(readingIDs.contains("view.reading"))
        XCTAssertTrue(readingIDs.contains("view.toggleReading"))
    }

    func testRegistryAcceptsPluginCommands() {
        var registry = PaletteCommandRegistry()
        registry.register(PaletteCommand(
            id: "plugin.hello",
            title: "Hello Plugin",
            shortcut: "⌘⌥H",
            keywords: ["extension"]
        ))
        let rows = CommandPalette.rows(rawQuery: ">hello", files: [], registry: registry)
        guard case .command(let command, let match) = rows.first else {
            return XCTFail("expected the plugin command")
        }
        XCTAssertEqual(command.id, "plugin.hello")
        XCTAssertEqual(command.shortcut, "⌘⌥H")
        XCTAssertEqual(match.characterIndices, [0, 1, 2, 3, 4])

        registry.register(PaletteCommand(id: "plugin.hello", title: "Hello Again", shortcut: ""))
        let replaced = CommandPalette.rows(rawQuery: ">again", files: [], registry: registry)
        guard case .command(let updated, _) = replaced.first else {
            return XCTFail("expected the replaced command")
        }
        XCTAssertEqual(updated.title, "Hello Again")
        XCTAssertEqual(registry.commands.filter { $0.id == "plugin.hello" }.count, 1)
    }

    func testBuiltInCommandsExposeShortcuts() {
        let byID = Dictionary(uniqueKeysWithValues: PaletteCommand.builtIn.map { ($0.id, $0) })
        XCTAssertEqual(byID["view.toggleReading"]?.shortcut, "⌘E")
        XCTAssertEqual(byID["view.toggleSource"]?.shortcut, "⌘/")
        XCTAssertEqual(byID["workspace.focusFilter"]?.shortcut, "⇧⌘F")
        XCTAssertEqual(byID["folder.open"]?.shortcut, "⇧⌘O")
        XCTAssertEqual(byID["view.coding"]?.shortcut, "")
    }
}