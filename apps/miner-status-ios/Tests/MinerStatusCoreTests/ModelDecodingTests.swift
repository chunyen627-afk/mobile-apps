// UNRUN: written on Windows without a Swift toolchain (2026-10-24). Not yet compiled or executed.

import XCTest
@testable import MinerStatusCore

final class ModelDecodingTests: XCTestCase {
    private func machineJSON() -> [String: Any] {
        SampleSpec(sequence: 1, at: testStart, accepted: 10).json
    }

    private func machine(_ edit: (inout [String: Any]) -> Void) -> [String: Any] {
        var object = machineJSON()
        edit(&object)
        return object
    }

    private func nested(_ object: inout [String: Any], _ key: String, _ edit: (inout [String: Any]) -> Void) {
        var inner = object[key] as! [String: Any]
        edit(&inner)
        object[key] = inner
    }

    private func firstGPU(_ object: inout [String: Any], _ edit: (inout [String: Any]) -> Void) {
        var gpus = object["gpus"] as! [[String: Any]]
        edit(&gpus[0])
        object["gpus"] = gpus
    }

    // MARK: - Demo fixture

    func testDemoFixtureDecodesAndIsMarkedDemo() throws {
        let data = try Data(contentsOf: fixtureURL("demo-running.json"))
        let feed = try JSONDecoder().decode(MinerStatusFeed.self, from: data)

        XCTAssertTrue(feed.isDemo)
        XCTAssertFalse(feed.demoNotice?.isEmpty ?? true)
        let rig = try XCTUnwrap(feed.machines.first)
        XCTAssertEqual(rig.machineId, "demo-rig-a")
        XCTAssertTrue(rig.displayName.contains("DEMO"))
        XCTAssertEqual(rig.expectedRunning, .value(true))
        XCTAssertEqual(rig.minerRunning.state, .value(.running))
        XCTAssertEqual(rig.hashrate.unit, .terahashesPerSecond)
        XCTAssertEqual(rig.gpus?.count, 3)
        XCTAssertEqual(rig.shares.accepted, 40)
        XCTAssertEqual(rig.stop.reason, .noData)
        XCTAssertNil(rig.stop.sessionId)
        // 17:30 at +08:00 is 09:30Z.
        XCTAssertEqual(rig.observedAt, Timestamp(rfc3339: "2026-10-24T09:30:00Z"))
    }

    func testDemoFixtureAloneIsNotGreen() throws {
        let data = try Data(contentsOf: fixtureURL("demo-running.json"))
        let feed = try JSONDecoder().decode(MinerStatusFeed.self, from: data)
        let observedAt = try XCTUnwrap(feed.machines.first?.observedAt?.date)

        var engine = StatusEngine()
        let reading = ClockReading(wall: observedAt, monotonic: 1_000)
        engine.ingest(feed, at: reading)
        let snapshot = try XCTUnwrap(engine.snapshots(at: reading).first)
        XCTAssertEqual(snapshot.light, .yellow)
        XCTAssertEqual(snapshot.reason, .awaitingShareEvidence)
        XCTAssertEqual(snapshot.dataOrigin, .demo)
    }

    // MARK: - Required keys and whitelist

