// UNRUN: written without a Swift toolchain. Not yet compiled or executed.

import XCTest
@testable import MinerStatusCore

final class FixtureAndTextTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> MinerStatusFeed {
        try JSONDecoder().decode(MinerStatusFeed.self, from: Data(contentsOf: fixtureURL(name)))
    }

    private func snapshots(of feed: MinerStatusFeed, at text: String) throws -> [MachineSnapshot] {
        let wall = try XCTUnwrap(Timestamp(rfc3339: text)).date
        var engine = StatusEngine()
        let reading = ClockReading(wall: wall, monotonic: 1_000)
        engine.ingest(feed, at: reading)
        return engine.snapshots(at: reading)
    }

    private func assertNeverClaimsOffline(_ snapshot: MachineSnapshot?, file: StaticString = #filePath, line: UInt = #line) {
        guard let snapshot else { return XCTFail("missing snapshot", file: file, line: line) }
        for text in [snapshot.statusTitle, snapshot.reason.displayText, snapshot.problem?.displayText ?? ""] {
            XCTAssertFalse(text.contains("離線"), "\(text) must not claim the host is offline", file: file, line: line)
        }
    }

    // MARK: - Synthetic fixtures

    func testTwoMachineFixture() throws {
        let feed = try loadFixture("demo-two-machines.json")
        XCTAssertTrue(feed.isDemo)
        XCTAssertTrue(feed.machines.allSatisfy { $0.machineId.hasPrefix("demo-") && $0.displayName.contains("DEMO") })

        let result = try snapshots(of: feed, at: "2026-10-24T17:40:00+08:00")
        let a = try XCTUnwrap(result.first { $0.machineId == "demo-rig-a" })
        XCTAssertEqual(a.light, .yellow)
        XCTAssertEqual(a.reason, .awaitingShareEvidence, "a single sample is never green")

        let b = try XCTUnwrap(result.first { $0.machineId == "demo-rig-b" })
        XCTAssertEqual(b.light, .red)
        XCTAssertEqual(b.applicableStopReason, .value(.userRequested))
        XCTAssertEqual(b.sample?.expectedRunning, .unknown)
        XCTAssertNil(b.sample?.worker)
        XCTAssertNil(b.sample?.shares.stale)
        XCTAssertEqual(b.freshness?.hashrate, .noTimestamp)
        XCTAssertEqual(b.freshness?.shares, .fresh(age: 120))
    }

    func testIncompleteFixtureIsGrayWithoutClaimingOffline() throws {
        let feed = try loadFixture("demo-incomplete.json")
        let result = try snapshots(of: feed, at: "2026-10-24T17:50:01+08:00")

        let a = try XCTUnwrap(result.first { $0.machineId == "demo-rig-a" })
        XCTAssertEqual(a.light, .gray)
        XCTAssertEqual(a.reason, .noData)
        XCTAssertEqual(a.problem, .incompleteSample)
        XCTAssertEqual(a.statusTitle, "資料不足")
        assertNeverClaimsOffline(a)

        let b = try XCTUnwrap(result.first { $0.machineId == "demo-rig-b" })
        XCTAssertEqual(b.light, .gray)
        XCTAssertEqual(b.problem, .sourceUnavailable(.unreachable))
        XCTAssertEqual(b.statusTitle, "來源無法讀取・尚無有效資料")
        assertNeverClaimsOffline(b)
    }

    // MARK: - Null identity fields

    func testEachNullIdentityFieldMakesTheSampleIncomplete() throws {
        let edits: [(String, (inout SampleSpec) -> Void)] = [
            ("sessionId", { $0.sessionId = nil }),
            ("sampleSequence", { $0.sequence = nil }),
            ("observedAt", { $0.observedAt = nil }),
        ]
        for (field, edit) in edits {
            var spec = SampleSpec(sequence: 1, at: testStart, accepted: 10)
            edit(&spec)
            var engine = StatusEngine()
            let reading = ClockReading(wall: testStart, monotonic: 1_000)
            engine.ingest(try decodeFeed(feedJSON([spec.json])), at: reading)
            let snapshot = engine.snapshots(at: reading).first

            XCTAssertEqual(snapshot?.light, .gray, field)
            XCTAssertEqual(snapshot?.reason, .noData, field)
            XCTAssertEqual(snapshot?.problem, .incompleteSample, field)
            XCTAssertNil(snapshot?.sample, field)
            XCTAssertEqual(snapshot?.statusTitle, "資料不足", field)
            assertNeverClaimsOffline(snapshot)
        }
    }

    func testIncompleteSampleAfterGreenRemovesGreenAndMarksHistorical() throws {
        var clock = TestClock()
        var engine = StatusEngine()
        engine.ingest(try decodeFeed(feedJSON([SampleSpec(sequence: 1, at: clock.wall, accepted: 10).json])), at: clock.reading)
        clock.advance(30)
        engine.ingest(try decodeFeed(feedJSON([SampleSpec(sequence: 2, at: clock.wall, accepted: 11).json])), at: clock.reading)
        XCTAssertEqual(engine.snapshots(at: clock.reading).first?.light, .green)

        clock.advance(30)
        var incomplete = SampleSpec(sequence: 3, at: clock.wall, accepted: 12)
        incomplete.sessionId = nil
        engine.ingest(try decodeFeed(feedJSON([incomplete.json])), at: clock.reading)
        let snapshot = engine.snapshots(at: clock.reading).first
        XCTAssertEqual(snapshot?.light, .yellow)
        XCTAssertEqual(snapshot?.reason, .updateProblem(.incompleteSample))
        XCTAssertEqual(snapshot?.isHistorical, true)
        XCTAssertEqual(snapshot?.sample?.sampleSequence, 2, "the held sample is the last accepted one")
    }

    // MARK: - Gray titles

    func testGrayTitlesNameTheCauseAndNeverClaimOffline() throws {
        var clock = TestClock()

        // Materially future timestamp.
        var future = StatusEngine()
        future.ingest(try decodeFeed(feedJSON([
            SampleSpec(sequence: 1, at: clock.wall.addingTimeInterval(3_600), accepted: 10).json,
        ])), at: clock.reading)
        let futureSnapshot = future.snapshots(at: clock.reading).first
        XCTAssertEqual(futureSnapshot?.light, .gray)
        XCTAssertEqual(futureSnapshot?.statusTitle, "時間無法驗證")
        assertNeverClaimsOffline(futureSnapshot)

        // Request failure before any valid sample.
        var failed = StatusEngine()
        var incomplete = SampleSpec(sequence: 1, at: nil, accepted: nil)
        incomplete.running = NSNull()
        failed.ingest(try decodeFeed(feedJSON([incomplete.json])), at: clock.reading)
        failed.recordRequestFailure(at: clock.reading)
        let failedSnapshot = failed.snapshots(at: clock.reading).first
        XCTAssertEqual(failedSnapshot?.light, .gray)
        XCTAssertEqual(failedSnapshot?.statusTitle, "請求失敗・尚無有效資料")
        assertNeverClaimsOffline(failedSnapshot)

        // Stale data and unverifiable age.
        var engine = StatusEngine()
        engine.ingest(try decodeFeed(feedJSON([SampleSpec(sequence: 1, at: clock.wall, accepted: 10).json])), at: clock.reading)
        clock.advance(300.001)
        let staleSnapshot = engine.snapshots(at: clock.reading).first
        XCTAssertEqual(staleSnapshot?.statusTitle, "資料逾時（超過 5 分鐘未更新）")
        assertNeverClaimsOffline(staleSnapshot)

        clock.monotonic = 0
        let unverifiable = engine.snapshots(at: clock.reading).first
        XCTAssertEqual(unverifiable?.reason, .ageUnverifiable)
        XCTAssertEqual(unverifiable?.statusTitle, "時間無法驗證")
        assertNeverClaimsOffline(unverifiable)
    }

    func testNoDisplayTextClaimsOffline() {
        let reasons: [StatusReason] = [
            .noData, .dataTooOld, .ageUnverifiable, .minerStopped, .minerStateUnknown,
            .minerStateNotFresh, .stopReportConflict, .awaitingShareEvidence, .miningConfirmed,
            .updateProblem(.requestFailed),
        ]
        let problems: [UpdateProblem] = [
            .requestFailed, .sourceUnavailable(.ok), .sourceUnavailable(.unreachable), .sourceUnavailable(.error),
            .sourceUnavailable(.noDataYet), .missingFromFeed, .incompleteSample, .futureTimestamp,
            .replayOrOutOfOrder, .retiredSession, .counterRegression, .clockDiscontinuity,
        ]
        for text in reasons.map(\.displayText) + problems.map(\.displayText) {
            XCTAssertFalse(text.contains("離線"), text)
        }
        XCTAssertTrue(StatusLight.gray.legend.contains("不代表主機離線"))
    }

    // MARK: - null / unknown / freshness text

    func testNullAndUnknownDisplayText() {
        XCTAssertEqual(Reported<Bool>.noData.displayText { $0 ? "是" : "否" }, "無資料")
        XCTAssertEqual(Reported<Bool>.unknown.displayText { $0 ? "是" : "否" }, "未知")
        XCTAssertEqual(Reported<Bool>.value(false).displayText { $0 ? "是" : "否" }, "否")
        XCTAssertEqual(Reported<StopReason>.value(.protectionTriggered).displayText(\.displayText), "保護機制觸發")
    }

    func testFreshnessDisplayText() {
        XCTAssertEqual(Freshness.fresh(age: 35).displayText(historical: false), "新鮮・35 秒前")
        XCTAssertEqual(Freshness.fresh(age: 35).displayText(historical: true), "歷史資料（未確認）・35 秒前")
        XCTAssertEqual(Freshness.stale(age: 331).displayText(historical: false), "歷史資料・5 分 31 秒前")
        XCTAssertEqual(Freshness.unverifiable.displayText(historical: false), "時間無法驗證")
        XCTAssertEqual(Freshness.noTimestamp.displayText(historical: false), "無時間")
    }
}
