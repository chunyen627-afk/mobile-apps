import XCTest
@testable import MinerStatusCore

final class TimeTextTests: XCTestCase {
    private let now = Timestamp(rfc3339: "2026-10-25T10:12:57+08:00")!.date

    func testSameDayShowsTaiwanClockAndAge() {
        // The PC once sent UTC "Z" times, which read eight hours behind when shown as text.
        let utc = Timestamp(rfc3339: "2026-10-25T02:12:54.191Z")
        XCTAssertEqual(DisplayText.clock(utc, now: now), "10:12:54（2 秒前）")
        let local = Timestamp(rfc3339: "2026-10-25T10:10:06.201+08:00")
        XCTAssertEqual(DisplayText.clock(local, now: now), "10:10:06（2 分鐘前）")
        XCTAssertNil(DisplayText.clock(nil, now: now))
    }

    func testOtherDayAddsDate() {
        let yesterday = Timestamp(rfc3339: "2026-10-24T17:40:00+08:00")
        XCTAssertEqual(DisplayText.clock(yesterday, now: now), "10/24 17:40:00（16 小時 32 分前）")
        // 2026-10-24 23:30 UTC is already 10/25 in Taiwan.
        let lateUTC = Timestamp(rfc3339: "2026-10-24T23:30:00Z")
        XCTAssertEqual(DisplayText.clock(lateUTC, now: now), "07:30:00（2 小時 42 分前）")
    }

    func testAgeSpans() {
        XCTAssertEqual(DisplayText.ago(0.4), "0 秒前")
        XCTAssertEqual(DisplayText.ago(-0.8), "0 秒前")  // jitter, not "ahead"
        XCTAssertEqual(DisplayText.ago(-4.2), "4 秒後")
        XCTAssertEqual(DisplayText.ago(59.9), "59 秒前")
        XCTAssertEqual(DisplayText.ago(3599), "59 分鐘前")
        XCTAssertEqual(DisplayText.ago(7200), "2 小時前")
        XCTAssertEqual(DisplayText.ago(3 * 86400 + 5), "3 天前")
    }
}
