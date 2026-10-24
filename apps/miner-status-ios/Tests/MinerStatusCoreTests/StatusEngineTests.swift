// UNRUN: written on Windows without a Swift toolchain (2026-10-24). Not yet compiled or executed.

import XCTest
@testable import MinerStatusCore

final class StatusEngineTests: XCTestCase {
    private var clock = TestClock()
    private var engine = StatusEngine()
    private var nextSequence = 0

    private let session1 = "demo-session-1"
    private let session2 = "demo-session-2"

    // MARK: - Helpers

    /// Fresh `running` sample observed now, with the next sequence number.
    private func sample(_ accepted: Int?, session: String = "demo-session-1") -> SampleSpec {
        nextSequence += 1
        return SampleSpec(sequence: nextSequence, at: clock.wall, accepted: accepted, session: session)
    }

    private func ingest(_ specs: SampleSpec..., file: StaticString = #filePath, line: UInt = #line) {
        do {
            engine.ingest(try decodeFeed(feedJSON(specs.map(\.json))), at: clock.reading)
        } catch {
            XCTFail("feed did not decode: \(error)", file: file, line: line)
        }
    }

    private func snapshot(_ id: String = "demo-rig-a") -> MachineSnapshot? {
        engine.snapshots(at: clock.reading).first { $0.machineId == id }
    }

    private func assertStatus(
        _ light: StatusLight, _ reason: StatusReason, historical: Bool? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let current = snapshot()
        XCTAssertEqual(current?.light, light, "light", file: file, line: line)
        XCTAssertEqual(current?.reason, reason, "reason", file: file, line: line)
        if let historical {
            XCTAssertEqual(current?.isHistorical, historical, "isHistorical", file: file, line: line)
        }
    }

    /// Baseline at T, accepted increase at T+30: green at T+30.
    private func establishGreen(file: StaticString = #filePath, line: UInt = #line) {
        ingest(sample(10))
        clock.advance(30)
        ingest(sample(11))
        assertStatus(.green, .miningConfirmed, historical: false, file: file, line: line)
    }

    // MARK: - No data and first sample

    func testNoFeedYieldsNoMachines() {
        XCTAssertEqual(engine.snapshots(at: clock.reading), [])
        engine.recordRequestFailure(at: clock.reading)
        XCTAssertEqual(engine.feedProblem, .requestFailed)
        XCTAssertEqual(engine.snapshots(at: clock.reading), [])
    }

    func testMachineWithoutDataIsGray() {
        var spec = SampleSpec(sequence: nil, at: nil, accepted: nil, session: nil)
        spec.sourceStatus = "noDataYet"
        spec.running = NSNull()
        ingest(spec)
        assertStatus(.gray, .noData, historical: false)
        XCTAssertEqual(snapshot()?.problem, .sourceUnavailable(.noDataYet))
        XCTAssertNil(snapshot()?.sample)
    }

    func testIncompleteSampleIsNotAccepted() {
        var spec = sample(10)
        spec.observedAt = nil
        ingest(spec)
        assertStatus(.gray, .noData)
        XCTAssertEqual(snapshot()?.problem, .incompleteSample)
    }

    func testFirstSampleIsYellow() {
        ingest(sample(10))
        assertStatus(.yellow, .awaitingShareEvidence, historical: false)
        XCTAssertEqual(snapshot()?.sampleAge, 0)
    }

    // MARK: - Share evidence

    func testAcceptedIncreaseBetweenTwoFreshSamplesIsGreen() {
        establishGreen()
    }

