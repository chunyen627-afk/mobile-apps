import Foundation
import DeskRemoteCore

/// Conversations as last seen, kept on the phone (asked 10/30): opening one again shows it at
/// once and asks the PC only for what came after. Held in memory while the app runs and saved in
/// the app's Caches folder (never backed up; the system may clear it), the newest 40 only.
@MainActor
final class DeskLogCache {
    static let shared = DeskLogCache()
    nonisolated static let keep = 40

    private var memory: [String: TranscriptLog] = [:]
    private let folder: URL

    init(folder: URL? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? caches.appendingPathComponent("conversations", isDirectory: true)
    }

    func log(pc: UUID, app: DeskApp, session: String) -> TranscriptLog? {
        let key = Self.key(pc: pc, app: app, session: session)
        if let log = memory[key] { return log }
        guard let data = try? Data(contentsOf: file(key)),
              let log = try? JSONDecoder().decode(TranscriptLog.self, from: data) else { return nil }
        memory[key] = log
        return log
    }

    /// Remembers `log` (cheap: memory only).
    func note(_ log: TranscriptLog, pc: UUID, app: DeskApp, session: String) {
        guard log.loaded else { return }
        memory[Self.key(pc: pc, app: app, session: session)] = log
    }

    /// Writes the remembered log to disk, off the main thread, and drops the oldest files.
    func save(pc: UUID, app: DeskApp, session: String) {
        let key = Self.key(pc: pc, app: app, session: session)
        guard let log = memory[key] else { return }
        let target = file(key)
        let folder = folder
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(log) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            Self.prune(folder)
        }
    }

    /// A PC removed from the app takes its conversations with it.
    func forget(pc: UUID) {
        let prefix = pc.uuidString + "_"
        memory = memory.filter { !$0.key.hasPrefix(prefix) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }

    static func key(pc: UUID, app: DeskApp, session: String) -> String {
        let safe = String(session.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
        return "\(pc.uuidString)_\(app.rawValue)_\(safe)"
    }

    nonisolated private static func prune(_ folder: URL) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? manager.removeItem(at: url)
        }
    }
}
