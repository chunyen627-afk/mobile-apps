import XCTest
@testable import MinerStatusCore

final class EarningsTests: XCTestCase {
    private let calendar = Calendar.taipei
    private let marketJSON: [String: Any] = [
        "coin": "PRL", "coinUsd": 1.5, "btcUsd": 75000.0, "usdTwd": 32.0, "observedAt": "2026-10-24T17:30:00+08:00",
    ]
    private let earningsJSON: [String: Any] = [
        "coinPerDay": 2.0, "poolHashrate": 1.75e14, "electricityBilled": true, "observedAt": "2026-10-24T17:30:00+08:00",
    ]

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func feed(earnings: Any? = nil, market: Any? = nil) throws -> MinerStatusFeed {
        var machine = SampleSpec(sequence: 1, at: Date(timeIntervalSince1970: 1_792_800_000), accepted: 1).json
        if let earnings { machine["earnings"] = earnings }
        var object = feedJSON([machine])
        if let market { object["market"] = market }
        return try decodeFeed(object)
    }

    private func estimate(_ feed: MinerStatusFeed, billed: Bool, day: Date) -> MachineEarnings {
        EarningsCalculator.estimate(status: feed.machines[0], market: feed.market, billed: billed, extraWatts: 60,
                                    tariff: TouTariff(), day: day, calendar: calendar)
    }

    func testExtensionIsOptional() throws {
        let decoded = try feed()
        XCTAssertNil(decoded.market)
        XCTAssertNil(decoded.machines[0].earnings)
    }

    func testExtensionDecodes() throws {
        let decoded = try feed(earnings: earningsJSON, market: marketJSON)
        XCTAssertEqual(decoded.market?.usdTwd, 32)
        XCTAssertEqual(decoded.machines[0].earnings?.coinPerDay, 2)
        XCTAssertEqual(decoded.machines[0].earnings?.electricityBilled, true)
    }

    func testExtensionRejectsUnknownKeysAndBadValues() {
        XCTAssertThrowsError(try feed(earnings: earningsJSON.merging(["account": "x"]) { $1 }))
        XCTAssertThrowsError(try feed(earnings: earningsJSON.merging(["coinPerDay": -1]) { $1 }))
        XCTAssertThrowsError(try feed(market: marketJSON.merging(["usdTwd": 0]) { $1 }))
        XCTAssertThrowsError(try feed(market: marketJSON.merging(["coin": "prl"]) { $1 }))
    }

    func testTimeOfUseRates() {
        let tariff = TouTariff()
        XCTAssertEqual(tariff.rate(at: date(2026, 7, 15, 10), calendar: calendar), 5.16)  // summer Wednesday, peak
        XCTAssertEqual(tariff.rate(at: date(2026, 7, 15, 8), calendar: calendar), 2.06)   // summer, before 09:00
        XCTAssertEqual(tariff.rate(at: date(2026, 10, 21, 7), calendar: calendar), 4.93)  // non-summer morning peak
        XCTAssertEqual(tariff.rate(at: date(2026, 10, 21, 12), calendar: calendar), 1.99) // 11:00–14:00 off-peak
        XCTAssertEqual(tariff.rate(at: date(2026, 10, 21, 15), calendar: calendar), 4.93)
        XCTAssertEqual(tariff.rate(at: date(2026, 10, 24, 15), calendar: calendar), 1.99) // Saturday
    }

    func testCostPerDayFollowsPeakHours() {
        let tariff = TouTariff()
        XCTAssertEqual(tariff.costPerDay(watts: 1000, day: date(2026, 10, 21), calendar: calendar), 15 * 4.93 + 9 * 1.99, accuracy: 1e-9)
        XCTAssertEqual(tariff.costPerDay(watts: 1000, day: date(2026, 7, 15), calendar: calendar), 15 * 5.16 + 9 * 2.06, accuracy: 1e-9)
        XCTAssertEqual(tariff.costPerDay(watts: 500, day: date(2026, 10, 24), calendar: calendar), 24 * 0.5 * 1.99, accuracy: 1e-9)
    }

    func testBilledMachineSubtractsElectricity() throws {
        let result = estimate(try feed(earnings: earningsJSON, market: marketJSON), billed: true, day: date(2026, 10, 24))
        XCTAssertEqual(result.revenueTwdPerDay!, 2 * 1.5 * 32, accuracy: 1e-9)
        XCTAssertEqual(result.btcPerDay!, 2 * 1.5 / 75000, accuracy: 1e-12)
        XCTAssertEqual(result.powerW, 170)  // 110 W reported + 60 W extra
        XCTAssertEqual(result.electricityTwdPerDay!, 24 * 0.17 * 1.99, accuracy: 1e-9)
        XCTAssertEqual(result.netTwdPerDay!, 96 - 24 * 0.17 * 1.99, accuracy: 1e-9)
    }

    func testUnbilledMachineKeepsFullRevenue() throws {
        let result = estimate(try feed(earnings: earningsJSON, market: marketJSON), billed: false, day: date(2026, 10, 24))
        XCTAssertEqual(result.electricityTwdPerDay, 0)
        XCTAssertEqual(result.netTwdPerDay!, 96, accuracy: 1e-9)
    }

    func testMissingPricesLeaveRevenueUnknown() throws {
        let result = estimate(try feed(earnings: earningsJSON), billed: true, day: date(2026, 10, 24))
        XCTAssertNil(result.revenueTwdPerDay)
        XCTAssertNil(result.netTwdPerDay)
        XCTAssertNotNil(result.electricityTwdPerDay)
    }

    func testTotalsSkipUnknownValues() throws {
        let known = estimate(try feed(earnings: earningsJSON, market: marketJSON), billed: false, day: date(2026, 10, 24))
        let unknown = estimate(try feed(), billed: true, day: date(2026, 10, 24))
        let total = EarningsCalculator.total([known, unknown])
        XCTAssertEqual(total.revenue!, 96, accuracy: 1e-9)
        XCTAssertEqual(total.net!, 96, accuracy: 1e-9)
        XCTAssertNotNil(total.electricity)
    }
}
