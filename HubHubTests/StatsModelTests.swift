import XCTest
@testable import HubHub

/// Fixtures shaped exactly like `scripts/snapshot_stats.py` writes them — if
/// the script's output drifts, these are what should fail.
enum Fixtures {
    static let latestJSON = """
    {
      "generatedAt": "2026-09-14T06:22:11Z",
      "owner": "giovannicoppola",
      "current": "2026-09-14",
      "previous": "2026-09-13",
      "repos": [
        {
          "name": "AlfreDo",
          "url": "https://github.com/giovannicoppola/AlfreDo",
          "downloads": 3294, "issues": 0, "stars": 93, "forks": 4, "watchers": 4,
          "previous": {"downloads": 3280, "issues": 1, "stars": 92, "forks": 4, "watchers": 4}
        },
        {
          "name": "alfred-powerthesaurus",
          "url": "https://github.com/giovannicoppola/alfred-powerthesaurus",
          "downloads": 702, "issues": 2, "stars": 44, "forks": 2, "watchers": 0,
          "previous": {"downloads": 702, "issues": 2, "stars": 44, "forks": 2, "watchers": 0}
        },
        {
          "name": "brand-new",
          "url": "https://github.com/giovannicoppola/brand-new",
          "downloads": 0, "issues": 3, "stars": 1, "forks": 0, "watchers": 0
        }
      ]
    }
    """

    static let seriesJSON = """
    {"dates":["2026-09-12","2026-09-13","2026-09-14"],
     "repos":{"AlfreDo":{"downloads":[3270,3280,3294],"issues":[1,1,0],"stars":[92,92,93],"forks":[4,4,4],"watchers":[4,4,4]},
              "brand-new":{"downloads":[null,null,0],"issues":[null,null,3],"stars":[null,null,1],"forks":[null,null,0],"watchers":[null,null,0]}}}
    """

    static func latest() throws -> LatestStats {
        try JSONDecoder().decode(LatestStats.self, from: Data(latestJSON.utf8))
    }

    static func series() throws -> StatsSeries {
        try JSONDecoder().decode(StatsSeries.self, from: Data(seriesJSON.utf8))
    }
}

final class StatsDecodingTests: XCTestCase {
    func testDecodesTheLatestFile() throws {
        let latest = try Fixtures.latest()
        XCTAssertEqual(latest.current, "2026-09-14")
        XCTAssertEqual(latest.previous, "2026-09-13")
        XCTAssertEqual(latest.repos.count, 3)

        let alfredo = latest.repos[0]
        XCTAssertEqual(alfredo.name, "AlfreDo")
        XCTAssertEqual(alfredo.downloads, 3294)
        XCTAssertEqual(alfredo.previous?.downloads, 3280)
    }

    func testIssuesURLHangsOffTheRepoURL() throws {
        let repo = try Fixtures.latest().repos[0]
        XCTAssertEqual(repo.issuesURL?.absoluteString, "https://github.com/giovannicoppola/AlfreDo/issues")
    }

    func testDecodesTheCompactSeries() throws {
        let series = try Fixtures.series()
        XCTAssertEqual(series.dates.count, 3)
        XCTAssertEqual(series.repos.count, 2)
    }
}

final class DeltaTests: XCTestCase {
    func testDeltaIsTheDifferenceFromThePreviousSnapshot() throws {
        let repo = try Fixtures.latest().repos[0]
        XCTAssertEqual(repo.delta(.downloads), 14)
        XCTAssertEqual(repo.delta(.stars), 1)
        XCTAssertEqual(repo.delta(.issues), -1)
        XCTAssertEqual(repo.delta(.forks), 0)
    }

    /// A repo in its first snapshot has no baseline, and must not be reported
    /// as "unchanged" — that is a different claim.
    func testFirstSnapshotHasNoDelta() throws {
        let repo = try Fixtures.latest().repos[2]
        XCTAssertNil(repo.delta(.downloads))
        XCTAssertFalse(repo.hasChanged)
    }

    func testHasChangedTracksAnyMetric() throws {
        let repos = try Fixtures.latest().repos
        XCTAssertTrue(repos[0].hasChanged, "downloads, stars and issues all moved")
        XCTAssertFalse(repos[1].hasChanged, "every count is identical")
    }

    func testSignedDeltaIsNilWhenNothingMoved() {
        XCTAssertNil(0.signedDelta)
        XCTAssertEqual(14.signedDelta, "+14")
        XCTAssertEqual((-3).signedDelta, "-3")
        XCTAssertEqual(3294.signedDelta, "+3,294")
    }

    /// Rising issues are bad news and must not be coloured like rising stars.
    func testRisingIssuesAreNotColouredAsGrowth() {
        XCTAssertFalse(Metric.issues.risingIsGood)
        XCTAssertTrue(Metric.downloads.risingIsGood)
        XCTAssertEqual(Metric.issues.deltaColor(2), Metric.downloads.deltaColor(-2))
    }
}

