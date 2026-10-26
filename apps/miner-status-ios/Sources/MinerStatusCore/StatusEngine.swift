import Foundation

// Deterministic per-machine status state machine. No clock, timer or I/O inside: every call
// takes a `ClockReading`, so identical inputs always give identical lights.
//
// Lights (checked in this order):
// - gray:   no accepted sample, sample age unknown, or age > staleAfter (exactly staleAfter is current).
// - red:    miner explicitly `stopped` with a fresh observation. Kept through a later failed
//           request while still fresh: the stop was confirmed recently and nothing contradicts it.
// - yellow: anything uncertain. Any update problem since the last accepted sample (failed request,
//           unavailable source, missing machine, replay, future timestamp, clock jump, ...) removes
//           green at once and marks the held sample historical.
// - green:  fresh `running` observation, no stop recorded for this session, a fresh current share
//           observation, and an accepted-counter increase observed between two fresh samples of
//           the same session within shareEvidenceWindow, both of which confirmed `running`.
//           The first sample of a session is therefore never green; a positive hashrate, a
//           cumulative accepted count or lastAcceptedAt are never enough on their own.
//
// Evidence chain: anything that breaks mining confirmation (a sample that is not fresh `running`,
// a missing/stale/unverifiable share observation, a stop for the session, a counter regression)
// or any rejected update/failure discards existing
// share evidence and disqualifies the held sample as a baseline. Green then needs a new baseline
// sample followed by a later accepted-counter increase.
//
// Age = (client wall − source observedAt) at receipt, clamped at 0, plus monotonic time elapsed
// since receipt. Source time more than maxFutureSkew ahead is rejected. A sample only refreshes
// freshness if its observedAt is strictly newer than the last accepted one and, within the same
// session, its sampleSequence is strictly higher; sessions that were superseded are never accepted
// again. publishedAt is ignored for freshness: rewriting a cache must not make data newer.
// Limitation: the very first reading trusts the client wall clock, bounded only by the future check.

// MARK: - Inputs and policy

/// Both client clocks read together. `monotonic` must keep counting through device sleep
/// (ContinuousClock / CLOCK_MONOTONIC on Darwin), otherwise every wake-up looks like a wall-clock jump.
public struct ClockReading: Hashable, Sendable {
    public var wall: Date
    public var monotonic: TimeInterval

    public init(wall: Date, monotonic: TimeInterval) {
        self.wall = wall
        self.monotonic = monotonic
    }
}

public struct StatusPolicy: Hashable, Sendable {
    /// Older than this is gray; exactly equal is still current.
    public var staleAfter: TimeInterval
    /// The newest observed accepted-counter increase must be at most this old for green.
    public var shareEvidenceWindow: TimeInterval
    /// Source time up to this far ahead of the client wall clock is skew (age 0); further is rejected.
    public var maxFutureSkew: TimeInterval
    /// Allowed |Δwall − Δmonotonic| between consecutive readings before a wall-clock jump is assumed.
    public var maxClockDrift: TimeInterval
    /// Superseded session ids remembered per machine for replay rejection.
    public var retiredSessionLimit: Int

    public init(
        staleAfter: TimeInterval = 300,
        shareEvidenceWindow: TimeInterval = 300,
        maxFutureSkew: TimeInterval = 10,
        maxClockDrift: TimeInterval = 5,
        retiredSessionLimit: Int = 32
    ) {
        self.staleAfter = staleAfter
        self.shareEvidenceWindow = shareEvidenceWindow
        self.maxFutureSkew = maxFutureSkew
        self.maxClockDrift = maxClockDrift
        self.retiredSessionLimit = max(0, retiredSessionLimit)
    }
}

// MARK: - Outputs

public enum StatusLight: String, Hashable, Sendable {
    case green, yellow, red, gray
}

