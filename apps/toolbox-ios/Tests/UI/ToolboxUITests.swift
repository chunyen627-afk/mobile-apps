import XCTest

// Drives the toolbox on a simulator: every tool is reachable from the tab bar, each keeps its own
// screen while another is in use, and the last tool opens again after a relaunch. The album runs
// on its built-in simulator fixtures (LIGHTBOX_UI_TEST), the miner on its offline demo and the
// desk remote against the fake helper that scripts/build.sh serves on the Mac's loopback, so no
// real PC or device is involved. Each screen is kept as a screenshot.
final class ToolboxUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    }

    override func tearDownWithError() throws {
        // A crash during the test shows up here as "not running", reported as such rather than
        // as XCUITest's opaque "Failed to terminate" (run 40330467762, test01).
        switch app.state {
        case .runningForeground, .runningBackground, .runningBackgroundSuspended:
            app.terminate()
        default:
            XCTFail("the app was no longer running at the end of the test (state \(app.state.rawValue)); it may have crashed")
        }
    }

    private var albumTab: XCUIElement { app.tabBars.buttons["相簿"] }
    private var minerTab: XCUIElement { app.tabBars.buttons["礦機狀態"] }
    private var deskTab: XCUIElement { app.tabBars.buttons["桌面遙控"] }
    private var albumStart: XCUIElement { app.buttons["開始播放"] }
    private var minerBanner: XCUIElement { app.descendants(matching: .any)["mode-banner"] }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func test01OpensOnTheAlbumWithBothTools() throws {
        app.launch()
        XCTAssertTrue(albumStart.waitForExistence(timeout: 60), "album did not open first")
        XCTAssertTrue(albumTab.exists && minerTab.exists && deskTab.exists && thermoTab.exists, "tab bar does not list all four tools")
        XCTAssertTrue(albumTab.isSelected, "album tab not selected")
        snapshot("01-toolbox-album")
    }

    func test02SwitchingKeepsEachToolsScreen() throws {
        app.launch()
        XCTAssertTrue(albumStart.waitForExistence(timeout: 60), "album did not open first")
        minerTab.tap()
        XCTAssertTrue(minerBanner.waitForExistence(timeout: 10), "miner tab shows no mode banner")
        XCTAssertTrue(minerBanner.label.contains("示範模式"), "miner should start in its offline demo: \(minerBanner.label)")
        let row = app.descendants(matching: .any)["machine-demo-rig-a"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "miner demo rows missing")
        snapshot("02-toolbox-miner")
        // The miner's detail screen opens inside its tab and back still works.
        row.tap()
        XCTAssertTrue(app.navigationBars["詳情（示範）"].waitForExistence(timeout: 10), "miner detail did not open in the tab")
        snapshot("03-toolbox-miner-detail")
        albumTab.tap()
        XCTAssertTrue(albumStart.waitForExistence(timeout: 10), "album screen lost after switching")
        minerTab.tap()
        XCTAssertTrue(app.navigationBars["詳情（示範）"].waitForExistence(timeout: 10), "miner tab did not keep its screen")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back from the miner detail did not return to the list")
    }

    func test03ReopensTheLastTool() throws {
        // Without the album fixtures the stored choice decides, as on the phone.
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = nil
        app.launch()
        XCTAssertTrue(minerTab.waitForExistence(timeout: 30), "tab bar missing")
        minerTab.tap()
        XCTAssertTrue(minerBanner.waitForExistence(timeout: 10), "miner tab shows no mode banner")
        app.terminate()
        app.launch()
        XCTAssertTrue(minerBanner.waitForExistence(timeout: 30), "the last tool (miner) did not open again")
        XCTAssertTrue(minerTab.isSelected, "miner tab not selected after relaunch")
        snapshot("04-toolbox-reopened-miner")
        albumTab.tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(albumTab.waitForExistence(timeout: 30) && albumTab.isSelected, "the album was not reopened")
    }

    func test04TestHarnessCanChooseTheTool() throws {
        app.launchEnvironment["TOOLBOX_TOOL"] = "miner"
        app.launch()
        XCTAssertTrue(minerBanner.waitForExistence(timeout: 30), "TOOLBOX_TOOL=miner did not open the miner")
        XCTAssertTrue(minerTab.isSelected, "miner tab not selected")
    }

    /// The desk remote in its tab, talking to the fake helper: its PC list, PC page and a
    /// conversation open inside the tab, the input bar sits above the tab bar, and the tab keeps
    /// its screen while the album is in use. Its own 41 UI tests also run here (DeskRemoteUITests).
    func test05DeskRemoteInItsTab() throws {
        let environment = ProcessInfo.processInfo.environment
        func setting(_ key: String) throws -> String {
            try XCTUnwrap(environment[key], "\(key) not set: run through scripts/build.sh, which serves the desk remote's fake helper")
        }
        let host = try setting("DESK_HELPER_HOST"), port = try setting("DESK_HELPER_PORT"), token = try setting("DESK_HELPER_TOKEN")
        let preset = "示範電腦|\(host)|\(port)|\(token)"
        // As on the phone: no album fixtures; the desk remote's own test mode keeps its secrets in memory.
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = nil
        app.launchEnvironment["DESK_UI_TEST"] = "1"
        app.launchEnvironment["DESK_UI_PC"] = preset
        app.launch()
        let row = element("pc-row-示範電腦")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "DESK_UI_TEST=1 did not open the desk remote with its preset PC")
        XCTAssertTrue(deskTab.isSelected, "desk remote tab not selected")
        XCTAssertTrue(poll(timeout: 20) { row.label.contains("連線正常") }, "the fake helper was not reached: \(row.label)")
        snapshot("05-toolbox-desk")
        row.tap()
        let presence = element("pc-presence")
        XCTAssertTrue(presence.waitForExistence(timeout: 15), "the PC page did not open in the tab")
        let claude = element("app-row-claude")
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "Claude row missing")
        claude.tap()
        let session = element("session-row-local_11111111-1111-4111-8111-111111111111")
        XCTAssertTrue(session.waitForExistence(timeout: 15), "conversation list did not open in the tab")
        snapshot("06-toolbox-desk-sessions")
        session.tap()
        let input = element("chat-input")
        XCTAssertTrue(input.waitForExistence(timeout: 15), "the conversation did not open in the tab")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists, "tab bar missing in the conversation")
        XCTAssertLessThanOrEqual(input.frame.maxY, tabBar.frame.minY + 1, "the input bar is under the tab bar: \(input.frame) vs \(tabBar.frame)")
        snapshot("07-toolbox-desk-chat")
        albumTab.tap()
        XCTAssertTrue(poll(timeout: 10) { albumTab.isSelected }, "album tab did not open")
        deskTab.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10), "the desk remote tab did not keep its conversation")
    }

    /// The thermometer tab on its built-in demo: three thermometers, a page with the history
    /// chart, a name that stays after going back.
    func test06ThermoDemoRenameAndChart() throws {
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = nil
        app.launchEnvironment["TOOLBOX_TOOL"] = "thermo"
        app.launchEnvironment["THERMO_UI_TEST"] = "1"
        app.launch()
        XCTAssertTrue(thermoTab.waitForExistence(timeout: 30), "tab bar has no thermometer tab")
        XCTAssertTrue(thermoTab.isSelected, "TOOLBOX_TOOL=thermo did not open the thermometers")
        XCTAssertTrue(element("thermo-demo-banner").waitForExistence(timeout: 15), "demo banner missing")
        let row = element("thermo-row-A4:C1:38:00:00:01")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "demo thermometer missing")
        XCTAssertTrue(element("thermo-row-A4:C1:38:00:00:03").exists, "third demo thermometer missing")
        XCTAssertTrue(shows("26.1°", in: row), "temperature not shown: \(row.label)")
        XCTAssertTrue(shows("12%", in: element("thermo-row-A4:C1:38:00:00:03")), "low battery not shown")
        snapshot("08-thermo-demo-list")
        row.tap()
        XCTAssertTrue(element("thermo-detail-reading").waitForExistence(timeout: 10), "thermometer page did not open")
        XCTAssertTrue(element("thermo-detail-battery").label.contains("93%"), "battery missing: \(element("thermo-detail-battery").label)")
        let summary = element("thermo-summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "history summary missing")
        XCTAssertTrue(summary.label.contains("最高"), "summary: \(summary.label)")
        snapshot("09-thermo-demo-chart-day")
        app.segmentedControls["thermo-range"].buttons["7 天"].tap()
        app.segmentedControls["thermo-metric"].buttons["濕度"].tap()
        XCTAssertTrue(poll(timeout: 10) { self.element("thermo-summary").label.contains("%") }, "humidity summary missing")
        snapshot("10-thermo-demo-chart-week-humidity")
        // Rename as in Mi Home: the name row opens a dialog holding the current name.
        let renameRow = element("thermo-rename")
        for _ in 0..<6 where !renameRow.isHittable {
            app.swipeUp()
        }
        renameRow.tap()
        renameIn(alertWith: "客廳", to: "Office A", shot: "11-thermo-rename-dialog")
        XCTAssertTrue(app.navigationBars["Office A"].waitForExistence(timeout: 5), "title did not take the new name")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "list did not come back")
        XCTAssertTrue(poll(timeout: 10) { self.shows("Office A", in: row) }, "new name not in the list: \(row.label)")
        XCTAssertFalse(shows("客廳", in: row), "old name still shown: \(row.label)")
        // Swipe left on another thermometer in the list.
        let bedroom = element("thermo-row-A4:C1:38:00:00:02")
        bedroom.swipeLeft()
        let swipe = app.buttons["thermo-swipe-rename"].exists ? app.buttons["thermo-swipe-rename"] : app.buttons["改名"]
        XCTAssertTrue(swipe.waitForExistence(timeout: 5), "swipe action missing")
        swipe.tap()
        renameIn(alertWith: "臥室", to: "Bedroom B", shot: nil)
        XCTAssertTrue(poll(timeout: 10) { self.shows("Bedroom B", in: bedroom) }, "swipe rename not in the list: \(bedroom.label)")
        snapshot("12-thermo-renamed-list")
    }

    /// Fills the rename dialog, which must open holding `current`.
    private func renameIn(alertWith current: String, to name: String, shot: String?) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "rename dialog did not open")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(poll(timeout: 5) { (field.value as? String) == current }, "dialog should hold \(current): \(String(describing: field.value))")
        if let shot { snapshot(shot) }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4) + name)
        alert.buttons["儲存"].tap()
        XCTAssertTrue(poll(timeout: 5) { !alert.exists }, "rename dialog did not close")
    }

    /// The thermometer tab against two gateways: the fake gateway that scripts/build.sh serves
    /// (four thermometers, one stale, one failing) and an address where nothing answers.
    func test07ThermoGatewaysAndHiding() throws {
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["THERMO_GATEWAY_URL"],
                                "THERMO_GATEWAY_URL not set: run through scripts/build.sh, which serves the fake gateway")
        let dead = try XCTUnwrap(ProcessInfo.processInfo.environment["THERMO_DEAD_URL"], "THERMO_DEAD_URL not set")
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = nil
        app.launchEnvironment["TOOLBOX_TOOL"] = "thermo"
        app.launchEnvironment["THERMO_UI_GATEWAYS"] = "\(url)|\(dead)"
        app.launch()
        let room = element("thermo-row-A4:C1:38:00:00:03")
        XCTAssertTrue(room.waitForExistence(timeout: 30), "fake gateway's thermometers missing")
        XCTAssertFalse(element("thermo-demo-banner").exists, "demo banner shown with gateways set")
        XCTAssertTrue(app.staticTexts["示範閘道"].exists, "gateway name missing")
        XCTAssertTrue(shows("40 分鐘前", in: room), "stale age missing: \(room.label)")
        XCTAssertTrue(shows("連線讀取失敗", in: element("thermo-row-A4:C1:38:00:00:04")), "thermometer error missing")
        XCTAssertTrue(element("thermo-gateway-error").waitForExistence(timeout: 30), "the dead gateway shows no error")
        snapshot("13-thermo-gateways")
        room.tap()
        XCTAssertTrue(element("thermo-summary").waitForExistence(timeout: 15), "history from the fake gateway missing")
        snapshot("14-thermo-gateway-chart")
        let hide = app.switches["thermo-hide"]
        for _ in 0..<6 where !hide.isHittable {
            app.swipeUp()
        }
        hide.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(poll(timeout: 5) { (hide.value as? String) == "1" }, "hide switch did not turn on")
        app.navigationBars.buttons.firstMatch.tap()
        let hidden = element("thermo-hidden-group")
        XCTAssertTrue(hidden.waitForExistence(timeout: 10), "hidden section missing")
        XCTAssertFalse(room.exists, "hidden thermometer still in its gateway's list")
        snapshot("15-thermo-hidden")
        element("thermo-settings").tap()
        XCTAssertTrue(element("thermo-gateways").waitForExistence(timeout: 10), "gateway settings did not open")
        snapshot("16-thermo-settings")
    }

    private var thermoTab: XCUIElement { app.tabBars.buttons["溫濕度"] }

    /// A list row's text: SwiftUI exposes it either in the row's own label or as static texts.
    private func shows(_ text: String, in row: XCUIElement) -> Bool {
        row.label.contains(text) || row.staticTexts[text].exists
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return condition()
    }
}
