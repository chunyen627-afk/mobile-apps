import Foundation

/// The newest plan limits seen for each account on any PC. Each PC only knows the limits its own
/// desktop app last read (a Codex reply, Claude's usage button), so two PCs signed in to one plan
/// disagreed (live 10/28: Codex 0% on one, 14% from hours before on the other). Shown limits are
/// the newer of the PC's own and the newest any PC with the same account reported.
public struct UsageBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let usage: PlanUsage
        /// The PC that reported it.
        public let pc: String
    }

    /// What to show: the limits, and the other PC's name when they came from there.
    public struct Shown: Equatable, Sendable {
        public let usage: PlanUsage
        public let from: String?
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    private static func key(_ app: DeskApp, _ account: String) -> String { "\(app.rawValue)|\(account)" }

    private static func time(_ usage: PlanUsage) -> Date? { usage.sampledAt.flatMap(DeskText.parse) }

    /// Keeps each app's limits from `state` that are newer than what is known for their account.
    /// True when something changed.
    @discardableResult
    public mutating func record(_ state: HelperState, pc: String) -> Bool {
        var changed = false
        for app in DeskApp.allCases {
            guard let usage = state.usage(app), let account = usage.account, let at = Self.time(usage) else { continue }
            let key = Self.key(app, account)
            if let known = entries[key], let knownAt = Self.time(known.usage), knownAt >= at { continue }
            entries[key] = Entry(usage: usage, pc: pc)
            changed = true
        }
        return changed
    }

    /// The PC's own limits, unless a PC with the same account reported newer ones.
    public func shown(_ app: DeskApp, own: PlanUsage?, pc: String) -> Shown? {
        guard let own else { return nil }
        guard let account = own.account, let best = entries[Self.key(app, account)], best.pc != pc,
              let bestAt = Self.time(best.usage) else { return Shown(usage: own, from: nil) }
        if let ownAt = Self.time(own), ownAt >= bestAt { return Shown(usage: own, from: nil) }
        return Shown(usage: best.usage, from: best.pc)
    }
}
