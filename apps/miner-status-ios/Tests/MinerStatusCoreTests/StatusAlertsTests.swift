import XCTest
@testable import MinerStatusCore

final class StatusAlertsTests: XCTestCase {
    private func snapshot(_ id: String, _ light: StatusLight) -> MachineSnapshot {
        let reason: StatusReason
        switch light {
        case .green: reason = .miningConfirmed
        case .yellow: reason = .minerStateUnknown
        case .red: reason = .minerStopped
        case .gray: reason = .noData
        }
        return MachineSnapshot(
            machineId: id, displayName: id.uppercased(), dataOrigin: .live, light: light, reason: reason,
            problem: nil, sample: nil, sampleAge: nil, isHistorical: false, freshness: nil,
            applicableStopReason: .noData)
    }

    func testAllGreenNeedsNoAttention() {
        let all = [snapshot("a", .green), snapshot("b", .green)]
        XCTAssertTrue(StatusAlerts.needingAttention(all).isEmpty)
        XCTAssertNil(StatusAlerts.headline(all))
    }

    func testEveryNonGreenLightNeedsAttention() {
        let all = [snapshot("a", .green), snapshot("b", .yellow), snapshot("c", .red), snapshot("d", .gray)]
        XCTAssertEqual(StatusAlerts.needingAttention(all).map(\.machineId), ["b", "c", "d"])
        XCTAssertEqual(StatusAlerts.headline(all), "3 台不是綠燈")
    }

    func testGreenToNonGreenIsNewlyDegraded() {
        let before = [snapshot("a", .green), snapshot("b", .green)]
        let after = [snapshot("a", .yellow), snapshot("b", .green)]
        XCTAssertEqual(StatusAlerts.newlyDegraded(from: before, to: after).map(\.machineId), ["a"])
    }

    func testStayingNonGreenDoesNotAlertAgain() {
        let before = [snapshot("a", .yellow)]
        let after = [snapshot("a", .red)]
        XCTAssertTrue(StatusAlerts.newlyDegraded(from: before, to: after).isEmpty)
    }

    func testFirstSightingIsNotNewlyDegraded() {
        XCTAssertTrue(StatusAlerts.newlyDegraded(from: [], to: [snapshot("a", .gray)]).isEmpty)
    }

    func testDescribeNamesLightAndStatus() {
        XCTAssertEqual(StatusAlerts.describe([snapshot("a", .red)]), ["A（紅燈・\(snapshot("a", .red).statusTitle)）"])
    }
}
