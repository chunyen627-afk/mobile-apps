import DeskRemoteCore
import SwiftUI

/// What the PC's screen shows right now (all monitors), read on demand: look only, no input.
/// Pinch to zoom; "重新整理" takes a new picture.
struct DeskScreenView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    @State private var image: UIImage?
    @State private var takenAt: Date?
    @State private var failure: String?
    @State private var loading = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 8) {
            if let failure {
                DeskNotice(text: failure, tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityIdentifier("screen-error")
            }
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: max(1, UIScreen.main.bounds.width * zoom * pinch))
                        .accessibilityLabel("電腦畫面")
                        .accessibilityIdentifier("screen-image")
                }
                .gesture(MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in zoom = min(max(zoom * value, 1), 5) })
            } else if loading {
                ProgressView("正在讀取電腦畫面…").frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let takenAt {
                Text("截圖時間 \(takenAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("電腦畫面")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
                    .accessibilityLabel("重新整理")
                    .accessibilityIdentifier("screen-refresh")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let data = try await client.screen()
            guard let picture = UIImage(data: data) else {
                failure = DeskText.failure(.badResponse)
                return
            }
            image = picture
            takenAt = Date()
            failure = nil
        } catch let error as HelperFailure {
            if error != .cancelled { failure = DeskText.failure(error) }
        } catch {
            failure = DeskText.failure(.unreachable)
        }
    }
}
