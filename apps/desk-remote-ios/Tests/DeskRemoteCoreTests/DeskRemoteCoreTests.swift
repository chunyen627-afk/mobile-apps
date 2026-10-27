@testable import DeskRemoteCore
import UIKit
import XCTest

final class EndpointTests: XCTestCase {
    func testAcceptsIPAndHostName() {
        XCTAssertEqual(HelperEndpoint(host: " 10.1.2.3 ", port: 18790)?.host, "10.1.2.3")
        XCTAssertNotNil(HelperEndpoint(host: "office-pc.local", port: 1))
        XCTAssertNotNil(HelperEndpoint(host: "fd00::1", port: 80))
    }

    func testRejectsSchemesPathsSpacesAndBadPorts() {
        for host in ["", "http://10.1.2.3", "10.1.2.3/x", "a b", "user@host", "10.1.2.3:80", "-x", "主機"] {
            XCTAssertNil(HelperEndpoint(host: host, port: 80), host)
        }
        XCTAssertNil(HelperEndpoint(host: "10.1.2.3", port: 0))
        XCTAssertNil(HelperEndpoint(host: "10.1.2.3", port: 65536))
    }

    func testBuildsEscapedURL() throws {
        let endpoint = try XCTUnwrap(HelperEndpoint(host: "10.1.2.3", port: 18790))
        let url = endpoint.url(["v1", "claude", "sessions", "a/../b", "events"],
                               query: [URLQueryItem(name: "after", value: "3")])
        XCTAssertEqual(url?.absoluteString, "http://10.1.2.3:18790/v1/claude/sessions/a%2F..%2Fb/events?after=3")
        XCTAssertEqual(HelperEndpoint(host: "fd00::1", port: 80)?.url(["health"])?.absoluteString, "http://[fd00::1]:80/health")
    }
}

