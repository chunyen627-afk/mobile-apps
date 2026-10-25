// Uses only documentation-reserved addresses (RFC 2606 `.example`).

import XCTest
@testable import MinerStatusCore

private struct ControlTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}

final class ControlClientTests: XCTestCase {
    private let endpoint = try! SourceEndpoint(validating: "http://monitor.example:8080/status?x=1")

    private func client(status: Int, body: String, url: URL? = nil) -> ControlClient {
        let endpoint = endpoint
        return ControlClient(endpoint: endpoint, transport: ControlTransport { request in
            let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        })
    }

    func testRequestIsATokenPostToTheControlPathOfTheSameOrigin() throws {
        let request = try XCTUnwrap(ControlClient(endpoint: endpoint).makeRequest(machineId: "laptop3070", action: .start, token: "secret"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://monitor.example:8080/control/laptop3070/start")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(ControlClient(endpoint: endpoint).makeRequest(machineId: "rig-1", action: .stop, token: "t")?.url?.path,
                       "/control/rig-1/stop")
    }

    func testMachineIdMustBeAPlainPathSegment() {
        let control = ControlClient(endpoint: endpoint)
        XCTAssertNil(control.makeRequest(machineId: "../status", action: .start, token: "t"))
        XCTAssertNil(control.makeRequest(machineId: "a/b", action: .start, token: "t"))
        XCTAssertNil(control.makeRequest(machineId: "", action: .start, token: "t"))
    }

    func testRepliesMapToResults() async {
        let ok = await client(status: 200, body: #"{"ok": true, "result": "started", "message": "已送出開始指令"}"#)
            .send(machineId: "laptop3070", action: .start, token: "t")
        XCTAssertEqual(ok, .success("已送出開始指令"))

        let refused = await client(status: 200, body: #"{"ok": false, "message": "筆電無法啟動保護程式"}"#)
            .send(machineId: "laptop3070", action: .start, token: "t")
        XCTAssertEqual(refused, .failure(.rejected(status: 200, message: "筆電無法啟動保護程式")))

        let wrong = await client(status: 401, body: #"{"ok": false}"#).send(machineId: "laptop3070", action: .stop, token: "t")
        XCTAssertEqual(wrong, .failure(.unauthorized))

        let busy = await client(status: 429, body: #"{"message": "請稍等"}"#).send(machineId: "laptop3070", action: .stop, token: "t")
        XCTAssertEqual(busy, .failure(.busy("請稍等")))

        let gone = await client(status: 501, body: "not json").send(machineId: "laptop3070", action: .stop, token: "t")
        XCTAssertEqual(gone, .failure(.rejected(status: 501, message: nil)))
        XCTAssertEqual(ControlFailure.rejected(status: 501, message: nil).displayText, "控制失敗（HTTP 501）")
    }

    func testReplyFromAnotherOriginIsRejected() async {
        let elsewhere = await client(status: 200, body: #"{"ok": true}"#, url: URL(string: "http://other.example/control")!)
            .send(machineId: "laptop3070", action: .start, token: "t")
        XCTAssertEqual(elsewhere, .failure(.invalidResponse))
    }

    func testTimeoutIsReported() async {
        let control = ControlClient(endpoint: endpoint, transport: ControlTransport { _ in throw URLError(.timedOut) })
        let result = await control.send(machineId: "laptop3070", action: .start, token: "t")
        XCTAssertEqual(result, .failure(.timedOut))
    }

    func testControlExtensionDecodes() throws {
        var machine = SampleSpec(sequence: 1, at: Date(timeIntervalSince1970: 1_792_800_000), accepted: 1).json
        XCTAssertNil(try decodeFeed(feedJSON([machine])).machines[0].control)
        machine["control"] = ["canStart": false, "canStop": true]
        let control = try XCTUnwrap(try decodeFeed(feedJSON([machine])).machines[0].control)
        XCTAssertFalse(control.canStart)
        XCTAssertTrue(control.canStop)
        machine["control"] = ["canStart": false, "canStop": true, "token": "x"]
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine])))
        machine["control"] = ["canStart": "yes", "canStop": true]
        XCTAssertThrowsError(try decodeFeed(feedJSON([machine])))
    }
}
