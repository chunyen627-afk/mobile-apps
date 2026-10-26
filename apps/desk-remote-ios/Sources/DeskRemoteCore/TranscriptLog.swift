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

/// The events of one conversation as the app has received them, merged page by page.
public struct TranscriptLog: Equatable, Sendable {
    public private(set) var events: [TranscriptEvent] = []
    public private(set) var epoch = ""
    public private(set) var cursor = 0
    /// Older events exist on the PC but were not sent.
    public private(set) var earlier = false
    public private(set) var status = "idle"
    public private(set) var prompt: PermissionPrompt?
    public private(set) var loaded = false
    static let maxEvents = 1000

    public init() {}

    /// Merges one page: a reset replaces everything (new conversation file, helper restart);
    /// otherwise only events newer than what is held are appended. Returns whether anything
    /// visible changed.
    @discardableResult
    public mutating func apply(_ page: EventPage) -> Bool {
        let before = (events.last?.seq, events.count, prompt, status, earlier, loaded)
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
        loaded = true
        let after = (events.last?.seq, events.count, prompt, status, earlier, loaded)
        return before != after
    }

    /// Events grouped for display: each tool result sits under the first earlier call of the
    /// same tool that has no result yet (calls can run in parallel).
    public var rows: [TranscriptRow] {
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
