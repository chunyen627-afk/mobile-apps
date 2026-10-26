import XCTest

// Drives the real app on a simulator against the fake helper that scripts/build.sh runs on the
// Mac's loopback (the real HTTP, auth and file parsers over hand-written fixtures). Address,
// port and token come in through TEST_RUNNER_ environment variables; none is written here.
// Each screen is kept as a screenshot.
final class DeskRemoteUITests: XCTestCase {
    private var app: XCUIApplication!
    private let claudeA = "local_11111111-1111-4111-8111-111111111111"
    private let claudeB = "local_22222222-2222-4222-8222-222222222222"
    private let claudeC = "local_33333333-3333-4333-8333-333333333333"
    private let claudeArchived = "local_44444444-4444-4444-8444-444444444444"
    private let codexX = "0a000000-0000-4000-8000-000000000001"
    private let codexY = "0a000000-0000-4000-8000-000000000002"
    private let codexGuardian = "0a000000-0000-4000-8000-000000000003"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - PC list and form

    func test01EmptyState() throws {
        launch(pc: nil)
        XCTAssertTrue(element("pc-empty").waitForExistence(timeout: 10), "empty state missing")
        XCTAssertTrue(element("pc-add").exists, "add button missing")
        snapshot("01-empty")
    }

    func test02FormRejectsBadAddress() throws {
        launch(pc: nil)
        openAddForm()
        type("Office", into: app.textFields["pc-name"])
        type("http://bad", into: app.textFields["pc-host"])
        let problem = element("pc-form-problem")
        XCTAssertTrue(waitFor(problem, labelContains: "不要加 http://", timeout: 5), "bad address shows no problem: \(problem.label)")
        XCTAssertFalse(app.buttons["pc-save"].isEnabled, "save must stay disabled")
        snapshot("02-form-invalid")
    }

