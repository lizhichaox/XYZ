import XCTest
@testable import XYZCore

final class TextBytesTests: XCTestCase {
    func testUTF8RoundTripKeepsTheText() throws {
        let decoded = try XCTUnwrap(TextBytes.decode(Data("line\n".utf8)))
        XCTAssertEqual(decoded.text, "line\n")
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertEqual(decoded.lineEnding, .lf)
        XCTAssertFalse(decoded.mixedLineEndings)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: .utf8, lineEnding: .lf), Data("line\n".utf8))
    }

    func testUTF8BOMIsPreserved() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("note".utf8)
        let decoded = try XCTUnwrap(TextBytes.decode(original))
        XCTAssertEqual(decoded.text, "note")
        XCTAssertEqual(decoded.encoding, .utf8BOM)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: decoded.encoding, lineEnding: .lf), original)
    }

    func testCRLFIsNormalizedAndWrittenBack() throws {
        let original = Data("a\r\nb\r\n".utf8)
        let decoded = try XCTUnwrap(TextBytes.decode(original))
        XCTAssertEqual(decoded.text, "a\nb\n")
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertFalse(decoded.mixedLineEndings)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: .utf8, lineEnding: .crlf), original)
    }

    func testCRIsNormalizedAndWrittenBack() throws {
        let original = Data("a\rb\r".utf8)
        let decoded = try XCTUnwrap(TextBytes.decode(original))
        XCTAssertEqual(decoded.text, "a\nb\n")
        XCTAssertEqual(decoded.lineEnding, .cr)
        XCTAssertFalse(decoded.mixedLineEndings)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: .utf8, lineEnding: .cr), original)
    }

    func testMixedEndingsKeepTheMostCommon() throws {
        let decoded = try XCTUnwrap(TextBytes.decode(Data("a\nb\r\nc\n".utf8)))
        XCTAssertEqual(decoded.text, "a\nb\nc\n")
        XCTAssertEqual(decoded.lineEnding, .lf)
        XCTAssertTrue(decoded.mixedLineEndings)
    }

    func testUTF16LittleEndianBOMRoundTrip() throws {
        let text = "Hi\n"
        let data = try XCTUnwrap(TextBytes.encode(text, encoding: .utf16LEBOM, lineEnding: .lf))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE])
        let decoded = try XCTUnwrap(TextBytes.decode(data))
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(decoded.encoding, .utf16LEBOM)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: decoded.encoding, lineEnding: .lf), data)
    }

    func testWindows1252RoundTripForATextName() throws {
        let original = Data([0x48, 0x69, 0x20, 0xE9])
        let decoded = try XCTUnwrap(TextBytes.decode(original, allowLegacy: true))
        XCTAssertEqual(decoded.text, "Hi é")
        XCTAssertEqual(decoded.encoding, .windows1252)
        XCTAssertEqual(TextBytes.encode(decoded.text, encoding: .windows1252, lineEnding: .lf), original)
        XCTAssertNil(TextBytes.decode(original, allowLegacy: false))
    }

    func testUTF16SampleIsTextForAKnownName() {
        let data = Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "notes.txt", byteCount: data.count, sample: data),
            .plainText
        )
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(name: "notes.png", byteCount: data.count, sample: data),
            .binary
        )
    }

    func testALargeImageIsStillAViewer() {
        XCTAssertEqual(
            WorkspaceFileClassifier.kind(
                name: "photo.png",
                byteCount: WorkspaceFileClassifier.editLimit + 10,
                sample: Data([0x89, 0x50, 0x4E, 0x47])
            ),
            .binary
        )
    }
}

final class EditorTabTests: XCTestCase {
    func testSingleClickReplacesThePreview() {
        var strip = EditorTabStrip()
        XCTAssertNil(strip.open("a.md", pin: false))
        XCTAssertEqual(strip.open("b.md", pin: false), "a.md")
        XCTAssertEqual(strip.tabs.map(\.id), ["b.md"])
        XCTAssertTrue(strip.tabs[0].isPreview)
        XCTAssertEqual(strip.activeID, "b.md")
    }

