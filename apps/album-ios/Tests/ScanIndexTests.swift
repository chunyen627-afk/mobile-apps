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
        try Data("invalid".utf8).write(to: dir.appendingPathComponent("test.catalog.json"))
        let fixture = DirectoryFixture()
        let result = try await ScanIndex(directory: dir).prepare(key: "test", chosen: [root], list: { await fixture.list($0) })
        XCTAssertFalse(result.reused)
        XCTAssertEqual(result.snapshot.entries.count, 2)
    }

    func testScanDiagnosticsSurviveFailedReadWithoutStoringPaths() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiagnosticStore(directory: dir.appendingPathComponent("diagnostics"))
        let index = ScanIndex(directory: dir.appendingPathComponent("index"), diagnostics: store)
        let privateRoot = AlbumEntry(path: "private-directory", name: "private-directory", kind: .folder, size: 0)
        _ = try await index.prepare(key: "test", chosen: [privateRoot], list: { _ in
            throw AlbumError.message("private-server private-password")
        })
        let data = try Data(contentsOf: store.export())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        let actions = events.compactMap { $0["action"] as? String }
        XCTAssertTrue(actions.contains("scanDirectoryReading"))
        XCTAssertFalse(actions.contains("scanDirectoryRead"))
        XCTAssertFalse(actions.contains("scanIndexSaved"))
    }

    func testKeysSeparateAccountsSelectionsAndShareButIgnoreOrderAndFileSize() throws {
        var settings = ConnectionSettings(server: "example.local", share: "Photos")
        let other = AlbumEntry(path: "other", name: "other", kind: .folder, size: 0)
        let first = try ScanIndex.key(settings: settings, chosen: [root, other])
        XCTAssertEqual(first, try ScanIndex.key(settings: settings, chosen: [other, root]))
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root]))
        XCTAssertEqual(try ScanIndex.scopeKey(settings: settings), try ScanIndex.key(settings: settings, chosen: []))
        settings.username = "another-account"
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root, other]))
        settings.username = ""; settings.share = "OtherPhotos"
        XCTAssertNotEqual(first, try ScanIndex.key(settings: settings, chosen: [root, other]))
    }

    func testSelectionSubsetsAndNewCombinationsReuseDirectoryListings() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = AlbumEntry(path: "album2", name: "album2", kind: .folder, size: 0)
        let fixture = DirectoryFixture()
        let index = ScanIndex(directory: dir)
        _ = try await index.prepare(key: "scope", chosen: [root, other], list: { await fixture.list($0) })
        for selection in [[root], [other], [root, other], []] {
            let result = try await ScanIndex(directory: dir).prepare(key: "scope", chosen: selection, list: { _ in XCTFail("selection changes must not scan"); return [] })
            XCTAssertTrue(result.reused)
            XCTAssertEqual(result.snapshot.entries.count, selection.count * 2)
        }
        let calls = await fixture.calls
        XCTAssertEqual(calls, 2)
    }

    func testSelectingParentOnlyScansUnknownFoldersAndPreservesEmptyFolders() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = AlbumEntry(path: "album/child", name: "child", kind: .folder, size: 0)
        let empty = AlbumEntry(path: "album/empty", name: "empty", kind: .folder, size: 0)
        let fixture = DirectoryFixture()
        let index = ScanIndex(directory: dir)
        _ = try await index.prepare(key: "scope", chosen: [child], list: { await fixture.list($0) })
        let expanded = try await index.prepare(key: "scope", chosen: [root], list: { path in
            if path == "album" { return [child, empty] }
            if path == empty.path { return [] }
            XCTFail("known child must not scan"); return []
        })
        XCTAssertFalse(expanded.reused)
        XCTAssertEqual(expanded.snapshot.entries.count, 2)
        let subset = try await ScanIndex(directory: dir).prepare(key: "scope", chosen: [child, empty], list: { _ in XCTFail("known descendants must not scan"); return [] })
        XCTAssertTrue(subset.reused)
        XCTAssertEqual(subset.snapshot.folders, 2)
    }

    func testRefreshChildUpdatesParentWithoutLosingSiblingCache() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = AlbumEntry(path: "album/child", name: "child", kind: .folder, size: 0)
        let sibling = AlbumEntry(path: "album/sibling", name: "sibling", kind: .folder, size: 0)
        let fixture = DirectoryFixture()
        let index = ScanIndex(directory: dir)
        _ = try await index.prepare(key: "scope", chosen: [root], list: { path in
            if path == "album" { return [child, sibling] }
            return await fixture.list(path)
        })
        _ = try await index.prepare(key: "scope", chosen: [child], force: true, list: { _ in [] })
        let parent = try await index.prepare(key: "scope", chosen: [root], list: { _ in XCTFail("refresh must update parent and preserve sibling"); return [] })
        XCTAssertEqual(parent.snapshot.entries.map(\.path).sorted(), ["album/sibling/a.jpg", "album/sibling/b.mov"])
    }

    func testLegacyExactSelectionMigratesForSubsequentSubsets() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let media = AlbumEntry(path: "album/child/a.jpg", name: "a.jpg", kind: .photo, size: 10)
        try JSONEncoder().encode(ScanSnapshot(entries: [media], folders: 3)).write(to: dir.appendingPathComponent("legacy.json"))
        let migrated = try await ScanIndex(directory: dir).prepare(key: "scope", chosen: [root], legacyKey: "legacy", list: { _ in XCTFail("must migrate"); return [] })
        XCTAssertTrue(migrated.reused)
        let child = AlbumEntry(path: "album/child", name: "child", kind: .folder, size: 0)
        let subset = try await ScanIndex(directory: dir).prepare(key: "scope", chosen: [child], list: { _ in XCTFail("must reuse migrated subtree"); return [] })
        XCTAssertEqual(subset.snapshot.entries, [media])
        let empty = AlbumEntry(path: "album/empty", name: "empty", kind: .folder, size: 0)
        let noMedia = try await ScanIndex(directory: dir).prepare(key: "scope", chosen: [empty], list: { _ in XCTFail("complete legacy root proves empty subtree"); return [] })
        XCTAssertTrue(noMedia.snapshot.entries.isEmpty)
    }
}