    func test03AddPCThroughForm() throws {
        let helper = try helperSettings()
        launch(pc: nil)
        openAddForm()
        type("Office", into: app.textFields["pc-name"])
        type(helper.host, into: app.textFields["pc-host"])
        let port = app.textFields["pc-port"]
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + helper.port)
        type(helper.token, into: app.secureTextFields["pc-token"])
        let save = app.buttons["pc-save"]
        XCTAssertTrue(poll(timeout: 5) { save.isEnabled }, "save stays disabled; problem: \(element("pc-form-problem").label)")
        snapshot("03a-form-filled")
        save.tap()
        let row = element("pc-row-Office")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "saved PC is not listed")
        XCTAssertTrue(waitFor(row, labelContains: "連線正常", timeout: 15), "row says \(row.label)")
        XCTAssertTrue(row.label.contains("閒置 7 分鐘"), "presence missing: \(row.label)")
        snapshot("03-pc-list")
    }

    func test04PCDetail() throws {
        try launchWithHelper()
        openPC()
        XCTAssertTrue(waitFor(element("pc-presence"), labelContains: "閒置 7 分鐘", timeout: 10), "presence not shown")
        XCTAssertTrue(waitFor(element("app-row-claude"), labelContains: "桌面版開著", timeout: 5),
                      "Claude row says \(element("app-row-claude").label)")
        XCTAssertTrue(element("app-row-codex").exists, "Codex row missing")
        snapshot("04-pc-detail")
    }

    // MARK: - Conversations

    func test05ClaudeSessions() throws {
        try launchWithHelper()
        openSessions("claude")
        let a = element("session-row-\(claudeA)"), b = element("session-row-\(claudeB)"), c = element("session-row-\(claudeC)")
        XCTAssertTrue(a.waitForExistence(timeout: 10), "conversation A missing")
        XCTAssertTrue(b.exists && c.exists, "conversations B or C missing")
        XCTAssertFalse(element("session-row-\(claudeArchived)").exists, "archived conversation must be hidden")
        XCTAssertTrue(a.frame.minY < b.frame.minY && b.frame.minY < c.frame.minY, "not newest first")
        XCTAssertTrue(waitFor(a, labelContains: "最近有更新", timeout: 5), "A says \(a.label)")
        XCTAssertTrue(a.label.contains("demo-app"), "folder missing: \(a.label)")
        XCTAssertTrue(waitFor(b, labelContains: "需要處理", timeout: 5), "B says \(b.label)")
        XCTAssertTrue(waitFor(element("sessions-warning"), labelContains: "1 個檔案無法解析", timeout: 5), "warning missing")
        snapshot("05-claude-sessions")
    }

    func test06ChatShowsTranscriptAndLiveEvents() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "reply missing")
        // The chat is a lazy stack scrolled to the bottom: earlier rows are revealed by scrolling.
        XCTAssertTrue(reveal(element("tool-Bash")), "Bash tool row missing")
        XCTAssertTrue(reveal(element("tool-Read")), "Read tool row missing")
        XCTAssertTrue(reveal(text("請整理 README 的安裝段落")), "user message missing")
        XCTAssertFalse(text("internal note the user never typed").exists, "injected text must be hidden")
        XCTAssertFalse(text("subagent text").exists, "subagent text must be hidden")
        snapshot("06a-chat")
        // The fake helper appends two lines a few seconds after the conversation is first opened;
        // a new row scrolls the chat to the bottom.
        XCTAssertTrue(text("已加上解除安裝").waitForExistence(timeout: 25), "live reply did not arrive")
        XCTAssertTrue(reveal(text("再加上解除安裝的步驟。")), "live user line did not arrive")
        XCTAssertTrue(element("input-bar").exists, "input bar missing")
        snapshot("06-chat-live")
    }

    func test07ToolOutputExpands() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        let tool = element("tool-Read")
        XCTAssertTrue(reveal(tool), "Read tool row missing")
        tool.tap()
        let output = element("tool-output")
        XCTAssertTrue(output.waitForExistence(timeout: 5), "tool output did not expand")
        XCTAssertFalse(output.label.contains("第 120 行"), "output should start shortened")
        let full = element("tool-load-full")
        XCTAssertTrue(reveal(full), "load-full button missing")
        full.tap()
        XCTAssertTrue(waitFor(output, labelContains: "第 120 行", timeout: 10), "full output not loaded")
        snapshot("07-tool-expanded")
    }

    func test08PermissionCard() throws {
        try launchWithHelper()
        openChat("claude", claudeB)
        let card = element("prompt-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "permission card missing")
        XCTAssertTrue(card.label.contains("要求權限：編輯"), "card says \(card.label)")
        XCTAssertTrue(card.label.contains("請先在電腦上"), "read-only note missing: \(card.label)")
        snapshot("08-permission-card")
    }

    func test09CodexListAndChat() throws {
        try launchWithHelper()
        openSessions("codex")
        let x = element("session-row-\(codexX)")
        XCTAssertTrue(x.waitForExistence(timeout: 10), "Codex thread X missing")
        XCTAssertTrue(element("session-row-\(codexY)").exists, "Codex thread Y missing")
        XCTAssertFalse(element("session-row-\(codexGuardian)").exists, "approval sub-thread must be hidden")
        XCTAssertTrue(x.label.contains("回覆 A1") && x.label.contains("代我核准"), "X says \(x.label)")
        snapshot("09a-codex-sessions")
        x.tap()
        XCTAssertTrue(text("有 README.md 和 main.c 兩個檔案。").waitForExistence(timeout: 10), "Codex reply missing")
        XCTAssertTrue(reveal(element("tool-指令")), "Codex command row missing")
        XCTAssertTrue(reveal(text("測試：請回覆 A1")), "Codex user message missing")
        snapshot("09-codex-chat")
    }

    // MARK: - Failures

    func test10WrongToken() throws {
        let helper = try helperSettings()
        launch(pc: "示範電腦|\(helper.host)|\(helper.port)|wrong-token-wrong-token-wrong-token-0")
        let row = element("pc-row-示範電腦")
        XCTAssertTrue(waitFor(row, labelContains: "連線密碼不正確", timeout: 15), "row says \(row.label)")
        snapshot("10-wrong-token")
    }

    func test11UnreachablePC() throws {
        let helper = try helperSettings()
        let dead = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_DEAD_PORT"], "DESK_DEAD_PORT not set")
        launch(pc: "關機的電腦|\(helper.host)|\(dead)|\(helper.token)")
        let row = element("pc-row-關機的電腦")
        XCTAssertTrue(waitFor(row, labelContains: "無法連線", timeout: 20), "row says \(row.label)")
        snapshot("11-unreachable")
    }

    // MARK: - Helpers

    private struct Helper {
        let host: String
        let port: String
        let token: String
    }

    private func helperSettings() throws -> Helper {
        let environment = ProcessInfo.processInfo.environment
        func value(_ key: String) throws -> String {
            try XCTUnwrap(environment[key], "\(key) not set: run through scripts/build.sh, which serves the fake helper")
        }
        return Helper(host: try value("DESK_HELPER_HOST"), port: try value("DESK_HELPER_PORT"),
                      token: try value("DESK_HELPER_TOKEN"))
    }

    private func launch(pc: String?) {
        app = XCUIApplication()
        app.launchEnvironment["DESK_UI_TEST"] = "1"
        if let pc { app.launchEnvironment["DESK_UI_PC"] = pc }
        app.launch()
    }

    private func launchWithHelper() throws {
        let helper = try helperSettings()
        launch(pc: "示範電腦|\(helper.host)|\(helper.port)|\(helper.token)")
    }

    private func openAddForm() {
        let add = element("pc-add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "add button missing")
        add.tap()
        XCTAssertTrue(app.textFields["pc-name"].waitForExistence(timeout: 5), "form did not open")
    }

    private func openPC() {
        let row = element("pc-row-示範電腦")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "preset PC missing")
        row.tap()
    }

    private func openSessions(_ app: String) {
        openPC()
        let row = element("app-row-\(app)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(app) row missing")
        row.tap()
    }

    private func openChat(_ app: String, _ id: String) {
        openSessions(app)
        let row = element("session-row-\(id)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "conversation \(id) missing")
        row.tap()
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "field missing")
        field.tap()
        field.typeText(text)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func text(_ fragment: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
    }

    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) {
            element.exists && (element.label.contains(text) || ((element.value as? String)?.contains(text) ?? false))
        }
    }

    private func reveal(_ element: XCUIElement) -> Bool {
        let visible = { element.exists && element.isHittable }
        if poll(timeout: 2, visible) { return true }
        for _ in 0 ..< 4 {
            app.swipeDown()
            if poll(timeout: 1, visible) { return true }
        }
        for _ in 0 ..< 8 {
            app.swipeUp()
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
