import XCTest
@testable import XYZCore

final class TextDocumentTests: XCTestCase {
    func testRoundTripPreservesText() throws {
        let text = "Hello\nworld\r\nend"
        let document = TextDocument(text: text)
        let decoded = try TextDocument(data: document.data())
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(document.data(), Data(text.utf8))
        XCTAssertEqual(decoded.encoding, .utf8)
    }

    func testRoundTripUnicode() throws {
        let text = "你好 — café ☕️\nsecond"
        let document = TextDocument(text: text)
        XCTAssertEqual(try TextDocument(data: document.data()).text, text)
    }

    func testEmptyDocument() throws {
        let document = TextDocument()
        XCTAssertEqual(document.text, "")
        XCTAssertTrue(document.data().isEmpty)
        XCTAssertEqual(try TextDocument(data: Data()).text, "")
    }

    func testDoesNotInventTrailingNewline() {
        let document = TextDocument(text: "no newline")
        XCTAssertEqual(String(data: document.data(), encoding: .utf8), "no newline")
    }

    /// The document scene used to strip the mark, so a save removed a byte the file
    /// had. The workspace path keeps it, and now so does this one.
    func testKeepsUTF8BOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let document = try TextDocument(data: bom + Data("note".utf8))
        XCTAssertEqual(document.text, "note")
        XCTAssertEqual(document.encoding, .utf8BOM)
        XCTAssertEqual(document.data(), bom + Data("note".utf8))
    }

    func testReadsWindows1252AndWritesItBack() throws {
        let original = Data([0x48, 0x69, 0x20, 0xE9])
        let document = try TextDocument(data: original)
        XCTAssertEqual(document.text, "Hi é")
        XCTAssertEqual(document.encoding, .windows1252)
        XCTAssertEqual(document.data(), original)
    }

    func testReadsUTF16WithBOMAndWritesItBack() throws {
        let original = try XCTUnwrap(TextBytes.encode("Hi\n", encoding: .utf16LEBOM, lineEnding: .lf))
        let document = try TextDocument(data: original)
        XCTAssertEqual(document.text, "Hi\n")
        XCTAssertEqual(document.encoding, .utf16LEBOM)
        XCTAssertEqual(document.data(), original)
    }

    /// Mixed line endings are left in the string, as they were before this change.
    func testMixedLineEndingsAreNotRewritten() throws {
        let original = Data("a\r\nb\nc".utf8)
        let document = try TextDocument(data: original)
        XCTAssertEqual(document.text, "a\r\nb\nc")
        XCTAssertEqual(document.data(), original)
    }

    /// A character the file's encoding cannot hold must not make `data()` empty.
    func testUnstorableCharacterFallsBackToUTF8() throws {
        let document = try TextDocument(data: Data([0x48, 0x69, 0x20, 0xE9]))
        var edited = document
        edited.text = "你好"
        XCTAssertEqual(edited.data(), Data("你好".utf8))
    }

    func testRejectsBytesThatAreNotText() {
        // 0x81 is not assigned in Windows-1252 and is not valid UTF-8.
        XCTAssertThrowsError(try TextDocument(data: Data([0x81]))) { error in
            XCTAssertEqual(error as? TextDocument.DecodingError, .unreadableBytes)
        }
    }

    func testLargeRoundTrip() throws {
        let line = "The quick brown fox jumps over the lazy dog.\n"
        let text = String(repeating: line, count: 1_000)
        let document = TextDocument(text: text)
        XCTAssertEqual(try TextDocument(data: document.data()).text, text)
    }
}
