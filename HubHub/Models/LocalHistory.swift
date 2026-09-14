import Foundation

/// Direct mode's history, kept on the device.
///
/// Deliberately the same shape as `github-stats-history.json` — dates mapping
/// to per-repo counts, plus the repo URLs — so a phone-collected history and an
/// Action-collected one are the same thing, and either can be exported to the
/// other later.
struct LocalHistory: Codable, Equatable {
    /// `yyyy-MM-dd` → repo name → counts.
    var snapshots: [String: [String: Counts]] = [:]
    var repoURLs: [String: String] = [:]
    var owner: String = ""

    static let empty = LocalHistory()

    /// Daily detail for a year, then one snapshot a month — the same retention
    /// the Action uses, so a phone that has run for years stays small.
    static let keepDailyDays = 365

    var dates: [String] { snapshots.keys.sorted() }

    // MARK: - Recording

    mutating func record(_ snapshot: Snapshot, on date: String = LocalHistory.today()) {
        snapshots[date] = snapshot.counts
        // Merge rather than replace: a repo skipped today keeps the URL it had.
        repoURLs.merge(snapshot.urls) { _, new in new }
        if !snapshot.owner.isEmpty { owner = snapshot.owner }
        prune()
    }

    mutating func prune(asOf now: Date = Date()) {
        var keep: Set<String> = []
        var monthsSeen: Set<String> = []
        for date in dates {
            guard let parsed = StatsSeries.dateParser.date(from: date) else {
                // Not a date we understand — never throw away what we can't read.
                keep.insert(date)
                continue
            }
            let age = Calendar.current.dateComponents([.day], from: parsed, to: now).day ?? 0
            if age <= Self.keepDailyDays {
                keep.insert(date)
            } else if monthsSeen.insert(String(date.prefix(7))).inserted {
                keep.insert(date)
            }
        }
        snapshots = snapshots.filter { keep.contains($0.key) }
    }

    // MARK: - Derivation

    /// The two most recent snapshots, flattened — what the list renders.
    func latest() -> LatestStats {
        let dates = self.dates
        guard let currentKey = dates.last else { return .empty }
        let previousKey = dates.count > 1 ? dates[dates.count - 2] : currentKey
        let current = snapshots[currentKey] ?? [:]
        let previous = snapshots[previousKey] ?? [:]

        let repos = current
            .map { name, counts in
                RepoStats(
                    name: name,
                    url: repoURLs[name] ?? "https://github.com/\(owner)/\(name)",
                    downloads: counts.downloads,
                    issues: counts.issues,
                    stars: counts.stars,
                    forks: counts.forks,
                    watchers: counts.watchers,
                    // Only when there really is an earlier snapshot: comparing
                    // the first snapshot against itself would report every
                    // repo as unchanged, which is a different claim from
                    // "nothing to compare".
                    previous: currentKey == previousKey ? nil : previous[name]
                )
            }
        return LatestStats(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            owner: owner,
            current: currentKey,
            previous: previousKey,
            repos: RepoFilter.sorted(repos, by: .downloads)
        )
    }

    /// The whole history columnar — what the charts read.
    func series() -> StatsSeries {
        let dates = self.dates
        let names = Set(snapshots.values.flatMap(\.keys)).sorted()

        var repos: [String: [String: [Int?]]] = [:]
        for name in names {
            var columns: [String: [Int?]] = [:]
            for metric in Metric.allCases {
                columns[metric.rawValue] = dates.map { snapshots[$0]?[name]?[metric] }
            }
            // A repo that is zero on every count in every column is chart noise.
            if columns.values.contains(where: { $0.contains { ($0 ?? 0) != 0 } }) {
                repos[name] = columns
            }
        }
        return StatsSeries(dates: dates, repos: repos)
    }

    // MARK: - Helpers

    static func today(_ now: Date = Date()) -> String {
        StatsSeries.dateParser.string(from: now)
    }
}
