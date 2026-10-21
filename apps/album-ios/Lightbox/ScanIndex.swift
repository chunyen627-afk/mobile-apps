import CryptoKit
import Foundation

struct ScanSnapshot: Codable, Sendable {
    var version = 1
    var entries: [AlbumEntry]
    var folders: Int
    var date = Date()
}

struct ScanResult: Sendable {
    var snapshot: ScanSnapshot
    var reused = false
    var warnings: [String] = []
    var warningCount = 0
    var saved = false
}

/// Stores metadata only. Incomplete scans never replace a previously complete index.
actor ScanIndex {
    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("ScanIndex", isDirectory: true)) {
        self.directory = directory
    }

    static func key(settings: ConnectionSettings, chosen: [AlbumEntry]) throws -> String {
        let roots = SelectionRules.roots(chosen).sorted { $0.path < $1.path }
        let fields = [try settings.serverURL().absoluteString.lowercased(), settings.share,
                      settings.username, settings.domain, String(settings.encrypted), try AlbumPath.clean(settings.folder)]
            + roots.flatMap { [$0.path, $0.kind.rawValue] }
        let data = try JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func prepare(key: String, chosen: [AlbumEntry], force: Bool = false,
                 list: @Sendable (String) async throws -> [AlbumEntry],
                 progress: @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> ScanResult {
        try Task.checkCancellation()
        let file = directory.appendingPathComponent(key + ".json")
        if !force, let data = try? Data(contentsOf: file),
           let snapshot = try? JSONDecoder().decode(ScanSnapshot.self, from: data), snapshot.version == 1 {
            try Task.checkCancellation()
            return ScanResult(snapshot: snapshot, reused: true, saved: true)
        }
        var pending = SelectionRules.roots(chosen)
        var visited = Set<String>()
        var found: [String: AlbumEntry] = [:]
        var warnings: [String] = []
        var warningCount = 0
        var lastProgress = Date.distantPast
        while let entry = pending.popLast() {
            try Task.checkCancellation()
            if entry.kind == .folder {
                guard visited.insert(entry.path).inserted else { continue }
                if Date().timeIntervalSince(lastProgress) > 0.15 {
                    await progress(found.count, visited.count, entry.path)
                    lastProgress = Date()
                }
                do { pending.append(contentsOf: try await list(entry.path)) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    warningCount += 1
                    if warnings.count < 20 { warnings.append("\(entry.path)：\(error.localizedDescription)") }
                }
            } else {
                found[entry.path] = entry
                if found.count >= 100000 {
                    warningCount += 1
                    if warnings.count < 20 { warnings.append("已達 100,000 個媒體上限；請縮小勾選範圍。這次結果不會儲存。") }
                    break
                }
            }
        }
        try Task.checkCancellation()
        let snapshot = ScanSnapshot(entries: found.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, folders: visited.count)
        var result = ScanResult(snapshot: snapshot, warnings: warnings, warningCount: warningCount)
        if warningCount == 0 {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try Task.checkCancellation()
                try data.write(to: file, options: .atomic)
                result.saved = true
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.warningCount += 1
                result.warnings.append("清單無法儲存；本次仍可播放，下次需要重掃。")
            }
        }
        return result
    }
}
