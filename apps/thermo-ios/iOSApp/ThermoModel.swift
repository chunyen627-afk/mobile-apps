import Foundation
import SwiftUI
import ThermoCore

/// Which thermometer a screen shows: the same thermometer may be heard by two gateways.
struct ThermoSensorRef: Hashable {
    let gateway: String
    let sensor: String
}

/// The thermometer tab's state: the configured gateways (one per line, stored on this phone),
/// each read every 30 seconds while the tab is on screen, and the phone's own names.
/// With no gateway configured the tab shows built-in demo readings.
@MainActor
final class ThermoModel: ObservableObject {
    static let gatewaysKey = "thermo.gateways"
    static let preferencesKey = "thermo.preferences"
    static let pollSeconds: UInt64 = 30

    @Published private(set) var gatewayText: String
    @Published private(set) var gateways: [ThermoGatewayState] = []
    @Published private(set) var demo: ThermoGatewayState?
    @Published private(set) var refreshing = false
    @Published var preferences: ThermoPreferences {
        didSet { defaults.set(preferences.encoded(), forKey: Self.preferencesKey) }
    }

    private let defaults: UserDefaults
    private let client: ThermoClient

    init(environment: [String: String] = ProcessInfo.processInfo.environment, client: ThermoClient = ThermoClient()) {
        // UI tests start from a clean, throwaway store, optionally with gateways preset.
        let uiTest = environment["THERMO_UI_TEST"] == "1" || environment["THERMO_UI_GATEWAYS"] != nil
        if uiTest, let suite = UserDefaults(suiteName: "org.personal.thermo.uitest") {
            suite.removePersistentDomain(forName: "org.personal.thermo.uitest")
            if let preset = environment["THERMO_UI_GATEWAYS"] {
                suite.set(preset.replacingOccurrences(of: "|", with: "\n"), forKey: Self.gatewaysKey)
            }
            defaults = suite
        } else {
            defaults = .standard
        }
        self.client = client
        gatewayText = defaults.string(forKey: Self.gatewaysKey) ?? ""
        preferences = ThermoPreferences.decoded(defaults.data(forKey: Self.preferencesKey))
        rebuildGateways()
    }

    var isDemo: Bool { gateways.isEmpty }

    /// What the list shows: the configured gateways, or the demo.
    var shown: [ThermoGatewayState] {
        if isDemo { return demo.map { [$0] } ?? [] }
        return gateways
    }

    func setGatewayText(_ text: String) {
        let cleaned = ThermoGatewayList.lines(text).joined(separator: "\n")
        defaults.set(cleaned, forKey: Self.gatewaysKey)
        gatewayText = cleaned
        rebuildGateways()
        Task { await refresh() }
    }

