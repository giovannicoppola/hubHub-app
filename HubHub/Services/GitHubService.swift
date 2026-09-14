import Foundation

/// Where the sync-mode data files live. Only used in `.sync`; direct
/// collection needs no repo at all.
struct GitHubConfig: Equatable, Codable {
    var owner: String
    var repo: String
    var branch: String
    var latestPath: String
    var seriesPath: String
    var workflowFile: String

    /// A private vault, not a public repo: `/user/repos` lists private
    /// repositories, so publishing the counts would publish their names.
    static let `default` = GitHubConfig(
        owner: "giovannicoppola",
        repo: "gitVault",
        branch: "main",
        latestPath: "gitVault-notes/hubhub/github-stats-latest.json",
        seriesPath: "gitVault-notes/hubhub/github-stats-series.json",
        workflowFile: "snapshot-stats.yml"
    )
}

/// The state of the snapshot Action, as far as the phone can see it.
struct WorkflowRun: Equatable {
    var id: Int
    /// `queued`, `in_progress`, `completed`.
    var status: String
    /// `success`, `failure`, … — only set once completed.
    var conclusion: String?
    var htmlURL: URL?
    var createdAt: Date?

    var isFinished: Bool { status == "completed" }
    var succeeded: Bool { conclusion == "success" }
}

/// Sync mode: read the two JSON files an Action wrote, and ask it to run again.
///
/// Read-only, so there are no shas to reconcile and nothing can conflict.
actor GitHubService {
    private let http: GitHubHTTP

    init(session: URLSession? = nil) {
        self.http = GitHubHTTP(session: session)
    }

    // MARK: - Reading data files

    /// Fetch a file's text.
    ///
    /// With a token this goes through the contents API with the `raw` media
    /// type, which — unlike the base64 JSON form — has no 1 MB ceiling. With no
    /// token it falls back to `raw.githubusercontent.com`, so a public data
    /// repo works before anything has been pasted.
    func fetchText(config: GitHubConfig, path: String, token: String) async throws -> String {
        let encoded = GitHubHTTP.encode(path)
        let request: URLRequest

        if token.isEmpty {
            guard let url = URL(
                string: "https://raw.githubusercontent.com/\(config.owner)/\(config.repo)/\(config.branch)/\(encoded)"
            ) else { throw GitHubError.badURL }
            request = http.request(url, token: "")
        } else {
            guard let url = URL(
                string: "\(GitHubHTTP.api)/repos/\(config.owner)/\(config.repo)/contents/\(encoded)?ref=\(config.branch)"
            ) else { throw GitHubError.badURL }
            request = http.request(url, token: token, accept: "application/vnd.github.raw")
        }

        let (data, _) = try await http.send(request, describing: path, authenticated: !token.isEmpty)
        guard let text = String(data: data, encoding: .utf8) else { throw GitHubError.decode(path) }
        return text
    }

    // MARK: - Running the snapshot Action

    /// Kick off the workflow. `workflow_dispatch` answers 204 with no body, so
    /// the run it started has to be found afterwards by polling.
    func dispatchSnapshot(config: GitHubConfig, token: String) async throws {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = URL(
            string: "\(GitHubHTTP.api)/repos/\(config.owner)/\(config.repo)/actions/workflows/\(config.workflowFile)/dispatches"
        ) else { throw GitHubError.badURL }

        let body = try JSONSerialization.data(withJSONObject: ["ref": config.branch])
        let request = http.request(url, token: token, method: "POST", body: body)
        try await http.send(request, describing: config.workflowFile, authenticated: true)
    }

    /// The most recent run of the snapshot workflow, if there is one.
    func latestRun(config: GitHubConfig, token: String) async throws -> WorkflowRun? {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = URL(
            string: "\(GitHubHTTP.api)/repos/\(config.owner)/\(config.repo)/actions/workflows/\(config.workflowFile)/runs?per_page=1"
        ) else { throw GitHubError.badURL }

        let json = try await http.object(url, token: token, describing: config.workflowFile)
        guard let runs = json["workflow_runs"] as? [[String: Any]],
              let run = runs.first,
              let id = run["id"] as? Int,
              let status = run["status"] as? String else {
            return nil
        }
        return WorkflowRun(
            id: id,
            status: status,
            conclusion: run["conclusion"] as? String,
            htmlURL: (run["html_url"] as? String).flatMap(URL.init(string:)),
            createdAt: (run["created_at"] as? String).flatMap(ISO8601DateFormatter().date(from:))
        )
    }
}
