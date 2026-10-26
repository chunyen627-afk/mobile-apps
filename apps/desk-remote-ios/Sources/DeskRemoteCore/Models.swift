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

    public let pc: PC
    public let capabilities: [String]
    public let apps: [String: AppState]
    public let presence: Presence
    public let warnings: [String]

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
