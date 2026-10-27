import Foundation

/// Taipower 表燈簡易型時間電價（二段式）flow rates, NT$ per kWh. Defaults are the published rates
/// in effect from 2025-10-01; the source may send newer ones and the app lets the user edit them.
/// The NT$75 monthly basic fee is per household, not per machine, and the over-2,000 kWh
/// surcharge is not applied.
public struct TouTariff: Codable, Hashable, Sendable {
    public var summerPeak: Double
    public var summerOffPeak: Double
    public var nonSummerPeak: Double
    public var nonSummerOffPeak: Double
    /// Weekday days off ("YYYY-MM-DD", Taiwan time) billed off-peak all day. Comes from the source,
    /// never stored with the user's settings.
    public var offPeakDates: Set<String> = []

    enum CodingKeys: String, CodingKey {
        case summerPeak, summerOffPeak, nonSummerPeak, nonSummerOffPeak
    }

    public init(summerPeak: Double = 5.16, summerOffPeak: Double = 2.06,
                nonSummerPeak: Double = 4.93, nonSummerOffPeak: Double = 1.99,
                offPeakDates: Set<String> = []) {
        self.summerPeak = summerPeak
        self.summerOffPeak = summerOffPeak
        self.nonSummerPeak = nonSummerPeak
        self.nonSummerOffPeak = nonSummerOffPeak
        self.offPeakDates = offPeakDates
    }

    public static let taipowerSimpleTwoStage = TouTariff()

    /// Rates from the source's published tariff.
    public init(report: TariffReport) {
        self.init(summerPeak: report.summerPeak, summerOffPeak: report.summerOffPeak,
                  nonSummerPeak: report.nonSummerPeak, nonSummerOffPeak: report.nonSummerOffPeak,
                  offPeakDates: Set(report.offPeakDates))
    }

    /// Taiwan time. Summer is June 1 – September 30. Weekday peak: summer 09:00–24:00,
    /// otherwise 06:00–11:00 and 14:00–24:00. Saturdays, Sundays and `offPeakDates` are
    /// off-peak all day.
    public func rate(at date: Date, calendar: Calendar = .taipei) -> Double {
        period(at: date, calendar: calendar).rate
    }

    /// "非夏月離峰" and its rate, for showing the current price.
    public func period(at date: Date, calendar: Calendar = .taipei) -> (name: String, rate: Double) {
        let summer = Self.isSummer(date, calendar: calendar)
        let hour = calendar.component(.hour, from: date)
        let peak = peakHours(on: date, calendar: calendar).contains { $0.contains(hour) }
        return (Self.periodName(summer: summer, peak: peak), rate(summer: summer, peak: peak))
    }

    /// Why the whole day is off-peak ("週末" or "放假日"), or nil on a normal weekday.
    public func offPeakReason(on date: Date, calendar: Calendar = .taipei) -> String? {
        let weekday = calendar.component(.weekday, from: date)
        if weekday == 1 || weekday == 7 { return "週末" }
        return offPeakDates.contains(Self.dayKey(date, calendar: calendar)) ? "放假日" : nil
    }

    /// Peak hour ranges of that day; empty when the whole day is off-peak.
    public func peakHours(on date: Date, calendar: Calendar = .taipei) -> [Range<Int>] {
        guard offPeakReason(on: date, calendar: calendar) == nil else { return [] }
        return Self.isSummer(date, calendar: calendar) ? [9 ..< 24] : [6 ..< 11, 14 ..< 24]
    }

    /// The day split into contiguous peak/off-peak segments covering 0–24 h.
    public func schedule(on date: Date, calendar: Calendar = .taipei) -> [TariffSegment] {
        let summer = Self.isSummer(date, calendar: calendar)
        let peaks = peakHours(on: date, calendar: calendar)
        var segments: [TariffSegment] = []
        for hour in 0 ..< 24 {
            let peak = peaks.contains { $0.contains(hour) }
            if let last = segments.last, last.isPeak == peak {
                segments[segments.count - 1].endHour = hour + 1
            } else {
                segments.append(TariffSegment(startHour: hour, endHour: hour + 1, isPeak: peak,
                                              name: Self.periodName(summer: summer, peak: peak),
                                              rate: rate(summer: summer, peak: peak)))
            }
        }
        return segments
    }

    /// The next moment the price changes after `date`, within the coming 21 days.
    public func nextChange(after date: Date, calendar: Calendar = .taipei) -> Date? {
        let current = period(at: date, calendar: calendar)
        guard let hourStart = calendar.dateInterval(of: .hour, for: date)?.start else { return nil }
        for offset in 1 ... 21 * 24 {
            guard let moment = calendar.date(byAdding: .hour, value: offset, to: hourStart) else { return nil }
            if period(at: moment, calendar: calendar) != current { return moment }
        }
        return nil
    }

    /// Cost of a constant load over the calendar day containing `day`, hour by hour.
    public func costPerDay(watts: Double, day: Date, calendar: Calendar = .taipei) -> Double {
        let start = calendar.startOfDay(for: day)
        return (0 ..< 24).reduce(0) { total, hour in
            let moment = calendar.date(byAdding: .hour, value: hour, to: start) ?? start
            return total + watts / 1000 * rate(at: moment, calendar: calendar)
        }
    }

    private func rate(summer: Bool, peak: Bool) -> Double {
        switch (summer, peak) {
        case (true, true): return summerPeak
        case (true, false): return summerOffPeak
        case (false, true): return nonSummerPeak
        case (false, false): return nonSummerOffPeak
        }
    }

    private static func periodName(summer: Bool, peak: Bool) -> String {
        "\(summer ? "夏月" : "非夏月")\(peak ? "尖峰" : "離峰")"
    }

    private static func isSummer(_ date: Date, calendar: Calendar) -> Bool {
        (6 ... 9).contains(calendar.component(.month, from: date))
    }

    /// "YYYY-MM-DD" in the calendar's time zone.
    public static func dayKey(_ date: Date, calendar: Calendar = .taipei) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One stretch of a day at a single price; `endHour` is exclusive (24 = midnight).
public struct TariffSegment: Hashable, Sendable {
    public var startHour: Int
    public var endHour: Int
    public var isPeak: Bool
    public var name: String
    public var rate: Double
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
    /// The coin mined and its USD price: the machine's own (feature `coins`) or the feed's market.
    public let coin: String?
    public let coinUsd: Double?
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
        // A machine on another coin brings its own price; never price it in the market coin.
        let ownCoin = status?.earnings?.coin
        let symbol = ownCoin ?? market?.coin
        let price = ownCoin != nil ? status?.earnings?.coinUsd : market?.coinUsd
        var btcPerDay: Double?
        var revenue: Double?
        if let coin = coinPerDay, let coinUsd = price {
            if let btcUsd = market?.btcUsd { btcPerDay = coin * coinUsd / btcUsd }
            if let usdTwd = market?.usdTwd { revenue = coin * coinUsd * usdTwd }
        }
        let gpuWatts = status?.gpus?.compactMap(\.powerW)
        let power = gpuWatts.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) + max(0, extraWatts) }
        let electricity: Double? = billed ? power.map { tariff.costPerDay(watts: $0, day: day, calendar: calendar) } : 0
        let net: Double? = revenue.flatMap { value in electricity.map { value - $0 } }
        return MachineEarnings(coinPerDay: coinPerDay, coin: symbol, coinUsd: price, btcPerDay: btcPerDay, revenueTwdPerDay: revenue,
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
