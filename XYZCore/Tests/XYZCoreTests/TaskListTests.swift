import XCTest
import XYZCore

final class TaskListTests: XCTestCase {
    func testTogglesUncheckedAndChecked() {
        let open = TaskList.toggle(in: "- [ ] open\n", line: 1)
        XCTAssertEqual(open?.text, "- [x] open\n")
        XCTAssertEqual(open?.isChecked, true)

        let done = TaskList.toggle(in: "- [x] done\n", line: 1)
        XCTAssertEqual(done?.text, "- [ ] done\n")
        XCTAssertEqual(done?.isChecked, false)
    }

    func testPreservesIndentAndOrderedMarker() {
        let indented = TaskList.toggle(in: "    * [ ] nested\n", line: 1)
        XCTAssertEqual(indented?.text, "    * [x] nested\n")

        let ordered = TaskList.toggle(in: "12) [X] ordered\n", line: 1)
        XCTAssertEqual(ordered?.text, "12) [ ] ordered\n")
    }

    func testTogglesTheRequestedLineOnly() {
        let text = "- [ ] one\n- [ ] two\n- [ ] three\n"
        let toggled = TaskList.toggle(in: text, line: 2)
        XCTAssertEqual(toggled?.text, "- [ ] one\n- [x] two\n- [ ] three\n")
    }

    func testKeepsCRLF() {
        let text = "- [ ] one\r\n- [ ] two\r\n"
        let toggled = TaskList.toggle(in: text, line: 2)
        XCTAssertEqual(toggled?.text, "- [ ] one\r\n- [x] two\r\n")
    }

    func testTogglesATaskInsideABlockquote() {
        let toggled = TaskList.toggle(in: "> - [ ] quoted\n", line: 1)
        XCTAssertEqual(toggled?.text, "> - [x] quoted\n")
    }

    func testIgnoresNonTaskLines() {
        XCTAssertNil(TaskList.toggle(in: "- plain item\n", line: 1))
        XCTAssertNil(TaskList.toggle(in: "text [x] not a list\n", line: 1))
        XCTAssertNil(TaskList.toggle(in: "- [x] done\n", line: 2))
        XCTAssertNil(TaskList.toggle(in: "", line: 1))
        XCTAssertNil(TaskList.toggle(in: "- [x] done\n", line: 0))
    }
}
