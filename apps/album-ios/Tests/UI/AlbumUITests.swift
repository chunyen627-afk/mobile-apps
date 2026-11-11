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

    /// Every failure keeps the screen it happened on ("fail-L<line>" in the screenshots).
    override func record(_ issue: XCTIssue) {
        var issue = issue
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "fail-L\(issue.sourceCodeContext.location?.lineNumber ?? 0)"
        shot.lifetime = .keepAlways
        issue.add(shot)
        super.record(issue)
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
        tapOverlay("暫停", until: app.buttons["繼續"])
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
        tapOverlay("暫停", until: app.buttons["繼續"])
        XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 3))
        app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.3)
        let seekReached = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let parts = app.staticTexts["videoTime"].label.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return false }
            return (8...14).contains(parts[0] * 60 + parts[1])
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [seekReached], timeout: 8), .completed, "The 36-second fixture must actually seek near 30%, not return to zero")
        capture("video-fit-landscape-seek")
        assertPausedVideoCanHideControls(aspect: 16.0 / 9.0, name: "native-paused-hidden")
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

    func testAVIPlaybackSeekPauseAndReopen() throws {
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
            // The test clip is 30 s long. The seek check used to come after a played-and-hidden
            // check, and on a busy runner those steps took the clip to its last frame (29.833 s)
            // before the pause: the seek to 15 s then showed "0:15" over the last frame and playback
            // never came back (toolbox runs 42511452483, 42970581456). Pause first, so the seek
            // starts from the first seconds of the clip.
            tapOverlay("暫停", until: app.buttons["繼續"])
            XCTAssertTrue(app.sliders["影片進度"].waitForExistence(timeout: 15))
            app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.5)
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                videoSeconds().map { (12...18).contains($0) } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 10), .completed, "player: \(playerDebug)")
            capture("avi-paused-seek-\(pass)")
            assertPausedVideoCanHideControls(aspect: pass == 0 ? 16.0 / 9.0 : 4.0 / 3.0, name: "avi-paused-hidden-\(pass)")
            let start = try XCTUnwrap(videoSeconds(), "no paused position; player: \(playerDebug)")
            app.buttons["繼續"].tap()
            let resumedAt = Date()
            // The decoder's advancing clock, not the slider's requested position (shown for up to
            // 3 s after 繼續), read from the player's debug line, which does not hide itself.
            // Ahead of where it was paused, and not ahead of the time really gone by.
            let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                guard let now = playerSeconds() else { return false }
                return now >= start + 2 && Double(now) <= Double(start) + Date().timeIntervalSince(resumedAt) + 2
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed,
                           "paused at \(start) s, \(Int(Date().timeIntervalSince(resumedAt))) s ago; player: \(playerDebug)")
            waitUntilGone(app.buttons["leavePlayer"], timeout: 12)  // 4 s hide timer; 8 s was once short on the iPhone runner (11/08)
            assertVideoFits(aspect: pass == 0 ? 16.0 / 9.0 : 4.0 / 3.0)
            capture("avi-fit-playing-\(pass)")
            XCUIDevice.shared.orientation = .landscapeLeft
            centerTap()
            XCTAssertFalse(app.buttons["填滿螢幕（會裁切邊緣）"].exists)
            waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
            assertVideoFits(aspect: pass == 0 ? 16.0 / 9.0 : 4.0 / 3.0)
            capture("avi-landscape-fit-\(pass)")
            XCUIDevice.shared.orientation = .portrait
            // The end of the clip: one video on its own starts over (PlayerModel: ended → show the
            // next, which is itself), and must not sit on its last frame.
            tapOverlay("暫停", until: app.buttons["繼續"])
            app.sliders["影片進度"].adjust(toNormalizedSliderPosition: 0.9)
            let nearEnd = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                videoSeconds().map { (24...29).contains($0) } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [nearEnd], timeout: 10), .completed, "player: \(playerDebug)")
            app.buttons["繼續"].tap()
            let looped = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                playerSeconds().map { $0 < 10 } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [looped], timeout: 20), .completed,
                           "the clip did not start over after its end; player: \(playerDebug)")
            capture("avi-started-over-\(pass)")
            tapOverlay("leavePlayer", until: app.buttons["開始播放"])
        }
    }

    func testPausedPhotoPinchPanResetAndTapGestures() {
        // Give explicit gestures time; auto-advance is covered by the separate fast-slide test.
        app.terminate()
        app.launchArguments += ["-photoInterval", "30"]
        app.launch()
        XCTAssertTrue(app.buttons["開始播放"].waitForExistence(timeout: 30))
        app.buttons["勾選 測試影片"].tap()
        app.buttons["開始播放"].tap()
        XCTAssertTrue(app.buttons["播放 3 個項目"].waitForExistence(timeout: 10))
        app.buttons["播放 3 個項目"].tap()
        let image = app.images["displayedPhoto"]
        let viewport = app.scrollViews["photoViewport"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        tapOverlay("暫停", until: app.buttons["繼續"])
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "測試照片 ")).firstMatch.label
        capture("photo-paused-before-pinch")
        XCTAssertTrue(app.buttons["繼續"].exists, "the slideshow did not pause before the pinch")
        pinchToZoom(viewport)
        capture("photo-paused-pinch-first")
        assertPhotoZoom { $0 > 150 }
        XCTAssertFalse(app.buttons["leavePlayer"].exists, "Zoom should hide chrome without a spurious single tap")
        capture("photo-paused-pinched")
        let beforePan = photoPixels()
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        capture("photo-paused-panned")
        XCTAssertNotEqual(beforePan, photoPixels(), "Dragging must change the rendered image, not merely a zoom value")
        centerTap()
        XCTAssertTrue(app.buttons["繼續"].exists)
        XCTAssertTrue(app.staticTexts[title].exists, "Panning must not turn the page")
        app.buttons["繼續"].tap()
        assertPhotoZoom { $0 == 100 }
        viewport.pinch(withScale: 2, velocity: 1)
        assertPhotoZoom { $0 == 100 }
        tapOverlay("暫停", until: app.buttons["繼續"])
        pinchToZoom(viewport)
        assertPhotoZoom { $0 > 150 }
        centerTap()
        app.buttons["下一個"].tap()
        assertPhotoZoom { $0 == 100 }
        XCTAssertFalse(app.staticTexts[title].exists)
        XCTAssertTrue(app.buttons["繼續"].exists, "Changing photos must keep the slideshow paused")
        // Wait for the replacement photo, whose loading uses a synthetic delay.
        Thread.sleep(forTimeInterval: 1)
        viewport.doubleTap()
        assertPhotoZoom { $0 > 150 }
        viewport.doubleTap()
        assertPhotoZoom { $0 == 100 }
        // At fit size, a horizontal swipe may navigate; at zoom size it must only pan.
        viewport.swipeRight()
        centerTap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)
        pinchToZoom(viewport)
        assertPhotoZoom { $0 > 150 }
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPhotoZoom { $0 == 100 }
        capture("photo-zoom-rotation-refit")
    }

    /// A pinch that enlarges. On the iPad simulator (Xcode 26.6) XCUITest's pinch with scale 2 and
    /// velocity 1 ended at scale 1 although the zoom began (traced on 11/08: "begin end 100%", no
    /// reset), so two other pinches are tried before the caller's check fails.
    private func pinchToZoom(_ viewport: XCUIElement) {
        let pinches: [(scale: CGFloat, velocity: CGFloat)] = [(2, 1), (3, 0.5), (4, 2)]
        for pinch in pinches {
            viewport.pinch(withScale: pinch.scale, velocity: pinch.velocity)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if photoZoomPercent() > 150 { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    private func photoZoomPercent() -> Int {
        let text = ((app.images["displayedPhoto"].value as? String) ?? "").split(separator: "%").first.map(String.init) ?? ""
        return Int(text.filter { $0.isNumber }) ?? 0
    }

    private func assertPhotoZoom(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping (Int) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            // "縮放 150%", then on the simulator a trace of what reset or ended the zoom.
            let text = ((app.images["displayedPhoto"].value as? String) ?? "").split(separator: "%").first.map(String.init) ?? ""
            guard let percent = Int(text.filter { $0.isNumber }) else { return false }
            return condition(percent)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 4), .completed,
                       "photo zoom: \(String(describing: app.images["displayedPhoto"].value))", file: file, line: line)
    }

    private func photoPixels() -> [UInt8] {
        let screenshot = XCUIScreen.main.screenshot().image
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(screenshot.cgImage!, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return pixels
    }

    private func assertPausedVideoCanHideControls(aspect: CGFloat, name: String) {
        XCTAssertTrue(app.buttons["繼續"].exists)
        let position = app.staticTexts["videoTime"].label
        tapCanvas()
        // The player says the controls are hidden before their fade-out ends, and on a loaded
        // iPad simulator the tree still listed the button after 2 s (toolbox run 42775759673:
        // "still shown after 2.0 s; player: ... controls=false"): six seconds covers the fade.
        waitUntilGone(app.buttons["leavePlayer"], timeout: 6)
        assertVideoFits(aspect: aspect)
        capture(name)
        Thread.sleep(forTimeInterval: 2)
        tapCanvas()
        XCTAssertTrue(app.buttons["繼續"].waitForExistence(timeout: 2))
        XCTAssertEqual(app.staticTexts["videoTime"].label, position, "Hiding controls must not resume a paused video")
    }

    private var playerDebug: String {
        let debug = app.staticTexts["playerDebug"]
        return debug.exists ? debug.label : "no debug state"
    }
    private var savedNote: XCUIElement { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "使用已儲存清單")).firstMatch }
    // Start each group of playing controls from a newly revealed overlay.
    // An exists snapshot can be true just before the four-second timer fires.
    private func centerTap() {
        if app.buttons["繼續"].exists { return } // Paused controls have no hide timer.
        waitUntilGone(app.buttons["leavePlayer"], timeout: 8)
        tapCanvas()
        // Photo single taps wait for the double-tap recognizer to fail. XCTest
        // returning from tap does not mean that delayed callback has executed.
        // On a busy runner the callback came later than 2 s, or the tap was lost (toolbox release
        // run 42191989395, 11/06): wait longer, then tap once more. Taps seconds apart are not a
        // double tap, and the overlay only hides itself 4 s after it shows.
        let leave = app.buttons["leavePlayer"]
        if !leave.waitForExistence(timeout: 5) {
            tapCanvas()
            XCTAssertTrue(leave.waitForExistence(timeout: 5), "the controls did not come back after two taps")
        }
    }
    /// Taps a button of the playing overlay, which hides itself 4 s after it shows. XCUITest's
    /// tap looks the button up again first, and on a busy runner that outlasted the 4 s, so the
    /// tap found nothing and failed the test (iPhone run 42459465153: "leavePlayer", no matches).
    /// Here the button's place is read while it is shown and the tap goes there; if the overlay
    /// had gone by then, the tap lands on the picture, which only shows it again, and the button
    /// is tapped once more. Done once `until` shows (a paused overlay has no timer).
    private func tapOverlay(_ name: String, until done: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            centerTap()
            // One look: `exists` and then `frame` looked twice, and the overlay hid in between
            // ("Failed to get matching snapshot" for 暫停, iPhone run 42970581456).
            guard let frame = (try? app.buttons[name].firstMatch.snapshot())?.frame else { continue }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            if done.waitForExistence(timeout: 5) { return }
        }
        XCTFail("tapping \(name) did not get to \(done); player: \(playerDebug)", file: file, line: line)
    }
    /// The player's position in seconds, read in one look: `exists` and then `label` would look
    /// twice, and the auto-hiding overlay can go in between.
    private func videoSeconds() -> Int? {
        guard let label = (try? app.staticTexts["videoTime"].firstMatch.snapshot())?.label else { return nil }
        let parts = label.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
    /// The position from the player's debug line ("time=15"), there whether or not the
    /// controls are shown.
    private func playerSeconds() -> Int? {
        guard let label = (try? app.staticTexts["playerDebug"].firstMatch.snapshot())?.label,
              let range = label.range(of: #"time=(\d+)"#, options: .regularExpression) else { return nil }
        return Int(label[range].dropFirst(5))
    }
    private func tapCanvas() { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "still shown after \(timeout) s; player: \(playerDebug)", file: file, line: line)
        if element.exists { capture("still-shown-line-\(line)") }
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
