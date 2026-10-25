// UNRUN: written without a Swift toolchain. Not yet compiled or executed.
// Uses only documentation-reserved addresses (RFC 2606 `.example`, RFC 5737 192.0.2.0/24).

import XCTest
@testable import MinerStatusCore

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        stored.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private struct MockTransport: HTTPTransport {
    let log = RequestLog()
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        log.append(request)
        return try handler(request)
    }
}

final class StatusClientTests: XCTestCase {
    private let endpoint = try! SourceEndpoint(validating: "http://monitor.example:8080/status")

    private func response(
        _ status: Int = 200, contentType: String? = "application/json; charset=utf-8", url: URL? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? endpoint.url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] })!
    }

    private func makeClient(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) -> (StatusFeedClient, RequestLog) {
        let transport = MockTransport(handler: handler)
        return (StatusFeedClient(endpoint: endpoint, transport: transport), transport.log)
    }

    private func liveFeedData(sequence: Int, at time: Date, accepted: Int) throws -> Data {
        let feed = feedJSON([SampleSpec(sequence: sequence, at: time, accepted: accepted).json], origin: "live", notice: NSNull())
        return try JSONSerialization.data(withJSONObject: feed)
    }

    // MARK: - Endpoint validation

    func testEndpointAcceptsHTTPAndHTTPSWithHost() throws {
        XCTAssertTrue(try SourceEndpoint(validating: "http://monitor.example:8080/status").usesPlainHTTP)
        XCTAssertFalse(try SourceEndpoint(validating: "HTTPS://Monitor.Example/status").usesPlainHTTP)
        XCTAssertNoThrow(try SourceEndpoint(validating: "  http://192.0.2.10:8080/status \n"))
    }

    func testEndpointRejectsUnsafeOrIncompleteInput() {
        let cases: [(String, SourceEndpointError)] = [
            ("", .empty),
            ("   ", .empty),
            ("ftp://monitor.example/status", .unsupportedScheme),
            ("monitor.example/status", .unsupportedScheme),
            ("http:///status", .missingHost),
            ("http://user:secret@monitor.example/status", .embeddedCredentials),
            ("http://monitor.example/status#top", .fragment),
            ("http://monitor.example/st atus", .malformed),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try SourceEndpoint(validating: text), text) { error in
                XCTAssertEqual(error as? SourceEndpointError, expected, text)
            }
        }
    }

    // MARK: - Request shape

    func testRequestIsReadOnlyGET() {
        let request = StatusFeedClient(endpoint: endpoint).makeRequest()
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url, endpoint.url)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, StatusFeedClient.requestTimeout)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Miner-Status-Features"), "earnings,assessment,control")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testEphemeralSessionKeepsNoCookiesOrCache() {
        let configuration = URLSessionTransport.makeEphemeralSession().configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    // MARK: - Responses

    func testValidResponseDecodesThroughTheWhitelist() async throws {
        let data = try Data(contentsOf: fixtureURL("demo-two-machines.json"))
        let ok = response()
        let (client, log) = makeClient { _ in (data, ok) }
        let result = await client.fetch()
        XCTAssertEqual(try result.get().machines.count, 2)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertEqual(log.requests.first?.httpMethod, "GET")
    }

    func testNon200IsAFailure() async {
        for status in [204, 301, 404, 500, 503] {
            let reply = response(status)
            let (client, _) = makeClient { _ in (Data("{}".utf8), reply) }
            let result = await client.fetch()
            XCTAssertEqual(result.failureValue, .httpStatus(status))
        }
    }

    func testContentTypeMustBeJSON() async {
        for contentType in ["text/html", nil] as [String?] {
            let reply = response(contentType: contentType)
            let (client, _) = makeClient { _ in (Data("{}".utf8), reply) }
            let result = await client.fetch()
            XCTAssertEqual(result.failureValue, .unexpectedContentType)
        }
    }

    func testOversizedResponseIsRejected() async {
        let reply = response()
        let (client, _) = makeClient { _ in (Data(count: StatusFeedClient.maxResponseBytes + 1), reply) }
        let result = await client.fetch()
        XCTAssertEqual(result.failureValue, .responseTooLarge)
    }

    func testInvalidOrNonWhitelistedPayloadIsRejected() async throws {
        var machine = SampleSpec(sequence: 1, at: testStart, accepted: 10).json
        machine["pid"] = 1234
        let withExtraKey = try JSONSerialization.data(withJSONObject: feedJSON([machine]))
        for body in [Data("{}".utf8), Data("not json".utf8), withExtraKey] {
            let reply = response()
            let (client, _) = makeClient { _ in (body, reply) }
            let result = await client.fetch()
            XCTAssertEqual(result.failureValue, .invalidPayload)
        }
    }

    func testRedirectToAnotherOriginIsRejected() async throws {
        let data = try Data(contentsOf: fixtureURL("demo-running.json"))
        let elsewhere = [
            URL(string: "http://other.example:8080/status")!,
            URL(string: "http://monitor.example:9090/status")!,
            URL(string: "https://monitor.example:8080/status")!,
        ]
        for url in elsewhere {
            let reply = response(url: url)
            let (client, _) = makeClient { _ in (data, reply) }
            let result = await client.fetch()
            XCTAssertEqual(result.failureValue, .redirectedElsewhere, url.absoluteString)
        }

        let samePlace = response(url: URL(string: "http://MONITOR.example:8080/v1/status")!)
        let (client, _) = makeClient { _ in (data, samePlace) }
        let result = await client.fetch()
        XCTAssertNoThrow(try result.get(), "same origin, different path is allowed")
    }

    func testNonHTTPResponseIsRejected() async {
        let plain = URLResponse(url: endpoint.url, mimeType: "application/json", expectedContentLength: 2, textEncodingName: nil)
        let (client, _) = makeClient { _ in (Data("{}".utf8), plain) }
        let result = await client.fetch()
        XCTAssertEqual(result.failureValue, .notHTTPResponse)
    }

    func testTransportErrorsAreClassified() async {
        let cases: [(Error, FetchFailure)] = [
            (URLError(.timedOut), .timedOut),
            (URLError(.cannotConnectToHost), .cannotConnect),
            (URLError(.cannotFindHost), .cannotConnect),
            (URLError(.notConnectedToInternet), .cannotConnect),
            (URLError(.appTransportSecurityRequiresSecureConnection), .insecureConnectionBlocked),
            (URLError(.cancelled), .cancelled),
            (CancellationError(), .cancelled),
            (URLError(.badServerResponse), .transport(code: URLError.Code.badServerResponse.rawValue)),
            (NSError(domain: "demo", code: 1), .transport(code: nil)),
        ]
        for (error, expected) in cases {
            let (client, _) = makeClient { _ in throw error }
            let result = await client.fetch()
            XCTAssertEqual(result.failureValue, expected, "\(error)")
        }
    }

    // MARK: - Engine integration

    func testFetchResultsDriveTheEngineWithFailureAndReconnectSemantics() async throws {
        var clock = TestClock()
        var engine = StatusEngine()
        let reply = response()

        let first = try liveFeedData(sequence: 1, at: clock.wall, accepted: 10)
        engine.apply(await makeClient { _ in (first, reply) }.0.fetch(), at: clock.reading)
        clock.advance(30)
        let second = try liveFeedData(sequence: 2, at: clock.wall, accepted: 11)
        engine.apply(await makeClient { _ in (second, reply) }.0.fetch(), at: clock.reading)
        XCTAssertEqual(engine.snapshots(at: clock.reading).first?.light, .green)

        // A cancelled fetch (e.g. app backgrounded) changes nothing.
        engine.apply(await makeClient { _ in throw CancellationError() }.0.fetch(), at: clock.reading)
        XCTAssertEqual(engine.snapshots(at: clock.reading).first?.light, .green)

        // A real failure removes green at once and marks the held data historical.
        clock.advance(10)
        engine.apply(await makeClient { _ in throw URLError(.timedOut) }.0.fetch(), at: clock.reading)
        let failed = engine.snapshots(at: clock.reading).first
        XCTAssertEqual(failed?.light, .yellow)
        XCTAssertEqual(failed?.reason, .updateProblem(.requestFailed))
        XCTAssertEqual(failed?.isHistorical, true)

        // Reconnect: an increase measured against the pre-failure sample does not count.
        clock.advance(20)
        let third = try liveFeedData(sequence: 3, at: clock.wall, accepted: 12)
        engine.apply(await makeClient { _ in (third, reply) }.0.fetch(), at: clock.reading)
        XCTAssertEqual(engine.snapshots(at: clock.reading).first?.reason, .awaitingShareEvidence)

        clock.advance(30)
        let fourth = try liveFeedData(sequence: 4, at: clock.wall, accepted: 13)
        engine.apply(await makeClient { _ in (fourth, reply) }.0.fetch(), at: clock.reading)
        XCTAssertEqual(engine.snapshots(at: clock.reading).first?.light, .green)
    }

    // MARK: - Clock and text

    func testSystemClockIsMonotonicAndNearWallTime() {
        let clock = SystemClock()
        let first = clock.reading()
        let second = clock.reading()
        XCTAssertGreaterThanOrEqual(first.monotonic, 0)
        XCTAssertGreaterThanOrEqual(second.monotonic, first.monotonic)
        XCTAssertLessThan(abs(second.wall.timeIntervalSinceNow), 5)
    }

    func testFailureAndEndpointTextNeverClaimsOffline() {
        let failures: [FetchFailure] = [
            .cancelled, .timedOut, .cannotConnect, .insecureConnectionBlocked, .transport(code: -1),
            .transport(code: nil), .notHTTPResponse, .httpStatus(503), .redirectedElsewhere,
            .unexpectedContentType, .responseTooLarge, .invalidPayload,
        ]
        let endpointErrors: [SourceEndpointError] = [
            .empty, .malformed, .unsupportedScheme, .missingHost, .embeddedCredentials, .fragment,
        ]
        for text in failures.map(\.displayText) + endpointErrors.map(\.displayText) {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("離線"), text)
        }
    }
}

private extension Result {
    /// Named differently from the `failure` case to avoid a member-name clash.
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
