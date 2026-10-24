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
        snapshot("08-detail-top")
        // LabeledContent merges title and value into one element, so match either.
        let machineId = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "demo-rig-a", "demo-rig-a")).firstMatch
        if !machineId.waitForExistence(timeout: 3) {
            app.swipeUp()  // The earnings section above can push the machine section below the fold.
        }
        if !machineId.waitForExistence(timeout: 5) {
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(30).map { "\($0.label)=\($0.value ?? "")" }
            XCTFail("Machine ID not shown on detail; texts on screen: \(texts)")
        }
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
        // The fixture's timestamps are old, so both machines are gray: the warning must say so.
        XCTAssertTrue(waitFor(element("attention-banner"), labelContains: "2 台不是綠燈", timeout: 5),
                      "attention banner missing in live mode")
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

    // MARK: - Earnings

    func test12EarningsShownPerMachineAndInTotal() throws {
        let rowA = element("machine-demo-rig-a")
        XCTAssertTrue(rowA.waitForExistence(timeout: 5), "machine row A missing")
        XCTAssertTrue(waitFor(rowA, labelContains: "收益 ≈ NT$", timeout: 5), "row A has no earnings: \(rowA.label)")
        XCTAssertTrue(waitFor(element("machine-demo-rig-b"), labelContains: "電費不計", timeout: 5),
                      "demo machine B should not be billed by default")
        let summary = element("earnings-summary")
        if !summary.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "earnings summary missing")
        XCTAssertTrue(waitFor(summary, labelContains: "NT$", timeout: 3), "summary says \(summary.label)")
        snapshot("13-earnings-summary")
    }

    func test13ElectricityToggleChangesTotals() throws {
        let summary = element("earnings-summary")
        if !summary.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "earnings summary missing")
        let before = summary.label
        element("earnings-settings").tap()
        let toggle = app.switches["billed-demo-rig-b"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "electricity toggle for machine B missing")
        let wasOn = (toggle.value as? String) == "1"
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(poll(timeout: 3) { ((toggle.value as? String) == "1") != wasOn }, "toggle did not change")
        snapshot("14-earnings-settings")
        element("earnings-done").tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "earnings summary missing after settings")
        XCTAssertTrue(poll(timeout: 5) { summary.label != before }, "totals did not change: \(summary.label)")
    }

    // MARK: - Helpers

    private var banner: XCUIElement { element("mode-banner") }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func checkScenario(_ title: String, light: String, shot: String) throws {
        let picker = element("scenario-picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "scenario picker missing")
        picker.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        guard item.waitForExistence(timeout: 5) else {
            snapshot("\(shot)-picker")
            let labels = app.buttons.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("scenario \(title) missing from the picker list; buttons on screen: \(labels)")
            return
        }
        if title == "首筆資料" { snapshot("00-scenario-list") }
        item.tap()
        // The navigation-link picker normally pops back by itself; go back explicitly if not.
        if !(picker.waitForExistence(timeout: 3) && picker.isHittable) {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "did not return from the scenario list")
        // Poll the value directly: an NSPredicate on `value` once missed a selection that was
        // already shown (run 40108162409 reported "目前情境 / 首筆資料" yet failed).
        XCTAssertTrue(poll(timeout: 5) { picker.label.contains(title) || ((picker.value as? String)?.contains(title) ?? false) },
                      "scenario \(title) was not selected; picker says \(picker.label) / \(picker.value ?? "")")
        for id in ["demo-rig-a", "demo-rig-b"] {
            let row = element("machine-\(id)")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) row missing in \(title)")
            XCTAssertTrue(waitFor(row, labelContains: light, timeout: 5),
                          "\(id) in \(title): expected \(light), row says \(row.label)")
        }
        let attention = element("attention-banner")
        if light == "綠燈" {
            XCTAssertFalse(attention.exists, "all-green \(title) must not show the attention banner")
        } else {
            XCTAssertTrue(attention.waitForExistence(timeout: 3), "\(title) must show the attention banner")
            XCTAssertTrue(waitFor(attention, labelContains: "2 台不是綠燈", timeout: 3),
                          "attention banner in \(title) says \(attention.label)")
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

    /// Checks label or value: a picker row keeps its title in the label and the selection in the value.
    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