/// Why the light has its color. Exactly one per snapshot.
public enum StatusReason: Hashable, Sendable {
    // gray
    case noData
    case dataTooOld
    /// The monotonic clock went backwards; the age of held data cannot be computed.
    case ageUnverifiable
    // red
    case minerStopped
    // yellow
    case updateProblem(UpdateProblem)
    /// minerRunning is "unknown" or null.
    case minerStateUnknown
    /// minerRunning has no timestamp, a stale one, or an unverifiable one.
    case minerStateNotFresh
    /// A stop is recorded for the current session while the miner reports running.
    case stopReportConflict
    /// No recent same-session accepted-counter increase between two fresh samples (yet).
    case awaitingShareEvidence
    // green
    case miningConfirmed
    // publisher
    /// The source's own judgment, shown while its sample is fresh (any light).
    case publisherAssessment(title: String, detail: String)
    /// The source sends judgments but its latest sample is too old to show one (gray).
    case publisherSilent
}

/// Most recent problem since the last accepted sample; cleared by the next accepted sample.
public enum UpdateProblem: Hashable, Sendable {
    case requestFailed
    case sourceUnavailable(SourceStatus)
    case missingFromFeed
    /// sessionId, sampleSequence or observedAt is null.
    case incompleteSample
    case futureTimestamp
    /// observedAt not strictly newer, or sampleSequence not strictly higher in the same session.
    case replayOrOutOfOrder
    case retiredSession
    /// Accepted count went down within one session; share evidence was discarded.
    case counterRegression
    case clockDiscontinuity
}

public enum Freshness: Hashable, Sendable {
    case fresh(age: TimeInterval)
    case stale(age: TimeInterval)
    case noTimestamp
    /// Later than its own sample beyond skew, or the client age is unknown.
    case unverifiable

    public var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

public struct MetricFreshness: Hashable, Sendable {
    public let minerRunning: Freshness
    public let hashrate: Freshness
    public let shares: Freshness
    public let lastAcceptedShare: Freshness
    /// Same order as `sample.gpus`; empty when gpus is null.
    public let gpus: [Freshness]
}

public struct MachineSnapshot: Hashable, Sendable {
    public let machineId: String
    public let displayName: String
    public let dataOrigin: DataOrigin
    public let light: StatusLight
    public let reason: StatusReason
    public let problem: UpdateProblem?
    /// Last accepted sample, never a rejected or replayed entry; nil before the first one.
    public let sample: MachineStatus?
    /// Age of `sample` on the client timeline; nil when there is none or it cannot be computed.
    public let sampleAge: TimeInterval?
    /// `sample` exists but is not currently confirmed: age unknown or beyond staleAfter, or a later
    /// update failed or was rejected (even within staleAfter).
    public let isHistorical: Bool
    public let freshness: MetricFreshness?
    /// The stop reason only when recorded for the sample's own session; otherwise `.noData`.
    public let applicableStopReason: Reported<StopReason>
}

// MARK: - Engine

public struct StatusEngine: Sendable {
    public let policy: StatusPolicy
    public private(set) var dataOrigin: DataOrigin?
    /// Set by a failed request; cleared by the next ingested feed. Lets the UI explain an empty list.
    public private(set) var feedProblem: UpdateProblem?

    private var trackers: [String: MachineTracker] = [:]
    private var order: [String] = []
    private var lastReading: ClockReading?

    public init(policy: StatusPolicy = StatusPolicy()) {
        self.policy = policy
    }

    /// A successfully decoded feed. Switching between demo and live data starts from scratch.
    public mutating func ingest(_ feed: MinerStatusFeed, at reading: ClockReading) {
        observeClock(reading)
        if dataOrigin != feed.dataOrigin {
            trackers = [:]
            order = []
            dataOrigin = feed.dataOrigin
        }
        feedProblem = nil

        // Local copy: reading self.policy while mutating self.trackers would overlap accesses to self.
        let policy = self.policy
        let present = Set(feed.machines.map(\.machineId))
        for id in order where !present.contains(id) {
            trackers[id]?.reject(.missingFromFeed)
        }
        for machine in feed.machines {
            if trackers[machine.machineId] == nil {
                trackers[machine.machineId] = MachineTracker(displayName: machine.displayName)
                order.append(machine.machineId)
            }
            trackers[machine.machineId]?.ingest(machine, at: reading, policy: policy)
        }
    }

