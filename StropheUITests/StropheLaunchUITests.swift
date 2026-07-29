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
        XCTAssertTrue(ensureApplicationWindow(app))
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
        XCTAssertTrue(ensureApplicationWindow(app))

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

    @MainActor
    func testKaraokeEditorPresentsTemplateAndDraggableWordTimeline() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing",
            "-ui-testing-open-editor",
            "-ui-testing-karaoke-demo",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(ensureApplicationWindow(app))

        let panel = app.descendants(matching: .any)["karaokeEditorPanel"].firstMatch
        let karaokeButton = app.descendants(matching: .any)[
            "karaokeModeButton"
        ].firstMatch
        XCTAssertTrue(
            karaokeButton.waitForExistence(timeout: 15),
            "The timeline toolbar should expose the Karaoke tool."
        )
        XCTAssertFalse(
            panel.exists,
            "Selecting a subtitle must not reveal Karaoke until its tool is activated."
        )
        XCTAssertTrue(karaokeButton.isEnabled)
        karaokeButton.click()
        XCTAssertTrue(
            panel.waitForExistence(timeout: 5),
            "Clicking the Karaoke tool should reveal the editor for the selected cue."
        )

        let preset = app.descendants(matching: .any)["karaokePresetPicker"].firstMatch
        let reveal = app.descendants(matching: .any)["karaokeRevealPicker"].firstMatch
        let timeline = app.descendants(matching: .any)["karaokeUnitTimeline"].firstMatch
        let preview = app.descendants(matching: .any)["karaokePreviewCanvas"].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(timeline.frame.width, 400)
        XCTAssertGreaterThan(timeline.frame.height, 30)

        let selectedTiming = app.descendants(matching: .any)[
            "karaokeSelectedUnitTiming"
        ].firstMatch
        XCTAssertTrue(selectedTiming.waitForExistence(timeout: 5))
        let initialTimingValue = String(describing: selectedTiming.value)
        XCTAssertFalse(initialTimingValue.isEmpty)

        let boundary = app.sliders
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "karaokeBoundary-"
                )
            )
            .firstMatch
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        let initialBoundaryValue = String(describing: boundary.value)
        XCTAssertFalse(initialBoundaryValue.isEmpty)
        boundary.adjust(toNormalizedSliderPosition: 0.72)
        XCTAssertNotEqual(
            String(describing: boundary.value),
            initialBoundaryValue,
            "Adjusting a Karaoke boundary should update its timing value."
        )
        XCTAssertNotEqual(
            String(describing: selectedTiming.value),
            initialTimingValue,
            "The boundary edit should commit into the selected unit timing."
        )
        XCTAssertTrue(panel.exists)

        karaokeButton.hover()
        let tooltip = app.descendants(matching: .any)[
            "karaokeModeTooltip"
        ].firstMatch
        XCTAssertTrue(
            tooltip.waitForExistence(timeout: 3),
            "Hovering the Karaoke tool should reveal its shortcut and description."
        )
        XCTAssertTrue(app.staticTexts["⌥K"].exists)

        let attachment = XCTAttachment(
            screenshot: app.windows.firstMatch.screenshot()
        )
        attachment.name = "Karaoke Editor – Glow Template"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    @MainActor
    private func ensureApplicationWindow(_ app: XCUIApplication) -> Bool {
        if app.windows.firstMatch.waitForExistence(timeout: 3) {
            return true
        }

        // A macOS `Window` scene can remember that its sole window was closed
        // in an earlier run. Reopen the declared scene so launch-state
        // persistence cannot make the UI tests depend on local machine state.
        app.activate()
        let windowMenu = app.menuBars.menuBarItems["Window"]
        guard windowMenu.waitForExistence(timeout: 3) else { return false }
        windowMenu.click()
        let welcome = app.menuItems["Welcome"]
        guard welcome.waitForExistence(timeout: 3) else { return false }
        welcome.click()
        return app.windows.firstMatch.waitForExistence(timeout: 10)
    }
}
