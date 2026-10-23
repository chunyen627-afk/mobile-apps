import XCTest
import UIKit
@testable import Lightbox

@MainActor
final class PhotoZoomTests: XCTestCase {
    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
    }

    private func surface(image: UIImage, paused: Bool = true) -> ZoomablePhotoView {
        let view = ZoomablePhotoView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.setPhoto(image, identity: "first", zoomEnabled: paused)
        view.layoutIfNeeded()
        return view
    }

    func testPhotoFitsAndCentersWithoutCropping() {
        let view = surface(image: photo())
        XCTAssertEqual(view.imageView.frame.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(view.scrollView.contentInset.top, 300, accuracy: 0.1)
        XCTAssertEqual(view.scrollView.contentOffset.y, -300, accuracy: 0.1)
        XCTAssertFalse(view.scrollView.panGestureRecognizer.isEnabled)
        XCTAssertTrue(view.scrollView.pinchGestureRecognizer?.isEnabled == true)
    }

    func testPausedZoomSurvivesViewUpdatesAndBlocksPageSwipes() {
        let image = photo()
        let view = surface(image: image)
        view.scrollView.setZoomScale(3, animated: false)
        view.scrollView.contentOffset = CGPoint(x: 120, y: -100)
        view.setPhoto(image, identity: "first", zoomEnabled: true)
        XCTAssertEqual(view.scrollView.zoomScale, 3, accuracy: 0.01)
        XCTAssertEqual(view.scrollView.contentOffset.x, 120, accuracy: 0.1)
        XCTAssertTrue(view.scrollView.panGestureRecognizer.isEnabled)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(UISwipeGestureRecognizer()))
        view.scrollView.setZoomScale(1, animated: false)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(UISwipeGestureRecognizer()))
        XCTAssertFalse(view.scrollView.panGestureRecognizer.isEnabled)
    }

    func testResumeResetsZoomAndDisablesPinch() {
        let image = photo()
        let view = surface(image: image)
        view.scrollView.setZoomScale(3, animated: false)
        view.setPhoto(image, identity: "first", zoomEnabled: false)
        XCTAssertEqual(view.scrollView.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(view.scrollView.maximumZoomScale, 1)
        XCTAssertFalse(view.scrollView.pinchGestureRecognizer?.isEnabled == true)
        XCTAssertFalse(view.scrollView.panGestureRecognizer.isEnabled)
        XCTAssertEqual(view.scrollView.contentOffset.x, 0, accuracy: 0.1)
    }

    func testSwitchAndDelayedImageReplacementEachResetZoom() {
        let image = photo()
        let view = surface(image: image)
        view.scrollView.setZoomScale(3, animated: false)
        // The previous image remains visible while the next entry loads.
        view.setPhoto(image, identity: "second", zoomEnabled: false)
        XCTAssertEqual(view.scrollView.zoomScale, 1, accuracy: 0.01)
        view.setPhoto(photo(), identity: "second", zoomEnabled: true)
        XCTAssertEqual(view.scrollView.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(view.imageView.frame.size, CGSize(width: 400, height: 200))
    }

    func testRotationRefitsPhotoAndResetsOffset() {
        let view = surface(image: photo())
        view.scrollView.setZoomScale(3, animated: false)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(view.scrollView.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(view.imageView.frame.size, CGSize(width: 800, height: 400))
        XCTAssertEqual(view.scrollView.contentOffset.x, 0, accuracy: 0.1)
        XCTAssertEqual(view.scrollView.contentOffset.y, 0, accuracy: 0.1)
    }
}
