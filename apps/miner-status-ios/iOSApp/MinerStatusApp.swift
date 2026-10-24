// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.
//
// Demo-only SwiftUI app over the real MinerStatusCore engine. No networking, polling, services
// or mining controls. Requires fixtures/demo-running.json to be added to the app target's
// bundle resources; without it the app shows a load error instead of inventing data.

import MinerStatusCore
import SwiftUI

@main
struct MinerStatusApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

// MARK: - Demo scenarios

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

fileprivate func demoTimestamp(_ date: Date) -> String {
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

// MARK: - Demo store

/// Replays a fixed scenario through the real StatusEngine at a frozen simulated clock.
/// Every derived entry goes back through the real decoder, so the whitelist still applies.
@MainActor
final class DemoStore: ObservableObject {
    @Published private(set) var scenario: DemoScenario = .confirmedMining
    @Published private(set) var snapshots: [MachineSnapshot] = []
    @Published private(set) var feedProblem: UpdateProblem?
    @Published private(set) var clock: ClockReading?
    @Published private(set) var loadError: String?
    let demoNotice: String

    private let template: [String: Any]?
    private let baseDate: Date?

    init() {
        if let url = Bundle.main.url(forResource: "demo-running", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let feed = try? JSONDecoder().decode(MinerStatusFeed.self, from: data), feed.isDemo,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let machine = (object["machines"] as? [[String: Any]])?.first,
           let base = feed.machines.first?.observedAt?.date {
            template = machine
            baseDate = base
            demoNotice = feed.demoNotice ?? ""
        } else {
            template = nil
            baseDate = nil
            demoNotice = ""
            loadError = "找不到或無法解碼內建示範資料 demo-running.json（需加入 App 資源，且必須標示為 demo）。"
        }
        select(.confirmedMining)
    }

    func select(_ scenario: DemoScenario) {
        self.scenario = scenario
        guard let template, let baseDate else { return }
        func reading(_ offset: TimeInterval) -> ClockReading {
            ClockReading(wall: baseDate.addingTimeInterval(offset), monotonic: 10_000 + offset)
        }

        var engine = StatusEngine()
        do {
            for step in scenario.steps {
                switch step {
                case let .samples(offset, sequence, accepted, edit):
                    let time = baseDate.addingTimeInterval(offset)
                    let machines = (0 ..< 2).map { index -> [String: Any] in
                        var machine = Self.machineJSON(template, index: index, sequence: sequence,
                                                       accepted: accepted, at: time)
                        let session = (machine["sessionId"] as? String) ?? ""
                        edit?(&machine, StepContext(index: index, time: time, session: session))
                        return machine
                    }
                    engine.ingest(try decodeDemoFeed(machines, at: time), at: reading(offset))
                case let .requestFailure(offset):
                    engine.recordRequestFailure(at: reading(offset))
                }
            }
        } catch {
            loadError = "示範資料未通過解碼：\(error.localizedDescription)"
            snapshots = []
            feedProblem = nil
            clock = nil
            return
        }
        let now = reading(scenario.evaluateAt)
        loadError = nil
        snapshots = engine.snapshots(at: now)
        feedProblem = engine.feedProblem
        clock = now
    }

    /// Re-stamps the fixture machine for one step. Index 1 is a second, equally fictional machine.
    private static func machineJSON(
        _ template: [String: Any], index: Int, sequence: Int, accepted: Int, at time: Date
    ) -> [String: Any] {
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

    private func decodeDemoFeed(_ machines: [[String: Any]], at time: Date) throws -> MinerStatusFeed {
        let object: [String: Any] = [
            "schemaVersion": 1, "dataOrigin": "demo", "demoNotice": demoNotice,
            "publishedAt": demoTimestamp(time), "machines": machines,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MinerStatusFeed.self, from: data)
    }
}

// MARK: - Root and banner

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var store = DemoStore()
    @State private var selection: String?

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    OverviewList(store: store, selection: $selection)
                } detail: {
                    NavigationStack {
                        if let selection {
                            MachineDetailView(store: store, machineId: selection)
                        } else {
                            Text("請選擇一台示範機器").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                NavigationStack {
                    OverviewList(store: store, selection: nil)
                        .navigationDestination(for: String.self) { MachineDetailView(store: store, machineId: $0) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { DemoBanner(store: store) }
    }
}

struct DemoBanner: View {
    @ObservedObject var store: DemoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("示範模式：人工編寫資料，非真實礦機連線", systemImage: "theatermasks.fill").font(.footnote.bold())
            if !store.demoNotice.isEmpty { Text(store.demoNotice).font(.caption2) }
            Text("模擬時鐘（已凍結，非目前時間）：\(store.clock.map { demoTimestamp($0.wall) } ?? DisplayText.noData)")
                .font(.caption2.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.25))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Overview

struct OverviewList: View {
    @ObservedObject var store: DemoStore
    var selection: Binding<String?>?

    var body: some View {
        Group {
            if let selection { List(selection: selection) { content } } else { List { content } }
        }
        .navigationTitle("礦機狀態（示範）")
    }

    @ViewBuilder private var content: some View {
        Section {
            Menu {
                ForEach(DemoScenario.allCases) { scenario in
                    Button { store.select(scenario) } label: {
                        if scenario == store.scenario { Label(scenario.title, systemImage: "checkmark") } else { Text(scenario.title) }
                    }
                }
            } label: {
                LabeledContent("目前情境", value: store.scenario.title)
            }
            Text(store.scenario.summary).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("示範情境（僅限示範）")
        } footer: {
            Text("只切換內建人工資料；不連線、不輪詢、不控制礦機。")
        }

        if let error = store.loadError {
            Section { Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
        }
        if let problem = store.feedProblem {
            Section { Label("最近一次請求：\(problem.displayText)", systemImage: "exclamationmark.triangle") }
        }

        Section("機器") {
            ForEach(store.snapshots, id: \.machineId) { snapshot in
                NavigationLink(value: snapshot.machineId) { MachineRow(snapshot: snapshot) }
            }
        }

        Section("圖例") {
            ForEach([StatusLight.green, .yellow, .red, .gray], id: \.self) { light in
                HStack(alignment: .top) {
                    StatusDot(light: light)
                    Text(light.legend).font(.caption)
                }
            }
        }
    }
}

struct MachineRow: View {
    let snapshot: MachineSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusDot(light: snapshot.light)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.displayName).font(.headline)
                Text("\(snapshot.light.displayName)・\(snapshot.statusTitle)").font(.subheadline)
                if let problem = snapshot.problem {
                    Text("最近問題：\(problem.displayText)").font(.caption).foregroundStyle(.orange)
                }
                Text("資料時間：\(snapshot.sample?.observedAt?.rfc3339 ?? DisplayText.noData)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if snapshot.isHistorical {
                    Text("歷史資料（未確認為目前狀態）").font(.caption.bold()).foregroundStyle(.orange)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let light: StatusLight

    var body: some View {
        Image(systemName: light.symbol)
            .font(.title3)
            .foregroundStyle(light.color)
            .accessibilityLabel(light.displayName)
    }
}

// MARK: - Detail

struct MachineDetailView: View {
    @ObservedObject var store: DemoStore
    let machineId: String

    var body: some View {
        Group {
            if let snapshot = store.snapshots.first(where: { $0.machineId == machineId }) {
                DetailContent(snapshot: snapshot)
            } else {
                Text("此機器在目前示範情境中沒有資料").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("詳情（示範）")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DetailContent: View {
    let snapshot: MachineSnapshot

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    StatusDot(light: snapshot.light)
                    Text("\(snapshot.light.displayName)・\(snapshot.statusTitle)").font(.headline)
                }
                Text(snapshot.reason.displayText).font(.subheadline)
                if let problem = snapshot.problem { LabeledContent("最近問題", value: problem.displayText) }
                LabeledContent("資料年齡", value: snapshot.sampleAge.map(DisplayText.age) ?? "無法計算")
                if snapshot.isHistorical {
                    Label("歷史資料：以下數值未確認為目前狀態", systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                }
            }

            if let sample = snapshot.sample {
                details(sample)
            } else {
                Section { Text("尚無可顯示的有效資料（不代表主機離線）").foregroundStyle(.secondary) }
            }

            Section { Text("示範資料：人工編寫，非真實礦機連線。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func details(_ sample: MachineStatus) -> some View {
        let freshness = snapshot.freshness
        let historical = snapshot.isHistorical

        Section("機器") {
            LabeledContent("電腦名稱", value: sample.displayName)
            LabeledContent("Machine ID", value: sample.machineId)
            LabeledContent("Worker", value: sample.worker ?? DisplayText.noData)
            LabeledContent("工作代號", value: sample.sessionId ?? DisplayText.noData)
            LabeledContent("序號", value: sample.sampleSequence.map(String.init) ?? DisplayText.noData)
            LabeledContent("資料時間", value: sample.observedAt?.rfc3339 ?? DisplayText.noData)
        }

        Section("運行") {
            LabeledContent("預期運行", value: sample.expectedRunning.displayText { $0 ? "是" : "否" })
            MetricRow(title: "miner 是否運行", value: sample.minerRunning.state.displayText(\.displayText),
                      freshness: freshness?.minerRunning, historical: historical)
            LabeledContent("停止原因（同一工作）", value: snapshot.applicableStopReason.displayText(\.displayText))
        }

        Section("算力") {
            MetricRow(title: "算力", value: hashrateText(sample.hashrate),
                      freshness: freshness?.hashrate, historical: historical)
        }

        Section("GPU") {
            if let gpus = sample.gpus {
                if gpus.isEmpty { Text("未回報 GPU") }
                ForEach(Array(gpus.enumerated()), id: \.offset) { position, gpu in
                    MetricRow(
                        title: "GPU \(gpu.index)",
                        value: "\(numberText(gpu.temperatureC, " °C"))・風扇 \(numberText(gpu.fanPercent, "%"))・\(numberText(gpu.powerW, " W"))",
                        freshness: freshness?.gpus.indices.contains(position) == true ? freshness?.gpus[position] : nil,
                        historical: historical)
                }
            } else {
                Text(DisplayText.noData)
            }
        }

        Section("份額") {
            LabeledContent("接受", value: sample.shares.accepted.map(String.init) ?? DisplayText.noData)
            LabeledContent("過期", value: sample.shares.stale.map(String.init) ?? DisplayText.noData)
            LabeledContent("拒絕", value: sample.shares.rejected.map(String.init) ?? DisplayText.noData)
            MetricRow(title: "份額資料時間", value: sample.shares.observedAt?.rfc3339 ?? DisplayText.noData,
                      freshness: freshness?.shares, historical: historical)
            MetricRow(title: "最後接受份額", value: sample.shares.lastAcceptedAt?.rfc3339 ?? DisplayText.noData,
                      freshness: freshness?.lastAcceptedShare, historical: historical)
        }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    let freshness: Freshness?
    let historical: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: value)
            Text(freshness?.displayText(historical: historical) ?? DisplayText.noData)
                .font(.caption)
                .foregroundStyle(freshnessColor)
        }
    }

    private var freshnessColor: Color {
        switch freshness {
        case .fresh?: return historical ? .orange : .green
        case .stale?: return .orange
        case .unverifiable?: return .purple
        case .noTimestamp?, nil: return .secondary
        }
    }
}

// MARK: - Formatting

private func numberText(_ value: Double?, _ suffix: String) -> String {
    guard let value else { return DisplayText.noData }
    return value.formatted(.number.precision(.fractionLength(0 ... 2))) + suffix
}

private func hashrateText(_ hashrate: HashrateReport) -> String {
    guard let value = hashrate.value else { return DisplayText.noData }
    let number = value.formatted(.number.precision(.fractionLength(0 ... 2)))
    return hashrate.unit.map { "\(number) \($0.rawValue)" } ?? "\(number)（單位\(DisplayText.noData)）"
}

private extension StatusLight {
    var color: Color {
        switch self {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        case .gray: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .green: return "checkmark.circle.fill"
        case .yellow: return "questionmark.circle.fill"
        case .red: return "stop.circle.fill"
        case .gray: return "minus.circle.fill"
        }
    }
}
