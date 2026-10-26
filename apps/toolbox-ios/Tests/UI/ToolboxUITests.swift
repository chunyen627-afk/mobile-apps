import XCTest

// Drives the toolbox on a simulator: both tools are reachable from the tab bar, each keeps its own
// screen while the other is in use, and the last tool opens again after a relaunch. The album runs
// on its built-in simulator fixtures (LIGHTBOX_UI_TEST) and the miner on its offline demo, so no
// network or real device is involved. Each screen is kept as a screenshot.
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
        app.terminate()
    }

    private var albumTab: XCUIElement { app.tabBars.buttons["相簿"] }
    private var minerTab: XCUIElement { app.tabBars.buttons["礦機狀態"] }
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
        XCTAssertTrue(albumTab.exists && minerTab.exists, "tab bar does not list both tools")
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
}
