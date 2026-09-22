import XCTest
@testable import HubHub

/// Serves the GitHub endpoints direct collection walks, so the collector can be
/// driven end to end without a network.
final class FakeGitHub: URLProtocol {
    struct Repo {
        var name: String
        var issues: Int
        var stars: Int
        var forks: Int
        var watchers: Int
        /// Download counts, one entry per release asset.
        var assets: [Int]
        var releasePages: Int = 1
    }

    nonisolated(unsafe) static var login = "octocat"
    nonisolated(unsafe) static var repos: [Repo] = []
    /// Repo names whose sub-requests should fail, and with what status.
    nonisolated(unsafe) static var failing: [String: Int] = [:]
    nonisolated(unsafe) static var repoPageSize = 100
    nonisolated(unsafe) static private(set) var requestCount = 0

    static func reset() {
        login = "octocat"
        repos = []
        failing = [:]
        repoPageSize = 100
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeGitHub.self]
        return URLSession(configuration: configuration)
    }

    override func startLoading() {
        Self.requestCount += 1
        let url = request.url!
        let path = url.path
        var status = 200
        var body: Any = [:]
        var headers: [String: String] = ["Content-Type": "application/json"]

        if path == "/user" {
            body = ["login": Self.login]
        } else if path == "/user/repos" {
            let page = Int(url.queryValue("page") ?? "1") ?? 1
            let chunks = Self.repos.chunked(into: Self.repoPageSize)
            let slice = page <= chunks.count ? chunks[page - 1] : []
            body = slice.map { repo -> [String: Any] in
                [
                    "name": repo.name,
                    "full_name": "\(Self.login)/\(repo.name)",
                    "html_url": "https://github.com/\(Self.login)/\(repo.name)",
                    "open_issues_count": repo.issues,
                    "stargazers_count": repo.stars,
                    "forks_count": repo.forks,
                ]
            }
            if page < chunks.count {
                var next = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                next.queryItems = (next.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(page + 1)")]
                headers["Link"] = "<\(next.url!.absoluteString)>; rel=\"next\""
            }
        } else if path.hasSuffix("/releases") {
            let name = url.pathComponents[3]
            if let failure = Self.failing[name] {
                status = failure
            } else if let repo = Self.repos.first(where: { $0.name == name }) {
                let page = Int(url.queryValue("page") ?? "1") ?? 1
                // Split the assets across pages so paging is really exercised.
                let perPage = max(1, repo.assets.count / max(1, repo.releasePages))
                let chunks = repo.assets.chunked(into: perPage)
                let slice = page <= chunks.count ? chunks[page - 1] : []
                body = slice.map { ["assets": [["download_count": $0]]] }
                if page < chunks.count {
                    var next = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    next.queryItems = (next.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(page + 1)")]
                    headers["Link"] = "<\(next.url!.absoluteString)>; rel=\"next\""
                }
            } else {
                body = []
            }
        } else if url.pathComponents.count == 4, path.hasPrefix("/repos/") {
            let name = url.pathComponents[3]
            if let failure = Self.failing[name] {
                status = failure
            } else if let repo = Self.repos.first(where: { $0.name == name }) {
                body = ["subscribers_count": repo.watchers]
            } else {
                status = 404
            }
        } else {
            status = 404
        }

        if status == 429 || (status == 403 && Self.failing.values.contains(403)) {
            headers["X-RateLimit-Remaining"] = "0"
        }
        if status != 200 {
            body = ["message": "boom"]
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

final class StatsCollectorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeGitHub.reset()
    }

    private func collector() -> StatsCollector {
        StatsCollector(session: FakeGitHub.session())
    }

    func testCollectsEveryCountForEveryRepo() async throws {
        FakeGitHub.repos = [
            .init(name: "alpha", issues: 2, stars: 10, forks: 1, watchers: 3, assets: [100, 50]),
            .init(name: "beta", issues: 0, stars: 4, forks: 0, watchers: 1, assets: []),
        ]

        let snapshot = try await collector().collect(token: "t") { _, _ in }

        XCTAssertEqual(snapshot.owner, "octocat")
        XCTAssertEqual(snapshot.counts.count, 2)
        XCTAssertEqual(snapshot.counts["alpha"], Counts(downloads: 150, issues: 2, stars: 10, forks: 1, watchers: 3))
        XCTAssertEqual(snapshot.counts["beta"], Counts(downloads: 0, issues: 0, stars: 4, forks: 0, watchers: 1))
        XCTAssertEqual(snapshot.urls["alpha"], "https://github.com/octocat/alpha")
        XCTAssertTrue(snapshot.skipped.isEmpty)
    }

    /// Every asset of every release, not `assets[0]` — the bug in the Alfred
    /// workflow, where a release with a .zip and a .dmg was undercounted.
    func testDownloadsSumEveryAssetAcrossEveryReleasePage() async throws {
        FakeGitHub.repos = [
            .init(name: "alpha", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [10, 20, 30, 40], releasePages: 2)
        ]

        let snapshot = try await collector().collect(token: "t") { _, _ in }

        XCTAssertEqual(snapshot.counts["alpha"]?.downloads, 100)
    }

    /// The workflow's other long-standing bug: `watchers_count` on the list
    /// endpoint is an alias for stars, so watchers must come from the repo.
    func testWatchersComeFromSubscribersNotStars() async throws {
        FakeGitHub.repos = [
            .init(name: "alpha", issues: 0, stars: 99, forks: 0, watchers: 2, assets: [])
        ]

        let snapshot = try await collector().collect(token: "t") { _, _ in }

        XCTAssertEqual(snapshot.counts["alpha"]?.stars, 99)
        XCTAssertEqual(snapshot.counts["alpha"]?.watchers, 2)
    }

    func testFollowsRepoPagination() async throws {
        FakeGitHub.repos = (1...25).map {
            .init(name: "repo\($0)", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [1])
        }
        FakeGitHub.repoPageSize = 10

        let snapshot = try await collector().collect(token: "t") { _, _ in }

        XCTAssertEqual(snapshot.counts.count, 25, "three pages of repos, not just the first")
    }

    func testReportsProgressUpToTheTotal() async throws {
        FakeGitHub.repos = (1...8).map {
            .init(name: "repo\($0)", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [1])
        }

        let box = ProgressBox()
        _ = try await collector().collect(token: "t") { done, total in box.record(done, total) }

        XCTAssertEqual(box.lastTotal, 8)
        XCTAssertEqual(box.lastDone, 8)
        XCTAssertTrue(box.isMonotonic, "progress went backwards: \(box.dones)")
    }

    /// One unreadable repo is left out rather than written down as zero: a
    /// fabricated 0 would show as a delta of -3,294 and "recover" tomorrow.
    func testAFailingRepoIsSkippedNotZeroed() async throws {
        FakeGitHub.repos = (1...10).map {
            .init(name: "repo\($0)", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [5])
        }
        FakeGitHub.failing = ["repo3": 500]

        let snapshot = try await collector().collect(token: "t") { _, _ in }

        XCTAssertEqual(snapshot.skipped, ["repo3"])
        XCTAssertNil(snapshot.counts["repo3"], "must not be recorded as zero")
        XCTAssertEqual(snapshot.counts.count, 9)
    }

    /// Losing a quarter of the account is systemic, and writing it to history
    /// would corrupt every delta after it.
    func testTooManyFailuresAbortsRatherThanSavingAPartialSnapshot() async {
        FakeGitHub.repos = (1...8).map {
            .init(name: "repo\($0)", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [1])
        }
        FakeGitHub.failing = Dictionary(uniqueKeysWithValues: (1...5).map { ("repo\($0)", 500) })

        do {
            _ = try await collector().collect(token: "t") { _, _ in }
            XCTFail("expected the collection to abort")
        } catch let error as GitHubError {
            guard case .collectionFailed(let collected, let total, _) = error else {
                return XCTFail("expected collectionFailed, got \(error)")
            }
            XCTAssertEqual(collected, 3)
            XCTAssertEqual(total, 8)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNoTokenIsRefusedBeforeAnyRequest() async {
        do {
            _ = try await collector().collect(token: "") { _, _ in }
            XCTFail("expected missingToken")
        } catch {
            XCTAssertEqual(error as? GitHubError, .missingToken)
            XCTAssertEqual(FakeGitHub.requestCount, 0)
        }
    }
}

/// Collects progress callbacks, which arrive off the main actor.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var dones: [Int] = []
    private(set) var lastTotal = 0

    func record(_ done: Int, _ total: Int) {
        lock.lock()
        defer { lock.unlock() }
        dones.append(done)
        lastTotal = total
    }

    var lastDone: Int { lock.withLock { dones.last ?? -1 } }
    var isMonotonic: Bool { lock.withLock { zip(dones, dones.dropFirst()).allSatisfy { $0 <= $1 } } }
}

final class LocalHistoryTests: XCTestCase {
    private func snapshot(_ downloads: Int, stars: Int = 1, name: String = "alpha") -> Snapshot {
        Snapshot(
            counts: [name: Counts(downloads: downloads, issues: 0, stars: stars, forks: 0, watchers: 0)],
            urls: [name: "https://github.com/octocat/\(name)"],
            owner: "octocat",
            skipped: []
        )
    }

    func testRecordingTwoDaysProducesADelta() {
        var history = LocalHistory.empty
        history.record(snapshot(100), on: "2026-09-13")
        history.record(snapshot(120), on: "2026-09-14")

        let latest = history.latest()
        XCTAssertEqual(latest.current, "2026-09-14")
        XCTAssertEqual(latest.previous, "2026-09-13")
        XCTAssertEqual(latest.repos.first?.delta(.downloads), 20)
    }

    /// One snapshot has nothing to compare against, and must not claim the
    /// repo is unchanged.
    func testASingleSnapshotHasNoDeltas() {
        var history = LocalHistory.empty
        history.record(snapshot(100), on: "2026-09-14")

        let repo = history.latest().repos.first
        XCTAssertNotNil(repo)
        XCTAssertNil(repo?.previous)
        XCTAssertNil(repo?.delta(.downloads))
        XCTAssertFalse(repo?.hasChanged ?? true)
    }

    func testSeriesIsAlignedToTheDates() {
        var history = LocalHistory.empty
        history.record(snapshot(100), on: "2026-09-12")
        history.record(snapshot(110), on: "2026-09-13")
        history.record(snapshot(120), on: "2026-09-14")

        let series = history.series()
        XCTAssertEqual(series.dates, ["2026-09-12", "2026-09-13", "2026-09-14"])
        XCTAssertEqual(series.points(repo: "alpha", metric: .downloads).map(\.value), [100, 110, 120])
    }

    /// A repo that appears later leaves a gap, not a zero.
    func testARepoAddedLaterHasAGapNotAZero() {
        var history = LocalHistory.empty
        history.record(snapshot(100), on: "2026-09-13")
        history.record(snapshot(5, name: "beta"), on: "2026-09-14")

        let series = history.series()
        XCTAssertEqual(series.repos["beta"]?["downloads"] ?? [], [nil, 5])
        XCTAssertEqual(series.points(repo: "beta", metric: .downloads).count, 1)
    }

    func testSurvivesARoundTripThroughJSON() throws {
        var history = LocalHistory.empty
        history.record(snapshot(100), on: "2026-09-13")
        history.record(snapshot(120), on: "2026-09-14")

        let data = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode(LocalHistory.self, from: data)

        XCTAssertEqual(restored, history)
        XCTAssertEqual(restored.latest().repos.first?.delta(.downloads), 20)
    }

    /// A repo skipped today keeps the URL it was recorded with.
    func testURLsAreMergedNotReplaced() {
        var history = LocalHistory.empty
        history.record(snapshot(100, name: "alpha"), on: "2026-09-13")
        history.record(snapshot(5, name: "beta"), on: "2026-09-14")

        XCTAssertEqual(history.repoURLs["alpha"], "https://github.com/octocat/alpha")
        XCTAssertEqual(history.repoURLs["beta"], "https://github.com/octocat/beta")
    }
}


/// The store in direct mode: no repo, no Action, history kept on the device.
@MainActor
final class DirectModeStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var cacheDirectory: URL!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        FakeGitHub.reset()
        suiteName = "hubhub.direct.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainHelper.delete(account: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
        FakeGitHub.reset()
        try await super.tearDown()
    }

    private func makeStore() -> StatsStore {
        StatsStore(
            github: GitHubService(session: FakeGitHub.session()),
            collector: StatsCollector(session: FakeGitHub.session()),
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            tokenAccount: suiteName
        )
    }

    private func withToken(_ store: StatsStore) -> StatsStore {
        store.saveToken("ghp_test")
        return store
    }

    /// A fresh install has no repo configured, so it collects on the phone.
    func testAFreshInstallDefaultsToDirect() {
        XCTAssertEqual(makeStore().source, .direct)
    }

    /// An install that already had a data repo predates direct mode, and must
    /// keep working the way its owner set it up.
    func testAnExistingSyncInstallIsLeftInSyncMode() throws {
        let config = GitHubConfig.default
        defaults.set(try JSONEncoder().encode(config), forKey: "gh_config")

        XCTAssertEqual(makeStore().source, .sync)
    }

    func testRefreshCollectsAndBuildsTheList() async {
        FakeGitHub.repos = [
            .init(name: "alpha", issues: 1, stars: 10, forks: 2, watchers: 3, assets: [200]),
            .init(name: "beta", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [5]),
        ]
        let store = withToken(makeStore())

        await store.refresh(force: true)

        XCTAssertEqual(store.status, .idle)
        XCTAssertEqual(store.latest.repos.count, 2)
        XCTAssertEqual(store.repos.first?.name, "alpha", "sorted by downloads")
        XCTAssertEqual(store.totals.downloads, 205)
        XCTAssertEqual(store.latest.owner, "octocat")
    }

    /// Charts come from the local history, with no second file to fetch.
    func testSeriesComesFromTheLocalHistory() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [10])]
        let store = withToken(makeStore())

        await store.refresh(force: true)

        XCTAssertEqual(store.series.dates.count, 1)
        XCTAssertEqual(store.series.points(repo: "alpha", metric: .downloads).map(\.value), [10])
    }

    func testHistorySurvivesRelaunch() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [10])]
        let first = withToken(makeStore())
        await first.refresh(force: true)
        XCTAssertEqual(first.latest.repos.count, 1)

        // Second launch with the network refusing everything.
        FakeGitHub.repos = []
        let second = makeStore()
        XCTAssertEqual(second.latest.repos.count, 1, "the cached history should come back")
        XCTAssertEqual(second.latest.repos.first?.downloads, 10)
    }

    /// Two requests per repo is not something to do on every launch.
    func testASecondLaunchTheSameDayDoesNotRecollect() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [10])]
        let first = withToken(makeStore())
        await first.refresh(force: true)

        let before = FakeGitHub.requestCount
        let second = makeStore()
        await second.refresh()

        XCTAssertEqual(FakeGitHub.requestCount, before, "today's snapshot is already collected")
        XCTAssertEqual(second.latest.repos.count, 1)
    }

    func testDirectModeWithoutATokenAsksForOne() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [])]
        let store = makeStore()

        await store.refresh(force: true)

        XCTAssertEqual(store.status.errorMessage, GitHubError.missingToken.localizedDescription)
    }

    /// A collection that blows up must leave yesterday's numbers on screen.
    func testAFailedCollectionKeepsTheExistingList() async {
        FakeGitHub.repos = (1...4).map {
            .init(name: "repo\($0)", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [1])
        }
        let store = withToken(makeStore())
        await store.refresh(force: true)
        XCTAssertEqual(store.latest.repos.count, 4)

        FakeGitHub.failing = Dictionary(uniqueKeysWithValues: (1...4).map { ("repo\($0)", 500) })
        await store.refresh(force: true)

        XCTAssertNotNil(store.status.errorMessage)
        XCTAssertEqual(store.latest.repos.count, 4, "the previous snapshot is still shown")
    }

    /// Skipped repos are reported rather than silently thinning the list.
    func testSkippedReposAreSurfaced() async {
        FakeGitHub.repos = (1...10).map {
            .init(name: "repo\($0)", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [1])
        }
        FakeGitHub.failing = ["repo7": 500]
        let store = withToken(makeStore())

        await store.refresh(force: true)

        XCTAssertEqual(store.skipped, ["repo7"])
        XCTAssertEqual(store.latest.repos.count, 9)
    }

    /// Switching modes must not show one mode's numbers under the other's dates.
    func testSwitchingModesSwapsTheHistory() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 1, forks: 0, watchers: 0, assets: [10])]
        let store = withToken(makeStore())
        await store.refresh(force: true)
        XCTAssertEqual(store.latest.repos.count, 1)

        store.setSource(.sync)
        XCTAssertTrue(store.latest.repos.isEmpty, "sync mode has no cached file here")

        store.setSource(.direct)
        XCTAssertEqual(store.latest.repos.count, 1, "the local history comes back")
    }
}


