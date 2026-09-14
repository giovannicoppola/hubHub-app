import Foundation

enum GitHubError: LocalizedError, Equatable {
    case missingToken
    case badURL
    case notFound(path: String, authenticated: Bool)
    case rateLimited(resetsAt: Date?)
    case http(Int, String)
    case decode(String)
    /// Too much of a collection failed to trust the result.
    case collectionFailed(collected: Int, total: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add a GitHub personal access token in Settings."
        case .badURL:
            return "Invalid GitHub URL — check the settings."
        case .notFound(let path, let authenticated):
            // Unauthenticated, a private data repo is indistinguishable from a
            // missing file, and "has the Action run?" sends you hunting in the
            // wrong place. Name both possibilities.
            return authenticated
                ? "Not found on GitHub: \(path). Has the Action run yet?"
                : "Not found: \(path). Add a token in Settings if the data repo is private."
        case .rateLimited(let resetsAt):
            guard let resetsAt else {
                return "GitHub rate limit reached. Try again shortly."
            }
            let time = resetsAt.formatted(date: .omitted, time: .shortened)
            return "GitHub rate limit reached. It resets at \(time)."
        case .http(let code, let body):
            return "GitHub HTTP \(code): \(body)"
        case .decode(let what):
            return "Could not read \(what) — the file may still be being written."
        case .collectionFailed(let collected, let total, let reason):
            return "Only \(collected) of \(total) repos could be read, so no snapshot was saved. \(reason)"
        }
    }
}

/// Shared plumbing for every GitHub call the app makes: headers, paging, and
/// turning a status code into something a person can act on.
///
/// Both the sync path (reading files the Action wrote) and direct collection
/// go through this, so the two cannot drift apart on error handling.
struct GitHubHTTP {
    static let api = "https://api.github.com"

    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // A cached response would hand back the stats from before the last
            // refresh, which is exactly what a refresh is trying to escape.
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Requests

    func request(
        _ url: URL,
        token: String,
        method: String = "GET",
        accept: String = "application/vnd.github+json",
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    func send(_ request: URLRequest, describing path: String, authenticated: Bool) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.decode("the response") }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, path: path, headers: http, authenticated: authenticated)
        }
        return (data, http)
    }

    /// One JSON object.
    func object(_ url: URL, token: String, describing path: String) async throws -> [String: Any] {
        let (data, _) = try await send(request(url, token: token), describing: path, authenticated: !token.isEmpty)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decode(path)
        }
        return json
    }

    /// A JSON array, following `Link rel="next"` to the end.
    ///
    /// The Alfred workflow read only the first page, which quietly capped it at
    /// 100 repos and at 100 releases per repo.
    func paginate(_ url: URL, token: String, describing path: String) async throws -> [[String: Any]] {
        var next: URL? = url
        var items: [[String: Any]] = []
        while let current = next {
            let (data, http) = try await send(request(current, token: token), describing: path, authenticated: !token.isEmpty)
            guard let page = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw GitHubError.decode(path)
            }
            items.append(contentsOf: page)
            next = Self.nextLink(http.value(forHTTPHeaderField: "Link"))
        }
        return items
    }

    // MARK: - Helpers

    static func encode(_ path: String) -> String {
        path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";")
            guard pieces.count >= 2,
                  pieces[1].replacingOccurrences(of: " ", with: "").contains("rel=\"next\"") else { continue }
            let raw = pieces[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }

    static func error(status: Int, data: Data, path: String, headers: HTTPURLResponse, authenticated: Bool) -> GitHubError {
        let message = Self.message(from: data)
        switch status {
        case 404:
            return .notFound(path: path, authenticated: authenticated)
        case 401:
            return .http(401, "Bad or expired token — paste a new one in Settings.")
        case 403 where headers.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0", 429:
            let reset = headers.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(Double.init)
                .map(Date.init(timeIntervalSince1970:))
            return .rateLimited(resetsAt: reset)
        case 403:
            // Almost always the token missing a scope, which reads very
            // differently from a generic 403.
            return .http(403, "\(message) (check the token's scopes)")
        default:
            return .http(status, message)
        }
    }

    /// GitHub's JSON `message`, falling back to a truncated body — the raw blob
    /// is unreadable in a status line on a phone.
    static func message(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}
