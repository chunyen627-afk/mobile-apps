import Foundation

/// Every user-facing sentence that depends on helper data, kept here so XCTest can pin it.
public enum DeskText {
    /// Below this many idle seconds someone is taken to be using the PC (design: 60 s).
    public static let idleThreshold = 60

    public static func failure(_ failure: HelperFailure) -> String {
        switch failure {
        case .unauthorized: return "連線密碼不正確"
        case .lockedOut: return "密碼錯誤太多次，電腦端已暫停 10 分鐘"
        case .notFound(let message): return message ?? "電腦端找不到這個項目"
        case .forbidden: return "電腦端拒絕連線（不在允許的網路）"
        case .readOnly: return "這台電腦的小幫手只能讀取（舊版或未開啟操作）"
        case .busyUser(let seconds): return seconds.map { "電腦有人在用（\($0) 秒前有操作）" } ?? "電腦有人在用"
        case .locked: return "電腦已鎖定，請先解鎖（可用 Google 遠端桌面）"
        case .promptChanged: return "電腦上的權限詢問已經不一樣了"
        case .badRequest(let message): return message ?? "送出的內容不對"
        case .queueFull: return "電腦端還有動作在排隊，請稍後再試"
        case .server(let message): return message ?? "電腦端發生錯誤"
        case .unreachable: return "無法連線（電腦關機、小幫手沒開或不在同一個私人網路）"
        case .timeout: return "電腦端沒有回應（逾時）"
        case .badResponse: return "電腦端回應的格式不對"
        case .cancelled: return "已取消"
        }
    }

    /// "閒置 7 分鐘", "有人在用電腦", "已鎖定".
    public static func presence(_ presence: HelperState.Presence) -> String {
        if presence.locked == true { return "已鎖定（需要先解鎖）" }
        guard let seconds = presence.idleSeconds else { return "閒置時間未知" }
        if seconds < idleThreshold { return "有人在用電腦" }
        if seconds < 3600 { return "閒置 \(seconds / 60) 分鐘" }
        return "閒置 \(seconds / 3600) 小時"
    }

    public static func appState(_ state: HelperState.AppState?) -> String {
        guard let state, state.available else { return "這台電腦沒有找到資料" }
        switch state.running {
        case .some(true): return "桌面版開著"
        case .some(false): return "桌面版沒開（仍可看紀錄）"
        case .none: return "無法判斷是否開著"
        }
    }

    public static func sessionStatus(_ status: String) -> String? {
        switch status {
        case "active": return "最近有更新"
        case "needs-action": return "需要處理"
        default: return nil
        }
    }

    public static func working(_ app: DeskApp, status: String) -> String? {
        status == "working" ? "\(app.displayName) 正在處理…" : nil
    }

    /// "剛剛", "5 分鐘前", "3 小時前", "2 天前"; nil for a missing or unreadable time.
    public static func relative(_ iso: String?, now: Date = Date()) -> String? {
        guard let iso, let date = parse(iso) else { return nil }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "剛剛" }
        if seconds < 3600 { return "\(seconds / 60) 分鐘前" }
        if seconds < 86400 { return "\(seconds / 3600) 小時前" }
        return "\(seconds / 86400) 天前"
    }

    public static func parse(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: iso)
    }

    /// Text split into prose and ``` fenced code blocks, for the chat bubbles.
    public static func segments(_ text: String) -> [(code: Bool, text: String)] {
        var out: [(code: Bool, text: String)] = []
        let parts = text.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            let isCode = index % 2 == 1 && index < parts.count - (parts.count % 2 == 0 ? 1 : 0)
            var body = part
            if isCode, let newline = body.firstIndex(of: "\n") {
                // Drop the language tag after the opening fence.
                let tag = body[..<newline]
                if !tag.contains(" ") { body = String(body[body.index(after: newline)...]) }
            }
            let trimmed = body.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty { out.append((isCode, trimmed)) }
        }
        return out
    }
}
