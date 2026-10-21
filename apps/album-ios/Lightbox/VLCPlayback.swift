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
    private var requestedPosition: Double?
    private var seekDeadline = Date.distantPast

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
                let clock = max(0, Double(self.player.time.intValue) / 1000)
                // VLCKit caches time notifications; a paused seek renders the new
                // frame without refreshing that clock until playback resumes.
                if let requested = self.requestedPosition,
                   abs(clock - requested) < 1 || (!self.paused && Date() > self.seekDeadline) {
                    self.requestedPosition = nil
                }
                let value = Update(position: self.requestedPosition ?? clock,
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
        if !paused { seekDeadline = Date().addingTimeInterval(3) }
        guard started, !stopped else { return }
        if paused { player.pause() } else { player.play() }
    }
    func seek(_ seconds: Double) {
        guard !stopped, player.isSeekable, seconds.isFinite else { return }
        requestedPosition = max(0, seconds)
        seekDeadline = Date().addingTimeInterval(3)
        player.time = VLCTime(int: Int32(min(Double(Int32.max), max(0, seconds * 1000))))
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
    func makeUIView(context: Context) -> VLCDrawableView { VLCDrawableView() }
    func updateUIView(_ view: VLCDrawableView, context: Context) {
        view.playback = playback
        playback.attach(view)
    }
    static func dismantleUIView(_ view: VLCDrawableView, coordinator: ()) {
        view.playback?.stop(); view.playback = nil
    }
}

final class VLCDrawableView: UIView {
    weak var playback: VLCPlayback?
    override init(frame: CGRect) { super.init(frame: frame); clipsToBounds = true; backgroundColor = .black }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
