import Foundation

/// Taipower 表燈簡易型時間電價（二段式）flow rates, NT$ per kWh. Defaults are the published rates
/// in effect from 2025-10-01; the app lets the user edit them. The NT$75 monthly basic fee is per
/// household, not per machine, and the over-2,000 kWh surcharge is not applied.
public struct TouTariff: Codable, Hashable, Sendable {
    public var summerPeak: Double
    public var summerOffPeak: Double
    public var nonSummerPeak: Double
    public var nonSummerOffPeak: Double

    public init(summerPeak: Double = 5.16, summerOffPeak: Double = 2.06,
                nonSummerPeak: Double = 4.93, nonSummerOffPeak: Double = 1.99) {
        self.summerPeak = summerPeak
        self.summerOffPeak = summerOffPeak
        self.nonSummerPeak = nonSummerPeak
        self.nonSummerOffPeak = nonSummerOffPeak
    }

    public static let taipowerSimpleTwoStage = TouTariff()

    /// Taiwan time. Summer is June 1 – September 30. Weekday peak: summer 09:00–24:00,
    /// otherwise 06:00–11:00 and 14:00–24:00. Saturdays and Sundays are off-peak all day.
    /// National holidays (also off-peak) are not known here and are billed as weekdays.
    public func rate(at date: Date, calendar: Calendar = .taipei) -> Double {
        period(at: date, calendar: calendar).rate
    }

    /// "非夏月離峰" and its rate, for showing the current price.
    public func period(at date: Date, calendar: Calendar = .taipei) -> (name: String, rate: Double) {
        let parts = calendar.dateComponents([.month, .weekday, .hour], from: date)
        let summer = (6 ... 9).contains(parts.month ?? 0)
        let weekend = parts.weekday == 1 || parts.weekday == 7
        let hour = parts.hour ?? 0
        let peak = !weekend && (summer ? hour >= 9 : (6 ..< 11).contains(hour) || hour >= 14)
        let rate: Double
        switch (summer, peak) {
        case (true, true): rate = summerPeak
        case (true, false): rate = summerOffPeak
        case (false, true): rate = nonSummerPeak
        case (false, false): rate = nonSummerOffPeak
        }
        return ("\(summer ? "夏月" : "非夏月")\(peak ? "尖峰" : "離峰")", rate)
    }

    /// Cost of a constant load over the calendar day containing `day`, hour by hour.
    public func costPerDay(watts: Double, day: Date, calendar: Calendar = .taipei) -> Double {
        let start = calendar.startOfDay(for: day)
        return (0 ..< 24).reduce(0) { total, hour in
            let moment = calendar.date(byAdding: .hour, value: hour, to: start) ?? start
            return total + watts / 1000 * rate(at: moment, calendar: calendar)
        }
    }
}

public extension Calendar {
    static var taipei: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return calendar
    }
}

/// One machine's estimated day, in NT$ where prices allow.
public struct MachineEarnings: Hashable, Sendable {
    public let coinPerDay: Double?
    public let btcPerDay: Double?
    public let revenueTwdPerDay: Double?
    /// Reported GPU watts plus the user's extra watts; nil without GPU power data.
    public let powerW: Double?
    public let electricityBilled: Bool
    /// 0 when not billed; nil when billed but power is unknown.
    public let electricityTwdPerDay: Double?
    public let netTwdPerDay: Double?
}

public enum EarningsCalculator {
    public static func estimate(
        status: MachineStatus?, market: MarketReport?, billed: Bool, extraWatts: Double,
        tariff: TouTariff, day: Date, calendar: Calendar = .taipei
    ) -> MachineEarnings {
        let coinPerDay = status?.earnings?.coinPerDay
        var btcPerDay: Double?
        var revenue: Double?
        if let coin = coinPerDay, let coinUsd = market?.coinUsd {
            if let btcUsd = market?.btcUsd { btcPerDay = coin * coinUsd / btcUsd }
            if let usdTwd = market?.usdTwd { revenue = coin * coinUsd * usdTwd }
        }
        let gpuWatts = status?.gpus?.compactMap(\.powerW)
        let power = gpuWatts.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) + max(0, extraWatts) }
        let electricity: Double? = billed ? power.map { tariff.costPerDay(watts: $0, day: day, calendar: calendar) } : 0
        let net: Double? = revenue.flatMap { value in electricity.map { value - $0 } }
        return MachineEarnings(coinPerDay: coinPerDay, btcPerDay: btcPerDay, revenueTwdPerDay: revenue,
                               powerW: power, electricityBilled: billed, electricityTwdPerDay: electricity,
                               netTwdPerDay: net)
    }

    /// Sums of the machines that have a value; nil when none has one.
    public static func total(_ machines: [MachineEarnings]) -> (revenue: Double?, electricity: Double?, net: Double?) {
        func sum(_ values: [Double?]) -> Double? {
            let known = values.compactMap { $0 }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        return (sum(machines.map(\.revenueTwdPerDay)), sum(machines.map(\.electricityTwdPerDay)),
                sum(machines.map(\.netTwdPerDay)))
    }
}
