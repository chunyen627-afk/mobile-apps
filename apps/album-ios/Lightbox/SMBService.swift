import Foundation
import AMSMB2

/// This adapter intentionally exposes only read operations.
final class SMBService: @unchecked Sendable {
    let manager: SMB2Manager
    let settings: ConnectionSettings

    init(settings: ConnectionSettings, password: String) throws {
        try settings.validate()
        let credentials = URLCredential(user: settings.username.isEmpty ? "guest" : settings.username,
                                        password: password, persistence: .forSession)
        guard let client = SMB2Manager(url: try settings.serverURL(), domain: settings.domain, credential: credentials) else {
            throw AlbumError.message("無法建立 SMB 連線")
        }
        client.timeout = 20
        manager = client
        self.settings = settings
    }

    func connect() async throws {
        try await manager.connectShare(name: settings.share, encrypted: settings.encrypted)
    }

    func list(_ path: String) async throws -> [AlbumEntry] {
        try Task.checkCancellation()
        let folder = try AlbumPath.clean(path)
        let rows = try await manager.contentsOfDirectory(atPath: folder)
        try Task.checkCancellation()
        return rows.compactMap { row -> AlbumEntry? in
            guard let name = row[.nameKey] as? String, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\") else { return nil }
            let type = row[.fileResourceTypeKey] as? URLFileResourceType
            // Do not follow symlinks: prevents escaping the selected tree or cycling.
            guard type == .directory || type == .regular else { return nil }
            guard let kind = type == .directory ? MediaKind.folder : MediaKind.fromExtension(name) else { return nil }
            let size = (row[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            return AlbumEntry(path: AlbumPath.joined(folder, name), name: name, kind: kind, size: size)
        }.sorted {
            if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        try await CancellableRead.perform { [manager] shouldContinue in
            try await manager.contents(atPath: path, range: range, progress: { _, _ in shouldContinue() })
        }
    }
}

/// AMSMB2's continuation does not forward Task cancellation. Stop its read loop at
/// the next progress callback and never return partial data as a complete image.
enum CancellableRead {
    static func perform(_ read: @Sendable (@escaping @Sendable () -> Bool) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        let cancellation = ReadCancellation()
        return try await withTaskCancellationHandler {
            let data = try await read { cancellation.shouldContinue }
            try Task.checkCancellation()
            return data
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var shouldContinue: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}
