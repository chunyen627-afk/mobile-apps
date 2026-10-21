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
    @Published var scanNote = ""
    @Published var warnings: [String] = []
    @Published var warningCount = 0
    @Published var playlist: [AlbumEntry] = []
    @Published var showPlayer = false
    private var navigationID = UUID()
    private var scanTask: Task<Void, Never>?
    private var scanID = UUID()
    private let scanIndex = ScanIndex()
    private var root = ""

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorFixtures.active {
            settings = ConnectionSettings(server: "ui-test.invalid", share: "Fixtures")
            service = try? SMBService(settings: settings, password: "")
            entries = SimulatorFixtures.roots
            selections = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
            UserDefaults.standard.set(false, forKey: "randomPlayback")
            UserDefaults.standard.set(2.0, forKey: "photoInterval")
            UserDefaults.standard.set(false, forKey: "cropVideoToFill")
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: "connection"),
           let saved = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            settings = saved
            password = PasswordStore.read(for: saved.identity)
        }
    }

    func connect() async {
        DiagnosticStore.shared.record(.connectStarted)
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
            DiagnosticStore.shared.record(.connectSucceeded, values: ["rows": rows.count])
            if let saved = UserDefaults.standard.data(forKey: "selection." + settings.identity),
               let decoded = try? JSONDecoder().decode([AlbumEntry].self, from: saved) {
                selections = Dictionary(decoded.filter { AlbumPath.contains(root, $0.path) }.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            } else { selections = [:] }
            favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites." + settings.identity) ?? [])
        } catch {
            DiagnosticStore.shared.recordError(.connectFailed, error: error)
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
        } catch {
            DiagnosticStore.shared.recordError(.navigationFailed, error: error)
            if navigationID == ticket { self.error = error.localizedDescription }
        }
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
        DiagnosticStore.shared.record(.selectionChanged, values: ["selected": selections.count])
        if let data = try? JSONEncoder().encode(Array(selections.values)) {
            UserDefaults.standard.set(data, forKey: "selection." + settings.identity)
        }
    }

    func toggleFavorite(_ path: String) {
        if !favorites.insert(path).inserted { favorites.remove(path) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites." + settings.identity)
    }

    func disconnect() {
        DiagnosticStore.shared.record(.disconnected)
        cancelScan()
        navigationID = UUID()
        service = nil
        entries = []
        playlist = []
        busy = false
    }

    func cancelScan() {
        if scanTask != nil && !scanFinished { DiagnosticStore.shared.record(.scanCancelled) }
        scanID = UUID(); scanTask?.cancel(); scanTask = nil; showScan = false
    }

    func scan(filter: PlaybackFilter, random: Bool, favoritesOnly: Bool, force: Bool = false) {
        guard let service, !selections.isEmpty else { return }
        DiagnosticStore.shared.record(.scanStarted, values: ["selected": selections.count, "force": force ? 1 : 0])
        scanTask?.cancel()
        let ticket = UUID()
        scanID = ticket
        showScan = true
        scanFinished = false
        scanCount = 0
        scanFolders = 0
        scanPath = ""
        scanNote = force ? "正在重新掃描…" : "正在整理已儲存清單；只補掃尚未掃過的資料夾。"
        warnings = []
        warningCount = 0
        playlist = []
        let chosen = SelectionRules.roots(Array(selections.values))
        let favoritePaths = favorites
        scanTask = Task {
            do {
                let key = try ScanIndex.scopeKey(settings: settings)
                let legacyKey = try ScanIndex.key(settings: settings, chosen: chosen)
                let result = try await scanIndex.prepare(key: key, chosen: chosen, force: force, legacyKey: legacyKey, list: { path in
                    #if DEBUG && targetEnvironment(simulator)
                    if SimulatorFixtures.active { return try await SimulatorFixtures.list(path) }
                    #endif
                    return try await service.list(path)
                }, progress: { count, folders, path in
                    await MainActor.run {
                        guard self.scanID == ticket else { return }
                        self.scanCount = count; self.scanFolders = folders; self.scanPath = path
                        self.scanNote = "正在整理清單；已掃過的資料夾直接重用，未掃過的才補掃。"
                    }
                })
                try Task.checkCancellation()
                guard scanID == ticket else { return }
                let ordered = result.snapshot.entries.filter { filter.accepts($0) && (!favoritesOnly || favoritePaths.contains($0.path)) }
                playlist = random ? ordered.shuffled() : ordered
                scanCount = result.snapshot.entries.count
                scanFolders = result.snapshot.folders
                warnings = result.warnings
                warningCount = result.warningCount
                scanNote = result.saved
                    ? "\(result.reused ? "使用已儲存清單" : "清單已儲存") · \(result.snapshot.date.formatted(date: .abbreviated, time: .shortened))\n電腦新增、移動或刪除檔案後，請按「重新掃描」。"
                    : "掃描未完整完成或無法儲存；本次仍可播放已找到項目，原有完整清單保留。"
                scanFinished = true
                DiagnosticStore.shared.record(.scanFinished, values: ["media": scanCount, "folders": scanFolders, "reused": result.reused ? 1 : 0, "warnings": warningCount])
            } catch is CancellationError { }
            catch {
                DiagnosticStore.shared.recordError(.scanFailed, error: error)
                if scanID == ticket { self.error = error.localizedDescription; showScan = false }
            }
        }
    }

    func beginPlayback() { showScan = false; showPlayer = !playlist.isEmpty }
}
