import Foundation

// Read-only HTTP client for a status source the user typed in. There is no built-in address:
// nothing connects until the user supplies a URL and explicitly starts reading.
//
// - GET only: no body, no credentials, no cookies, no cache. The app has no write or control path.
// - Only a 200 response with a JSON content type, from the same origin as the configured URL,
//   at most `maxResponseBytes`, that passes the whitelist decoder is accepted. Everything else is
//   a `FetchFailure`, which the engine treats as a failed request (green is removed at once).
// - Take the `ClockReading` for `StatusEngine.apply` after `fetch()` returns: it is the receive time.

// MARK: - Endpoint

public enum SourceEndpointError: Error, Hashable, Sendable {
    case empty
    case malformed
    case unsupportedScheme
    case missingHost
    case embeddedCredentials
    case fragment
}

public struct SourceEndpoint: Hashable, Sendable {
    public let url: URL

    /// Accepts `http` or `https` URLs with a host. Credentials in the URL and fragments are rejected.
    public init(validating text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceEndpointError.empty }
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed)
        else { throw SourceEndpointError.malformed }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SourceEndpointError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else { throw SourceEndpointError.missingHost }
        guard components.user == nil, components.password == nil else {
            throw SourceEndpointError.embeddedCredentials
        }
        guard components.fragment == nil else { throw SourceEndpointError.fragment }
        guard let url = components.url else { throw SourceEndpointError.malformed }
        self.url = url
    }

    /// Plain HTTP is unencrypted; the UI warns about it.
    public var usesPlainHTTP: Bool { url.scheme?.lowercased() == "http" }

    /// Scheme, lowercased host and effective port.
    var origin: (scheme: String, host: String, port: Int) { Self.origin(of: url) }

    static func origin(of url: URL) -> (scheme: String, host: String, port: Int) {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return (scheme, url.host?.lowercased() ?? "", port)
    }
}

// MARK: - Transport

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// URLSession with an ephemeral, cookie-free, cache-free configuration.
/// `@unchecked` because URLSession is documented as thread-safe.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeEphemeralSession()) {
        self.session = session
    }

    public static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = StatusFeedClient.requestTimeout
        configuration.timeoutIntervalForResource = StatusFeedClient.requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Client

public enum FetchFailure: Error, Hashable, Sendable {
    /// The task was cancelled (e.g. the app left the foreground); not a source failure.
    case cancelled
    case timedOut
    case cannotConnect
    /// App Transport Security refused a plain-HTTP connection.
    case insecureConnectionBlocked
    case transport(code: Int?)
    case notHTTPResponse
    case httpStatus(Int)
    case redirectedElsewhere
    case unexpectedContentType
    case responseTooLarge
    /// Not valid JSON, or rejected by the whitelist decoder.
    case invalidPayload
}

public struct StatusFeedClient: Sendable {
    public static let requestTimeout: TimeInterval = 10
    public static let maxResponseBytes = 512 * 1024

    public let endpoint: SourceEndpoint
    private let transport: any HTTPTransport

    public init(endpoint: SourceEndpoint, transport: any HTTPTransport = URLSessionTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func makeRequest() -> URLRequest {
        var request = URLRequest(
            url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public func fetch() async -> Result<MinerStatusFeed, FetchFailure> {
        let request = makeRequest()
        let received: (Data, URLResponse)
        do {
            received = try await transport.send(request)
        } catch let error as URLError {
            return .failure(Self.failure(for: error))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.transport(code: nil))
        }
        let (data, response) = received

        guard let http = response as? HTTPURLResponse else { return .failure(.notHTTPResponse) }
        // URLSession follows redirects; refuse data that came from another origin.
        let finalURL = http.url ?? endpoint.url
        guard SourceEndpoint.origin(of: finalURL) == endpoint.origin else { return .failure(.redirectedElsewhere) }
        guard http.statusCode == 200 else { return .failure(.httpStatus(http.statusCode)) }
        guard let contentType = http.value(forHTTPHeaderField: "Content-Type"),
              contentType.lowercased().contains("json")
        else { return .failure(.unexpectedContentType) }
        guard data.count <= Self.maxResponseBytes else { return .failure(.responseTooLarge) }

        do {
            return .success(try JSONDecoder().decode(MinerStatusFeed.self, from: data))
        } catch {
            return .failure(.invalidPayload)
        }
    }

    static func failure(for error: URLError) -> FetchFailure {
        switch error.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed:
            return .cannotConnect
        case .appTransportSecurityRequiresSecureConnection: return .insecureConnectionBlocked
        case .dataLengthExceedsMaximum: return .responseTooLarge
        default: return .transport(code: error.code.rawValue)
        }
    }
}

// MARK: - Engine integration

public extension StatusEngine {
    /// Applies one fetch result. A cancelled fetch changes nothing; any other failure is a failed
    /// request, so green is removed at once and reconnecting needs a new baseline.
    mutating func apply(_ result: Result<MinerStatusFeed, FetchFailure>, at reading: ClockReading) {
        switch result {
        case .success(let feed): ingest(feed, at: reading)
        case .failure(.cancelled): break
        case .failure: recordRequestFailure(at: reading)
        }
    }
}

// MARK: - Clock

/// Wall clock plus a monotonic clock that keeps counting through device sleep (`ContinuousClock`).
/// Monotonic values are seconds since this value was created; keep one instance per engine.
public struct SystemClock: Sendable {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public func reading() -> ClockReading {
        let elapsed = ContinuousClock.now - origin
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return ClockReading(wall: Date(), monotonic: seconds)
    }
}
