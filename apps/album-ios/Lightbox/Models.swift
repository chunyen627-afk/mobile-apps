import Foundation

enum AlbumError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct ConnectionSettings: Codable, Equatable, Sendable {
    var server = ""
    var share = ""
    var folder = ""
    var username = ""
    var domain = ""
    var encrypted = false

    var identity: String { [server.lowercased(), share.lowercased(), username, domain].joined(separator: "|") }

    func serverURL() throws -> URL {
        let text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: text.contains("://") ? text : "smb://" + text)
        guard components?.scheme?.lowercased() == "smb", let host = components?.host, !host.isEmpty,
              components?.user == nil, components?.password == nil,
              components?.query == nil, components?.fragment == nil,
              components?.path.isEmpty == true || components?.path == "/" else {
            throw AlbumError.message("主機欄請只填 IP 或主機名稱；分享名稱與資料夾請填在下方。")
        }
        components?.path = ""
        guard let url = components?.url else { throw AlbumError.message("主機位址格式不正確") }
        return url
    }

    func validate() throws {
        _ = try serverURL()
        guard !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !share.contains("/"), !share.contains("\\") else {
            throw AlbumError.message("請輸入分享名稱，例如 Photos 或 e；不是 Windows 磁碟代號 Z:。")
        }
        _ = try AlbumPath.clean(folder)
    }
}

enum AlbumPath {
    static func clean(_ path: String) throws -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard !parts.contains(".."), !parts.contains(where: { $0.contains(":") || $0.contains("\0") }) else {
            throw AlbumError.message("資料夾路徑不正確")
        }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    static func contains(_ parent: String, _ child: String) -> Bool {
        parent.isEmpty || parent == child || child.hasPrefix(parent + "/")
    }

    static func joined(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}

enum MediaKind: String, Codable, Sendable {
    case folder, photo, video
    static func fromExtension(_ name: String) -> MediaKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "avif"].contains(ext) { return .photo }
        if ["mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "mpg", "mpeg", "ts", "mts", "m2ts"].contains(ext) { return .video }
        return nil
    }
    var symbol: String { self == .folder ? "folder.fill" : self == .photo ? "photo" : "film" }
    var label: String { self == .folder ? "包含所有子資料夾" : self == .photo ? "照片" : "影片" }
}

struct AlbumEntry: Identifiable, Hashable, Codable, Sendable {
    var path: String
    var name: String
    var kind: MediaKind
    var size: Int64
    var id: String { path }
}

enum PlaybackFilter: String, CaseIterable, Identifiable {
    case all = "照片與影片", photo = "只播照片", video = "只播影片"
    var id: String { rawValue }
    func accepts(_ entry: AlbumEntry) -> Bool {
        entry.kind != .folder && (self == .all || (self == .photo && entry.kind == .photo) || (self == .video && entry.kind == .video))
    }
}

enum SelectionRules {
    static func roots(_ entries: [AlbumEntry]) -> [AlbumEntry] {
        let sorted = entries.sorted { $0.path.count < $1.path.count }
        return sorted.reduce(into: [AlbumEntry]()) { result, entry in
            if !result.contains(where: { $0.path == entry.path || ($0.kind == .folder && AlbumPath.contains($0.path, entry.path)) }) {
                result.append(entry)
            }
        }
    }
}
