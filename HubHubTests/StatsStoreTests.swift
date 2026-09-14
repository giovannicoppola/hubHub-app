import XCTest
@testable import HubHub

/// Answers GitHub requests from a table of path-suffix → response, so the store
/// can be exercised end to end without a network or a token.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var routes: [(match: String, status: Int, body: String)] = []
    nonisolated(unsafe) static private(set) var requestedURLs: [String] = []

    static func reset() {
        routes = []
        requestedURLs = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.requestedURLs.append(url)

        let route = Self.routes.first { url.contains($0.match) }
        let status = route?.status ?? 404
        let body = route?.body ?? #"{"message":"Not Found"}"#

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor
final class StatsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var cacheDirectory: URL!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        suiteName = "hubhub.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        cacheDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheDirectory)
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeStore() -> StatsStore {
        StatsStore(
            github: GitHubService(session: StubURLProtocol.session()),
            defaults: defaults,
            cacheDirectory: cacheDirectory
        )
    }

    func testRefreshLoadsAndSortsRepos() async {
        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        let store = makeStore()

        await store.refresh(force: true)

        XCTAssertEqual(store.status, .idle)
        XCTAssertEqual(store.latest.repos.count, 3)
        XCTAssertEqual(store.repos.first?.name, "AlfreDo")
        XCTAssertEqual(store.totals.downloads, 3996)
        XCTAssertEqual(store.totals.issues, 5)
    }

    /// With no token the read must go to raw.githubusercontent.com, so a fresh
    /// install against a public repo shows numbers before any setup.
    func testReadsWithoutATokenViaRaw() async {
        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        let store = makeStore()

        await store.refresh(force: true)

        XCTAssertFalse(store.hasToken)
        XCTAssertTrue(
            StubURLProtocol.requestedURLs.contains { $0.hasPrefix("https://raw.githubusercontent.com/") },
            "expected the unauthenticated path, got \(StubURLProtocol.requestedURLs)"
        )
    }

    func testRefreshSurvivesRelaunchFromCache() async {
        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        let first = makeStore()
        await first.refresh(force: true)
        XCTAssertEqual(first.latest.repos.count, 3)

        // Second launch, network refusing everything: the list still works.
        StubURLProtocol.routes = []
        let second = makeStore()
        XCTAssertEqual(second.latest.repos.count, 3, "cached snapshot should survive relaunch")
        XCTAssertEqual(second.repos.first?.name, "AlfreDo")
    }

    func testMissingFileReportsAUsableError() async {
        StubURLProtocol.routes = []
        let store = makeStore()

        await store.refresh(force: true)

        guard let message = store.status.errorMessage else {
            return XCTFail("expected a failure status, got \(store.status)")
        }
        XCTAssertTrue(message.contains("data/github-stats-latest.json"), message)
    }

    /// A corrupt or half-written file must not wipe out the good cached list.
    func testMalformedResponseKeepsTheCachedList() async {
        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        let store = makeStore()
        await store.refresh(force: true)

        StubURLProtocol.routes = [("github-stats-latest.json", 200, "<!DOCTYPE html><html>oops</html>")]
        await store.refresh(force: true)

        XCTAssertNotNil(store.status.errorMessage)
        XCTAssertEqual(store.latest.repos.count, 3, "a bad response must not blank the list")
    }

    func testRunSnapshotWithoutATokenAsksForOne() async {
        let store = makeStore()

        await store.runSnapshot()

        XCTAssertEqual(store.status.errorMessage, GitHubError.missingToken.localizedDescription)
    }

    func testMetricTogglesPersistAndKeepAtLeastOne() async {
        let store = makeStore()
        for metric in Metric.allCases { store.toggleMetric(metric) }

        XCTAssertEqual(store.visibleMetrics.count, 1, "the last metric must not be removable")

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.visibleMetrics, store.visibleMetrics)
    }

    func testSortPreferencePersists() async {
        let store = makeStore()
        store.setSort(.stars)
        XCTAssertEqual(makeStore().sort, .stars)
    }

    /// The workflow's "show only changed on launch" preference.
    func testChangedOnlyOnLaunchAppliesAtStartup() async {
        let store = makeStore()
        store.setChangedOnlyOnLaunch(true)

        let relaunched = makeStore()
        XCTAssertTrue(relaunched.changedOnly)

        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        await relaunched.refresh(force: true)
        XCTAssertEqual(relaunched.repos.map(\.name), ["AlfreDo"])
    }

    func testProvenanceNamesBothSnapshots() async {
        StubURLProtocol.routes = [("github-stats-latest.json", 200, Fixtures.latestJSON)]
        let store = makeStore()
        await store.refresh(force: true)

        XCTAssertEqual(store.provenance, "Snapshot 2026-09-14, compared to 2026-09-13")
    }

    /// A single snapshot has nothing to compare against, and the header must
    /// say so rather than implying the deltas are real.
    func testProvenanceCallsOutASingleSnapshot() async {
        let single = Fixtures.latestJSON.replacingOccurrences(of: #""previous": "2026-09-13""#, with: #""previous": "2026-09-14""#)
        StubURLProtocol.routes = [("github-stats-latest.json", 200, single)]
        let store = makeStore()
        await store.refresh(force: true)

        XCTAssertTrue(store.provenance.contains("no earlier snapshot"), store.provenance)
    }

    func testSeriesIsFetchedSeparatelyFromTheList() async {
        StubURLProtocol.routes = [
            ("github-stats-latest.json", 200, Fixtures.latestJSON),
            ("github-stats-series.json", 200, Fixtures.seriesJSON),
        ]
        let store = makeStore()

        await store.refresh(force: true)
        XCTAssertTrue(store.series.dates.isEmpty, "charts data should not be pulled on launch")

        await store.loadSeries()
        XCTAssertEqual(store.series.dates.count, 3)
        XCTAssertEqual(store.series.points(repo: "AlfreDo", metric: .downloads).count, 3)
    }
}