    func testHashrateCumulativeAcceptedAndLastAcceptedAloneAreNotGreen() {
        var first = sample(1_000)
        first.hashrate = 999
        first.lastAcceptedAt = clock.wall
        ingest(first)
        assertStatus(.yellow, .awaitingShareEvidence)

        clock.advance(30)
        var second = sample(1_000)
        second.hashrate = 999
        second.lastAcceptedAt = clock.wall.addingTimeInterval(-1)
        ingest(second)
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    func testEvidenceExpiresAfterWindowWithoutNewIncrease() {
        establishGreen() // increase observed at T+30
        for _ in 0 ..< 5 { // T+90 ... T+330: evidence age 60 ... 300
            clock.advance(60)
            ingest(sample(11))
            assertStatus(.green, .miningConfirmed)
        }
        clock.advance(60) // evidence age 360
        ingest(sample(11))
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    func testCountersAreNotComparedAcrossSessions() {
        ingest(sample(10, session: session1))
        clock.advance(30)
        ingest(sample(50, session: session2))
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    func testCounterRegressionDiscardsEvidenceAndBaseline() {
        establishGreen()
        clock.advance(30)
        ingest(sample(5))
        assertStatus(.yellow, .updateProblem(.counterRegression))
        clock.advance(30)
        ingest(sample(6)) // regressed sample is not a baseline
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(7))
        assertStatus(.green, .miningConfirmed)
    }

    // MARK: - Stopped, null and unknown

    func testFreshStoppedIsRed() {
        var spec = sample(10)
        spec.running = "stopped"
        ingest(spec)
        assertStatus(.red, .minerStopped)
    }

    func testStoppedObservationOlderThanThresholdIsNotRed() {
        var spec = sample(10)
        spec.running = "stopped"
        spec.runningAt = clock.wall.addingTimeInterval(-301)
        ingest(spec)
        assertStatus(.yellow, .minerStateNotFresh)
        XCTAssertEqual(snapshot()?.freshness?.minerRunning, .stale(age: 301))
    }

    func testStoppedSampleBeyondThresholdIsGray() {
        var spec = sample(10)
        spec.running = "stopped"
        ingest(spec)
        clock.advance(300.001)
        assertStatus(.gray, .dataTooOld, historical: true)
    }

    func testStopReasonAppliesOnlyToItsOwnSession() {
        var own = sample(10)
        own.running = "stopped"
        own.stopReason = "protectionTriggered"
        own.stopSessionId = session1
        ingest(own)
        assertStatus(.red, .minerStopped)
        XCTAssertEqual(snapshot()?.applicableStopReason, .value(.protectionTriggered))

        clock.advance(30)
        var older = sample(10)
        older.running = "stopped"
        older.stopReason = "userRequested"
        older.stopSessionId = "demo-session-0"
        ingest(older)
        XCTAssertEqual(snapshot()?.applicableStopReason, .noData, "a previous run's result must not apply")
    }

    func testStopRecordedForSessionWhileRunningIsYellow() {
        ingest(sample(10))
        clock.advance(30)
        var spec = sample(11)
        spec.stopReason = "abnormalExit"
        spec.stopSessionId = session1
        ingest(spec)
        assertStatus(.yellow, .stopReportConflict)
    }

    func testNullAndUnknownMinerStateAreYellowAndStayDistinct() {
        var unknown = sample(10)
        unknown.running = "unknown"
        ingest(unknown)
        assertStatus(.yellow, .minerStateUnknown)
        XCTAssertEqual(snapshot()?.sample?.minerRunning.state, .unknown)

        clock.advance(30)
        var missing = sample(11)
        missing.running = NSNull()
        ingest(missing)
        assertStatus(.yellow, .minerStateUnknown)
        XCTAssertEqual(snapshot()?.sample?.minerRunning.state, .noData)
    }

    func testExpectedRunningDoesNotDriveTheLight() {
        var first = sample(10)
        first.expectedRunning = "unknown"
        ingest(first)
        clock.advance(30)
        var second = sample(11)
        second.expectedRunning = NSNull()
        ingest(second)
        assertStatus(.green, .miningConfirmed)
        XCTAssertEqual(snapshot()?.sample?.expectedRunning, .noData)
    }

    // MARK: - 300 s boundary

    func testExactly300SecondsIsStillCurrent() {
        establishGreen()
        clock.advance(300)
        assertStatus(.green, .miningConfirmed, historical: false)
        XCTAssertEqual(snapshot()?.sampleAge, 300)
    }

    func testJustOver300SecondsIsGray() {
        establishGreen()
        clock.advance(300.001)
        assertStatus(.gray, .dataTooOld, historical: true)
    }

    // MARK: - Replay and ordering

    func testReplayedSampleDoesNotRefreshFreshness() {
        ingest(sample(10))
        clock.advance(30)
        let latest = sample(11)
        ingest(latest)
        assertStatus(.green, .miningConfirmed)

        clock.advance(30)
        ingest(latest)
        assertStatus(.yellow, .updateProblem(.replayOrOutOfOrder), historical: true)
        XCTAssertEqual(snapshot()?.sampleAge, 30)

        clock.advance(271) // 301 s since the last accepted sample, replays in between
        ingest(latest)
        assertStatus(.gray, .dataTooOld, historical: true)
    }

    func testHigherSequenceWithOlderObservedAtIsRejected() {
        ingest(sample(10))
        clock.advance(30)
        ingest(sample(11))
        clock.advance(30)
        let old = SampleSpec(sequence: 99, at: testStart.addingTimeInterval(10), accepted: 12)
        ingest(old)
        assertStatus(.yellow, .updateProblem(.replayOrOutOfOrder))
        XCTAssertEqual(snapshot()?.sample?.sampleSequence, 2)
    }

    func testLowerSequenceWithNewerObservedAtIsRejected() {
        ingest(sample(10))
        clock.advance(30)
        ingest(sample(11))
        clock.advance(30)
        ingest(SampleSpec(sequence: 1, at: clock.wall, accepted: 12))
        assertStatus(.yellow, .updateProblem(.replayOrOutOfOrder))
    }

    func testSessionChangeAndRetiredSessionReplay() {
        establishGreen()
        clock.advance(30)
        ingest(sample(0, session: session2))
        assertStatus(.yellow, .awaitingShareEvidence)

        clock.advance(30)
        ingest(SampleSpec(sequence: 99, at: clock.wall, accepted: 12, session: session1))
        assertStatus(.yellow, .updateProblem(.retiredSession), historical: true)
        XCTAssertEqual(snapshot()?.sample?.sessionId, session2)

        clock.advance(30)
        ingest(sample(1, session: session2)) // rejection broke the baseline
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(2, session: session2))
        assertStatus(.green, .miningConfirmed)
    }

    // MARK: - Clocks

    func testMateriallyFutureTimestampIsRejected() {
        ingest(SampleSpec(sequence: 1, at: clock.wall.addingTimeInterval(11), accepted: 10))
        assertStatus(.gray, .noData)
        XCTAssertEqual(snapshot()?.problem, .futureTimestamp)
    }

    func testSmallFutureSkewIsClampedToZeroAge() {
        ingest(SampleSpec(sequence: 1, at: clock.wall.addingTimeInterval(5), accepted: 10))
        assertStatus(.yellow, .awaitingShareEvidence)
        XCTAssertEqual(snapshot()?.sampleAge, 0)
    }

    func testWallClockJumpForwardBreaksEvidence() {
        establishGreen()
        clock.wall += 3_600
        clock.monotonic += 30
        assertStatus(.yellow, .updateProblem(.clockDiscontinuity), historical: true)

        ingest(sample(12))
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(13))
        assertStatus(.green, .miningConfirmed)
    }

