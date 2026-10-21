import XCTest
import UIKit
@testable import Lightbox

private actor PhotoFixture {
    var calls: [String: Int] = [:]
    let delay: Double
    init(delay: Double = 0) { self.delay = delay }
    func load(_ entry: AlbumEntry) async throws -> UIImage {
        calls[entry.path, default: 0] += 1
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return UIImage()
    }
}

@MainActor
final class PlaybackTests: XCTestCase {
    private let a = AlbumEntry(path: "a.jpg", name: "a.jpg", kind: .photo, size: 10)
    private let b = AlbumEntry(path: "b.jpg", name: "b.jpg", kind: .photo, size: 10)

    private func service() throws -> SMBService {
        try SMBService(settings: ConnectionSettings(server: "example.invalid", share: "Photos"), password: "")
    }

    func testInFlightPrefetchIsReusedInsteadOfReadingTwice() async throws {
        let fixture = PhotoFixture(delay: 0.06)
        let buffer = PhotoBuffer(load: { try await fixture.load($0) })
        buffer.retain([a, b])
        let prefetch = Task { try await buffer.image(for: b) }
        await Task.yield()
        let displayed = try await buffer.image(for: b)
        let prefetched = try await prefetch.value
        XCTAssertTrue(displayed === prefetched)
        let calls = await fixture.calls
        XCTAssertEqual(calls[b.path], 1)
        buffer.clear()
    }

    func testBufferEvictsPhotosOutsideCurrentAndNext() async throws {
        let fixture = PhotoFixture()
        let buffer = PhotoBuffer(load: { try await fixture.load($0) })
        buffer.retain([a, b])
        _ = try await buffer.image(for: a)
        buffer.retain([b])
        buffer.retain([a, b])
        _ = try await buffer.image(for: a)
        let calls = await fixture.calls
        XCTAssertEqual(calls[a.path], 2)
        buffer.clear()
    }

    func testPreviousPhotoRemainsVisibleWhileNextPhotoLoads() async throws {
        let fixture = PhotoFixture(delay: 0.12)
        let model = PlayerModel(entries: [a, b], service: try service(), interval: 30, photoLoad: { try await fixture.load($0) })
        model.start()
        defer { model.stop() }
        try await waitUntil { model.image != nil }
        let previous = model.image
        model.next()
        XCTAssertTrue(model.loading)
        XCTAssertTrue(model.image === previous)
        try await waitUntil { !model.loading }
        XCTAssertFalse(model.image === previous)
        let calls = await fixture.calls
        XCTAssertEqual(calls[b.path], 1)
    }

    func testFastAutomaticSlidesDoNotRestartControlsTimer() async throws {
        let model = PlayerModel(entries: [a, b], service: try service(), interval: 0.04, controlsDelay: 0.12, photoLoad: { _ in UIImage() })
        model.start()
        defer { model.stop() }
        try await waitUntil { !model.controlsVisible }
        try await Task.sleep(for: .seconds(0.15))
        XCTAssertFalse(model.controlsVisible)
        model.revealControls()
        XCTAssertTrue(model.controlsVisible)
    }

    func testVideoControlsAlsoHideAndDragKeepsControlsVisible() async throws {
        let video = AlbumEntry(path: "v.mov", name: "v.mov", kind: .video, size: 10)
        let model = PlayerModel(entries: [video], service: try service(), interval: 5, controlsDelay: 0.04)
        model.revealControls()
        try await waitUntil { !model.controlsVisible }
        model.setInteracting(true)
        try await Task.sleep(for: .seconds(0.1))
        XCTAssertTrue(model.controlsVisible)
        model.setInteracting(false)
        try await waitUntil { !model.controlsVisible }
    }

    func testPauseAndBackgroundCancelHideTimer() async throws {
        let model = PlayerModel(entries: [a], service: try service(), interval: 5, controlsDelay: 0.04)
        model.revealControls()
        model.suspend()
        try await Task.sleep(for: .seconds(0.1))
        XCTAssertTrue(model.controlsVisible)
        XCTAssertTrue(model.paused)
    }

    func testRapidSkippingDoesNotLetOldPhotoReplaceLatest() async throws {
        let fixture = PhotoFixture(delay: 0.06)
        let c = AlbumEntry(path: "c.jpg", name: "c.jpg", kind: .photo, size: 10)
        let model = PlayerModel(entries: [a, b, c], service: try service(), interval: 30, photoLoad: { try await fixture.load($0) })
        model.start()
        defer { model.stop() }
        model.next(); model.next()
        try await waitUntil { !model.loading }
        XCTAssertEqual(model.entry.path, c.path)
        XCTAssertNotNil(model.image)
        XCTAssertNil(model.message)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Condition did not become true within 3 seconds")
    }
}
