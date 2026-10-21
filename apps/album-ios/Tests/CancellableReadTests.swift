import XCTest
@testable import Lightbox

private actor TransferFixture {
    var chunks = 0
    func advance() { chunks += 1 }
}

final class CancellableReadTests: XCTestCase {
    func testCancelledReadStopsProviderAndRejectsPartialData() async throws {
        let fixture = TransferFixture()
        let started = expectation(description: "Provider started reading")
        let task = Task {
            try await CancellableRead.perform { shouldContinue in
                // Deliberately ignore Task cancellation, like the library's continuation.
                await Task.detached {
                    started.fulfill()
                    for _ in 0..<200 {
                        guard shouldContinue() else { break }
                        await fixture.advance()
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    return Data([1, 2, 3])
                }.value
            }
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled partial read must not be displayed") }
        catch is CancellationError { }
        let chunks = await fixture.chunks
        XCTAssertLessThan(chunks, 200)
    }

    func testCompletedReadPreservesAllData() async throws {
        let data = try await CancellableRead.perform { shouldContinue in
            XCTAssertTrue(shouldContinue())
            return Data([1, 2, 3, 4])
        }
        XCTAssertEqual(data, Data([1, 2, 3, 4]))
    }
}
