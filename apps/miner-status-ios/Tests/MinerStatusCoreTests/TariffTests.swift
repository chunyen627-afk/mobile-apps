import XCTest
@testable import MinerStatusCore

final class TariffTests: XCTestCase {
    private let calendar = Calendar.taipei
    private let tariffJSON: [String: Any] = [
        "name": "表燈簡易型時間電價（二段式）", "effectiveDate": "2025-10-01",
        "summerPeak": 5.16, "summerOffPeak": 2.06, "nonSummerPeak": 4.93, "nonSummerOffPeak": 1.99,
        "periodsMatch": true, "offPeakDates": ["2026-10-26", "2026-12-25"],
        "observedAt": "2026-10-25T09:00:00+08:00",
    ]

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func feed(tariff: Any?) throws -> MinerStatusFeed {
        let machine = SampleSpec(sequence: 1, at: Date(timeIntervalSince1970: 1_792_800_000), accepted: 1).json
        var object = feedJSON([machine])
        if let tariff { object["tariff"] = tariff }
        return try decodeFeed(object)
    }

    private var holidays: TouTariff { TouTariff(offPeakDates: ["2026-10-26"]) }

    func testTariffExtensionDecodesAndIsOptional() throws {
        XCTAssertNil(try feed(tariff: nil).tariff)
        XCTAssertNil(try feed(tariff: NSNull()).tariff)
        let report = try XCTUnwrap(try feed(tariff: tariffJSON).tariff)
        XCTAssertEqual(report.effectiveDate, "2025-10-01")
        XCTAssertEqual(report.offPeakDates, ["2026-10-26", "2026-12-25"])
        let tariff = TouTariff(report: report)
        XCTAssertEqual(tariff.nonSummerPeak, 4.93)
        XCTAssertEqual(tariff.offPeakDates, ["2026-10-26", "2026-12-25"])
    }

    func testTariffExtensionRejectsBadValues() {
        func bad(_ change: [String: Any]) {
            XCTAssertThrowsError(try feed(tariff: tariffJSON.merging(change) { $1 }), "\(change)")
        }
        bad(["summerPeak": -1])
        bad(["summerPeak": NSNull()])
        bad(["effectiveDate": "2025/10/01"])
        bad(["offPeakDates": ["10-26"]])
        bad(["offPeakDates": Array(repeating: "2026-10-26", count: 61)])
        bad(["name": ""])
        bad(["url": "https://tariff.example"])
        var missing = tariffJSON
        missing.removeValue(forKey: "offPeakDates")
        XCTAssertThrowsError(try feed(tariff: missing))
    }

    func testHolidayIsOffPeakAllDay() {
        // 2026-10-26 is a Monday 補假.
        XCTAssertEqual(holidays.offPeakReason(on: date(10, 26, 12), calendar: calendar), "放假日")
        XCTAssertTrue(holidays.period(at: date(10, 26, 15), calendar: calendar) == ("非夏月離峰", 1.99))
        XCTAssertTrue(TouTariff().period(at: date(10, 26, 15), calendar: calendar) == ("非夏月尖峰", 4.93))
        XCTAssertEqual(holidays.offPeakReason(on: date(10, 25), calendar: calendar), "週末")
        XCTAssertNil(holidays.offPeakReason(on: date(10, 27), calendar: calendar))
        XCTAssertEqual(holidays.costPerDay(watts: 1000, day: date(10, 26), calendar: calendar), 24 * 1.99, accuracy: 1e-9)
    }

    func testDayScheduleSegments() {
        let weekday = TouTariff().schedule(on: date(10, 27), calendar: calendar)
        XCTAssertEqual(weekday.map { [$0.startHour, $0.endHour] }, [[0, 6], [6, 11], [11, 14], [14, 24]])
        XCTAssertEqual(weekday.map(\.isPeak), [false, true, false, true])
        XCTAssertEqual(weekday[1].rate, 4.93)

        let summer = TouTariff().schedule(on: date(7, 15), calendar: calendar)
        XCTAssertEqual(summer.map { [$0.startHour, $0.endHour] }, [[0, 9], [9, 24]])
        XCTAssertEqual(summer[1].name, "夏月尖峰")

        let holiday = holidays.schedule(on: date(10, 26), calendar: calendar)
        XCTAssertEqual(holiday.count, 1)
        XCTAssertEqual(holiday[0].endHour, 24)
        XCTAssertFalse(holiday[0].isPeak)
    }

    func testNextChange() {
        let weekday = TouTariff()
        XCTAssertEqual(weekday.nextChange(after: date(10, 27, 9, 30), calendar: calendar), date(10, 27, 11))
        XCTAssertEqual(weekday.nextChange(after: date(10, 27, 23, 10), calendar: calendar), date(10, 28, 0))
        // Saturday morning: off-peak through Sunday, then Monday 06:00; with the 補假 it is Tuesday.
        XCTAssertEqual(weekday.nextChange(after: date(10, 24, 8), calendar: calendar), date(10, 26, 6))
        XCTAssertEqual(holidays.nextChange(after: date(10, 24, 8), calendar: calendar), date(10, 27, 6))
    }

    func testStoredTariffLeavesOutDates() throws {
        let data = try JSONEncoder().encode(TouTariff(nonSummerPeak: 5, offPeakDates: ["2026-10-26"]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["summerPeak", "summerOffPeak", "nonSummerPeak", "nonSummerOffPeak"])
        let decoded = try JSONDecoder().decode(TouTariff.self, from: data)
        XCTAssertEqual(decoded.nonSummerPeak, 5)
        XCTAssertTrue(decoded.offPeakDates.isEmpty)
    }

    func testDayKeyUsesTaiwanTime() {
        // 2026-10-25 16:30 UTC is 2026-10-26 00:30 in Taipei.
        let moment = ISO8601DateFormatter().date(from: "2026-10-25T16:30:00Z")!
        XCTAssertEqual(TouTariff.dayKey(moment, calendar: calendar), "2026-10-26")
    }
}