    /// Network error, HTTP error, timeout or undecodable body. Removes every green immediately.
    public mutating func recordRequestFailure(at reading: ClockReading) {
        observeClock(reading)
        feedProblem = .requestFailed
        for id in order {
            trackers[id]?.reject(.requestFailed)
        }
    }

    /// Mutating only because each reading is also checked for clock discontinuities.
    public mutating func snapshots(at reading: ClockReading) -> [MachineSnapshot] {
        observeClock(reading)
        guard let origin = dataOrigin else { return [] }
        return order.compactMap { id in
            trackers[id]?.snapshot(machineId: id, dataOrigin: origin, at: reading, policy: policy)
        }
    }

    private mutating func observeClock(_ reading: ClockReading) {
        defer { lastReading = reading }
        guard let previous = lastReading else { return }
        let monotonicDelta = reading.monotonic - previous.monotonic
        let wallDelta = reading.wall.timeIntervalSince(previous.wall)
        if monotonicDelta < 0 {
            for id in order { trackers[id]?.clockDiscontinuity(monotonicReset: true) }
        } else if abs(wallDelta - monotonicDelta) > policy.maxClockDrift {
            for id in order { trackers[id]?.clockDiscontinuity(monotonicReset: false) }
        }
    }
}

// MARK: - Per-machine state

private struct MonotonicAnchor: Hashable, Sendable {
    let ageAtReceipt: TimeInterval
    let receivedMonotonic: TimeInterval

    func age(at reading: ClockReading) -> TimeInterval? {
        let elapsed = reading.monotonic - receivedMonotonic
        return elapsed >= 0 ? ageAtReceipt + elapsed : nil
    }
}

private struct AcceptedSample: Sendable {
    let status: MachineStatus
    let sessionId: String
    let sequence: Int
    let observedAt: Timestamp
    /// nil after the monotonic clock went backwards.
    var anchor: MonotonicAnchor?
    /// false when this sample did not confirm `running`, regressed its counter, or was followed by
    /// a rejected update/clock jump: it may not be the earlier half of a share-evidence pair.
    var isBaseline = true

    /// The stop reason only when recorded for this sample's own session.
    var applicableStopReason: Reported<StopReason> {
        status.stop.sessionId == sessionId ? status.stop.reason : .noData
    }
}

private struct ShareEvidence: Sendable {
    let sessionId: String
    let accepted: Int
    let sharesObservedAt: Timestamp
    /// Age of the share observation in which the increase was seen.
    let anchor: MonotonicAnchor
}

private struct MachineTracker: Sendable {
    var displayName: String
    var latest: AcceptedSample?
    var evidence: ShareEvidence?
    var retiredSessions: [String] = []
    var problem: UpdateProblem?
    /// The last update yielded no accepted sample, so `latest` is held, unconfirmed data.
    var holdsUnconfirmedData = false

    init(displayName: String) {
        self.displayName = displayName
    }

    /// Any update that does not yield an accepted sample breaks the evidence chain.
    mutating func reject(_ reason: UpdateProblem) {
        problem = reason
        evidence = nil
        latest?.isBaseline = false
        holdsUnconfirmedData = latest != nil
    }

    mutating func clockDiscontinuity(monotonicReset: Bool) {
        if monotonicReset { latest?.anchor = nil }
        reject(.clockDiscontinuity)
    }

