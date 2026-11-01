import XCTest
@testable import Lightbox

private actor Attempts {
    var operations = 0
    var reconnects = 0
    func operate() -> Int { operations += 1; return operations }
    func reconnect() { reconnects += 1 }
}

private struct Dropped: Error {}

final class ReconnectingTests: XCTestCase {
    /// Without SIGPIPE ignored, this write kills the whole test process, as it killed the album
    /// when a folder was opened on a connection the NAS had closed.
    func testWritingToAClosedConnectionFailsInsteadOfEndingTheApp() throws {
        _ = try SMBService(settings: ConnectionSettings(server: "example.invalid", share: "Photos"), password: "")
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0)
        close(ends[1])
        let written = [UInt8(1)].withUnsafeBytes { write(ends[0], $0.baseAddress, 1) }
        let failure = errno
        close(ends[0])
        XCTAssertEqual(written, -1)
        XCTAssertEqual(failure, EPIPE)
    }

    func testAFailedRequestReconnectsAndSucceedsOnTheSecondTry() async throws {
        let attempts = Attempts()
        let value = try await Reconnecting.perform(reconnect: { await attempts.reconnect() }) { () async throws -> String in
            if await attempts.operate() == 1 { throw Dropped() }
            return "rows"
        }
        XCTAssertEqual(value, "rows")
        let (operations, reconnects) = await (attempts.operations, attempts.reconnects)
        XCTAssertEqual(operations, 2)
        XCTAssertEqual(reconnects, 1)
    }

    func testASecondFailureIsReportedWithoutLooping() async {
        let attempts = Attempts()
        do {
            _ = try await Reconnecting.perform(reconnect: { await attempts.reconnect() }) { () async throws -> Int in
                _ = await attempts.operate()
                throw Dropped()
            }
            XCTFail("the second failure must reach the caller")
        } catch { XCTAssertTrue(error is Dropped) }
        let (operations, reconnects) = await (attempts.operations, attempts.reconnects)
        XCTAssertEqual(operations, 2)
        XCTAssertEqual(reconnects, 1)
    }

    func testCancellationIsNeverRetried() async {
        let attempts = Attempts()
        do {
            _ = try await Reconnecting.perform(reconnect: { await attempts.reconnect() }) { () async throws -> Int in
                _ = await attempts.operate()
                throw CancellationError()
            }
            XCTFail("a cancelled request must stay cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        let (operations, reconnects) = await (attempts.operations, attempts.reconnects)
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(reconnects, 0)
    }

    func testAFailedReconnectIsReportedInsteadOfTheFirstError() async {
        struct Unreachable: Error {}
        let attempts = Attempts()
        do {
            _ = try await Reconnecting.perform(reconnect: { throw Unreachable() }) { () async throws -> Int in
                _ = await attempts.operate()
                throw Dropped()
            }
            XCTFail("a failed reconnect must reach the caller")
        } catch { XCTAssertTrue(error is Unreachable) }
        let operations = await attempts.operations
        XCTAssertEqual(operations, 1)
    }
}
