import AVKit
import SwiftUI

@MainActor
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var library: LibraryModel
    @StateObject private var playback: PlayerModel
    @State private var seeking = false
    @State private var seekValue = 0.0
    @State private var seekingVideo = false
    @State private var videoSeekValue = 0.0

    init(entries: [AlbumEntry], service: SMBService, interval: Double, library: LibraryModel) {
        self.library = library
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorFixtures.active {
            _playback = StateObject(wrappedValue: PlayerModel(entries: entries, service: service, interval: interval,
                photoLoad: { try await SimulatorFixtures.photo($0) }, videoAsset: { _ in AVURLAsset(url: SimulatorFixtures.videoURL) },
                videoRead: { try await SimulatorFixtures.readVideo($0, range: $1) }))
            return
        }
        #endif
        _playback = StateObject(wrappedValue: PlayerModel(entries: entries, service: service, interval: interval))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = playback.image {
                ZoomablePhotoSurface(image: image, identity: playback.entry.path,
                    zoomEnabled: playback.paused && playback.entry.kind == .photo && !playback.loading && playback.message == nil,
                    tapped: { playback.toggleControls() }, zoomBegan: { playback.hideControls() },
                    next: { playback.next() }, previous: { playback.previous() })
                    .ignoresSafeArea()
            }
            if let player = playback.player {
                VideoSurface(player: player) { playback.videoBecameVisible(player) }
                    .ignoresSafeArea().opacity(playback.videoReady ? 1 : 0)
                    .accessibilityIdentifier("videoSurface")
            }
            if let vlc = playback.vlc {
                VLCSurface(playback: vlc)
                    .ignoresSafeArea().opacity(playback.videoReady ? 1 : 0)
                    .accessibilityIdentifier("vlcVideoSurface")
            }
            if playback.image == nil || playback.entry.kind != .photo {
                Color.clear.contentShape(Rectangle()).accessibilityIdentifier("playerCanvas")
                    .onTapGesture { playback.toggleControls() }
                    .gesture(DragGesture(minimumDistance: 40).onEnded { gesture in
                        guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                        if gesture.translation.width < 0 { playback.next() } else { playback.previous() }
                    })
            }
            if playback.loading && playback.image == nil && !playback.videoReady {
                ProgressView("讀取中…").tint(.white).foregroundStyle(.white).padding(22).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false)
            }
            if let message = playback.message {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white).padding(24).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14)).padding(24).allowsHitTesting(false)
            }
            if playback.controlsVisible {
                VStack {
                    HStack {
                        Button { playback.stop(); dismiss() } label: { Label("返回", systemImage: "chevron.left") }.accessibilityIdentifier("leavePlayer")
                        Spacer()
                        Button { library.toggleFavorite(playback.entry.path); playback.revealControls() } label: {
                            Image(systemName: library.favorites.contains(playback.entry.path) ? "heart.fill" : "heart").foregroundStyle(library.favorites.contains(playback.entry.path) ? .pink : .white)
                        }.accessibilityLabel("收藏此項目")
                    }.padding().background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 12) {
                        Text(playback.entry.name).font(.caption).lineLimit(1)
                        if playback.entry.kind == .video {
                            Text("完整顯示 · 保留原始比例").font(.caption2)
                            if playback.videoDuration > 0 {
                                HStack {
                                    Text(timeLabel(seekingVideo ? videoSeekValue : playback.videoPosition)).monospacedDigit().accessibilityIdentifier("videoTime")
                                    Slider(value: $videoSeekValue, in: 0...playback.videoDuration, onEditingChanged: { editing in
                                        seekingVideo = editing
                                        if !editing { playback.seekVideo(videoSeekValue) }
                                        playback.setInteracting(editing)
                                    }).tint(.white).accessibilityLabel("影片進度")
                                    Text(timeLabel(playback.videoDuration)).monospacedDigit()
                                }.font(.caption2)
                            }
                        }
                        HStack(spacing: 36) {
                            Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("上一個")
                            Button { playback.togglePause() } label: { Image(systemName: playback.paused ? "play.fill" : "pause.fill").font(.title2) }.accessibilityLabel(playback.paused ? "繼續" : "暫停")
                            Button { playback.next() } label: { Image(systemName: "forward.end.fill") }.accessibilityLabel("下一個")
                        }
                        HStack {
                            Text("\(playback.index + 1) / \(playback.entries.count)").font(.caption2).monospacedDigit()
                            if playback.entries.count > 1 {
                                Slider(value: Binding(get: { seeking ? seekValue : Double(playback.index) }, set: { seekValue = $0 }), in: 0...Double(playback.entries.count - 1), step: 1, onEditingChanged: { editing in
                                    if editing { seekValue = Double(playback.index) }
                                    seeking = editing
                                    if !editing { playback.show(Int(seekValue)) }
                                    playback.setInteracting(editing)
                                }).tint(.white).accessibilityLabel("播放清單位置")
                            }
                        }
                    }.padding().background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                }.foregroundStyle(.white).buttonStyle(PlayerButtonStyle())
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { playback.start() }
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.suspend() } }
        .onChange(of: playback.videoPosition) { _, position in
            if !seekingVideo { videoSeekValue = min(position, playback.videoDuration) }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// No native controls or reserved margins: the app's overlay owns visibility and seeking.
private struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let ready: () -> Void

    func makeUIView(context: Context) -> VideoLayerView { VideoLayerView() }
    func updateUIView(_ view: VideoLayerView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.videoLayer.videoGravity = .resizeAspect
        CATransaction.commit()
        view.onReady = ready
        if view.videoLayer.player !== player {
            view.observation = nil
            view.videoLayer.player = player
            view.observation = view.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak view] layer, _ in
                guard layer.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    guard let view, view.videoLayer.player === player, view.videoLayer.isReadyForDisplay else { return }
                    view.onReady?()
                }
            }
        }
    }
    static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) {
        view.observation = nil; view.onReady = nil; view.videoLayer.player = nil
    }
}

private final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var observation: NSKeyValueObservation?
    var onReady: (() -> Void)?

    override init(frame: CGRect) { super.init(frame: frame); clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).padding(.horizontal, 6)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
