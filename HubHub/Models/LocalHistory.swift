import Foundation

/// Direct mode's history, kept on the device.
///
/// Deliberately the same shape as `github-stats-history.json` — dates mapping
/// to per-repo counts, plus the repo URLs — so a phone-collected history and an
/// Action-collected one are the same thing, and either can be imported into the
/// other.
///
/// Counts are stored as a sparse `metric → value` map rather than a `Counts`,
/// because an imported snapshot from before the Alfred workflow tracked all
/// five carries only downloads. A missing metric has to stay missing: padding
/// it with 0 draws a star count that "starts at zero" and jumps, which is a
/// cliff that never happened.
struct LocalHistory: Codable, Equatable {
    typealias SparseCounts = [String: Int]

    /// `yyyy-MM-dd` → repo name → metric raw value → count.
    var snapshots: [String: [String: SparseCounts]] = [:]
    var repoURLs: [String: String] = [:]
    var owner: String = ""

    static let empty = LocalHistory()

    var dates: [String] { snapshots.keys.sorted() }

    // MARK: - Recording

    mutating func record(_ snapshot: Snapshot, on date: String = LocalHistory.today()) {
        snapshots[date] = snapshot.counts.mapValues(Self.sparse)
        // Merge rather than replace: a repo skipped today keeps the URL it had.
        repoURLs.merge(snapshot.urls) { _, new in new }
        if !snapshot.owner.isEmpty { owner = snapshot.owner }
    }

