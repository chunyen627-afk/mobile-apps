import XCTest
@testable import Lightbox

final class SelectionTests: XCTestCase {
    private func folder(_ path: String) -> AlbumEntry { AlbumEntry(path: path, name: path, kind: .folder, size: 0) }
    private func photo(_ path: String) -> AlbumEntry { AlbumEntry(path: path, name: path, kind: .photo, size: 10) }

    func testParentAndChildAreNotScannedTwice() {
        let chosen = SelectionRules.roots([folder("相簿/旅遊"), photo("相簿/旅遊/a.jpg"), folder("相簿/旅遊/台東"), folder("相簿/旅遊2")])
        XCTAssertEqual(Set(chosen.map(\.path)), Set(["相簿/旅遊", "相簿/旅遊2"]))
    }
    func testShareRootIncludesEverything() {
        XCTAssertEqual(SelectionRules.roots([folder(""), photo("a.jpg"), folder("sub")]).count, 1)
    }
    func testPathsDoNotEscapeOrConfusePrefixes() throws {
        XCTAssertEqual(try AlbumPath.clean("/相簿\\台東/"), "相簿/台東")
        XCTAssertFalse(AlbumPath.contains("相簿/a", "相簿/ab"))
        XCTAssertThrowsError(try AlbumPath.clean("相簿/../private"))
        XCTAssertThrowsError(try AlbumPath.clean("Z:\\相簿"))
    }
    func testServerDoesNotAcceptEmbeddedCredentialsOrShare() throws {
        var config = ConnectionSettings()
        config.server = "smb://user:password@example.local/Photos"
        config.share = "Photos"
        XCTAssertThrowsError(try config.validate())
        config.server = "example.local"
        XCTAssertEqual(try config.serverURL().host, "example.local")
    }
    func testFileTypesAndFiltering() {
        XCTAssertEqual(MediaKind.fromExtension("旅行.JPG"), .photo)
        XCTAssertEqual(MediaKind.fromExtension("影片.MOV"), .video)
        XCTAssertNil(MediaKind.fromExtension("密碼.txt"))
        XCTAssertFalse(PlaybackFilter.all.accepts(folder("旅行")))
        XCTAssertTrue(PlaybackFilter.photo.accepts(photo("旅行.jpg")))
    }
}
