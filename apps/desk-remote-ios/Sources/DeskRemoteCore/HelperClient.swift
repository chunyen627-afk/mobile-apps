import Foundation

/// Where a PC's helper listens: a host name or IP address and a port, plain HTTP inside the
/// private ZeroTier network. No address is built into the app.
public struct HelperEndpoint: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int

    /// nil for an empty host, one with a scheme, path, spaces or credentials, or a bad port.
    public init?(host: String, port: Int) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !trimmed.isEmpty, trimmed.count <= 253,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !trimmed.hasPrefix("-"), !trimmed.hasPrefix("."),
              (1 ... 65535).contains(port)
        else { return nil }
        // A colon is only valid inside an IPv6 address.
        if trimmed.contains(":") && trimmed.filter({ $0 == ":" }).count < 2 { return nil }
        self.host = trimmed
        self.port = port
    }

    /// URL for a path made of already-validated segments plus query items.
    public func url(_ segments: [String], query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.percentEncodedPath = "/" + segments.map {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

/// Why a request to the helper failed; `DeskText.failure` turns it into Chinese.
public enum HelperFailure: Error, Equatable, Sendable {
    case unauthorized
    case lockedOut
    case notFound(String?)
    case forbidden
    case readOnly
    case server(String?)
    case unreachable
    case timeout
    case badResponse
    case cancelled
}

/// Reads one PC's helper. Every request carries `Authorization: Bearer <token>`, uses an
/// ephemeral session (no cookies, cache or stored credentials), never follows a redirect and
/// accepts at most 4 MB of JSON.
public struct HelperClient: Sendable {
    public let endpoint: HelperEndpoint
    private let token: String
    private let session: URLSession
    static let maxBytes = 4 * 1024 * 1024

    public init(endpoint: HelperEndpoint, token: String, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.token = token
        self.session = session ?? Self.sharedSession
    }

    /// One ephemeral session for every PC, so views can create clients freely.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public func state() async throws -> HelperState {
        try await get(["v1", "state"], timeout: 10)
    }

    public func sessions(_ app: DeskApp, limit: Int = 50) async throws -> SessionList {
        try await get(["v1", app.rawValue, "sessions"], query: [URLQueryItem(name: "limit", value: String(limit))], timeout: 15)
    }

    /// Long-polls for events after `cursor` in `epoch`, waiting up to `wait` seconds.
    public func events(_ app: DeskApp, session id: String, after cursor: Int, epoch: String,
                       knownPrompt: String?, wait: Int) async throws -> EventPage {
        try await get(["v1", app.rawValue, "sessions", id, "events"], query: [
            URLQueryItem(name: "after", value: String(cursor)),
            URLQueryItem(name: "epoch", value: epoch),
            URLQueryItem(name: "prompt", value: knownPrompt ?? ""),
            URLQueryItem(name: "wait", value: String(wait)),
        ], timeout: TimeInterval(wait + 10))
    }

    /// Full text of an event the helper shortened.
    public func item(_ app: DeskApp, session id: String, item itemId: String) async throws -> String {
        let body: ItemText = try await get(["v1", app.rawValue, "sessions", id, "items", itemId], timeout: 15)
        return body.text
    }

    private func get<T: Decodable>(_ segments: [String], query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> T {
        guard let url = endpoint.url(segments, query: query) else { throw HelperFailure.badResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect.shared)
        } catch {
            throw Self.failure(for: error)
        }
        guard let http = response as? HTTPURLResponse, data.count <= Self.maxBytes else { throw HelperFailure.badResponse }
        return try Self.decode(T.self, status: http.statusCode, data: data)
    }

    /// Maps a status and body to the decoded value or a `HelperFailure`. Internal for tests.
    static func decode<T: Decodable>(_ type: T.Type, status: Int, data: Data) throws -> T {
        if status == 200 {
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw HelperFailure.badResponse
            }
        }
        let body = try? JSONDecoder().decode(HelperErrorBody.self, from: data)
        switch (status, body?.error) {
        case (401, _): throw HelperFailure.unauthorized
        case (429, "locked-out"): throw HelperFailure.lockedOut
        case (403, _): throw HelperFailure.forbidden
        case (404, _): throw HelperFailure.notFound(body?.message)
        case (405, _): throw HelperFailure.readOnly
        default: throw HelperFailure.server(body?.message)
        }
    }

    static func failure(for error: Error) -> HelperFailure {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        default: return .unreachable
        }
    }
}

/// Refuses every redirect: the helper never redirects, so one means something else answered.
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
