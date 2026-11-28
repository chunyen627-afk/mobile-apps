import XCTest

/// 模擬器 UI 測試：用示範資料啟動（不啟動藍牙、不要權限），檢查畫面並存截圖。
final class WatchLinkUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func visibleTexts(_ app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label).joined(separator: " | ")
    }

    func testMainScreenShowsDemoWeatherAndEvents() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["手錶連結"].waitForExistence(timeout: 15))
        shot("01-main")
        XCTAssertTrue(app.staticTexts["陣雨 22°C"].exists, "畫面文字：\(visibleTexts(app))")
        XCTAssertTrue(app.staticTexts["示範行程：週會"].exists, "畫面文字：\(visibleTexts(app))")
    }

    func testScrollToHelpSection() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["手錶連結"].waitForExistence(timeout: 15))
        app.swipeUp()
        shot("02-bottom")
        XCTAssertTrue(app.staticTexts["示範行程：晚餐"].exists || app.staticTexts["說明"].exists || app.staticTexts["說明".uppercased()].exists,
                      "畫面文字：\(visibleTexts(app))")
    }
}
