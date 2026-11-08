import XCTest
@testable import XYZCore

final class StatusBarLayoutTests: XCTestCase {
    private func candidates(_ extra: Bool = true) -> [StatusBarEntry] {
        var items: [StatusBarEntry] = [
            .wrap,
            .words(TextStatistics(words: 10, characters: 20)),
        ]
        if extra { items.append(.detail("100%")) }
        items.append(contentsOf: [.encoding(.utf8), .lineEnding(.lf), .mode("Editing")])
        return items
    }

    func testRightKeepsAtMostThreeAndModeStays() {
        let layout = StatusBarDistribution.layout(candidates: candidates(), hasPrimary: true, hasSelection: false)
        XCTAssertEqual(layout.right.count, 3)
        XCTAssertEqual(layout.right.last, .mode("Editing"))
        XCTAssertEqual(layout.right, [.encoding(.utf8), .lineEnding(.lf), .mode("Editing")])
    }

    func testOverflowMovesLeftAfterPosition() {
        let layout = StatusBarDistribution.layout(candidates: candidates(), hasPrimary: true, hasSelection: false)
        XCTAssertEqual(layout.left.count, 2)
        XCTAssertEqual(layout.left.first, .wrap)
        XCTAssertTrue(layout.left.contains { if case .words = $0 { return true } else { return false } })
    }

    func testLeftNeverExceedsThree() {
        let many: [StatusBarEntry] = [
            .wrap, .detail("1"), .detail("2"),
            .encoding(.utf8), .lineEnding(.lf), .mode("Editing"),
        ]
        let layout = StatusBarDistribution.layout(candidates: many, hasPrimary: true, hasSelection: true)
        XCTAssertEqual(layout.left.count, 1)
        XCTAssertLessThanOrEqual(layout.left.count + 2, 3)
        XCTAssertEqual(layout.right.count, 3)
    }

    func testShortBarKeepsEverythingOnRight() {
        let layout = StatusBarDistribution.layout(
            candidates: [.encoding(.utf8), .mode("Read-only")],
            hasPrimary: true,
            hasSelection: false
        )
        XCTAssertEqual(layout.left, [])
        XCTAssertEqual(layout.right, [.encoding(.utf8), .mode("Read-only")])
    }

    func testNoPrimaryLeavesRoomOnLeft() {
        let layout = StatusBarDistribution.layout(candidates: candidates(), hasPrimary: false, hasSelection: false)
        XCTAssertEqual(layout.left.count, 3)
    }

    func testModeNeverMovesLeft() {
        for hasSelection in [false, true] {
            let layout = StatusBarDistribution.layout(
                candidates: candidates(),
                hasPrimary: true,
                hasSelection: hasSelection
            )
            XCTAssertEqual(layout.right.last, .mode("Editing"))
            XCTAssertFalse(layout.left.contains(.mode("Editing")))
        }
    }
}
