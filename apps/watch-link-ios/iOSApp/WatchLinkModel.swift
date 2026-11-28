import EventKit
import Foundation
import UIKit
import WatchLinkCore

struct Place: Identifiable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name }

    static let all: [Place] = [
        Place(name: "台北", latitude: 25.033, longitude: 121.565),
        Place(name: "新北", latitude: 25.012, longitude: 121.465),
        Place(name: "桃園", latitude: 24.994, longitude: 121.301),
        Place(name: "新竹", latitude: 24.804, longitude: 120.971),
        Place(name: "台中", latitude: 24.148, longitude: 120.674),
        Place(name: "嘉義", latitude: 23.480, longitude: 120.449),
        Place(name: "台南", latitude: 22.999, longitude: 120.227),
        Place(name: "高雄", latitude: 22.627, longitude: 120.301),
        Place(name: "宜蘭", latitude: 24.757, longitude: 121.753),
        Place(name: "花蓮", latitude: 23.991, longitude: 121.611),
        Place(name: "台東", latitude: 22.758, longitude: 121.144),
    ]
}

/// App 的狀態：設定、天氣、行事曆，以及要送給手錶的資料。
@MainActor
final class WatchLinkModel: ObservableObject {
    let service = PeripheralService()
    lazy var trip = TripController(service: service)
    private let store = EKEventStore()
    private let defaults = UserDefaults.standard

    @Published var placeName: String {
        didSet {
            defaults.set(placeName, forKey: "place")
            weather = nil
        }
    }
    @Published var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: "calendarEnabled") }
    }
    @Published var weather: WeatherInfo?
    @Published var weatherError: String?
    @Published var events: [EventInfo] = []
    @Published var calendarAuthorized = false

    let isDemo: Bool

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("-uiTestDemo")
        placeName = defaults.string(forKey: "place") ?? "台北"
        calendarEnabled = defaults.bool(forKey: "calendarEnabled")
        UIDevice.current.isBatteryMonitoringEnabled = true
        if isDemo {
            loadDemo()
        } else {
            calendarAuthorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            service.snapshotProvider = { [weak self] in
                await self?.makeSnapshot() ?? Snapshot(nowMs: 0, battery: -1, weather: nil, events: [])
            }
            service.start()
        }
    }

    var place: Place { Place.all.first { $0.name == placeName } ?? Place.all[0] }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 手錶要資料時呼叫。天氣 30 分鐘內用快取，避免每次都連網。
    func makeSnapshot() async -> Snapshot {
        if weather == nil || nowMs() - (weather?.fetchedAtMs ?? 0) > 30 * 60 * 1000 {
            await refreshWeather()
        }
        refreshEvents()
        let level = UIDevice.current.batteryLevel
        return Snapshot(
            nowMs: nowMs(),
            battery: level < 0 ? -1 : Int((level * 100).rounded()),
            weather: weather,
            events: events
        )
    }

    func refreshWeather() async {
        let target = place
        guard let url = OpenMeteo.url(latitude: target.latitude, longitude: target.longitude) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let parsed = OpenMeteo.parse(data, place: target.name, fetchedAtMs: nowMs()) {
                weather = parsed
                weatherError = nil
            } else {
                weatherError = "天氣資料格式無法解析"
            }
        } catch {
            weatherError = "無法取得天氣：\(error.localizedDescription)"
        }
    }

    func requestCalendarAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        calendarAuthorized = granted
        if granted {
            calendarEnabled = true
            refreshEvents()
        }
    }

    func refreshEvents() {
        guard calendarEnabled, calendarAuthorized else {
            events = []
            return
        }
        let now = Date()
        let end = now.addingTimeInterval(7 * 24 * 3600)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate).map { e in
            EventInfo(
                title: e.title ?? "",
                startMs: Int64(e.startDate.timeIntervalSince1970 * 1000),
                endMs: Int64(e.endDate.timeIntervalSince1970 * 1000),
                allDay: e.isAllDay,
                location: e.location ?? ""
            )
        }
        events = EventPicker.upcoming(found, nowMs: nowMs(), limit: 5)
    }

    private func loadDemo() {
        let now = nowMs()
        weather = WeatherInfo(place: "台北", tempC: 22.4, code: 80, text: "陣雨", highC: 25.1, lowC: 19.3, rainPercent: 65, fetchedAtMs: now)
        calendarAuthorized = true
        calendarEnabled = true
        events = [
            EventInfo(title: "示範行程：週會", startMs: now + 3_600_000, endMs: now + 7_200_000, allDay: false, location: "會議室"),
            EventInfo(title: "示範行程：晚餐", startMs: now + 18_000_000, endMs: now + 21_600_000, allDay: false, location: ""),
        ]
        service.stateText = "示範模式（未啟動藍牙）"
    }
}
