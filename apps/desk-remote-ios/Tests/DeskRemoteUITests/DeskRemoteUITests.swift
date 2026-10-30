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
        XCTAssertTrue(waitFor(element("app-version"), labelContains: "App 版本 ", timeout: 5), "app version missing")
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
        XCTAssertTrue(element("app-row-claude").waitForExistence(timeout: 5), "Claude row missing")
        XCTAssertFalse(element("app-row-claude").label.contains("桌面版"),
                       "whether the window is open is not said: \(element("app-row-claude").label)")
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
        XCTAssertTrue(row.label.contains("重連 ZeroTier"), "row says \(row.label)")
        snapshot("11-unreachable")
        // The PC page spells out what to do; it keeps retrying on its own.
        row.tap()
        let error = element("pc-error")
        XCTAssertTrue(waitFor(error, labelContains: "ZeroTier 關掉再打開", timeout: 20), "page says \(error.label)")
        XCTAssertTrue(error.label.contains("每 5 秒自動重試"), "page says \(error.label)")
        snapshot("11b-unreachable-hint")
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
        let shown = reveal(content)
        snapshot("18a-elevate-waiting")
        XCTAssertTrue(shown, "the waiting command is not shown; texts: "
                      + app.staticTexts.allElementsBoundByIndex.prefix(20).map(\.label).joined(separator: " | "))
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
        // Finished requests can be cleared off the page (they piled up, 10/28) and stay cleared.
        let clear = app.buttons.matching(identifier: "elevate-clear").firstMatch
        XCTAssertTrue(reveal(clear), "no clear button under the finished requests")
        clear.tap()
        XCTAssertTrue(poll(timeout: 5) { !self.element("elevate-result").exists }, "finished requests still shown")
        XCTAssertFalse(clear.exists, "the clear button stays with nothing to clear")
        RunLoop.current.run(until: Date().addingTimeInterval(7))  // the page re-reads every 5 s
        XCTAssertFalse(element("elevate-result").exists, "a refresh brought them back")
        snapshot("19b-elevate-cleared")
    }

    /// A message's long-press menu offers copy-all and "select text", which opens the whole message
    /// in a text view where part of it can be selected. A long press there selects one word and
    /// shows the word menu (Look Up / Translate, found in CI 10/27); SwiftUI's own text selection
    /// on iOS only copies everything (reported 10/27).
    func test20ReplyTextSelectsPart() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        let reply = text("整理好了，安裝段落改成三步")
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "reply missing")
        reply.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["拷貝全部"].waitForExistence(timeout: 5), "copy-all missing from the menu")
        let select = app.buttons["選取文字"]
        XCTAssertTrue(select.exists, "select-text missing from the menu")
        snapshot("20a-message-menu")
        select.tap()
        let sheet = element("select-text")
        XCTAssertTrue(waitFor(sheet, labelContains: "整理好了，安裝段落改成三步", timeout: 5), "select-text sheet missing")
        sheet.press(forDuration: 1.2)
        let wordMenu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["查詢", "翻譯", "Look Up", "Translate", "全選", "Select All"])).firstMatch
        XCTAssertTrue(wordMenu.waitForExistence(timeout: 5),
                      "no partial-selection menu; menu: " + app.menuItems.allElementsBoundByIndex.prefix(8).map(\.label).joined(separator: " | "))
        snapshot("20-select-part")
        element("select-done").tap()
        XCTAssertTrue(poll(timeout: 5) { !self.element("select-text").exists }, "sheet did not close")
    }

    func test21ChatShowsModelContextAndSwitchesTheModel() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        let bar = element("chat-meta")
        XCTAssertTrue(waitFor(bar, labelContains: "Opus 5.5・高・上下文 18%", timeout: 10), "meta bar says \(bar.label)")
        snapshot("21a-chat-meta")
        bar.tap()
        XCTAssertTrue(waitFor(element("meta-context"), labelContains: "18%（18.3 萬 / 100 萬）", timeout: 5),
                      "context detail missing")
        let weekly = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'usage-claude' AND label CONTAINS '每週'")).firstMatch
        XCTAssertTrue(waitFor(weekly, labelContains: "每週 46%・週日上午11:00 重設", timeout: 10),
                      "weekly limit missing: \(said(weekly))")
        snapshot("21b-model-sheet")
        let sonnet = element("model-Sonnet 5.5")
        XCTAssertTrue(revealInSheet(sonnet), "model choices missing")
        sonnet.tap()
        XCTAssertTrue(revealInSheet(element("model-busy")), "no switch progress shown")
        XCTAssertTrue(waitFor(element("model-busy"), labelContains: "已切換為 Sonnet 5.5", timeout: 20),
                      "switch did not finish: \(said(element("model-busy")))")
        XCTAssertTrue(waitFor(element("meta-model"), labelContains: "Sonnet 5.5", timeout: 30), "sheet still shows the old model")
        snapshot("21-model-switched")
        element("meta-done").tap()
        XCTAssertTrue(waitFor(bar, labelContains: "Sonnet 5.5", timeout: 10), "meta bar says \(bar.label)")
    }

    func test22PCShowsPlanLimits() throws {
        try launchWithHelper()
        openPC()
        let claude = element("usage-claude"), codex = element("usage-codex")
        XCTAssertTrue(reveal(codex), "Codex limits missing")
        XCTAssertTrue(waitFor(codex, labelContains: "每週 5%", timeout: 5), "Codex says \(codex.label)")
        XCTAssertTrue(claude.exists && claude.label.contains("Claude"), "Claude limits missing: \(claude.label)")
        snapshot("22-pc-usage")
    }

    func test23StopARunningTurn() throws {
        try launchWithHelper()
        openChat("claude", claudeC)
        type("長任務：請慢慢整理", into: element("chat-input"))
        app.buttons["chat-send"].tap()
        let stop = app.buttons["chat-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 20), "no stop button while the turn runs")
        snapshot("23a-running")
        stop.tap()
        XCTAssertTrue(poll(timeout: 20) { self.element("chat-stop-state").exists || self.reveal(self.element("chat-stop-state")) },
                      "no stop progress shown")
        XCTAssertTrue(waitFor(element("chat-stop-state"), labelContains: "已停止", timeout: 20),
                      "stop did not finish: \(said(element("chat-stop-state")))")
        XCTAssertTrue(text("（已停止）").waitForExistence(timeout: 20), "the stopped turn is not in the transcript")
        snapshot("23-stopped")
    }

    func test24ScreenView() throws {
        try launchWithHelper()
        openPC()
        XCTAssertTrue(element("pc-presence").waitForExistence(timeout: 10), "PC state did not load")
        let row = element("pc-screen")
        XCTAssertTrue(reveal(row), "screen row missing")
        row.tap()
        XCTAssertTrue(element("screen-image").waitForExistence(timeout: 15), "the screen picture did not load")
        snapshot("24-screen")
    }

    /// The notification's link, handed in at launch (opened from outside, iOS first asks whether
    /// to open the app; the link's parsing has unit tests).
    func test25NotificationLinkOpensTheConversation() throws {
        let link = "deskremote://open?pc=%E7%A4%BA%E7%AF%84%E9%9B%BB%E8%85%A6&app=claude&session=\(claudeB)"
            + "&title=%E4%BF%AE%E6%AD%A3%E5%BB%BA%E7%BD%AE%E9%8C%AF%E8%AA%A4"
        try launchWithHelper(openURL: link)
        XCTAssertTrue(app.navigationBars["修正建置錯誤"].waitForExistence(timeout: 15), "the linked conversation did not open")
        // test12 already answered this conversation's question on the shared fake helper.
        XCTAssertTrue(text("要修改 main.c 第 42 行").waitForExistence(timeout: 15), "its transcript is not shown")
        snapshot("25-opened-from-link")
    }

    func test26EffortAndPermissionMode() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        let bar = element("chat-meta")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "meta bar missing")
        bar.tap()
        let effort = element("effort-超高")
        XCTAssertTrue(revealInSheet(effort), "effort choices missing")
        effort.tap()
        XCTAssertTrue(revealInSheet(element("effort-busy")), "no effort progress shown")
        XCTAssertTrue(waitFor(element("effort-busy"), labelContains: "推理強度已切換為 超高", timeout: 20),
                      "effort switch did not finish: \(said(element("effort-busy")))")
        let mode = element("mode-計畫")
        XCTAssertTrue(revealInSheet(mode), "mode choices missing")
        mode.tap()
        XCTAssertTrue(revealInSheet(element("mode-busy")), "no mode progress shown")
        XCTAssertTrue(waitFor(element("mode-busy"), labelContains: "權限模式已切換為 計畫", timeout: 20),
                      "mode switch did not finish: \(said(element("mode-busy")))")
        snapshot("26-effort-and-mode")
        // The mode row is at the top of the sheet: reopen the sheet rather than scroll back up
        // (a downward swipe at its top closes it).
        element("meta-done").tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "chat did not come back")
        bar.tap()
        XCTAssertTrue(waitFor(element("meta-permission"), labelContains: "計畫", timeout: 30),
                      "sheet still shows the old mode: \(said(element("meta-permission")))")
    }

    /// Codex thread Y has no turn on record (like one imported from another account): the bar
    /// says so instead of vanishing, and a mode picked there shows until a reply records one.
    func test27ImportedCodexThreadNoteAndModePick() throws {
        try launchWithHelper()
        openChat("codex", codexY)
        let bar = element("chat-meta")
        XCTAssertTrue(waitFor(bar, labelContains: "匯入的舊對話，回覆一次後才有資料", timeout: 10), "meta bar says \(said(bar))")
        snapshot("27a-imported-note")
        bar.tap()
        XCTAssertTrue(element("meta-note").waitForExistence(timeout: 5), "the sheet does not explain the missing data")
        let mode = element("mode-代我核准")
        XCTAssertTrue(revealInSheet(mode), "Codex mode choices missing")
        mode.tap()
        XCTAssertTrue(revealInSheet(element("mode-busy")), "no mode progress shown")
        XCTAssertTrue(waitFor(element("mode-busy"), labelContains: "下一則回覆起生效", timeout: 20),
                      "mode pick did not finish: \(said(element("mode-busy")))")
        element("meta-done").tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "chat did not come back")
        bar.tap()
        XCTAssertTrue(waitFor(element("meta-permission"), labelContains: "代我核准（下一則回覆起生效）", timeout: 30),
                      "sheet does not show the pick: \(said(element("meta-permission")))")
        snapshot("27-codex-mode-picked")
    }

    /// Coming into a desktop app that has no window on the PC opens it there, without a word.
    func test28ComingInOpensAClosedDesktopApp() throws {
        let helper = try helperSettings()
        let closed = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_CLOSED_PORT"], "DESK_CLOSED_PORT not set")
        XCTAssertEqual(codexWindowOpen(helper, port: closed), false, "the fake Codex should start with no window")
        launch(pc: "示範電腦|\(helper.host)|\(closed)|\(helper.token)")
        openSessions("codex")
        XCTAssertTrue(element("session-row-\(codexX)").waitForExistence(timeout: 10), "Codex conversations missing")
        XCTAssertTrue(poll(timeout: 20) { codexWindowOpen(helper, port: closed) == true }, "Codex was not opened on the PC")
        XCTAssertFalse(text("桌面版").exists, "the phone should not talk about the window")
        snapshot("28-codex-opened-quietly")
    }

    /// Two PCs on one plan: the PC whose own Codex limits are older shows the other's newer ones.
    func test29PCsOnOnePlanShowTheNewerLimits() throws {
        let helper = try helperSettings()
        let other = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_CLOSED_PORT"], "DESK_CLOSED_PORT not set")
        launch(pc: "示範電腦|\(helper.host)|\(helper.port)|\(helper.token);第二台|\(helper.host)|\(other)|\(helper.token)")
        XCTAssertTrue(element("pc-row-第二台").waitForExistence(timeout: 10), "second PC missing")
        openPC()
        let codex = element("usage-codex")
        XCTAssertTrue(reveal(codex), "Codex limits missing")
        XCTAssertTrue(waitFor(codex, labelContains: "每週 37%", timeout: 20), "Codex says \(codex.label)")
        XCTAssertTrue(waitFor(element("usage-source-codex"), labelContains: "來自第二台", timeout: 5),
                      "source says \(element("usage-source-codex").label)")
        snapshot("29-usage-from-the-other-pc")
    }

    /// The camera button (the simulator has no camera: UI tests get a made-up shot): the shot
    /// shows as the preview and goes out with the message.
    func test30CameraShotGoesOutWithTheMessage() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        let camera = element("chat-camera")
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "camera button missing")
        camera.tap()
        XCTAssertTrue(element("chat-photo-preview").waitForExistence(timeout: 5), "the shot is not shown")
        let input = element("chat-input")
        input.tap()
        input.typeText("camera shot")
        snapshot("30a-camera-shot")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(text("（示範）收到：camera shot").waitForExistence(timeout: 25), "the shot was not sent")
        XCTAssertFalse(element("chat-photo-preview").exists, "the preview should clear once sent")
        snapshot("30-camera-sent")
    }

    /// The microphone button (the simulator cannot speak: UI tests get a fixed phrase) puts the
    /// words into the box without the keyboard, after what was already typed.
    func test31MicrophoneTypesIntoTheBox() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        let mic = element("chat-mic")
        XCTAssertTrue(mic.waitForExistence(timeout: 5), "microphone button missing")
        let input = element("chat-input")
        input.tap()
        input.typeText("先打字，")
        mic.tap()
        XCTAssertTrue(waitFor(input, labelContains: "先打字，語音輸入測試", timeout: 5), "box says \(said(input))")
        XCTAssertTrue(poll(timeout: 5) { !self.app.keyboards.firstMatch.exists }, "the keyboard should go away")
        snapshot("31a-dictated")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(text("（示範）收到：先打字，語音輸入測試").waitForExistence(timeout: 25), "the dictated text was not sent")
        snapshot("31-dictated-sent")
    }

    /// A window that pops up on the PC (a firewall question kept messages from going through,
    /// 10/29) shows on the PC page and above the chat, and its button is pressed from the phone.
    func test32APopupOnThePCIsAnsweredFromThePhone() throws {
        let helper = try helperSettings()
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_POPUP_PORT"], "DESK_POPUP_PORT not set")
        launch(pc: "示範電腦|\(helper.host)|\(port)|\(helper.token)")
        openPC()
        let card = element("popup-card")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the pop-up is not on the PC page")
        XCTAssertTrue(text("電腦跳出視窗：Windows 安全性").exists, "the pop-up has no title")
        snapshot("32a-popup-on-pc-page")
        let row = element("app-row-claude")
        XCTAssertTrue(reveal(row), "Claude row missing")
        row.tap()
        let session = element("session-row-\(claudeA)")
        XCTAssertTrue(session.waitForExistence(timeout: 10), "conversation missing")
        session.tap()
        XCTAssertTrue(element("popup-card").waitForExistence(timeout: 15), "the pop-up is not above the chat")
        let allow = element("popup-button-允許")
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the pop-up's button is missing")
        allow.tap()
        let confirm = app.buttons["按「允許」"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "pressing was not confirmed first")
        snapshot("32b-popup-confirm")
        confirm.tap()
        XCTAssertTrue(waitFor(element("popup-result"), labelContains: "已在電腦上按「允許」", timeout: 25),
                      "result says \(said(element("popup-result")))")
        XCTAssertTrue(poll(timeout: 15) { !self.element("popup-card").exists }, "the answered pop-up is still shown")
        snapshot("32-popup-answered")
    }

    /// Several photos (three made-up camera shots) go out in one message, in order.
    func test33SeveralPhotosGoInOneMessage() throws {
        let helper = try helperSettings()
        try launchWithHelper()
        openChat("claude", claudeA)
        XCTAssertTrue(text("整理好了，安裝段落改成三步").waitForExistence(timeout: 10), "chat did not load")
        let before = try XCTUnwrap(userPhotos(helper, session: claudeA), "could not read the transcript")
        let camera = element("chat-camera")
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "camera button missing")
        // The PC's state (how many photos it takes) arrives just after the chat opens.
        XCTAssertTrue(poll(timeout: 10) {
            camera.tap()
            return self.app.descendants(matching: .any).matching(identifier: "chat-photo-preview").count >= 2
        }, "a second shot replaced the first")
        camera.tap()
        XCTAssertTrue(poll(timeout: 5) {
            self.app.descendants(matching: .any).matching(identifier: "chat-photo-preview").count == 3
        }, "previews: \(app.descendants(matching: .any).matching(identifier: "chat-photo-preview").count)")
        XCTAssertTrue(waitFor(element("chat-photo-count"), labelContains: "3 張照片", timeout: 5), "count line missing")
        let input = element("chat-input")
        input.tap()
        input.typeText("three shots")
        snapshot("33a-three-photos")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(text("（示範）收到：three shots").waitForExistence(timeout: 30), "the photos were not sent")
        XCTAssertEqual(userPhotos(helper, session: claudeA), before + 3, "the PC did not get three photos")
        snapshot("33-three-photos-sent")
    }

    /// A reply with a Markdown table, a heading and a list is laid out as the desktop apps show
    /// it, not as rows of "|".
    func test34TablesShowAsTables() throws {
        try launchWithHelper()
        openChat("claude", claudeA)
        let input = element("chat-input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "chat did not load")
        input.tap()
        input.typeText("請用表格整理")
        app.buttons["chat-send"].tap()
        XCTAssertTrue(text("（示範）收到：請用表格整理").waitForExistence(timeout: 25), "the reply did not arrive")
        app.swipeUp()
        snapshot("34-table")
        // The bubble reads as one element (its parts combined), so the table is checked by its text.
        XCTAssertTrue(text("RTX 5080，192 TH/s、187 W").exists, "the table rows are not read as cells")
        XCTAssertFalse(text("| RTX 5080 |").exists, "the table is shown as rows of |")
        XCTAssertFalse(text("| --- |").exists, "the table's separator row is shown as text")
        XCTAssertFalse(text("**+15").exists, "a cell's bold marks are shown")
        XCTAssertFalse(text("## 各卡現況").exists, "the heading marks are shown")
        XCTAssertTrue(text("• 先改設定").exists, "the list has no bullets")
    }

    func test35FirstScreenLinksToEachPCsNewestConversations() throws {
        // As if the user had last looked long ago: the conversations are all new.
        try launchWithHelper(environment: ["DESK_UI_SEEN_BEFORE": "2000-01-01T00:00:00Z"])
        let codex = element("pc-recent-示範電腦-\(codexY)")
        XCTAssertTrue(codex.waitForExistence(timeout: 15), "Codex's conversation is not on the first screen")
        let links = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pc-recent-示範電腦-'"))
        let labels = links.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("Claude") } && labels.contains { $0.contains("Codex") }, "\(labels)")
        XCTAssertLessThanOrEqual(labels.count, 6, "at most three per app")
        // Codex's older conversation (5 hours ago) is idle, so it carries the dot.
        let marked = poll(timeout: 10) { (codex.value as? String) == "有新訊息" }
        snapshot("35-recent")
        XCTAssertTrue(marked, "not marked new: \(said(codex)) \(String(describing: codex.value))")
        codex.tap()
        XCTAssertTrue(element("chat-input").waitForExistence(timeout: 10), "the link did not open the conversation")
        XCTAssertTrue(text("建議先做模擬器版本").waitForExistence(timeout: 10), "a different conversation opened")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(codex.waitForExistence(timeout: 10), "back on the first screen")
        XCTAssertTrue(poll(timeout: 5) { (codex.value as? String) != "有新訊息" }, "still marked new after opening it")
    }

    func test36LongConversationOpensAtItsNewestAndJumpsBothWays() throws {
        let helper = try helperSettings()
        let path = "/v1/codex/sessions/\(codexY)"
        func written(_ reply: String) -> Bool {
            let events = ask(helper, "\(path)/events?after=0")?["events"] as? [[String: Any]] ?? []
            return events.contains { $0["text"] as? String == reply }
        }
        for n in 1 ... 8 {
            ask(helper, "\(path)/messages", body: ["text": "長對話第 \(n) 則", "clientMsgId": UUID().uuidString, "force": true])
            XCTAssertTrue(poll(timeout: 30) { written("（示範）收到：長對話第 \(n) 則") }, "reply \(n) was not written")
        }
        try launchWithHelper()
        openChat("codex", codexY)
        let newest = text("（示範）收到：長對話第 8 則")
        XCTAssertTrue(newest.waitForExistence(timeout: 15), "the conversation did not load")
        let landed = poll(timeout: 5) { newest.isHittable }
        snapshot("36-newest")
        XCTAssertTrue(landed, "opening did not land on the newest message")
        let top = element("chat-to-top")
        XCTAssertTrue(top.waitForExistence(timeout: 5), "no button to the top")
        top.tap()
        let first = text("建議先做模擬器版本")
        XCTAssertTrue(poll(timeout: 6) { first.exists && first.isHittable }, "the top button did not reach the first message")
        XCTAssertFalse(newest.exists && newest.isHittable, "the newest message is still on screen after going to the top")
        snapshot("36-top")
        element("chat-to-bottom").tap()
        XCTAssertTrue(poll(timeout: 6) { newest.exists && newest.isHittable }, "the bottom button did not reach the newest message")
        // The scroll bar at the right edge, like the desktop's (asked 10/30): the thumb sits at the
        // end now; holding the blank track above it pages up, a page at a time, towards the finger.
        let rail = top.frame
        XCTAssertGreaterThan(rail.minX, app.windows.firstMatch.frame.maxX - 30, "the bar is not at the right edge: \(rail)")
        let bar = element("chat-scrollbar")
        XCTAssertTrue(bar.exists, "no scroll bar")
        // The bar says where its thumb is ("位置 p 大小 s …"); the thumb's own frame does not
        // follow its offset in the accessibility tree, so the thumb is placed from these.
        func barState() -> (position: Double, size: Double) {
            let numbers = (bar.value as? String ?? "").split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
            return (numbers.first ?? -1, numbers.dropFirst().first ?? -1)
        }
        let frame = bar.frame
        let arrow = 18.0, track = frame.height - 2 * arrow
        func thumbTop(_ state: (position: Double, size: Double)) -> Double {
            arrow + (track - max(36, track * state.size)) * state.position
        }
        // Points on the bar from the screen's origin: a coordinate on the bar itself re-queries it
        // during a drag, which timed out while the app kept scrolling (CI 10/30).
        func point(_ y: Double) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.minY + y))
        }
        let opened = barState()
        XCTAssertGreaterThan(opened.position, 0.6, "the thumb is not near the end of a conversation opened at its end: \(bar.value ?? "-")")
        XCTAssertLessThan(opened.size, 0.95, "the thumb fills the track: \(bar.value ?? "-")")
        // Held on the track above the thumb for a moment: pages up towards the finger (a page is
        // half of this short conversation, so it may well reach the top).
        point(max(arrow + 6, thumbTop(opened) - 40)).press(forDuration: 0.6)
        XCTAssertTrue(poll(timeout: 3) { !(newest.exists && newest.isHittable) },
                      "holding the track above the thumb did not scroll up: \(bar.value ?? "-")")
        XCTAssertTrue(poll(timeout: 2) { barState().position < opened.position - 0.2 }, "the thumb did not move up: \(bar.value ?? "-")")
        snapshot("36-scrollbar")
        // The thumb dragged to the bottom of the track: back at the newest message.
        let now = barState()
        point(thumbTop(now) + max(36, track * now.size) / 2)
            .press(forDuration: 0.2, thenDragTo: point(frame.height - arrow - 2), withVelocity: .default, thenHoldForDuration: 0.3)
        XCTAssertTrue(poll(timeout: 6) { newest.exists && newest.isHittable }, "dragging the thumb to the bottom did not reach the newest message: \(bar.value ?? "-")")
    }

    func test37CodexFastModeSwitch() throws {
        try launchWithHelper()
        openChat("codex", codexX)
        let bar = element("chat-meta")
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "meta bar missing")
        bar.tap()
        let toggle = app.switches["fast-toggle"]
        XCTAssertTrue(revealInSheet(toggle), "no fast mode switch for Codex")
        XCTAssertTrue(poll(timeout: 5) { toggle.isEnabled }, "the switch stays disabled")
        XCTAssertEqual(toggle.value as? String, "0", "fast mode starts off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let note = element("fast-busy")
        XCTAssertTrue(waitFor(note, labelContains: "已切換為快速模式", timeout: 20), "did not finish: \(said(note))")
        XCTAssertTrue(poll(timeout: 5) { toggle.value as? String == "1" }, "the switch went back off")
        snapshot("37-fast-on")
        element("meta-done").tap()
        XCTAssertTrue(waitFor(bar, labelContains: "⚡", timeout: 15), "the chat's top line has no lightning: \(said(bar))")
        // Off again, for the tests after this one.
        bar.tap()
        XCTAssertTrue(revealInSheet(toggle), "the switch is gone")
        XCTAssertTrue(poll(timeout: 5) { toggle.isEnabled && toggle.value as? String == "1" }, "the sheet shows it off")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(note, labelContains: "已切換為標準模式", timeout: 20), "did not switch back: \(said(note))")
        element("meta-done").tap()
    }

    func test38ClaudeUpdateIsPressedOnlyFromThePhone() throws {
        let helper = try helperSettings()
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["DESK_POPUP_PORT"], "DESK_POPUP_PORT not set")
        launch(pc: "示範電腦|\(helper.host)|\(port)|\(helper.token)")
        openPC()
        let button = element("claude-update")
        XCTAssertTrue(reveal(button), "no update button for Claude's downloaded version")
        XCTAssertTrue(button.label.contains("4.30.0"), "the button does not name the version: \(said(button))")
        XCTAssertTrue(element("app-row-claude").label.contains("已下載"), "the Claude row does not say: \(said(element("app-row-claude")))")
        snapshot("38a-update-waiting")
        let note = element("claude-update-note")
        func pressUpdate() {
            XCTAssertTrue(reveal(element("claude-update")), "the update button is gone")
            element("claude-update").tap()
            let confirm = app.buttons["重新啟動以更新"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no confirmation before ending Claude Code sessions")
            XCTAssertTrue(text("Claude Code 工作").exists, "the confirmation does not say what is lost")
            confirm.tap()
        }
        // Claude Code is working (fake): Claude asks on the PC first, and the phone answers (10/30).
        pressUpdate()
        XCTAssertTrue(waitFor(note, labelContains: "仍在處理中", timeout: 30), "the PC's question is not mentioned: \(said(note))")
        let cancel = element("popup-button-取消")
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "Claude's question is not shown with its buttons")
        XCTAssertTrue(element("popup-button-等待 Claude").exists && element("popup-button-仍要更新").exists, "buttons missing")
        snapshot("38b-claude-asks")
        XCTAssertTrue(reveal(cancel), "the cancel button cannot be reached")
        cancel.tap()
        let sure = app.buttons["按「取消」"]
        XCTAssertTrue(sure.waitForExistence(timeout: 5), "pressing was not confirmed first")
        sure.tap()
        XCTAssertTrue(waitFor(element("popup-result"), labelContains: "已在電腦上按「取消」", timeout: 25),
                      "result says \(said(element("popup-result")))")
        XCTAssertTrue(poll(timeout: 15) { !self.element("popup-button-取消").exists }, "the question is still shown")
        XCTAssertTrue(reveal(element("claude-update")), "cancelling took the update button away")
        snapshot("38c-cancelled")
        // Again, and this time update anyway: it updates.
        pressUpdate()
        let quit = element("popup-button-仍要更新")
        XCTAssertTrue(quit.waitForExistence(timeout: 30), "Claude's question did not come back")
        XCTAssertTrue(reveal(quit), "the quit button cannot be reached")
        quit.tap()
        let sureQuit = app.buttons["按「仍要更新」"]
        XCTAssertTrue(sureQuit.waitForExistence(timeout: 5), "pressing was not confirmed first")
        sureQuit.tap()
        XCTAssertTrue(waitFor(element("popup-result"), labelContains: "已在電腦上按「仍要更新」", timeout: 25),
                      "result says \(said(element("popup-result")))")
        XCTAssertTrue(poll(timeout: 90) { !element("claude-update").exists }, "the button stays after updating")
        XCTAssertTrue(element("app-version-claude").label.contains("4.30.0"), "version: \(said(element("app-version-claude")))")
        XCTAssertTrue(waitFor(note, labelContains: "已更新為 4.30.0", timeout: 20), "the note still talks of the question: \(said(note))")
        snapshot("38d-updated")
    }

    func test39HugeMessagesAfterASavedCopyStillEndAtTheNewest() throws {
        let helper = try helperSettings()
        let path = "/v1/codex/sessions/\(codexX)"
        func written(_ reply: String) -> Bool {
            let events = ask(helper, "\(path)/events?after=0")?["events"] as? [[String: Any]] ?? []
            return events.contains { $0["text"] as? String == reply }
        }
        try launchWithHelper()
        openChat("codex", codexX)
        XCTAssertTrue(element("bubble-reply").waitForExistence(timeout: 15), "the conversation did not load")
        app.navigationBars.buttons.element(boundBy: 0).tap()  // the phone keeps this copy
        let row = element("session-row-\(codexX)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on the list")
        // Meanwhile two huge messages come on the PC, then a short one (10/30: it stopped in the
        // middle of a long blue bubble). The fake echoes a message's first 30 characters.
        let huge = String(repeating: "很長的貼上內容，一行接一行。", count: 400)
        for (n, message) in ["甲：" + huge, "乙：" + huge, "尾巴第 39 則"].enumerated() {
            ask(helper, "\(path)/messages", body: ["text": message, "clientMsgId": UUID().uuidString, "force": true])
            XCTAssertTrue(poll(timeout: 30) { written("（示範）收到：\(message.prefix(30))") }, "reply \(n + 1) was not written")
        }
        row.tap()
        let newest = text("（示範）收到：尾巴第 39 則")
        if !newest.waitForExistence(timeout: 25) {
            // Failed twice on CI (10/30) after passing twice: say what the screen holds, so the
            // log tail tells whether the rows came at all or the view stopped short of them.
            let replies = app.descendants(matching: .any).matching(identifier: "bubble-reply").allElementsBoundByIndex
            let users = app.descendants(matching: .any).matching(identifier: "bubble-user").allElementsBoundByIndex
            let shown = (replies + users).filter(\.isHittable).map { String($0.label.prefix(24)) }
            let events = ask(helper, "\(path)/events?after=0")?["events"] as? [[String: Any]] ?? []
            snapshot("39-stuck")
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map { String($0.label.prefix(16)) }
            XCTFail("the new messages did not come: title \(said(app.navigationBars.firstMatch)), \(app.staticTexts.count) texts "
                    + "\(texts), \(replies.count) replies and \(users.count) user bubbles in the tree, "
                    + "on screen \(shown), bar \(element("chat-scrollbar").exists) \(element("chat-scrollbar").value ?? "-"), "
                    + "landing \(element("chat-landing").exists), "
                    + "error \(said(element("chat-error"))), "
                    + "helper has \(events.count) events, last: \(String((events.last?["text"] as? String ?? "").prefix(30)))")
        }
        let landed = poll(timeout: 4) { newest.isHittable }
        snapshot("39-newest-after-huge")
        XCTAssertTrue(landed, "it did not end at the newest message after the huge ones")
    }

    // MARK: - Helpers

    /// How many photos the fake helper's transcript of `session` holds from the user.
    private func userPhotos(_ helper: Helper, session: String) -> Int? {
        guard let url = URL(string: "http://\(helper.host):\(helper.port)/v1/claude/sessions/\(session)/events?after=0") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(helper.token)", forHTTPHeaderField: "Authorization")
        var count: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let page = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            count = (page?["events"] as? [[String: Any]])?.filter {
                $0["kind"] as? String == "user" && $0["text"] as? String == "[圖片]"
            }.count
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return count
    }

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

    private func launch(pc: String?, openURL: String? = nil, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment["DESK_UI_TEST"] = "1"
        if let pc { app.launchEnvironment["DESK_UI_PC"] = pc }
        if let openURL { app.launchEnvironment["DESK_UI_OPEN_URL"] = openURL }
        app.launchEnvironment.merge(environment) { $1 }
        app.launch()
    }

    /// Asks the fake helper directly (not through the app), e.g. to write to a conversation.
    @discardableResult
    private func ask(_ helper: Helper, _ path: String, body: [String: Any]? = nil) -> [String: Any]? {
        guard let url = URL(string: "http://\(helper.host):\(helper.port)\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(helper.token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        var out: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        return out
    }

    /// What the fake helper on `port` says about Codex's window, asked directly.
    private func codexWindowOpen(_ helper: Helper, port: String) -> Bool? {
        guard let url = URL(string: "http://\(helper.host):\(port)/v1/state") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Bearer \(helper.token)", forHTTPHeaderField: "Authorization")
        var running: Bool?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let state = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let apps = state?["apps"] as? [String: Any]
            running = (apps?["codex"] as? [String: Any])?["running"] as? Bool
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return running
    }

    private func launchWithHelper(openURL: String? = nil, environment: [String: String] = [:]) throws {
        let helper = try helperSettings()
        launch(pc: "示範電腦|\(helper.host)|\(helper.port)|\(helper.token)", openURL: openURL, environment: environment)
    }

    /// An element's label for a failure message; reading a missing element's label fails the test.
    private func said(_ element: XCUIElement) -> String {
        element.exists ? element.label : "（畫面上沒有）"
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
        // Rows move down when the PC's state arrives; a tap during that layout change was lost
        // (CI 10/27, once the state also carried plan limits), so wait for it first.
        XCTAssertTrue(element("pc-presence").waitForExistence(timeout: 10), "PC state did not load")
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

    /// Scrolls a sheet's list up only: a downward swipe at the top of a sheet closes it (CI 10/27).
    private func revealInSheet(_ element: XCUIElement) -> Bool {
        let visible = { element.exists && element.isHittable }
        if poll(timeout: 2, visible) { return true }
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0 ..< 8 {
            list.swipeUp(velocity: .slow)
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
