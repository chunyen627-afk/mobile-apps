import Foundation

// GET /history?id=<address>&range=day|week|month (version 1):
// {"version": 1, "id": "A4:..", "range": "day", "bucket": 300, "time": <epoch s>,
//  "points": [{"t": <epoch s>, "temperature": 24.7, "humidity": 68.5, "battery": 93}]}
// Each point averages one bucket (5 minutes, 30 minutes or 2 hours) of 5-minute samples.

public enum ThermoRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: return "24 小時"
        case .week: return "7 天"
        case .month: return "30 天"
        }
    }

    public var seconds: Int {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }

    public var bucket: Int {
        switch self {
        case .day: return 300
        case .week: return 1800
        case .month: return 7200
        }
    }
}

public enum ThermoMetric: String, CaseIterable, Identifiable, Sendable {
    case temperature, humidity, battery

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .temperature: return "溫度"
        case .humidity: return "濕度"
        case .battery: return "電量"
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .temperature: return ThermoText.temperature(value)
        case .humidity: return ThermoText.humidity(value)
        case .battery: return String(format: "%.0f%%", value)
        }
    }
}

public struct ThermoPoint: Decodable, Equatable, Sendable, Identifiable {
    public let t: Int
    public let temperature: Double?
    public let humidity: Double?
    public let battery: Int?

    public var id: Int { t }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    public init(t: Int, temperature: Double?, humidity: Double?, battery: Int?) {
        self.t = t
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
    }

    public func value(_ metric: ThermoMetric) -> Double? {
        switch metric {
        case .temperature: return temperature
        case .humidity: return humidity
        case .battery: return battery.map(Double.init)
        }
    }
}

public struct ThermoSummary: Equatable, Sendable {
    public let min: Double
    public let max: Double
    public let average: Double
}

public struct ThermoHistory: Decodable, Equatable, Sendable {
    public let version: Int
    public let id: String
    public let range: String
    public let bucket: Int
    public let time: Int
    public let points: [ThermoPoint]

    public init(id: String, range: ThermoRange, time: Int, points: [ThermoPoint]) {
        version = ThermoFeed.supportedVersion
        self.id = id
        self.range = range.rawValue
        bucket = range.bucket
        self.time = time
        self.points = points
    }

    public static func decode(_ data: Data) throws -> ThermoHistory {
        struct Probe: Decodable { let version: Int }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: data)
        } catch {
            throw ThermoFetchError.malformed
        }
        guard probe.version == ThermoFeed.supportedVersion else { throw ThermoFetchError.unsupportedVersion(probe.version) }
        do {
            return try JSONDecoder().decode(ThermoHistory.self, from: data)
        } catch {
            throw ThermoFetchError.malformed
        }
    }

    /// Lowest, highest and mean of one metric; nil without any value.
    public func summary(_ metric: ThermoMetric) -> ThermoSummary? {
        let values = points.compactMap { $0.value(metric) }
        guard let low = values.min(), let high = values.max() else { return nil }
        return ThermoSummary(min: low, max: high, average: values.reduce(0, +) / Double(values.count))
    }

    /// Points split where samples are missing for more than two buckets (gateway off, out of
    /// range), so the chart leaves a gap instead of drawing a straight line across it.
    public func segments(_ metric: ThermoMetric) -> [[ThermoPoint]] {
        var out: [[ThermoPoint]] = []
        var current: [ThermoPoint] = []
        var last: Int?
        for point in points where point.value(metric) != nil {
            if let last, point.t - last > 2 * bucket, !current.isEmpty {
                out.append(current)
                current = []
            }
            current.append(point)
            last = point.t
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Made-up curves for the demo readings, ending at the sensor's current values.
    public static func demo(for sensor: ThermoSensor, range: ThermoRange, now: Int) -> ThermoHistory {
        let phase = Double(Int(sensor.id.suffix(2), radix: 16) ?? 1)
        let end = (sensor.updated ?? now) - (sensor.updated ?? now) % range.bucket
        let count = range.seconds / range.bucket
        var points: [ThermoPoint] = []
        for k in stride(from: count - 1, through: 0, by: -1) {
            let t = end - k * range.bucket
            let day = sin(2 * Double.pi * Double(t % 86400) / 86400 + phase)
            let drift = sin(2 * Double.pi * Double(t) / (5 * 86400))
            let base = sensor.temperature ?? 25
            let temperature = ((base + 1.8 * day - 1.8 * sin(phase) + 0.6 * drift) * 100).rounded() / 100
            let humidity = Swift.max(5, Swift.min(99, (sensor.humidity ?? 50) - 6 * day + 6 * sin(phase)))
            let battery = Swift.min(100, (sensor.battery ?? 50) + k * range.bucket / (10 * 86400))
            points.append(ThermoPoint(t: t, temperature: temperature, humidity: (humidity * 100).rounded() / 100, battery: battery))
        }
        return ThermoHistory(id: sensor.id, range: range, time: now, points: points)
    }
}

public extension ThermoEndpoint {
    /// The same gateway's /history for one thermometer.
    func historyURL(id: String, range: ThermoRange) -> URL? {
        guard var components = URLComponents(url: sensorsURL, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        if path.hasSuffix("/sensors") {
            path.removeLast("/sensors".count)
        }
        components.path = path + "/history"
        components.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "range", value: range.rawValue)]
        return components.url
    }
}

public extension ThermoClient {
    func history(_ endpoint: ThermoEndpoint, id: String, range: ThermoRange) async throws -> ThermoHistory {
        guard let url = endpoint.historyURL(id: id, range: range) else { throw ThermoFetchError.malformed }
        return try ThermoHistory.decode(try await get(url))
    }
}
