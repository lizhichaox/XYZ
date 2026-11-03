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
    }

    func testSyntaxColorsASwiftLine() {
        let spans = SyntaxColoring.spans(in: "let name = \"hi\" // note\n", language: .swift)
        XCTAssertTrue(spans.contains { $0.kind == .keyword })
        XCTAssertTrue(spans.contains { $0.kind == .string })
        XCTAssertTrue(spans.contains { $0.kind == .comment })
        XCTAssertTrue(SyntaxColoring.spans(in: "let", language: .markdown).isEmpty)
    }

    func testJSONSyntaxSkipsAStringThatLooksLikeAKeyword() {
        let spans = SyntaxColoring.spans(in: "{\"true\": false}\n", language: .json)
        let keywords = spans.filter { $0.kind == .keyword }
        XCTAssertEqual(keywords.count, 1)
        XCTAssertTrue(spans.contains { $0.kind == .string })
    }
}
