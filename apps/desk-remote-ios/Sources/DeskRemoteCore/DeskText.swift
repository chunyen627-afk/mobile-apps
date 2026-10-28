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
        case .promptChanged: return "電腦上的詢問已經不一樣了（可能已經回答過）"
        case .badRequest(let message): return message ?? "送出的內容不對"
        case .queueFull: return "電腦端還有動作在排隊，請稍後再試"
        case .badSignature: return "電腦不接受這個核准（手機上的管理員核准金鑰不是這台電腦的）"
        case .server(let message): return message ?? "電腦端發生錯誤"
        case .unreachable: return "無法連線（電腦關機、小幫手沒開或不在同一個私人網路）"
        case .timeout: return "電腦端沒有回應（逾時）"
        case .badResponse: return "電腦端回應的格式不對"
        case .cancelled: return "已取消"
        }
    }

    /// The request never reached the helper: what a stuck ZeroTier looks like from the phone.
    public static func isConnectionFailure(_ failure: HelperFailure) -> Bool {
        failure == .unreachable || failure == .timeout
    }

    /// How long ago the phone's network changed still counts as "just now" for the hint.
    public static let recentNetworkChange: TimeInterval = 600

    /// What to do when the PC cannot be reached. ZeroTier on iOS stalls after the phone changes
    /// networks (measured 10/28: no recovery in over 3 minutes; after turning it off and on, about
    /// a minute), and no app can switch another app's VPN, so the user toggles it and the app retries.
    public static func reconnectHint(networkChangedAgo: TimeInterval?, short: Bool = false) -> String {
        let recent = networkChangedAgo.map { $0 >= 0 && $0 < recentNetworkChange } ?? false
        if short {
            return recent ? "手機剛換網路：請重連 ZeroTier" : "換過網路請重連 ZeroTier"
        }
        return recent
            ? "手機剛換過網路，ZeroTier 常會卡住：請把 ZeroTier 關掉再打開，約 1 分鐘內這裡會自動連上（每 5 秒重試）。"
            : "手機換過網路的話，請把 ZeroTier 關掉再打開；這裡每 5 秒自動重試。"
    }

    /// `failure(_:)`, plus the reconnect hint when the PC could not be reached.
    public static func failure(_ failure: HelperFailure, networkChangedAgo: TimeInterval?, short: Bool = false) -> String {
        let text = self.failure(failure)
        guard isConnectionFailure(failure) else { return text }
        return text + (short ? "・" : "\n") + reconnectHint(networkChangedAgo: networkChangedAgo, short: short)
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

    /// Time left to approve, from epoch seconds.
    public static func remaining(until expires: Int, now: Date = Date()) -> String {
        let seconds = expires - Int(now.timeIntervalSince1970)
        if seconds <= 0 { return "已逾時" }
        if seconds < 60 { return "剩不到 1 分鐘" }
        return "剩約 \(seconds / 60) 分鐘"
    }

    public static func elevateState(_ result: ElevateResult) -> String {
        switch result.state {
        case "done": return "已執行・結束碼 \(result.exitCode.map(String.init) ?? "?")"
        case "denied": return "已拒絕"
        case "expired": return "逾時未核准"
        case "timeout": return "執行超過時間上限，已停止"
        default: return result.state
        }
    }

    /// "App 版本 0.5.3（build 6）" from the app's Info.plist values.
    public static func appVersion(_ info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "App 版本 \(version)（build \(build)）"
    }

    /// "9,800", "18.3 萬", "100 萬": token counts the way the phone shows them.
    public static func tokens(_ count: Int) -> String {
        if count < 10_000 { return count.formatted(.number.locale(Locale(identifier: "en_US"))) }
        let tenThousands = Double(count) / 10_000
        return String(format: tenThousands < 100 ? "%.1f 萬" : "%.0f 萬", tenThousands)
    }

    /// "上下文 18%（18.3 萬 / 100 萬）", or "上下文已用 12.3 萬 tokens" when the window is unknown.
    public static func context(_ context: ConversationMeta.Context) -> String {
        guard let window = context.window, let percent = context.percent else {
            return "上下文已用 \(tokens(context.used)) tokens"
        }
        return "上下文 \(percent)%（\(tokens(context.used)) / \(tokens(window))）"
    }

    /// The chat's subtitle: "Opus 5.5・高・上下文 18%", or the helper's note when it knows nothing
    /// yet ("匯入的舊對話，回覆一次後才有資料"); nil when the helper sent nothing.
    public static func metaLine(_ meta: ConversationMeta?) -> String? {
        guard let meta else { return nil }
        var parts = [meta.model, meta.effort].compactMap { $0 }
        if let context = meta.context {
            parts.append(context.percent.map { "上下文 \($0)%" } ?? "上下文 \(tokens(context.used))")
        } else if let note = meta.note {
            parts.append(note)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// "代我核准", or "代我核准（下一則回覆起生效）" for a Codex pick no reply has recorded yet.
    public static func permission(_ meta: ConversationMeta?) -> String? {
        guard let permission = meta?.permission else { return nil }
        return meta?.permissionPending == true ? "\(permission)（下一則回覆起生效）" : permission
    }

    /// "每週 46%・週日上午11:00 重設" or "每週 5%・11/2 18:49 重設".
    public static func usageWindow(_ window: PlanUsage.Window, timeZone: TimeZone = .current) -> String {
        var text = "\(window.label) \(window.percent)%"
        if let reset = window.resetsText {
            text += "・\(reset)"
        } else if let iso = window.resetsAt, let date = parse(iso) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_Hant_TW")
            formatter.timeZone = timeZone
            formatter.dateFormat = "M/d HH:mm"
            text += "・\(formatter.string(from: date)) 重設"
        }
        return text
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

    /// Bare http(s) addresses become links; text that already is a (Markdown) link stays as it is.
    /// Paths on the PC (C:\…) are not links: the phone cannot open them.
    public static func linkingWebAddresses(_ text: AttributedString) -> AttributedString {
        var out = text
        let plain = String(out.characters)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        for match in detector.matches(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out)
            else { continue }
            if out[lower ..< upper].runs.contains(where: { $0.link != nil }) { continue }
            out[lower ..< upper].link = url
        }
        return out
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
