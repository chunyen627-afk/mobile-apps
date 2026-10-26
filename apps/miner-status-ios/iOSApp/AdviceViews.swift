import MinerStatusCore
import SwiftUI

// Whether mining the machines that pay for electricity is worth it now, shown only when the
// source sends the advice extension. Covers switched-off machines, which have no machine row.

struct AdviceSection: View {
    let items: [AdviceReport]
    let now: Date

    var body: some View {
        Section {
            ForEach(items, id: \.machineId) { item in
                AdviceRow(item: item, now: now)
            }
        } header: {
            Text("開挖建議（要算電費的機器）").textCase(nil)
        } footer: {
            Text("電腦端依每台實測算力與耗電、目前幣價與台電平均電價，估算挖一整個月扣掉電費的淨收益。連續數小時越過門檻才改變建議，並推播通知；只是估算，開不開由你決定。")
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
