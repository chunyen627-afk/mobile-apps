import SwiftUI
import WatchLinkCore

@main
struct WatchLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, service: model.service)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: PeripheralService

    var body: some View {
        NavigationStack {
            List {
                Section("手錶連線") {
                    LabeledContent("狀態", value: service.stateText)
                    LabeledContent("已同步次數", value: "\(service.syncCount)")
                    if let last = service.lastSync {
                        LabeledContent("上次同步", value: last.formatted(date: .omitted, time: .standard))
                    }
                }

                Section("天氣") {
                    Picker("地點", selection: $model.placeName) {
                        ForEach(Place.all) { place in
                            Text(place.name).tag(place.name)
                        }
                    }
                    if let w = model.weather {
                        LabeledContent("現在", value: "\(w.text) \(Self.degrees(w.tempC))")
                        LabeledContent("高低溫", value: "\(Self.degrees(w.highC))／\(Self.degrees(w.lowC))")
                        LabeledContent("降雨機率", value: "\(w.rainPercent)%")
                    } else if let error = model.weatherError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("尚未取得").foregroundStyle(.secondary)
                    }
                    if !model.isDemo {
                        Button("立即更新天氣") { Task { await model.refreshWeather() } }
                    }
                }

                Section("行事曆") {
                    if model.calendarAuthorized {
                        Toggle("把行程送到手錶", isOn: $model.calendarEnabled)
                        if model.calendarEnabled {
                            if model.events.isEmpty {
                                Text("未來 7 天沒有行程").foregroundStyle(.secondary)
                            }
                            ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title)
                                    Text(Self.when(event)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Button("允許讀取行事曆") { Task { await model.requestCalendarAccess() } }
                    }
                }

                Section("說明") {
                    Text("這個 App 要保持在背景，手錶才要得到資料。請不要從多工畫面把它滑掉。")
                        .font(.footnote)
                    Text("資料只經由藍牙送到已配對的手錶。天氣來自 Open-Meteo。")
                        .font(.footnote)
                }
            }
            .navigationTitle("手錶連結")
            .toolbar { NavigationLink("導航") { TripView(trip: model.trip, service: service) } }
            .onChange(of: model.calendarEnabled) { _, _ in
                if !model.isDemo { model.refreshEvents() }
            }
            .task {
                if !model.isDemo {
                    await model.refreshWeather()
                    model.refreshEvents()
                }
            }
        }
    }

    static func degrees(_ value: Double) -> String {
        String(format: "%.0f°C", value)
    }

    static func when(_ event: EventInfo) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(event.startMs) / 1000)
        let text = event.allDay
            ? date.formatted(date: .abbreviated, time: .omitted) + " 整天"
            : date.formatted(date: .abbreviated, time: .shortened)
        return event.location.isEmpty ? text : text + "・" + event.location
    }
}
