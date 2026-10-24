import XCTest

// Drives the real app on a simulator: every offline demo scenario, the detail screen, and the
// read-only custom source. Source URLs come from scripts/build.sh through TEST_RUNNER_ environment
// variables, so no address is written in this file. Each screen is kept as a screenshot.
final class MinerStatusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "mode banner missing after launch")
    }

    // MARK: - Offline demo scenarios

    func test01FirstSample() throws { try checkScenario("首筆資料", light: "黃燈", shot: "01-first-sample") }
    func test02ConfirmedMining() throws { try checkScenario("確認挖礦（兩筆樣本）", light: "綠燈", shot: "02-confirmed-mining") }
    func test03Stopped() throws { try checkScenario("已停止", light: "紅燈", shot: "03-stopped") }
    func test04Unknown() throws { try checkScenario("未知／無資料欄位", light: "黃燈", shot: "04-unknown") }
    func test05Stale() throws { try checkScenario("資料逾時（超過 5 分鐘）", light: "灰燈", shot: "05-stale") }
    func test06RequestFailure() throws { try checkScenario("請求失敗", light: "黃燈", shot: "06-request-failure") }
    func test07IncompleteData() throws { try checkScenario("資料不足／時間無法驗證", light: "灰燈", shot: "07-incomplete-data") }

    // MARK: - Detail

    func test08MachineDetail() throws {
        XCTAssertTrue(banner.label.contains("示範模式"), "launch must start in the offline demo")
        let row = element("machine-demo-rig-a")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "machine row A missing")
        row.tap()
        XCTAssertTrue(app.navigationBars["詳情（示範）"].waitForExistence(timeout: 5), "detail screen did not open")
        XCTAssertTrue(app.staticTexts["demo-rig-a"].waitForExistence(timeout: 5), "Machine ID not shown on detail")
        snapshot("08-detail-top")
        app.swipeUp()
        snapshot("09-detail-bottom")
    }

    // MARK: - Custom source (read-only)

    func test09SourceSettingsRejectsInvalidURL() throws {
        openSettings()
        let field = app.textFields["source-url"]
        replaceText(in: field, with: "not a url")
        XCTAssertTrue(element("source-url-error").waitForExistence(timeout: 5), "invalid URL shows no error")
        XCTAssertFalse(app.buttons["start-live"].isEnabled, "start must stay disabled for an invalid URL")
        snapshot("10-settings-invalid-url")
    }

    func test10LiveSourceReadsLocalFeed() throws {
        let url = try sourceURL("MINER_UI_SOURCE_URL")
        startLive(url)
        XCTAssertTrue(waitFor(banner, labelContains: "自訂來源（唯讀）", timeout: 10), "banner did not switch to live mode")
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "live feed rows did not appear")
        XCTAssertTrue(element("machine-demo-rig-b").exists, "second live machine missing")
        XCTAssertTrue(waitFor(banner, labelContains: "示範資料", timeout: 5), "demo-marked source data is not flagged")
        snapshot("11-live-local-feed")
        stopLiveAndCheckDemo()
    }

    func test11LiveSourceFailureIsShown() throws {
        let url = try sourceURL("MINER_UI_FAILING_SOURCE_URL")
        startLive(url)
        XCTAssertTrue(waitFor(banner, labelContains: "自訂來源（唯讀）", timeout: 10), "banner did not switch to live mode")
        XCTAssertTrue(element("live-failure").waitForExistence(timeout: 30), "request failure is not shown")
        snapshot("12-live-failure")
        stopLiveAndCheckDemo()
    }

    // MARK: - Helpers

    private var banner: XCUIElement { element("mode-banner") }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func checkScenario(_ title: String, light: String, shot: String) throws {
        let menu = element("scenario-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "scenario menu missing")
        menu.tap()
        let item = app.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "scenario \(title) missing from menu")
        item.tap()
        XCTAssertTrue(waitFor(menu, labelContains: title, timeout: 5), "scenario \(title) was not selected")
        for id in ["demo-rig-a", "demo-rig-b"] {
            let row = element("machine-\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) row missing in \(title)")
            XCTAssertTrue(waitFor(row, labelContains: light, timeout: 5),
                          "\(id) in \(title): expected \(light), row says \(row.label)")
        }
        snapshot(shot)
    }

    private func openSettings() {
        let button = element("source-settings")
        XCTAssertTrue(button.waitForExistence(timeout: 5), "source settings button missing")
        button.tap()
        XCTAssertTrue(app.textFields["source-url"].waitForExistence(timeout: 5), "settings sheet did not open")
    }

    private func startLive(_ url: String) {
        openSettings()
        replaceText(in: app.textFields["source-url"], with: url)
        let start = app.buttons["start-live"]
        XCTAssertTrue(start.isEnabled, "start disabled for a valid URL")
        start.tap()
    }

    private func stopLiveAndCheckDemo() {
        let stop = element("stop-live")
        if !stop.exists { app.swipeUp() }
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "stop button missing in live mode")
        stop.tap()
        XCTAssertTrue(waitFor(banner, labelContains: "示範模式", timeout: 10), "did not return to the offline demo")
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    private func sourceURL(_ key: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[key],
                      "\(key) not set: run through scripts/build.sh, which serves the local feed")
    }

    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
