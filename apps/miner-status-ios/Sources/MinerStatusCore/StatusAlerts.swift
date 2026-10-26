import Foundation

/// Which machines need attention, for the in-app warning. Pure functions over snapshots.
public enum StatusAlerts {
    /// Machines that are not green, in snapshot order.
    public static func needingAttention(_ snapshots: [MachineSnapshot]) -> [MachineSnapshot] {
        snapshots.filter { $0.light != .green }
    }

    /// Machines that were green in `previous` and are not green in `current`.
    /// A machine seen for the first time, or already non-green before, is not "newly" degraded,
    /// so one change raises one alert instead of one per refresh.
    public static func newlyDegraded(from previous: [MachineSnapshot], to current: [MachineSnapshot]) -> [MachineSnapshot] {
        let wasGreen = Set(previous.filter { $0.light == .green }.map(\.machineId))
        return current.filter { $0.light != .green && wasGreen.contains($0.machineId) }
    }

    /// One line per machine: "office（黃燈・無法確認挖礦）".
    public static func describe(_ snapshots: [MachineSnapshot]) -> [String] {
        snapshots.map { "\($0.displayName)（\($0.light.displayName)・\($0.statusTitle)）" }
    }

    /// Banner heading, or nil when every machine is green.
    public static func headline(_ snapshots: [MachineSnapshot]) -> String? {
        let attention = needingAttention(snapshots)
        return attention.isEmpty ? nil : "\(attention.count) 台不是綠燈"
    }
}
