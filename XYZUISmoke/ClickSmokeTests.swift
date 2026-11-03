import XCTest

/// One documented XCUIElement click on the existing app. Not an acceptance suite.
final class ClickSmokeTests: XCTestCase {
    func testEditMenuClick() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let edit = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15), "XCUI_SMOKE menu-missing")
        XCTAssertTrue(edit.isHittable, "XCUI_SMOKE not-hittable")
        edit.click()
        let find = edit.menuItems["Find"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "XCUI_SMOKE menu-did-not-open")
        print("XCUI_SMOKE click=pass")
    }
}
