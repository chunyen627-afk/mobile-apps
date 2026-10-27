import MinerStatusCore
import SwiftUI

// Health details sent by the source with its own judgment (feature `assessment`).

enum HealthText {
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分鐘" }
        let minutes = Int(seconds / 60)
        return minutes % 60 == 0 ? "\(minutes / 60) 小時" : "\(minutes / 60) 小時 \(minutes % 60) 分"
    }

    static func ago(_ timestamp: Timestamp?, now: Date) -> String? {
        timestamp.map { "\(duration(max(0, now.timeIntervalSince($0.date))))前" }
    }

    /// One line for a machine row: "最後份額 1 分鐘前・已運轉 9 小時 32 分".
    static func rowLine(_ health: HealthReport, now: Date) -> String? {
        let parts = [ago(health.lastShareAt, now: now).map { "最後份額 \($0)" },
                     health.uptimeSeconds.map { "已運轉 \(duration($0))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

struct HealthDetailSection: View {
    let health: HealthReport
    /// The machine's own reported hashrate in H/s, to compare with what the pool credits.
    let localHashrate: Double?
    let now: Date

    var body: some View {
        Section("健康") {
            LabeledContent("運轉時間", value: health.uptimeSeconds.map(HealthText.duration) ?? DisplayText.noData)
            LabeledContent("最後份額", value: DisplayText.clock(health.lastShareAt, now: now) ?? DisplayText.noData)
            LabeledContent("平常份額間隔", value: health.expectedShareSeconds.map { "約 \(HealthText.duration($0))一個" } ?? DisplayText.noData)
            LabeledContent("礦池認列算力", value: poolText)
            LabeledContent("份額有效率", value: health.validSharePercent.map { "\($0.formatted(.number.precision(.fractionLength(0 ... 2))))%" } ?? DisplayText.noData)
            LabeledContent("最高溫度", value: temperatureText)
            LabeledContent("礦池狀態", value: health.poolOnline.map { $0 ? "在線" : "離線" } ?? DisplayText.noData)
        }
    }

    private var poolText: String {
        guard let pool = health.poolHashrate else { return DisplayText.noData }
        // In the machine's own scale: an FPGA's 150 MH/s must not read as 0.0 TH/s.
        let (scale, unit) = [(1e12, "TH/s"), (1e9, "GH/s"), (1e6, "MH/s"), (1e3, "kH/s")].first { pool >= $0.0 } ?? (1, "H/s")
        let text = "\((pool / scale).formatted(.number.precision(.fractionLength(1)))) \(unit)"
        guard let local = localHashrate, local > 0 else { return text }
        return "\(text)（本機的 \(Int((pool / local * 100).rounded()))%）"
    }

    private var temperatureText: String {
        guard let hottest = health.maxGpuTemperatureC else { return DisplayText.noData }
        let value = "\(Int(hottest.rounded()))°C"
        guard let limit = health.temperatureLimitC else { return value }
        return "\(value)（保護線 \(Int(limit.rounded()))°C，還差 \(Int((limit - hottest).rounded()))°C）"
    }
}

extension HashrateReport {
    /// Value in H/s, or nil when the value or unit is missing.
    var hashesPerSecond: Double? {
        guard let value, let unit else { return nil }
        return value * unit.hashesPerSecondMultiplier
    }
}
