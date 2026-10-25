// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.

import MinerStatusCore
import SwiftUI

// MARK: - Overview

struct OverviewList: View {
    @ObservedObject var model: AppModel
    var selection: Binding<String?>?
    let showSettings: () -> Void
    @State private var showingEarningsSettings = false
    @State private var confirmingStop = false

    var body: some View {
        Group {
            if let selection { List(selection: selection) { content } } else { List { content } }
        }
        .sheet(isPresented: $showingEarningsSettings) { EarningsSettingsView(model: model) }
        // Owned by the list (not the row) and confirmed, because the button was easy to hit by accident.
        .confirmationDialog("停止讀取並回到離線示範？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("停止讀取", role: .destructive) { model.stopLiveAndReturnToDemo() }
                .accessibilityIdentifier("confirm-stop-live")
            Button("取消", role: .cancel) {}
        } message: {
            Text("會停止讀取電腦端的資料，改顯示內建的示範資料。")
        }
        .navigationTitle(model.mode == .demo ? "礦機狀態（示範）" : "礦機狀態")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: showSettings) {
                    Label("資料來源", systemImage: "antenna.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("source-settings")
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let headline = StatusAlerts.headline(model.snapshots) {
            let text = "\(headline)：\(StatusAlerts.needingAttention(model.snapshots).map(\.displayName).joined(separator: "、"))"
            Section {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                    // Without this VoiceOver (and UI tests) read only the icon's name.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text)
                    .accessibilityIdentifier("attention-banner")
            }
        }

        switch model.mode {
        case .demo: demoSection
        case .live: liveSection
        }

        if let problem = model.feedProblem {
            Section { Label("最近一次請求：\(problem.displayText)", systemImage: "exclamationmark.triangle") }
        }

        Section("機器") {
            if model.snapshots.isEmpty {
                Text(model.mode == .live ? "尚未收到有效資料" : DisplayText.noData).foregroundStyle(.secondary)
            }
            ForEach(model.snapshots, id: \.machineId) { snapshot in
                NavigationLink(value: snapshot.machineId) {
                    MachineRow(snapshot: snapshot,
                               healthLine: snapshot.sample?.health.flatMap { HealthText.rowLine($0, now: model.displayNow) },
                               earningsLine: model.hasEarnings ? EarningsText.rowLine(model.earnings(for: snapshot)) : nil)
                }
                    .accessibilityIdentifier("machine-\(snapshot.machineId)")
            }
        }

        // Below the machines so their rows stay on the first screen.
        if model.hasEarnings {
            EarningsSummarySection(model: model) { showingEarningsSettings = true }
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

    @ViewBuilder private var demoSection: some View {
        Section {
            // A pushed list rather than a Menu: a Menu inside the List did not open reliably in the
            // simulator UI tests, and seven long titles read better as a list on a phone.
            Picker("目前情境", selection: Binding(get: { model.scenario }, set: { model.selectDemo($0) })) {
                ForEach(DemoScenario.allCases) { scenario in
                    Text(scenario.title).tag(scenario)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("scenario-picker")
            Text(model.scenario.summary).font(.caption).foregroundStyle(.secondary)
            if let error = model.demoError {
                Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
            }
        } header: {
            Text("示範情境（僅限示範）")
        } footer: {
            Text("只切換內建人工資料；不連線、不輪詢、不控制礦機。")
        }
    }

    @ViewBuilder private var liveSection: some View {
        Section {
            LabeledContent("狀態", value: model.isPolling ? "前景讀取中（每 \(Int(model.pollInterval)) 秒）" : "已暫停（App 不在前景）")
            LabeledContent("最後嘗試", value: model.lastAttemptAt.map(timeText) ?? DisplayText.noData)
            LabeledContent("最後成功", value: model.lastSuccessAt.map(timeText) ?? DisplayText.noData)
            if let failure = model.lastFailure {
                Label(failure.displayText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityIdentifier("live-failure")
            }
            Button("立即讀取一次") { model.refreshNow() }
                .disabled(!model.isPolling)
            Button("停止讀取並回到離線示範", role: .destructive) { confirmingStop = true }
                .accessibilityIdentifier("stop-live")
        } header: {
            Text("自訂來源（唯讀）")
        } footer: {
            Text("只送出 GET 讀取請求；沒有任何控制礦機的功能。App 離開前景即停止讀取。")
        }
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

struct MachineRow: View {
    let snapshot: MachineSnapshot
    var healthLine: String?
    var earningsLine: String?

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
                if let healthLine {
                    Text(healthLine).font(.caption.monospacedDigit())
                }
                if let earningsLine {
                    Text(earningsLine).font(.caption.monospacedDigit())
                }
                if snapshot.dataOrigin == .demo {
                    Text("示範資料").font(.caption2.bold()).foregroundStyle(.orange)
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
    @ObservedObject var model: AppModel
    let machineId: String

    var body: some View {
        Group {
            if let snapshot = model.snapshots.first(where: { $0.machineId == machineId }) {
                DetailContent(snapshot: snapshot,
                              earnings: model.hasEarnings ? model.earnings(for: snapshot) : nil,
                              market: model.market, now: model.displayNow)
            } else {
                Text("目前沒有這台機器的資料").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.mode == .demo ? "詳情（示範）" : "詳情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DetailContent: View {
    let snapshot: MachineSnapshot
    var earnings: MachineEarnings?
    var market: MarketReport?
    var now = Date()

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

            if let health = snapshot.sample?.health {
                HealthDetailSection(health: health, localHashrate: snapshot.sample?.hashrate.hashesPerSecond, now: now)
            }

            if let earnings {
                EarningsDetailSection(earnings: earnings, market: market)
            }

            if let sample = snapshot.sample {
                details(sample)
            } else {
                Section { Text("尚無可顯示的有效資料（不代表主機離線）").foregroundStyle(.secondary) }
            }

            if snapshot.dataOrigin == .demo {
                Section { Text("示範資料：人工編寫，非真實礦機連線。").font(.caption).foregroundStyle(.secondary) }
            }
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
