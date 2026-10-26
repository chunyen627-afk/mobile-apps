import MinerStatusCore
import SwiftUI

// Whether mining the machines that pay for electricity is worth it now, shown only when the
// source sends the advice extension. Covers switched-off machines, which have no machine row,
// and offers a remote power-on for those the source can wake (feature `wake`).

struct AdviceSection: View {
    @ObservedObject var model: AppModel
    let items: [AdviceReport]
    let now: Date
    @State private var pendingWake: AdviceReport?

    var body: some View {
        Section {
            ForEach(items, id: \.machineId) { item in
                VStack(alignment: .leading, spacing: 8) {
                    AdviceRow(item: item, now: now)
                    if item.canWake == true, model.mode == .live {
                        wakeControl(item)
                    }
                }
            }
        } header: {
            Text("開挖建議（要算電費的機器）").textCase(nil)
        } footer: {
            Text("電腦端依每台實測算力與耗電、目前幣價與台電電價估算挖礦是否划算。標示「自動」的機器由電腦端自己決定開關：離峰划算就開機挖，尖峰不划算就停挖關機。只是估算，隨時可以手動操作。")
        }
        .confirmationDialog("遠端開機？", isPresented: Binding(get: { pendingWake != nil }, set: { if !$0 { pendingWake = nil } }),
                            titleVisibility: .visible, presenting: pendingWake) { item in
            Button("確定遠端開機") {
                Task { await model.sendControl(.wake, to: item.machineId) }
            }
            .accessibilityIdentifier("confirm-wake")
            Button("取消", role: .cancel) {}
        } message: { item in
            Text("電腦端會請同一個網路裡的電腦叫醒「\(item.displayName)」，約 1 分鐘後開機完成；開機後不會自己開始挖礦。")
        }
    }

    @ViewBuilder private func wakeControl(_ item: AdviceReport) -> some View {
        if !model.hasControlToken {
            Text("在「資料來源」設定輸入控制密碼後，就能從這裡遠端開機。").font(.caption).foregroundStyle(.secondary)
        } else {
            Button { pendingWake = item } label: { Label("遠端開機", systemImage: "power") }
                .buttonStyle(.borderless)
                .disabled(model.controlInFlight != nil)
                .accessibilityIdentifier("wake-\(item.machineId)")
            if model.controlInFlight == item.machineId {
                HStack { ProgressView(); Text("傳送中…") }
            }
        }
        if let notice = model.controlNotice, notice.machineId == item.machineId {
            Text(notice.text)
                .font(.caption)
                .foregroundStyle(notice.succeeded ? Color.green : Color.red)
                .accessibilityIdentifier("wake-result")
        }
    }
}

struct AdviceRow: View {
    let item: AdviceReport
    let now: Date

    private var mine: Bool { item.recommendation == .mine }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: mine ? "bolt.circle.fill" : "moon.zzz.fill")
                    .foregroundStyle(mine ? Color.green : Color.secondary)
                Text(item.displayName).font(.headline)
                Spacer()
                Text(mine ? "建議挖礦" : "建議停挖")
                    .font(.subheadline.bold())
                    .foregroundStyle(mine ? Color.green : Color.orange)
            }
            Text("每月淨收益約 \(EarningsText.twd(item.monthlyNetTwd))").font(.subheadline).monospacedDigit()
            Text("達 \(EarningsText.twd(item.startAtTwd)) 建議挖・低於 \(EarningsText.twd(item.stopBelowTwd)) 建議停")
                .font(.caption).foregroundStyle(.secondary)
            Text(item.reason).font(.caption)
            if let since = DisplayText.clock(item.since, now: now) {
                Text("建議自 \(since) 起").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("advice-\(item.machineId)")
    }
}