    static func sparse(_ counts: Counts) -> SparseCounts {
        Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0.rawValue, counts[$0]) })
    }

    // MARK: - Derivation

    /// The two most recent snapshots, flattened — what the list renders.
    ///
    /// These are always complete (the app collected them), so a missing metric
    /// here reads as 0 rather than propagating an optional through every view.
    func latest() -> LatestStats {
        let dates = self.dates
        guard let currentKey = dates.last else { return .empty }
        let previousKey = dates.count > 1 ? dates[dates.count - 2] : currentKey
        let current = snapshots[currentKey] ?? [:]
        let previous = snapshots[previousKey] ?? [:]

        let repos = current.map { name, counts in
            RepoStats(
                name: name,
                url: repoURLs[name] ?? "https://github.com/\(owner)/\(name)",
                downloads: counts[Metric.downloads.rawValue] ?? 0,
                issues: counts[Metric.issues.rawValue] ?? 0,
                stars: counts[Metric.stars.rawValue] ?? 0,
                forks: counts[Metric.forks.rawValue] ?? 0,
                watchers: counts[Metric.watchers.rawValue] ?? 0,
                // Only when there really is an earlier snapshot: comparing the
                // first snapshot against itself would report every repo as
                // unchanged, which is a different claim from "nothing to
                // compare".
                previous: currentKey == previousKey ? nil : previous[name].map(Self.counts)
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

    static func counts(_ sparse: SparseCounts) -> Counts {
        Counts(
            downloads: sparse[Metric.downloads.rawValue] ?? 0,
            issues: sparse[Metric.issues.rawValue] ?? 0,
            stars: sparse[Metric.stars.rawValue] ?? 0,
            forks: sparse[Metric.forks.rawValue] ?? 0,
            watchers: sparse[Metric.watchers.rawValue] ?? 0
        )
    }

    /// The history columnar — what the charts read.
    ///
    /// Daily detail for a year, then one snapshot a month, so a four-year
    /// history is still a chart rather than a wall of pixels. The snapshots
    /// themselves are all kept; only what the chart plots is thinned.
    func series(asOf now: Date = Date()) -> StatsSeries {
        let dates = Self.thin(self.dates, asOf: now)
        let names = Set(snapshots.values.flatMap(\.keys)).sorted()

        var repos: [String: [String: [Int?]]] = [:]
        for name in names {
            var columns: [String: [Int?]] = [:]
            for metric in Metric.allCases {
                columns[metric.rawValue] = dates.map { snapshots[$0]?[name]?[metric.rawValue] }
            }
            // A repo that is zero on every count on every date is chart noise.
            if columns.values.contains(where: { $0.contains { ($0 ?? 0) != 0 } }) {
                repos[name] = columns
            }
        }
        return StatsSeries(dates: dates, repos: repos)
    }

    static let keepDailyDays = 365

    static func thin(_ dates: [String], asOf now: Date) -> [String] {
        var kept: [String] = []
        var monthsSeen: Set<String> = []
        for date in dates {
            guard let parsed = StatsSeries.dateParser.date(from: date) else {
                kept.append(date)
                continue
            }
            let age = Calendar.current.dateComponents([.day], from: parsed, to: now).day ?? 0
            if age <= keepDailyDays {
                kept.append(date)
            } else if monthsSeen.insert(String(date.prefix(7))).inserted {
                kept.append(date)
            }
        }
        return kept
    }

    // MARK: - Importing

    struct ImportSummary: Equatable {
        var added: Int
        var filled: Int
        var earliest: String
        var latest: String

        var description: String {
            guard added + filled > 0 else { return "Nothing new to import." }
            let dates = added == 1 ? "1 snapshot" : "\(added) snapshots"
            return "Imported \(dates), back to \(earliest)."
        }
    }

    /// Merge an Alfred `myGitHistory.json` in.
    ///
    /// A union, not a conversion: the file already has this shape, only with
    /// the workflow's `my`-prefixed key names. Existing entries win, so
    /// importing twice changes nothing the second time.
    mutating func merge(alfred json: [String: Any]) throws -> ImportSummary {
        var added = 0
        var filled = 0

        let dateKeys = json.keys.filter { $0 != "RepoURLs" && StatsSeries.dateParser.date(from: $0) != nil }
        guard !dateKeys.isEmpty else { throw ImportError.notAHistoryFile }

        for date in dateKeys.sorted() {
            guard let raw = json[date] as? [String: Any] else { continue }
            let snapshot = Self.cleaned(raw)
            guard !snapshot.isEmpty else { continue }

            if var existing = snapshots[date] {
                let before = existing.count
                for (name, counts) in snapshot where existing[name] == nil {
                    existing[name] = counts
                }
                if existing.count != before {
                    snapshots[date] = existing
                    filled += 1
                }
            } else {
                snapshots[date] = snapshot
                added += 1
            }
        }

        if let urls = json["RepoURLs"] as? [String: String] {
            for (name, url) in urls where repoURLs[name] == nil {
                repoURLs[name] = url
            }
        }

        let all = dates
        return ImportSummary(
            added: added,
            filled: filled,
            earliest: all.first ?? "",
            latest: all.last ?? ""
        )
    }

    /// Keep only recognised counts, and only where the workflow really recorded
    /// one. Very early versions stored a bare integer per repo, which cannot be
    /// placed on any particular metric and so is skipped rather than guessed at.
    private static func cleaned(_ snapshot: [String: Any]) -> [String: SparseCounts] {
        var result: [String: SparseCounts] = [:]
        for (name, value) in snapshot {
            guard let stats = value as? [String: Any] else { continue }
            var counts: SparseCounts = [:]
            for metric in Metric.allCases {
                if let number = stats[metric.alfredKey] as? Int {
                    counts[metric.rawValue] = number
                }
            }
            if !counts.isEmpty { result[name] = counts }
        }
        return result
    }

    enum ImportError: LocalizedError, Equatable {
        case notAHistoryFile
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notAHistoryFile:
                return "That file has no dated snapshots in it. Pick the workflow's myGitHistory.json."
            case .unreadable(let reason):
                return "Could not read that file: \(reason)"
            }
        }
    }

    // MARK: - Helpers

    static func today(_ now: Date = Date()) -> String {
        StatsSeries.dateParser.string(from: now)
    }
}

extension Metric {
    /// The key the Alfred workflow writes into `myGitHistory.json`.
    var alfredKey: String {
        switch self {
        case .downloads: return "myDownloads"
        case .issues: return "myIssues"
        case .stars: return "myStars"
        case .forks: return "myForks"
        case .watchers: return "myWatchers"
        }
    }
}
