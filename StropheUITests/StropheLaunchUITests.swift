import XCTest

final class StropheLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testApplicationLaunchesAndCreatesAWindow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
    }

    #if os(macOS)
    @MainActor
    func testTimelineSearchCommandPresentsEditingTools() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "-ui-testing-open-editor",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()

        let timelineMenu = app.menuBars.menuBarItems["Timeline"]
        XCTAssertTrue(timelineMenu.waitForExistence(timeout: 15))
        timelineMenu.click()

        let searchCommand = app.menuItems["Search, Replace & Filter"]
        XCTAssertTrue(searchCommand.waitForExistence(timeout: 5))
        searchCommand.click()

        let editingTools = app.descendants(matching: .any)["subtitleEditingTools"].firstMatch
        XCTAssertTrue(
            editingTools.waitForExistence(timeout: 10),
            "The Timeline command should present the subtitle editing tools from the root window."
        )
    }
    #endif
}