    func testEveryFeedKeyIsRequired() {
        for key in feedJSON([machineJSON()]).keys {
            var object = feedJSON([machineJSON()])
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeFeed(object), "missing feed key \(key)")
        }
    }

    func testEveryMachineKeyIsRequired() {
        for key in machineJSON().keys {
            var object = machineJSON()
            object.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeFeed(feedJSON([object])), "missing machine key \(key)")
        }
    }

    func testEveryNestedKeyIsRequired() {
        for parent in ["minerRunning", "hashrate", "shares", "stop"] {
            let keys = (machineJSON()[parent] as! [String: Any]).keys
            for key in keys {
                let object = machine { nested(&$0, parent) { $0.removeValue(forKey: key) } }
                XCTAssertThrowsError(try decodeFeed(feedJSON([object])), "missing \(parent).\(key)")
            }
        }
        for key in ["index", "temperatureC", "fanPercent", "powerW", "observedAt"] {
            let object = machine { firstGPU(&$0) { $0.removeValue(forKey: key) } }
            XCTAssertThrowsError(try decodeFeed(feedJSON([object])), "missing gpus[0].\(key)")
        }
    }

    func testNonWhitelistedKeysAreRejected() {
        var feed = feedJSON([machineJSON()])
        feed["token"] = "x"
        XCTAssertThrowsError(try decodeFeed(feed), "feed.token")

        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["pid"] = 1234 }])), "machine.pid")
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machine { nested(&$0, "minerRunning") { $0["pid"] = 1234 } }])),
            "minerRunning.pid")
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machine { nested(&$0, "shares") { $0["log"] = "C:/x.log" } }])),
            "shares.log")
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machine { firstGPU(&$0) { $0["limit"] = 70 } }])), "gpus[0].limit")
    }

    func testMalformedJSONIsRejected() {
        let truncated = Data(#"{"schemaVersion": 1, "dataOrigin": "demo", "machines": ["#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(MinerStatusFeed.self, from: truncated))
        XCTAssertThrowsError(try JSONDecoder().decode(MinerStatusFeed.self, from: Data("[]".utf8)))
    }

    // MARK: - null versus "unknown"

    func testExplicitNullsDecodeAsNoData() throws {
        let object = machine {
            $0["worker"] = NSNull()
            $0["gpus"] = NSNull()
            $0["expectedRunning"] = NSNull()
            nested(&$0, "minerRunning") { $0["state"] = NSNull() }
            nested(&$0, "shares") {
                $0["accepted"] = NSNull()
                $0["stale"] = NSNull()
                $0["rejected"] = NSNull()
            }
        }
        let rig = try XCTUnwrap(try decodeFeed(feedJSON([object])).machines.first)
        XCTAssertNil(rig.worker)
        XCTAssertNil(rig.gpus)
        XCTAssertEqual(rig.expectedRunning, .noData)
        XCTAssertEqual(rig.minerRunning.state, .noData)
        XCTAssertNil(rig.shares.accepted)
        XCTAssertNil(rig.shares.stale, "missing stale count must stay null, never 0")
        XCTAssertNil(rig.shares.rejected, "missing rejected count must stay null, never 0")
    }

    func testUnknownStaysDistinctFromNull() throws {
        let object = machine {
            $0["expectedRunning"] = "unknown"
            nested(&$0, "minerRunning") { $0["state"] = "unknown" }
            nested(&$0, "stop") { $0["reason"] = "unknown" }
        }
        let rig = try XCTUnwrap(try decodeFeed(feedJSON([object])).machines.first)
        XCTAssertEqual(rig.expectedRunning, .unknown)
        XCTAssertEqual(rig.minerRunning.state, .unknown)
        XCTAssertEqual(rig.stop.reason, .unknown)
        XCTAssertNotEqual(rig.expectedRunning, .noData)
    }

    func testRoundTripKeepsExplicitNullsAndUnknown() throws {
        var spec = SampleSpec(sequence: 1, at: testStart, accepted: nil)
        spec.worker = nil
        spec.running = "unknown"
        let original = try decodeFeed(feedJSON([spec.json]))

        let encoded = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rig = try XCTUnwrap((object["machines"] as? [[String: Any]])?.first)
        XCTAssertTrue(rig["worker"] is NSNull, "null must be written, not omitted")
        XCTAssertEqual((rig["minerRunning"] as? [String: Any])?["state"] as? String, "unknown")
        XCTAssertTrue((rig["shares"] as? [String: Any])?["accepted"] is NSNull)
        XCTAssertTrue((rig["stop"] as? [String: Any])?["reason"] is NSNull)

        XCTAssertEqual(try JSONDecoder().decode(MinerStatusFeed.self, from: encoded), original)
    }

    // MARK: - Values

    func testInvalidEnumValuesAreRejected() {
        let cases: [(String, [String: Any])] = [
            ("minerRunning.state", machine { nested(&$0, "minerRunning") { $0["state"] = "paused" } }),
            ("expectedRunning", machine { $0["expectedRunning"] = "yes" }),
            ("stop.reason", machine { nested(&$0, "stop") { $0["reason"] = "crash" } }),
            ("hashrate.unit", machine { nested(&$0, "hashrate") { $0["unit"] = "PH/s" } }),
            ("sourceStatus", machine { $0["sourceStatus"] = "offline" }),
        ]
        for (label, object) in cases {
            XCTAssertThrowsError(try decodeFeed(feedJSON([object])), label)
        }
        XCTAssertThrowsError(try decodeFeed(feedJSON([machineJSON()], origin: "test")), "dataOrigin")
    }

    func testWrongTypesAreRejected() {
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machine { nested(&$0, "shares") { $0["accepted"] = "10" } }])))
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["sampleSequence"] = "1" } ])))
    }

    func testRangesAreEnforced() {
        let cases: [(String, [String: Any])] = [
            ("accepted < 0", machine { nested(&$0, "shares") { $0["accepted"] = -1 } }),
            ("rejected < 0", machine { nested(&$0, "shares") { $0["rejected"] = -1 } }),
            ("sampleSequence < 0", machine { $0["sampleSequence"] = -1 }),
            ("hashrate < 0", machine { nested(&$0, "hashrate") { $0["value"] = -0.1 } }),
            ("fan > 100", machine { firstGPU(&$0) { $0["fanPercent"] = 101 } }),
            ("temperature > 150", machine { firstGPU(&$0) { $0["temperatureC"] = 151 } }),
            ("power < 0", machine { firstGPU(&$0) { $0["powerW"] = -1 } }),
            ("gpu index < 0", machine { firstGPU(&$0) { $0["index"] = -1 } }),
        ]
        for (label, object) in cases {
            XCTAssertThrowsError(try decodeFeed(feedJSON([object])), label)
        }
    }

    func testIdentityConstraints() {
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["machineId"] = "rig a" }])), "space in id")
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["machineId"] = "" }])), "empty id")
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["displayName"] = "" }])), "empty name")
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine { $0["sessionId"] = "" }])), "empty session")
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machine { $0["sessionId"] = String(repeating: "s", count: 129) }])),
            "129-char session")
        XCTAssertNoThrow(
            try decodeFeed(feedJSON([machine { $0["sessionId"] = String(repeating: "s", count: 128) }])))
        XCTAssertThrowsError(try decodeFeed(feedJSON([machineJSON(), machineJSON()])), "duplicate machineId")
    }

    func testSchemaVersionAndDemoNoticeRules() {
        var wrongVersion = feedJSON([machineJSON()])
        wrongVersion["schemaVersion"] = 2
        XCTAssertThrowsError(try decodeFeed(wrongVersion))

        XCTAssertThrowsError(try decodeFeed(feedJSON([machineJSON()], notice: NSNull())), "demo needs notice")
        XCTAssertThrowsError(try decodeFeed(feedJSON([machineJSON()], notice: "")), "demo needs non-empty notice")
        XCTAssertThrowsError(
            try decodeFeed(feedJSON([machineJSON()], origin: "live", notice: "x")), "live must not carry a notice")
        XCTAssertNoThrow(try decodeFeed(feedJSON([machineJSON()], origin: "live", notice: NSNull())))
    }

    // MARK: - Timestamps

    func testTimestampsRequireExplicitOffset() {
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-24T17:30:00+08:00"), Timestamp(rfc3339: "2026-10-24T09:30:00Z"))
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-24T09:30:00Z")?.date.timeIntervalSince1970, 1_792_834_200)
        XCTAssertEqual(Timestamp(rfc3339: "2024-02-29T00:00:00Z")?.date.timeIntervalSince1970, 1_709_164_800)
        XCTAssertNotNil(Timestamp(rfc3339: "2026-10-24T09:30:00.123456789Z"))
        XCTAssertEqual(Timestamp(rfc3339: "2026-10-24T17:30:00+08:00")?.rfc3339, "2026-10-24T17:30:00+08:00")

        let rejected = [
            "2026-10-24T17:30:00",            // no offset
            "17:30:00",                       // log time of day only
            "2026-10-24 17:30:00Z",           // space separator
            "2026-10-24T17:30:00z",           // lowercase zone
            "2026-10-24T09:30:00+8:00",       // one-digit offset hour
            "2026-02-30T00:00:00Z",           // impossible date
            "2025-02-29T00:00:00Z",           // not a leap year
            "2026-10-24T23:59:60Z",           // leap second
            "2026-10-24T09:30:00.Z",          // empty fraction
            "2026-10-24T09:30:00.1234567890Z", // 10 fraction digits
            "",
        ]
        for text in rejected {
            XCTAssertNil(Timestamp(rfc3339: text), text)
        }

        let object = machine { $0["observedAt"] = "2026-10-24T17:30:00" }
        XCTAssertThrowsError(try decodeFeed(feedJSON([object])), "offset-less observedAt")
    }
}
