import CryptoKit
import Foundation
import MetricKit
import SwiftUI
import UIKit

enum DiagnosticAction: String {
    case launch, previousSessionEndedInForeground, foreground, background, termination, memoryWarning
    case connectStarted, connectSucceeded, connectFailed, disconnected, navigationFailed
    case selectionChanged, scanStarted, scanFinished, scanCancelled, scanFailed
    case playbackStarted, playbackStopped, photoSelected, videoSelected, playbackFailed, videoFailed, photoFailed, videoSeek
    case userMarkedProblem, mediaReadFailed, vlcStarted, vlcFailed, nativeDecoderFallback
}

private struct DiagnosticEvent: Codable {
    let date: Date
    let session: String
    let action: String
    let values: [String: Int]
}

private struct DiagnosticSession: Codable {
    var active: Bool
}

/// Serial, bounded local storage. Callers can log only named events and numbers,
/// never hostnames, credentials, filenames, media contents or error descriptions.
final class DiagnosticStore: @unchecked Sendable {
    static let shared = DiagnosticStore()
    private let queue = DispatchQueue(label: "Lightbox.diagnostics")
    private let directory: URL
    private let maximumEventBytes: Int
    private let session = UUID().uuidString
    private var started = false
    private var storageFailed = false

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true), maximumEventBytes: Int = 256 * 1024) {
        self.directory = directory
        self.maximumEventBytes = maximumEventBytes
    }

    func beginSession() {
        queue.sync {
            guard !started else { return }
            started = true
            if let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")),
               let previous = try? JSONDecoder().decode(DiagnosticSession.self, from: data), previous.active {
                append(.previousSessionEndedInForeground, values: [:])
            }
            writeState(active: false)
            append(.launch, values: [:])
        }
    }

    func setActive(_ active: Bool) {
        queue.sync {
            writeState(active: active)
            append(active ? .foreground : .background, values: [:])
        }
    }

    func record(_ action: DiagnosticAction, values: [String: Int] = [:]) {
        queue.sync { append(action, values: values) }
    }

    func recordError(_ action: DiagnosticAction, error: Error) {
        let value = error as NSError
        // Numeric classification only; arbitrary domains and userInfo can contain private paths.
        let domains = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, "AVFoundationErrorDomain"]
        record(action, values: ["code": value.code, "domainClass": domains.firstIndex(of: value.domain).map { $0 + 1 } ?? 0])
    }

    func saveSystemReport(_ data: Data) {
        queue.sync {
            guard data.count <= 2 * 1024 * 1024, (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
            do {
                try createDirectory()
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let target = directory.appendingPathComponent("system-\(digest).json")
                if !FileManager.default.fileExists(atPath: target.path) { try data.write(to: target, options: .atomic) }
                let reports = try systemReports().sorted {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a > b
                }
                for report in reports.dropFirst(5) { try FileManager.default.removeItem(at: report) }
            } catch { storageFailed = true }
        }
    }

    func summary() -> String {
        queue.sync {
            if storageFailed { return "部分紀錄無法寫入；請檢查手機可用空間。" }
            let count = (try? systemReports().count) ?? 0
            return "近期操作已保存在手機；已收到 \(count) 份 iOS 診斷／統計報告。"
        }
    }

    func export() throws -> URL {
        try queue.sync {
            var events: [Any] = []
            for number in [2, 1, 0] {
                let file = eventFile(number)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) { events.append(object) }
                }
            }
            let reports: [Any] = try systemReports().compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: $0)) }
            let document: [String: Any] = [
                "format": 1, "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "note": "previousSessionEndedInForeground is a clue, not proof of a crash; force quit, restart or power loss may also cause it. System reports are delivered by iOS when available.",
                "storageHadErrors": storageFailed, "events": events, "systemReports": reports
            ]
            let exports = directory.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            // One replaceable export avoids accumulating copies of diagnostic data.
            let file = exports.appendingPathComponent("Lightbox-diagnostics.json")
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            return file
        }
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func writeState(active: Bool) {
        do {
            try createDirectory()
            try JSONEncoder().encode(DiagnosticSession(active: active)).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        } catch { storageFailed = true }
    }

    private func eventFile(_ number: Int) -> URL { directory.appendingPathComponent("events-\(number).jsonl") }

    private func systemReports() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("system-") && $0.pathExtension == "json" }
    }

    private func append(_ action: DiagnosticAction, values: [String: Int]) {
        do {
            try createDirectory()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(DiagnosticEvent(date: Date(), session: session, action: action.rawValue, values: values))
            data.append(0x0a)
            let file = eventFile(0)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size + data.count > maximumEventBytes {
                if FileManager.default.fileExists(atPath: eventFile(2).path) { try FileManager.default.removeItem(at: eventFile(2)) }
                for number in [1, 0] where FileManager.default.fileExists(atPath: eventFile(number).path) {
                    try FileManager.default.moveItem(at: eventFile(number), to: eventFile(number + 1))
                }
            }
            if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
            else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch { storageFailed = true }
    }
}

@MainActor
final class AppDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = AppDiagnostics()
    private var started = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        started = true
        DiagnosticStore.shared.beginSession()
        MXMetricManager.shared.add(self)
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            DiagnosticStore.shared.record(.memoryWarning)
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            DiagnosticStore.shared.record(.termination)
            DiagnosticStore.shared.setActive(false)
        })
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { DiagnosticStore.shared.saveSystemReport(payload.jsonRepresentation()) }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { DiagnosticStore.shared.saveSystemReport(payload.jsonRepresentation()) }
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""
    @State private var exportURL: URL?
    @State private var exporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("自動保留在手機") {
                    Text(status)
                    Text("保留近期操作、錯誤代碼、記憶體警告，以及 iOS 提供的診斷。下次開啟也會檢查上次是否未正常結束；強制關閉或重新開機也可能留下這個線索。").font(.footnote)
                    Text("不記錄 SMB 位址、帳密、檔名或照片內容，不會自動上傳。紀錄有容量上限，較舊資料會輪替。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("遇到問題後") {
                    Button("標記剛剛發生問題") {
                        DiagnosticStore.shared.record(.userMarkedProblem)
                        status = "已記錄目前時間，匯出後可用來對照問題。"
                    }
                    Button(exporting ? "正在整理…" : "準備診斷檔") {
                        exporting = true
                        Task {
                            do {
                                exportURL = try await Task.detached(priority: .utility) { try DiagnosticStore.shared.export() }.value
                                status = "診斷檔已準備，可儲存到「檔案」或分享給協助除錯的人。"
                            } catch { status = "無法匯出，請檢查手機可用空間後再試。" }
                            exporting = false
                        }
                    }.disabled(exporting)
                    if let exportURL { ShareLink("分享診斷檔", item: exportURL) }
                    Text("iOS 不一定會提供每次閃退的完整報告。請在問題發生後重開 App 再匯出；收到更多系統報告後可再次匯出。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("診斷紀錄")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { status = DiagnosticStore.shared.summary() }
        }
    }
}