    func testWallClockRollbackIsDetectedAndSourceTimeLooksFuture() {
        establishGreen() // last sample observed at T+30
        clock.monotonic += 30
        clock.wall += 30 - 600
        assertStatus(.yellow, .updateProblem(.clockDiscontinuity), historical: true)

        // Source clock is unaffected: T+60 is now 600 s ahead of the client wall clock.
        ingest(SampleSpec(sequence: 3, at: testStart.addingTimeInterval(60), accepted: 12))
        assertStatus(.yellow, .updateProblem(.futureTimestamp))
    }

    func testMonotonicRollbackMakesAgeUnverifiable() {
        establishGreen()
        let held = SampleSpec(sequence: 2, at: clock.wall, accepted: 11)
        clock.monotonic = 5
        clock.wall += 30
        assertStatus(.gray, .ageUnverifiable, historical: true)
        XCTAssertNil(snapshot()?.sampleAge)

        ingest(held) // replay identity survives the reset
        XCTAssertEqual(snapshot()?.problem, .replayOrOutOfOrder)

        ingest(sample(12))
        assertStatus(.yellow, .awaitingShareEvidence, historical: false)
    }

    // MARK: - Metric freshness

    func testPerMetricFreshness() {
        var spec = sample(10)
        spec.hashrateAt = clock.wall.addingTimeInterval(-400)
        spec.gpuAt = clock.wall.addingTimeInterval(-10)
        spec.lastAcceptedAt = nil
        spec.sharesAt = clock.wall.addingTimeInterval(60)
        ingest(spec)

        clock.advance(5)
        let freshness = snapshot()?.freshness
        XCTAssertEqual(freshness?.minerRunning, .fresh(age: 5))
        XCTAssertEqual(freshness?.hashrate, .stale(age: 405), "reused hashrate stays stale")
        XCTAssertEqual(freshness?.gpus, [.fresh(age: 15)])
        XCTAssertEqual(freshness?.lastAcceptedShare, .noTimestamp)
        XCTAssertEqual(freshness?.shares, .unverifiable, "metric newer than its sample")
    }

