import Foundation

/// A PC the phone knows. The token is not here: it lives only in the iPhone Keychain.
public struct DeskPC: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: Int
    /// The helper's address on the PC's own local network (helper 0.5.44 reports it in its state;
    /// the form can set it too). A phone on the same Wi-Fi reaches it directly instead of waiting
    /// for ZeroTier to find the path; `HelperClient` tries both and keeps whichever answers.
    public var lanHost: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int, lanHost: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.lanHost = lanHost
    }

    public var endpoint: HelperEndpoint? { HelperEndpoint(host: host, port: port) }

    /// The local-network address on the same port, when one is known.
    public var lanEndpoint: HelperEndpoint? { lanHost.flatMap { HelperEndpoint(host: $0, port: port) } }

    public static let defaultPort = 18790

    /// Why the form cannot be saved yet, or nil when it can.
    public static func problem(name: String, host: String, port: String, token: String, tokenRequired: Bool,
                               lanHost: String = "") -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "請輸入名稱" }
        guard let number = Int(port.trimmingCharacters(in: .whitespaces)), (1 ... 65535).contains(number) else {
            return "埠要是 1 到 65535 的數字"
        }
        if HelperEndpoint(host: host, port: number) == nil {
            return "位址只填 IP 或主機名稱，不要加 http:// 或路徑"
        }
        let lan = lanHost.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty, HelperEndpoint(host: lan, port: number) == nil {
            return "區網位址只填 IP，不要加 http:// 或路徑"
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenRequired && trimmed.count < 32 { return "連線密碼至少 32 個字元（電腦端 config.json 裡的 token）" }
        if !tokenRequired && !trimmed.isEmpty && trimmed.count < 32 { return "連線密碼至少 32 個字元" }
        return nil
    }
}
