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
        /// A UAC prompt is up (it also reads as locked); helper 0.5.12.
        public let uac: Bool?

        init(idleSeconds: Int?, locked: Bool?, uac: Bool? = nil) {
            self.idleSeconds = idleSeconds
            self.locked = locked
            self.uac = uac
        }
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
    /// Each app's plan limits; missing from helpers before 0.4.0, nil per app when unknown.
    public let usage: [String: PlanUsage?]?
    /// Models the phone may switch to, per app.
    public let models: [String: [String]]?
    /// Reasoning efforts and permission modes the phone may pick, per app (helper 0.5.0).
    public let efforts: [String: [String]]?
    public let modes: [String: [String]]?
    /// Apps whose running turn the phone can stop.
    public let stop: [String]?
    /// Windows that popped up on the PC and wait for an answer (helper 0.5.11).
    public let popups: [Popup]?
    /// Each app's few newest conversations, newest first (helper 0.5.12).
    public let recent: [Recent]?
    /// Codex's fast mode (the lightning switch), nil while its setting cannot be read (helper 0.5.12).
    public let fast: [String: Bool?]?
    /// Each desktop app's installed and running version (helper 0.5.12).
    public let versions: [String: AppVersion]?

    public struct AppVersion: Decodable, Equatable, Sendable {
        public let installed: String?
        /// nil while the app is not running.
        public let running: String?
        /// A newer version is installed than the one running, or (Claude) downloaded and waiting.
        public let update: Bool
        /// Claude's downloaded version behind its "重新啟動以更新" button, which the phone may press.
        public let pending: String?
    }

    /// One of the PC list's links: a conversation and the desktop app it is in.
    public struct Recent: Decodable, Equatable, Hashable, Identifiable, Sendable {
        /// Text, so an app this phone does not know yet does not spoil the whole state.
        public let appName: String
        public let session: SessionSummary

        public var app: DeskApp? { DeskApp(rawValue: appName) }
        public var id: String { "\(appName)/\(session.id)" }

        private enum Keys: String, CodingKey { case app }

        /// The helper sends the conversation's own fields with `app` beside them.
        public init(from decoder: Decoder) throws {
            appName = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .app)
            session = try SessionSummary(from: decoder)
        }
    }

    /// A window on the PC's desktop waiting for a button (a firewall question, a message box);
    /// while it is there the desktop apps cannot come to the front, so nothing can be sent.
    public struct Popup: Decodable, Equatable, Hashable, Identifiable, Sendable {
        public let id: String
        public let title: String
        /// The program that showed it, e.g. "SecurityHealthHost".
        public let process: String
        public let text: String
        public let buttons: [String]

        public var name: String { title.isEmpty ? process : title }
    }

    public var shownPopups: [Popup] { can("popups") ? popups ?? [] : [] }
    /// How many photos one message may carry: helpers before 0.5.11 take one.
    public var photoLimit: Int { can("photos") ? 10 : 1 }

    public func app(_ app: DeskApp) -> AppState? { apps[app.rawValue] }
    /// Links for the PC list; an app the phone does not know (a newer helper) is skipped.
    public var recentLinks: [Recent] { (recent ?? []).filter { $0.app != nil } }
    public func usage(_ app: DeskApp) -> PlanUsage? { usage?[app.rawValue] ?? nil }
    public func models(_ app: DeskApp) -> [String] { can("model") ? models?[app.rawValue] ?? [] : [] }
    public func efforts(_ app: DeskApp) -> [String] { can("effort") ? efforts?[app.rawValue] ?? [] : [] }
    public func modes(_ app: DeskApp) -> [String] { can("mode") ? modes?[app.rawValue] ?? [] : [] }
    public func version(_ app: DeskApp) -> AppVersion? { versions?[app.rawValue] }
    /// The app has a fast mode the phone can switch.
    public func hasFast(_ app: DeskApp) -> Bool { can("fast") && fast?.keys.contains(app.rawValue) == true }
    public func fastOn(_ app: DeskApp) -> Bool? { fast?[app.rawValue] ?? nil }
    public func canStop(_ app: DeskApp) -> Bool { can("stop") && (stop ?? []).contains(app.rawValue) }

    /// "read", "send", "permission", "new", "open".
    public func can(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// One app's plan limits as the desktop app last read them.
public struct PlanUsage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Hashable, Sendable {
        /// "5 小時", "每週", ...
        public let label: String
        public let percent: Int
        /// ISO time the window resets, when the app's files say.
        public let resetsAt: String?
        /// The desktop app's own reset wording, e.g. "週日上午11:00 重設".
        public let resetsText: String?
    }

    public let windows: [Window]
    public let sampledAt: String?
    /// A one-way mark of the signed-in account (helper 0.5.8): PCs with the same mark share one plan.
    public let account: String?
}

