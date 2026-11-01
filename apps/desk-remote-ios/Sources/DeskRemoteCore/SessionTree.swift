import Foundation

/// The conversation list laid out like the desktop's sidebar (asked 11/1): a section per day,
/// newest first, and a conversation started from another one nested under it.
public struct SessionTree: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let session: SessionSummary
        /// 0 for a top-level conversation, 1 for one started from it, and so on.
        public let depth: Int
        /// Whether this is the last child under its parent (the tree line stops here).
        public let last: Bool
        public var id: String { session.id }
    }

    public struct Section: Equatable, Identifiable, Sendable {
        /// "YYYY-MM-DD" of the newest activity in the section, "" when unknown.
        public let day: String
        public let rows: [Row]
        public var id: String { day }
    }

    public let sections: [Section]

    /// Builds the tree. A conversation whose parent is not in the list is a top-level one. A
    /// top-level conversation sits in the day of its newest activity, its own or any
    /// descendant's; children keep the list's order (newest first).
    public static func build(_ sessions: [SessionSummary], timeZone: TimeZone = .current) -> SessionTree {
        let ids = Set(sessions.map(\.id))
        var children: [String: [SessionSummary]] = [:]
        var roots: [SessionSummary] = []
        for session in sessions {
            if let parent = session.parent, parent != session.id, ids.contains(parent) {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        func newest(_ session: SessionSummary, _ seen: inout Set<String>) -> String {
            guard seen.insert(session.id).inserted else { return session.updatedAt ?? "" }
            var best = session.updatedAt ?? ""
            for child in children[session.id] ?? [] {
                let time = newest(child, &seen)
                if time > best { best = time }
            }
            return best
        }
        func rows(_ session: SessionSummary, depth: Int, last: Bool, _ seen: inout Set<String>) -> [Row] {
            guard seen.insert(session.id).inserted else { return [] }  // a loop in the data
            var out = [Row(session: session, depth: depth, last: last)]
            let kids = children[session.id] ?? []
            for (index, child) in kids.enumerated() {
                out += rows(child, depth: depth + 1, last: index == kids.count - 1, &seen)
            }
            return out
        }
        var order: [(day: String, time: String, root: SessionSummary)] = []
        for root in roots {
            var seen = Set<String>()
            let time = newest(root, &seen)
            order.append((localDay(time, timeZone: timeZone), time, root))
        }
        order.sort { $0.time > $1.time }
        var sections: [Section] = []
        var seen = Set<String>()
        for item in order {
            let built = rows(item.root, depth: 0, last: true, &seen)
            if let index = sections.firstIndex(where: { $0.day == item.day }) {
                sections[index] = Section(day: item.day, rows: sections[index].rows + built)
            } else {
                sections.append(Section(day: item.day, rows: built))
            }
        }
        return SessionTree(sections: sections)
    }

    /// The local day ("YYYY-MM-DD") of an ISO time, "" when it cannot be read.
    public static func localDay(_ iso: String, timeZone: TimeZone = .current) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: iso)
        }
        guard let date else { return "" }
        return dayKey(date, timeZone: timeZone)
    }

    public static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// "今天", "昨天", or "M月D日" for a section's day, against `today` (both "YYYY-MM-DD").
    public static func dayLabel(_ day: String, today: String) -> String {
        guard day.count == 10 else { return "更早" }
        if day == today { return "今天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: day), let now = formatter.date(from: today) else { return day }
        if Int(now.timeIntervalSince(date).rounded() / 86400) == 1 { return "昨天" }
        let parts = day.split(separator: "-")
        return parts.count == 3 ? "\(Int(parts[1]) ?? 0)月\(Int(parts[2]) ?? 0)日" : day
    }
}
