import DeskRemoteCore
import Foundation
import Security

/// The PCs this phone knows, in UserDefaults (no secrets), and each PC's token in the Keychain.
@MainActor
final class DeskStore: ObservableObject {
    @Published private(set) var pcs: [DeskPC] = []
    private let defaults: UserDefaults
    static let key = "deskremote.pcs"

    /// UI tests start from an empty list (`DESK_UI_TEST=1`) and may add one PC given as
    /// `DESK_UI_PC=name|host|port|token`, with tokens kept in memory instead of the Keychain.
    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if environment["DESK_UI_TEST"] == "1" {
            defaults.removeObject(forKey: Self.key)
            DeskSecret.useMemory()
            load()
            if let preset = environment["DESK_UI_PC"] {
                let parts = preset.components(separatedBy: "|")
                if parts.count == 4, let port = Int(parts[2]) {
                    _ = save(DeskPC(name: parts[0], host: parts[1], port: port), token: parts[3])
                }
            }
        } else {
            load()
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([DeskPC].self, from: data) else {
            pcs = []
            return
        }
        pcs = saved
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pcs) { defaults.set(data, forKey: Self.key) }
    }

    func pc(_ id: UUID) -> DeskPC? { pcs.first { $0.id == id } }

    func hasToken(_ pc: DeskPC) -> Bool { DeskSecret.load(pc.id) != nil }

    /// Adds or updates a PC. An empty token keeps the stored one. False when the Keychain refused.
    func save(_ pc: DeskPC, token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !DeskSecret.save(trimmed, for: pc.id) { return false }
        if let index = pcs.firstIndex(where: { $0.id == pc.id }) {
            pcs[index] = pc
        } else {
            pcs.append(pc)
        }
        persist()
        return true
    }

    func delete(_ id: UUID) {
        DeskSecret.remove(id)
        pcs.removeAll { $0.id == id }
        persist()
    }

    func client(_ id: UUID) -> HelperClient? {
        guard let pc = pc(id), let endpoint = pc.endpoint, let token = DeskSecret.load(id) else { return nil }
        return HelperClient(endpoint: endpoint, token: token)
    }
}

/// Each PC's helper token, only in this iPhone's Keychain: this device only, readable while
/// unlocked, never in UserDefaults, backups or the repository.
@MainActor
enum DeskSecret {
    private static let service = "org.personal.deskremote.token"
    private static var memory: [UUID: String]?

    static func useMemory() { memory = [:] }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func load(_ id: UUID) -> String? {
        if let memory { return memory[id] }
        var item: CFTypeRef?
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    static func save(_ token: String, for id: UUID) -> Bool {
        if memory != nil {
            memory?[id] = token
            return true
        }
        SecItemDelete(query(id) as CFDictionary)
        var item = query(id)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: UUID) {
        if memory != nil {
            memory?[id] = nil
            return
        }
        SecItemDelete(query(id) as CFDictionary)
    }
}
