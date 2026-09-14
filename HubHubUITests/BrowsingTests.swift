import XCTest

/// The list, the tabs and the chart only exist once SwiftUI has laid them out —
/// a decoding test says nothing about whether tapping a repo actually draws a
/// chart. These drive the real app against whatever snapshot is cached on the
/// simulator (see `scripts/seed-simulator.py`), and skip when there is none.
///
/// Row *counts* are deliberately never asserted: XCUITest only sees the cells
/// the list has currently realised, so a count is a fact about scroll position.
/// Membership of a named repo is stable.
final class BrowsingTests: XCTestCase {
    private func launch() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        guard app.buttons.matching(identifier: "repoRow").firstMatch.waitForExistence(timeout: 10) else {
            throw XCTSkip("no cached snapshot on this simulator to browse")
        }
        return app
    }

    /// A repo with no open issues, and one with some, taken from the cached
    /// snapshot itself so the test does not hard-code today's numbers.
    private func anchors(in app: XCUIApplication) throws -> (quiet: String, noisy: String) {
        app.tabBars.buttons["Issues"].tap()
        guard app.buttons.matching(identifier: "repoRow").firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip("no open issues in the cached snapshot")
        }
        let noisy = firstRepoName(in: app)

        app.tabBars.buttons["Repos"].tap()
        _ = app.buttons.matching(identifier: "repoRow").firstMatch.waitForExistence(timeout: 5)
        // Sorted by downloads, so the top repo is the popular one; find one the
        // Issues tab did not list.
        let quiet = (0..<min(6, app.buttons.matching(identifier: "repoRow").count))
            .map { name(ofRowAt: $0, in: app) }
            .first { $0 != noisy && !$0.isEmpty }

        guard let quiet else { throw XCTSkip("could not find a repo without open issues") }
        return (quiet, noisy)
    }

    private func firstRepoName(in app: XCUIApplication) -> String {
        name(ofRowAt: 0, in: app)
    }

    /// The row's label is the repo name followed by its metric chips.
    private func name(ofRowAt index: Int, in app: XCUIApplication) -> String {
        let row = app.buttons.matching(identifier: "repoRow").element(boundBy: index)
        guard row.exists else { return "" }
        return row.label.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDrillingIntoARepoDrawsItsChart() throws {
        let app = try launch()
        attach(app, named: "repos")

        app.buttons.matching(identifier: "repoRow").element(boundBy: 0).tap()

        XCTAssertTrue(
            app.otherElements["historyChart"].waitForExistence(timeout: 5),
            "the repo's history should chart from the series file"
        )
        attach(app, named: "detail")

        // Every metric charts from the same series file.
        app.buttons["Stars"].tap()
        XCTAssertTrue(app.otherElements["historyChart"].waitForExistence(timeout: 5))
        attach(app, named: "detail-stars")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["hubHub"].waitForExistence(timeout: 5))
    }

    /// The `--i` behaviour: repos with no open issues are dropped from the
    /// Issues tab, not merely sorted to the bottom.
    func testIssuesTabDropsReposWithNoOpenIssues() throws {
        let app = try launch()
        let (quiet, noisy) = try anchors(in: app)

        app.tabBars.buttons["Repos"].tap()
        XCTAssertTrue(app.staticTexts[quiet].waitForExistence(timeout: 5), "\(quiet) is in the full list")

        app.tabBars.buttons["Issues"].tap()
        XCTAssertTrue(app.navigationBars["Issues"].waitForExistence(timeout: 5))
        attach(app, named: "issues")

        XCTAssertTrue(app.staticTexts[noisy].exists, "\(noisy) has open issues and stays")
        XCTAssertFalse(app.staticTexts[quiet].exists, "\(quiet) has no open issues and should be gone")
    }

    func testSearchNarrowsToTheMatchingRepo() throws {
        let app = try launch()
        let target = firstRepoName(in: app)
        try XCTSkipIf(target.isEmpty, "no rows to search")

        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText(target)

        XCTAssertTrue(app.staticTexts[target].waitForExistence(timeout: 5), "the searched repo stays")
        attach(app, named: "search")

        field.typeText("zzz-no-such-repo")
        XCTAssertTrue(
            app.staticTexts["No matches"].waitForExistence(timeout: 5),
            "a query matching nothing should say so rather than show a blank list"
        )
        attach(app, named: "search-empty")
    }

    func testSettingsOffersTheRefreshControls() throws {
        let app = try launch()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Reload stats file"].exists)
        XCTAssertTrue(app.buttons["Run snapshot Action now"].exists)
        attach(app, named: "settings")
    }
}
