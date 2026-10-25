import XCTest
@testable import MinerStatusCore

final class PublisherAssessmentTests: XCTestCase {
    private let assessmentJSON: [String: Any] = [
        "light": "yellow", "title": "太久沒有份額", "reason": "已 16 分鐘沒有新份額（平常約 2 分鐘一個）",
        "observedAt": "2026-10-24T17:30:00+08:00",
    ]
    private let healthJSON: [String: Any] = [
        "uptimeSeconds": 34200, "lastShareAt": "2026-10-24T17:14:00+08:00", "expectedShareSeconds": 120,
        "poolHashrate": 1.5e14, "poolOnline": true, "validSharePercent": 99.6, "maxGpuTemperatureC": 60,
        "temperatureLimitC": 70, "observedAt": "2026-10-24T17:30:00+08:00",
    ]

    private func machine(assessment: Any? = nil, health: Any? = nil) throws -> MachineStatus {
        var object = SampleSpec(sequence: 1, at: Date(timeIntervalSince1970: 1_792_800_000), accepted: 1).json
        if let assessment { object["assessment"] = assessment }
        if let health { object["health"] = health }
        return try decodeFeed(feedJSON([object])).machines[0]
    }

    private func snapshot(_ sample: MachineStatus?, age: TimeInterval?) -> MachineSnapshot {
        MachineSnapshot(
            machineId: "demo-rig-a", displayName: "A", dataOrigin: .demo, light: .green, reason: .miningConfirmed,
            problem: nil, sample: sample, sampleAge: age, isHistorical: false, freshness: nil,
            applicableStopReason: .noData)
    }

    func testFreshAssessmentReplacesLightAndText() throws {
        let shown = snapshot(try machine(assessment: assessmentJSON), age: 10).applyingPublisherAssessment()
        XCTAssertEqual(shown.light, .yellow)
        XCTAssertEqual(shown.statusTitle, "太久沒有份額")
        XCTAssertTrue(shown.reason.displayText.contains("16 分鐘"))
    }

    func testStaleAssessmentTurnsGray() throws {
        let shown = snapshot(try machine(assessment: assessmentJSON), age: 200).applyingPublisherAssessment()
        XCTAssertEqual(shown.light, .gray)
        XCTAssertEqual(shown.statusTitle, "電腦端沒有回應")
        XCTAssertTrue(shown.isHistorical)
        XCTAssertEqual(snapshot(try machine(assessment: assessmentJSON), age: nil).applyingPublisherAssessment().light, .gray)
    }

    func testWithoutAssessmentTheEngineDecides() throws {
        let original = snapshot(try machine(), age: 10)
        XCTAssertEqual(original.applyingPublisherAssessment(), original)
    }

    func testHealthDecodes() throws {
        let health = try XCTUnwrap(try machine(assessment: assessmentJSON, health: healthJSON).health)
        XCTAssertEqual(health.expectedShareSeconds, 120)
        XCTAssertEqual(health.poolOnline, true)
        XCTAssertEqual(health.temperatureLimitC, 70)
    }

    func testAssessmentAndHealthRejectBadValues() {
        XCTAssertThrowsError(try machine(assessment: assessmentJSON.merging(["light": "blue"]) { $1 }))
        XCTAssertThrowsError(try machine(assessment: assessmentJSON.merging(["reason": ""]) { $1 }))
        XCTAssertThrowsError(try machine(assessment: assessmentJSON.merging(["token": "x"]) { $1 }))
        XCTAssertThrowsError(try machine(health: healthJSON.merging(["validSharePercent": 101]) { $1 }))
        XCTAssertThrowsError(try machine(health: healthJSON.merging(["pid": 1]) { $1 }))
    }

    func testCurrentTariffPeriod() {
        let calendar = Calendar.taipei
        func at(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let tariff = TouTariff()
        XCTAssertTrue(tariff.period(at: at(10, 21, 15), calendar: calendar) == ("非夏月尖峰", 4.93))  // Wednesday
        XCTAssertTrue(tariff.period(at: at(10, 24, 15), calendar: calendar) == ("非夏月離峰", 1.99))  // Saturday
        XCTAssertTrue(tariff.period(at: at(7, 15, 10), calendar: calendar) == ("夏月尖峰", 5.16))
    }
}
