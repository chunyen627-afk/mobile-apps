import XCTest
@testable import Lightbox

private actor DirectoryFixture {
    var calls = 0
    func list(_ path: String) -> [AlbumEntry] {
        calls += 1
        return [AlbumEntry(path: path + "/a.jpg", name: "a.jpg", kind: .photo, size: 10),
                AlbumEntry(path: path + "/b.mov", name: "b.mov", kind: .video, size: 20)]
    }
}

final class ScanIndexTests: XCTestCase {
    private let root = AlbumEntry(path: "album", name: "album", kind: .folder, size: 0)

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testReplayAndRelaunchUseSavedUnfilteredListWithoutNetworkScan() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DirectoryFixture()
        let first = try await ScanIndex(directory: dir).prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertTrue(first.saved)
        let second = try await ScanIndex(directory: dir).prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertTrue(second.reused)
        XCTAssertEqual(second.snapshot.entries.count, 2)
        XCTAssertEqual(second.snapshot.entries.filter { PlaybackFilter.video.accepts($0) }.count, 1)
        let calls = await fixture.calls
        XCTAssertEqual(calls, 1)
    }

    func testExplicitRefreshReplacesSavedList() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DirectoryFixture()
        let index = ScanIndex(directory: dir)
        _ = try await index.prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        let refreshed = try await index.prepare(key: "test", chosen: [root], force: true, list: { _ in [] })
        XCTAssertTrue(refreshed.saved)
        XCTAssertFalse(refreshed.reused)
        let restored = try await index.prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertTrue(restored.snapshot.entries.isEmpty)
        XCTAssertTrue(restored.reused)
    }

    func testFailedRefreshPreservesCompleteIndex() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DirectoryFixture()
        let index = ScanIndex(directory: dir)
        _ = try await index.prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        let failed = try await index.prepare(key: "test", chosen: [root], force: true, list: { _ in throw AlbumError.message("offline") })
        XCTAssertFalse(failed.saved)
        XCTAssertEqual(failed.warningCount, 1)
        let restored = try await index.prepare(key: "test", chosen: [root], list: { _ in XCTFail("must not scan"); return [] })
        XCTAssertEqual(restored.snapshot.entries.count, 2)
    }

    func testCancellationDoesNotSavePartialScan() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = ScanIndex(directory: dir)
        do {
            _ = try await index.prepare(key: "test", chosen: [root], list: { _ in throw CancellationError() })
            XCTFail("expected cancellation")
        } catch is CancellationError { }
        let fixture = DirectoryFixture()
        let result = try await index.prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertFalse(result.reused)
        XCTAssertTrue(result.saved)
    }

    func testCorruptIndexRecoversByScanning() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("test.json"))
        let fixture = DirectoryFixture()
        let result = try await ScanIndex(directory: dir).prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.snapshot.entries.count, 2)
    }

    func testKeysSeparateAccountsSelectionsAndShareButIgnoreOrderAndFileSize() throws {
        var settings = ConnectionSettings(server: "example.local", share: "Photos")
        let other = AlbumEntry(path: "other", name: "other", kind: .folder, size: 0)
        let first = try ScanIndex.key(settings: settings, chosen: [root, other])
        XCTAssertEqual(first, try ScanIndex.key(settings: settings, chosen: [other, root]))
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root]))
        settings.username = "another-account"
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root, other]))
        settings.username = ""; settings.share = "OtherPhotos"
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root, other]))
    }
}
