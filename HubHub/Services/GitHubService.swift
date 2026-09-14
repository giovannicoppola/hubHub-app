import Foundation

struct GitHubConfig: Equatable, Codable {
    var owner: String
    var repo: String
    var branch: String
    var latestPath: String
    var seriesPath: String
    var workflowFile: String

    static let `default` = GitHubConfig(
        owner: "giovannicoppola",
        repo: "alfred-hubHub",
        branch: "main",
        latestPath: "data/github-stats-latest.json",
        seriesPath: "data/github-stats-series.json",
        workflowFile: "snapshot-stats.yml"
    )
}

enum GitHubError: LocalizedError, Equatable {
    case missingToken
    case badURL
    case notFound(String)
    case rateLimited
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add a GitHub personal access token in Settings to refresh."
        case .badURL:
            return "Invalid GitHub URL — check owner, repo and paths in Settings."
        case .notFound(let path):
            return "Not found on GitHub: \(path). Has the Action run yet?"
        case .rateLimited:
            return "GitHub rate limit reached. Add a token in Settings, or try again later."
        case .http(let code, let body):
            return "GitHub HTTP \(code): \(body)"
        case .decode(let what):
            return "Could not read \(what) — the file may still be being written."
        }
    }
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

/// Read-only against the data repo: the app pulls two JSON files and can ask
/// the Action to regenerate them. It never writes a file, so there is no
/// sha handling and nothing to conflict.
actor GitHubService {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // A cached response would hand back the stats from before the
            // Action ran, which is exactly what a refresh is trying to escape.
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Reading data files

    /// Fetch a file's text.
    ///
    /// With a token this goes through the contents API with the `raw` media
    /// type, which — unlike the base64 JSON form — has no 1 MB ceiling. With no
    /// token it falls back to `raw.githubusercontent.com`, so a fresh install
    /// against a public repo shows stats before you have pasted anything.
    func fetchText(config: GitHubConfig, path: String, token: String) async throws -> String {
        let url: URL?
        var request: URLRequest

        if token.isEmpty {
            url = URL(string: "https://raw.githubusercontent.com/\(config.owner)/\(config.repo)/\(config.branch)/\(Self.encode(path))")
            guard let url else { throw GitHubError.badURL }
            request = URLRequest(url: url)
        } else {
            url = URL(string: "\(Self.api)/repos/\(config.owner)/\(config.repo)/contents/\(Self.encode(path))?ref=\(config.branch)")
            guard let url else { throw GitHubError.badURL }
            request = URLRequest(url: url)
            Self.applyHeaders(to: &request, token: token)
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        }

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, path: path, headers: http)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitHubError.decode(path)
        }
        return text
    }

    // MARK: - Running the snapshot Action

    /// Kick off `snapshot-stats.yml` and return the run it started.
    ///
    /// `workflow_dispatch` answers 204 with no body, so the run has to be found
    /// afterwards by looking for one newer than the moment we asked.
    func dispatchSnapshot(config: GitHubConfig, token: String) async throws {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = URL(
            string: "\(Self.api)/repos/\(config.owner)/\(config.repo)/actions/workflows/\(config.workflowFile)/dispatches"
        ) else { throw GitHubError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        Self.applyHeaders(to: &request, token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ref": config.branch])

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, path: config.workflowFile, headers: http)
        }
    }

    /// The most recent run of the snapshot workflow, if there is one.
    func latestRun(config: GitHubConfig, token: String) async throws -> WorkflowRun? {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = URL(
            string: "\(Self.api)/repos/\(config.owner)/\(config.repo)/actions/workflows/\(config.workflowFile)/runs?per_page=1"
        ) else { throw GitHubError.badURL }

        var request = URLRequest(url: url)
        Self.applyHeaders(to: &request, token: token)

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, path: config.workflowFile, headers: http)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = json["workflow_runs"] as? [[String: Any]],
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

    // MARK: - Plumbing

    private static let api = "https://api.github.com"

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.decode("the response") }
        return (data, http)
    }

    private static func encode(_ path: String) -> String {
        path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    private static func applyHeaders(to request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    }

    private static func error(status: Int, data: Data, path: String, headers: HTTPURLResponse) -> GitHubError {
        let message = Self.message(from: data)
        switch status {
        case 404:
            return .notFound(path)
        case 401:
            return .http(401, "Bad or expired token — paste a new one in Settings.")
        case 403 where headers.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0", 429:
            return .rateLimited
        case 403:
            // Almost always the token missing Actions write, which reads very
            // differently from a generic 403.
            return .http(403, "\(message) (the token needs Actions: read and write to refresh)")
        default:
            return .http(status, message)
        }
    }

    /// GitHub's JSON `message`, falling back to a truncated body — the raw blob
    /// is unreadable in a status line on a phone.
    private static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}
