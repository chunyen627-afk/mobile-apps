@testable import ThermoCore
import XCTest

private let sampleFeed = """
{"version": 1, "gateway": "office", "time": 1000000, "sensors": [
 {"id": "A4:C1:38:00:00:01", "name": "ATC_000001", "advertised_name": "ATC_000001", "temperature": 24.76,
  "humidity": 68.37, "battery": 93, "voltage": 2.953, "rssi": -45, "updated": 999990, "format": "bthome", "error": null},
 {"id": "A4:C1:38:00:00:04", "name": "陽台", "advertised_name": null, "temperature": null, "humidity": null,
  "battery": null, "voltage": null, "rssi": null, "updated": null, "format": null, "error": "連線讀取失敗"}]}
"""

final class EndpointTests: XCTestCase {
    func testHostPortBecomesSensorsURL() throws {
        XCTAssertEqual(try ThermoEndpoint(validating: " 192.0.2.10:18787 ").sensorsURL.absoluteString, "http://192.0.2.10:18787/sensors")
        XCTAssertEqual(try ThermoEndpoint(validating: "http://192.0.2.10:18787/").sensorsURL.absoluteString, "http://192.0.2.10:18787/sensors")
        XCTAssertEqual(try ThermoEndpoint(validating: "HTTP://gw.local:80/sensors?x=1#y").sensorsURL.absoluteString, "http://gw.local:80/sensors")
        XCTAssertEqual(try ThermoEndpoint(validating: "https://gw.example/api").sensorsURL.absoluteString, "https://gw.example/api/sensors")
        XCTAssertTrue(try ThermoEndpoint(validating: "192.0.2.10:18787").usesPlainHTTP)
    }

    func testRejectsBadInput() {
        let cases: [(String, ThermoEndpointError)] = [
            ("", .empty), ("   ", .empty), ("a b:80", .malformed), ("ftp://192.0.2.10", .unsupportedScheme),
            ("http://user:pw@192.0.2.10", .embeddedCredentials), ("http://", .missingHost),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try ThermoEndpoint(validating: text), text) { error in
                XCTAssertEqual(error as? ThermoEndpointError, expected, text)
            }
        }
    }

    func testHistoryURL() throws {
        let endpoint = try ThermoEndpoint(validating: "192.0.2.10:18787")
        XCTAssertEqual(endpoint.historyURL(id: "A4:C1:38:00:00:01", range: .week)?.absoluteString,
                       "http://192.0.2.10:18787/history?id=A4:C1:38:00:00:01&range=week")
        let nested = try ThermoEndpoint(validating: "https://gw.example/api")
        XCTAssertEqual(nested.historyURL(id: "x", range: .day)?.path, "/api/history")
    }
}

final class GatewayListTests: XCTestCase {
    func testLinesTrimDeduplicateAndCap() {
        let text = " 192.0.2.10:18787 \n\nhttp://192.0.2.10:18787/sensors\n192.0.2.11:18787\nnot a url\n"
        XCTAssertEqual(ThermoGatewayList.lines(text), ["192.0.2.10:18787", "192.0.2.11:18787", "not a url"])
        let parsed = ThermoGatewayList.parse(text)
        XCTAssertEqual(parsed.map(\.isValid), [true, true, false])
        XCTAssertEqual(ThermoGatewayList.endpoints(text).count, 2)
        let many = (1...12).map { "192.0.2.\($0):1" }.joined(separator: "\n")
        XCTAssertEqual(ThermoGatewayList.lines(many).count, ThermoGatewayList.maxGateways)
    }

    func testGatewayClockAdvancesWithThePhone() throws {
        let feed = try ThermoFeed.decode(Data(sampleFeed.utf8))
        let received = Date(timeIntervalSince1970: 5000)
        let state = ThermoGatewayState(endpoint: try ThermoEndpoint(validating: "192.0.2.10:1"), feed: feed, receivedAt: received)
        XCTAssertEqual(state.gatewayNow(phoneNow: received.addingTimeInterval(90)), 1_000_090)
        XCTAssertEqual(state.gatewayNow(phoneNow: received.addingTimeInterval(-30)), 1_000_000)
        XCTAssertEqual(state.title, "office")
        XCTAssertEqual(ThermoGatewayState(endpoint: try ThermoEndpoint(validating: "192.0.2.10:1")).title, "192.0.2.10")
    }
}

