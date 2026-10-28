import CryptoKit
import DeskRemoteCore
import Foundation
import LocalAuthentication
import Security

/// The PCs this phone knows, in UserDefaults (no secrets), and each PC's token in the Keychain.
@MainActor
final class DeskStore: ObservableObject {
    @Published private(set) var pcs: [DeskPC] = []
    /// The newest plan limits per account from any PC, so PCs on one plan show the same.
    @Published private(set) var usageBook = UsageBook()
    private var othersAskedAt: Date?
    private let defaults: UserDefaults
    static let key = "deskremote.pcs"
    static let usageKey = "deskremote.usage-book"
    /// Simulator UI tests: secrets in memory and no Face ID prompt (there is no enrolled face).
    private(set) var uiTest = false

    /// UI tests start from an empty list (`DESK_UI_TEST=1`) and may add PCs given as
    /// `DESK_UI_PC=name|host|port|token[|key]`, several separated by ";", with tokens kept in
    /// memory instead of the Keychain.
    init(environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if environment["DESK_UI_TEST"] == "1" {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: Self.usageKey)
            DeskSecret.useMemory()
            load()
            uiTest = true
            for preset in (environment["DESK_UI_PC"] ?? "").components(separatedBy: ";") {
                let parts = preset.components(separatedBy: "|")
                if parts.count >= 4, let port = Int(parts[2]) {
                    let pc = DeskPC(name: parts[0], host: parts[1], port: port)
                    _ = save(pc, token: parts[3])
                    if parts.count == 5 { _ = saveElevateKey(parts[4], for: pc.id) }
                }
            }
        } else {
            load()
        }
    }

    private func load() {
        if let data = defaults.data(forKey: Self.usageKey), let book = try? JSONDecoder().decode(UsageBook.self, from: data) {
            usageBook = book
        }
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
        DeskSecret.remove(id, kind: .elevate)
        defaults.removeObject(forKey: "deskremote.elevate-hidden.\(id.uuidString)")
        pcs.removeAll { $0.id == id }
        persist()
    }

    /// The PC's administrator approval key (64 hex characters); empty removes it.
    func saveElevateKey(_ hex: String, for id: UUID) -> Bool {
        let trimmed = hex.filter { !$0.isWhitespace }.lowercased()
        if trimmed.isEmpty {
            DeskSecret.remove(id, kind: .elevate)
            return true
        }
        guard ElevateSigner.key(fromHex: trimmed) != nil else { return false }
        return DeskSecret.save(trimmed, for: id, kind: .elevate)
    }

    func hasElevateKey(_ id: UUID) -> Bool { DeskSecret.load(id, kind: .elevate) != nil }

    func elevateKey(_ id: UUID) -> SymmetricKey? {
        DeskSecret.load(id, kind: .elevate).flatMap { ElevateSigner.key(fromHex: $0) }
    }

    /// Face ID (or the passcode) before an administrator approval; skipped in simulator UI tests.
    func confirmOwner(reason: String) async -> Bool {
        if uiTest { return true }
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    /// Finished administrator requests the user removed from this PC's page (ids only, no content).
    func hiddenElevateResults(_ id: UUID) -> Set<String> {
        Set(defaults.stringArray(forKey: "deskremote.elevate-hidden.\(id.uuidString)") ?? [])
    }

    func setHiddenElevateResults(_ ids: Set<String>, for id: UUID) {
        defaults.set(ids.sorted(), forKey: "deskremote.elevate-hidden.\(id.uuidString)")
    }

    /// Remembers the plan limits a PC reported (every place that reads a PC's state calls this).
    func note(_ state: HelperState, pcID: UUID) {
        guard let name = pc(pcID)?.name, usageBook.record(state, pc: name) else { return }
        if let data = try? JSONEncoder().encode(usageBook) { defaults.set(data, forKey: Self.usageKey) }
    }

    /// The PC's own limits for `app`, or newer ones another PC on the same account reported.
    func shownUsage(_ app: DeskApp, in state: HelperState, pcID: UUID) -> UsageBook.Shown? {
        usageBook.shown(app, own: state.usage(app), pc: pc(pcID)?.name ?? state.pc.name)
    }

    /// Asks the other PCs for their limits too, at most once a minute (their page may not be open).
    func askOthersForUsage(except id: UUID) async {
        if let at = othersAskedAt, Date().timeIntervalSince(at) < 60 { return }
        othersAskedAt = Date()
        for other in pcs where other.id != id {
            if let client = client(other.id), let state = try? await client.state() { note(state, pcID: other.id) }
        }
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
    /// The connection token, or the administrator approval key (a separate Keychain item).
    enum Kind: String {
        case token = "org.personal.deskremote.token"
        case elevate = "org.personal.deskremote.elevate"
    }

    private static var memory: [String: String]?

    static func useMemory() { memory = [:] }

    private static func query(_ id: UUID, _ kind: Kind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: kind.rawValue,
         kSecAttrAccount as String: id.uuidString]
    }

    static func load(_ id: UUID, kind: Kind = .token) -> String? {
        if let memory { return memory["\(kind.rawValue)/\(id)"] }
        var item: CFTypeRef?
        var request = query(id, kind)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return text
    }

    static func save(_ token: String, for id: UUID, kind: Kind = .token) -> Bool {
        if memory != nil {
            memory?["\(kind.rawValue)/\(id)"] = token
            return true
        }
        SecItemDelete(query(id, kind) as CFDictionary)
        var item = query(id, kind)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ id: UUID, kind: Kind = .token) {
        if memory != nil {
            memory?["\(kind.rawValue)/\(id)"] = nil
            return
        }
        SecItemDelete(query(id, kind) as CFDictionary)
    }
}
