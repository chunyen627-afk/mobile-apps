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
        XCTAssertTrue(albumTab.exists && minerTab.exists && deskTab.exists, "tab bar does not list all three tools")
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
