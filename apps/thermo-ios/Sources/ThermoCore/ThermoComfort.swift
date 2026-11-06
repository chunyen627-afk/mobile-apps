import Foundation

/// The comfortable range, as in Mi Home's thermometer settings; editable on the phone.
public struct ThermoComfortZone: Codable, Equatable, Sendable {
    public static let standard = ThermoComfortZone(temperatureLow: 20, temperatureHigh: 26, humidityLow: 40, humidityHigh: 60)

    public var temperatureLow: Double
    public var temperatureHigh: Double
    public var humidityLow: Double
    public var humidityHigh: Double

    public init(temperatureLow: Double, temperatureHigh: Double, humidityLow: Double, humidityHigh: Double) {
        self.temperatureLow = temperatureLow
        self.temperatureHigh = temperatureHigh
        self.humidityLow = humidityLow
        self.humidityHigh = humidityHigh
    }

    /// Low stays below high: a step that would cross pushes the other end along.
    public mutating func normalize() {
        if temperatureHigh <= temperatureLow { temperatureHigh = temperatureLow + 1 }
        if humidityHigh <= humidityLow { humidityHigh = humidityLow + 5 }
    }
}

public enum ThermoComfortLevel: Equatable, Sendable {
    case comfortable
    case uncomfortable([String])
    case unknown

    public var text: String {
        switch self {
        case .comfortable: return "舒適"
        case .uncomfortable(let parts): return parts.joined(separator: "・")
        case .unknown: return "--"
        }
    }

    public var isComfortable: Bool { self == .comfortable }
}

public enum ThermoComfort {
    /// "舒適", or what is off: "偏冷"/"偏熱" and "乾燥"/"潮濕", as Mi Home words it.
    public static func level(temperature: Double?, humidity: Double?, zone: ThermoComfortZone) -> ThermoComfortLevel {
        guard temperature != nil || humidity != nil else { return .unknown }
        var parts: [String] = []
        if let temperature {
            if temperature < zone.temperatureLow { parts.append("偏冷") }
            if temperature > zone.temperatureHigh { parts.append("偏熱") }
        }
        if let humidity {
            if humidity < zone.humidityLow { parts.append("乾燥") }
            if humidity > zone.humidityHigh { parts.append("潮濕") }
        }
        return parts.isEmpty ? .comfortable : .uncomfortable(parts)
    }
}
