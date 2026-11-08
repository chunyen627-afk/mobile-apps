import Charts
import SwiftUI
import ThermoCore

/// The history on a thermometer's page, as in Mi Home: day (a line of 30-minute points), week and
/// month (one bar per day from its lowest to its highest), for temperature, humidity or battery,
/// with the period's lowest, mean and highest.
struct ThermoHistorySection: View {
    @ObservedObject var model: ThermoModel
    let ref: ThermoSensorRef
    @State private var range: ThermoRange = .day
    @State private var metric: ThermoMetric = .temperature
    @State private var history: ThermoHistory?
    @State private var error: ThermoFetchError?
    @State private var loading = false
    /// Wide and short (an iPad in landscape, set by the page): pickers side by side, a lower chart.
    var wideAndShort = false

    private var fahrenheit: Bool { model.preferences.fahrenheit }

    var body: some View {
        Section {
            if wideAndShort {
                HStack(spacing: 16) {
                    rangePicker
                    metricPicker
                }
            } else {
                rangePicker
                metricPicker
            }
            chart
                .frame(height: wideAndShort ? 150 : 220)
                .accessibilityIdentifier("thermo-chart")
            if let history, let summary = history.summary(metric) {
                HStack {
                    stat("最低", metric.format(summary.min, fahrenheit: fahrenheit), .blue)
                    Spacer()
                    stat("平均", metric.format(summary.average, fahrenheit: fahrenheit), .primary)
                    Spacer()
                    stat("最高", metric.format(summary.max, fahrenheit: fahrenheit), .red)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("thermo-summary")
            }
        } header: {
            Text("歷史紀錄")
        } footer: {
            Text(range.isDaily ? "每天一條：從當天最低到最高。閘道沒收到的日子留白。"
                               : "每 30 分鐘一點的平均。閘道沒收到的時段留白。")
        }
        .task(id: range) { await load() }
    }

    private var rangePicker: some View {
        Picker("期間", selection: $range) {
            ForEach(ThermoRange.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("thermo-range")
    }

    private var metricPicker: some View {
        Picker("項目", selection: $metric) {
            ForEach(ThermoMetric.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("thermo-metric")
    }

    private var bars: Bool { range.isDaily && metric != .battery }

    @ViewBuilder
    private var chart: some View {
        if let history, !history.segments(metric).isEmpty {
            let segments = history.segments(metric)
            let points = segments.flatMap { $0 }
            let lows = points.compactMap { $0.low(metric) }.map { metric.display($0, fahrenheit: fahrenheit) }
            let highs = points.compactMap { $0.high(metric) }.map { metric.display($0, fahrenheit: fahrenheit) }
            let low = lows.min() ?? 0, high = highs.max() ?? 1
            let pad = Swift.max(0.5, (high - low) * 0.15)
            Chart {
                if bars {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("日期", point.date, unit: .day),
                            yStart: .value("最低", metric.display(point.low(metric) ?? 0, fahrenheit: fahrenheit)),
                            yEnd: .value("最高", metric.display(point.high(metric) ?? 0, fahrenheit: fahrenheit)),
                            width: .ratio(0.5)
                        )
                        .foregroundStyle(color.gradient)
                        .clipShape(Capsule())
                    }
                } else {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment) { point in
                            LineMark(
                                x: .value("時間", point.date),
                                y: .value(metric.title, metric.display(point.value(metric) ?? 0, fahrenheit: fahrenheit)),
                                series: .value("段", index)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(color)
                        }
                    }
                }
            }
            .chartYScale(domain: (low - pad)...(high + pad))
            .chartXAxis {
                if range == .day {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                } else {
                    AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 7)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
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
