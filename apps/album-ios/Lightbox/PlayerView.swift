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

    init(entries: [AlbumEntry], service: SMBService, interval: Double, library: LibraryModel) {
        self.library = library
        _playback = StateObject(wrappedValue: PlayerModel(entries: entries, service: service, interval: interval))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = playback.image {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                }.ignoresSafeArea()
            }
            if let player = playback.player {
                VideoPlayer(player: player).padding(.top, 50).padding(.bottom, 135)
            }
            if playback.entry.kind == .photo {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { playback.revealControls() }
                    .gesture(DragGesture(minimumDistance: 40).onEnded { gesture in
                        guard abs(gesture.translation.width) > abs(gesture.translation.height) else { return }
                        if gesture.translation.width < 0 { playback.next() } else { playback.previous() }
                    })
            }
            if playback.loading { ProgressView("讀取中…").tint(.white).foregroundStyle(.white).padding(22).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)).allowsHitTesting(false) }
            if let message = playback.message {
                Text(message).multilineTextAlignment(.center).foregroundStyle(.white).padding(24).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14)).padding(24).allowsHitTesting(false)
            }
            if playback.controlsVisible {
                VStack {
                    HStack {
                        Button { playback.stop(); dismiss() } label: { Label("返回", systemImage: "chevron.left") }
                        Spacer()
                        Button { library.toggleFavorite(playback.entry.path) } label: {
                            Image(systemName: library.favorites.contains(playback.entry.path) ? "heart.fill" : "heart").foregroundStyle(library.favorites.contains(playback.entry.path) ? .pink : .white)
                        }.accessibilityLabel("收藏此項目")
                    }.padding().background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 12) {
                        Text(playback.entry.name).font(.caption).lineLimit(1)
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
    }
}

private struct PlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).padding(.horizontal, 6)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
