import XCTest
@testable import XYZCore

final class TextDocumentTests: XCTestCase {
    func testRoundTripPreservesText() throws {
        let text = "Hello\nworld\r\nend"
        let document = TextDocument(text: text)
        let decoded = try TextDocument(data: document.data())
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(document.data(), Data(text.utf8))
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

    func testStripsUTF8BOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let document = try TextDocument(data: bom + Data("note".utf8))
        XCTAssertEqual(document.text, "note")
        XCTAssertEqual(document.data(), Data("note".utf8))
        XCTAssertFalse(document.data().starts(with: [0xEF, 0xBB, 0xBF]))
    }

    func testRejectsInvalidUTF8() {
        XCTAssertThrowsError(try TextDocument(data: Data([0x80]))) { error in
            XCTAssertEqual(error as? TextDocument.DecodingError, .invalidUTF8)
        }
    }

    func testLargeRoundTrip() throws {
        let line = "The quick brown fox jumps over the lazy dog.\n"
        let text = String(repeating: line, count: 1_000)
        let document = TextDocument(text: text)
        XCTAssertEqual(try TextDocument(data: document.data()).text, text)
    }
}
