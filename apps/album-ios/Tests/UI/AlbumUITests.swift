import XCTest
import UIKit

final class AlbumUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = "1"
        // An old saved crop preference must no longer affect playback.
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-cropVideoToFill", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 60))
    }

    override func tearDownWithError() throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func testReselectReplayRelaunchAndExplicitRefresh() {
        for pass in 0..<3 {
            if pass > 0 {
                app.buttons["勾選 測試影片"].tap()
            }
            app.buttons["開始播放"].tap()
            let play = app.buttons[pass == 1 ? "播放 3 個項目" : "播放 4 個項目"]
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

    func testVideoAlwaysFitsHideRotateAndSeek() {
        app.buttons["勾選 測試照片"].tap()
        app.buttons["開始播放"].tap()
        XCTAssertTrue(app.buttons["播放 1 個項目"].waitForExistence(timeout: 10))
        app.buttons["播放 1 個項目"].tap()
        XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 8))
        capture("video-fit-portrait-default")
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        assertVideoFits(aspect: 16.0 / 9.0)
        capture("video-fit-portrait")
        centerTap()
        XCTAssertFalse(app.buttons["填滿螢幕（會裁切邊緣）"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        centerTap()
        XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 3))
        app.buttons["暫停"].tap()
        app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.3)
        let seekReached = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let parts = app.staticTexts["videoTime"].label.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return false }
            return (8...14).contains(parts[0] * 60 + parts[1])
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seekReached], timeout: 8), .completed, "The 36-second fixture must actually seek near 30%, not return to zero")
        capture("video-fit-landscape-seek")
        app.buttons["繼續"].tap()
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        assertVideoFits(aspect: 16.0 / 9.0)
        capture("video-fit-landscape-hidden")
    }

    func testDiagnosticsCanPrepareExportWithoutSMBTransfer() {
        app.buttons["診斷紀錄"].tap()
        XCTAssertTrue(app.buttons["標記剛剛發生問題"].waitForExistence(timeout: 3))
        app.buttons["標記剛剛發生問題"].tap()
        app.buttons["準備診斷檔"].tap()
        XCTAssertTrue(app.buttons["分享診斷檔"].waitForExistence(timeout: 5))
        capture("diagnostics-export-ready")
    }

    func testAVIPlaybackSeekPauseAndReopen() {
        app.terminate()
        app.launchEnvironment["LIGHTBOX_UI_AVI"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 30))
        app.buttons["勾選 測試照片"].tap()
        for pass in 0..<2 {
            if pass == 1 {
                app.terminate()
                app.launchEnvironment["LIGHTBOX_UI_MJPEG"] = "1"
                app.launch()
                XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 30))
                app.buttons["勾選 測試照片"].tap()
            }
            app.buttons["開始播放"].tap()
            XCTAssertTrue(app.buttons["播放 1 個項目"].waitForExistence(timeout: 10))
            // Also exercise explicitly refreshing the selected video folder.
            app.buttons["重新掃描"].tap()
            XCTAssertTrue(app.buttons["播放 1 個項目"].waitForExistence(timeout: 10))
            app.buttons["播放 1 個項目"].tap()
            XCTAssertTrue(app.otherElements["vlcVideoSurface"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 15))
            waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
            assertVideoFits(aspect: pass == 0 ? 16.0 / 9.0 : 4.0 / 3.0)
            capture("avi-fit-playing-\(pass)")
            centerTap()
            app.buttons["暫停"].tap()
            app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.5)
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let parts = app.staticTexts["videoTime"].label.split(separator: ":").compactMap { Int($0) }
                return parts.count == 2 && (12...18).contains(parts[0] * 60 + parts[1])
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 10), .completed)
            capture("avi-paused-seek-\(pass)")
            app.buttons["繼續"].tap()
            // Wait past the temporary seek display. This must be the decoder's
            // advancing clock, not merely the slider's requested position.
            Thread.sleep(forTimeInterval: 3.5)
            centerTap()
            let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let parts = app.staticTexts["videoTime"].label.split(separator: ":").compactMap { Int($0) }
                return parts.count == 2 && (17...24).contains(parts[0] * 60 + parts[1])
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 3), .completed)
            XCUIDevice.shared.orientation = .landscapeLeft
            centerTap()
            XCTAssertFalse(app.buttons["填滿螢幕（會裁切邊緣）"].exists)
            waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
            assertVideoFits(aspect: pass == 0 ? 16.0 / 9.0 : 4.0 / 3.0)
            capture("avi-landscape-fit-\(pass)")
            centerTap()
            app.buttons["leavePlayer"].tap()
            XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 5))
            XCUIDevice.shared.orientation = .portrait
        }
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

    private func assertVideoFits(aspect: CGFloat) {
        // Rotation/rendering can settle after XCUITest reports idle.
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            videoFits(aspect: aspect)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 5), .completed,
            "Video must reach the aspect-fit bounds, with black only outside the complete frame")
    }

    private func videoFits(aspect: CGFloat) -> Bool {
        let screenshot = XCUIScreen.main.screenshot().image
        let side = 128
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            screenshot.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(small.cgImage!, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        func brightness(_ x: CGFloat, _ y: CGFloat) -> Int {
            let col = min(side - 1, max(0, Int(x * CGFloat(side))))
            let row = min(side - 1, max(0, Int(y * CGFloat(side))))
            let offset = (row * side + col) * 4
            return pixels[offset..<offset + 3].map(Int.init).max()!
        }
        let screenAspect = screenshot.size.width / screenshot.size.height
        let width: CGFloat = min(1, aspect / screenAspect)
        let height: CGFloat = min(1, screenAspect / aspect)
        let x = (1 - width) / 2, y = (1 - height) / 2
        // Sample inside all four edges: a blank or undersized frame must fail.
        let lit = [brightness(x + width * 0.03, 0.5), brightness(x + width * 0.97, 0.5),
                   brightness(0.5, y + height * 0.03), brightness(0.5, y + height * 0.97)]
        guard lit.allSatisfy({ $0 > 40 }) else { return false }
        if x > 0.02 { return brightness(x / 2, 0.5) < 12 && brightness(1 - x / 2, 0.5) < 12 }
        if y > 0.02 { return brightness(0.5, y / 2) < 12 && brightness(0.5, 1 - y / 2) < 12 }
        return true
    }
}