final class RepoFilterTests: XCTestCase {
    private func repos() throws -> [RepoStats] { try Fixtures.latest().repos }

    func testDefaultSortIsDownloadsThenIssues() throws {
        let sorted = RepoFilter.sorted(try repos(), by: .downloads)
        XCTAssertEqual(sorted.map(\.name), ["AlfreDo", "alfred-powerthesaurus", "brand-new"])
    }

    func testSortByIssues() throws {
        let sorted = RepoFilter.sorted(try repos(), by: .issues)
        XCTAssertEqual(sorted.first?.name, "brand-new")
    }

    /// Case-insensitive, so `AlfreDo` files with the lowercase names rather
    /// than ahead of all of them. `alfred-…` precedes `AlfreDo` because `-`
    /// sorts before `o`, which is ordinary alphabetical order.
    func testSortByNameIsCaseInsensitive() throws {
        let sorted = RepoFilter.sorted(try repos(), by: .name)
        XCTAssertEqual(sorted.map(\.name), ["alfred-powerthesaurus", "AlfreDo", "brand-new"])
    }

    func testSearchIsCaseInsensitiveSubstring() throws {
        let result = RepoFilter.apply(to: try repos(), search: "POWER", sort: .downloads, changedOnly: false)
        XCTAssertEqual(result.map(\.name), ["alfred-powerthesaurus"])
    }

    func testSearchIgnoresSurroundingWhitespace() throws {
        let result = RepoFilter.apply(to: try repos(), search: "  alfredo  ", sort: .downloads, changedOnly: false)
        XCTAssertEqual(result.map(\.name), ["AlfreDo"])
    }

    func testChangedOnlyKeepsOnlyMovedCounts() throws {
        let result = RepoFilter.apply(to: try repos(), search: "", sort: .downloads, changedOnly: true)
        XCTAssertEqual(result.map(\.name), ["AlfreDo"])
    }

    /// The `--i` behaviour: zero-issue repos are dropped, not just sorted last.
    func testIssueQueueDropsZeroIssueRepos() throws {
        let queue = RepoFilter.issueQueue(try repos(), search: "")
        XCTAssertEqual(queue.map(\.name), ["brand-new", "alfred-powerthesaurus"])
    }

    func testIssueQueueRespectsSearch() throws {
        let queue = RepoFilter.issueQueue(try repos(), search: "power")
        XCTAssertEqual(queue.map(\.name), ["alfred-powerthesaurus"])
    }

    /// Downloads move in tens and stars in ones, so "biggest change" must not
    /// collapse into "biggest download change".
    func testBiggestChangeRanksByHowManyCountsMoved() throws {
        let manySmall = RepoStats(
            name: "many-small", url: "https://example.com/many-small",
            downloads: 10, issues: 2, stars: 6, forks: 3, watchers: 2,
            previous: Counts(downloads: 9, issues: 1, stars: 5, forks: 2, watchers: 1)
        )
        let oneBig = RepoStats(
            name: "one-big", url: "https://example.com/one-big",
            downloads: 5000, issues: 0, stars: 10, forks: 0, watchers: 0,
            previous: Counts(downloads: 4000, issues: 0, stars: 10, forks: 0, watchers: 0)
        )
        let sorted = RepoFilter.sorted([oneBig, manySmall], by: .recentChange)
        XCTAssertEqual(sorted.map(\.name), ["many-small", "one-big"])
    }
}

final class SeriesTests: XCTestCase {
    func testPointsAreParsedInOrder() throws {
        let points = try Fixtures.series().points(repo: "AlfreDo", metric: .downloads)
        XCTAssertEqual(points.map(\.value), [3270, 3280, 3294])
        XCTAssertTrue(points[0].date < points[1].date)
    }

    /// `null` marks a date before the repo existed; charting it as 0 would draw
    /// a cliff that never happened.
    func testGapsAreDroppedRatherThanZeroed() throws {
        let series = try Fixtures.series()
        let points = series.points(repo: "brand-new", metric: .downloads)
        XCTAssertEqual(points.count, 1)
        XCTAssertFalse(series.isChartable(repo: "brand-new", metric: .downloads))
        XCTAssertTrue(series.isChartable(repo: "AlfreDo", metric: .downloads))
    }

    func testUnknownRepoHasNoPoints() throws {
        XCTAssertTrue(try Fixtures.series().points(repo: "nope", metric: .stars).isEmpty)
    }

    /// Dates are parsed in UTC with a fixed locale — a phone in a non-Gregorian
    /// calendar or east of UTC must not shift a snapshot onto the wrong day.
    func testDatesParseIndependentlyOfDeviceLocale() throws {
        let series = try Fixtures.series()
        let points = series.points(repo: "AlfreDo", metric: .downloads)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(utc.component(.day, from: points[0].date), 12)
        XCTAssertEqual(utc.component(.month, from: points[0].date), 9)
    }
}