/// Importing the Alfred workflow's own history file.
final class AlfredImportTests: XCTestCase {
    /// The real file's shape: dates → repo → my-prefixed counts, plus RepoURLs.
    /// Pre-2022-12 snapshots carry only myDownloads, which is the whole reason
    /// the history stores counts sparsely.
    private let alfred: [String: Any] = [
        "2022-05-04": ["alpha": ["myDownloads": 71]],
        "2022-06-01": ["alpha": ["myDownloads": 100]],
        "2022-12-01": ["alpha": ["myDownloads": 321, "myIssues": 1, "myStars": 25, "myForks": 2, "myWatchers": 3]],
        "RepoURLs": ["alpha": "https://github.com/octocat/alpha"],
    ]

    func testImportsEveryDatedSnapshot() throws {
        var history = LocalHistory.empty
        let summary = try history.merge(alfred: alfred)

        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(history.dates, ["2022-05-04", "2022-06-01", "2022-12-01"])
        XCTAssertEqual(history.repoURLs["alpha"], "https://github.com/octocat/alpha")
    }

    /// The point of the sparse storage: downloads exist from May, stars do not,
    /// and the chart must show a gap rather than a star count of 0 that jumps.
    func testDownloadsOnlySnapshotsKeepStarsUnknown() throws {
        var history = LocalHistory.empty
        _ = try history.merge(alfred: alfred)

        let series = history.series(asOf: StatsSeries.dateParser.date(from: "2022-12-02")!)
        XCTAssertEqual(series.repos["alpha"]?["downloads"] ?? [], [71, 100, 321])
        XCTAssertEqual(series.repos["alpha"]?["stars"] ?? [], [nil, nil, 25])

        XCTAssertEqual(series.points(repo: "alpha", metric: .downloads).count, 3)
        XCTAssertEqual(series.points(repo: "alpha", metric: .stars).count, 1, "stars start when they were first tracked")
    }