    func testADirtyPreviewIsPinnedInsteadOfReplaced() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: false)
        XCTAssertTrue(strip.setDirty(id: "a.md", true))
        XCTAssertFalse(strip.tabs[0].isPreview)
        XCTAssertNil(strip.open("b.md", pin: false))
        XCTAssertEqual(strip.tabs.map(\.id), ["a.md", "b.md"])
        XCTAssertTrue(strip.tabs[1].isPreview)
    }

    func testPinAndEditKeepTheTab() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: true)
        strip.open("b.md", pin: false)
        XCTAssertEqual(strip.tabs.map(\.id), ["a.md", "b.md"])
        strip.open("a.md", pin: false)
        XCTAssertEqual(strip.activeID, "a.md")
        XCTAssertEqual(strip.tabs.count, 2)
    }

    func testCloseSelectsTheNeighbor() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: true)
        strip.open("b.md", pin: true)
        strip.open("c.md", pin: true)
        XCTAssertEqual(strip.close(id: "b.md"), "c.md")
        XCTAssertEqual(strip.close(id: "c.md"), "a.md")
        XCTAssertNil(strip.close(id: "a.md"))
        XCTAssertTrue(strip.tabs.isEmpty)
    }

    func testTabsToTheRightAndTheOthers() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: true)
        strip.open("b.md", pin: true)
        strip.open("c.md", pin: true)
        XCTAssertEqual(strip.ids(toTheRightOf: "b.md"), ["c.md"])
        XCTAssertEqual(strip.ids(toTheRightOf: "c.md"), [])
        XCTAssertEqual(strip.ids(otherThan: "b.md"), ["a.md", "c.md"])
        XCTAssertEqual(strip.ids(toTheRightOf: "missing"), [])
    }

    func testShortcutsSelectTabsAndNineIsLast() {
        var strip = EditorTabStrip()
        for name in ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"] {
            strip.open(name, pin: true)
        }
        XCTAssertEqual(strip.select(shortcut: 1), "a")
        XCTAssertEqual(strip.select(shortcut: 2), "b")
        XCTAssertEqual(strip.select(shortcut: 9), "j")
        XCTAssertNil(strip.select(shortcut: 0))
    }

    func testRenameRewritesOpenTabs() {
        var strip = EditorTabStrip()
        strip.open("notes/a.md", pin: true)
        strip.open("notes/b.md", pin: true)
        strip.retarget(from: "notes", to: "archive")
        XCTAssertEqual(strip.tabs.map(\.id), ["archive/a.md", "archive/b.md"])
        XCTAssertEqual(strip.activeID, "archive/b.md")
    }

    func testClosedTabHistoryIsNewestFirstAndDropsDuplicates() {
        var history = ClosedTabHistory()
        history.push("")
        history.push("a.md")
        history.push("b.md")
        history.push("a.md")
        XCTAssertEqual(history.paths, ["a.md", "b.md"])
        XCTAssertEqual(history.pop(), "a.md")
        XCTAssertEqual(history.pop(), "b.md")
        XCTAssertNil(history.pop())
        for index in 0..<30 {
            history.push("file-\(index).txt")
        }
        XCTAssertEqual(history.paths.count, ClosedTabHistory.limit)
        XCTAssertEqual(history.paths.first, "file-29.txt")
        XCTAssertEqual(history.paths.last, "file-5.txt")
        history.retarget(from: "file-29.txt", to: "renamed.txt")
        XCTAssertEqual(history.paths.first, "renamed.txt")
    }

    func testATabKeepsItsOwnViewMode() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: true, mode: .reading)
        strip.open("b.txt", pin: true, mode: .source)
        strip.setMode(id: "b.txt", .reading)
        XCTAssertEqual(strip.tabs.map(\.mode), [.reading, .reading])
        strip.open("a.md", pin: false)
        XCTAssertEqual(strip.tabs.first?.mode, .reading)
    }

    func testDetachHandsTheTabToAnotherWindow() {
        var strip = EditorTabStrip()
        strip.open("a.md", pin: true)
        strip.open("b.md", pin: true, mode: .reading)
        let moved = strip.detach("a.md")
        XCTAssertEqual(moved?.id, "a.md")
        XCTAssertEqual(strip.tabs.map(\.id), ["b.md"])
        XCTAssertEqual(strip.activeID, "b.md")
    }
}

