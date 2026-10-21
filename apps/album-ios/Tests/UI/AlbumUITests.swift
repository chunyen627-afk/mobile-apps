import XCTest
import UIKit

final class AlbumUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testReselectReplayRelaunchAndExplicitRefresh() {
        for pass in 0..<3 {
            if pass > 0 {
                app.buttons["勾選 測試照片"].tap()
                app.buttons["勾選 測試照片"].tap()
            }
            app.buttons["開始播放"].tap()
            let play = app.buttons["播放 4 個項目"]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            if pass > 0 { XCTAssertTrue(savedNote.waitForExistence(timeout: 3)) }
            capture("scan-pass-\(pass)")
            play.tap()
            XCTAssertTrue(app.buttons["leavePlayer"].waitForExistence(timeout: 5))
            app.buttons["leavePlayer"].tap()
            XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 5))
        }
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 15))
        app.buttons["開始播放"].tap()
        XCTAssertTrue(savedNote.waitForExistence(timeout: 5))
        capture("scan-restored-after-relaunch")
        app.buttons["重新掃描"].tap()
        XCTAssertTrue(app.buttons["播放 4 個項目"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "清單已儲存")).firstMatch.exists)
    }

    func testPhotoBufferAndAutomaticControlsAcrossFastSlides() {
        app.buttons["勾選 測試影片"].tap()
        app.buttons["開始播放"].tap()
        XCTAssertTrue(app.buttons["播放 3 個項目"].waitForExistence(timeout: 10))
        app.buttons["播放 3 個項目"].tap()
        XCTAssertTrue(app.images["displayedPhoto"].waitForExistence(timeout: 5))
        capture("photo-controls-visible")
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        XCTAssertTrue(app.images["displayedPhoto"].exists)
        XCTAssertFalse(app.staticTexts["讀取中…"].exists)
        capture("photo-controls-hidden-after-fast-slides")
        centerTap()
        XCTAssertTrue(app.buttons["leavePlayer"].waitForExistence(timeout: 2))
        app.buttons["暫停"].tap()
        app.buttons["下一個"].tap()
        XCTAssertTrue(app.images["displayedPhoto"].exists)
        XCTAssertFalse(app.staticTexts["讀取中…"].exists)
        capture("photo-held-during-manual-switch")
        XCUIDevice.shared.orientation = .landscapeLeft
        capture("photo-landscape")
    }

    func testVideoFillFitHideRotateAndSeek() {
        app.buttons["勾選 測試照片"].tap()
        app.buttons["開始播放"].tap()
        XCTAssertTrue(app.buttons["播放 1 個項目"].waitForExistence(timeout: 10))
        app.buttons["播放 1 個項目"].tap()
        XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 8))
        capture("video-fill-portrait-controls")
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        assertVideoBands(dark: false)
        capture("video-fill-portrait-hidden")
        centerTap()
        XCTAssertTrue(app.buttons["完整顯示影片"].waitForExistence(timeout: 2))
        app.buttons["完整顯示影片"].tap()
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        assertVideoBands(dark: true)
        capture("video-fit-portrait")
        centerTap()
        app.buttons["填滿螢幕（會裁切邊緣）"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        centerTap()
        XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 3))
        app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.3)
        capture("video-fill-landscape-seek")
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        assertVideoBands(dark: false)
        capture("video-fill-landscape-hidden")
    }

    private var savedNote: XCUIElement { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "使用已儲存清單")).firstMatch }
    private func centerTap() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func capture(_ name: String) {
        // XCUITest can report idle before UIKit's rotation/AVPlayerLayer transition has settled.
        Thread.sleep(forTimeInterval: 0.8)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertVideoBands(dark: Bool) {
        let screenshot = XCUIScreen.main.screenshot().image
        let small = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            screenshot.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(small.cgImage!, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        for row in [4, 11] {
            let offset = (row * 16 + 8) * 4
            let brightness = pixels[offset..<offset + 3].map(Int.init).max()!
            if dark { XCTAssertLessThan(brightness, 12, "Fit must preserve the complete 16:9 frame with letterboxing") }
            else { XCTAssertGreaterThan(brightness, 40, "Fill must render video beyond the center without app-imposed black bands") }
        }
    }
}
