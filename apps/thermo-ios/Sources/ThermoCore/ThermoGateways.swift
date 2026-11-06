import Foundation

/// The gateways the user typed in, one per line (a PC at the office, an ESP32 at home, ...).
/// Each gateway is read on its own; one failing never hides the others' readings.
public enum ThermoGatewayList {
    public static let maxGateways = 8

    /// Non-empty lines, trimmed, duplicates removed (by resolved URL), at most `maxGateways`.
    public static func lines(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let key = (try? ThermoEndpoint(validating: line))?.sensorsURL.absoluteString ?? line
            guard seen.insert(key).inserted else { continue }
            out.append(line)
            if out.count == maxGateways { break }
        }
        return out
    }

    /// Each line with its endpoint or the reason it was rejected.
    public static func parse(_ text: String) -> [ThermoGatewayLine] {
        lines(text).map { line in
            do {
                return ThermoGatewayLine(line: line, result: .success(try ThermoEndpoint(validating: line)))
            } catch let error as ThermoEndpointError {
                return ThermoGatewayLine(line: line, result: .failure(error))
            } catch {
                return ThermoGatewayLine(line: line, result: .failure(.malformed))
            }
        }
    }

    public static func endpoints(_ text: String) -> [ThermoEndpoint] {
        parse(text).compactMap(\.endpoint)
    }
}

public struct ThermoGatewayLine: Identifiable, Sendable {
    public let line: String
    public let result: Result<ThermoEndpoint, ThermoEndpointError>

    public var id: String { line }
    public var endpoint: ThermoEndpoint? { try? result.get() }
    public var isValid: Bool { endpoint != nil }
}

/// One gateway's last good feed and its latest error. A failed read keeps the last feed, so the
/// screen still shows it (with its age growing) next to the error.
public struct ThermoGatewayState: Equatable, Sendable, Identifiable {
    public let endpoint: ThermoEndpoint
    public var feed: ThermoFeed?
    /// Phone time when `feed` arrived; the gateway clock then advances with the phone's.
    public var receivedAt: Date?
    public var error: ThermoFetchError?

    public var id: String { endpoint.sensorsURL.absoluteString }

    public init(endpoint: ThermoEndpoint, feed: ThermoFeed? = nil, receivedAt: Date? = nil, error: ThermoFetchError? = nil) {
        self.endpoint = endpoint
        self.feed = feed
        self.receivedAt = receivedAt
        self.error = error
    }

    /// The gateway's clock now, estimated from its last response.
    public func gatewayNow(phoneNow: Date) -> Int? {
        guard let feed, let receivedAt else { return nil }
        return feed.time + max(0, Int(phoneNow.timeIntervalSince(receivedAt)))
    }

    /// Short name for the screen: the gateway's own name, else the host.
    public var title: String {
        if let name = feed?.gateway, !name.isEmpty { return name }
        return endpoint.sensorsURL.host ?? id
    }
}