final class WindowRestoreTests: XCTestCase {
    func testNormalizedStateDropsEmptyAndRepeatedPaths() {
        let state = WorkspaceWindowState(
            tabs: [
                WorkspaceTabState(path: "", isPreview: false, mode: .source),
                WorkspaceTabState(path: "a.md", isPreview: true, mode: .reading),
                WorkspaceTabState(path: "a.md", isPreview: false, mode: .source),
                WorkspaceTabState(path: "b.md", isPreview: true, mode: .source),
            ],
            activePath: "missing.md"
        ).normalized()
        XCTAssertEqual(state.tabs.map(\.path), ["a.md", "b.md"])
        XCTAssertEqual(state.tabs.map(\.isPreview), [true, false])
        XCTAssertNil(state.activePath)
    }

    func testAnotherWindowOwnsAFileTheCurrentWindowDoesNot() {
        let tabs = [["a.md"], ["b.md", "c.md"]]
        XCTAssertEqual(WorkspaceFileFocus.otherWindow(containing: "b.md", tabs: tabs, current: 0), 1)
        XCTAssertNil(WorkspaceFileFocus.otherWindow(containing: "a.md", tabs: tabs, current: 0))
        XCTAssertNil(WorkspaceFileFocus.otherWindow(containing: "z.md", tabs: tabs, current: 0))
    }

    func testRecentTabsStayNewestFirstAcrossCloseAndMove() {
        var source = TabMRU()
        source.focus("a.md")
        source.focus("b.md")
        source.focus("a.md")
        XCTAssertEqual(source.recent, ["a.md", "b.md"])
        let moved = "a.md"
        source.close(moved)
        var destination = TabMRU()
        destination.focus(moved)
        XCTAssertEqual(source.order(open: ["b.md", "c.md"]), ["b.md", "c.md"])
        XCTAssertEqual(destination.recent, ["a.md"])
        source.retarget(from: "b.md", to: "notes/b.md")
        XCTAssertEqual(source.recent, ["notes/b.md"])
    }
}

final class ReadOnlyPreviewTests: XCTestCase {
    func testPicturesStayViewersAndOfficeStaysQuickLook() {
        XCTAssertEqual(FileOpenRouting.route(name: "photo.png", kind: .binary), .viewer(.image))
        XCTAssertEqual(FileOpenRouting.route(name: "clip.mp4", kind: .binary), .viewer(.audiovisual))
        XCTAssertEqual(FileOpenRouting.route(name: "report.docx", kind: .binary), .quickLook)
        XCTAssertEqual(FileOpenRouting.route(name: "notes.md", kind: .markdown), .edit)
        XCTAssertEqual(FileOpenRouting.route(name: "data.dat", kind: .binary), .readOnlyPreview)
        XCTAssertEqual(FileOpenRouting.route(name: "huge.log", kind: .tooLarge), .readOnlyPreview)
    }

    func testPreviewFallsBackWhenTheBytesAreNotUnicode() throws {
        let latin = TextBytes.preview(Data([0x48, 0x69, 0xFF]), truncated: false)
        XCTAssertEqual(latin.encoding, .windows1252)
        XCTAssertEqual(latin.text.count, 3)
        XCTAssertFalse(latin.text.contains("\u{FFFD}"))
        XCTAssertFalse(latin.truncated)

        let nuls = TextBytes.preview(Data([0x41, 0x00, 0x42]), truncated: true)
        XCTAssertEqual(nuls.encoding, .utf8)
        XCTAssertTrue(nuls.text.contains("A"))
        XCTAssertTrue(nuls.text.contains("B"))
        XCTAssertTrue(nuls.truncated)
        let mixed = TextBytes.preview(Data([0xFF, 0x00]), truncated: false)
        XCTAssertEqual(mixed.encoding, .windows1252)
        XCTAssertFalse(mixed.text.contains("\u{FFFD}"))

        let utf8 = TextBytes.preview(Data("你好".utf8), truncated: false)
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(utf8.text, "你好")
    }
}

