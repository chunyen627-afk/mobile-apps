import Foundation

/// How recent a reading is, by the gateway's clock.
public enum ThermoFreshness: Equatable, Sendable {
    case fresh   // at most 10 minutes old
    case stale   // up to an hour
    case lost    // older than an hour
    case never   // no reading yet

    public static func of(updated: Int?, now: Int) -> ThermoFreshness {
        guard let updated else { return .never }
        let age = max(0, now - updated)
        if age <= 600 { return .fresh }
        if age <= 3600 { return .stale }
        return .lost
    }
}

/// Display text for the thermometer screens (Traditional Chinese).
public enum ThermoText {
    /// Celsius as "24.8°"; Fahrenheit (the phone's unit setting) as "76.6°F".
    public static func temperature(_ value: Double?, fahrenheit: Bool = false) -> String {
        guard let value else { return "--" }
        if fahrenheit {
            return String(format: "%.1f°F", value * 9 / 5 + 32)
        }
        return String(format: "%.1f°", value)
    }

    public static func humidity(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f%%", value)
    }

    public static func battery(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value)%"
    }

    public static func voltage(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.3f V", value)
    }

    public static func rssi(_ value: Int?) -> String {
        guard let value else { return "--" }
        return "\(value) dBm"
    }

    public static func isBatteryLow(_ value: Int?) -> Bool {
        guard let value else { return false }
        return value < 20
    }

    public static func batterySymbol(_ value: Int?) -> String {
        guard let value else { return "battery.0" }
        switch value {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    /// "剛剛", "5 分鐘前", "3 小時前", "2 天前" or "尚無讀數".
    public static func age(updated: Int?, now: Int) -> String {
        guard let updated else { return "尚無讀數" }
        let age = max(0, now - updated)
        if age < 60 { return "剛剛" }
        if age < 3600 { return "\(age / 60) 分鐘前" }
        if age < 86400 { return "\(age / 3600) 小時前" }
        return "\(age / 86400) 天前"
    }

    public static func format(_ value: String?) -> String {
        guard let value else { return "--" }
        switch value {
        case "bthome": return "BTHome 廣播（明文）"
        case "pvvx": return "pvvx 廣播（明文）"
        case "atc1441": return "ATC 廣播（明文）"
        case "gatt": return "原廠韌體，連線讀取"
        default: return value
        }
    }
}

public struct ThermoRoomGroup<Item>: Identifiable {
    public let room: String
    public let items: [Item]

    public var id: String { room }
}

/// The phone's own names and hidden thermometers, keyed by the thermometer's address. Stored
/// only on this phone; the gateway's names are the defaults.
public struct ThermoPreferences: Codable, Equatable, Sendable {
    public static let maxNameLength = 40
    public static let noRoom = "未指定房間"

    public var names: [String: String] = [:]
    public var hidden: Set<String> = []
    /// Room per thermometer, as Mi Home groups devices by room.
    public var rooms: [String: String] = [:]
    public var fahrenheit = false
    public var comfort = ThermoComfortZone.standard

    public init() {}

    enum CodingKeys: String, CodingKey {
        case names, hidden, rooms, fahrenheit, comfort
    }

    /// Settings saved by an earlier version miss the newer keys; those take their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        names = try container.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        hidden = try container.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        rooms = try container.decodeIfPresent([String: String].self, forKey: .rooms) ?? [:]
        fahrenheit = try container.decodeIfPresent(Bool.self, forKey: .fahrenheit) ?? false
        comfort = try container.decodeIfPresent(ThermoComfortZone.self, forKey: .comfort) ?? .standard
    }

    public func room(_ id: String) -> String? {
        rooms[id]
    }

    /// An empty room clears it.
    public mutating func setRoom(_ id: String, _ room: String?) {
        let trimmed = (room ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rooms[id] = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxNameLength))
    }

    /// Every room in use, sorted.
    public var allRooms: [String] {
        Set(rooms.values).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func comfortLevel(_ sensor: ThermoSensor) -> ThermoComfortLevel {
        ThermoComfort.level(temperature: sensor.temperature, humidity: sensor.humidity, zone: comfort)
    }

    public func temperature(_ value: Double?) -> String {
        ThermoText.temperature(value, fahrenheit: fahrenheit)
    }

    /// Visible thermometers grouped by room: named rooms sorted, then the unassigned ones.
    public func byRoom<Item>(_ items: [Item], sensor: (Item) -> ThermoSensor) -> [ThermoRoomGroup<Item>] {
        let visible = items.filter { !hidden.contains(sensor($0).id) }
        let sorted = visible.sorted {
            let order = displayName(sensor($0)).localizedStandardCompare(displayName(sensor($1)))
            return order == .orderedSame ? sensor($0).id < sensor($1).id : order == .orderedAscending
        }
        var groups: [String: [Item]] = [:]
        for item in sorted {
            groups[rooms[sensor(item).id] ?? Self.noRoom, default: []].append(item)
        }
        let named = groups.keys.filter { $0 != Self.noRoom }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (named + (groups[Self.noRoom] == nil ? [] : [Self.noRoom])).map {
            ThermoRoomGroup(room: $0, items: groups[$0] ?? [])
        }
    }

    public func displayName(_ sensor: ThermoSensor) -> String {
        if let name = names[sensor.id], !name.isEmpty { return name }
        return sensor.name
    }

    /// An empty name goes back to the gateway's name.
    public mutating func rename(_ id: String, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxNameLength))
    }

    /// Renames from the rename dialog, which starts with the current name: the gateway's own
    /// name, or an empty one, goes back to following the gateway.
    public mutating func rename(_ sensor: ThermoSensor, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rename(sensor.id, to: trimmed == sensor.name ? "" : trimmed)
    }

    public mutating func setHidden(_ id: String, _ isHidden: Bool) {
        if isHidden {
            hidden.insert(id)
        } else {
            hidden.remove(id)
        }
    }

    /// Visible and hidden thermometers, each sorted by display name.
    public func arrange(_ sensors: [ThermoSensor]) -> (visible: [ThermoSensor], hidden: [ThermoSensor]) {
        let sorted = sensors.sorted {
            let order = displayName($0).localizedStandardCompare(displayName($1))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return (sorted.filter { !hidden.contains($0.id) }, sorted.filter { hidden.contains($0.id) })
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decoded(_ data: Data?) -> ThermoPreferences {
        guard let data, let value = try? JSONDecoder().decode(ThermoPreferences.self, from: data) else {
            return ThermoPreferences()
        }
        return value
    }
}
