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

private struct ScanCatalog: Codable {
    var version = 2
    var listings: [String: [AlbumEntry]] = [:]
    // Legacy indexes omit empty folders. A complete legacy root proves that an
    // unrepresented descendant has no media, so it need not be scanned again.
    var legacyRoots: [String] = []
    var date = Date()
}

/// Stores metadata only. Incomplete scans never replace a previously complete index.
actor ScanIndex {
    private let directory: URL
    private let diagnostics: DiagnosticStore?

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("ScanIndex", isDirectory: true), diagnostics: DiagnosticStore? = nil) {
        self.directory = directory
        self.diagnostics = diagnostics
    }

    static func key(settings: ConnectionSettings, chosen: [AlbumEntry]) throws -> String {
        let roots = SelectionRules.roots(chosen).sorted { $0.path < $1.path }
        let fields = [try settings.serverURL().absoluteString.lowercased(), settings.share,
                      settings.username, settings.domain, String(settings.encrypted), try AlbumPath.clean(settings.folder)]
            + roots.flatMap { [$0.path, $0.kind.rawValue] }
        let data = try JSONEncoder().encode(fields)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func scopeKey(settings: ConnectionSettings) throws -> String {
        try key(settings: settings, chosen: [])
    }

    func prepare(key: String, chosen: [AlbumEntry], force: Bool = false, legacyKey: String? = nil,
                 list: @Sendable (String) async throws -> [AlbumEntry],
                 progress: @Sendable (Int, Int, String) async -> Void = { _, _, _ in }) async throws -> ScanResult {
        try Task.checkCancellation()
        diagnostics?.record(.scanIndexLoading)
        let file = directory.appendingPathComponent(key + ".catalog.json")
        var catalog = ScanCatalog()
        var needsSave = true
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode(ScanCatalog.self, from: data), stored.version == 2 {
            catalog = stored
            needsSave = false
        } else if !force, let legacyKey,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(legacyKey + ".json")),
                  let snapshot = try? JSONDecoder().decode(ScanSnapshot.self, from: data), snapshot.version == 1 {
            catalog = Self.migrate(snapshot, chosen: chosen)
        }
        diagnostics?.record(.scanIndexLoaded, values: ["cachedFolders": catalog.listings.count])
        let roots = SelectionRules.roots(chosen)
        if force {
            for root in roots where root.kind == .folder {
                catalog.listings = catalog.listings.filter { !AlbumPath.contains(root.path, $0.key) }
                catalog.legacyRoots.removeAll { AlbumPath.contains(root.path, $0) }
            }
        }
        var pending = roots
        var networkLists = 0
        var visited = Set<String>()
        var found: [String: AlbumEntry] = [:]
        var warnings: [String] = []
        var warningCount = 0
        var lastProgress = Date.distantPast
        var lastDirectoryDiagnostic = Date.distantPast
        while let entry = pending.popLast() {
            try Task.checkCancellation()
            if entry.kind == .folder {
                guard visited.insert(entry.path).inserted else { continue }
                if Date().timeIntervalSince(lastProgress) > 0.15 {
                    await progress(found.count, visited.count, entry.path)
                    lastProgress = Date()
                }
                do {
                    let children: [AlbumEntry]
                    if !force, let saved = catalog.listings[entry.path] { children = saved }
                    else if !force, catalog.legacyRoots.contains(where: { AlbumPath.contains($0, entry.path) }) {
                        children = []
                    } else {
                        networkLists += 1
                        // Sample network operations at most once every two seconds.
                        // Never record a directory path or media name.
                        let traceRead = Date().timeIntervalSince(lastDirectoryDiagnostic) >= 2
                        if traceRead {
                            lastDirectoryDiagnostic = Date()
                            diagnostics?.record(.scanDirectoryReading, values: ["folders": visited.count, "media": found.count, "networkLists": networkLists])
                        }
                        children = try await list(entry.path)
                        if traceRead {
                            diagnostics?.record(.scanDirectoryRead, values: ["children": children.count, "networkLists": networkLists])
                        }
                        catalog.listings[entry.path] = children
                    }
                    pending.append(contentsOf: children)
                }
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
        if networkLists > 0 { catalog.date = Date() }
        diagnostics?.record(.scanSorting, values: ["media": found.count, "folders": visited.count])
        let snapshot = ScanSnapshot(entries: found.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, folders: visited.count, date: catalog.date)
        var result = ScanResult(snapshot: snapshot, reused: networkLists == 0 && !force, warnings: warnings, warningCount: warningCount)
        if warningCount == 0 {
            if networkLists == 0 && !force && !needsSave {
                result.saved = true
                return result
            }
            do {
                diagnostics?.record(.scanIndexSaving, values: ["cachedFolders": catalog.listings.count])
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(catalog)
                try Task.checkCancellation()
                try data.write(to: file, options: .atomic)
                diagnostics?.record(.scanIndexSaved, values: ["bytes": data.count])
                result.saved = true
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.warningCount += 1
                result.warnings.append("清單無法儲存；本次仍可播放，下次需要重掃。")
            }
        }
        return result
    }

    private static func migrate(_ snapshot: ScanSnapshot, chosen: [AlbumEntry]) -> ScanCatalog {
        var catalog = ScanCatalog(date: snapshot.date)
        for root in SelectionRules.roots(chosen) where root.kind == .folder {
            catalog.legacyRoots.append(root.path)
            var rows: [String: [String: AlbumEntry]] = [root.path: [:]]
            for entry in snapshot.entries where AlbumPath.contains(root.path, entry.path) {
                var current = entry
                while current.path != root.path {
                    let parent = current.path.split(separator: "/").dropLast().joined(separator: "/")
                    rows[parent, default: [:]][current.path] = current
                    if parent == root.path { break }
                    current = AlbumEntry(path: parent, name: parent.split(separator: "/").last.map(String.init) ?? "", kind: .folder, size: 0)
                }
            }
            for (path, children) in rows { catalog.listings[path] = Array(children.values) }
        }
        return catalog
    }
}
