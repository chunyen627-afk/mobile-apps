import Foundation

// GET /history?id=<address>&range=day|week|month (version 1):
// {"version": 1, "id": "A4:..", "range": "week", "bucket": 86400, "time": <epoch s>, "utc_offset": 28800,
//  "points": [{"t": <bucket start>, "temperature": 24.7, "humidity": 68.5, "battery": 93,
//              "temperature_min": 23.1, "temperature_max": 26.0, "humidity_min": 60.2, "humidity_max": 71.0}]}
// As in Mi Home: the day is 30-minute points drawn as a line; the week and month are one point per
// local calendar day, drawn as a bar from the day's lowest to its highest.

public enum ThermoRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: return "日"
        case .week: return "週"
        case .month: return "月"
        }
    }

    public var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    public var bucket: Int { self == .day ? 1800 : 86400 }

    /// Week and month show one bar per day.
    public var isDaily: Bool { self != .day }
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

    public func format(_ value: Double, fahrenheit: Bool = false) -> String {
        switch self {
        case .temperature: return ThermoText.temperature(value, fahrenheit: fahrenheit)
        case .humidity: return ThermoText.humidity(value)
        case .battery: return String(format: "%.0f%%", value)
        }
    }

    /// Value on the chart's axis: Fahrenheit when the phone shows Fahrenheit.
    public func display(_ value: Double, fahrenheit: Bool) -> Double {
        self == .temperature && fahrenheit ? value * 9 / 5 + 32 : value
    }
}

public struct ThermoPoint: Decodable, Equatable, Sendable, Identifiable {
    public let t: Int
    public let temperature: Double?
    public let humidity: Double?
    public let battery: Int?
    public let temperatureMin: Double?
    public let temperatureMax: Double?
    public let humidityMin: Double?
    public let humidityMax: Double?

    enum CodingKeys: String, CodingKey {
        case t, temperature, humidity, battery
        case temperatureMin = "temperature_min"
        case temperatureMax = "temperature_max"
        case humidityMin = "humidity_min"
        case humidityMax = "humidity_max"
    }

    public var id: Int { t }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    public init(t: Int, temperature: Double?, humidity: Double?, battery: Int?,
                temperatureMin: Double? = nil, temperatureMax: Double? = nil,
                humidityMin: Double? = nil, humidityMax: Double? = nil) {
        self.t = t
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.temperatureMin = temperatureMin
        self.temperatureMax = temperatureMax
        self.humidityMin = humidityMin
        self.humidityMax = humidityMax
    }

    public func value(_ metric: ThermoMetric) -> Double? {
        switch metric {
        case .temperature: return temperature
        case .humidity: return humidity
        case .battery: return battery.map(Double.init)
        }
    }

    /// The bucket's lowest value (its average when the gateway gave none).
    public func low(_ metric: ThermoMetric) -> Double? {
        switch metric {
        case .temperature: return temperatureMin ?? temperature
        case .humidity: return humidityMin ?? humidity
        case .battery: return value(.battery)
        }
    }

    public func high(_ metric: ThermoMetric) -> Double? {
        switch metric {
        case .temperature: return temperatureMax ?? temperature
        case .humidity: return humidityMax ?? humidity
        case .battery: return value(.battery)
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
    public let utcOffset: Int?
    public let points: [ThermoPoint]

    enum CodingKeys: String, CodingKey {
        case version, id, range, bucket, time, points
        case utcOffset = "utc_offset"
    }

    public init(id: String, range: ThermoRange, time: Int, utcOffset: Int? = nil, points: [ThermoPoint]) {
        version = ThermoFeed.supportedVersion
        self.id = id
        self.range = range.rawValue
        bucket = range.bucket
        self.time = time
        self.utcOffset = utcOffset
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

    /// The period's lowest and highest (from each bucket's own lowest and highest) and the mean.
    public func summary(_ metric: ThermoMetric) -> ThermoSummary? {
        let values = points.compactMap { $0.value(metric) }
        guard let low = points.compactMap({ $0.low(metric) }).min(),
              let high = points.compactMap({ $0.high(metric) }).max(),
              !values.isEmpty else { return nil }
        return ThermoSummary(min: low, max: high, average: values.reduce(0, +) / Double(values.count))
    }

    /// Points split where samples are missing for more than two buckets (gateway off, out of
    /// range), so the line leaves a gap instead of a straight line across it.
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

    /// Made-up curves for the demo readings, ending at the sensor's current values; days start
    /// at local midnight (`utcOffset` seconds east of UTC).
    public static func demo(for sensor: ThermoSensor, range: ThermoRange, now: Int, utcOffset: Int = 0) -> ThermoHistory {
        let phase = Double(Int(sensor.id.suffix(2), radix: 16) ?? 1)
        let last = (sensor.updated ?? now) - (sensor.updated ?? now) % 1800
        let first = range == .day ? last - 86400 + 1800 : (now + utcOffset) / 86400 * 86400 - utcOffset - (range.days - 1) * 86400
        var samples: [ThermoPoint] = []
        var t = last
        while t >= first {
            let day = sin(2 * Double.pi * Double((t + utcOffset) % 86400) / 86400 + phase)
            let drift = sin(2 * Double.pi * Double(t) / (5 * 86400))
            let temperature = ((sensor.temperature ?? 25) + 1.8 * day - 1.8 * sin(phase) + 0.6 * drift) * 100
            let humidity = Swift.max(5, Swift.min(99, (sensor.humidity ?? 50) - 6 * day + 6 * sin(phase))) * 100
            let battery = Swift.min(100, (sensor.battery ?? 50) + (last - t) / (10 * 86400))
            samples.insert(ThermoPoint(t: t, temperature: temperature.rounded() / 100, humidity: humidity.rounded() / 100,
                                       battery: battery), at: 0)
            t -= 1800
        }
        guard range.isDaily else {
            return ThermoHistory(id: sensor.id, range: range, time: now, utcOffset: utcOffset, points: samples)
        }
        var days: [Int: [ThermoPoint]] = [:]
        for sample in samples {
            days[(sample.t + utcOffset) / 86400 * 86400 - utcOffset, default: []].append(sample)
        }
        let points = days.keys.sorted().map { start -> ThermoPoint in
            let day = days[start] ?? []
            let temps = day.compactMap(\.temperature), hums = day.compactMap(\.humidity)
            func mean(_ values: [Double]) -> Double { (values.reduce(0, +) / Double(Swift.max(1, values.count)) * 100).rounded() / 100 }
            return ThermoPoint(t: start, temperature: mean(temps), humidity: mean(hums), battery: day.compactMap(\.battery).min(),
                               temperatureMin: temps.min(), temperatureMax: temps.max(),
                               humidityMin: hums.min(), humidityMax: hums.max())
        }
        return ThermoHistory(id: sensor.id, range: range, time: now, utcOffset: utcOffset, points: points)
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
