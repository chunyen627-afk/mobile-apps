import MinerStatusCore
import SwiftUI

// Today's electricity price. Shown in every mode, on the real clock, so it also serves as a
// household reference for the same Taipower tariff.

enum TariffText {
    static func rate(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) 元／度"
    }

    static func hour(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    static func kind(_ isPeak: Bool) -> String { isPeak ? "尖峰" : "離峰" }

    /// "1 小時 20 分", rounded up to the minute.
    static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小時" }
        if hours == 0 { return "\(minutes) 分" }
        return minutes % 60 == 0 ? "\(hours) 小時" : "\(hours) 小時 \(minutes % 60) 分"
    }

    /// "今天 14:00", "今天 24:00" (the coming midnight), "明天 06:00", "10/27（二）06:00".
    static func when(_ date: Date, now: Date, calendar: Calendar = .taipei) -> String {
        let hour = calendar.component(.hour, from: date)
        let time = String(format: "%02d:%02d", hour, calendar.component(.minute, from: date))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "今天 \(time)"
        case 1 where hour == 0 && calendar.component(.minute, from: date) == 0: return "今天 24:00"
        case 1: return "明天 \(time)"
        default: return "\(day(date, calendar: calendar)) \(time)"
        }
    }

    /// "10/27（二）".
    static func day(_ date: Date, calendar: Calendar = .taipei) -> String {
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][calendar.component(.weekday, from: date) - 1]
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))（\(weekday)）"
    }
}

struct TodayTariffSection: View {
    @ObservedObject var model: AppModel
    let showSettings: () -> Void

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        } header: {
            HStack {
                Text("今日電價")
                Spacer()
                Button("費率設定", action: showSettings)
                    .font(.subheadline)
                    .accessibilityIdentifier("tariff-settings")
            }
            .textCase(nil)
        } footer: {
            Text("台電表燈簡易型時間電價（二段式），\(sourceText)。夏月 6/1–9/30；週末與放假日全天離峰。放假日依政府行政機關辦公日曆，台電的離峰日可能略有不同。")
        }
    }

    private var sourceText: String {
        if model.usingSourceRates, let report = model.sourceTariff {
            return report.effectiveDate.map { "台電公告 \($0) 起的費率" } ?? "台電公告的費率"
        }
        return model.earningsSettings.tariff == .taipowerSimpleTwoStage ? "App 內建費率" : "自訂費率"
    }

    @ViewBuilder private func content(now: Date) -> some View {
        let calendar = Calendar.taipei
        let tariff = model.effectiveTariff
        let schedule = tariff.schedule(on: now, calendar: calendar)
        let hour = calendar.component(.hour, from: now)
        let current = schedule.first { $0.startHour <= hour && hour < $0.endHour } ?? schedule[0]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("現在\(TariffText.kind(current.isPeak))")
                    .font(.title3.bold())
                    .foregroundStyle(current.isPeak ? Color.orange : Color.green)
                Spacer()
                Text(TariffText.rate(current.rate)).font(.headline).monospacedDigit()
            }
            if let next = tariff.nextChange(after: now, calendar: calendar) {
                let nextRate = tariff.rate(at: next, calendar: calendar)
                let nextKind = TariffText.kind(tariff.period(at: next, calendar: calendar).name.hasSuffix("尖峰"))
                Text("\(TariffText.when(next, now: now, calendar: calendar)) 起改為\(nextKind) \(TariffText.rate(nextRate))（還有 \(TariffText.remaining(next.timeIntervalSince(now)))）")
                    .font(.subheadline)
            }
            if let reason = tariff.offPeakReason(on: now, calendar: calendar) {
                Text("今天是\(reason)，全天離峰").font(.subheadline.bold())
            } else {
                ForEach(schedule, id: \.startHour) { segment in
                    HStack {
                        Text("\(TariffText.hour(segment.startHour))–\(TariffText.hour(segment.endHour))")
                        Text(TariffText.kind(segment.isPeak))
                            .foregroundStyle(segment.isPeak ? Color.orange : Color.green)
                        Spacer()
                        Text(TariffText.rate(segment.rate))
                    }
                    .font(.subheadline)
                    .fontWeight(segment == current ? .semibold : .regular)
                    .monospacedDigit()
                }
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
               tariff.offPeakReason(on: now, calendar: calendar) == nil,
               let reason = tariff.offPeakReason(on: tomorrow, calendar: calendar) {
                Text("明天（\(TariffText.day(tomorrow, calendar: calendar))）是\(reason)，全天離峰")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.usingSourceRates, model.sourceTariff?.periodsMatch == false {
                Text("台電公告的尖離峰時段與 App 內建的不同，請以台電公告為準。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-tariff")
    }
}

/// Settings rows for where the rates come from. Embedded in EarningsSettingsView.
struct TariffSourceSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Toggle("使用台電公告費率（自動）", isOn: $model.earningsSettings.useSourceTariff)
                .accessibilityIdentifier("tariff-use-source")
            if let report = model.sourceTariff {
                LabeledContent("台電公告", value: report.effectiveDate.map { "\($0) 起" } ?? DisplayText.noData)
                LabeledContent("夏月 尖峰／離峰", value: "\(rate(report.summerPeak))／\(rate(report.summerOffPeak))")
                LabeledContent("非夏月 尖峰／離峰", value: "\(rate(report.nonSummerPeak))／\(rate(report.nonSummerOffPeak))")
                LabeledContent("已知放假日", value: holidays(report))
                if report.periodsMatch == false {
                    Text("台電公告的尖離峰時段與 App 內建的不同，請以台電公告為準。")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("尚未從電腦端收到台電費率；先用下方費率。").foregroundStyle(.secondary)
            }
        } header: {
            Text("費率來源").textCase(nil)
        } footer: {
            Text("電腦端每天向台電開放資料與政府行事曆查一次，費率調整或放假日都會自動套用。關掉就改用下方自己填的費率（放假日仍照算離峰）。")
        }
    }

    private func rate(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }

    private func holidays(_ report: TariffReport) -> String {
        let today = TouTariff.dayKey(Date())
        let upcoming = report.offPeakDates.filter { $0 >= today }.sorted()
        guard let first = upcoming.first else { return "無" }
        let short = first.dropFirst(5).replacingOccurrences(of: "-", with: "/")
        return upcoming.count == 1 ? "下一個 \(short)" : "\(upcoming.count) 天，下一個 \(short)"
    }
}