    func testImportingTwiceChangesNothing() throws {
        var history = LocalHistory.empty
        _ = try history.merge(alfred: alfred)
        let after = history

        let summary = try history.merge(alfred: alfred)

        XCTAssertEqual(summary.added, 0)
        XCTAssertEqual(summary.filled, 0)
        XCTAssertEqual(history, after)
    }

    /// A snapshot the app already collected wins; the import only fills gaps.
    func testCollectedSnapshotsAreNotOverwritten() throws {
        var history = LocalHistory.empty
        history.record(
            Snapshot(
                counts: ["alpha": Counts(downloads: 999, issues: 0, stars: 0, forks: 0, watchers: 0)],
                urls: ["alpha": "https://github.com/octocat/alpha"],
                owner: "octocat",
                skipped: []
            ),
            on: "2022-12-01"
        )

        _ = try history.merge(alfred: alfred)

        XCTAssertEqual(history.snapshots["2022-12-01"]?["alpha"]?["downloads"], 999, "the app's own snapshot stands")
        XCTAssertEqual(history.snapshots["2022-05-04"]?["alpha"]?["downloads"], 71, "older dates still imported")
    }

    /// The import fills a date the app has, when it knows repos the app missed.
    func testImportFillsMissingReposOnASharedDate() throws {
        var history = LocalHistory.empty
        history.record(
            Snapshot(
                counts: ["beta": Counts(downloads: 5, issues: 0, stars: 0, forks: 0, watchers: 0)],
                urls: [:], owner: "octocat", skipped: []
            ),
            on: "2022-12-01"
        )

        let summary = try history.merge(alfred: alfred)

        XCTAssertEqual(summary.filled, 1)
        XCTAssertEqual(history.snapshots["2022-12-01"]?.count, 2)
        XCTAssertEqual(history.snapshots["2022-12-01"]?["alpha"]?["stars"], 25)
    }

