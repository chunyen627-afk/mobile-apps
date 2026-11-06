import Charts
import SwiftUI
import ThermoCore

/// The history chart on a thermometer's page: 24 hours, 7 days or 30 days of temperature,
/// humidity or battery, with the lowest, highest and mean value of the period.
struct ThermoHistorySection: View {
    @ObservedObject var model: ThermoModel
    let ref: ThermoSensorRef
    @State private var range: ThermoRange = .day
    @State private var metric: ThermoMetric = .temperature
    @State private var history: ThermoHistory?
    @State private var error: ThermoFetchError?
    @State private var loading = false

    var body: some View {
        Section {
            Picker("期間", selection: $range) {
                ForEach(ThermoRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("thermo-range")
            Picker("項目", selection: $metric) {
                ForEach(ThermoMetric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("thermo-metric")
            chart
                .frame(height: 220)
                .accessibilityIdentifier("thermo-chart")
            if let history, let summary = history.summary(metric) {
                HStack {
                    stat("最低", metric.format(summary.min), .blue)
                    Spacer()
                    stat("平均", metric.format(summary.average), .primary)
                    Spacer()
                    stat("最高", metric.format(summary.max), .red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thermo-summary")
            }
        } header: {
            Text("紀錄")
        } footer: {
            Text("閘道每 5 分鐘記一筆；圖上每點是 \(bucketText) 的平均。閘道沒收到的時段會留白。")
        }
        .task(id: range) { await load() }
    }

    private var bucketText: String {
        switch range {
        case .day: return "5 分鐘"
        case .week: return "30 分鐘"
        case .month: return "2 小時"
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let history, !history.segments(metric).isEmpty {
            let segments = history.segments(metric)
            let values = segments.flatMap { $0 }.compactMap { $0.value(metric) }
            let low = values.min() ?? 0, high = values.max() ?? 1
            let pad = Swift.max(0.5, (high - low) * 0.15)
            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    ForEach(segment) { point in
                        LineMark(
                            x: .value("時間", point.date),
                            y: .value(metric.title, point.value(metric) ?? 0),
                            series: .value("段", index)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(color)
                    }
                }
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.month(.defaultDigits).day())
                }
            }
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            Label(error.displayText, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("這段期間還沒有紀錄。閘道開始收到後，每 5 分鐘會多一筆。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var color: Color {
        switch metric {
        case .temperature: return .orange
        case .humidity: return .blue
        case .battery: return .green
        }
    }

    private func stat(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().foregroundStyle(tint)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch await model.history(ref, range: range) {
        case .success(let value):
            history = value
            error = nil
        case .failure(let failure):
            history = nil
            error = failure
        }
    }
}
