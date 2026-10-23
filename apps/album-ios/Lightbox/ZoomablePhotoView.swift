import SwiftUI
import UIKit

/// UIKit supplies anchored two-finger zoom, bounded scrolling and deceleration.
/// This view owns photo gestures; no transparent SwiftUI gesture layer sits above it.
struct ZoomablePhotoSurface: UIViewRepresentable {
    let image: UIImage
    let identity: String
    let zoomEnabled: Bool
    let tapped: () -> Void
    let zoomBegan: () -> Void
    let next: () -> Void
    let previous: () -> Void

    func makeUIView(context: Context) -> ZoomablePhotoView { ZoomablePhotoView() }

    func updateUIView(_ view: ZoomablePhotoView, context: Context) {
        view.tapped = tapped
        view.zoomBegan = zoomBegan
        view.next = next
        view.previous = previous
        view.setPhoto(image, identity: identity, zoomEnabled: zoomEnabled)
    }
}

final class ZoomablePhotoView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scrollView = UIScrollView()
    let imageView = UIImageView()
    var tapped: (() -> Void)?
    var zoomBegan: (() -> Void)?
    var next: (() -> Void)?
    var previous: (() -> Void)?
    private(set) var zoomEnabled = false
    private var identity: String?
    private var viewportSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        scrollView.bouncesZoom = false
        scrollView.accessibilityIdentifier = "photoViewport"
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = "照片"
        imageView.accessibilityIdentifier = "displayedPhoto"
        addSubview(scrollView)
        scrollView.addSubview(imageView)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(didSwipe(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPhoto(_ image: UIImage, identity: String, zoomEnabled: Bool) {
        let changed = self.identity != identity || imageView.image !== image
        let resumed = self.zoomEnabled && !zoomEnabled
        self.identity = identity
        self.zoomEnabled = zoomEnabled
        imageView.image = image
        if changed || resumed { resetToFit() }
        scrollView.maximumZoomScale = zoomEnabled ? 5 : 1
        scrollView.pinchGestureRecognizer?.isEnabled = zoomEnabled
        updatePanAndAccessibility()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        if viewportSize != bounds.size {
            viewportSize = bounds.size
            // Rotation must never leave an old zoom offset outside the new viewport.
            resetToFit()
        }
    }

    private func resetToFit() {
        scrollView.setZoomScale(1, animated: false)
        scrollView.contentInset = .zero
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let factor = min(bounds.width / image.size.width, bounds.height / image.size.height)
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * factor, height: image.size.height * factor))
        scrollView.contentSize = imageView.bounds.size
        centerPhoto()
        scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
        updatePanAndAccessibility()
    }

    private func centerPhoto() {
        let horizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
        let vertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func updatePanAndAccessibility() {
        // At fit size, one-finger swipes belong to next/previous. Once enlarged,
        // the scroll view owns them even at an edge; dragging must not change media.
        scrollView.panGestureRecognizer.isEnabled = zoomEnabled && scrollView.zoomScale > 1.01
        imageView.accessibilityValue = "縮放 \(Int((scrollView.zoomScale * 100).rounded()))%"
        imageView.accessibilityHint = zoomEnabled ? "雙指縮放；放大後拖移，雙點放大或還原" : "暫停後可雙指縮放"
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomBegan?() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPhoto()
        updatePanAndAccessibility()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is UISwipeGestureRecognizer) || scrollView.zoomScale <= 1.01
    }

    @objc private func didTap() { tapped?() }
    @objc private func didSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else { return }
        if gesture.direction == .left { next?() } else { previous?() }
    }
    @objc private func didDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard zoomEnabled else { return }
        zoomBegan?()
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 3
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                      width: size.width, height: size.height), animated: true)
        }
    }
}
