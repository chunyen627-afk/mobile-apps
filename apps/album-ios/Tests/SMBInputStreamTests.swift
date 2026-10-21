import XCTest
@testable import Lightbox

final class SMBInputStreamTests: XCTestCase {
    func testChunkLimitSeekEOFAndShortReads() async {
        let stream = SMBInputStream(size: 900_000) { range in
            XCTAssertLessThanOrEqual(range.count, 512 * 1024)
            return Data(repeating: UInt8(range.lowerBound % 251), count: min(4096, range.count))
        }
        await Task.detached {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 600_000)
            XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), 4096)
            XCTAssertTrue(stream.setProperty(899_998 as NSNumber, forKey: .fileCurrentOffsetKey))
            XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), 2)
            XCTAssertEqual(buffer[0], UInt8(899_998 % 251))
            XCTAssertEqual(stream.read(&buffer, maxLength: 10), 0)
            XCTAssertTrue(stream.setProperty(3 as NSNumber, forKey: .fileCurrentOffsetKey))
            XCTAssertEqual(stream.read(&buffer, maxLength: 10), 10)
            XCTAssertEqual(buffer[0], 3)
            XCTAssertFalse(stream.setProperty((-1) as NSNumber, forKey: .fileCurrentOffsetKey))
            XCTAssertFalse(stream.setProperty(900_001 as NSNumber, forKey: .fileCurrentOffsetKey))
            stream.close()
            XCTAssertEqual(stream.read(&buffer, maxLength: 1), -1)
        }.value
    }

    func testCloseWakesBlockedReadAndCancelsProvider() async {
        let started = expectation(description: "read started")
        let cancelled = expectation(description: "provider cancelled")
        let stream = SMBInputStream(size: 10) { _ in
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
            return Data([1])
        }
        let task = Task.detached {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 10)
            return stream.read(&buffer, maxLength: 10)
        }
        await fulfillment(of: [started], timeout: 3)
        stream.close()
        await fulfillment(of: [cancelled], timeout: 3)
        let result = await task.value
        XCTAssertEqual(result, -1)
        XCTAssertEqual(stream.streamStatus, .closed)
    }

    func testTimeoutAndUnexpectedEmptyReadAreErrors() async {
        await Task.detached {
            let stream = SMBInputStream(size: 10, timeout: 0.05) { _ in
                try await Task.sleep(for: .seconds(5)); return Data([1])
            }
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 10)
            XCTAssertEqual(stream.read(&buffer, maxLength: 10), -1)
            XCTAssertEqual((stream.streamError as NSError?)?.code, NSURLErrorTimedOut)
            let empty = SMBInputStream(size: 10) { _ in Data() }
            empty.open()
            XCTAssertEqual(empty.read(&buffer, maxLength: 10), -1)
            XCTAssertEqual(empty.streamStatus, .error)
        }.value
    }
}
