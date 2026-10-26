// UNRUN: written on Windows without a Swift toolchain (2026-10-24). Not yet compiled or executed.

import Foundation
@testable import MinerStatusCore

/// 2026-10-24T09:30:00Z, an arbitrary fixed instant for hand-written demo samples.
let testStart = Timestamp(rfc3339: "2026-10-24T09:30:00Z")!.date

struct TestClock {
    var wall = testStart
    var monotonic: TimeInterval = 1_000

    var reading: ClockReading { ClockReading(wall: wall, monotonic: monotonic) }

    /// Both clocks move together, as on a healthy device.
    mutating func advance(_ seconds: TimeInterval) {
        wall += seconds
        monotonic += seconds
    }
}

func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func timestampJSON(_ date: Date?) -> Any { date.map { rfc3339($0) as Any } ?? NSNull() }
private func nullable(_ value: Any?) -> Any { value ?? NSNull() }

/// One hand-written demo machine entry. Every timestamp defaults to the sample time;
/// set a property to nil to emit an explicit JSON null.
struct SampleSpec {
    var machineId = "demo-rig-a"
    var displayName = "示範礦機 A（DEMO）"
    var worker: String? = "demo-worker-a"
    var sourceStatus = "ok"
    var sourceCheckedAt: Date?
    var sessionId: String?
    var sequence: Int?
    var observedAt: Date?
    var expectedRunning: Any = true
    var running: Any = "running"
    var runningAt: Date?
    var hashrate: Double? = 70
    var hashrateUnit: String? = "TH/s"
    var hashrateAt: Date?
    var gpuAt: Date?
    var accepted: Int?
    var stale: Int? = 0
    var rejected: Int? = 0
    var sharesAt: Date?
    var lastAcceptedAt: Date?
    var stopReason: Any = NSNull()
    var stopSessionId: String?
    var stopAt: Date?

    init(sequence: Int?, at time: Date?, accepted: Int?, session: String? = "demo-session-1") {
        self.sessionId = session
        self.sequence = sequence
        self.observedAt = time
        self.sourceCheckedAt = time
        self.runningAt = time
        self.hashrateAt = time
        self.gpuAt = time
        self.accepted = accepted
        self.sharesAt = time
    }

    var json: [String: Any] {
        [
            "machineId": machineId,
            "displayName": displayName,
            "worker": nullable(worker),
            "sourceStatus": sourceStatus,
            "sourceCheckedAt": timestampJSON(sourceCheckedAt),
            "sessionId": nullable(sessionId),
            "sampleSequence": nullable(sequence),
            "observedAt": timestampJSON(observedAt),
            "expectedRunning": expectedRunning,
            "minerRunning": ["state": running, "observedAt": timestampJSON(runningAt)] as [String: Any],
            "hashrate": [
                "value": nullable(hashrate),
                "unit": nullable(hashrateUnit),
                "observedAt": timestampJSON(hashrateAt),
            ] as [String: Any],
            "gpus": [
                [
                    "index": 0,
                    "temperatureC": 65,
                    "fanPercent": 80,
                    "powerW": 110,
                    "observedAt": timestampJSON(gpuAt),
                ] as [String: Any],
            ],
            "shares": [
                "accepted": nullable(accepted),
                "stale": nullable(stale),
                "rejected": nullable(rejected),
                "observedAt": timestampJSON(sharesAt),
                "lastAcceptedAt": timestampJSON(lastAcceptedAt),
            ] as [String: Any],
            "stop": [
                "reason": stopReason,
                "sessionId": nullable(stopSessionId),
                "observedAt": timestampJSON(stopAt),
            ] as [String: Any],
        ]
    }
}

func feedJSON(
    _ machines: [[String: Any]],
    origin: String = "demo",
    notice: Any = "示範資料（人工編寫的測試資料，非真實連線）"
) -> [String: Any] {
    [
        "schemaVersion": 1,
        "dataOrigin": origin,
        "demoNotice": notice,
        "publishedAt": NSNull(),
        "machines": machines,
    ]
}

func decodeFeed(_ object: Any) throws -> MinerStatusFeed {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(MinerStatusFeed.self, from: data)
}

/// Package root, derived from this file's location (Tests/MinerStatusCoreTests/TestSupport.swift).
func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures")
        .appendingPathComponent(name)
}
