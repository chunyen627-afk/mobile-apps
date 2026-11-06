import Foundation

// The thermometer gateway's JSON (apps/thermo-ios/pc-gateway, GET /sensors), version 1:
// {"version": 1, "gateway": "office", "time": <epoch s>, "sensors": [{"id": "A4:C1:38:..",
//  "name": "..", "advertised_name": "..", "temperature": 24.76, "humidity": 68.37, "battery": 93,
//  "voltage": 2.953, "rssi": -45, "updated": <epoch s>, "format": "bthome", "error": null,
//  "label": <name given on a phone or null>, "room": <room or null>}],
//  "alerts": {"enabled": true, "temperature_high": 32, ..., "offline_after_seconds": 7200}}
// Times are the gateway's clock, so ages are measured against `time`, never the phone's clock.
// `label`, `room` and `alerts` came later and may be missing.

public struct ThermoSensor: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let advertisedName: String?
    public let temperature: Double?
    public let humidity: Double?
    public let battery: Int?
    public let voltage: Double?
    public let rssi: Int?
    public let updated: Int?
    public let format: String?
    public let error: String?
    /// The name given on a phone (POST /labels); `name` already shows it when set.
    public let label: String?
    public let room: String?

    enum CodingKeys: String, CodingKey {
        case id, name, temperature, humidity, battery, voltage, rssi, updated, format, error, label, room
        case advertisedName = "advertised_name"
    }

    public init(id: String, name: String, advertisedName: String? = nil, temperature: Double? = nil,
                humidity: Double? = nil, battery: Int? = nil, voltage: Double? = nil, rssi: Int? = nil,
                updated: Int? = nil, format: String? = nil, error: String? = nil, label: String? = nil,
                room: String? = nil) {
        self.id = id
        self.name = name
        self.advertisedName = advertisedName
        self.temperature = temperature
        self.humidity = humidity
        self.battery = battery
        self.voltage = voltage
        self.rssi = rssi
        self.updated = updated
        self.format = format
        self.error = error
        self.label = label
        self.room = room
    }
}

/// The gateway's notification rules (set in its thermo-gateway.json); null turns one off.
public struct ThermoAlertRules: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let temperatureHigh: Double?
    public let temperatureLow: Double?
    public let humidityHigh: Double?
    public let humidityLow: Double?
    public let batteryLow: Double?
    public let offlineAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case temperatureHigh = "temperature_high"
        case temperatureLow = "temperature_low"
        case humidityHigh = "humidity_high"
        case humidityLow = "humidity_low"
        case batteryLow = "battery_low"
        case offlineAfterSeconds = "offline_after_seconds"
    }

    public init(enabled: Bool, temperatureHigh: Double? = nil, temperatureLow: Double? = nil, humidityHigh: Double? = nil,
                humidityLow: Double? = nil, batteryLow: Double? = nil, offlineAfterSeconds: Int? = nil) {
        self.enabled = enabled
        self.temperatureHigh = temperatureHigh
        self.temperatureLow = temperatureLow
        self.humidityHigh = humidityHigh
        self.humidityLow = humidityLow
        self.batteryLow = batteryLow
        self.offlineAfterSeconds = offlineAfterSeconds
    }

    /// One line per kind, as the app lists them ("高於 32°C、低於 10°C").
    public func lines(fahrenheit: Bool) -> [ThermoAlertLine] {
        func temp(_ v: Double) -> String { ThermoText.temperature(v, fahrenheit: fahrenheit) }
        func both(_ high: String?, _ low: String?) -> String {
            let parts = [high.map { "高於 \($0)" }, low.map { "低於 \($0)" }].compactMap { $0 }
            return parts.isEmpty ? "不通知" : parts.joined(separator: "、")
        }
        let hours = offlineAfterSeconds.map { String(format: "%g", Double($0) / 3600) }
        return [
            ThermoAlertLine(title: "溫度", value: both(temperatureHigh.map(temp), temperatureLow.map(temp))),
            ThermoAlertLine(title: "濕度", value: both(humidityHigh.map { String(format: "%.0f%%", $0) },
                                                      humidityLow.map { String(format: "%.0f%%", $0) })),
            ThermoAlertLine(title: "電量", value: batteryLow.map { String(format: "低於 %.0f%%", $0) } ?? "不通知"),
            ThermoAlertLine(title: "收不到訊號", value: hours.map { "超過 \($0) 小時" } ?? "不通知"),
        ]
    }
}

public struct ThermoAlertLine: Identifiable, Equatable, Sendable {
    public let title: String
    public let value: String

    public var id: String { title }
}

public struct ThermoFeed: Decodable, Equatable, Sendable {
    public static let supportedVersion = 1

    public let version: Int
    public let gateway: String
    public let time: Int
    public let sensors: [ThermoSensor]
    public let alerts: ThermoAlertRules?

    public init(version: Int = ThermoFeed.supportedVersion, gateway: String, time: Int, sensors: [ThermoSensor],
                alerts: ThermoAlertRules? = nil) {
        self.version = version
        self.gateway = gateway
        self.time = time
        self.sensors = sensors
        self.alerts = alerts
    }

    /// Decodes a gateway response; another version or a malformed body is an error.
    public static func decode(_ data: Data) throws -> ThermoFeed {
        struct Probe: Decodable { let version: Int }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: data)
        } catch {
            throw ThermoFetchError.malformed
        }
        guard probe.version == supportedVersion else { throw ThermoFetchError.unsupportedVersion(probe.version) }
        do {
            return try JSONDecoder().decode(ThermoFeed.self, from: data)
        } catch {
            throw ThermoFetchError.malformed
        }
    }

    /// Built-in readings shown until a gateway address is set (made-up addresses).
    public static func demo(now: Int) -> ThermoFeed {
        ThermoFeed(gateway: "示範", time: now, sensors: [
            ThermoSensor(id: "A4:C1:38:00:00:01", name: "客廳", advertisedName: "ATC_000001", temperature: 26.13,
                         humidity: 64.5, battery: 93, voltage: 2.953, rssi: -52, updated: now - 20, format: "bthome"),
            ThermoSensor(id: "A4:C1:38:00:00:02", name: "臥室", advertisedName: "ATC_000002", temperature: 24.71,
                         humidity: 58.02, battery: 71, voltage: 2.84, rssi: -68, updated: now - 75, format: "bthome"),
            ThermoSensor(id: "A4:C1:38:00:00:03", name: "機房", advertisedName: "ATC_000003", temperature: 31.4,
                         humidity: 41.2, battery: 12, voltage: 2.31, rssi: -80, updated: now - 2400, format: "pvvx"),
        ])
    }
}
