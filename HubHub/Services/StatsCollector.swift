import Foundation

/// One collection run's result: the counts, and where each repo lives.
struct Snapshot: Equatable {
    var counts: [String: Counts]
    var urls: [String: String]
    /// The token's own login, so nothing has to be typed in Settings.
    var owner: String
    /// Repos that could not be read this time. They are left out of the
    /// snapshot rather than recorded as zero — a fabricated 0 would show up as
    /// a delta of -3,294 and then "recover" tomorrow.
    var skipped: [String]
}

/// Direct mode: collect the counts on the phone, with no repo and no Action.
///
/// This is the Swift port of `snapshot_stats.py`. It costs two requests per
/// repo, which is seconds for a normal account — the Action exists for large
/// ones, and for snapshots that accrue while the app is closed.
actor StatsCollector {
    /// GitHub's own guidance is to avoid many concurrent requests; this is
    /// enough to make 30 repos feel instant without tripping the secondary
    /// rate limit.
    private static let maxConcurrent = 6

    private let http: GitHubHTTP

    init(session: URLSession? = nil) {
        self.http = GitHubHTTP(session: session)
    }

    private struct RepoRef {
        var name: String
        var fullName: String
        var url: String
        var issues: Int
        var stars: Int
        var forks: Int
    }

    func collect(
        token: String,
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async throws -> Snapshot {
        guard !token.isEmpty else { throw GitHubError.missingToken }

        let owner = try await login(token: token)
        let repos = try await listRepos(token: token)
        guard !repos.isEmpty else {
            throw GitHubError.collectionFailed(collected: 0, total: 0, reason: "The token can see no repositories.")
        }

        var counts: [String: Counts] = [:]
        var urls: [String: String] = [:]
        var skipped: [String] = []
        var done = 0
        onProgress(0, repos.count)

        try await withThrowingTaskGroup(of: (RepoRef, Counts?).self) { group in
            var next = 0
            func addTask() {
                guard next < repos.count else { return }
                let repo = repos[next]
                next += 1
                group.addTask { [http] in
                    // Two extra calls per repo: releases for the download
                    // total, and the repo itself for subscribers_count.
                    async let downloads = Self.totalDownloads(repo.fullName, token: token, http: http)
                    async let watchers = Self.watchers(repo.fullName, token: token, http: http)
                    do {
                        return (repo, Counts(
                            downloads: try await downloads,
                            issues: repo.issues,
                            stars: repo.stars,
                            forks: repo.forks,
                            watchers: try await watchers
                        ))
                    } catch let error as GitHubError {
                        // A rate limit is not a per-repo problem; it will hit
                        // every remaining repo, so stop rather than "skip" 100.
                        if case .rateLimited = error { throw error }
                        return (repo, nil)
                    }
                }
            }

            for _ in 0..<min(Self.maxConcurrent, repos.count) { addTask() }

            while let (repo, result) = try await group.next() {
                if let result {
                    counts[repo.name] = result
                    urls[repo.name] = repo.url
                } else {
                    skipped.append(repo.name)
                }
                done += 1
                onProgress(done, repos.count)
                addTask()
            }
        }

        // A handful of failures on a flaky connection is survivable; losing a
        // quarter of the account means something systemic, and writing that to
        // history would corrupt every delta that follows.
        if skipped.count * 4 > repos.count {
            throw GitHubError.collectionFailed(
                collected: counts.count,
                total: repos.count,
                reason: "Check your connection and try again."
            )
        }

        return Snapshot(counts: counts, urls: urls, owner: owner, skipped: skipped.sorted())
    }

    // MARK: - Pieces

    private func login(token: String) async throws -> String {
        guard let url = URL(string: "\(GitHubHTTP.api)/user") else { throw GitHubError.badURL }
        let json = try await http.object(url, token: token, describing: "your account")
        return json["login"] as? String ?? ""
    }

    /// Every repo the token owns, paginated.
    private func listRepos(token: String) async throws -> [RepoRef] {
        guard let url = URL(string: "\(GitHubHTTP.api)/user/repos?per_page=100&affiliation=owner") else {
            throw GitHubError.badURL
        }
        let raw = try await http.paginate(url, token: token, describing: "your repositories")
        return raw.compactMap { repo in
            guard let name = repo["name"] as? String,
                  let fullName = repo["full_name"] as? String else { return nil }
            return RepoRef(
                name: name,
                fullName: fullName,
                url: repo["html_url"] as? String ?? "https://github.com/\(fullName)",
                issues: repo["open_issues_count"] as? Int ?? 0,
                stars: repo["stargazers_count"] as? Int ?? 0,
                forks: repo["forks_count"] as? Int ?? 0
            )
        }
    }

    /// Release asset downloads, across every release and every asset.
    ///
    /// The Alfred workflow counted `assets[0]` only, so a release with a .zip
    /// and a .dmg was undercounted.
    private static func totalDownloads(_ fullName: String, token: String, http: GitHubHTTP) async throws -> Int {
        guard let url = URL(string: "\(GitHubHTTP.api)/repos/\(fullName)/releases?per_page=100") else {
            throw GitHubError.badURL
        }
        let releases = try await http.paginate(url, token: token, describing: fullName)
        return releases.reduce(0) { total, release in
            let assets = release["assets"] as? [[String: Any]] ?? []
            return total + assets.reduce(0) { $0 + (($1["download_count"] as? Int) ?? 0) }
        }
    }

    /// `subscribers_count` — actual watchers, which the list endpoint omits.
    /// `watchers_count` there is an alias for stars, which is what made the
    /// workflow's watcher column wrong twice.
    private static func watchers(_ fullName: String, token: String, http: GitHubHTTP) async throws -> Int {
        guard let url = URL(string: "\(GitHubHTTP.api)/repos/\(fullName)") else { throw GitHubError.badURL }
        let json = try await http.object(url, token: token, describing: fullName)
        return json["subscribers_count"] as? Int ?? 0
    }
}
