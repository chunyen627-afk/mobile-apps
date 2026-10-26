@testable import DeskRemoteCore
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
