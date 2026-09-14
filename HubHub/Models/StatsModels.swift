import Foundation

/// The five counts the Alfred workflow tracks, in its own order.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case downloads
    case issues
    case stars
    case forks
    case watchers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downloads: return "Downloads"
        case .issues: return "Issues"
        case .stars: return "Stars"
        case .forks: return "Forks"
        case .watchers: return "Watchers"
        }
    }

    /// The workflow's emoji, so a row reads the same on both devices.
    var emoji: String {
        switch self {
        case .downloads: return "⬇️"
        case .issues: return "🚨"
        case .stars: return "⭐"
        case .forks: return "🌿"
        case .watchers: return "👀"
        }
    }

    var symbol: String {
        switch self {
        case .downloads: return "arrow.down.circle"
        case .issues: return "exclamationmark.triangle"
        case .stars: return "star"
        case .forks: return "tuningfork"
        case .watchers: return "eye"
        }
    }
}

/// One repo's five counts at a point in time.
struct Counts: Codable, Equatable, Hashable {
    var downloads: Int
    var issues: Int
    var stars: Int
    var forks: Int
    var watchers: Int

    static let zero = Counts(downloads: 0, issues: 0, stars: 0, forks: 0, watchers: 0)

    subscript(metric: Metric) -> Int {
        switch metric {
        case .downloads: return downloads
        case .issues: return issues
        case .stars: return stars
        case .forks: return forks
        case .watchers: return watchers
        }
    }
}

/// A repo as `github-stats-latest.json` writes it: today's counts flat, the
/// previous snapshot's counts nested.
struct RepoStats: Codable, Equatable, Identifiable, Hashable {
    var name: String
    var url: String
    var downloads: Int
    var issues: Int
    var stars: Int
    var forks: Int
    var watchers: Int
    var previous: Counts?

    var id: String { name }

    var counts: Counts {
        Counts(downloads: downloads, issues: issues, stars: stars, forks: forks, watchers: watchers)
    }

    var issuesURL: URL? { URL(string: url + "/issues") }
    var repoURL: URL? { URL(string: url) }

    func value(_ metric: Metric) -> Int { counts[metric] }

    /// `nil` on the first snapshot a repo appears in — no baseline is not the
    /// same as no change, and the row should not claim otherwise.
    func delta(_ metric: Metric) -> Int? {
        guard let previous else { return nil }
        return counts[metric] - previous[metric]
    }

    /// True when any tracked count moved — the workflow's `--c` filter.
    var hasChanged: Bool {
        guard let previous else { return false }
        return previous != counts
    }
}

struct LatestStats: Codable, Equatable {
    var generatedAt: String
    var owner: String
    /// Snapshot dates, `yyyy-MM-dd`.
    var current: String
    var previous: String
    var repos: [RepoStats]

    static let empty = LatestStats(generatedAt: "", owner: "", current: "", previous: "", repos: [])

    var generatedDate: Date? { ISO8601DateFormatter().date(from: generatedAt) }
}

/// `github-stats-series.json`: dates once, then one array per repo per metric
/// aligned to them. `nil` marks a date before the repo existed.
struct StatsSeries: Codable, Equatable {
    var dates: [String]
    var repos: [String: [String: [Int?]]]

    static let empty = StatsSeries(dates: [], repos: [:])

    struct Point: Identifiable, Equatable {
        var date: Date
        var value: Int
        var id: Date { date }
    }

    static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Charting points for one repo and metric, gaps dropped.
    func points(repo: String, metric: Metric) -> [Point] {
        guard let values = repos[repo]?[metric.rawValue] else { return [] }
        return zip(dates, values).compactMap { date, value in
            guard let value, let parsed = Self.dateParser.date(from: date) else { return nil }
            return Point(date: parsed, value: value)
        }
    }

    /// Whether this repo has enough history for a line rather than a dot.
    func isChartable(repo: String, metric: Metric) -> Bool {
        points(repo: repo, metric: metric).count > 1
    }
}

/// How the repo list is ordered. `.downloads` reproduces the workflow's
/// default (downloads, then issues as the tiebreak).
enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case downloads
    case issues
    case stars
    case forks
    case watchers
    case name
    case recentChange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downloads: return "Downloads"
        case .issues: return "Issues"
        case .stars: return "Stars"
        case .forks: return "Forks"
        case .watchers: return "Watchers"
        case .name: return "Name"
        case .recentChange: return "Biggest change"
        }
    }

    var metric: Metric? {
        switch self {
        case .downloads: return .downloads
        case .issues: return .issues
        case .stars: return .stars
        case .forks: return .forks
        case .watchers: return .watchers
        case .name, .recentChange: return nil
        }
    }
}

enum AppTab: String, Codable {
    case repos
    case issues
    case settings
}

/// Pure list shaping, kept out of the store so it can be tested without a
/// network, a Keychain or a cache directory.
enum RepoFilter {
    static func apply(
        to repos: [RepoStats],
        search: String,
        sort: SortOrder,
        changedOnly: Bool
    ) -> [RepoStats] {
        var result = repos

        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        if changedOnly {
            result = result.filter(\.hasChanged)
        }
        return sorted(result, by: sort)
    }

    /// The Issues tab: repos with open issues, most first — the `--i` tag.
    static func issueQueue(_ repos: [RepoStats], search: String) -> [RepoStats] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return repos
            .filter { $0.issues > 0 }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { ($0.issues, $0.downloads) > ($1.issues, $1.downloads) }
    }

    static func sorted(_ repos: [RepoStats], by sort: SortOrder) -> [RepoStats] {
        switch sort {
        case .name:
            return repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentChange:
            // Downloads move in tens while stars move in ones, so ranking by a
            // raw delta sum would only ever surface download changes. Rank by
            // how many counts moved first, and break ties on the download delta.
            return repos.sorted {
                let left = (changedMetricCount($0), abs($0.delta(.downloads) ?? 0), $0.downloads)
                let right = (changedMetricCount($1), abs($1.delta(.downloads) ?? 0), $1.downloads)
                return left > right
            }
        case .downloads, .issues, .stars, .forks, .watchers:
            guard let metric = sort.metric else { return repos }
            // Downloads then issues is the workflow's tiebreak; for the other
            // metrics downloads is the natural second key.
            return repos.sorted {
                ($0.value(metric), $0.downloads, $0.issues) > ($1.value(metric), $1.downloads, $1.issues)
            }
        }
    }

    private static func changedMetricCount(_ repo: RepoStats) -> Int {
        Metric.allCases.filter { (repo.delta($0) ?? 0) != 0 }.count
    }
}
