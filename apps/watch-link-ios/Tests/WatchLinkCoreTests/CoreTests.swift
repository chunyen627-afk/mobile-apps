import XCTest
@testable import WatchLinkCore

final class CoreTests: XCTestCase {

    func testSplitSingleChunk() {
        let chunks = Framing.split(Data([1, 2, 3]), maxChunk: 20)
        XCTAssertEqual(chunks, [Data([3, 1, 2, 3])])
    }

    func testSplitEmptyMessage() {
        XCTAssertEqual(Framing.split(Data(), maxChunk: 20), [Data([3])])
    }

    func testSplitAndReassembleLongMessage() {
        let message = Data((0..<1000).map { UInt8($0 % 251) })
        let chunks = Framing.split(message, maxChunk: 23)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 23 })
        XCTAssertEqual(chunks.first?.first, Framing.flagStart)
        XCTAssertEqual(chunks.last?.first, Framing.flagEnd)
        var r = Reassembler()
        var result: Data?
        for (i, c) in chunks.enumerated() {
            result = r.feed(c)
            if i < chunks.count - 1 { XCTAssertNil(result) }
        }
        XCTAssertEqual(result, message)
    }

    func testReassemblerDropsChunkWithoutStart() {
        var r = Reassembler()
        XCTAssertNil(r.feed(Data([Framing.flagEnd, 9])))
        XCTAssertEqual(r.feed(Data([3, 7])), Data([7]))
    }

    func testReassemblerRestartsOnNewStart() {
        var r = Reassembler()
        XCTAssertNil(r.feed(Data([Framing.flagStart, 1, 1])))
        XCTAssertNil(r.feed(Data([Framing.flagStart, 2])))
        XCTAssertEqual(r.feed(Data([Framing.flagEnd, 3])), Data([2, 3]))
    }

    func testSnapshotRoundTripKeepsChineseText() throws {
        let weather = WeatherInfo(place: "台北", tempC: 21.5, code: 61, text: "雨", highC: 24, lowC: 18, rainPercent: 80, fetchedAtMs: 1000)
        let snap = Snapshot(nowMs: 2000, battery: 77, weather: weather,
                            events: [EventInfo(title: "開會", startMs: 3000, endMs: 4000, allDay: false, location: "三樓")])
        let decoded = try JSONDecoder().decode(Snapshot.self, from: snap.encoded())
        XCTAssertEqual(decoded, snap)
        XCTAssertEqual(decoded.t, "snapshot")
    }

    func testUpcomingEventsSkipsFinishedAndSorts() {
        let events = [
            EventInfo(title: "晚", startMs: 500, endMs: 600, allDay: false, location: ""),
            EventInfo(title: "已結束", startMs: 10, endMs: 90, allDay: false, location: ""),
            EventInfo(title: "進行中", startMs: 50, endMs: 200, allDay: false, location: ""),
            EventInfo(title: "早", startMs: 300, endMs: 400, allDay: false, location: ""),
        ]
        let picked = EventPicker.upcoming(events, nowMs: 100, limit: 2)
        XCTAssertEqual(picked.map(\.title), ["進行中", "早"])
    }

    func testParsesOpenMeteoResponse() {
        let json = """
        {"current":{"time":"2026-11-28T17:00","interval":900,"temperature_2m":22.4,"weather_code":80},
         "daily":{"time":["2026-11-28"],"temperature_2m_max":[25.1],"temperature_2m_min":[19.3],"precipitation_probability_max":[65]}}
        """
        let w = OpenMeteo.parse(Data(json.utf8), place: "台北", fetchedAtMs: 42)
        XCTAssertEqual(w?.tempC, 22.4)
        XCTAssertEqual(w?.text, "陣雨")
        XCTAssertEqual(w?.highC, 25.1)
        XCTAssertEqual(w?.lowC, 19.3)
        XCTAssertEqual(w?.rainPercent, 65)
        XCTAssertEqual(w?.place, "台北")
    }

    func testWeatherParseToleratesMissingRainAndRejectsGarbage() {
        let json = """
        {"current":{"temperature_2m":10.0,"weather_code":0},
         "daily":{"temperature_2m_max":[12.0],"temperature_2m_min":[8.0],"precipitation_probability_max":[null]}}
        """
        XCTAssertEqual(OpenMeteo.parse(Data(json.utf8), place: "x", fetchedAtMs: 0)?.rainPercent, 0)
        XCTAssertNil(OpenMeteo.parse(Data("not json".utf8), place: "x", fetchedAtMs: 0))
        XCTAssertNotNil(OpenMeteo.url(latitude: 25.033, longitude: 121.565))
    }
}
