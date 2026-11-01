import XCTest
@testable import Lightbox

final class DiagnosticsTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func exported(_ store: DiagnosticStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.export())) as? [String: Any])
    }

    func testUnexpectedForegroundEndSurvivesRelaunchAndIsOnlyAClue() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DiagnosticStore(directory: dir)
        first.beginSession(); first.setActive(true)
        let next = DiagnosticStore(directory: dir)
        next.beginSession()
        let report = try exported(next)
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["action"] as? String == "previousSessionEndedInForeground" }.count, 1)
        XCTAssertTrue((report["note"] as? String)?.contains("not proof of a crash") == true)
    }

    func testNormalBackgroundDoesNotFlagCrash() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DiagnosticStore(directory: dir)
        first.beginSession(); first.setActive(true); first.setActive(false)
        let next = DiagnosticStore(directory: dir)
        next.beginSession()
        let events = try XCTUnwrap(exported(next)["events"] as? [[String: Any]])
        XCTAssertFalse(events.contains { $0["action"] as? String == "previousSessionEndedInForeground" })
    }

    func testSummarySeparatesRecordedEventsFromMissingSystemReports() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DiagnosticStore(directory: dir)
        first.beginSession(); first.setActive(true)
        first.record(.scanStarted)
        let next = DiagnosticStore(directory: dir)
        next.beginSession()
        XCTAssertTrue(next.summary().contains("5 筆操作紀錄"))
        XCTAssertTrue(next.summary().contains("1 次前次未正常結束"))
        XCTAssertTrue(next.summary().contains("0 份 iOS"))
        XCTAssertEqual((try exported(next)["events"] as? [Any])?.count, 5)
    }

    func testErrorExportOmitsPrivateDescriptionsAndDomains() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiagnosticStore(directory: dir)
        store.recordError(.connectFailed, error: NSError(domain: "private-host/share", code: 42, userInfo: [NSLocalizedDescriptionKey: "private-password private-photo.jpg"]))
        let text = try String(contentsOf: store.export(), encoding: .utf8)
        XCTAssertFalse(text.contains("private-"))
        XCTAssertTrue(text.contains("42"))
        XCTAssertTrue(text.contains("connectFailed"))
    }

    func testEveryEventCarriesTheMemoryReading() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiagnosticStore(directory: dir)
        store.record(.photoSelected, values: ["index": 3])
        let events = try XCTUnwrap(exported(store)["events"] as? [[String: Any]])
        let values = try XCTUnwrap(events.last?["values"] as? [String: Int])
        XCTAssertEqual(values["index"], 3)
        XCTAssertGreaterThan(values["memMB"] ?? 0, 0, "the app's own memory use")
        XCTAssertNotNil(values["freeMB"], "what is left before iOS ends the app (0 on the simulator)")
    }

    @MainActor
    func testHeartbeatRunsOnlyInTheForegroundAndNamesTheTab() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiagnosticStore(directory: dir)
        let diagnostics = AppDiagnostics(store: store, heartbeatSeconds: 0.05)
        diagnostics.showTool(2)
        diagnostics.showTool(2)
        diagnostics.setForeground(true)
        try await Task.sleep(for: .milliseconds(400))
        diagnostics.setForeground(false)
        let beats = try XCTUnwrap(exported(store)["events"] as? [[String: Any]]).filter { $0["action"] as? String == "heartbeat" }
        XCTAssertGreaterThanOrEqual(beats.count, 2)
        XCTAssertEqual((beats.first?["values"] as? [String: Int])?["tool"], 2)
        try await Task.sleep(for: .milliseconds(300))
        let events = try XCTUnwrap(exported(store)["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["action"] as? String == "heartbeat" }.count, beats.count, "stopped in the background")
        XCTAssertEqual(events.filter { $0["action"] as? String == "toolShown" }.count, 1, "the same tab is logged once")
    }

    func testEventRotationAndSystemReportDeduplicationAreBounded() throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiagnosticStore(directory: dir, maximumEventBytes: 512)
        for number in 0..<100 { store.record(.photoSelected, values: ["index": number]) }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.filter { $0.pathExtension == "jsonl" }.count, 3)
        for file in files where file.pathExtension == "jsonl" {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 512)
        }
        for _ in 0..<10 { store.saveSystemReport(Data("{\"test\":1}".utf8)) }
        var report = try exported(store)
        XCTAssertEqual((report["systemReports"] as? [Any])?.count, 1)
        for number in 2..<10 { store.saveSystemReport(Data("{\"test\":\(number)}".utf8)) }
        report = try exported(store)
        XCTAssertEqual((report["systemReports"] as? [Any])?.count, 5)
        XCTAssertTrue((report["events"] as? [[String: Any]])?.contains { ($0["values"] as? [String: Int])?["index"] == 99 } == true)
    }
}
