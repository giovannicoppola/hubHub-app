import Foundation
import Combine

enum SyncStatus: Equatable {
    case idle
    case loading
    /// The snapshot Action is running; the string is what to show the user.
    case running(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .running: return true
        case .idle, .failed: return false
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var progressMessage: String? {
        switch self {
        case .loading: return "Loading…"
        case .running(let message): return message
        case .idle, .failed: return nil
        }
    }
}

@MainActor
final class StatsStore: ObservableObject {
    // MARK: - Published state

    @Published private(set) var latest: LatestStats = .empty
    @Published private(set) var series: StatsSeries = .empty
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var hasToken = false
    @Published private(set) var lastRunURL: URL?

    @Published var selectedTab: AppTab = .repos
    @Published var search = ""

    @Published private(set) var visibleMetrics: Set<Metric> = [.downloads, .issues, .stars, .forks, .watchers]
    @Published private(set) var sort: SortOrder = .downloads
    @Published private(set) var changedOnly = false
    /// The workflow's "show only changed items on launch" preference.
    @Published private(set) var changedOnlyOnLaunch = false

    @Published var config: GitHubConfig {
        didSet {
            guard oldValue != config else { return }
            persistConfig()
        }
    }

    // MARK: - Private state

    private let github: GitHubService
    private let defaults: UserDefaults
    /// Injectable so tests never scribble over the real app's offline cache —
    /// the test bundle shares a container with the host app.
    private let cacheDirectory: URL?

    private var cachedToken: String?
    private var refreshTask: Task<Void, Never>?
    private var lastLatestFetch: Date?

    private let tokenAccount = "github_pat"

    private enum DefaultsKey {
        static let config = "gh_config"
        static let metrics = "visible_metrics"
        static let sort = "sort_order"
        static let changedOnlyOnLaunch = "changed_only_on_launch"
        static let lastFetch = "last_latest_fetch"
    }

    // MARK: - Init

    init(
        github: GitHubService = GitHubService(),
        defaults: UserDefaults = .standard,
        cacheDirectory: URL? = nil
    ) {
        self.github = github
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory

        if let data = defaults.data(forKey: DefaultsKey.config),
           let stored = try? JSONDecoder().decode(GitHubConfig.self, from: data) {
            self.config = stored
        } else {
            self.config = .default
        }

        if let raw = defaults.array(forKey: DefaultsKey.metrics) as? [String] {
            let restored = Set(raw.compactMap(Metric.init(rawValue:)))
            // An empty set would render rows with no numbers at all and look
            // like a bug; treat "none saved" as "all".
            self.visibleMetrics = restored.isEmpty ? Set(Metric.allCases) : restored
        }
        if let raw = defaults.string(forKey: DefaultsKey.sort), let stored = SortOrder(rawValue: raw) {
            self.sort = stored
        }
        self.changedOnlyOnLaunch = defaults.bool(forKey: DefaultsKey.changedOnlyOnLaunch)
        self.changedOnly = self.changedOnlyOnLaunch
        self.lastLatestFetch = defaults.object(forKey: DefaultsKey.lastFetch) as? Date

        self.cachedToken = KeychainHelper.load(account: tokenAccount)
        self.hasToken = !(cachedToken ?? "").isEmpty

        loadCache()
    }

    // MARK: - Derived lists

    var repos: [RepoStats] {
        RepoFilter.apply(to: latest.repos, search: search, sort: sort, changedOnly: changedOnly)
    }

    var issueQueue: [RepoStats] {
        RepoFilter.issueQueue(latest.repos, search: search)
    }

    var changedCount: Int {
        latest.repos.filter(\.hasChanged).count
    }

    var totals: Counts {
        latest.repos.reduce(into: Counts.zero) { total, repo in
            total.downloads += repo.downloads
            total.issues += repo.issues
            total.stars += repo.stars
            total.forks += repo.forks
            total.watchers += repo.watchers
        }
    }

    /// "Last updated on 2026-09-13, compared to 2026-09-12" — the workflow's
    /// subtitle, which is the only clue that a delta is a week old.
    var provenance: String {
        guard !latest.current.isEmpty else { return "No snapshot yet" }
        if latest.current == latest.previous {
            return "Snapshot \(latest.current) · no earlier snapshot to compare"
        }
        return "Snapshot \(latest.current), compared to \(latest.previous)"
    }

    var isStale: Bool {
        guard let date = StatsSeries.dateParser.date(from: latest.current) else { return false }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0 >= 2
    }

    // MARK: - Preferences

    func toggleMetric(_ metric: Metric) {
        var next = visibleMetrics
        if next.contains(metric) {
            // Never let the last one go: a row of bare repo names is useless.
            guard next.count > 1 else { return }
            next.remove(metric)
        } else {
            next.insert(metric)
        }
        visibleMetrics = next
        defaults.set(next.map(\.rawValue), forKey: DefaultsKey.metrics)
    }