final class EditorCaretTests: XCTestCase {
    func testColumnCountsCharacters() {
        let text = "ab\n你c"
        let caret = EditorCaret.measure(text: text, utf16Location: 4, utf16Length: 0)
        XCTAssertEqual(caret.line, 2)
        XCTAssertEqual(caret.column, 2)
    }

    func testSelectionOnOneLineCountsCharacters() {
        let caret = EditorCaret.measure(text: "hello", utf16Location: 1, utf16Length: 3)
        XCTAssertEqual(caret.selectedCharacters, 3)
        XCTAssertEqual(caret.selectedLines, 0)
        XCTAssertEqual(caret.column, 2)
    }

    func testSelectionAcrossLines() {
        let caret = EditorCaret.measure(text: "one\ntwo\nthree", utf16Location: 0, utf16Length: 9)
        XCTAssertEqual(caret.selectedLines, 3)
        XCTAssertEqual(caret.line, 1)
    }

    func testGoToPositionParsesLineAndColumn() {
        XCTAssertEqual(GoToPosition.parse("12"), GoToPosition(line: 12))
        XCTAssertEqual(GoToPosition.parse("12:4"), GoToPosition(line: 12, column: 4))
        XCTAssertEqual(GoToPosition.parse("12,4"), GoToPosition(line: 12, column: 4))
        XCTAssertEqual(GoToPosition.parse("12：4"), GoToPosition(line: 12, column: 4))
        XCTAssertEqual(GoToPosition.parse(" 12 : 4 "), GoToPosition(line: 12, column: 4))
        XCTAssertNil(GoToPosition.parse(""))
        XCTAssertNil(GoToPosition.parse("a"))
        XCTAssertNil(GoToPosition.parse("0"))
        XCTAssertNil(GoToPosition.parse("1:0"))
        XCTAssertNil(GoToPosition.parse("1:2:3"))
    }

    func testGoToOffsetCountsCharacters() {
        let text = "ab\n你c"
        XCTAssertEqual(GoToPosition.utf16Offset(in: text, line: 2, column: 1), 3)
        XCTAssertEqual(GoToPosition.utf16Offset(in: text, line: 2, column: 2), 4)
        XCTAssertEqual(GoToPosition.utf16Offset(in: text, line: 9, column: 1), 3)
        let emoji = "a😀"
        XCTAssertEqual(GoToPosition.utf16Offset(in: emoji, line: 1, column: 2), 1)
        XCTAssertEqual(GoToPosition.utf16Offset(in: emoji, line: 1, column: 3), 3)
    }
}

final class FileFormatTests: XCTestCase {
    func testMarkdownJSONAndCSVReading() {
        XCTAssertEqual(FileFormats.format(for: "README.md").reading, .markdown)
        XCTAssertTrue(FileFormats.format(for: "README.md").isProse)
        XCTAssertEqual(FileFormats.format(for: "data.json").reading, .json)
        XCTAssertEqual(FileFormats.format(for: "data.json").language, .json)
        XCTAssertTrue(FileFormats.format(for: "App.swift").usesCodeFont)
        XCTAssertEqual(FileFormats.format(for: "table.csv").reading, .csv)
        XCTAssertEqual(FileFormats.format(for: "photo.png").viewer, .image)
        XCTAssertEqual(FileFormats.format(for: "notes.pdf").viewer, .pdf)
        XCTAssertNil(FileFormats.format(for: "archive.zip").viewer)
    }

    func testCrumbsIncludeTheFile() {
        let crumbs = WorkspacePaths.crumbs(rootName: "Notes", relativePath: "a/b.md")
        XCTAssertEqual(crumbs.map(\.name), ["Notes", "a", "b.md"])
        XCTAssertEqual(crumbs.map(\.relativePath), ["", "a", "a/b.md"])
    }

    func testJSONPrettyPrintSortsKeys() {
        let pretty = JSONText.pretty("{\"b\":1,\"a\":2}\n")
        let a = pretty?.range(of: "\"a\"")
        let b = pretty?.range(of: "\"b\"")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        if let a, let b {
            XCTAssertLessThan(a.lowerBound, b.lowerBound)
        }
        XCTAssertNil(JSONText.pretty("{"))
    }