    mutating func ingest(_ machine: MachineStatus, at reading: ClockReading, policy: StatusPolicy) {
        guard machine.sourceStatus == .ok else {
            reject(.sourceUnavailable(machine.sourceStatus))
            return
        }
        guard let session = machine.sessionId,
              let sequence = machine.sampleSequence,
              let observedAt = machine.observedAt
        else {
            reject(.incompleteSample)
            return
        }
        let rawAge = reading.wall.timeIntervalSince(observedAt.date)
        guard rawAge >= -policy.maxFutureSkew else {
            reject(.futureTimestamp)
            return
        }
        guard !retiredSessions.contains(session) else {
            reject(.retiredSession)
            return
        }
        if let last = latest {
            guard observedAt > last.observedAt,
                  session != last.sessionId || sequence > last.sequence
            else {
                reject(.replayOrOutOfOrder)
                return
            }
        }

        var sample = AcceptedSample(
            status: machine, sessionId: session, sequence: sequence, observedAt: observedAt,
            anchor: MonotonicAnchor(ageAtReceipt: max(0, rawAge), receivedMonotonic: reading.monotonic))
        let sameSession = latest?.sessionId == session
        var regressed = false
        if sameSession, let previousAccepted = latest?.status.shares.accepted,
           let currentAccepted = machine.shares.accepted {
            regressed = currentAccepted < previousAccepted
        }
        // A sample breaks the chain unless it confirms `running` with a fresh, verifiable share observation.
        let confirmsMining = policy.confirmsRunning(sample, at: reading)
            && policy.freshness(of: machine.shares.observedAt, in: sample, at: reading).isFresh

        if !sameSession, let last = latest {
            // New session: counters restart, nothing carries over, the old session is never accepted again.
            retiredSessions.append(last.sessionId)
            if retiredSessions.count > policy.retiredSessionLimit {
                retiredSessions.removeFirst(retiredSessions.count - policy.retiredSessionLimit)
            }
        }
        if regressed || !confirmsMining {
            sample.isBaseline = false
        }
        if !sameSession || regressed || !confirmsMining {
            evidence = nil
        } else if let last = latest,
                  let found = shareEvidence(from: last, to: sample, at: reading, policy: policy) {
            evidence = found
        }

        latest = sample
        problem = regressed ? .counterRegression : nil
        holdsUnconfirmedData = false
        displayName = machine.displayName
    }

    /// An accepted-counter increase between two fresh samples of the same session that both
    /// confirmed `running`, with both share observations fresh and strictly ordered.
    /// The caller has already checked that `current` confirms `running`.
    private func shareEvidence(
        from previous: AcceptedSample, to current: AcceptedSample,
        at reading: ClockReading, policy: StatusPolicy
    ) -> ShareEvidence? {
        guard previous.isBaseline,
              policy.confirmsRunning(previous, at: reading),
              let previousAge = previous.anchor?.age(at: reading), previousAge <= policy.staleAfter,
              let previousAccepted = previous.status.shares.accepted,
              let currentAccepted = current.status.shares.accepted,
              currentAccepted > previousAccepted,
              let previousSharesAt = previous.status.shares.observedAt,
              let currentSharesAt = current.status.shares.observedAt,
              currentSharesAt > previousSharesAt,
              policy.freshness(of: previousSharesAt, in: previous, at: reading).isFresh,
              case .fresh(let currentSharesAge) = policy.freshness(of: currentSharesAt, in: current, at: reading),
              currentSharesAge <= policy.shareEvidenceWindow
        else { return nil }
        return ShareEvidence(
            sessionId: current.sessionId, accepted: currentAccepted, sharesObservedAt: currentSharesAt,
            anchor: MonotonicAnchor(ageAtReceipt: currentSharesAge, receivedMonotonic: reading.monotonic))
    }

