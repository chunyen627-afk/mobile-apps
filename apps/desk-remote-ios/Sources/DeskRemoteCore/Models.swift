import Foundation

/// The two desktop apps the helper can read.
public enum DeskApp: String, CaseIterable, Codable, Hashable, Sendable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// `GET /v1/state`.
public struct HelperState: Decodable, Equatable, Sendable {
    public struct PC: Decodable, Equatable, Sendable {
        public let name: String
        public let helperVersion: String
    }

    public struct AppState: Decodable, Equatable, Sendable {
        /// nil when the helper could not tell.
        public let running: Bool?
        /// The app's files were found on the PC.
        public let available: Bool
    }

    public struct Presence: Decodable, Equatable, Sendable {
        public let idleSeconds: Int?
        public let locked: Bool?
    }

    public struct ElevateSummary: Decodable, Equatable, Sendable {
        /// The elevated companion answered.
        public let available: Bool
        public let pending: Int
    }

    public let pc: PC
    public let capabilities: [String]
    public let apps: [String: AppState]
    public let presence: Presence
    public let warnings: [String]
    /// nil when the PC has no elevated companion installed.
    public let elevate: ElevateSummary?

    public func app(_ app: DeskApp) -> AppState? { apps[app.rawValue] }

    /// "read", "send", "permission", "new", "open".
    public func can(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// `POST` answers and `GET /v1/actions/{id}`: one action the helper runs on the PC's windows.
public struct ActionStatus: Decodable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let app: String
    public let sessionId: String?
    /// "queued", "running", "done" or "failed".
    public let state: String
    public let message: String
    public let error: String?
    /// The sent text (or the new conversation) showed up in the transcript.
    public let verified: Bool?
    public let title: String?

    public var finished: Bool { state == "done" || state == "failed" }
}

struct ActionRequest: Encodable {
    var text: String?
    var clientMsgId: String?
    var promptId: String?
    var decision: String?
    var questionId: String?
    var answers: [QuestionAnswer]?
    var project: String?
    var force: Bool?
}

/// One conversation in `GET /v1/{app}/sessions`.
public struct SessionSummary: Decodable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let folder: String?
    public let updatedAt: String?
    /// "active", "needs-action" or "idle".
    public let status: String
    public let permission: String?
    public let hasTranscript: Bool

    /// A conversation the phone just started, before the next list refresh describes it.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
        folder = nil
        updatedAt = nil
        status = "active"
        permission = nil
        hasTranscript = true
    }
}

public struct SessionList: Decodable, Equatable, Sendable {
    public let app: String
    public let sessions: [SessionSummary]
    public let warning: String?
}

/// One transcript event. `kind` is user, assistant, tool_call, tool_result or status.
public struct TranscriptEvent: Decodable, Equatable, Identifiable, Sendable {
    public let seq: Int
    public let ts: String?
    public let kind: String
    public let text: String
    public let tool: String?
    public let isError: Bool?
    public let truncated: Bool?
    public let itemId: String?

    public var id: Int { seq }

    public init(seq: Int, kind: String, text: String, tool: String? = nil, ts: String? = nil,
                isError: Bool? = nil, truncated: Bool? = nil, itemId: String? = nil) {
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.text = text
        self.tool = tool
        self.isError = isError
        self.truncated = truncated
        self.itemId = itemId
    }
}

/// A permission question the desktop app is showing now.
public struct PermissionPrompt: Decodable, Equatable, Sendable {
    public let promptId: String
    public let tool: String?
    public let text: String
}

/// An option question Claude is waiting on (AskUserQuestion): one or more questions, each with
/// labelled options, single or multiple choice, plus free text ("其他").
public struct OptionQuestion: Decodable, Equatable, Sendable {
    public struct Option: Decodable, Equatable, Sendable {
        public let label: String
        public let description: String?
    }

    public struct Item: Decodable, Equatable, Sendable {
        public let question: String
        public let header: String?
        public let multiSelect: Bool
        public let options: [Option]
    }

    public let questionId: String
    public let questions: [Item]
}

/// The answer to one question: chosen option labels and/or free text.
public struct QuestionAnswer: Codable, Equatable, Sendable {
    public var labels: [String]
    public var other: String?

    public init(labels: [String] = [], other: String? = nil) {
        self.labels = labels
        self.other = other
    }

    public var isEmpty: Bool { labels.isEmpty && (other ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Reply buttons from the desktop app's next-step box; each just sends its message.
public struct ReplySuggestions: Decodable, Equatable, Sendable {
    public struct Reply: Decodable, Equatable, Hashable, Sendable {
        public let label: String
        public let message: String
    }

    public let ask: String?
    public let replies: [Reply]
}

/// `GET /v1/{app}/sessions/{id}/events`.
public struct EventPage: Decodable, Equatable, Sendable {
    public let epoch: String
    public let reset: Bool
    public let events: [TranscriptEvent]
    public let earlier: Bool
    public let cursor: Int
    /// "working" or "idle", as far as the transcript shows.
    public let status: String
    public let prompt: PermissionPrompt?
    public let question: OptionQuestion?
    public let suggestions: ReplySuggestions?

    public init(epoch: String, reset: Bool, events: [TranscriptEvent], earlier: Bool, cursor: Int, status: String,
                prompt: PermissionPrompt?, question: OptionQuestion? = nil, suggestions: ReplySuggestions? = nil) {
        self.epoch = epoch
        self.reset = reset
        self.events = events
        self.earlier = earlier
        self.cursor = cursor
        self.status = status
        self.prompt = prompt
        self.question = question
        self.suggestions = suggestions
    }
}

/// A command waiting for administrator approval (`GET /v1/elevate`).
public struct ElevateRequest: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    /// "command" or "script".
    public let kind: String
    public let name: String
    /// Exactly what will run; the approval signature covers its SHA-256.
    public let content: String
    public let cwd: String
    public let created: Int
    public let expires: Int
}

/// A request that was approved and ran, denied, or ran out of time.
public struct ElevateResult: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let name: String
    /// "done", "denied", "expired" or "timeout".
    public let state: String
    public let exitCode: Int?
    public let finished: Int?
    public let content: String
    public let output: String
}

public struct ElevateList: Decodable, Equatable, Sendable {
    public let available: Bool
    public let pending: [ElevateRequest]
    public let recent: [ElevateResult]
}

struct ElevateDecision: Encodable {
    let decision: String
    let hmac: String?
}

struct DecisionAnswer: Decodable, Sendable {
    let state: String?
}

struct ItemText: Decodable, Sendable {
    let text: String
}

/// The helper's error body: `{ok:false, error, message}`.
struct HelperErrorBody: Decodable, Sendable {
    let error: String
    let message: String?
    let idleSeconds: Int?
}