final class DecodingTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testDecodesState() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"示範電腦","helperVersion":"0.1.0"},"capabilities":["read"],
         "apps":{"claude":{"running":true,"available":true},"codex":{"running":null,"available":false}},
         "presence":{"idleSeconds":420,"locked":false},"warnings":["w"]}
        """))
        XCTAssertEqual(state.pc.name, "示範電腦")
        XCTAssertEqual(state.app(.claude)?.running, true)
        XCTAssertNil(state.app(.codex)?.running)
        XCTAssertEqual(state.presence.idleSeconds, 420)
        XCTAssertEqual(state.warnings, ["w"])
    }

    func testDecodesSessionsAndEvents() throws {
        let list = try HelperClient.decode(SessionList.self, status: 200, data: data("""
        {"ok":true,"app":"claude","warning":null,"sessions":[{"id":"local_1","title":"T","folder":"demo",
         "updatedAt":"2026-10-26T01:00:00Z","status":"needs-action","permission":"自動","hasTranscript":true}]}
        """))
        XCTAssertEqual(list.sessions.first?.status, "needs-action")
        let page = try HelperClient.decode(EventPage.self, status: 200, data: data("""
        {"ok":true,"epoch":"ab12","reset":true,"earlier":false,"cursor":2,"status":"working",
         "prompt":{"promptId":"p1","tool":"Edit","text":"要求權限"},
         "events":[{"seq":1,"ts":"2026-10-26T01:00:00Z","kind":"user","text":"hi"},
                   {"seq":2,"ts":null,"kind":"tool_result","text":"x","tool":"Bash","truncated":true,"itemId":"i2","isError":true}]}
        """))
        XCTAssertEqual(page.events.map(\.seq), [1, 2])
        XCTAssertEqual(page.events[1].itemId, "i2")
        XCTAssertEqual(page.prompt?.promptId, "p1")
    }

    func testMapsErrorStatuses() {
        func failure(_ status: Int, _ body: String) -> HelperFailure? {
            do {
                _ = try HelperClient.decode(HelperState.self, status: status, data: data(body))
                return nil
            } catch {
                return error as? HelperFailure
            }
        }
        XCTAssertEqual(failure(401, #"{"ok":false,"error":"unauthorized"}"#), .unauthorized)
        XCTAssertEqual(failure(429, #"{"ok":false,"error":"locked-out","message":"m"}"#), .lockedOut)
        XCTAssertEqual(failure(404, #"{"ok":false,"error":"not-found","message":"找不到"}"#), .notFound("找不到"))
        XCTAssertEqual(failure(405, "{}"), .readOnly)
        XCTAssertEqual(failure(500, "not json"), .server(nil))
        XCTAssertEqual(failure(200, #"{"unexpected":true}"#), .badResponse)
    }

    func testMapsActionErrors() {
        func failure(_ status: Int, _ body: String) -> HelperFailure? {
            do {
                _ = try HelperClient.decode(ActionStatus.self, status: status, data: data(body))
                return nil
            } catch {
                return error as? HelperFailure
            }
        }
        XCTAssertEqual(failure(409, #"{"ok":false,"error":"busy-user","message":"m","idleSeconds":5}"#), .busyUser(5))
        XCTAssertEqual(failure(409, #"{"ok":false,"error":"prompt-changed"}"#), .promptChanged)
        XCTAssertEqual(failure(423, #"{"ok":false,"error":"locked"}"#), .locked)
        XCTAssertEqual(failure(400, #"{"ok":false,"error":"bad-request","message":"訊息是空的"}"#), .badRequest("訊息是空的"))
        XCTAssertEqual(failure(429, #"{"ok":false,"error":"busy"}"#), .queueFull)
        XCTAssertEqual(DeskText.failure(.busyUser(5)), "電腦有人在用（5 秒前有操作）")
    }

    func testDecodesActionStatus() throws {
        let status = try HelperClient.decode(ActionStatus.self, status: 202, data: data("""
        {"ok":true,"id":"ab12","kind":"new","app":"codex","sessionId":null,"state":"queued","message":"排隊中",
         "error":null,"verified":null}
        """))
        XCTAssertFalse(status.finished)
        let done = try HelperClient.decode(ActionStatus.self, status: 200, data: data("""
        {"ok":true,"id":"ab12","kind":"new","app":"codex","sessionId":"0a0","state":"done","message":"已開新對話",
         "error":null,"verified":true,"title":"幫我看"}
        """))
        XCTAssertTrue(done.finished)
        XCTAssertEqual(done.title, "幫我看")
    }

    func testDecodesQuestionAndReplySuggestions() throws {
        let page = try HelperClient.decode(EventPage.self, status: 200, data: data("""
        {"ok":true,"epoch":"e","reset":true,"earlier":false,"cursor":0,"status":"idle","prompt":null,"events":[],
         "question":{"questionId":"toolu_1","questions":[{"question":"哪一種？","header":"方式","multiSelect":false,
           "options":[{"label":"A","description":"快"},{"label":"B","description":null}]}]},
         "suggestions":{"ask":"要繼續嗎？","replies":[{"label":"好","message":"好，繼續。"}]}}
        """))
        XCTAssertEqual(page.question?.questions.first?.options.map(\.label), ["A", "B"])
        XCTAssertEqual(page.suggestions?.replies.first?.message, "好，繼續。")
        var log = TranscriptLog()
        XCTAssertTrue(log.apply(page))
        XCTAssertEqual(log.question?.questionId, "toolu_1")
        // An older helper without these fields still decodes.
        let old = try HelperClient.decode(EventPage.self, status: 200, data: data("""
        {"ok":true,"epoch":"e","reset":false,"earlier":false,"cursor":0,"status":"idle","prompt":null,"events":[]}
        """))
        XCTAssertNil(old.question)
        XCTAssertTrue(log.apply(old), "a question that went away is a visible change")
        XCTAssertNil(log.question)
    }

    func testQuestionAnswerEmptinessAndEncoding() throws {
        XCTAssertTrue(QuestionAnswer().isEmpty)
        XCTAssertTrue(QuestionAnswer(labels: [], other: "  ").isEmpty)
        XCTAssertFalse(QuestionAnswer(labels: [], other: "自己寫").isEmpty)
        let body = try JSONEncoder().encode(ActionRequest(questionId: "q", answers: [QuestionAnswer(labels: ["A"])]))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["questionId"] as? String, "q")
        XCTAssertEqual(((json["answers"] as? [[String: Any]])?.first?["labels"] as? [String]), ["A"])
        XCTAssertNil(json["text"], "unused fields are left out")
    }

    func testMapsTransportErrors() {
        XCTAssertEqual(HelperClient.failure(for: URLError(.timedOut)), .timeout)
        XCTAssertEqual(HelperClient.failure(for: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(HelperClient.failure(for: URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(HelperClient.failure(for: CancellationError()), .cancelled)
    }
}

final class TranscriptLogTests: XCTestCase {
    private func page(_ epoch: String, reset: Bool, _ events: [TranscriptEvent], cursor: Int? = nil,
                      prompt: PermissionPrompt? = nil) -> EventPage {
        EventPage(epoch: epoch, reset: reset, events: events, earlier: false,
                  cursor: cursor ?? events.last?.seq ?? 0, status: "idle", prompt: prompt)
    }

    private func event(_ seq: Int, _ kind: String = "assistant", tool: String? = nil) -> TranscriptEvent {
        TranscriptEvent(seq: seq, kind: kind, text: "e\(seq)", tool: tool)
    }

    func testResetReplacesAndAppendSkipsSeen() {
        var log = TranscriptLog()
        XCTAssertTrue(log.apply(page("a", reset: true, [event(1), event(2)])))
        XCTAssertTrue(log.apply(page("a", reset: false, [event(2), event(3)])))
        XCTAssertEqual(log.events.map(\.seq), [1, 2, 3])
        XCTAssertEqual(log.cursor, 3)
        XCTAssertFalse(log.apply(page("a", reset: false, [], cursor: 3)))
        XCTAssertTrue(log.loaded)
    }

    func testNewEpochResets() {
        var log = TranscriptLog()
        log.apply(page("a", reset: true, [event(1), event(2), event(3)]))
        log.apply(page("b", reset: false, [event(1)]))
        XCTAssertEqual(log.events.map(\.seq), [1])
        XCTAssertEqual(log.epoch, "b")
    }

    func testToolResultsFoldUnderMatchingCalls() {
        var log = TranscriptLog()
        log.apply(page("a", reset: true, [
            event(1, "user"), event(2, "tool_call", tool: "Read"), event(3, "tool_call", tool: "Bash"),
            event(4, "tool_result", tool: "Bash"), event(5, "tool_result", tool: "Read"),
            event(6, "tool_result", tool: "Grep"), event(7, "status"), event(8),
        ]))
        XCTAssertEqual(log.rows.map(\.id), ["m1", "t2", "t3", "t6", "s7", "m8"])
        guard case .tool(let call, let result) = log.rows[1] else { return XCTFail("row 1 is not a tool") }
        XCTAssertEqual(call?.seq, 2)
        XCTAssertEqual(result?.seq, 5)
        guard case .tool(let orphanCall, let orphan) = log.rows[3] else { return XCTFail("row 3 is not a tool") }
        XCTAssertNil(orphanCall)
        XCTAssertEqual(orphan?.seq, 6)
    }

    func testPendingTextMatchesOnlyNewerUserMessages() {
        var log = TranscriptLog()
        log.apply(page("a", reset: true, [
            TranscriptEvent(seq: 1, kind: "user", text: "請再檢查一次"),
            TranscriptEvent(seq: 2, kind: "assistant", text: "請再檢查一次  好的"),
            TranscriptEvent(seq: 3, kind: "user", text: "請再\n檢查一次\n"),
        ]))
        XCTAssertTrue(log.hasUserText("請再 檢查一次", after: 2))
        XCTAssertFalse(log.hasUserText("請再檢查一次", after: 3), "only messages after the mark count")
        XCTAssertFalse(log.hasUserText("別的", after: 0))
    }

    func testCapsEventsAndKeepsPrompt() {
        var log = TranscriptLog()
        let many = (1 ... TranscriptLog.maxEvents + 5).map { event($0) }
        let prompt = PermissionPrompt(promptId: "p", tool: nil, text: "q")
        log.apply(page("a", reset: true, many, prompt: prompt))
        XCTAssertEqual(log.events.count, TranscriptLog.maxEvents)
        XCTAssertEqual(log.events.first?.seq, 6)
        XCTAssertTrue(log.earlier)
        XCTAssertEqual(log.prompt, prompt)
    }
}

final class ElevateTests: XCTestCase {
    /// The same vector as pc-helper/tests/test_elevate.py: phone and PC must agree byte for byte.
    func testSignatureMatchesThePCsVector() throws {
        let key = try XCTUnwrap(ElevateSigner.key(fromHex: String(repeating: "6b", count: 32)))  // "k" * 32
        let signature = ElevateSigner.signature(key: key, id: "0123456789abcdef",
                                                content: "Restart-Service -Name Spooler\r\n# 測試",
                                                cwd: "C:\\work", expires: 1_793_100_000)
        XCTAssertEqual(signature, "0ca586d0d0ea0c76843937f83eb9541cf0726b8040a81b448472a864e62a4a6d")
    }

    func testKeyParsing() {
        XCTAssertNotNil(ElevateSigner.key(fromHex: String(repeating: "AB", count: 32)))
        XCTAssertNotNil(ElevateSigner.key(fromHex: "ab cd " + String(repeating: "00", count: 30)))
        XCTAssertNil(ElevateSigner.key(fromHex: String(repeating: "ab", count: 31)))
        XCTAssertNil(ElevateSigner.key(fromHex: String(repeating: "zz", count: 32)))
        XCTAssertNil(ElevateSigner.key(fromHex: ""))
    }

    func testDecodesElevateListAndStateAndErrors() throws {
        let list = try HelperClient.decode(ElevateList.self, status: 200, data: Data("""
        {"ok":true,"available":true,"pending":[{"id":"0123456789abcdef","kind":"script","name":"fix.ps1",
          "content":"Write-Output ok","cwd":"C:\\\\work","created":1793099400,"expires":1793100000}],
         "recent":[{"id":"fedcba9876543210","kind":"command","name":"","state":"done","exitCode":0,"finished":1793099000,
          "content":"Get-Date","output":"2026\\r\\n"},
          {"id":"1111111111111111","kind":"command","name":"","state":"denied","exitCode":126,"finished":null,
          "content":"x","output":""}]}
        """.utf8))
        XCTAssertEqual(list.pending.first?.cwd, "C:\\work")
        XCTAssertEqual(list.recent.map { DeskText.elevateState($0) }, ["已執行・結束碼 0", "已拒絕"])
        let state = try HelperClient.decode(HelperState.self, status: 200, data: Data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.3.0"},"capabilities":["read","elevate"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],"elevate":{"available":true,"pending":2}}
        """.utf8))
        XCTAssertEqual(state.elevate?.pending, 2)
        XCTAssertTrue(state.can("elevate"))
        XCTAssertThrowsError(try HelperClient.decode(ElevateList.self, status: 403,
                                                     data: Data(#"{"ok":false,"error":"bad-signature"}"#.utf8))) {
            XCTAssertEqual($0 as? HelperFailure, .badSignature)
        }
        XCTAssertEqual(DeskText.remaining(until: 1_000_000 + 300, now: Date(timeIntervalSince1970: 1_000_000)), "剩約 5 分鐘")
        XCTAssertEqual(DeskText.remaining(until: 10, now: Date(timeIntervalSince1970: 20)), "已逾時")
    }
}

