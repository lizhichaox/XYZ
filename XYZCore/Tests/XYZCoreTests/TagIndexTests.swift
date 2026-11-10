import XCTest
import XYZCore

final class TagIndexTests: XCTestCase {
    func testFindsTags() {
        XCTAssertEqual(TagIndex.tags(in: "A #swift note and #release/1."), ["swift", "release/1"])
    }

    func testIgnoresCodeAndNumbers() {
        let text = "`#swift`\n\n```\n#swift\n```\n\nIssue #123."
        XCTAssertTrue(TagIndex.tags(in: text).isEmpty)
    }

    func testIgnoresHashInsideWords() {
        XCTAssertTrue(TagIndex.tags(in: "C# and foo#bar").isEmpty)
    }
}
