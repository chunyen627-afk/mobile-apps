import MinerStatusCore
import SwiftUI

// Estimated earnings and electricity, shown only when the source sends the earnings extension.

enum EarningsText {
    static func twd(_ value: Double?) -> String {
        value.map { "NT$\($0.formatted(.number.precision(.fractionLength(0))))" } ?? DisplayText.noData
    }

    static func coin(_ value: Double?, _ symbol: String) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(3)))) \(symbol)" } ?? DisplayText.noData
    }

    static func btc(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(8)))) BTC" } ?? DisplayText.noData
    }

    static func usd(_ value: Double?) -> String {
        value.map { "US$\($0.formatted(.number.precision(.fractionLength(0 ... 2))))" } ?? DisplayText.noData
    }

    /// One line for a machine row: "收益 ≈ NT$104/天・電費 NT$23・淨 NT$81".
    static func rowLine(_ earnings: MachineEarnings) -> String? {
        guard earnings.coinPerDay != nil || earnings.revenueTwdPerDay != nil else { return nil }
        let power = earnings.electricityBilled ? "電費 \(twd(earnings.electricityTwdPerDay))" : "電費不計"
        return "收益 ≈ \(twd(earnings.revenueTwdPerDay))/天・\(power)・淨 \(twd(earnings.netTwdPerDay))"
    }
}

/// Totals for all machines, per day. The settings sheet is presented by the list, not here: a
/// sheet attached to a List row closes when the row scrolls away and is recycled.
struct EarningsSummarySection: View {
    @ObservedObject var model: AppModel
    let showSettings: () -> Void

    var body: some View {
        let total = model.earningsTotal
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("收益（估算）", value: "\(EarningsText.twd(total.revenue))/天")
                LabeledContent("電費（有勾選的機器）", value: "\(EarningsText.twd(total.electricity))/天")
                LabeledContent("淨收益", value: "\(EarningsText.twd(total.net))/天").font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("earnings-summary")
            Button("收益與電費設定", action: showSettings)
                .accessibilityIdentifier("earnings-settings")
        } header: {
            Text("今日估算")
        } footer: {
            Text("依礦池近 3 小時平均算力與目前幣價估算，不是實際入帳金額；電費依台電簡易型二段式與目前耗電推算一整天。")
        }
    }
}

/// Detail screen section for one machine.
struct EarningsDetailSection: View {
    let earnings: MachineEarnings
    let market: MarketReport?

    var body: some View {
        Section("收益（估算，每天）") {
            LabeledContent("挖到的幣", value: EarningsText.coin(earnings.coinPerDay, market?.coin ?? "PRL"))
            LabeledContent("約等於", value: EarningsText.btc(earnings.btcPerDay))
            LabeledContent("收益", value: EarningsText.twd(earnings.revenueTwdPerDay))
            LabeledContent("耗電（顯卡＋額外）", value: earnings.powerW.map { "\(Int($0.rounded())) W" } ?? DisplayText.noData)
            LabeledContent("電費", value: earnings.electricityBilled ? EarningsText.twd(earnings.electricityTwdPerDay) : "不計")
            LabeledContent("淨收益", value: EarningsText.twd(earnings.netTwdPerDay)).font(.headline)
        }
        if let market {
            Section("幣價") {
                LabeledContent(market.coin, value: EarningsText.usd(market.coinUsd))
                LabeledContent("BTC", value: EarningsText.usd(market.btcUsd))
                LabeledContent("美元兌台幣", value: market.usdTwd.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? DisplayText.noData)
                LabeledContent("價格時間", value: market.observedAt?.rfc3339 ?? DisplayText.noData)
            }
        }
    }
}

struct EarningsSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.snapshots.isEmpty {
                        Text("尚未收到機器資料").foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshots, id: \.machineId) { snapshot in
                        Toggle("\(snapshot.displayName) 的電要算錢", isOn: Binding(
                            get: { model.isBilled(snapshot) },
                            set: { model.setBilled(snapshot.machineId, $0) }))
                            .accessibilityIdentifier("billed-\(snapshot.machineId)")
                        Stepper(value: Binding(
                            get: { model.extraWatts(snapshot.machineId) },
                            set: { model.setExtraWatts(snapshot.machineId, $0) }), in: 0 ... 500, step: 10) {
                            Text("額外耗電 \(Int(model.extraWatts(snapshot.machineId))) W")
                        }
                        .accessibilityIdentifier("extra-\(snapshot.machineId)")
                    }
                } header: {
                    Text("哪幾台的電要算錢").textCase(nil)
                } footer: {
                    Text("耗電＝顯卡回報的瓦數＋額外耗電（CPU、主機板、電源損耗）。可用插座電表量到的數字調整。")
                }

                Section {
                    rateField("夏月尖峰", \.summerPeak, id: "tariff-summer-peak")
                    rateField("夏月離峰", \.summerOffPeak, id: "tariff-summer-offpeak")
                    rateField("非夏月尖峰", \.nonSummerPeak, id: "tariff-nonsummer-peak")
                    rateField("非夏月離峰", \.nonSummerOffPeak, id: "tariff-nonsummer-offpeak")
                    Button("恢復台電預設費率") { model.earningsSettings.tariff = .taipowerSimpleTwoStage }
                } header: {
                    Text("台電簡易型時間電價（二段式），元／度").textCase(nil)
                } footer: {
                    Text("夏月 6/1–9/30。平日尖峰：夏月 09:00–24:00；非夏月 06:00–11:00、14:00–24:00；週末全天離峰。國定假日未另計為離峰；每戶 75 元基本電費不分攤到礦機。")
                }
            }
            .navigationTitle("收益與電費設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("earnings-done")
                }
            }
        }
    }

    private func rateField(_ title: String, _ path: WritableKeyPath<TouTariff, Double>, id: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { model.earningsSettings.tariff[keyPath: path] },
                set: { if $0 >= 0 { model.earningsSettings.tariff[keyPath: path] = $0 } }),
                format: .number.precision(.fractionLength(0 ... 2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