final class MetaAndUsageTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testDecodesUsageModelsAndMetaAndToleratesOlderHelpers() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.4.0"},"capabilities":["read","model"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],"elevate":null,
         "usage":{"claude":{"windows":[{"label":"每週","percent":46,"resetsAt":null,"resetsText":"週日上午11:00 重設"}],
                            "sampledAt":"2026-10-27T04:49:26Z"},"codex":null},
         "models":{"claude":["Opus 5.5","Sonnet 5.5"]}}
        """))
        XCTAssertEqual(state.usage(.claude)?.windows.first?.percent, 46)
        XCTAssertNil(state.usage(.codex))
        XCTAssertEqual(state.models(.claude), ["Opus 5.5", "Sonnet 5.5"])
        XCTAssertEqual(state.models(.codex), [])
        let old = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.3.0"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[]}
        """))
        XCTAssertNil(old.usage(.claude))
        XCTAssertEqual(old.models(.claude), [])
        let page = try HelperClient.decode(EventPage.self, status: 200, data: data("""
        {"ok":true,"epoch":"e","reset":true,"events":[],"earlier":false,"cursor":0,"status":"idle","prompt":null,
         "meta":{"model":"Opus 5.5","modelId":"claude-opus-5-5","effort":"高",
                 "context":{"used":183203,"window":1000000,"percent":18}}}
        """))
        XCTAssertEqual(page.meta?.context?.percent, 18)
    }

    func testMetaAndUsageText() {
        let full = ConversationMeta(model: "Opus 5.5", effort: "高",
                                    context: ConversationMeta.Context(used: 183_203, window: 1_000_000, percent: 18))
        XCTAssertEqual(DeskText.metaLine(full), "Opus 5.5・高・上下文 18%")
        XCTAssertEqual(DeskText.context(full.context!), "上下文 18%（18.3 萬 / 100 萬）")
        let unknown = ConversationMeta(model: "Sonnet 5.5", effort: nil,
                                       context: ConversationMeta.Context(used: 9_800, window: nil, percent: nil))
        XCTAssertEqual(DeskText.metaLine(unknown), "Sonnet 5.5・上下文 9,800")
        XCTAssertEqual(DeskText.context(unknown.context!), "上下文已用 9,800 tokens")
        XCTAssertNil(DeskText.metaLine(ConversationMeta(model: nil, effort: nil, context: nil)))
        XCTAssertNil(DeskText.metaLine(nil))
        let weekly = PlanUsage.Window(label: "每週", percent: 46, resetsAt: nil, resetsText: "週日上午11:00 重設")
        XCTAssertEqual(DeskText.usageWindow(weekly), "每週 46%・週日上午11:00 重設")
        let codex = PlanUsage.Window(label: "每週", percent: 5, resetsAt: "2026-11-02T10:49:20Z", resetsText: nil)
        XCTAssertEqual(DeskText.usageWindow(codex, timeZone: TimeZone(identifier: "Asia/Taipei")!), "每週 5%・11/2 18:49 重設")
    }

    func testLogKeepsMetaWhenAPageHasNone() {
        var log = TranscriptLog()
        let meta = ConversationMeta(model: "Opus 5.5", effort: "高", context: nil)
        XCTAssertTrue(log.apply(EventPage(epoch: "e", reset: true, events: [], earlier: false, cursor: 0, status: "idle",
                                          prompt: nil, meta: meta)))
        XCTAssertFalse(log.apply(EventPage(epoch: "e", reset: false, events: [], earlier: false, cursor: 0, status: "idle",
                                           prompt: nil)))
        XCTAssertEqual(log.meta, meta)
        let switched = ConversationMeta(model: "Sonnet 5.5", effort: "高", context: nil)
        XCTAssertTrue(log.apply(EventPage(epoch: "e", reset: false, events: [], earlier: false, cursor: 0, status: "idle",
                                          prompt: nil, meta: switched)), "a model switch alone must redraw")
    }
}

