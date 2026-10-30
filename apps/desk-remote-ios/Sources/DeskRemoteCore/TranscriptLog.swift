import Foundation

/// One row of the chat screen: a message, a tool call with its result folded under it, or a
/// short status line such as "完成".
public enum TranscriptRow: Identifiable, Equatable, Sendable {
    case message(TranscriptEvent)
    case tool(call: TranscriptEvent?, result: TranscriptEvent?)
    case status(TranscriptEvent)

    public var id: String {
        switch self {
        case .message(let event): return "m\(event.seq)"
        case .tool(let call, let result): return "t\(call?.seq ?? result?.seq ?? 0)"
        case .status(let event): return "s\(event.seq)"
        }
    }
}

/// The events of one conversation as the app has received them, merged page by page. Kept on
/// the phone between visits (DeskLogCache), so opening it again only asks for what is new.
public struct TranscriptLog: Equatable, Sendable, Codable {
    public private(set) var events: [TranscriptEvent] = []
    public private(set) var epoch = ""
    public private(set) var cursor = 0
    /// Older events exist on the PC but were not sent.
    public private(set) var earlier = false
    public private(set) var status = "idle"
    public private(set) var prompt: PermissionPrompt?
    public private(set) var question: OptionQuestion?
    public private(set) var suggestions: ReplySuggestions?
    /// Model, effort and context use; kept when a page (from an older helper) has none.
    public private(set) var meta: ConversationMeta?
    public private(set) var loaded = false
    /// The events grouped for display, worked out once per change rather than on every redraw.
    public private(set) var rows: [TranscriptRow] = []
    static let maxEvents = 1000

    enum CodingKeys: String, CodingKey {
        case events, epoch, cursor, earlier, status, prompt, question, suggestions, meta
    }

    public init() {}

    /// A log saved on an earlier visit: shown at once, then brought up to date from its cursor.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decode([TranscriptEvent].self, forKey: .events)
        epoch = try c.decode(String.self, forKey: .epoch)
        cursor = try c.decode(Int.self, forKey: .cursor)
        earlier = try c.decode(Bool.self, forKey: .earlier)
        status = try c.decode(String.self, forKey: .status)
        prompt = try c.decodeIfPresent(PermissionPrompt.self, forKey: .prompt)
        question = try c.decodeIfPresent(OptionQuestion.self, forKey: .question)
        suggestions = try c.decodeIfPresent(ReplySuggestions.self, forKey: .suggestions)
        meta = try c.decodeIfPresent(ConversationMeta.self, forKey: .meta)
        rows = Self.group(events)
        loaded = true
    }

    /// Merges one page: a reset replaces everything (new conversation file, helper restart);
    /// otherwise only events newer than what is held are appended. Returns whether anything
    /// visible changed.
    @discardableResult
    public mutating func apply(_ page: EventPage) -> Bool {
        let waitingBefore = (question, suggestions, meta)
        let before = (events.last?.seq, events.count, prompt, status, earlier, loaded)
        let regroup = page.reset || page.epoch != epoch || rows.isEmpty
        if page.reset || page.epoch != epoch {
            events = page.events
            earlier = page.earlier
        } else {
            let newest = events.last?.seq ?? 0
            events.append(contentsOf: page.events.filter { $0.seq > newest })
        }
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
            earlier = true
        }
        epoch = page.epoch
        cursor = max(page.cursor, events.last?.seq ?? 0)
        status = page.status
        prompt = page.prompt
        question = page.question
        suggestions = page.suggestions
        if let pageMeta = page.meta { meta = pageMeta }
        loaded = true
        if regroup || (events.last?.seq, events.count) != (before.0, before.1) {
            rows = Self.group(events)
        }
        let after = (events.last?.seq, events.count, prompt, status, earlier, loaded)
        return before != after || waitingBefore != (question, suggestions, meta)
    }

    /// Whether a user message starting like `text` arrived after event `seq`: a message sent
    /// from the phone is shown as pending until the transcript itself has it.
    public func hasUserText(_ text: String, after seq: Int) -> Bool {
        let want = String(Self.normalized(text).prefix(40))
        // Codex records a photo and its caption as one message: "[圖片]\n<caption>".
        return events.contains {
            let seen = Self.normalized($0.text)
            return $0.seq > seq && $0.kind == "user" && (seen.hasPrefix(want) || (seen.hasPrefix("[圖片]") && seen.contains(want)))
        }
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Events grouped for display: each tool result sits under the first earlier call of the
    /// same tool that has no result yet (calls can run in parallel).
    static func group(_ events: [TranscriptEvent]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var pending: [Int] = []
        for event in events {
            switch event.kind {
            case "tool_call":
                pending.append(rows.count)
                rows.append(.tool(call: event, result: nil))
            case "tool_result":
                let match = pending.firstIndex { index in
                    guard case .tool(let call, _) = rows[index] else { return false }
                    return (event.tool ?? "").isEmpty || call?.tool == event.tool
                }
                if let match {
                    let index = pending.remove(at: match)
                    if case .tool(let call, _) = rows[index] { rows[index] = .tool(call: call, result: event) }
                } else {
                    rows.append(.tool(call: nil, result: event))
                }
            case "status":
                rows.append(.status(event))
            default:
                rows.append(.message(event))
            }
        }
        return rows
    }
}
