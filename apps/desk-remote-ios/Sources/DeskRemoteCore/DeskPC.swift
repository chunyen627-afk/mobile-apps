import Foundation

/// A PC the phone knows. The token is not here: it lives only in the iPhone Keychain.
public struct DeskPC: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int

    public init(id: UUID = UUID(), name: String, host: String, port: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }

    public var endpoint: HelperEndpoint? { HelperEndpoint(host: host, port: port) }

    public static let defaultPort = 18790

    /// Why the form cannot be saved yet, or nil when it can.
    public static func problem(name: String, host: String, port: String, token: String, tokenRequired: Bool) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "請輸入名稱" }
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(number) else {
            return "埠要是 1 到 65535 的數字"
        }
        if HelperEndpoint(host: host, port: number) == nil {
            return "位址只填 IP 或主機名稱，不要加 http:// 或路徑"
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenRequired && trimmed.count < 32 { return "連線密碼至少 32 個字元（電腦端 config.json 裡的 token）" }
        if !tokenRequired && !trimmed.isEmpty && trimmed.count < 32 { return "連線密碼至少 32 個字元" }
        return nil
    }
}
