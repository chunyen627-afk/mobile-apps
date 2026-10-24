// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.

import Foundation
import MinerStatusCore

// Offline demo: replays fixed scenarios built from the bundled demo-running.json through the
// real decoder and StatusEngine at a frozen simulated clock. No networking.

enum DemoScenario: String, CaseIterable, Identifiable {
    case firstSample, confirmedMining, stopped, unknown, stale, requestFailure, incompleteData
    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstSample: return "首筆資料"
        case .confirmedMining: return "確認挖礦（兩筆樣本）"
        case .stopped: return "已停止"
        case .unknown: return "未知／無資料欄位"
        case .stale: return "資料逾時（超過 5 分鐘）"
        case .requestFailure: return "請求失敗"
        case .incompleteData: return "資料不足／時間無法驗證"
        }
    }

    var summary: String {
        switch self {
        case .firstSample: return "第 0 秒收到首筆資料，第 5 秒評估；首筆不足以確認挖礦。"
        case .confirmedMining: return "第 0、30 秒兩筆同工作資料，接受份額增加；第 35 秒評估。"
        case .stopped: return "第 0 秒資料明確回報 miner 已停止；第 5 秒評估。"
        case .unknown: return "A 含「未知」欄位，B 含 null（無資料）欄位；第 5 秒評估。"
        case .stale: return "第 0、30 秒確認挖礦後再無有效資料；第 331 秒評估。"
        case .requestFailure: return "第 30 秒確認挖礦，第 40 秒請求失敗；第 45 秒評估。"
        case .incompleteData: return "A 缺資料時間，B 資料時間超前本機 1 小時；第 5 秒評估。"
        }
    }

    fileprivate var steps: [DemoStep] {
        switch self {
        case .firstSample:
            return [.samples(offset: 0, sequence: 1, accepted: 40)]
        case .confirmedMining, .stale:
            return [.samples(offset: 0, sequence: 1, accepted: 40), .samples(offset: 30, sequence: 2, accepted: 41)]
        case .stopped:
            return [.samples(offset: 0, sequence: 1, accepted: 40) { machine, context in
                let reason = context.index == 0 ? "userRequested" : "unknown"
                setField(&machine, "minerRunning", "state", "stopped")
                machine["stop"] = [
                    "reason": reason,
                    "sessionId": context.session,
                    "observedAt": demoTimestamp(context.time),
                ]
            }]
        case .unknown:
            return [.samples(offset: 0, sequence: 1, accepted: 40) { machine, context in
                if context.index == 0 {
                    machine["expectedRunning"] = "unknown"
                    machine["worker"] = NSNull()
                    setField(&machine, "minerRunning", "state", "unknown")
                    setField(&machine, "hashrate", "value", NSNull())
                    setField(&machine, "hashrate", "unit", NSNull())
                    setField(&machine, "shares", "stale", NSNull())
                    setField(&machine, "shares", "rejected", NSNull())
                    setField(&machine, "shares", "lastAcceptedAt", NSNull())
                } else {
                    machine["expectedRunning"] = NSNull()
                    machine["gpus"] = NSNull()
                    setField(&machine, "minerRunning", "state", NSNull())
                }
            }]
        case .requestFailure:
            return [
                .samples(offset: 0, sequence: 1, accepted: 40),
                .samples(offset: 30, sequence: 2, accepted: 41),
                .requestFailure(offset: 40),
            ]
        case .incompleteData:
            return [.samples(offset: 0, sequence: 1, accepted: 40) { machine, context in
                if context.index == 0 {
                    machine["observedAt"] = NSNull()
                } else {
                    machine["observedAt"] = demoTimestamp(context.time.addingTimeInterval(3_600))
                }
            }]
        }
    }

    fileprivate var evaluateAt: TimeInterval {
        switch self {
        case .confirmedMining: return 35
        case .stale: return 331
        case .requestFailure: return 45
        default: return 5
        }
    }
}

fileprivate struct StepContext {
    let index: Int
    let time: Date
    let session: String
}

fileprivate enum DemoStep {
    case samples(offset: TimeInterval, sequence: Int, accepted: Int,
                 edit: ((inout [String: Any], StepContext) -> Void)? = nil)
    case requestFailure(offset: TimeInterval)
}

func demoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
    return formatter.string(from: date)
}

fileprivate func setField(_ object: inout [String: Any], _ key: String, _ field: String, _ value: Any) {
    var inner = (object[key] as? [String: Any]) ?? [:]
    inner[field] = value
    object[key] = inner
}

struct DemoResult {
    let snapshots: [MachineSnapshot]
    let feedProblem: UpdateProblem?
    let clock: ClockReading
}

/// Holds the bundled template. `loadBundled()` returns nil when the resource is missing or not
/// marked demo; the app then shows a load error instead of inventing data.
struct DemoPlayer {
    let notice: String
    private let template: [String: Any]
    private let baseDate: Date

    static func loadBundled() -> DemoPlayer? {
        guard let url = Bundle.main.url(forResource: "demo-running", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let feed = try? JSONDecoder().decode(MinerStatusFeed.self, from: data), feed.isDemo,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let machine = (object["machines"] as? [[String: Any]])?.first,
              let base = feed.machines.first?.observedAt?.date
        else { return nil }
        return DemoPlayer(notice: feed.demoNotice ?? "", template: machine, baseDate: base)
    }

    func run(_ scenario: DemoScenario) throws -> DemoResult {
        func reading(_ offset: TimeInterval) -> ClockReading {
            ClockReading(wall: baseDate.addingTimeInterval(offset), monotonic: 10_000 + offset)
        }

        var engine = StatusEngine()
        for step in scenario.steps {
            switch step {
            case let .samples(offset, sequence, accepted, edit):
                let time = baseDate.addingTimeInterval(offset)
                let machines = (0 ..< 2).map { index -> [String: Any] in
                    var machine = machineJSON(index: index, sequence: sequence, accepted: accepted, at: time)
                    let session = (machine["sessionId"] as? String) ?? ""
                    edit?(&machine, StepContext(index: index, time: time, session: session))
                    return machine
                }
                engine.ingest(try decodeFeed(machines, at: time), at: reading(offset))
            case let .requestFailure(offset):
                engine.recordRequestFailure(at: reading(offset))
            }
        }
        let now = reading(scenario.evaluateAt)
        return DemoResult(snapshots: engine.snapshots(at: now), feedProblem: engine.feedProblem, clock: now)
    }

    /// Re-stamps the template machine for one step. Index 1 is a second, equally fictional machine.
    private func machineJSON(index: Int, sequence: Int, accepted: Int, at time: Date) -> [String: Any] {
        var machine = template
        let stamp = demoTimestamp(time)
        if index == 1 {
            machine["machineId"] = "demo-rig-b"
            machine["displayName"] = "示範礦機 B（DEMO）"
            machine["worker"] = "demo-worker-b"
            machine["sessionId"] = "demo-session-b-0001"
            setField(&machine, "hashrate", "value", 35.0)
        }
        machine["sampleSequence"] = sequence
        machine["observedAt"] = stamp
        machine["sourceCheckedAt"] = stamp
        setField(&machine, "minerRunning", "observedAt", stamp)
        setField(&machine, "hashrate", "observedAt", stamp)
        setField(&machine, "shares", "accepted", accepted + index * 100)
        setField(&machine, "shares", "observedAt", stamp)
        setField(&machine, "shares", "lastAcceptedAt", demoTimestamp(time.addingTimeInterval(-8)))
        if var gpus = machine["gpus"] as? [[String: Any]] {
            if index == 1 { gpus = Array(gpus.prefix(1)) }
            for gpu in gpus.indices { gpus[gpu]["observedAt"] = stamp }
            machine["gpus"] = gpus
        }
        return machine
    }

    /// Every derived entry goes back through the real decoder, so the whitelist still applies.
    private func decodeFeed(_ machines: [[String: Any]], at time: Date) throws -> MinerStatusFeed {
        let object: [String: Any] = [
            "schemaVersion": 1, "dataOrigin": "demo", "demoNotice": notice,
            "publishedAt": demoTimestamp(time), "machines": machines,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MinerStatusFeed.self, from: data)
    }
}
