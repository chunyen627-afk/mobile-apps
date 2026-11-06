import Foundation

// Reads the gateway the user typed in: GET only, no cookies, no cache, no credentials.
// Only a 200 JSON response of at most `maxResponseBytes` that decodes as version 1 is accepted.

public enum ThermoEndpointError: Error, Equatable, Sendable {
    case empty
    case malformed
    case unsupportedScheme
    case missingHost
    case embeddedCredentials

    public var displayText: String {
        switch self {
        case .empty: return "請輸入閘道網址"
        case .malformed: return "網址格式不對"
        case .unsupportedScheme: return "只接受 http 或 https"
        case .missingHost: return "缺少主機位址"
        case .embeddedCredentials: return "網址不可包含帳號密碼"
        }
    }
}

public struct ThermoEndpoint: Equatable, Sendable {
    public let sensorsURL: URL

    /// Accepts `host:port`, `http://host:port` or the full `/sensors` URL; always reads `/sensors`.
    public init(validating text: String) throws {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThermoEndpointError.empty }
        guard !trimmed.contains(where: \.isWhitespace) else { throw ThermoEndpointError.malformed }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        guard var components = URLComponents(string: trimmed) else { throw ThermoEndpointError.malformed }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ThermoEndpointError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty else { throw ThermoEndpointError.missingHost }
        guard components.user == nil, components.password == nil else { throw ThermoEndpointError.embeddedCredentials }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/sensors") {
            path += "/sensors"
        }
        components.path = path
        guard let url = components.url else { throw ThermoEndpointError.malformed }
        sensorsURL = url
    }

    public var usesPlainHTTP: Bool { sensorsURL.scheme == "http" }
}

public enum ThermoFetchError: Error, Equatable, Sendable {
    case offline(String)
    case http(Int)
    case notJSON
    case tooLarge
    case unsupportedVersion(Int)
    case malformed

    public var displayText: String {
        switch self {
        case .offline(let reason): return "連不到閘道（\(reason)）"
        case .http(let code): return code == 403 ? "閘道拒絕（403，手機不在允許的網段）" : "閘道回應錯誤（HTTP \(code)）"
        case .notJSON: return "回應不是 JSON，網址可能不是溫濕度閘道"
        case .tooLarge: return "回應太大，已拒收"
        case .unsupportedVersion(let version): return "閘道版本不相容（\(version)）"
        case .malformed: return "資料格式不對，已拒收"
        }
    }
}

public protocol ThermoTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// Ephemeral URLSession: no cookies, cache or stored credentials. `@unchecked` because URLSession
/// is documented as thread-safe.
public struct ThermoSessionTransport: ThermoTransport, @unchecked Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public struct ThermoClient: Sendable {
    public static let maxResponseBytes = 512 * 1024
    private let transport: any ThermoTransport

    public init(transport: any ThermoTransport = ThermoSessionTransport()) {
        self.transport = transport
    }

    public func fetch(_ endpoint: ThermoEndpoint) async throws -> ThermoFeed {
        try ThermoFeed.decode(try await get(endpoint.sensorsURL))
    }

    /// The body of a 200 JSON response, or a `ThermoFetchError`.
    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)
        do {
            result = try await transport.send(request)
        } catch {
            throw ThermoFetchError.offline(Self.describe(error))
        }
        guard let http = result.1 as? HTTPURLResponse else { throw ThermoFetchError.malformed }
        guard http.statusCode == 200 else { throw ThermoFetchError.http(http.statusCode) }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("application/json") else { throw ThermoFetchError.notJSON }
        guard result.0.count <= Self.maxResponseBytes else { throw ThermoFetchError.tooLarge }
        return result.0
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return "連線失敗" }
        switch urlError.code {
        case .timedOut: return "逾時"
        case .notConnectedToInternet: return "沒有網路"
        case .cannotConnectToHost: return "主機沒有回應"
        case .cannotFindHost: return "找不到主機"
        case .networkConnectionLost: return "連線中斷"
        default: return "錯誤 \(urlError.code.rawValue)"
        }
    }
}