    func testSwitchingDemoAndLiveStartsOver() throws {
        establishGreen()
        clock.advance(30)
        let live = feedJSON([sample(12).json], origin: "live", notice: NSNull())
        engine.ingest(try decodeFeed(live), at: clock.reading)
        assertStatus(.yellow, .awaitingShareEvidence)
        XCTAssertEqual(snapshot()?.dataOrigin, .live)
    }

    // MARK: - Review findings (regressions)

    /// Finding 1: evidence must not survive a stopped sample.
    func testStoppedSampleInvalidatesEvidence() {
        establishGreen()
        clock.advance(30)
        var stopped = sample(11)
        stopped.running = "stopped"
        ingest(stopped)
        assertStatus(.red, .minerStopped)

        clock.advance(30)
        ingest(sample(11))
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(12))
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 1: evidence must not survive an unknown sample.
    func testUnknownSampleInvalidatesEvidence() {
        establishGreen()
        clock.advance(30)
        var unknown = sample(11)
        unknown.running = "unknown"
        ingest(unknown)
        clock.advance(30)
        ingest(sample(11))
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    /// Finding 1: both samples of an evidence pair must confirm `running`.
    func testEvidencePairRequiresRunningOnBothSamples() {
        var stopped = sample(10)
        stopped.running = "stopped"
        ingest(stopped)
        clock.advance(30)
        ingest(sample(11))
        assertStatus(.yellow, .awaitingShareEvidence)

        clock.advance(30)
        var staleRunning = sample(12)
        staleRunning.runningAt = clock.wall.addingTimeInterval(-400)
        ingest(staleRunning)
        clock.advance(30)
        ingest(sample(13))
        assertStatus(.yellow, .awaitingShareEvidence, historical: false)
    }

    /// Finding 2: a failed request breaks the pair; reconnect needs a new baseline and a later increase.
    func testRequestFailureRequiresNewBaseline() {
        establishGreen()
        clock.advance(10)
        engine.recordRequestFailure(at: clock.reading)
        assertStatus(.yellow, .updateProblem(.requestFailed), historical: true)
        XCTAssertEqual(snapshot()?.sampleAge, 10)

        clock.advance(20)
        ingest(sample(12)) // increase vs the pre-failure sample must not count
        assertStatus(.yellow, .awaitingShareEvidence, historical: false)
        clock.advance(30)
        ingest(sample(13))
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 2: old evidence must not survive a failure either.
    func testRequestFailureDiscardsExistingEvidence() {
        establishGreen()
        clock.advance(10)
        engine.recordRequestFailure(at: clock.reading)
        clock.advance(20)
        ingest(sample(11))
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    /// Finding 2: an unavailable source breaks the pair.
    func testSourceUnavailableRequiresNewBaseline() {
        establishGreen()
        clock.advance(30)
        var unreachable = sample(12)
        unreachable.sourceStatus = "unreachable"
        ingest(unreachable)
        assertStatus(.yellow, .updateProblem(.sourceUnavailable(.unreachable)), historical: true)

        clock.advance(30)
        ingest(sample(12))
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(13))
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 2: a machine missing from the feed breaks the pair.
    func testMissingMachineRequiresNewBaseline() {
        establishGreen()
        clock.advance(30)
        var other = sample(1)
        other.machineId = "demo-rig-b"
        other.displayName = "示範礦機 B（DEMO）"
        ingest(other)
        assertStatus(.yellow, .updateProblem(.missingFromFeed), historical: true)

        clock.advance(30)
        ingest(sample(12))
        assertStatus(.yellow, .awaitingShareEvidence)
    }

    /// Finding 3: the current share observation must be fresh and verifiable, and an unverifiable
    /// one breaks the chain: a later valid sample with unchanged accepted must not resurrect green.
    func testFutureCurrentShareObservationRejectsGreen() {
        establishGreen()
        clock.advance(30)
        var spec = sample(11)
        spec.sharesAt = clock.wall.addingTimeInterval(60) // later than its own sample beyond skew
        ingest(spec)
        assertStatus(.yellow, .awaitingShareEvidence)
        XCTAssertEqual(snapshot()?.freshness?.shares, .unverifiable)

        clock.advance(30)
        ingest(sample(11)) // valid again, unchanged accepted: old evidence is gone
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(12)) // new baseline above, then a later increase
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 3: a sample without a share timestamp cannot keep green or serve as a baseline.
    func testMissingCurrentShareObservationRejectsGreen() {
        establishGreen()
        clock.advance(30)
        var spec = sample(11)
        spec.sharesAt = nil
        ingest(spec)
        assertStatus(.yellow, .awaitingShareEvidence)
        XCTAssertEqual(snapshot()?.freshness?.shares, .noTimestamp)

        clock.advance(30)
        ingest(sample(11)) // unchanged accepted must not resurrect the old evidence
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(12))
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 3: an increase measured from a sample without a share timestamp does not count.
    func testIncreaseAfterMissingShareObservationNeedsNewBaseline() {
        establishGreen()
        clock.advance(30)
        var spec = sample(11)
        spec.sharesAt = nil
        ingest(spec)

        clock.advance(30)
        ingest(sample(12)) // increase vs a non-baseline sample
        assertStatus(.yellow, .awaitingShareEvidence)
        clock.advance(30)
        ingest(sample(13))
        assertStatus(.green, .miningConfirmed)
    }

    /// Finding 4: held data after a failed or rejected update is historical before 300 s.
    func testHeldDataIsHistoricalAfterFailureOrRejection() {
        establishGreen()
        let held = SampleSpec(sequence: 2, at: clock.wall, accepted: 11)

        clock.advance(10)
        engine.recordRequestFailure(at: clock.reading)
        XCTAssertEqual(snapshot()?.isHistorical, true)

        clock.advance(10)
        ingest(held)
        XCTAssertEqual(snapshot()?.isHistorical, true)
        XCTAssertEqual(snapshot()?.sampleAge, 20)

        clock.advance(10)
        ingest(sample(12))
        XCTAssertEqual(snapshot()?.isHistorical, false)
    }

    /// Design choice: a fresh stop stays red through a failed request, but the data is historical.
    func testFreshStopStaysRedAfterFailureButIsHistorical() {
        var stopped = sample(10)
        stopped.running = "stopped"
        ingest(stopped)
        clock.advance(10)
        engine.recordRequestFailure(at: clock.reading)
        assertStatus(.red, .minerStopped, historical: true)
        XCTAssertEqual(snapshot()?.problem, .requestFailed)
    }
}
