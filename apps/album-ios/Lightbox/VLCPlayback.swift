import MobileVLCKit
import SwiftUI

@MainActor
final class VLCPlayback {
    struct Update {
        let position: Double
        let duration: Double
        let visible: Bool
        let buffering: Bool
        let ended: Bool
        let failed: Bool
    }
    let player = VLCMediaPlayer()
    private let stream: SMBInputStream
    private let update: (Update) -> Void
    private var polling: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var paused: Bool
    private var crop = ""

    static func prefersVLC(_ name: String) -> Bool {
        !["mp4", "mov", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }

    init(size: Int64, paused: Bool, load: @escaping SMBInputStream.Load, update: @escaping (Update) -> Void) {
        self.stream = SMBInputStream(size: size, load: load)
        self.paused = paused
        self.update = update
        let media = VLCMedia(stream: stream)
        media.addOption(":network-caching=1500")
        media.addOption(":file-caching=1500")
        media.addOption(":no-sub-autodetect-file")
        player.media = media
        player.scaleFactor = 0
        player.videoAspectRatio = nil
        player.videoCropGeometry = nil
        DiagnosticStore.shared.record(.vlcStarted)
    }

    func attach(_ view: UIView) {
        guard !stopped else { return }
        if player.drawable as? UIView !== view { player.drawable = view }
        guard !started else { return }
        started = true
        player.play()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                guard let self, !self.stopped else { break }
                let state = self.player.state
                if self.paused && self.player.isPlaying { self.player.pause() }
                let media = self.player.media
                let value = Update(position: max(0, Double(self.player.time.intValue) / 1000),
                                   duration: max(0, Double(media?.length.intValue ?? 0) / 1000),
                                   visible: (media?.numberOfDisplayedPictures ?? 0) > 0,
                                   buffering: state == .opening || state == .buffering,
                                   ended: state == .ended, failed: state == .error)
                self.update(value)
                if value.ended || value.failed { break }
            }
        }
    }
    func setPaused(_ paused: Bool) {
        self.paused = paused
        guard started, !stopped else { return }
        if paused { player.pause() } else { player.play() }
    }
    func seek(_ seconds: Double) {
        guard !stopped, player.isSeekable, seconds.isFinite else { return }
        player.time = VLCTime(int: Int32(min(Double(Int32.max), max(0, seconds * 1000))))
    }
    func layout(size: CGSize, fill: Bool) {
        guard !stopped, size.width > 0, size.height > 0 else { return }
        let next = fill ? "\(Int(size.width)):\(Int(size.height))" : ""
        guard next != crop else { return }
        crop = next
        player.scaleFactor = 0
        if next.isEmpty { player.videoCropGeometry = nil }
        else { next.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) } }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        polling?.cancel(); polling = nil
        stream.close() // Wake blocked input before VLC's asynchronous stop.
        player.stop()
        player.drawable = nil
    }
}

struct VLCSurface: UIViewRepresentable {
    let playback: VLCPlayback
    let fill: Bool
    func makeUIView(context: Context) -> VLCDrawableView { VLCDrawableView() }
    func updateUIView(_ view: VLCDrawableView, context: Context) {
        view.playback = playback
        view.fill = fill
        playback.attach(view)
        playback.layout(size: view.bounds.size, fill: fill)
    }
    static func dismantleUIView(_ view: VLCDrawableView, coordinator: ()) {
        view.playback?.stop(); view.playback = nil
    }
}

final class VLCDrawableView: UIView {
    weak var playback: VLCPlayback?
    var fill = false
    override init(frame: CGRect) { super.init(frame: frame); clipsToBounds = true; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        playback?.layout(size: bounds.size, fill: fill)
    }
}
