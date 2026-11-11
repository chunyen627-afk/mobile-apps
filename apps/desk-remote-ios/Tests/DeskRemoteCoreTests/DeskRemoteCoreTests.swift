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

    /// A log kept on the phone comes back whole, and the next page only adds what is new (10/30).
    func testSavedLogComesBackAndContinuesFromItsCursor() throws {
        var log = TranscriptLog()
        log.apply(page("a", reset: true, [event(1, "user"), event(2, "tool_call", tool: "Bash"),
                                          event(3, "tool_result", tool: "Bash"), event(4)]))
        let saved = try JSONDecoder().decode(TranscriptLog.self, from: JSONEncoder().encode(log))
        XCTAssertEqual(saved, log)
        XCTAssertTrue(saved.loaded, "a saved log shows at once")
        XCTAssertEqual(saved.rows.map(\.id), ["m1", "t2", "m4"])
        XCTAssertEqual(saved.cursor, 4)
        var next = saved
        XCTAssertTrue(next.apply(page("a", reset: false, [event(5)])))
        XCTAssertEqual(next.rows.map(\.id), ["m1", "t2", "m4", "m5"])
        // The helper restarted meanwhile: its new epoch replaces the saved events.
        XCTAssertTrue(next.apply(page("b", reset: true, [event(1)])))
        XCTAssertEqual(next.rows.map(\.id), ["m1"])
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
        // Three tool rows in a row fold into one line (asked 10/31), as the desktop shows them.
        XCTAssertEqual(log.rows.map(\.id), ["m1", "gt2", "s7", "m8"])
        guard case .tools(let inner) = log.rows[1] else { return XCTFail("row 1 is not a fold") }
        XCTAssertEqual(inner.map(\.id), ["t2", "t3", "t6"])
        guard case .tool(let call, let result) = inner[0] else { return XCTFail("inner 0 is not a tool") }
        XCTAssertEqual(call?.seq, 2)
        XCTAssertEqual(result?.seq, 5)
        guard case .tool(let orphanCall, let orphan) = inner[2] else { return XCTFail("inner 2 is not a tool") }
        XCTAssertNil(orphanCall)
        XCTAssertEqual(orphan?.seq, 6)
        XCTAssertEqual(log.rows[1].toolCounts.map { "\($0.tool)×\($0.count)" }, ["Read×1", "Bash×1", "Grep×1"])
        // A lone tool row stays as it is.
        var single = TranscriptLog()
        single.apply(page("a", reset: true, [event(1, "user"), event(2, "tool_call", tool: "Read"), event(3)]))
        XCTAssertEqual(single.rows.map(\.id), ["m1", "t2", "m3"])
    }

    func testSessionTreeNestsChildrenAndSplitsDays() throws {
        let json = """
        {"app": "claude", "sessions": [
          {"id": "local_a", "title": "A", "updatedAt": "2026-11-01T01:00:00Z", "status": "idle", "hasTranscript": true},
          {"id": "local_b", "title": "B", "updatedAt": "2026-10-31T23:00:00Z", "status": "idle", "hasTranscript": true},
          {"id": "local_c", "title": "C", "updatedAt": "2026-10-31T10:00:00Z", "status": "idle", "hasTranscript": true, "parent": "local_a"},
          {"id": "local_d", "title": "D", "updatedAt": "2026-10-30T10:00:00Z", "status": "idle", "hasTranscript": true, "parent": "local_c"},
          {"id": "local_e", "title": "E", "updatedAt": "2026-10-29T10:00:00Z", "status": "idle", "hasTranscript": true, "parent": "local_missing"}
        ]}
        """
        let list = try JSONDecoder().decode(SessionList.self, from: Data(json.utf8))
        let utc = TimeZone(secondsFromGMT: 0)!
        let tree = SessionTree.build(list.sessions, timeZone: utc)  // days are local; UTC here for a stable check
        XCTAssertEqual(tree.sections.map { $0.rows.map { "\($0.session.title)\($0.depth)" } },
                       [["A0", "C1", "D2"], ["B0"], ["E0"]])
        XCTAssertEqual(tree.sections.flatMap { $0.rows }.map(\.last), [true, true, true, true, true])
        XCTAssertEqual(SessionTree.localDay("2026-11-01T01:00:00Z", timeZone: utc), "2026-11-01")
        XCTAssertEqual(SessionTree.dayLabel("2026-11-01", today: "2026-11-01"), "今天")
        XCTAssertEqual(SessionTree.dayLabel("2026-10-31", today: "2026-11-01"), "昨天")
        XCTAssertEqual(SessionTree.dayLabel("2026-10-29", today: "2026-11-01"), "10月29日")
        XCTAssertEqual(SessionTree.dayLabel("", today: "2026-11-01"), "更早")
    }

    func testPhotosSentTogetherShareOneBubble() {
        var log = TranscriptLog()
        log.apply(page("a", reset: true, [
            TranscriptEvent(seq: 1, kind: "user", text: "[圖片]", images: ["g1-0"]),
            TranscriptEvent(seq: 2, kind: "user", text: "[圖片]", images: ["g2-0"]),
            TranscriptEvent(seq: 3, kind: "user", text: "three shots"),
            TranscriptEvent(seq: 4, kind: "user", text: "[圖片]", images: ["g4-0"]),
        ]))
        XCTAssertEqual(log.rows.map(\.id), ["m1", "m3", "m4"])
        guard case .message(let first) = log.rows[0] else { return XCTFail("row 0 is not a message") }
        XCTAssertEqual(first.pictures, ["g1-0", "g2-0"])
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

    func testRemovedElevateResultsStayHidden() throws {
        let list = try HelperClient.decode(ElevateList.self, status: 200, data: Data("""
        {"available":true,"pending":[],
         "recent":[{"id":"a","kind":"command","name":"","state":"done","exitCode":0,"finished":1,"content":"x","output":""},
                   {"id":"b","kind":"command","name":"","state":"denied","exitCode":126,"finished":null,"content":"y","output":""}]}
        """.utf8))
        XCTAssertEqual(list.recent(hiding: []).map(\.id), ["a", "b"])
        let hidden = list.hidden([], removing: ["a"])
        XCTAssertEqual(list.recent(hiding: hidden).map(\.id), ["b"])
        // Clearing all hides both; ids the PC no longer lists are forgotten.
        let all = list.hidden(hidden.union(["gone"]), removing: list.recent.map(\.id))
        XCTAssertEqual(all, ["a", "b"])
        XCTAssertTrue(list.recent(hiding: all).isEmpty)
    }
}