final class FeedTests: XCTestCase {
    func testDecodesTheGatewayFeed() throws {
        let feed = try ThermoFeed.decode(Data(sampleFeed.utf8))
        XCTAssertEqual(feed.gateway, "office")
        XCTAssertEqual(feed.sensors.count, 2)
        let first = feed.sensors[0]
        XCTAssertEqual(first.temperature, 24.76)
        XCTAssertEqual(first.battery, 93)
        XCTAssertEqual(first.advertisedName, "ATC_000001")
        XCTAssertNil(feed.sensors[1].temperature)
        XCTAssertEqual(feed.sensors[1].error, "連線讀取失敗")
    }

    func testRejectsOtherVersionsAndGarbage() {
        XCTAssertThrowsError(try ThermoFeed.decode(Data(#"{"version": 2, "gateway": "g", "time": 1, "sensors": []}"#.utf8))) {
            XCTAssertEqual($0 as? ThermoFetchError, .unsupportedVersion(2))
        }
        XCTAssertThrowsError(try ThermoFeed.decode(Data("<html>".utf8))) { XCTAssertEqual($0 as? ThermoFetchError, .malformed) }
        XCTAssertThrowsError(try ThermoFeed.decode(Data(#"{"version": 1, "gateway": "g"}"#.utf8))) {
            XCTAssertEqual($0 as? ThermoFetchError, .malformed)
        }
    }

    func testDecodesLabelRoomAndAlerts() throws {
        let body = #"{"version": 1, "gateway": "g", "time": 1, "sensors": [{"id": "a", "name": "書房溫度計", "label": "書房溫度計", "room": "書房"}], "alerts": {"enabled": true, "temperature_high": 32, "temperature_low": null, "humidity_high": 80, "humidity_low": 25, "battery_low": 15, "offline_after_seconds": 7200}}"#
        let feed = try ThermoFeed.decode(Data(body.utf8))
        XCTAssertEqual(feed.sensors[0].label, "書房溫度計")
        XCTAssertEqual(feed.sensors[0].room, "書房")
        let alerts = try XCTUnwrap(feed.alerts)
        XCTAssertTrue(alerts.enabled)
        XCTAssertEqual(alerts.lines(fahrenheit: false).map(\.value), ["高於 32.0°", "高於 80%、低於 25%", "低於 15%", "超過 2 小時"])
        XCTAssertEqual(alerts.lines(fahrenheit: true)[0].value, "高於 89.6°F")
        XCTAssertNil(try ThermoFeed.decode(Data(sampleFeed.utf8)).alerts, "older gateways send no rules")
    }

    func testDemoFeedUsesMadeUpAddresses() {
        let feed = ThermoFeed.demo(now: 1000)
        XCTAssertEqual(feed.sensors.count, 3)
        XCTAssertTrue(feed.sensors.allSatisfy { $0.id.hasPrefix("A4:C1:38:00:00:") })
    }
}

/// The requests a stub received. `@unchecked`: the tests read it only after the awaited call.
private final class RequestLog: @unchecked Sendable {
    var requests: [URLRequest] = []
}

private struct StubTransport: ThermoTransport {
    let status: Int
    let contentType: String
    let body: Data
    var failure: URLError?
    var log: RequestLog?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        log?.requests.append(request)
        if let failure { throw failure }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        return (body, response)
    }
}

final class ClientTests: XCTestCase {
    private let endpoint = try! ThermoEndpoint(validating: "192.0.2.10:18787")

    private func client(_ status: Int = 200, _ type: String = "application/json; charset=utf-8", _ body: String = sampleFeed,
                        failure: URLError? = nil) -> ThermoClient {
        ThermoClient(transport: StubTransport(status: status, contentType: type, body: Data(body.utf8), failure: failure))
    }

    func testFetchesAFeed() async throws {
        let log = RequestLog()
        let stub = StubTransport(status: 200, contentType: "application/json", body: Data(sampleFeed.utf8), log: log)
        let feed = try await ThermoClient(transport: stub).fetch(endpoint)
        XCTAssertEqual(feed.sensors.count, 2)
        XCTAssertEqual(log.requests.first?.httpMethod, "GET")
    }

    func testSetLabelPostsTheNameAndRoom() async throws {
        let log = RequestLog()
        let stub = StubTransport(status: 200, contentType: "application/json", body: Data(#"{"ok": true}"#.utf8), log: log)
        try await ThermoClient(transport: stub).setLabel(endpoint, id: "A4:C1:38:00:00:01", name: "書房溫度計", room: nil)
        let request = try XCTUnwrap(log.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://192.0.2.10:18787/labels")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "A4:C1:38:00:00:01")
        XCTAssertEqual(body["name"] as? String, "書房溫度計")
        XCTAssertNil(body["room"] as? String)
        do {
            try await client(404, "application/json", #"{"error": "unknown thermometer"}"#).setLabel(endpoint, id: "x", name: nil, room: nil)
            XCTFail("expected 404")
        } catch {
            XCTAssertEqual(error as? ThermoFetchError, .http(404))
        }
    }

    func testFailures() async {
        let cases: [(ThermoClient, ThermoFetchError)] = [
            (client(403, "application/json", #"{"error": "forbidden"}"#), .http(403)),
            (client(200, "text/html", "<html>"), .notJSON),
            (client(200, "application/json", String(repeating: " ", count: ThermoClient.maxResponseBytes + 1)), .tooLarge),
            (client(failure: URLError(.timedOut)), .offline("逾時")),
            (client(failure: URLError(.cannotConnectToHost)), .offline("主機沒有回應")),
        ]
        for (client, expected) in cases {
            do {
                _ = try await client.fetch(endpoint)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ThermoFetchError, expected)
            }
        }
        XCTAssertTrue(ThermoFetchError.http(403).displayText.contains("網段"))
    }

    func testFetchesHistory() async throws {
        let body = #"{"version": 1, "id": "A4:C1:38:00:00:01", "range": "day", "bucket": 300, "time": 1000, "points": [{"t": 600, "temperature": 24.5, "humidity": 60.0, "battery": 90}]}"#
        let history = try await client(200, "application/json", body).history(endpoint, id: "A4:C1:38:00:00:01", range: .day)
        XCTAssertEqual(history.points, [ThermoPoint(t: 600, temperature: 24.5, humidity: 60.0, battery: 90)])
    }
}

final class HistoryTests: XCTestCase {
    private func history(_ points: [ThermoPoint], range: ThermoRange = .day) -> ThermoHistory {
        ThermoHistory(id: "x", range: range, time: 100_000, points: points)
    }

    func testSummary() throws {
        let h = history([ThermoPoint(t: 0, temperature: 20, humidity: nil, battery: 90),
                         ThermoPoint(t: 1800, temperature: 26, humidity: 50, battery: 80),
                         ThermoPoint(t: 3600, temperature: nil, humidity: 70, battery: nil)])
        XCTAssertEqual(h.summary(.temperature), ThermoSummary(min: 20, max: 26, average: 23))
        XCTAssertEqual(h.summary(.humidity), ThermoSummary(min: 50, max: 70, average: 60))
        XCTAssertEqual(h.summary(.battery)?.min, 80)
        XCTAssertNil(history([]).summary(.temperature))
    }

    func testDailySummaryUsesEachDaysLowestAndHighest() {
        let h = history([ThermoPoint(t: 0, temperature: 22, humidity: 50, battery: 90, temperatureMin: 18, temperatureMax: 27,
                                     humidityMin: 40, humidityMax: 66),
                         ThermoPoint(t: 86400, temperature: 24, humidity: 60, battery: 89, temperatureMin: 21, temperatureMax: 29)],
                        range: .week)
        XCTAssertEqual(h.summary(.temperature), ThermoSummary(min: 18, max: 29, average: 23))
        XCTAssertEqual(h.summary(.humidity), ThermoSummary(min: 40, max: 66, average: 55))
        XCTAssertEqual(h.points[1].low(.humidity), 60, "a day without its own lowest uses its mean")
    }

    func testDecodesDailyPoints() throws {
        let body = #"{"version": 1, "id": "x", "range": "week", "bucket": 86400, "time": 1, "utc_offset": 28800, "points": [{"t": 0, "temperature": 22.5, "humidity": 50.0, "battery": 90, "temperature_min": 20.1, "temperature_max": 25.0, "humidity_min": 40.0, "humidity_max": 61.0}]}"#
        let h = try ThermoHistory.decode(Data(body.utf8))
        XCTAssertEqual(h.utcOffset, 28800)
        XCTAssertEqual(h.points[0].high(.temperature), 25.0)
        XCTAssertEqual(h.points[0].low(.humidity), 40.0)
    }

    func testGapsSplitTheLine() {
        let h = history([1800, 3600, 5400, 12600, 14400].map { ThermoPoint(t: $0, temperature: 20, humidity: nil, battery: nil) })
        XCTAssertEqual(h.segments(.temperature).map { $0.map(\.t) }, [[1800, 3600, 5400], [12600, 14400]])
        XCTAssertEqual(h.segments(.humidity).count, 0)
    }

    func testDemoHistoryEndsAtTheReading() {
        let taipei = 8 * 3600
        let now = 20 * 86400 - taipei + 10 * 3600  // 10:00 local
        let sensor = ThermoFeed.demo(now: now).sensors[0]
        let day = ThermoHistory.demo(for: sensor, range: .day, now: now, utcOffset: taipei)
        XCTAssertEqual(day.points.count, 48)
        XCTAssertEqual(day.segments(.temperature).count, 1)
        XCTAssertLessThanOrEqual(day.points.last!.t, now)
        XCTAssertGreaterThan(day.summary(.temperature)!.max - day.summary(.temperature)!.min, 2)
        for range in [ThermoRange.week, .month] {
            let h = ThermoHistory.demo(for: sensor, range: range, now: now, utcOffset: taipei)
            XCTAssertEqual(h.points.count, range.days, range.rawValue)
            XCTAssertTrue(h.points.allSatisfy { ($0.t + taipei) % 86400 == 0 }, "days start at local midnight")
            XCTAssertGreaterThan(h.points[0].high(.temperature)! - h.points[0].low(.temperature)!, 2)
        }
    }

    func testRangesAndMetrics() {
        XCTAssertEqual(ThermoRange.allCases.map(\.title), ["日", "週", "月"])
        XCTAssertEqual(ThermoRange.allCases.map(\.bucket), [1800, 86400, 86400])
        XCTAssertEqual(ThermoMetric.allCases.map(\.title), ["溫度", "濕度", "電量"])
        XCTAssertEqual(ThermoMetric.battery.format(87.4), "87%")
        XCTAssertEqual(ThermoMetric.temperature.format(25, fahrenheit: true), "77.0°F")
        XCTAssertEqual(ThermoMetric.temperature.display(100, fahrenheit: true), 212)
        XCTAssertEqual(ThermoMetric.humidity.display(50, fahrenheit: true), 50)
    }
}

final class ComfortTests: XCTestCase {
    func testLevels() {
        let zone = ThermoComfortZone.standard
        XCTAssertEqual(ThermoComfort.level(temperature: 23, humidity: 50, zone: zone), .comfortable)
        XCTAssertEqual(ThermoComfort.level(temperature: 28, humidity: 70, zone: zone).text, "偏熱・潮濕")
        XCTAssertEqual(ThermoComfort.level(temperature: 18, humidity: 30, zone: zone).text, "偏冷・乾燥")
        XCTAssertEqual(ThermoComfort.level(temperature: nil, humidity: 65, zone: zone).text, "潮濕")
        XCTAssertEqual(ThermoComfort.level(temperature: nil, humidity: nil, zone: zone), .unknown)
        XCTAssertTrue(ThermoComfort.level(temperature: 26, humidity: 60, zone: zone).isComfortable, "the limits are comfortable")
    }

    func testZoneKeepsLowBelowHigh() {
        var zone = ThermoComfortZone.standard
        zone.temperatureLow = 30
        zone.humidityLow = 70
        zone.normalize()
        XCTAssertEqual(zone.temperatureHigh, 31)
        XCTAssertEqual(zone.humidityHigh, 75)
    }
}

final class RoomTests: XCTestCase {
    private let sensors = [
        ThermoSensor(id: "A4:C1:38:00:00:01", name: "Sensor 1"),
        ThermoSensor(id: "A4:C1:38:00:00:02", name: "Sensor 2"),
        ThermoSensor(id: "A4:C1:38:00:00:03", name: "Sensor 3"),
        ThermoSensor(id: "A4:C1:38:00:00:04", name: "Sensor 4"),
    ]

    func testGroupsByRoomWithTheUnassignedLast() {
        var prefs = ThermoPreferences()
        prefs.setRoom("A4:C1:38:00:00:01", " 臥室 ")
        prefs.setRoom("A4:C1:38:00:00:02", "Bedroom")
        prefs.setRoom("A4:C1:38:00:00:03", "臥室")
        prefs.setHidden("A4:C1:38:00:00:03", true)
        let groups = prefs.byRoom(sensors) { $0 }
        XCTAssertEqual(groups.map(\.room), ["Bedroom", "臥室", ThermoPreferences.noRoom])
        XCTAssertEqual(groups.map { $0.items.map(\.name) }, [["Sensor 2"], ["Sensor 1"], ["Sensor 4"]])
        XCTAssertEqual(prefs.allRooms, ["Bedroom", "臥室"])
        prefs.setRoom("A4:C1:38:00:00:01", "  ")
        XCTAssertNil(prefs.room("A4:C1:38:00:00:01"))
    }

    func testThePhonesRoomWinsOverTheGateways() {
        var prefs = ThermoPreferences()
        let fromGateway = ThermoSensor(id: "a", name: "A", room: "客廳")
        XCTAssertEqual(prefs.room(for: fromGateway), "客廳")
        XCTAssertEqual(prefs.byRoom([fromGateway]) { $0 }.map(\.room), ["客廳"])
        prefs.setRoom("a", "書房")
        XCTAssertEqual(prefs.room(for: fromGateway), "書房")
        XCTAssertNil(prefs.room(for: ThermoSensor(id: "b", name: "B", room: "")))
    }

    func testOlderSettingsStillLoad() {
        let old = Data(#"{"names": {"a": "A"}, "hidden": ["b"]}"#.utf8)
        let prefs = ThermoPreferences.decoded(old)
        XCTAssertEqual(prefs.names, ["a": "A"])
        XCTAssertEqual(prefs.hidden, ["b"])
        XCTAssertEqual(prefs.comfort, .standard)
        XCTAssertFalse(prefs.fahrenheit)
        XCTAssertTrue(prefs.rooms.isEmpty)
    }

    func testUnitAndComfortRoundTrip() {
        var prefs = ThermoPreferences()
        prefs.fahrenheit = true
        prefs.comfort.temperatureHigh = 28
        prefs.setRoom("a", "書房")
        let again = ThermoPreferences.decoded(prefs.encoded())
        XCTAssertEqual(again, prefs)
        XCTAssertEqual(again.temperature(25), "77.0°F")
        XCTAssertEqual(again.comfortLevel(ThermoSensor(id: "a", name: "a", temperature: 27, humidity: 50)), .comfortable)
    }
}

final class TextTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(ThermoText.temperature(24.76), "24.8°")
        XCTAssertEqual(ThermoText.temperature(-3.04), "-3.0°")
        XCTAssertEqual(ThermoText.temperature(nil), "--")
        XCTAssertEqual(ThermoText.temperature(24.76, fahrenheit: true), "76.6°F")
        XCTAssertEqual(ThermoText.humidity(68.37), "68%")
        XCTAssertEqual(ThermoText.battery(93), "93%")
        XCTAssertEqual(ThermoText.voltage(2.953), "2.953 V")
        XCTAssertEqual(ThermoText.rssi(-45), "-45 dBm")
        XCTAssertEqual(ThermoText.format("bthome"), "BTHome 廣播（明文）")
        XCTAssertEqual(ThermoText.format("gatt"), "原廠韌體，連線讀取")
    }

    func testBattery() {
        XCTAssertTrue(ThermoText.isBatteryLow(19))
        XCTAssertFalse(ThermoText.isBatteryLow(20))
        XCTAssertFalse(ThermoText.isBatteryLow(nil))
        XCTAssertEqual([100, 70, 50, 20, 5, nil].map(ThermoText.batterySymbol),
                       ["battery.100", "battery.75", "battery.50", "battery.25", "battery.0", "battery.0"])
    }

    func testAgeAndFreshness() {
        XCTAssertEqual(ThermoText.age(updated: nil, now: 100), "尚無讀數")
        XCTAssertEqual(ThermoText.age(updated: 100, now: 130), "剛剛")
        XCTAssertEqual(ThermoText.age(updated: 100, now: 100 + 2400), "40 分鐘前")
        XCTAssertEqual(ThermoText.age(updated: 0, now: 7300), "2 小時前")
        XCTAssertEqual(ThermoText.age(updated: 0, now: 3 * 86400), "3 天前")
        XCTAssertEqual(ThermoText.age(updated: 200, now: 100), "剛剛")
        XCTAssertEqual(ThermoFreshness.of(updated: 0, now: 600), .fresh)
        XCTAssertEqual(ThermoFreshness.of(updated: 0, now: 601), .stale)
        XCTAssertEqual(ThermoFreshness.of(updated: 0, now: 3601), .lost)
        XCTAssertEqual(ThermoFreshness.of(updated: nil, now: 0), .never)
    }
}

final class PreferencesTests: XCTestCase {
    private let sensors = [
        ThermoSensor(id: "A4:C1:38:00:00:02", name: "臥室"),
        ThermoSensor(id: "A4:C1:38:00:00:01", name: "客廳"),
        ThermoSensor(id: "A4:C1:38:00:00:03", name: "Sensor 10"),
        ThermoSensor(id: "A4:C1:38:00:00:04", name: "Sensor 9"),
    ]

    func testRenameTrimsCapsAndResets() {
        var prefs = ThermoPreferences()
        prefs.rename("A4:C1:38:00:00:01", to: "  書房  ")
        XCTAssertEqual(prefs.displayName(sensors[1]), "書房")
        prefs.rename("A4:C1:38:00:00:01", to: String(repeating: "長", count: 60))
        XCTAssertEqual(prefs.names["A4:C1:38:00:00:01"]?.count, ThermoPreferences.maxNameLength)
        prefs.rename("A4:C1:38:00:00:01", to: "   ")
        XCTAssertNil(prefs.names["A4:C1:38:00:00:01"])
        XCTAssertEqual(prefs.displayName(sensors[1]), "客廳")
    }

    func testRenameDialogFollowsTheGatewayName() {
        var prefs = ThermoPreferences()
        let sensor = sensors[1]
        prefs.rename(sensor, to: " 書房 ")
        XCTAssertEqual(prefs.displayName(sensor), "書房")
        prefs.rename(sensor, to: "客廳")
        XCTAssertNil(prefs.names[sensor.id], "the gateway's own name is not stored as a custom name")
        prefs.rename(sensor, to: "")
        XCTAssertEqual(prefs.displayName(sensor), "客廳")
    }

    func testArrangeSortsByNameAndSplitsHidden() {
        var prefs = ThermoPreferences()
        prefs.setHidden("A4:C1:38:00:00:02", true)
        let arranged = prefs.arrange(sensors)
        XCTAssertEqual(arranged.visible.map(\.name), ["Sensor 9", "Sensor 10", "客廳"])
        XCTAssertEqual(arranged.hidden.map(\.name), ["臥室"])
        prefs.setHidden("A4:C1:38:00:00:02", false)
        XCTAssertTrue(prefs.arrange(sensors).hidden.isEmpty)
    }

    func testRoundTripAndBadData() {
        var prefs = ThermoPreferences()
        prefs.rename("a", to: "A")
        prefs.setHidden("b", true)
        XCTAssertEqual(ThermoPreferences.decoded(prefs.encoded()), prefs)
        XCTAssertEqual(ThermoPreferences.decoded(Data("x".utf8)), ThermoPreferences())
        XCTAssertEqual(ThermoPreferences.decoded(nil), ThermoPreferences())
    }
}