    /// Early workflow versions stored a bare integer per repo, which cannot be
    /// attributed to a metric.
    func testRowsThatAreNotCountsAreSkippedNotGuessed() throws {
        var history = LocalHistory.empty
        _ = try history.merge(alfred: [
            "2022-05-04": ["alpha": 71, "beta": ["myDownloads": 3]],
        ])

        XCTAssertNil(history.snapshots["2022-05-04"]?["alpha"])
        XCTAssertEqual(history.snapshots["2022-05-04"]?["beta"]?["downloads"], 3)
    }

    func testAFileWithNoSnapshotsIsRejected() {
        var history = LocalHistory.empty
        XCTAssertThrowsError(try history.merge(alfred: ["hello": "world"])) { error in
            XCTAssertEqual(error as? LocalHistory.ImportError, .notAHistoryFile)
        }
    }

    /// A four-year import charts at monthly resolution beyond the last year,
    /// while every snapshot is still kept.
    func testLongHistoryIsThinnedForChartingButNotDiscarded() throws {
        var history = LocalHistory.empty
        let now = StatsSeries.dateParser.date(from: "2026-09-14")!
        let calendar = Calendar.current
        var payload: [String: Any] = [:]
        for back in stride(from: 1600, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -back, to: now)!
            payload[StatsSeries.dateParser.string(from: day)] = ["alpha": ["myDownloads": 1600 - back]]
        }
        _ = try history.merge(alfred: payload)

