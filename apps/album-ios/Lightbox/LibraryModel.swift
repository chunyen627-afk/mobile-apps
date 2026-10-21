import Foundation
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var settings = ConnectionSettings()
    @Published var password = ""
    @Published var service: SMBService?
    @Published var entries: [AlbumEntry] = []
    @Published var currentPath = ""
    @Published var selections: [String: AlbumEntry] = [:]
    @Published var favorites = Set<String>()
    @Published var busy = false
    @Published var error: String?
    @Published var showScan = false
    @Published var scanFinished = false
    @Published var scanCount = 0
    @Published var scanFolders = 0
    @Published var scanPath = ""
    @Published var warnings: [String] = []
    @Published var warningCount = 0
    @Published var playlist: [AlbumEntry] = []
    @Published var showPlayer = false
    private var navigationID = UUID()
    private var scanTask: Task<Void, Never>?
    private var root = ""

    init() {
        if let data = UserDefaults.standard.data(forKey: "connection"),
           let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            settings = saved
            password = PasswordStore.read(for: saved.identity)
        }
    }

    func connect() async {
        busy = true
        defer { busy = false }
        do {
            settings.server = settings.server.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.share = settings.share.trimmingCharacters(in: .whitespacesAndNewlines)
            let connected = try SMBService(settings: settings, password: password)
            let newRoot = try AlbumPath.clean(settings.folder)
            try await connected.connect()
            let rows = try await connected.list(newRoot)
            try PasswordStore.save(password, for: settings.identity)
            UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "connection")
            root = newRoot
            currentPath = root
            entries = rows
            service = connected
            if let saved = UserDefaults.standard.data(forKey: "selection." + settings.identity),
               let decoded = try? JSONDecoder().decode([AlbumEntry].self, from: saved) {
                selections = Dictionary(decoded.filter { AlbumPath.contains(root, $0.path) }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            } else { selections = [:] }
            favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites." + settings.identity) ?? [])
        } catch {
            self.error = "連線失敗：\(error.localizedDescription)\n請確認手機網路、主機／分享名稱及帳號密碼。電腦的 Z: 連線不會自動授權給手機。"
        }
    }

    func navigate(_ path: String) async {
        guard let service, AlbumPath.contains(root, path) else { return }
        let ticket = UUID()
        navigationID = ticket
        busy = true
        defer { if navigationID == ticket { busy = false } }
        do {
            let rows = try await service.list(path)
            guard navigationID == ticket else { return }
            currentPath = path
            entries = rows
        } catch { if navigationID == ticket { self.error = error.localizedDescription } }
    }

    var canGoUp: Bool { currentPath != root }
    var parentPath: String { currentPath.split(separator: "/").dropLast().joined(separator: "/") }
    var currentFolder: AlbumEntry {
        AlbumEntry(path: currentPath, name: currentPath.split(separator: "/").last.map(String.init) ?? settings.share, kind: .folder, size: 0)
    }

    func isIncluded(_ entry: AlbumEntry) -> Bool {
        selections[entry.path] != nil || selections.values.contains { $0.kind == .folder && AlbumPath.contains($0.path, entry.path) }
    }

    func toggle(_ entry: AlbumEntry) {
        if selections.removeValue(forKey: entry.path) == nil {
            if isIncluded(entry) { error = "這個項目已由上層資料夾包含。請先取消勾選上層資料夾，再挑選個別項目。"; return }
            guard selections.count < 1000 else { error = "最多勾選 1000 個項目；可改勾選上層資料夾。"; return }
            selections[entry.path] = entry
        }
        persistSelection()
    }

    func removeSelection(_ path: String) { selections.removeValue(forKey: path); persistSelection() }
    func clearSelection() { selections = [:]; persistSelection() }
    private func persistSelection() {
        if let data = try? JSONEncoder().encode(Array(selections.values)) {
            UserDefaults.standard.set(data, forKey: "selection." + settings.identity)
        }
    }

    func toggleFavorite(_ path: String) {
        if !favorites.insert(path).inserted { favorites.remove(path) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites." + settings.identity)
    }

    func disconnect() {
        cancelScan()
        navigationID = UUID()
        service = nil
        entries = []
        playlist = []
        busy = false
    }

    func cancelScan() { scanTask?.cancel(); scanTask = nil; showScan = false }

    func scan(filter: PlaybackFilter, random: Bool, favoritesOnly: Bool) {
        guard let service, !selections.isEmpty else { return }
        scanTask?.cancel()
        showScan = true
        scanFinished = false
        scanCount = 0
        scanFolders = 0
        warnings = []
        warningCount = 0
        playlist = []
        let chosen = SelectionRules.roots(Array(selections.values))
        let favoritePaths = favorites
        scanTask = Task {
            var pending = chosen
            var visited = Set<String>()
            var found: [String: AlbumEntry] = [:]
            do {
                while let entry = pending.popLast() {
                    try Task.checkCancellation()
                    if entry.kind == .folder {
                        guard visited.insert(entry.path).inserted else { continue }
                        scanFolders += 1
                        scanPath = entry.path
                        do { pending.append(contentsOf: try await service.list(entry.path)) }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            warningCount += 1
                            if warnings.count < 20 { warnings.append("\(entry.path)：\(error.localizedDescription)") }
                        }
                    } else if filter.accepts(entry), !favoritesOnly || favoritePaths.contains(entry.path) {
                        found[entry.path] = entry
                        scanCount = found.count
                        if found.count >= 100000 {
                            warningCount += 1
                            warnings.append("已達第一版 100,000 個媒體項目的上限；其餘尚未掃描，請縮小勾選範圍。")
                            break
                        }
                    }
                }
                try Task.checkCancellation()
                let ordered = found.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                playlist = random ? ordered.shuffled() : ordered
                scanFinished = true
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; showScan = false }
        }
    }

    func beginPlayback() { showScan = false; showPlayer = !playlist.isEmpty }
}
