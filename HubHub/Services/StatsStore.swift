import Foundation
import Combine

/// Where the counts come from.
enum DataSource: String, CaseIterable, Identifiable, Codable {
    /// The phone collects from the GitHub API itself. No repo, no Action.
    case direct
    /// Read the files an Action committed to a repo.
    case sync

    var id: String { rawValue }

    /// The sources this build offers. Action mode needs `snapshot_stats.py`
    /// and a data repo that exist only in the owner's private vault, so a
    /// store build offering it would hand everyone else — App Review included —
    /// a 404 and the name of a private repo. It stays in Debug builds.
    static var available: [DataSource] {
        #if DEBUG
        return allCases
        #else
        return [.direct]
        #endif
    }

    var label: String { self == .direct ? "This phone" : "GitHub Action" }

    var explanation: String {
        switch self {
        case .direct:
            return "The phone reads the counts straight from the GitHub API and keeps the history here. Nothing to set up beyond a token."
        case .sync:
            return "Read the files a scheduled Action commits to a repo. Worth it for a large account, for snapshots that accrue while the app is closed, or to share one history with the Mac."
        }
    }
}

enum SyncStatus: Equatable {
    case idle
    case loading
    /// The snapshot Action is running; the string is what to show the user.
    case running(String)
    /// Direct collection, part way through the account's repos.
    case collecting(done: Int, total: Int)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .loading, .running, .collecting: return true
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
        case .collecting(let done, let total):
            return total > 0 ? "Reading repos… \(done) of \(total)" : "Reading repos…"
        case .idle, .failed: return nil
        }
    }

    var fraction: Double? {
        guard case .collecting(let done, let total) = self, total > 0 else { return nil }
        return Double(done) / Double(total)
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
    @Published private(set) var source: DataSource = .direct
    /// Repos the last direct collection could not read, so the list can say so
    /// rather than quietly showing fewer rows.
    @Published private(set) var skipped: [String] = []
    /// Showing `SampleData` instead of anyone's real repositories — for App
    /// Review, and for a first look before pasting a token.
    @Published private(set) var usingSample = false

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
    private let collector: StatsCollector
    private let defaults: UserDefaults
    /// Injectable so tests never scribble over the real app's offline cache —
    /// the test bundle shares a container with the host app.
    private let cacheDirectory: URL?

    private var cachedToken: String?
    private var lastLatestFetch: Date?
    /// The `generatedAt` of the stats file the cached series was built from.
    private var seriesStamp: String?
    /// Direct mode's history. Empty in sync mode, where the Action owns it.
    private var history: LocalHistory = .empty

    /// Injectable: the Keychain is process-wide, so tests that save a token
    /// would otherwise leak it into every suite that runs after them.
    private let tokenAccount: String

    private enum DefaultsKey {
        static let config = "gh_config"
        static let metrics = "visible_metrics"
        static let sort = "sort_order"
        static let changedOnlyOnLaunch = "changed_only_on_launch"
        static let lastFetch = "last_latest_fetch"
        static let source = "data_source"
        static let seriesStamp = "series_stamp"
        static let sample = "sample_data"
    }

    // MARK: - Init

    init(
        github: GitHubService = GitHubService(),
        collector: StatsCollector = StatsCollector(),
        defaults: UserDefaults = .standard,
        cacheDirectory: URL? = nil,
        tokenAccount: String = "github_pat"
    ) {
        self.github = github
        self.collector = collector
        self.defaults = defaults
        self.tokenAccount = tokenAccount
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory

        let storedConfig = defaults.data(forKey: DefaultsKey.config)
            .flatMap { try? JSONDecoder().decode(GitHubConfig.self, from: $0) }
        self.config = storedConfig ?? .default

        let wanted: DataSource
        if let raw = defaults.string(forKey: DefaultsKey.source), let stored = DataSource(rawValue: raw) {
            wanted = stored
        } else {
            // New installs collect on the phone — no repo, no Action, nothing
            // to set up. An install that already has a repo configured was set
            // up before direct mode existed and keeps working as it did.
            wanted = storedConfig == nil ? .direct : .sync
        }
        self.source = DataSource.available.contains(wanted) ? wanted : .direct
        self.usingSample = defaults.bool(forKey: DefaultsKey.sample)

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
        self.seriesStamp = defaults.string(forKey: DefaultsKey.seriesStamp)

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

    func setSource(_ value: DataSource) {
        guard value != source else { return }
        source = value
        defaults.set(value.rawValue, forKey: DefaultsKey.source)
        // The two modes keep separate histories; show what the new one has
        // rather than leaving the other mode's numbers on screen.
        loadCache()
    }

    func setUsingSample(_ value: Bool) {
        guard value != usingSample else { return }
        usingSample = value
        defaults.set(value, forKey: DefaultsKey.sample)
        if value { status = .idle }
        loadCache()
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
            // A real token means real numbers; leaving the sample up would put
            // made-up counts under a real account.
            setUsingSample(false)
        }
        return saved
    }

    /// Fold an Alfred `myGitHistory.json` into the local history.
    ///
    /// Direct mode only — in sync mode the Action's repo owns the history, and
    /// `import_alfred_history.py` does the same job there.
    @discardableResult
    func importAlfredHistory(from url: URL) -> String {
        guard !usingSample else {
            return "Turn off sample data first — the history would go under the sample's repos."
        }
        guard source == .direct else {
            return "Switch Source to “This phone” first — in Action mode the repo owns the history."
        }

        // A file handed over by the document picker lives outside the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LocalHistory.ImportError.notAHistoryFile
            }
            let summary = try history.merge(alfred: json)
            guard summary.added + summary.filled > 0 else { return summary.description }

            latest = history.latest()
            series = history.series()
            writeHistoryCache()
            return summary.description
        } catch {
            let message = message(for: error)
            status = .failed(message)
            return message
        }
    }

    func dismissError() {
        if case .failed = status { status = .idle }
    }

    // MARK: - Loading

    /// Bring the counts up to date, whichever way this install gets them.
    ///
    /// Direct collection is the expensive one — two requests per repo — so a
    /// launch only triggers it when there is no snapshot for today yet.
    func refresh(force: Bool = false) async {
        guard !status.isBusy, !usingSample else { return }
        if source == .direct {
            // A launch with no token has nothing to read, and the empty list
            // already says to add one — a red error on first launch is noise.
            // (Sync mode can still read a public data repo without one.)
            if !force, !hasToken { return }
            if !force, history.dates.last == LocalHistory.today(), !latest.repos.isEmpty { return }
            await collectOnDevice()
            return
        }
        if !force, let last = lastLatestFetch, Date().timeIntervalSince(last) < 1800, !latest.repos.isEmpty {
            return
        }
        await fetchFiles()
    }

    /// Direct mode: read the counts straight from the API and append today's
    /// snapshot to the on-device history.
    private func collectOnDevice() async {
        guard let token = cachedToken, !token.isEmpty else {
            status = .failed(GitHubError.missingToken.localizedDescription)
            return
        }

        status = .collecting(done: 0, total: 0)
        do {
            let snapshot = try await collector.collect(token: token) { [weak self] done, total in
                Task { @MainActor in
                    guard let self, case .collecting = self.status else { return }
                    self.status = .collecting(done: done, total: total)
                }
            }
            history.record(snapshot)
            skipped = snapshot.skipped
            latest = history.latest()
            series = history.series()
            writeHistoryCache()
            status = .idle
        } catch {
            // A failed collection leaves yesterday's history untouched, so the
            // list keeps working.
            status = .failed(message(for: error))
        }
    }

    private func fetchFiles() async {
        status = .loading
        do {
            let text = try await github.fetchText(config: config, path: config.latestPath, token: cachedToken ?? "")
            let decoded = try decode(LatestStats.self, from: text, describing: "the stats file")
            latest = decoded
            lastLatestFetch = Date()
            defaults.set(lastLatestFetch, forKey: DefaultsKey.lastFetch)
            writeCache(text, to: "latest.json")
            status = .idle
            // Refetch the charts whenever the stats file was regenerated —
            // not just when its newest date changes. Importing four years of
            // history rewrites the series while today's date stays today's
            // date, and comparing dates alone would never notice.
            if !series.dates.isEmpty, seriesStamp != decoded.generatedAt {
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
        // Direct mode derives the series from the local history; there is no
        // file to fetch.
        guard source == .sync else { return }
        if !force, !series.dates.isEmpty { return }
        do {
            let text = try await github.fetchText(config: config, path: config.seriesPath, token: cachedToken ?? "")
            series = try decode(StatsSeries.self, from: text, describing: "the history file")
            seriesStamp = latest.generatedAt
            defaults.set(seriesStamp, forKey: DefaultsKey.seriesStamp)
            writeCache(text, to: "series.json")
        } catch {
            // A missing history file must not blank out a working list — the
            // detail view just shows no chart.
            status = .failed(message(for: error))
        }
    }

    /// Ask the Action to take a fresh snapshot, then wait for it and reload.
    /// Sync mode only — in direct mode `refresh(force:)` is the equivalent.
    func runSnapshot() async {
        guard source == .sync else {
            await refresh(force: true)
            return
        }
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

    /// Each mode has its own cache on disk, so switching between them shows
    /// that mode's own history instead of the other's numbers under the wrong
    /// snapshot dates.
    private func loadCache() {
        if usingSample {
            history = SampleData.history()
            latest = history.latest()
            series = history.series()
            skipped = []
            return
        }
        switch source {
        case .direct:
            history = readCache("history.json")
                .flatMap { try? decode(LocalHistory.self, from: $0, describing: "cache") } ?? .empty
            latest = history.dates.isEmpty ? .empty : history.latest()
            series = history.dates.isEmpty ? .empty : history.series()
            skipped = []
        case .sync:
            latest = readCache("latest.json")
                .flatMap { try? decode(LatestStats.self, from: $0, describing: "cache") } ?? .empty
            series = readCache("series.json")
                .flatMap { try? decode(StatsSeries.self, from: $0, describing: "cache") } ?? .empty
            skipped = []
        }
    }

    private func writeHistoryCache() {
        guard let data = try? JSONEncoder().encode(history),
              let text = String(data: data, encoding: .utf8) else { return }
        writeCache(text, to: "history.json")
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