    func setSort(_ order: SortOrder) {
        sort = order
        defaults.set(order.rawValue, forKey: DefaultsKey.sort)
    }

    func setChangedOnly(_ value: Bool) {
        changedOnly = value
    }

    func setChangedOnlyOnLaunch(_ value: Bool) {
        changedOnlyOnLaunch = value
        defaults.set(value, forKey: DefaultsKey.changedOnlyOnLaunch)
    }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainHelper.delete(account: tokenAccount)
            cachedToken = nil
            hasToken = false
            return true
        }
        let saved = KeychainHelper.save(account: tokenAccount, value: trimmed)
        if saved {
            cachedToken = trimmed
            hasToken = true
        }
        return saved
    }

    func dismissError() {
        if case .failed = status { status = .idle }
    }

    // MARK: - Loading

    /// Pull the latest snapshot file. Cheap (tens of KB) and safe to call on
    /// every launch; the Action is what actually recomputes the numbers.
    func refresh(force: Bool = false) async {
        if !force, let last = lastLatestFetch, Date().timeIntervalSince(last) < 1800, !latest.repos.isEmpty {
            return
        }
        guard !status.isBusy else { return }

        status = .loading
        do {
            let text = try await github.fetchText(config: config, path: config.latestPath, token: cachedToken ?? "")
            let decoded = try decode(LatestStats.self, from: text, describing: "the stats file")
            latest = decoded
            lastLatestFetch = Date()
            defaults.set(lastLatestFetch, forKey: DefaultsKey.lastFetch)
            writeCache(text, to: "latest.json")
            status = .idle
            // The chart data on disk is now a snapshot behind.
            if !series.dates.isEmpty, series.dates.last != decoded.current {
                await loadSeries(force: true)
            }
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// The chart data, fetched on first use rather than on launch — it is an
    /// order of magnitude bigger than the list data and most launches never
    /// open a chart.
    func loadSeries(force: Bool = false) async {
        if !force, !series.dates.isEmpty { return }
        do {
            let text = try await github.fetchText(config: config, path: config.seriesPath, token: cachedToken ?? "")
            series = try decode(StatsSeries.self, from: text, describing: "the history file")
            writeCache(text, to: "series.json")
        } catch {
            // A missing history file must not blank out a working list — the
            // detail view just shows no chart.
            status = .failed(message(for: error))
        }
    }

    /// Ask the Action to take a fresh snapshot, then wait for it and reload.
    func runSnapshot() async {
        guard hasToken, let token = cachedToken else {
            status = .failed(GitHubError.missingToken.localizedDescription)
            return
        }
        guard !status.isBusy else { return }

        status = .running("Starting the snapshot…")
        lastRunURL = nil
        do {
            let before = try? await github.latestRun(config: config, token: token)
            try await github.dispatchSnapshot(config: config, token: token)
            let finished = try await waitForRun(startedAfter: before, token: token)

            if let finished, !finished.succeeded {
                status = .failed("The snapshot Action failed (\(finished.conclusion ?? "no result")).")
                return
            }
            status = .loading
            await refresh(force: true)
            if case .idle = status, !series.dates.isEmpty {
                await loadSeries(force: true)
            }
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// Poll until the run we just asked for finishes.
    ///
    /// Returns `nil` if it is still going after the timeout — the run is fine,
    /// we just stop watching, and the next pull picks up the result.
    private func waitForRun(startedAfter previous: WorkflowRun?, token: String) async throws -> WorkflowRun? {
        let deadline = Date().addingTimeInterval(300)
        var seenNewRun = false

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return nil }

            guard let run = try? await github.latestRun(config: config, token: token) else { continue }

            // A dispatch takes a moment to show up; until it does, the run we
            // can see is the previous one and says nothing about ours.
            if !seenNewRun {
                if run.id == previous?.id { continue }
                seenNewRun = true
                lastRunURL = run.htmlURL
            }

            status = .running(run.isFinished ? "Snapshot finished, loading…" : "Snapshot running on GitHub…")
            if run.isFinished { return run }
        }
        return nil
    }

    // MARK: - Cache

    private static var defaultCacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("HubHub", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadCache() {
        if let text = readCache("latest.json"), let decoded = try? decode(LatestStats.self, from: text, describing: "cache") {
            latest = decoded
        }
        if let text = readCache("series.json"), let decoded = try? decode(StatsSeries.self, from: text, describing: "cache") {
            series = decoded
        }
    }

    private func readCache(_ name: String) -> String? {
        guard let url = cacheDirectory?.appendingPathComponent(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func writeCache(_ text: String, to name: String) {
        guard let url = cacheDirectory?.appendingPathComponent(name) else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from text: String, describing what: String) throws -> T {
        guard let data = text.data(using: .utf8) else { throw GitHubError.decode(what) }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.decode(what)
        }
    }

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: DefaultsKey.config)
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
