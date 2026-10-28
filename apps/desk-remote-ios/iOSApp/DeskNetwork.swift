import DeskRemoteCore
import Foundation
import Network

/// Notices when the phone changes networks (Wi-Fi ↔ cellular, or another Wi-Fi), so a failed
/// request can say that ZeroTier probably needs turning off and on, and the screens retry at once.
@MainActor
final class DeskNetwork: ObservableObject {
    static let shared = DeskNetwork()

    /// Counts real changes; the foreground loops restart (read again now) when it moves.
    @Published private(set) var changes = 0
    private(set) var changedAt: Date?
    private var current: String?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let key = Self.key(path)
            Task { @MainActor in DeskNetwork.shared.update(key) }
        }
        monitor.start(queue: DispatchQueue(label: "desk-network"))
    }

    var secondsSinceChange: TimeInterval? {
        changedAt.map { Date().timeIntervalSince($0) }
    }

    /// The text for a failed request (nil when it was cancelled), with the ZeroTier hint when
    /// the PC could not be reached.
    func failureText(_ error: Error, short: Bool = false) -> String? {
        let failure = (error as? HelperFailure) ?? .unreachable
        if failure == .cancelled { return nil }
        return DeskText.failure(failure, networkChangedAgo: secondsSinceChange, short: short)
    }

    private func update(_ key: String) {
        defer { current = key }
        // The first report is how the app found the network, not a change; ZeroTier's own tunnel
        // coming and going does not change the primary interface or its gateway.
        guard let current, current != key else { return }
        changedAt = Date()
        changes += 1
    }

    /// The primary interface type and its gateways: another Wi-Fi has another gateway.
    nonisolated private static func key(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "offline" }
        let kind: String
        if path.usesInterfaceType(.wifi) {
            kind = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            kind = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = "wired"
        } else {
            kind = "other"
        }
        return kind + "|" + path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
    }
}
