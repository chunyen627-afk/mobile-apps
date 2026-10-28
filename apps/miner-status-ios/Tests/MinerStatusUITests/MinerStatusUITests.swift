import XCTest

// Drives the real app on a simulator: every offline demo scenario, the detail screen, and the
// read-only custom source. Source URLs come from scripts/build.sh through TEST_RUNNER_ environment
// variables, so no address is written in this file. Each screen is kept as a screenshot.
final class MinerStatusUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Each test starts in the demo, whatever source an earlier test left open; test19 checks
        // the reconnect itself.
        app.launchArguments = ["-resumeLive", "NO"]
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
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "運轉時間", "運轉時間")).firstMatch
            .waitForExistence(timeout: 5), "health section missing on detail")
        for _ in 0 ..< 3 where !machineId.waitForExistence(timeout: 2) {
            app.swipeUp()  // Health and earnings sections push the machine section below the fold.
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
        let rowA = element("machine-demo-rig-a")
        XCTAssertTrue(waitFor(rowA, labelContains: "前）", timeout: 5) && !rowA.label.contains("+08:00"),
                      "live row time not formatted: \(rowA.label)")
        XCTAssertTrue(waitFor(banner, labelContains: "示範資料", timeout: 5), "demo-marked source data is not flagged")
        // The fixture's timestamps are old, so both machines are gray: the warning must say so.
        let attention = element("attention-banner")
        XCTAssertTrue(attention.waitForExistence(timeout: 5) && poll(timeout: 5) { attention.label.contains("2 台不是綠燈") },
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
        XCTAssertTrue(waitFor(rowA, labelContains: "最後份額", timeout: 5), "row A has no health line: \(rowA.label)")
        // Taiwan clock plus age against the frozen demo clock (17:30:35), not the raw RFC 3339 text.
        XCTAssertTrue(waitFor(rowA, labelContains: "資料時間：17:30:30（5 秒前）", timeout: 5), "row A time: \(rowA.label)")
        XCTAssertFalse(rowA.label.contains("+08:00"), "raw timestamp still shown: \(rowA.label)")
        XCTAssertTrue(waitFor(element("machine-demo-rig-b"), labelContains: "電費不計", timeout: 5),
                      "demo machine B should not be billed by default")
        let summary = element("earnings-summary")
        XCTAssertTrue(reveal(summary), "earnings summary missing")
        XCTAssertTrue(waitFor(summary, labelContains: "NT$", timeout: 3), "summary says \(summary.label)")
        snapshot("13-earnings-summary")
    }

    func test20MachineOnAnotherCoinShowsItsOwnEarnings() throws {
        // Demo B stands for the FPGA on QTC: 0.0084 QTC × US$73 × 32.5 ≈ NT$20 a day, not priced as PRL.
        let row = element("machine-demo-rig-b")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "machine row B missing")
        XCTAssertTrue(waitFor(row, labelContains: "收益 ≈ NT$20/天", timeout: 5), "row B is not priced in QTC: \(row.label)")
        row.tap()
        XCTAssertTrue(app.navigationBars["詳情（示範）"].waitForExistence(timeout: 5), "detail screen did not open")
        // The pool's view in the machine's own scale, not "0.0 TH/s".
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "148.0 MH/s", "148.0 MH/s")).firstMatch
            .waitForExistence(timeout: 5), "pool hashrate not shown in MH/s")
        let mined = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "0.008 QTC", "0.008 QTC")).firstMatch
        let price = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "US$73", "US$73")).firstMatch
        for _ in 0 ..< 3 where !mined.waitForExistence(timeout: 2) {
            app.swipeUp()  // The machine section sits above the earnings section.
        }
        XCTAssertTrue(mined.exists, "QTC amount not shown on detail")
        snapshot("20-other-coin-earnings")
        for _ in 0 ..< 2 where !price.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(price.exists, "QTC price not shown on detail")
    }

    func test21RunningTotalIsMarkedAsAnEstimate() throws {
        // The demo source's fictional running total: NT$349 in all, B 0.025 QTC ≈ NT$60.
        let total = element("earnings-cumulative")
        XCTAssertTrue(reveal(total), "running total missing")
        XCTAssertTrue(waitFor(total, labelContains: "NT$349", timeout: 3), "running total says \(total.label)")
        XCTAssertTrue(total.label.contains("不是實際入帳"), "running total not marked as an estimate: \(total.label)")
        XCTAssertTrue(total.label.contains("0.00013400 BTC"), "running total has no BTC: \(total.label)")
        snapshot("21-running-total")
        app.swipeDown()
        app.swipeDown()
        let row = element("machine-demo-rig-b")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "machine row B missing")
        row.tap()
        XCTAssertTrue(app.navigationBars["詳情（示範）"].waitForExistence(timeout: 5), "detail screen did not open")
        let mined = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "0.025 QTC", "0.025 QTC")).firstMatch
        for _ in 0 ..< 5 where !mined.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(mined.exists, "B's running total not shown on detail")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "NT$60", "NT$60")).firstMatch.exists,
                      "B's running total in NT$ not shown")
        snapshot("21-running-total-detail")
    }

    func test13ElectricityToggleChangesTotals() throws {
        let summary = element("earnings-summary")
        XCTAssertTrue(reveal(summary), "earnings summary missing")
        let before = summary.label
        let settings = element("earnings-settings")
        XCTAssertTrue(reveal(settings), "earnings settings button not reachable")
        settings.tap()
        // Found by its label: inside a Form the identifier can land on the row instead of the switch.
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "示範礦機 B")).firstMatch
        if !toggle.waitForExistence(timeout: 5) {
            snapshot("14-earnings-settings-missing-toggle")
            let switches = app.switches.allElementsBoundByIndex.map { "\($0.identifier)=\($0.label)" }
            XCTFail("electricity toggle for machine B missing; switches: \(switches)")
            return
        }
        let wasOn = (toggle.value as? String) == "1"
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(poll(timeout: 3) { ((toggle.value as? String) == "1") != wasOn }, "toggle did not change")
        snapshot("14-earnings-settings")
        element("earnings-done").tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "earnings summary missing after settings")
        XCTAssertTrue(poll(timeout: 5) { summary.label != before }, "totals did not change: \(summary.label)")
    }

    // MARK: - Publisher judgment

    func test14StalePublisherJudgmentShowsComputerSilent() throws {
        let url = try sourceURL("MINER_UI_ASSESSED_SOURCE_URL")
        startLive(url)
        let row = element("machine-demo-rig-a")
        guard row.waitForExistence(timeout: 20) else {
            snapshot("15-live-publisher-missing")
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("assessed feed rows did not appear; banner \(banner.label); texts: \(texts)")
            return
        }
        // The fixture's judgment is old, so the app must not show its green: gray "電腦端沒有回應".
        XCTAssertTrue(waitFor(row, labelContains: "電腦端沒有回應", timeout: 5), "row says \(row.label)")
        XCTAssertTrue(waitFor(row, labelContains: "灰燈", timeout: 2), "row says \(row.label)")
        snapshot("15-live-publisher-silent")
        stopLiveAndCheckDemo()
    }

    // MARK: - Today's tariff

    func test15TodayTariffAndPublishedRates() throws {
        let today = element("today-tariff")
        XCTAssertTrue(reveal(today), "today tariff section missing")
        XCTAssertTrue(waitFor(today, labelContains: "元／度", timeout: 3), "today tariff says \(today.label)")
        XCTAssertTrue(today.label.contains("現在尖峰") || today.label.contains("現在離峰"), "no current period: \(today.label)")
        XCTAssertTrue(today.label.contains("起改為"), "no next change: \(today.label)")
        snapshot("16-today-tariff")

        // The live fixture carries a published tariff; the settings must show it is in use.
        startLive(try sourceURL("MINER_UI_SOURCE_URL"))
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "live feed rows did not appear")
        let settings = element("tariff-settings")
        XCTAssertTrue(reveal(settings), "tariff settings button not reachable")
        settings.tap()
        let published = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "2025-10-01 起", "2025-10-01 起")).firstMatch
        if !published.waitForExistence(timeout: 5) {
            snapshot("17-tariff-settings-missing")
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(30).map(\.label)
            XCTFail("published tariff not shown in settings; texts: \(texts)")
            return
        }
        snapshot("17-tariff-settings")
        element("earnings-done").tap()
        stopLiveAndCheckDemo()
    }

    // MARK: - Remote control

    func test16RemoteControlNeedsTokenAndConfirmation() throws {
        openSettings()
        let token = app.secureTextFields["control-token"]
        XCTAssertTrue(reveal(token), "control password field missing")
        token.tap()
        token.typeText("ui-test-token")
        let save = element("control-token-save")
        XCTAssertTrue(reveal(save), "save password button missing")
        save.tap()
        XCTAssertTrue(element("control-token-set").waitForExistence(timeout: 5), "password not marked as set")
        let field = app.textFields["source-url"]
        XCTAssertTrue(reveal(field), "URL field missing")
        replaceText(in: field, with: try sourceURL("MINER_UI_SOURCE_URL"))
        let start = app.buttons["start-live"]
        XCTAssertTrue(reveal(start), "start button missing")
        start.tap()

        let row = element("machine-demo-rig-a")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "live feed rows did not appear")
        row.tap()
        let stop = element("control-stop")
        XCTAssertTrue(reveal(stop), "stop button missing for a controllable machine")
        XCTAssertFalse(element("control-start").exists, "start shown although the source says it is running")
        stop.tap()
        // Asks first; nothing is sent until confirmed.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "確定停止挖礦")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation")
        snapshot("18-control-confirm")
        confirm.tap()
        // The test server answers POST with 501, so the app must show that failure.
        let result = element("control-result")
        XCTAssertTrue(waitFor(result, labelContains: "501", timeout: 15), "result says \(result.label)")
        snapshot("19-control-result")
    }

    // MARK: - Mining advice

    func test17MiningAdviceForBilledMachines() throws {
        XCTAssertFalse(element("advice-demo-laptop").exists, "the offline demo carries no advice")
        startLive(try sourceURL("MINER_UI_SOURCE_URL"))
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "live feed rows did not appear")
        // A switched-off machine has no machine row but still gets advice.
        let laptop = element("advice-demo-laptop")
        XCTAssertTrue(reveal(laptop), "advice for the switched-off machine missing")
        XCTAssertTrue(waitFor(laptop, labelContains: "建議挖礦", timeout: 3), "laptop advice says \(laptop.label)")
        XCTAssertTrue(laptop.label.contains("NT$343") || laptop.label.contains("NT$342"), "no monthly net: \(laptop.label)")
        let rig = element("advice-demo-rig-b")
        XCTAssertTrue(reveal(rig), "advice for the losing machine missing")
        XCTAssertTrue(waitFor(rig, labelContains: "建議停挖", timeout: 3), "rig advice says \(rig.label)")
        XCTAssertTrue(rig.label.contains("-35") || rig.label.contains("−35"), "loss not shown: \(rig.label)")
        snapshot("20-mining-advice")
        stopLiveAndCheckDemo()
        XCTAssertFalse(element("advice-demo-laptop").exists, "advice must not carry over into the demo")
    }

    func test18RemoteWakeForSwitchedOffMachine() throws {
        openSettings()
        let token = app.secureTextFields["control-token"]
        XCTAssertTrue(reveal(token), "control password field missing")
        token.tap()
        token.typeText("ui-test-token")
        let save = element("control-token-save")
        XCTAssertTrue(reveal(save), "save password button missing")
        save.tap()
        XCTAssertTrue(element("control-token-set").waitForExistence(timeout: 5), "password not marked as set")
        let field = app.textFields["source-url"]
        XCTAssertTrue(reveal(field), "URL field missing")
        replaceText(in: field, with: try sourceURL("MINER_UI_SOURCE_URL"))
        let start = app.buttons["start-live"]
        XCTAssertTrue(reveal(start), "start button missing")
        start.tap()
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "live feed rows did not appear")

        // Only the machine the source says it can wake gets the button.
        let wake = element("wake-demo-laptop")
        XCTAssertTrue(reveal(wake), "wake button missing for the switched-off machine")
        XCTAssertFalse(element("wake-demo-rig-b").exists, "wake offered although canWake is false")
        wake.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "確定遠端開機")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation before waking")
        snapshot("21-wake-confirm")
        confirm.tap()
        // The test server answers POST with 501, so the app must show that failure.
        let result = element("wake-result")
        XCTAssertTrue(reveal(result) && waitFor(result, labelContains: "501", timeout: 15), "wake result says \(result.label)")
        snapshot("22-wake-result")
    }

    // MARK: - Reconnect after iOS closed the app

    func test19RelaunchReconnectsUntilTheUserStops() throws {
        startLive(try sourceURL("MINER_UI_SOURCE_URL"))
        XCTAssertTrue(waitFor(banner, labelContains: "自訂來源（唯讀）", timeout: 10), "banner did not switch to live mode")
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "live feed rows did not appear")
        // A relaunch stands in for iOS ending the app in the background: it must reconnect by itself.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(waitFor(banner, labelContains: "自訂來源（唯讀）", timeout: 15), "relaunch fell back to the demo: \(banner.label)")
        XCTAssertTrue(element("machine-demo-rig-a").waitForExistence(timeout: 20), "rows missing after the reconnect")
        snapshot("23-relaunch-reconnected")
        // After the user stops reading, the next launch starts in the demo again.
        stopLiveAndCheckDemo()
        app.terminate()
        app.launch()
        XCTAssertTrue(waitFor(banner, labelContains: "示範模式", timeout: 15), "relaunch after stopping did not start in the demo: \(banner.label)")
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
            // Polled: an NSPredicate wait once missed text that was already shown (run 40208126240).
            XCTAssertTrue(poll(timeout: 3) { attention.label.contains("2 台不是綠燈") },
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
        XCTAssertTrue(reveal(stop), "stop button missing in live mode")
        stop.tap()
        // The stop now asks first, so an accidental tap does nothing.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "停止讀取")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "stop confirmation did not appear")
        XCTAssertTrue(waitFor(banner, labelContains: "自訂來源", timeout: 2), "stopped before confirming")
        confirm.tap()
        XCTAssertTrue(waitFor(banner, labelContains: "示範模式", timeout: 10), "did not return to the offline demo")
    }

    /// Clears with the field's own button: tapping a long saved URL puts the cursor mid-text, so
    /// deleting backwards once left part of the old address in front of the new one.
    private func replaceText(in field: XCUIElement, with text: String) {
        let clear = element("source-url-clear")
        if clear.exists { clear.tap() }
        field.tap()
        field.typeText(text)
        XCTAssertTrue(poll(timeout: 3) { (field.value as? String) == text },
                      "URL field holds \(field.value ?? "") instead of \(text)")
    }

    private func sourceURL(_ key: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[key],
                      "\(key) not set: run through scripts/build.sh, which serves the local feed")
    }

    /// Checks label or value: a picker row keeps its title in the label and the selection in the value.
    /// Polled directly: on slow runners an NSPredicate expectation timed out on text that was already
    /// shown (runs 40208126240 and 40210990544: "row says 黃燈…" failed to match 黃燈).
    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) {
            element.exists && (element.label.contains(text) || ((element.value as? String)?.contains(text) ?? false))
        }
    }

    /// Scrolls the list down, then back up, until the element is on screen and tappable.
    private func reveal(_ element: XCUIElement) -> Bool {
        let visible = { element.exists && element.isHittable }
        if poll(timeout: 2, visible) { return true }
        for _ in 0 ..< 4 {
            app.swipeUp()
            if poll(timeout: 1, visible) { return true }
        }
        for _ in 0 ..< 8 {
            app.swipeDown()
            if poll(timeout: 1, visible) { return true }
        }
        return false
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
