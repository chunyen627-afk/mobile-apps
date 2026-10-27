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
    private let claudeQuestion = "local_66666666-6666-4666-8666-666666666666"
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
        snapshot("05-claude-sessions")
        XCTAssertTrue(b.exists && c.exists, "conversations B or C missing")
        XCTAssertFalse(element("session-row-\(claudeArchived)").exists, "archived conversation must be hidden")
        XCTAssertTrue(a.frame.minY < b.frame.minY && b.frame.minY < c.frame.minY, "not newest first")
        XCTAssertTrue(waitFor(a, labelContains: "最近有更新", timeout: 5), "A says \(a.label)")
        XCTAssertTrue(a.label.contains("demo-app"), "folder missing: \(a.label)")
        XCTAssertTrue(waitFor(b, labelContains: "需要處理", timeout: 5), "B says \(b.label)")
        let warning = element("sessions-warning")
        XCTAssertTrue(waitFor(warning, labelContains: "1 個檔案無法解析", timeout: 5),
                      "warning missing: exists=\(warning.exists) label=\(warning.label); texts: "
                      + app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | "))
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
        XCTAssertTrue(element("chat-input").exists, "input box missing")
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
        XCTAssertTrue(waitFor(element("prompt-text"), labelContains: "要求權限：編輯", timeout: 5),
                      "card says \(element("prompt-text").label)")
        XCTAssertTrue(element("prompt-allow").exists && element("prompt-deny").exists, "answer buttons missing")
        XCTAssertFalse(text("永遠允許").exists, "the phone must not offer a broader permission")
        snapshot("08-permission-card")
    }

    func test09CodexListAndChat() throws {
        try launchWithHelper()
        openSessions("codex")
        let x = element("session-row-\(codexX)")
        XCTAssertTrue(x.waitForExistence(timeout: 10), "Codex thread X missing")
        XCTAssertTrue(element("session-row-\(codexY)").exists, "Codex thread Y missing")
        XCTAssertFalse(element("session-row-\(codexGuardian)").exists, "approval sub-thread must be hidden")
        XCTAssertTrue(x.label.contains("回覆 A1") && x.label.contains("demo-app"), "X says \(x.label)")
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

    // MARK: - Driving the PC (fake helper)

    func test12PermissionAllowOnce() throws {
        try launchWithHelper()
        openChat("claude", claudeB)
        let allow = element("prompt-allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "allow button missing")
        allow.tap()
        // The question goes away once the PC answered it, and the conversation carries on.
        XCTAssertTrue(text("已補上分號並存檔（示範）").waitForExistence(timeout: 20), "answer did not reach the PC")
        XCTAssertTrue(poll(timeout: 10) { !self.element("prompt-card").exists }, "card stayed after answering")
        XCTAssertFalse(element("open-on-pc").exists, "an answered conversation must not ask to be opened on the PC")
        snapshot("12-permission-answered")
    }

    func test13SendMessage() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        // A vertical TextField is a text view to XCUITest, so look it up by identifier only.
        let input = element("chat-input")
        XCTAssertTrue(input.waitForExistence(timeout: 5), "input box missing")
        input.tap()
        input.typeText("please check again")
        snapshot("13a-typed")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(text("（示範）收到：please check again").waitForExistence(timeout: 25), "reply to the sent message missing")
        XCTAssertTrue(poll(timeout: 10) { !self.element("pending-bubble").exists }, "pending bubble stayed after the transcript had it")
        XCTAssertTrue(text("please check again").exists, "sent message not in the transcript")
        snapshot("13-sent")
    }

    func test14BusyPCAsksBeforeSending() throws {
        let helper = try helperSettings()
        let busy = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_BUSY_PORT"], "DESK_BUSY_PORT not set")
        launch(pc: "示範電腦|\(helper.host)|\(busy)|\(helper.token)")
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        let input = element("chat-input")
        input.tap()
        input.typeText("send while busy")
        app.buttons["chat-send"].tap()
        let sendAnyway = app.alerts.buttons["仍要送出"]
        XCTAssertTrue(sendAnyway.waitForExistence(timeout: 10), "no confirmation while someone uses the PC")
        XCTAssertTrue(app.alerts.firstMatch.label.contains("電腦有人在用"), "alert says \(app.alerts.firstMatch.label)")
        snapshot("14a-busy-confirm")
        sendAnyway.tap()
        XCTAssertTrue(text("（示範）收到：send while busy").waitForExistence(timeout: 25), "forced send did not arrive")
        snapshot("14-busy-sent")
    }

    func test15NewCodexConversation() throws {
        try launchWithHelper()
        openSessions("codex")
        let new = element("new-session")
        XCTAssertTrue(new.waitForExistence(timeout: 10), "new conversation button missing")
        new.tap()
        let field = element("new-session-text")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "new conversation sheet missing")
        field.tap()
        field.typeText("look at README")
        snapshot("15a-new-session")
        app.buttons["new-session-send"].tap()
        XCTAssertTrue(app.navigationBars["look at README"].waitForExistence(timeout: 25), "did not open the new conversation")
        XCTAssertTrue(text("（示範）新對話收到：look at README").waitForExistence(timeout: 20), "new conversation reply missing")
        snapshot("15-new-session-chat")
    }

    func test16AnswerOptionQuestion() throws {
        try launchWithHelper()
        openChat("claude", claudeQuestion)
        let card = element("question-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "question card missing")
        XCTAssertFalse(element("chat-working").exists, "a conversation waiting on the person is not 'working'")
        snapshot("16a-question-card")
        let submit = element("question-submit")
        XCTAssertTrue(reveal(submit), "submit button missing")
        XCTAssertFalse(submit.isEnabled, "submit must wait until every question is answered")
        for id in ["question-option-0-藍綠部署", "question-option-1-ntfy", "question-option-1-Email"] {
            let option = element(id)
            XCTAssertTrue(reveal(option), "\(id) missing")
            option.tap()
        }
        XCTAssertTrue(reveal(submit) && submit.isEnabled, "submit stays disabled after answering")
        snapshot("16b-question-chosen")
        submit.tap()
        XCTAssertTrue(text("（示範）收到選擇：藍綠部署／ntfy、Email").waitForExistence(timeout: 25), "answer did not reach the PC")
        XCTAssertTrue(poll(timeout: 10) { !self.element("question-card").exists }, "card stayed after answering")
        snapshot("16-question-answered")
    }

    func test17QuickReply() throws {
        try launchWithHelper()
        openChat("claude", claudeC)
        let reply = element("quick-reply-好，繼續")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "quick reply missing")
        XCTAssertFalse(element("quick-reply-commit").exists, "app actions are not quick replies")
        snapshot("17a-quick-replies")
        reply.tap()
        XCTAssertTrue(text("（示範）收到：好，繼續寫下週計畫。").waitForExistence(timeout: 25), "quick reply was not sent")
        XCTAssertTrue(poll(timeout: 10) { !self.element("quick-reply-好，繼續").exists }, "quick replies stayed after use")
        snapshot("17-quick-reply-sent")
    }

    // MARK: - Administrator approval (elevate)

    func test18ElevateApproveWithKey() throws {
        let helper = try helperSettings()
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_ELEVATE_KEY"], "DESK_ELEVATE_KEY not set")
        launch(pc: "示範電腦|\(helper.host)|\(helper.port)|\(helper.token)|\(key)")
        let row = element("pc-row-示範電腦")
        XCTAssertTrue(waitFor(row, labelContains: "2 個管理員權限請求", timeout: 15), "row says \(row.label)")
        row.tap()
        let content = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'elevate-content' AND label CONTAINS 'Restart-Service'")).firstMatch
        XCTAssertTrue(reveal(content), "the waiting command is not shown")
        snapshot("18a-elevate-waiting")
        let allow = app.buttons.matching(identifier: "elevate-allow").firstMatch
        XCTAssertTrue(reveal(allow) && allow.isEnabled, "allow must be enabled with this PC's key")
        allow.tap()
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'elevate-result' AND label CONTAINS '結束碼 0'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15) || reveal(result), "the approved command did not run")
        XCTAssertFalse(content.exists, "the approved request is still waiting")
        snapshot("18-elevate-approved")
    }

    func test19ElevateWithoutKeyCanOnlyDeny() throws {
        try launchWithHelper()
        openPC()
        let card = element("elevate-card")
        XCTAssertTrue(reveal(card), "the remaining request is not shown")
        XCTAssertTrue(reveal(element("elevate-no-key")), "missing-key note not shown")
        XCTAssertFalse(app.buttons.matching(identifier: "elevate-allow").firstMatch.isEnabled, "allow must be disabled without a key")
        snapshot("19a-elevate-no-key")
        let deny = app.buttons.matching(identifier: "elevate-deny").firstMatch
        XCTAssertTrue(reveal(deny), "deny missing")
        deny.tap()
        XCTAssertTrue(reveal(element("elevate-empty")), "the denied request is still waiting")
        snapshot("19-elevate-denied")
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
