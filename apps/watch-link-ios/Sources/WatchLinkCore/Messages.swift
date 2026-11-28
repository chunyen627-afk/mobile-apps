import Foundation

/// 手錶送來的請求。目前只有 `sync`。
public struct WatchRequest: Codable, Equatable {
    public var t: String
    public init(t: String) { self.t = t }
}

public struct WeatherInfo: Codable, Equatable {
    public var place: String
    public var tempC: Double
    public var code: Int
    public var text: String
    public var highC: Double
    public var lowC: Double
    public var rainPercent: Int
    public var fetchedAtMs: Int64

    public init(place: String, tempC: Double, code: Int, text: String, highC: Double, lowC: Double, rainPercent: Int, fetchedAtMs: Int64) {
        self.place = place
        self.tempC = tempC
        self.code = code
        self.text = text
        self.highC = highC
        self.lowC = lowC
        self.rainPercent = rainPercent
        self.fetchedAtMs = fetchedAtMs
    }
}

public struct EventInfo: Codable, Equatable {
    public var title: String
    public var startMs: Int64
    public var endMs: Int64
    public var allDay: Bool
    public var location: String

    public init(title: String, startMs: Int64, endMs: Int64, allDay: Bool, location: String) {
        self.title = title
        self.startMs = startMs
        self.endMs = endMs
        self.allDay = allDay
        self.location = location
    }
}

/// iPhone 回給手錶的一份資料。
public struct Snapshot: Codable, Equatable {
    public var t: String
    public var nowMs: Int64
    public var battery: Int
    public var weather: WeatherInfo?
    public var events: [EventInfo]

    public init(nowMs: Int64, battery: Int, weather: WeatherInfo?, events: [EventInfo]) {
        self.t = "snapshot"
        self.nowMs = nowMs
        self.battery = battery
        self.weather = weather
        self.events = events
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

public enum EventPicker {
    /// 還沒結束的行程，依開始時間排序，最多 `limit` 筆。
    public static func upcoming(_ events: [EventInfo], nowMs: Int64, limit: Int) -> [EventInfo] {
        Array(events.filter { $0.endMs > nowMs }.sorted { $0.startMs < $1.startMs }.prefix(limit))
    }
}