    func testCSVQuotesCommasAndTabs() {
        let grid = CSVText.parse("name,note\n\"a,b\",\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(grid.rows, [["name", "note"], ["a,b", "say \"hi\""]])
        XCTAssertFalse(grid.truncated)
        let tabs = CSVText.parse("a\tb\n1\t2\n")
        XCTAssertEqual(tabs.rows, [["a", "b"], ["1", "2"]])
        XCTAssertEqual(CSVText.parse("a,b\r\n1,2\r\n").rows, [["a", "b"], ["1", "2"]])
    }

    func testSyntaxColorsASwiftLine() {
        let spans = SyntaxColoring.spans(in: "let name = \"hi\" // note\n", language: .swift)
        XCTAssertTrue(spans.contains { $0.kind == .keyword })
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .comment })
        XCTAssertTrue(SyntaxColoring.spans(in: "let", language: .markdown).isEmpty)
    }

    func testINIColorsSectionKeysAndValues() {
        let spans = SyntaxColoring.spans(in: "[Proxy]\nname = \"surge\"\nport = 6152\n", language: .ini)
        XCTAssertTrue(spans.contains { $0.kind == .type })
        XCTAssertTrue(spans.contains { $0.kind == .key })
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .number })
    }

    func testSyntaxColorsTheVisibleWindowOfALargeFile() {
        let gap = String(repeating: "a\n", count: 130_000)
        let tail = "let ready = 1\n"
        let text = gap + tail
        let ns = text as NSString
        let start = ns.length - (tail as NSString).length
        let spans = SyntaxColoring.spans(in: text, language: .swift, within: start..<ns.length)
        XCTAssertTrue(spans.contains { $0.kind == .keyword })
        XCTAssertTrue(spans.contains { $0.kind == .number })
        XCTAssertFalse(spans.contains { $0.location < start })
        XCTAssertTrue(SyntaxColoring.spans(in: text, language: .swift).isEmpty)
    }

    func testJSONSyntaxSkipsAStringThatLooksLikeAKeyword() {
        let spans = SyntaxColoring.spans(in: "{\"true\": false}\n", language: .json)
        let keywords = spans.filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 1)
        XCTAssertTrue(spans.contains { $0.kind == .string })
    }
}

final class FileOutlineTests: XCTestCase {
    func testMarkdownHeadingsKeepLevelAndLine() {
        let entries = FileOutline.entries(in: "# A\n\n## B\n", language: .markdown)
        XCTAssertEqual(entries.map(\.title), ["A", "B"])
        XCTAssertEqual(entries.map(\.depth), [0, 1])
        XCTAssertEqual(entries.map(\.line), [1, 3])
    }

    func testJSONKeysNestAndSkipStringsThatAreValues() {
        let text = "{\n  \"a\": 1,\n  \"b\": {\n    \"c\": \"func hidden\"\n  }\n}\n"
        let entries = FileOutline.entries(in: text, language: .json)
        XCTAssertEqual(entries.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(entries.map(\.depth), [0, 0, 1])
        XCTAssertEqual(entries.map(\.line), [2, 3, 4])
    }

    func testSwiftDeclarationsSkipCommentsAndKeepIndent() {
        let text = "// func hidden\nstruct Box {\n    public func open() {}\n}\n"
        let entries = FileOutline.entries(in: text, language: .swift)
        XCTAssertEqual(entries.map(\.title), ["Box", "open"])
        XCTAssertGreaterThan(entries[1].depth, entries[0].depth)
        XCTAssertEqual(entries[1].line, 3)
    }

    func testWindows1252RejectsCharactersItCannotStore() {
        XCTAssertTrue(TextBytes.canStore("Hi é", as: .windows1252))
        XCTAssertFalse(TextBytes.canStore("你好", as: .windows1252))
        XCTAssertTrue(TextBytes.canStore("你好", as: .utf8))
        XCTAssertTrue(TextBytes.canStore("你好", as: .utf16LE))
    }
}
