import XCTest

// Every tab and its main inner screens on an iPad simulator, portrait and landscape, for a look at
// the layout; run by the workflow's iPad job only (scripts/build.sh skips it on an iPhone). Each
// tool runs on its demo or fixture data: the album on its simulator fixtures, the miner on the fixture feed that
// scripts/build.sh serves (live mode, so the start/stop buttons show), the desk remote against
// the fake helper with a pop-up on the PC, the thermometers on their demo. Screenshots are named
// "ipad-...". A step that cannot be reached leaves a "missing" screenshot and the test goes on
// to the next tab.
final class IPadLayoutShots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
        settle()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "ipad-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The current screen in portrait, then in landscape, then back to portrait.
    private func bothOrientations(_ name: String) {
        XCUIDevice.shared.orientation = .portrait
        shot("\(name)-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("\(name)-landscape")
        XCUIDevice.shared.orientation = .portrait
        settle(1)
    }

    private func require(_ element: XCUIElement, _ timeout: TimeInterval, _ what: String) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        shot("missing-\(what)")
        XCTFail("\(what) did not appear")
        return false
    }

    /// Scrolls until the element can be tapped.
    private func reveal(_ element: XCUIElement, _ what: String) -> Bool {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeDown() }
        if element.exists && element.isHittable { return true }
        shot("missing-\(what)")
        XCTFail("\(what) not reachable")
        return false
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            settle(0.25)
        } while Date() < deadline
        return condition()
    }

    /// Launches the album and lets it come up before anything is asked of it: the very first
    /// query after the launch timed out on a loaded runner ("Timed out while evaluating UI
    /// query" on the start button, iPad run 42766832721, after the desk suite had run 28
    /// minutes), and a query that times out fails the test outright.
    private func launchAlbum() {
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = "1"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 60)
        settle(3)
    }

    /// Launches the album and lets it come up before anything is asked of it: the very first
    /// query after the launch timed out on a loaded runner ("Timed out while evaluating UI
    /// query" on the start button, iPad run 42766832721, after the desk suite had run 28
    /// minutes), and a query that times out fails the test outright.
    private func launchAlbum() {
        app.launchEnvironment["LIGHTBOX_UI_TEST"] = "1"
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 60)
        settle(3)
    }

    // MARK: - Album: folders, the scanned list, a photo, a video

    func test1Album() throws {
        launchAlbum()
        let start = app.buttons["開始播放"]
        guard require(start, 60, "album-start") else { return }
        bothOrientations("1a-album-folders")
        // Photos only: the video fixture unticked.
        app.buttons["勾選 測試影片"].tap()
        start.tap()
        let playPhotos = app.buttons["播放 3 個項目"]
        guard require(playPhotos, 15, "album-list") else { return }
        bothOrientations("1b-album-list")
        playPhotos.tap()
        guard require(app.images["displayedPhoto"], 10, "album-photo") else { return }
        shot("1c-album-photo-controls-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("1c-album-photo-controls-landscape")
        settle(8)
        shot("1c-album-photo-landscape")
        XCUIDevice.shared.orientation = .portrait
        shot("1c-album-photo-portrait")
    }

    func test1bAlbumVideo() throws {
        launchAlbum()
        let start = app.buttons["開始播放"]
        guard require(start, 60, "album-start") else { return }
        // Video only: the photo fixture unticked.
        app.buttons["勾選 測試照片"].tap()
        start.tap()
        let playVideo = app.buttons["播放 1 個項目"]
        guard require(playVideo, 15, "album-video-list") else { return }
        playVideo.tap()
        guard require(app.sliders["影片進度"], 10, "album-video") else { return }
        if app.buttons["暫停"].exists { app.buttons["暫停"].tap() }
        bothOrientations("1d-album-video-controls")
    }

    // MARK: - Miner: list, one machine, start/stop

    func test2Miner() throws {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["MINER_UI_SOURCE_URL"],
                                   "MINER_UI_SOURCE_URL not set: run through scripts/build.sh, which serves the miner fixtures")
        app.launchEnvironment["TOOLBOX_TOOL"] = "miner"
        app.launchArguments += ["-resumeLive", "NO"]
        app.launch()
        guard require(element("mode-banner"), 30, "miner-banner") else { return }
        guard require(element("machine-demo-rig-a"), 15, "miner-demo-row") else { return }
        bothOrientations("2a-miner-demo-list")
        // Live mode on the fixture feed, with a control password, so the start/stop buttons show.
        let settings = element("source-settings")
        guard reveal(settings, "miner-settings-button") else { return }
        settings.tap()
        let token = app.secureTextFields["control-token"]
        guard reveal(token, "miner-control-token") else { return }
        token.tap()
        token.typeText("ui-test-token")
        let save = element("control-token-save")
        guard reveal(save, "miner-token-save") else { return }
        save.tap()
        let field = app.textFields["source-url"]
        guard reveal(field, "miner-source-url") else { return }
        field.tap()
        if let old = field.value as? String, !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4))
        }
        field.typeText(source)
        bothOrientations("2b-miner-settings")
        let startLive = app.buttons["start-live"]
        guard reveal(startLive, "miner-start-live") else { return }
        startLive.tap()
        let row = element("machine-demo-rig-a")
        guard require(row, 20, "miner-live-row") else { return }
        settle(2)
        bothOrientations("2c-miner-list")
        row.tap()
        let stop = element("control-stop")
        guard require(stop, 15, "miner-detail") else { return }
        bothOrientations("2d-miner-detail")
        guard reveal(stop, "miner-stop-button") else { return }
        bothOrientations("2e-miner-control-buttons")
        stop.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "確定停止挖礦")).firstMatch
        guard require(confirm, 5, "miner-confirm") else { return }
        shot("2f-miner-confirm-stop-portrait")
    }

    // MARK: - Desk remote: PC page with a pop-up, conversations, the chat, a queued message

    func test3Desk() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["DESK_HELPER_HOST"], let port = environment["DESK_POPUP_PORT"],
              let token = environment["DESK_HELPER_TOKEN"] else {
            XCTFail("run through scripts/build.sh, which serves the desk remote's fake helpers")
            return
        }
        app.launchEnvironment["DESK_UI_TEST"] = "1"
        app.launchEnvironment["DESK_UI_PC"] = "示範電腦|\(host)|\(port)|\(token)"
        app.launch()
        let row = element("pc-row-示範電腦")
        guard require(row, 30, "desk-pc-row") else { return }
        _ = poll(timeout: 20) { row.label.contains("連線正常") }
        bothOrientations("3a-desk-pcs")
        row.tap()
        guard require(element("popup-card"), 15, "desk-popup-card") else { return }
        bothOrientations("3b-desk-pc-popup-card")
        let claude = element("app-row-claude")
        guard reveal(claude, "desk-claude-row") else { return }
        claude.tap()
        let session = element("session-row-local_11111111-1111-4111-8111-111111111111")
        guard require(session, 15, "desk-session-row") else { return }
        bothOrientations("3c-desk-conversations")
        session.tap()
        let input = element("chat-input")
        guard require(input, 15, "desk-chat-input") else { return }
        settle(2)
        bothOrientations("3d-desk-chat-with-popup")
        if element("popup-toggle").exists {
            element("popup-toggle").tap()
            bothOrientations("3e-desk-popup-opened")
            element("popup-toggle").tap()
        }
        input.tap()
        input.typeText("iPad layout check")
        bothOrientations("3f-desk-input-typed")
        app.buttons["chat-send"].tap()
        // The message waits as a queued bubble until the PC's transcript has it.
        if element("pending-bubble").waitForExistence(timeout: 5) {
            shot("3g-desk-queued-message-portrait")
        } else {
            shot("missing-desk-queued-message")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("3g-desk-after-send-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Thermometers: list, a thermometer, gateway settings, naming

    func test4Thermo() throws {
        app.launchEnvironment["TOOLBOX_TOOL"] = "thermo"
        app.launchEnvironment["THERMO_UI_TEST"] = "1"
        app.launch()
        // For the CI notice: the screen in points and pixels, and the app's window.
        let screen = XCUIScreen.main.screenshot().image
        print("IPAD-SCREEN points \(screen.size.width)x\(screen.size.height) scale \(screen.scale) "
              + "pixels \(screen.size.width * screen.scale)x\(screen.size.height * screen.scale) "
              + "app-window \(app.windows.firstMatch.frame.size.width)x\(app.windows.firstMatch.frame.size.height)")
        let row = element("thermo-row-A4:C1:38:00:00:01")
        guard require(row, 30, "thermo-row") else { return }
        bothOrientations("4a-thermo-list")
        row.tap()
        guard require(element("thermo-summary"), 15, "thermo-summary") else { return }
        bothOrientations("4b-thermo-detail")
        let rename = element("thermo-rename")
        guard reveal(rename, "thermo-rename-row") else { return }
        rename.tap()
        guard require(app.alerts.firstMatch, 5, "thermo-rename-dialog") else { return }
        bothOrientations("4c-thermo-rename-dialog")
        app.alerts.firstMatch.buttons["取消"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        guard require(element("thermo-settings"), 10, "thermo-settings-button") else { return }
        element("thermo-settings").tap()
        guard require(app.segmentedControls["thermo-unit"], 10, "thermo-settings") else { return }
        bothOrientations("4d-thermo-settings")
        let gateways = element("thermo-gateways")
        guard reveal(gateways, "thermo-gateways") else { return }
        bothOrientations("4e-thermo-settings-gateways")
    }
}