/// Model, effort and context use of one conversation (`meta` of an event page).
public struct ConversationMeta: Codable, Equatable, Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public let used: Int
        /// nil when the helper does not know this model's context window.
        public let window: Int?
        public let percent: Int?
    }

    public let model: String?
    public let modelId: String?
    public let effort: String?
    public let context: Context?
    /// The permission mode in the desktop app's own words ("自動", "代我核准", ...).
    public let permission: String?
    /// true while `permission` is a Codex pick from the phone that no reply has recorded yet (helper 0.5.5).
    public let permissionPending: Bool?
    /// Why nothing is known yet, e.g. a Codex thread imported from another account (helper 0.5.5).
    public let note: String?

    public init(model: String?, modelId: String? = nil, effort: String?, context: Context?, permission: String? = nil,
                permissionPending: Bool? = nil, note: String? = nil) {
        self.model = model
        self.modelId = modelId
        self.effort = effort
        self.context = context
        self.permission = permission
        self.permissionPending = permissionPending
        self.note = note
    }
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
    var model: String?
    var effort: String?
    var mode: String?
    /// A photo (JPEG, base64) pasted into the conversation before the text.
    var image: String?
    /// Several photos, pasted in this order (helper 0.5.11, capability "photos").
    var images: [String]?
    /// The button to press in a window that popped up on the PC.
    var button: String?
    /// Codex's fast mode on or off (helper 0.5.12, capability "fast").
    var fast: Bool?
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
public struct TranscriptEvent: Codable, Equatable, Identifiable, Sendable {
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
public struct PermissionPrompt: Codable, Equatable, Sendable {
    public let promptId: String
    public let tool: String?
    public let text: String
}

/// An option question Claude is waiting on (AskUserQuestion): one or more questions, each with
/// labelled options, single or multiple choice, plus free text ("其他").
public struct OptionQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let description: String?
    }

    public struct Item: Codable, Equatable, Sendable {
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
public struct ReplySuggestions: Codable, Equatable, Sendable {
    public struct Reply: Codable, Equatable, Hashable, Sendable {
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
    /// Missing from helpers before 0.4.0.
    public let meta: ConversationMeta?

    public init(epoch: String, reset: Bool, events: [TranscriptEvent], earlier: Bool, cursor: Int, status: String,
                prompt: PermissionPrompt?, question: OptionQuestion? = nil, suggestions: ReplySuggestions? = nil,
                meta: ConversationMeta? = nil) {
        self.epoch = epoch
        self.reset = reset
        self.events = events
        self.earlier = earlier
        self.cursor = cursor
        self.status = status
        self.prompt = prompt
        self.question = question
        self.suggestions = suggestions
        self.meta = meta
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

    /// The finished requests still to show: the PC keeps its last 10, the phone hides the ones
    /// the user removed (asked 10/28: they piled up).
    public func recent(hiding hidden: Set<String>) -> [ElevateResult] {
        recent.filter { !hidden.contains($0.id) }
    }

    /// What to remember as hidden after removing `ids`: only ids the PC still lists, so the
    /// remembered set stays as small as the PC's own list.
    public func hidden(_ hidden: Set<String>, removing ids: [String]) -> Set<String> {
        Set(recent.map(\.id)).intersection(hidden.union(ids))
    }
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
