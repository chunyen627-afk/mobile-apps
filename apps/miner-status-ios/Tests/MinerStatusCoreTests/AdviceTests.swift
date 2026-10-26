import XCTest
@testable import MinerStatusCore

final class AdviceTests: XCTestCase {
    private let item: [String: Any] = [
        "machineId": "demo-laptop", "displayName": "示範筆電", "recommendation": "rest",
        "monthlyNetTwd": 120.5, "startAtTwd": 300, "stopBelowTwd": 250,
        "reason": "估算每月淨收益 NT$120，未達開挖門檻 NT$300", "since": NSNull(),
        "observedAt": "2026-10-26T14:30:00+08:00",
    ]

    private func feed(advice: Any?) throws -> MinerStatusFeed {
        let machine = SampleSpec(sequence: 1, at: Date(timeIntervalSince1970: 1_792_800_000), accepted: 1).json
        var object = feedJSON([machine])
        if let advice { object["advice"] = advice }
        return try decodeFeed(object)
    }

    private func with(_ key: String, _ value: Any) -> [String: Any] {
        var copy = item
        copy[key] = value
        return copy
    }

    func testAdviceDecodesAndIsOptional() throws {
        XCTAssertNil(try feed(advice: nil).advice)
        XCTAssertNil(try feed(advice: NSNull()).advice)
        XCTAssertEqual(try feed(advice: [Any]()).advice, [])
        let loss = with("recommendation", "mine").merging(["machineId": "demo-rig-b", "monthlyNetTwd": -20.5,
                                                           "stopBelowTwd": 0, "since": "2026-10-26T14:30:00+08:00"]) { $1 }
        let items = try XCTUnwrap(try feed(advice: [item, loss]).advice)
        XCTAssertEqual(items.map(\.recommendation), [.rest, .mine])
        XCTAssertEqual(items[0].monthlyNetTwd, 120.5)
        XCTAssertNil(items[0].since)
        XCTAssertEqual(items[1].monthlyNetTwd, -20.5, "a net loss is negative and must decode")
        XCTAssertNotNil(items[1].since)
        XCTAssertNil(try feed(advice: [with("monthlyNetTwd", NSNull())]).advice?.first?.monthlyNetTwd)
    }

    func testAdviceIsStrict() {
        var missing = item
        missing.removeValue(forKey: "since")
        let bad: [Any] = [
            item,  // an object, not a list
            [with("account", "x")],
            [missing],
            [with("recommendation", "maybe")],
            [with("machineId", "demo laptop")],
            [with("reason", "")],
            [with("displayName", String(repeating: "x", count: 41))],
            [with("startAtTwd", NSNull())],
            [with("monthlyNetTwd", "120")],
            Array(repeating: item, count: 9),
        ]
        for value in bad {
            XCTAssertThrowsError(try feed(advice: value), "accepted \(value)")
        }
    }

    func testAdviceRoundTripsWithExplicitNulls() throws {
        let decoded = try feed(advice: [item])
        let data = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((object["advice"] as? [[String: Any]])?.first)
        XCTAssertTrue(first["since"] is NSNull)
        XCTAssertEqual(try decodeFeed(object), decoded)
    }

    func testLiveFixtureCarriesAdvice() throws {
        let data = try Data(contentsOf: fixtureURL("demo-two-machines.json"))
        let feed = try JSONDecoder().decode(MinerStatusFeed.self, from: data)
        XCTAssertEqual(feed.advice?.map(\.recommendation), [.mine, .rest])
    }
}
