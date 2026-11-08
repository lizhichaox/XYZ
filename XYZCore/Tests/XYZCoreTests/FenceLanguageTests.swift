import XCTest
@testable import XYZCore

final class FenceLanguageTests: XCTestCase {
    func testCommonAliases() {
        XCTAssertEqual(FileFormats.fenceLanguage("swift"), .swift)
        XCTAssertEqual(FileFormats.fenceLanguage(" js "), .javascript)
        XCTAssertEqual(FileFormats.fenceLanguage("ts"), .typescript)
        XCTAssertEqual(FileFormats.fenceLanguage("py"), .python)
        XCTAssertEqual(FileFormats.fenceLanguage("bash"), .shell)
        XCTAssertEqual(FileFormats.fenceLanguage("cpp"), .c)
        XCTAssertEqual(FileFormats.fenceLanguage("yml"), .yaml)
    }

    func testInfoStringWithExtraWords() {
        XCTAssertEqual(FileFormats.fenceLanguage("swift title=Example"), .swift)
        XCTAssertEqual(FileFormats.fenceLanguage("js {highlight}"), .javascript)
    }

    func testUnknownAndMissing() {
        XCTAssertEqual(FileFormats.fenceLanguage(""), .plain)
        XCTAssertEqual(FileFormats.fenceLanguage("brainfuck"), .plain)
    }
}
