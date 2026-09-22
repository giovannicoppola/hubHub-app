import Foundation

/// A made-up account, so the app can be seen working without a GitHub token.
///
/// App Review has no token to paste, and without one every screen is empty —
/// a Guideline 2.1 rejection. This ships in Release for that reason, and it is
/// labelled wherever it shows so it cannot be mistaken for someone's real
/// repositories. The repo names are invented: nothing here is a real account,
/// and none of the owner's private repositories can leak into a screenshot.
enum SampleData {
    private struct Repo {
        let name: String
        /// Counts on the most recent day.
        let today: Counts
        /// Rough growth per day, per metric, for walking the history back.
        let perDay: (downloads: Double, stars: Double, forks: Double, watchers: Double)
        /// How many days ago the repo was created; nothing before that.
        let age: Int
    }

    private static let repos: [Repo] = [
        Repo(name: "pocket-weather", today: Counts(downloads: 4_812, issues: 3, stars: 214, forks: 18, watchers: 9),
             perDay: (5.1, 0.22, 0.02, 0.01), age: 900),
        Repo(name: "tidy-clipboard", today: Counts(downloads: 2_947, issues: 1, stars: 131, forks: 11, watchers: 6),
             perDay: (3.4, 0.15, 0.01, 0.005), age: 700),
        Repo(name: "markdown-ledger", today: Counts(downloads: 1_588, issues: 5, stars: 97, forks: 14, watchers: 7),
             perDay: (2.2, 0.12, 0.02, 0.01), age: 540),
        Repo(name: "quiet-hours", today: Counts(downloads: 1_203, issues: 0, stars: 58, forks: 4, watchers: 3),
             perDay: (1.9, 0.08, 0.005, 0.003), age: 420),
        Repo(name: "habit-tally", today: Counts(downloads: 846, issues: 2, stars: 41, forks: 6, watchers: 4),
             perDay: (1.6, 0.07, 0.01, 0.005), age: 300),
        Repo(name: "trail-notes", today: Counts(downloads: 392, issues: 0, stars: 23, forks: 2, watchers: 2),
             perDay: (1.1, 0.06, 0.004, 0.003), age: 180),
        Repo(name: "dotfiles", today: Counts(downloads: 0, issues: 0, stars: 12, forks: 3, watchers: 1),
             perDay: (0, 0.02, 0.003, 0), age: 900),
        Repo(name: "recipe-scaler", today: Counts(downloads: 64, issues: 1, stars: 5, forks: 0, watchers: 1),
             perDay: (1.4, 0.05, 0, 0), age: 45),
    ]

    static let owner = "sample"

    /// A year and a bit of daily history, ending today. Deterministic, so the
    /// same screen looks the same on every launch and in every screenshot.
    static func history(asOf now: Date = Date()) -> LocalHistory {
        var history = LocalHistory.empty
        let calendar = Calendar(identifier: .gregorian)
        let days = 400
        let walks = repos.enumerated().map { walk($1, salt: $0, days: days) }

        for back in stride(from: days, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            var counts: [String: Counts] = [:]
            for (index, repo) in repos.enumerated() where back <= repo.age {
                counts[repo.name] = walks[index][back]
            }
            // Empty URLs: the sample repos do not exist, so the detail screen
            // shows no links rather than links to a 404.
            let urls = Dictionary(uniqueKeysWithValues: counts.keys.map { ($0, "") })
            history.record(Snapshot(counts: counts, urls: urls, owner: owner, skipped: []),
                           on: LocalHistory.today(date))
        }
        return history
    }

    /// One repo's counts for each day back from today, walked backwards from
    /// today's numbers. Each day takes off a varying amount around the repo's
    /// rate, so the lines are not rulers — but never a negative amount, so a
    /// download count never goes down, which a real one cannot.
    private static func walk(_ repo: Repo, salt: Int, days: Int) -> [Counts] {
        var result = [repo.today]
        var downloads = Double(repo.today.downloads)
        var stars = Double(repo.today.stars)
        var forks = Double(repo.today.forks)
        var watchers = Double(repo.today.watchers)

        for back in 1...days {
            // 0...1, repeating with a period no one will spot on a chart.
            let wobble = Double((back * 7 + salt * 13) % 11) / 10
            downloads = max(0, downloads - repo.perDay.downloads * (0.4 + 1.2 * wobble))
            stars = max(0, stars - repo.perDay.stars * (0.5 + wobble))
            forks = max(0, forks - repo.perDay.forks)
            watchers = max(0, watchers - repo.perDay.watchers)
            // Issues come and go rather than growing.
            let issues = max(0, repo.today.issues + (back / 9 + salt) % 3 - 1)
            result.append(Counts(
                downloads: Int(downloads.rounded()),
                issues: issues,
                stars: Int(stars.rounded()),
                forks: Int(forks.rounded()),
                watchers: Int(watchers.rounded())
            ))
        }
        return result
    }
}