    private func rebuildGateways() {
        let old = Dictionary(gateways.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        gateways = ThermoGatewayList.endpoints(gatewayText).map { endpoint in
            old[endpoint.sensorsURL.absoluteString] ?? ThermoGatewayState(endpoint: endpoint)
        }
    }

    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
        }
    }

    func refresh() async {
        if isDemo {
            if let endpoint = try? ThermoEndpoint(validating: "demo.invalid") {
                demo = ThermoGatewayState(endpoint: endpoint, feed: .demo(now: Int(Date().timeIntervalSince1970)), receivedAt: Date())
            }
            return
        }
        refreshing = true
        defer { refreshing = false }
        let client = self.client
        let endpoints = gateways.map(\.endpoint)
        let results = await withTaskGroup(of: (String, Result<ThermoFeed, ThermoFetchError>).self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let id = endpoint.sensorsURL.absoluteString
                    do {
                        return (id, .success(try await client.fetch(endpoint)))
                    } catch let error as ThermoFetchError {
                        return (id, .failure(error))
                    } catch {
                        return (id, .failure(.offline("連線失敗")))
                    }
                }
            }
            var out: [String: Result<ThermoFeed, ThermoFetchError>] = [:]
            for await (id, result) in group {
                out[id] = result
            }
            return out
        }
        let now = Date()
        for index in gateways.indices {
            switch results[gateways[index].id] {
            case .success(let feed):
                gateways[index].feed = feed
                gateways[index].receivedAt = now
                gateways[index].error = nil
            case .failure(let error):
                gateways[index].error = error
            case nil:
                break
            }
        }
    }

    func sensor(_ ref: ThermoSensorRef) -> (ThermoGatewayState, ThermoSensor)? {
        guard let gateway = shown.first(where: { $0.id == ref.gateway }),
              let sensor = gateway.feed?.sensors.first(where: { $0.id == ref.sensor }) else { return nil }
        return (gateway, sensor)
    }

    /// One thermometer's history from its gateway (made-up curves in the demo).
    func history(_ ref: ThermoSensorRef, range: ThermoRange) async -> Result<ThermoHistory, ThermoFetchError> {
        guard let found = self.sensor(ref) else { return .failure(.malformed) }
        let gateway = found.0, thermometer = found.1
        if isDemo {
            let now = gateway.gatewayNow(phoneNow: Date()) ?? Int(Date().timeIntervalSince1970)
            return .success(.demo(for: thermometer, range: range, now: now, utcOffset: TimeZone.current.secondsFromGMT()))
        }
        do {
            return .success(try await client.history(gateway.endpoint, id: thermometer.id, range: range))
        } catch let error as ThermoFetchError {
            return .failure(error)
        } catch {
            return .failure(.offline("連線失敗"))
        }
    }

    func displayName(_ sensor: ThermoSensor) -> String {
        preferences.displayName(sensor)
    }

    /// Every thermometer from every gateway shown.
    var allRows: [ThermoRowItem] {
        shown.flatMap { gateway in
            (gateway.feed?.sensors ?? []).map { ThermoRowItem(gateway: gateway, sensor: $0) }
        }
    }

    /// Visible thermometers by room, as Mi Home lists devices.
    var roomGroups: [ThermoRoomGroup<ThermoRowItem>] {
        preferences.byRoom(allRows) { $0.sensor }
    }

    /// Hidden thermometers from every gateway, for the bottom section.
    var hiddenRows: [ThermoRowItem] {
        allRows.filter { preferences.hidden.contains($0.sensor.id) }
            .sorted { displayName($0.sensor).localizedStandardCompare(displayName($1.sensor)) == .orderedAscending }
    }

    /// Visible thermometers whose battery needs replacing.
    var lowBatteryRows: [ThermoRowItem] {
        allRows.filter { !preferences.hidden.contains($0.sensor.id) && ThermoText.isBatteryLow($0.sensor.battery) }
    }

    /// Gateways with something to say: unreachable, still loading, or hearing no thermometer.
    var gatewayNotices: [ThermoGatewayNotice] {
        guard !isDemo else { return [] }
        return gateways.compactMap { gateway in
            if let error = gateway.error {
                let suffix = gateway.feed == nil ? "" : "（顯示上次讀到的資料）"
                return ThermoGatewayNotice(id: gateway.id, title: gateway.title, text: error.displayText + suffix, isError: true)
            }
            guard let feed = gateway.feed else {
                return ThermoGatewayNotice(id: gateway.id, title: gateway.title, text: "讀取中…", isError: false)
            }
            if feed.sensors.isEmpty {
                return ThermoGatewayNotice(id: gateway.id, title: gateway.title, text: "還沒聽到任何溫濕度計", isError: false)
            }
            return nil
        }
    }

    /// Rooms to offer: Mi Home's usual rooms plus every room already in use (here or on the gateways).
    var roomChoices: [String] {
        var out = ["客廳", "臥室", "書房", "廚房", "浴室", "陽台", "辦公室"]
        let inUse = preferences.allRooms + allRows.compactMap { $0.sensor.room }.filter { !$0.isEmpty }
        for room in inUse where !out.contains(room) {
            out.append(room)
        }
        return out
    }

    /// Renames on this phone and on the gateways that hear it (empty: back to the gateway's own name).
    func rename(_ sensor: ThermoSensor, to text: String) {
        preferences.rename(sensor, to: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nil : String(trimmed.prefix(ThermoPreferences.maxNameLength))
        pushLabel(sensor, name: name, room: preferences.room(for: sensor))
    }

    /// Sets the room on this phone and on the gateways that hear it (nil: no room).
    func setRoom(_ sensor: ThermoSensor, _ room: String?) {
        preferences.setRoom(sensor.id, room)
        pushLabel(sensor, name: preferences.names[sensor.id] ?? sensor.label, room: preferences.room(sensor.id))
    }

    /// Set when the last name or room could not reach a gateway; the phone keeps it anyway.
    @Published private(set) var syncError: String?

    private func pushLabel(_ sensor: ThermoSensor, name: String?, room: String?) {
        guard !isDemo else { return }
        let targets = gateways.filter { $0.feed?.sensors.contains { $0.id == sensor.id } == true }.map(\.endpoint)
        let client = self.client
        Task {
            var failure: ThermoFetchError?
            for endpoint in targets {
                do {
                    try await client.setLabel(endpoint, id: sensor.id, name: name, room: room)
                } catch let error as ThermoFetchError {
                    failure = error
                } catch {
                    failure = .offline("連線失敗")
                }
            }
            syncError = failure.map { "名稱與房間沒同步到閘道（\($0.displayText)），這支手機上已改好。" }
            await refresh()
        }
    }

    /// The notification rules of the gateway that hears this thermometer.
    func alerts(_ ref: ThermoSensorRef) -> ThermoAlertRules? {
        shown.first { $0.id == ref.gateway }?.feed?.alerts
    }
}

struct ThermoGatewayNotice: Identifiable {
    let id: String
    let title: String
    let text: String
    let isError: Bool
}

struct ThermoRowItem: Identifiable {
    let gateway: ThermoGatewayState
    let sensor: ThermoSensor

    var id: String { gateway.id + "|" + sensor.id }
}