        XCTAssertEqual(history.dates.count, 1601, "every snapshot is kept")

        let charted = history.series(asOf: now).dates
        XCTAssertLessThan(charted.count, 450, "but the chart is thinned")
        XCTAssertGreaterThan(charted.count, 365)
        XCTAssertEqual(charted.last, "2026-09-14")

        let old = charted.filter { $0 < "2025-09-14" }
        XCTAssertEqual(Set(old.map { $0.prefix(7) }).count, old.count, "one point per month before the daily window")
    }
}


/// Sample data: what App Review sees, since it has no GitHub token to paste.
@MainActor
final class SampleDataTests: XCTestCase {
    private var defaults: UserDefaults!
    private var cacheDirectory: URL!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        FakeGitHub.reset()
        suiteName = "hubhub.sample.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainHelper.delete(account: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
        FakeGitHub.reset()
        try await super.tearDown()
    }

    private func makeStore() -> StatsStore {
        StatsStore(
            github: GitHubService(session: FakeGitHub.session()),
            collector: StatsCollector(session: FakeGitHub.session()),
            defaults: defaults,
            cacheDirectory: cacheDirectory,
            tokenAccount: suiteName
        )
    }

    /// Every screen a reviewer can reach has something on it: rows, deltas,
    /// the Issues tab, the "changed only" filter, and a chart.
    func testSampleFillsEveryScreen() throws {
        let store = makeStore()
        store.setUsingSample(true)

        XCTAssertGreaterThanOrEqual(store.latest.repos.count, 6)
        XCTAssertFalse(store.issueQueue.isEmpty, "the Issues tab needs rows")
        XCTAssertGreaterThan(store.changedCount, 0, "something should have moved today")
        XCTAssertLessThan(store.changedCount, store.latest.repos.count, "and something should not have")
        XCTAssertNotEqual(store.latest.current, store.latest.previous, "deltas need two snapshots")

        let top = try XCTUnwrap(store.repos.first)
        let points = store.series.points(repo: top.name, metric: .downloads)
        XCTAssertGreaterThan(points.count, 100, "a chart, not a dot")
        XCTAssertEqual(points.last?.value, top.downloads, "the chart ends on the row's count")
    }

    /// The sample repos do not exist; linking them would open a 404.
    func testSampleReposHaveNoLinks() throws {
        let store = makeStore()
        store.setUsingSample(true)
        let repo = try XCTUnwrap(store.latest.repos.first)
        XCTAssertNil(repo.repoURL)
        XCTAssertNil(repo.issuesURL)
    }

    /// Nothing reaches the network, and a sample never turns into history.
    func testRefreshDoesNothingWhileShowingTheSample() async {
        FakeGitHub.repos = [.init(name: "alpha", issues: 0, stars: 0, forks: 0, watchers: 0, assets: [])]
        let store = makeStore()
        store.saveToken("ghp_test")
        store.setUsingSample(true)

        await store.refresh(force: true)

        XCTAssertEqual(FakeGitHub.requestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent("history.json").path))
    }

    func testTheSampleSurvivesARelaunch() {
        makeStore().setUsingSample(true)
        let relaunched = makeStore()
        XCTAssertTrue(relaunched.usingSample)
        XCTAssertFalse(relaunched.latest.repos.isEmpty)
    }

    /// A real token means real numbers — made-up counts must not linger
    /// under a real account.
    func testSavingATokenTurnsTheSampleOff() {
        let store = makeStore()
        store.setUsingSample(true)
        store.saveToken("ghp_test")

        XCTAssertFalse(store.usingSample)
        XCTAssertTrue(store.latest.repos.isEmpty, "the real (empty) history, not the sample")
    }

    /// First launch with no token: the empty list says what to do, and there
    /// is no red error bar on top of it.
    func testFirstLaunchWithoutATokenShowsNoError() async {
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.status, .idle)
    }
}

extension SampleDataTests {
    /// A download count cannot go down; a sample chart that does looks broken.
    func testSampleDownloadsNeverDecrease() {
        let history = SampleData.history()
        for name in Set(history.snapshots.values.flatMap(\.keys)) {
            let values = history.dates.compactMap { history.snapshots[$0]?[name]?[Metric.downloads.rawValue] }
            XCTAssertEqual(values, values.sorted(), "\(name) downloads went down")
        }
    }
}