final class MoreControlsTests: XCTestCase {
    func testNotificationLinks() throws {
        let link = try XCTUnwrap(DeskLink(URL(string:
            "deskremote://open?pc=%E8%BE%A6%E5%85%AC%E5%AE%A4&app=claude&session=local_1&title=%E6%95%B4%E7%90%86")!))
        XCTAssertEqual(link.pc, "辦公室")
        XCTAssertEqual(link.app, .claude)
        XCTAssertEqual(link.session, "local_1")
        XCTAssertEqual(link.title, "整理")
        XCTAssertFalse(link.elevate)
        let elevate = try XCTUnwrap(DeskLink(URL(string: "deskremote://open?pc=PC&elevate=1")!))
        XCTAssertTrue(elevate.elevate)
        XCTAssertNil(elevate.session)
        XCTAssertNil(DeskLink(URL(string: "deskremote://open?app=claude")!), "no PC")
        XCTAssertNil(DeskLink(URL(string: "https://open?pc=PC")!), "other scheme")
        XCTAssertNil(DeskLink(URL(string: "deskremote://open?pc=PC&app=other&session=x")!)?.app)
    }

    func testDecodesChoicesAndPermission() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: Data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.0"},"capabilities":["read","effort","mode","stop","screen"],
         "apps":{},"presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "efforts":{"claude":["低","高"]},"modes":{"claude":["手動"],"codex":["要求核准","代我核准"]},"stop":["claude"]}
        """.utf8))
        XCTAssertEqual(state.efforts(.claude), ["低", "高"])
        XCTAssertEqual(state.efforts(.codex), [])
        XCTAssertEqual(state.modes(.codex), ["要求核准", "代我核准"])
        XCTAssertTrue(state.canStop(.claude))
        XCTAssertFalse(state.canStop(.codex))
        XCTAssertTrue(state.can("screen"))
        let page = try HelperClient.decode(EventPage.self, status: 200, data: Data("""
        {"epoch":"e","reset":true,"events":[],"earlier":false,"cursor":0,"status":"idle","prompt":null,
         "meta":{"model":"Opus 5.5","effort":"高","context":null,"permission":"自動"}}
        """.utf8))
        XCTAssertEqual(page.meta?.permission, "自動")
    }

    func testPhotosAreShrunkToJPEG() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 1000)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 1000))
        }
        let data = try XCTUnwrap(DeskPhoto.prepare(big))
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8, 0xFF]), "not a JPEG")
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size.width * image.scale, 2048, accuracy: 1)
        XCTAssertEqual(image.size.height * image.scale, 512, accuracy: 1)
        XCTAssertNil(DeskPhoto.prepare(Data("not an image".utf8)))
    }

    func testCodexPhotoCaptionClearsThePendingBubble() {
        var log = TranscriptLog()
        log.apply(EventPage(epoch: "e", reset: true, events: [TranscriptEvent(seq: 5, kind: "user", text: "[圖片]\n看這張圖")],
                            earlier: false, cursor: 5, status: "working", prompt: nil))
        XCTAssertTrue(log.hasUserText("看這張圖", after: 4))
        XCTAssertFalse(log.hasUserText("別的", after: 4))
    }
}

final class TextTests: XCTestCase {
    func testPresenceText() {
        typealias P = HelperState.Presence
        XCTAssertEqual(DeskText.presence(P(idleSeconds: 5, locked: false)), "有人在用電腦")
        XCTAssertEqual(DeskText.presence(P(idleSeconds: 420, locked: false)), "閒置 7 分鐘")
        XCTAssertEqual(DeskText.presence(P(idleSeconds: 7300, locked: false)), "閒置 2 小時")
        XCTAssertEqual(DeskText.presence(P(idleSeconds: 999, locked: true)), "已鎖定（需要先解鎖）")
        XCTAssertEqual(DeskText.presence(P(idleSeconds: nil, locked: nil)), "閒置時間未知")
    }

    func testRelativeTime() throws {
        let now = try XCTUnwrap(DeskText.parse("2026-10-26T12:00:00Z"))
        XCTAssertEqual(DeskText.relative("2026-10-26T11:59:30Z", now: now), "剛剛")
        XCTAssertEqual(DeskText.relative("2026-10-26T11:55:00Z", now: now), "5 分鐘前")
        XCTAssertEqual(DeskText.relative("2026-10-26T08:59:59.500Z", now: now), "3 小時前")
        XCTAssertEqual(DeskText.relative("2026-10-24T12:00:00Z", now: now), "2 天前")
        XCTAssertNil(DeskText.relative("yesterday", now: now))
        XCTAssertNil(DeskText.relative(nil, now: now))
    }

    func testSegmentsSplitFencedCode() {
        let parts = DeskText.segments("前言\n\n```bash\nls -la\n```\n結尾")
        XCTAssertEqual(parts.map { $0.code }, [false, true, false])
        XCTAssertEqual(parts.map { $0.text }, ["前言", "ls -la", "結尾"])
        // An unclosed fence is shown as prose, not swallowed.
        XCTAssertEqual(DeskText.segments("a ``` b").map { $0.code }, [false, false])
    }

    func testPCFormProblems() {
        let token = String(repeating: "x", count: 32)
        XCTAssertNil(DeskPC.problem(name: "辦公室", host: "10.1.2.3", port: "18790", token: token, tokenRequired: true))
        XCTAssertEqual(DeskPC.problem(name: " ", host: "10.1.2.3", port: "1", token: token, tokenRequired: true), "請輸入名稱")
        XCTAssertNotNil(DeskPC.problem(name: "a", host: "http://x", port: "1", token: token, tokenRequired: true))
        XCTAssertNotNil(DeskPC.problem(name: "a", host: "x", port: "99999", token: token, tokenRequired: true))
        XCTAssertNotNil(DeskPC.problem(name: "a", host: "x", port: "1", token: "short", tokenRequired: true))
        XCTAssertNil(DeskPC.problem(name: "a", host: "x", port: "1", token: "", tokenRequired: false))
    }
}