final class MetaAndUsageTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func state(codex percent: Int, at time: String, account: String?) throws -> HelperState {
        let mark = account.map { "\"\($0)\"" } ?? "null"
        return try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.8"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],"elevate":null,
         "usage":{"codex":{"windows":[{"label":"每週","percent":\(percent),"resetsAt":null,"resetsText":null}],
                           "sampledAt":"\(time)","account":\(mark)}}}
        """))
    }

    func testPCsOnOnePlanShowTheNewerLimits() throws {
        let office = try state(codex: 0, at: "2026-10-28T09:30:53Z", account: "a1")
        let home = try state(codex: 14, at: "2026-10-28T05:35:21Z", account: "a1")
        var book = UsageBook()
        XCTAssertTrue(book.record(office, pc: "辦公室"))
        XCTAssertFalse(book.record(home, pc: "家用電腦"), "an older sample must not replace a newer one")
        // The home PC shows the office's newer reading and says where it came from.
        let shownAtHome = try XCTUnwrap(book.shown(.codex, own: home.usage(.codex), pc: "家用電腦"))
        XCTAssertEqual(shownAtHome.usage.windows.first?.percent, 0)
        XCTAssertEqual(shownAtHome.from, "辦公室")
        // The office keeps its own.
        XCTAssertEqual(book.shown(.codex, own: office.usage(.codex), pc: "辦公室")?.from, nil)
        // Another account, or a helper too old to say, keeps its own as well.
        let other = try state(codex: 50, at: "2026-10-28T01:00:00Z", account: "b2")
        XCTAssertEqual(book.shown(.codex, own: other.usage(.codex), pc: "家用電腦")?.usage.windows.first?.percent, 50)
        let unmarked = try state(codex: 50, at: "2026-10-28T01:00:00Z", account: nil)
        XCTAssertFalse(book.record(unmarked, pc: "舊電腦"))
        XCTAssertNil(book.shown(.codex, own: unmarked.usage(.codex), pc: "舊電腦")?.from)
        XCTAssertNil(book.shown(.claude, own: nil, pc: "辦公室"))
        // It survives the phone restarting.
        let saved = try JSONDecoder().decode(UsageBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(saved, book)
    }

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

    func testDecodesPopupsAndHowManyPhotosAPCTakes() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.11"},"capabilities":["read","send","photos","popups"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "popups":[{"id":"0123456789ab","title":"","process":"SecurityHealthHost","text":"是否要允許？","buttons":["允許","取消"]}]}
        """))
        XCTAssertEqual(state.shownPopups.map(\.name), ["SecurityHealthHost"], "an untitled window goes by its program")
        XCTAssertEqual(state.shownPopups.first?.buttons, ["允許", "取消"])
        XCTAssertEqual(state.photoLimit, 10)
        let old = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.10"},"capabilities":["read","send","photo"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[]}
        """))
        XCTAssertEqual(old.shownPopups, [])
        XCTAssertEqual(old.photoLimit, 1, "older helpers take one photo")
        // One photo still goes as `image`, which every helper takes; several as `images`.
        let several = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ActionRequest(text: "", images: ["a", "b"]))) as? [String: Any]
        XCTAssertEqual(several?["images"] as? [String], ["a", "b"])
        XCTAssertNil(several?["image"])
        let press = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ActionRequest(button: "允許"))) as? [String: Any]
        XCTAssertEqual(press as? [String: String], ["button": "允許"])
    }

    func testRecentConversationsAndWhetherTheyAreNew() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.12"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "recent":[{"app":"claude","id":"a","title":"整理 README","folder":"demo","updatedAt":"2026-10-29T10:00:00Z",
                    "status":"needs-action","permission":null,"hasTranscript":true},
                   {"app":"codex","id":"b","title":"回覆 A1","folder":null,"updatedAt":"2026-10-29T10:05:00Z",
                    "status":"active","permission":null,"hasTranscript":true},
                   {"app":"gemini","id":"c","title":"以後的 App","folder":null,"updatedAt":"2026-10-29T07:00:00Z",
                    "status":"idle","permission":null,"hasTranscript":true}]}
        """))
        XCTAssertEqual(state.recentLinks.map(\.app), [.claude, .codex], "an app the phone does not know is skipped")
        let now = DeskText.parse("2026-10-29T10:05:00Z")!
        XCTAssertEqual(DeskText.latestTime(state.recentLinks[0].session, now: now), "等你回答・5 分鐘前")
        XCTAssertEqual(DeskText.latestTime(state.recentLinks[1].session, now: now), "回覆中")
        XCTAssertEqual(DeskText.latestTime(state.recent![2].session, now: now), "3 小時前")
        XCTAssertTrue(DeskText.isNewer("2026-10-29T10:00:00Z", than: "2026-10-29T09:59:59Z"))
        XCTAssertFalse(DeskText.isNewer("2026-10-29T10:00:00Z", than: "2026-10-29T10:00:00Z"))
        XCTAssertFalse(DeskText.isNewer("2026-10-29T10:00:00Z", than: nil), "never looked is not news")
        let old = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.11"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[]}
        """))
        XCTAssertEqual(old.recentLinks, [], "older helpers say nothing")
        XCTAssertFalse(old.hasFast(.codex))
        let fast = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.12"},"capabilities":["read","fast"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],"fast":{"codex":true}}
        """))
        XCTAssertTrue(fast.hasFast(.codex))
        XCTAssertFalse(fast.hasFast(.claude), "Claude has no fast mode")
        XCTAssertEqual(fast.fastOn(.codex), true)
        let request = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ActionRequest(fast: false))) as? [String: Any]
        XCTAssertEqual(request?["fast"] as? Bool, false)
    }

    func testVersionLinesSayWhatHappensWithANewerOne() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.12"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "versions":{"codex":{"installed":"26.1023.6123.0","running":"26.1016.6573.0","update":true},
                     "claude":{"installed":"4.30.0.0","running":"4.29.0.0","update":true}}}
        """))
        XCTAssertEqual(DeskText.versionLine(.codex, state.version(.codex)),
                       "跑的是 26.1016.6573.0，新版 26.1023.6123.0 已裝好：電腦閒置 10 分鐘後自動重開")
        XCTAssertEqual(DeskText.versionLine(.claude, state.version(.claude)),
                       "跑的是 4.29.0.0，新版 4.30.0.0 已裝好：要自己重開 Claude 桌面版")
        let current = try JSONDecoder().decode(HelperState.AppVersion.self, from: data("""
        {"installed":"26.1023.6123.0","running":"26.1023.6123.0","update":false}
        """))
        XCTAssertEqual(DeskText.versionLine(.codex, current), "版本 26.1023.6123.0")
        let closed = try JSONDecoder().decode(HelperState.AppVersion.self, from: data("""
        {"installed":"26.1023.6123.0","running":null,"update":false}
        """))
        XCTAssertEqual(DeskText.versionLine(.codex, closed), "版本 26.1023.6123.0（沒有開著）")
        XCTAssertNil(DeskText.versionLine(.codex, nil), "older helpers say nothing")
        let waiting = try JSONDecoder().decode(HelperState.AppVersion.self, from: data("""
        {"installed":"3.6556.2.0","running":"3.6556.2.0","update":true,"pending":"4.29.0"}
        """))
        XCTAssertEqual(DeskText.versionLine(.claude, waiting),
                       "跑的是 3.6556.2.0，新版 4.29.0 已下載：按下面的「重新啟動以更新」才會換")
        XCTAssertFalse(current.newerWaiting)
        // Helper 0.5.30: a newer one only the PC can bring in is named after the version (11/01).
        let told = try JSONDecoder().decode(HelperState.AppVersion.self, from: data("""
        {"installed":"26.1027.3384.0","running":"26.1027.3384.0","update":false,
         "notice":"有新版：到電腦上按 Codex 左下角的「有可用的更新」"}
        """))
        XCTAssertEqual(DeskText.versionLine(.codex, told),
                       "版本 26.1027.3384.0・有新版：到電腦上按 Codex 左下角的「有可用的更新」")
        XCTAssertTrue(told.newerWaiting, "drawn in orange")
    }

    func testMemoryAndANewerHelperAreShown() throws {
        // Helper 0.5.30 (11/01): the commit charge, what it freed itself, and a newer helper on disk.
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.29","helperUpdate":"0.5.30"},"capabilities":["read","restart"],
         "apps":{},"presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "memory":{"percent":92,"usedGB":164.0,"limitGB":178.0,"high":true,
                   "top":[{"name":"game","gb":12.0,"handles":900},{"name":"steam","gb":1.0,"handles":2470000}],
                   "action":"Steam 已自動關掉","actionAt":"2026-11-01T14:55:00+00:00"}}
        """))
        XCTAssertEqual(state.pc.helperUpdate, "0.5.30")
        XCTAssertTrue(state.can("restart"))
        let memory = try XCTUnwrap(state.memory)
        XCTAssertEqual(DeskText.memoryValue(memory), "92%（164／178 GB）")
        XCTAssertEqual(DeskText.memoryTop(memory), "用最多的：game 12.0 GB、steam 247 萬個 handle")
        let now = try XCTUnwrap(DeskText.parse("2026-11-01T15:00:00+00:00"))
        XCTAssertEqual(DeskText.memoryAction(memory, now: now), "Steam 已自動關掉・5 分鐘前")
        let calm = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.12"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":1,"locked":false},"warnings":[],
         "memory":{"percent":27,"usedGB":30.1,"limitGB":111.9,"high":false,"top":[],"action":null,"actionAt":null}}
        """))
        XCTAssertNil(calm.pc.helperUpdate, "older helpers send no helperUpdate")
        XCTAssertNil(DeskText.memoryTop(try XCTUnwrap(calm.memory)), "no list while it is fine")
        XCTAssertNil(DeskText.memoryAction(try XCTUnwrap(calm.memory)))
        let restarted = try HelperClient.decode(HelperRestart.self, status: 202, data: data("""
        {"ok":true,"message":"小幫手重新啟動中，約 15 秒後回來"}
        """))
        XCTAssertTrue(restarted.ok)
    }

    func testAUACPromptIsNamedNotTakenForALock() throws {
        let state = try HelperClient.decode(HelperState.self, status: 200, data: data("""
        {"ok":true,"pc":{"name":"P","helperVersion":"0.5.12"},"capabilities":["read"],"apps":{},
         "presence":{"idleSeconds":900,"locked":true,"uac":true},"warnings":[]}
        """))
        XCTAssertEqual(DeskText.presence(state.presence), "UAC 擋著（要到電腦前按）")
        let locked = HelperState.Presence(idleSeconds: 900, locked: true, uac: nil)
        XCTAssertEqual(DeskText.presence(locked), "已鎖定（需要先解鎖）", "older helpers say only locked")
        XCTAssertThrowsError(try HelperClient.decode(HelperState.self, status: 423, data: data("""
        {"ok":false,"error":"uac","message":"x"}
        """))) { XCTAssertEqual($0 as? HelperFailure, .uac) }
        XCTAssertThrowsError(try HelperClient.decode(HelperState.self, status: 423, data: data("""
        {"ok":false,"error":"locked","message":"x"}
        """))) { XCTAssertEqual($0 as? HelperFailure, .locked) }
        XCTAssertTrue(DeskText.failure(.uac).contains("到電腦前按"))
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
        XCTAssertNil(DeskText.permission(full))
        let weekly = PlanUsage.Window(label: "每週", percent: 46, resetsAt: nil, resetsText: "週日上午11:00 重設")
        XCTAssertEqual(DeskText.usageWindow(weekly), "每週 46%・週日上午11:00 重設")
        let codex = PlanUsage.Window(label: "每週", percent: 5, resetsAt: "2026-11-02T10:49:20Z", resetsText: nil)
        XCTAssertEqual(DeskText.usageWindow(codex, timeZone: TimeZone(identifier: "Asia/Taipei")!), "每週 5%・11/2 18:49 重設")
    }

    func testImportedCodexThreadShowsTheNoteAndAPendingModePick() throws {
        let page = try HelperClient.decode(EventPage.self, status: 200, data: data("""
        {"ok":true,"epoch":"e","reset":true,"events":[],"earlier":false,"cursor":0,"status":"idle","prompt":null,
         "meta":{"model":null,"modelId":null,"effort":null,"context":null,"permission":"代我核准",
                 "permissionPending":true,"note":"匯入的舊對話，回覆一次後才有資料"}}
        """))
        XCTAssertEqual(DeskText.metaLine(page.meta), "匯入的舊對話，回覆一次後才有資料")
        XCTAssertEqual(DeskText.permission(page.meta), "代我核准（下一則回覆起生效）")
        // Once the model is known (the Codex button on screen) the note follows it until a reply.
        let seen = ConversationMeta(model: "GPT-6.1 Sol", effort: nil, context: nil, permission: "要求核准",
                                    note: "匯入的舊對話，回覆一次後才有資料")
        XCTAssertEqual(DeskText.metaLine(seen), "GPT-6.1 Sol・匯入的舊對話，回覆一次後才有資料")
        XCTAssertEqual(DeskText.permission(seen), "要求核准")
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

    func testAppVersionLine() {
        XCTAssertEqual(DeskText.appVersion(["CFBundleShortVersionString": "0.5.3", "CFBundleVersion": "6"]),
                       "App 版本 0.5.3（build 6）")
        XCTAssertEqual(DeskText.appVersion([:]), "App 版本 ?（build ?）")
    }

    func testUnreachablePCAddsTheZeroTierHint() {
        let recent = DeskText.failure(.unreachable, networkChangedAgo: 30)
        XCTAssertTrue(recent.hasPrefix(DeskText.failure(.unreachable) + "\n"))
        XCTAssertTrue(recent.contains("手機剛換過網路") && recent.contains("ZeroTier 關掉再打開"))
        let old = DeskText.failure(.timeout, networkChangedAgo: 3600)
        XCTAssertTrue(old.contains("換過網路的話") && !old.contains("剛換過"))
        XCTAssertEqual(DeskText.failure(.unreachable, networkChangedAgo: nil),
                       DeskText.failure(.unreachable) + "\n" + DeskText.reconnectHint(networkChangedAgo: nil))
        XCTAssertEqual(DeskText.failure(.unreachable, networkChangedAgo: 5, short: true),
                       DeskText.failure(.unreachable) + "・手機剛換網路：請重連 ZeroTier")
        // Answers from the helper are not a stuck VPN: no hint.
        XCTAssertEqual(DeskText.failure(.unauthorized, networkChangedAgo: 5), DeskText.failure(.unauthorized))
        XCTAssertEqual(DeskText.failure(.locked, networkChangedAgo: 5, short: true), DeskText.failure(.locked))
    }

    func testBareWebAddressesBecomeLinks() throws {
        let parsed = try AttributedString(markdown: "看 https://github.com/x/y 和 [說明](https://example.org/doc)，路徑 C:\\work\\a.txt",
                                          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let linked = DeskText.linkingWebAddresses(parsed)
        let links = linked.runs.compactMap { run in run.link.map { ($0.absoluteString, String(linked[run.range].characters)) } }
        XCTAssertEqual(links.map(\.0), ["https://github.com/x/y", "https://example.org/doc"])
        XCTAssertEqual(links.map(\.1), ["https://github.com/x/y", "說明"], "the Markdown link keeps its own text")
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

    func testBlocksLayOutTablesHeadingsListsAndRules() {
        let text = """
        還有空間：

        ## 各卡現況
        | 卡 | 現在 | 達成率 |
        | --- | :---: | ---: |
        | RTX 5080 | **192** TH/s | 89% |
        | 中間 3060 | 38.4 TH/s |
        | a \\| b | c | d | 多的 |
        - 先改設定
          * 再看溫度
        ---
        ```
        | 不是表格 |
        | --- |
        ```
        """
        XCTAssertEqual(DeskText.blocks(text), [
            .prose("還有空間："),
            .heading(level: 2, text: "各卡現況"),
            .table(header: ["卡", "現在", "達成率"],
                   rows: [["RTX 5080", "**192** TH/s", "89%"], ["中間 3060", "38.4 TH/s", ""], ["a | b", "c", "d"]]),
            .prose("• 先改設定\n  • 再看溫度"),
            .rule,
            .code("| 不是表格 |\n| --- |"),
        ])
        // A lone line with pipes, or a header whose separator does not match, stays prose.
        XCTAssertEqual(DeskText.blocks("a | b\nc | d"), [.prose("a | b\nc | d")])
        XCTAssertEqual(DeskText.blocks("| a | b |\n| --- |"), [.prose("| a | b |\n| --- |")])
        XCTAssertEqual(DeskText.blocks("#標籤不是標題"), [.prose("#標籤不是標題")])
    }

    func testPCKeepsItsLocalAddressAndReadsOlderSavesWithoutOne() throws {
        let saved = try JSONDecoder().decode([DeskPC].self, from: Data(
            #"[{"id":"6E0A1C2B-3D4E-4F50-8A6B-7C8D9E0F1A2B","name":"辦公室","host":"10.1.2.3","port":18790}]"#.utf8))
        XCTAssertNil(saved[0].lanHost)
        XCTAssertNil(saved[0].lanEndpoint)
        var pc = saved[0]
        pc.lanHost = "192.168.1.5"
        let again = try JSONDecoder().decode(DeskPC.self, from: JSONEncoder().encode(pc))
        XCTAssertEqual(again.lanEndpoint, HelperEndpoint(host: "192.168.1.5", port: 18790))
        XCTAssertNotNil(DeskPC.problem(name: "a", host: "10.1.2.3", port: "18790", token: "", tokenRequired: false,
                                       lanHost: "http://192.168.1.5"))
        XCTAssertNil(DeskPC.problem(name: "a", host: "10.1.2.3", port: "18790", token: "", tokenRequired: false, lanHost: " "))
        // Helper 0.5.44 reports it in its state; older helpers do not.
        let reported = try JSONDecoder().decode(HelperState.PC.self, from: Data(
            #"{"name":"辦公室","helperVersion":"0.5.44","helperUpdate":null,"lanHost":"192.168.1.5","lanPort":18790}"#.utf8))
        XCTAssertEqual(reported.lanHost, "192.168.1.5")
        XCTAssertEqual(reported.lanPort, 18790)
        let older = try JSONDecoder().decode(HelperState.PC.self, from: Data(#"{"name":"辦公室","helperVersion":"0.5.43"}"#.utf8))
        XCTAssertNil(older.lanHost)
    }

    func testRequestsFollowTheAddressThatAnsweredLast() throws {
        let book = RouteBook()
        let zt = try XCTUnwrap(HelperEndpoint(host: "10.1.2.3", port: 18790))
        let lan = try XCTUnwrap(HelperEndpoint(host: "192.168.1.5", port: 18790))
        let token = String(repeating: "x", count: 32)
        let client = HelperClient(endpoint: zt, token: token, lan: lan, routes: book)
        XCTAssertEqual(client.active, zt)
        XCTAssertFalse(client.viaLAN)
        book.note("10.1.2.3:18790", lanWon: true)
        XCTAssertEqual(client.active, lan)
        XCTAssertTrue(client.viaLAN)
        book.forget("10.1.2.3:18790")
        XCTAssertEqual(client.active, zt)
        // Without a local address the book changes nothing, and another PC's win is not this one's.
        book.note("10.1.2.3:18790", lanWon: true)
        let plain = HelperClient(endpoint: zt, token: token, routes: book)
        XCTAssertEqual(plain.active, zt)
        XCTAssertFalse(plain.viaLAN)
        let other = try XCTUnwrap(HelperEndpoint(host: "10.1.2.4", port: 18790))
        XCTAssertFalse(HelperClient(endpoint: other, token: token, lan: lan, routes: book).viaLAN)
    }

    /// Helper 0.5.45 watches a light in its camera picture: the state carries it, `/v1/light` adds the days.
    func testLightReportDecodesWithTodayFirst() throws {
        let report = try HelperClient.decode(LightReport.self, status: 200, data: Data("""
        {"ok": true, "name": "玻璃門", "on": true, "level": 183.0, "since": "2026-11-11T09:02:00+08:00", "error": null,
         "watching": true, "hours": [8, 18], "weekdaysOnly": true, "intervalSeconds": 30, "region": [0.75, 0.4, 0.05, 0.18],
         "days": [{"date": "2026-11-11", "changes": [{"time": "08:05:17", "on": true, "level": 179.6, "start": true},
                                                     {"time": "09:02:00", "on": false, "level": 72.3, "start": false}]},
                  {"date": "2026-11-10", "changes": []}],
         "samples": [{"at": "2026-11-11T09:02:00+08:00", "level": 183.0}]}
        """.utf8))
        XCTAssertEqual(report.days.map(\.date), ["2026-11-11", "2026-11-10"])
        XCTAssertEqual(report.days[0].changes.map(\.on), [true, false])
        XCTAssertTrue(report.days[0].changes[0].start)
        XCTAssertEqual(report.summary.sinceTime, "09:02")
        XCTAssertEqual(report.summary.hours, [8, 18])
        let state = try HelperClient.decode(HelperState.self, status: 200, data: Data("""
        {"ok": true, "pc": {"name": "辦公室", "helperVersion": "0.5.45"}, "capabilities": ["read", "camera", "light"],
         "apps": {}, "presence": {"idleSeconds": 3, "locked": false}, "warnings": [],
         "light": {"name": "玻璃門", "on": null, "level": null, "since": null, "error": null, "watching": false,
                   "hours": [8, 18], "weekdaysOnly": true}}
        """.utf8))
        XCTAssertEqual(state.light?.watching, false)
        XCTAssertNil(state.light?.on)
        XCTAssertTrue(state.can("light"))
        let older = try HelperClient.decode(HelperState.self, status: 200, data: Data("""
        {"ok": true, "pc": {"name": "辦公室", "helperVersion": "0.5.44"}, "capabilities": ["read"], "apps": {},
         "presence": {"idleSeconds": 3, "locked": false}, "warnings": []}
        """.utf8))
        XCTAssertNil(older.light)
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
