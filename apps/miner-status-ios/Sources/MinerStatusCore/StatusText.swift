import Foundation

// zh-TW display text, kept in the core so XCTest can pin it down.
// Gray text only says what could not be established. It never claims the host is offline:
// a missing timestamp, an unverifiable clock, a failed request or an unreachable source all look
// the same from here as a powered-off host, so the app must not pretend to know which it is.

public enum DisplayText {
    public static let noData = "無資料"
    public static let unknown = "未知"

    public static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total < 60 ? "\(total) 秒" : "\(total / 60) 分 \(total % 60) 秒"
    }
}

public extension Reported {
    /// null → 無資料, "unknown" → 未知, otherwise `describe(value)`.
    func displayText(_ describe: (Value) -> String) -> String {
        switch self {
        case .value(let value): return describe(value)
        case .unknown: return DisplayText.unknown
        case .noData: return DisplayText.noData
        }
    }
}

public extension StatusLight {
    var displayName: String {
        switch self {
        case .green: return "綠燈"
        case .yellow: return "黃燈"
        case .red: return "紅燈"
        case .gray: return "灰燈"
        }
    }

    var legend: String {
        switch self {
        case .green: return "綠：miner 運行中，且同一工作的兩筆新資料間接受份額增加。"
        case .yellow: return "黃：連得到但無法確認挖礦（首筆資料、狀態未知、最近更新失敗等）。"
        case .red: return "紅：近期資料明確確認 miner 已停止。"
        case .gray: return "灰：超過 5 分鐘沒有有效資料、資料不足或時間無法驗證；不代表主機離線。"
        }
    }
}

public extension MachineSnapshot {
    var statusTitle: String {
        switch light {
        case .green: return "挖礦中（已確認）"
        case .yellow: return "無法確認挖礦"
        case .red: return "已停止（近期確認）"
        case .gray:
            switch (reason, problem) {
            case (.dataTooOld, _): return "資料逾時（超過 5 分鐘未更新）"
            case (.ageUnverifiable, _), (_, .futureTimestamp?), (_, .clockDiscontinuity?): return "時間無法驗證"
            case (_, .incompleteSample?): return "資料不足"
            case (_, .requestFailed?): return "請求失敗・尚無有效資料"
            case (_, .sourceUnavailable?): return "來源無法讀取・尚無有效資料"
            default: return "尚無資料"
            }
        }
    }
}

public extension StatusReason {
    var displayText: String {
        switch self {
        case .noData: return "尚無可用的有效樣本。"
        case .dataTooOld: return "最後一筆有效資料已超過 5 分鐘。"
        case .ageUnverifiable: return "本機時鐘不連續，資料年齡無法驗證。"
        case .minerStopped: return "最近的資料明確觀測到 miner 已停止。"
        case .updateProblem(let problem): return "最近更新有問題：\(problem.displayText)"
        case .minerStateUnknown: return "miner 運行狀態為未知或無資料。"
        case .minerStateNotFresh: return "miner 運行狀態的觀測不夠新或時間無法驗證。"
        case .stopReportConflict: return "本工作已有停止紀錄，但仍回報運行中。"
        case .awaitingShareEvidence: return "尚未在同一工作的兩筆新資料之間看到接受份額增加。"
        case .miningConfirmed: return "同一工作的兩筆新資料之間接受份額增加，且 miner 運行中。"
        }
    }
}

public extension UpdateProblem {
    var displayText: String {
        switch self {
        case .requestFailed: return "請求失敗"
        case .sourceUnavailable(let status):
            switch status {
            case .ok: return "來源狀態正常"
            case .unreachable: return "發佈端無法讀取來源"
            case .error: return "來源回報錯誤"
            case .noDataYet: return "來源尚無資料"
            }
        case .missingFromFeed: return "本次資料未包含此機器"
        case .incompleteSample: return "資料不足（缺少工作代號、序號或資料時間）"
        case .futureTimestamp: return "時間無法驗證（資料時間超前本機時鐘）"
        case .replayOrOutOfOrder: return "重複或順序錯誤的資料，已忽略"
        case .retiredSession: return "已結束工作的資料，已忽略"
        case .counterRegression: return "接受份額計數倒退"
        case .clockDiscontinuity: return "本機時鐘跳動，時間無法驗證"
        }
    }
}

public extension MinerProcessState {
    var displayText: String {
        switch self {
        case .running: return "運行中"
        case .stopped: return "已停止"
        }
    }
}

public extension StopReason {
    var displayText: String {
        switch self {
        case .userRequested: return "使用者主動停止"
        case .protectionTriggered: return "保護機制觸發"
        case .abnormalExit: return "異常退出"
        }
    }
}

public extension Freshness {
    /// `historical` is the snapshot's flag: fresh-looking values held after a failed or rejected
    /// update are still shown as unconfirmed.
    func displayText(historical: Bool) -> String {
        switch self {
        case .fresh(let age):
            return historical ? "歷史資料（未確認）・\(DisplayText.age(age))前" : "新鮮・\(DisplayText.age(age))前"
        case .stale(let age): return "歷史資料・\(DisplayText.age(age))前"
        case .noTimestamp: return "無時間"
        case .unverifiable: return "時間無法驗證"
        }
    }
}
