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
    /// Someone used the PC this many seconds ago; the phone may confirm and send anyway.
    case busyUser(Int?)
    case locked
    case promptChanged
    case badRequest(String?)
    case queueFull
    /// The PC refused this phone's approval signature (wrong or missing key for that PC).
    case badSignature
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
                       knownPrompt: String?, knownQuestion: String? = nil, wait: Int) async throws -> EventPage {
        try await get(["v1", app.rawValue, "sessions", id, "events"], query: [
            URLQueryItem(name: "after", value: String(cursor)),
            URLQueryItem(name: "epoch", value: epoch),
            URLQueryItem(name: "prompt", value: knownPrompt ?? ""),
            URLQueryItem(name: "question", value: knownQuestion ?? ""),
            URLQueryItem(name: "wait", value: String(wait)),
        ], timeout: TimeInterval(wait + 10))
    }

    /// Answers the option question waiting now, one `QuestionAnswer` per question.
    public func answerQuestion(_ app: DeskApp, session id: String, questionId: String, answers: [QuestionAnswer],
                               force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions", id, "answer"],
                       ActionRequest(questionId: questionId, answers: answers, force: force ? true : nil))
    }

    /// Full text of an event the helper shortened.
    public func item(_ app: DeskApp, session id: String, item itemId: String) async throws -> String {
        let body: ItemText = try await get(["v1", app.rawValue, "sessions", id, "items", itemId], timeout: 15)
        return body.text
    }

    // MARK: - Actions on the PC's windows (each returns at once; follow the action for its result)

    /// Pastes `text` into the conversation on the PC and presses Enter. `clientMsgId` makes a
    /// retry safe: the helper sends one message per id.
    public func send(_ app: DeskApp, session id: String, text: String, clientMsgId: String, force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions", id, "messages"],
                       ActionRequest(text: text, clientMsgId: clientMsgId, force: force ? true : nil))
    }

    /// Answers the permission question the PC shows now: allow once or deny, nothing broader.
    public func answer(_ app: DeskApp, session id: String, promptId: String, allow: Bool, force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions", id, "permission"],
                       ActionRequest(promptId: promptId, decision: allow ? "allow_once" : "deny", force: force ? true : nil))
    }

    /// Starts a new conversation with `text` as its first message.
    public func newSession(_ app: DeskApp, text: String, clientMsgId: String, force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions"],
                       ActionRequest(text: text, clientMsgId: clientMsgId, force: force ? true : nil))
    }

    /// Picks `model` (one of `HelperState.models(app)`) in the conversation's model menu on the PC.
    public func setModel(_ app: DeskApp, session id: String, model: String, force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions", id, "model"], ActionRequest(model: model, force: force ? true : nil))
    }

    /// Brings the conversation up on the PC (to answer a question it is waiting on).
    public func openOnPC(_ app: DeskApp, session id: String, force: Bool = false) async throws -> ActionStatus {
        try await post(["v1", app.rawValue, "sessions", id, "open"], ActionRequest(force: force ? true : nil))
    }

    // MARK: - Administrator commands

    public func elevateList() async throws -> ElevateList {
        try await get(["v1", "elevate"], timeout: 15)
    }

    /// Approves with the phone's signature, or denies (no signature needed). Returns the new state.
    @discardableResult
    public func decideElevate(_ id: String, allow: Bool, signature: String?) async throws -> String? {
        guard let url = endpoint.url(["v1", "elevate", id]) else { throw HelperFailure.badResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(ElevateDecision(decision: allow ? "allow" : "deny", hmac: signature))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let answer: DecisionAnswer = try await perform(request)
        return answer.state
    }

    public func action(_ id: String) async throws -> ActionStatus {
        try await get(["v1", "actions", id], timeout: 10)
    }

    /// Polls an action once a second until it finishes or `timeout` passes, reporting each change.
    public func follow(_ start: ActionStatus, timeout: TimeInterval = 90,
                       onUpdate: @MainActor (ActionStatus) -> Void = { _ in }) async throws -> ActionStatus {
        var current = start
        let deadline = Date().addingTimeInterval(timeout)
        while !current.finished && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let next = try await action(current.id)
            if next != current { await onUpdate(next) }
            current = next
        }
        return current
    }

    private func post<T: Decodable>(_ segments: [String], _ body: ActionRequest) async throws -> T {
        guard let url = endpoint.url(segments) else { throw HelperFailure.badResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    private func get<T: Decodable>(_ segments: [String], query: [URLQueryItem] = [], timeout: TimeInterval) async throws -> T {
        guard let url = endpoint.url(segments, query: query) else { throw HelperFailure.badResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ original: URLRequest) async throws -> T {
        var request = original
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
        if status == 200 || status == 202 {
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
        case (429, _): throw HelperFailure.queueFull
        case (409, "busy-user"): throw HelperFailure.busyUser(body?.idleSeconds)
        case (409, "prompt-changed"), (409, "question-changed"): throw HelperFailure.promptChanged
        case (423, _): throw HelperFailure.locked
        case (403, "bad-signature"): throw HelperFailure.badSignature
        case (410, _): throw HelperFailure.notFound(body?.message ?? "這個請求已經逾時")
        case (503, "elevate-unavailable"): throw HelperFailure.server(body?.message)
        case (400, _), (413, _): throw HelperFailure.badRequest(body?.message)
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