    func snapshot(
        machineId: String, dataOrigin: DataOrigin, at reading: ClockReading, policy: StatusPolicy
    ) -> MachineSnapshot {
        guard let latest else {
            return MachineSnapshot(
                machineId: machineId, displayName: displayName, dataOrigin: dataOrigin,
                light: .gray, reason: .noData, problem: problem, sample: nil, sampleAge: nil,
                isHistorical: false, freshness: nil, applicableStopReason: .noData)
        }

        let status = latest.status
        let age = latest.anchor?.age(at: reading)
        let freshness = MetricFreshness(
            minerRunning: policy.freshness(of: status.minerRunning.observedAt, in: latest, at: reading),
            hashrate: policy.freshness(of: status.hashrate.observedAt, in: latest, at: reading),
            shares: policy.freshness(of: status.shares.observedAt, in: latest, at: reading),
            lastAcceptedShare: policy.freshness(of: status.shares.lastAcceptedAt, in: latest, at: reading),
            gpus: (status.gpus ?? []).map { policy.freshness(of: $0.observedAt, in: latest, at: reading) })
        let stopReason = latest.applicableStopReason
        let (light, reason) = classify(
            latest, age: age, freshness: freshness, stopReason: stopReason, at: reading, policy: policy)
        let beyondThreshold = age.map { $0 > policy.staleAfter } ?? true

        return MachineSnapshot(
            machineId: machineId, displayName: displayName, dataOrigin: dataOrigin,
            light: light, reason: reason, problem: problem, sample: status, sampleAge: age,
            isHistorical: holdsUnconfirmedData || beyondThreshold,
            freshness: freshness, applicableStopReason: stopReason)
    }

    private func classify(
        _ latest: AcceptedSample, age: TimeInterval?, freshness: MetricFreshness,
        stopReason: Reported<StopReason>, at reading: ClockReading, policy: StatusPolicy
    ) -> (StatusLight, StatusReason) {
        guard let age else { return (.gray, .ageUnverifiable) }
        guard age <= policy.staleAfter else { return (.gray, .dataTooOld) }

        let state = latest.status.minerRunning.state
        if state == .value(.stopped) {
            return freshness.minerRunning.isFresh ? (.red, .minerStopped) : (.yellow, .minerStateNotFresh)
        }
        if let problem { return (.yellow, .updateProblem(problem)) }
        guard state == .value(.running) else { return (.yellow, .minerStateUnknown) }
        guard freshness.minerRunning.isFresh else { return (.yellow, .minerStateNotFresh) }
        guard stopReason == .noData else { return (.yellow, .stopReportConflict) }
        guard hasCurrentShareEvidence(latest, at: reading, policy: policy) else {
            return (.yellow, .awaitingShareEvidence)
        }
        return (.green, .miningConfirmed)
    }

    /// Evidence must belong to the current session and still be recent; the current share
    /// observation must itself be fresh and verifiable, and must not contradict the evidence.
    private func hasCurrentShareEvidence(
        _ latest: AcceptedSample, at reading: ClockReading, policy: StatusPolicy
    ) -> Bool {
        guard let evidence, evidence.sessionId == latest.sessionId,
              let evidenceAge = evidence.anchor.age(at: reading),
              evidenceAge <= policy.shareEvidenceWindow, evidenceAge <= policy.staleAfter,
              let accepted = latest.status.shares.accepted, accepted >= evidence.accepted,
              let sharesAt = latest.status.shares.observedAt, sharesAt >= evidence.sharesObservedAt,
              policy.freshness(of: sharesAt, in: latest, at: reading).isFresh
        else { return false }
        return true
    }
}

private extension StatusPolicy {
    /// Fresh `running` observation and no stop recorded for the sample's own session.
    func confirmsRunning(_ sample: AcceptedSample, at reading: ClockReading) -> Bool {
        sample.status.minerRunning.state == .value(.running)
            && freshness(of: sample.status.minerRunning.observedAt, in: sample, at: reading).isFresh
            && sample.applicableStopReason == .noData
    }

    /// A metric's age = its sample's age plus how much older the metric is than the sample.
    func freshness(of timestamp: Timestamp?, in sample: AcceptedSample, at reading: ClockReading) -> Freshness {
        guard let timestamp else { return .noTimestamp }
        guard let sampleAge = sample.anchor?.age(at: reading) else { return .unverifiable }
        let lag = sample.observedAt.date.timeIntervalSince(timestamp.date)
        guard lag >= -maxFutureSkew else { return .unverifiable }
        let age = sampleAge + max(0, lag)
        return age <= staleAfter ? .fresh(age: age) : .stale(age: age)
    }
}
