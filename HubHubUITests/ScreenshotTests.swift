import XCTest

/// Captures the screenshots used in the READMEs.
///
/// Not an assertion suite — it drives the app to each screen and attaches the
/// result, so the documentation is generated from the running app rather than
/// from whatever happened to be on screen when someone reached for the shutter.
/// Skips unless `HUBHUB_SHOTS=1`, so a normal test run does not pay for it.
///
///     python3 scripts/seed-simulator.py --history <public-only history>
///     HUBHUB_SHOTS=1 xcodebuild ... -only-testing:HubHubUITests/ScreenshotTests test
///     python3 scripts/export-screenshots.py <result bundle> docs/screenshots
///
/// Seed it from a history containing only public repositories: these images end
/// up in a public README, and `/user/repos` lists private repos too.
final class ScreenshotTests: XCTestCase {
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureEveryScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HUBHUB_SHOTS"] == "1", "set HUBHUB_SHOTS=1 to capture")

        let app = XCUIApplication()
        app.launch()
        guard app.buttons.matching(identifier: "repoRow").firstMatch.waitForExistence(timeout: 15) else {
            throw XCTSkip("seed the simulator first")
        }

        shoot(app, "01-repos")

        // The chart, on the repo with the longest history.
        app.buttons.matching(identifier: "repoRow").element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["historyChart"].waitForExistence(timeout: 10))
        shoot(app, "02-chart-downloads")

        app.buttons["Stars"].tap()
        XCTAssertTrue(app.otherElements["historyChart"].waitForExistence(timeout: 10))
        shoot(app, "03-chart-stars")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["hubHub"].waitForExistence(timeout: 10))

        // Search, so the header's match count is visible.
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("alfred-g")
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' matching '")).firstMatch
            .waitForExistence(timeout: 5)
        shoot(app, "04-search")
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }

        app.tabBars.buttons["Issues"].tap()
        XCTAssertTrue(app.navigationBars["Issues"].waitForExistence(timeout: 10))
        shoot(app, "05-issues")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        shoot(app, "06-settings")
    }

    /// The App Store set: the sample account, so no real repository name —
    /// public or private — can reach the listing, and so the set can be
    /// regenerated on any simulator without seeding. Shoot on a 6.9" device
    /// (iPhone 16 Pro Max → 1320 x 2868) and export with `--full`.
    func testCaptureAppStoreScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HUBHUB_SHOTS"] == "appstore", "set HUBHUB_SHOTS=appstore to capture")

        let app = XCUIApplication()
        // The argument domain overrides UserDefaults for this launch only, so
        // the simulator's own settings are left as they were.
        app.launchArguments += ["-sample_data", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(identifier: "repoRow").firstMatch.waitForExistence(timeout: 15))
        shoot(app, "01-repos")

        app.buttons.matching(identifier: "repoRow").element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["historyChart"].waitForExistence(timeout: 10))
        shoot(app, "02-chart-downloads")

        app.buttons["Stars"].tap()
        XCTAssertTrue(app.otherElements["historyChart"].waitForExistence(timeout: 10))
        shoot(app, "03-chart-stars")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["hubHub"].waitForExistence(timeout: 10))

        app.tabBars.buttons["Issues"].tap()
        XCTAssertTrue(app.navigationBars["Issues"].waitForExistence(timeout: 10))
        shoot(app, "04-issues")
        // No Settings shot: UI tests run the Debug build, whose Source picker
        // offers an Action mode the store build does not have.
    }
}
