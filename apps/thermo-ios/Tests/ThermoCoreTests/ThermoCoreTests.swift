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

    func testDemoFeedUsesMadeUpAddresses() {
        let feed = ThermoFeed.demo(now: 1000)
        XCTAssertEqual(feed.sensors.count, 3)
        XCTAssertTrue(feed.sensors.allSatisfy { $0.id.hasPrefix("A4:C1:38:00:00:") })
    }
}

private struct StubTransport: ThermoTransport {
    let status: Int
    let contentType: String
    let body: Data
    var failure: URLError?

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if let failure { throw failure }
        XCTAssertEqual(request.httpMethod, "GET")
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
        let feed = try await client().fetch(endpoint)
        XCTAssertEqual(feed.sensors.count, 2)
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
                         ThermoPoint(t: 300, temperature: 26, humidity: 50, battery: 80),
                         ThermoPoint(t: 600, temperature: nil, humidity: 70, battery: nil)])
        XCTAssertEqual(h.summary(.temperature), ThermoSummary(min: 20, max: 26, average: 23))
        XCTAssertEqual(h.summary(.humidity), ThermoSummary(min: 50, max: 70, average: 60))
        XCTAssertEqual(h.summary(.battery)?.min, 80)
        XCTAssertNil(history([]).summary(.temperature))
    }

    func testGapsSplitTheLine() {
        let h = history([300, 600, 900, 2400, 2700].map { ThermoPoint(t: $0, temperature: 20, humidity: nil, battery: nil) })
        XCTAssertEqual(h.segments(.temperature).map { $0.map(\.t) }, [[300, 600, 900], [2400, 2700]])
        XCTAssertEqual(h.segments(.humidity).count, 0)
    }

    func testDemoHistoryEndsAtTheReading() {
        let sensor = ThermoFeed.demo(now: 1_000_000).sensors[0]
        for range in ThermoRange.allCases {
            let h = ThermoHistory.demo(for: sensor, range: range, now: 1_000_000)
            XCTAssertEqual(h.points.count, range.seconds / range.bucket, range.rawValue)
            XCTAssertEqual(h.segments(.temperature).count, 1)
            XCTAssertLessThan(h.points.last!.t, 1_000_000)
            let summary = h.summary(.temperature)!
            XCTAssertGreaterThan(summary.max - summary.min, 2)
        }
    }

    func testRangesAndMetrics() {
        XCTAssertEqual(ThermoRange.allCases.map(\.title), ["24 小時", "7 天", "30 天"])
        XCTAssertEqual(ThermoMetric.allCases.map(\.title), ["溫度", "濕度", "電量"])
        XCTAssertEqual(ThermoMetric.battery.format(87.4), "87%")
    }
}

final class TextTests: XCTestCase {
    func testValues() {
        XCTAssertEqual(ThermoText.temperature(24.76), "24.8°")
        XCTAssertEqual(ThermoText.temperature(-3.04), "-3.0°")
        XCTAssertEqual(ThermoText.temperature(nil), "--")
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
