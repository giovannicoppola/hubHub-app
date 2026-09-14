import XCTest
@testable import HubHub

/// Runs the importer against the actual Alfred workflow cache on this Mac, the
/// way `ReportParityTests` runs against the real vault. Skips when the file is
/// not there, so it is a no-op on anyone else's machine and in CI.
final class RealAlfredHistoryTests: XCTestCase {
    private static let candidates = [
        NSString(string: "~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/alfred-hubhub/myGitHistory.json").expandingTildeInPath,
        "/Users/giovanni/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/alfred-hubhub/myGitHistory.json",
    ]

    private func realHistory() throws -> [String: Any] {
        for path in Self.candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return json
        }
        throw XCTSkip("no Alfred workflow history on this machine")
    }

    func testImportsTheRealWorkflowHistory() throws {
        let json = try realHistory()
        var history = LocalHistory.empty

        let summary = try history.merge(alfred: json)

        XCTAssertGreaterThan(summary.added, 500, "years of snapshots")
        XCTAssertEqual(history.dates.first, summary.earliest)
        XCTAssertTrue(history.dates.first!.hasPrefix("2022"), "goes back to 2022, got \(history.dates.first!)")

        // Downloads are tracked throughout; stars only from 2022-12 onward, and
        // the earlier dates must stay unknown rather than becoming zeros.
        let series = history.series()
        let charted = series.dates
        XCTAssertLessThan(charted.count, 500, "thinned for charting")

        let withDownloads = series.repos.values.compactMap { $0["downloads"]?.compactMap { $0 }.count }.max() ?? 0
        XCTAssertGreaterThan(withDownloads, 100, "a real download trend to plot")

        // No repo should have a star series that starts at 0 on a
        // downloads-only date and then jumps — those entries must be nil.
        let firstDate = charted.first!
        if firstDate < "2022-12-01" {
            let starsOnFirstDate = series.repos.values.compactMap { $0["stars"]?.first ?? nil }
            XCTAssertTrue(starsOnFirstDate.isEmpty, "stars were not tracked on \(firstDate)")
        }
    }

    /// Real data through the real chart path: a repo with a long history must
    /// produce a monotonically rising download line.
    func testARealRepoProducesAUsableDownloadChart() throws {
        let json = try realHistory()
        var history = LocalHistory.empty
        _ = try history.merge(alfred: json)

        let series = history.series()
        let best = series.repos.keys
            .max { series.points(repo: $0, metric: .downloads).count < series.points(repo: $1, metric: .downloads).count }
        let name = try XCTUnwrap(best)
        let points = series.points(repo: name, metric: .downloads)

        XCTAssertGreaterThan(points.count, 50, "\(name) should have a long series")
        XCTAssertLessThan(points.first!.value, points.last!.value, "downloads grow over time")
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.date < $1.date }, "points are in date order")
        print("charted \(name): \(points.count) points, \(points.first!.value) → \(points.last!.value)")
    }
}
