import DeskRemoteCore
import SwiftUI

/// The PC's webcam, live while this page is open (helper 0.5.41): the phone asks for one frame
/// after another, each answered with the next picture the camera took, and the PC switches the
/// camera off a few seconds after the last frame was asked for. So leaving this page, or the app
/// going to the background, turns the camera off; nothing is recorded anywhere.
struct DeskCameraView: View {
    @ObservedObject var store: DeskStore
    let pcID: UUID
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var frames = 0
    @State private var frameAt: Date?
    @State private var perSecond = 0.0

    var body: some View {
        VStack(spacing: 8) {
            if let failure {
                DeskNotice(text: failure, tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityIdentifier("camera-error")
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("鏡頭畫面")
                    .accessibilityIdentifier("camera-image")
            } else if failure == nil {
                ProgressView("正在打開鏡頭…").frame(maxHeight: .infinity)
            } else {
                Spacer()
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .accessibilityIdentifier("camera-note")
        }
        .navigationTitle("鏡頭")
        .navigationBarTitleDisplayMode(.inline)
        // Restarted whenever the scene phase changes: in the background nothing is asked for,
        // and the PC closes the camera on its own.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await stream()
        }
    }

    private var note: String {
        guard let frameAt, frames > 0 else { return "鏡頭只在這一頁開著時開啟，離開這頁就關掉。" }
        return "每秒約 \(perSecond.formatted(.number.precision(.fractionLength(1)))) 張，最新畫面 \(frameAt.formatted(date: .omitted, time: .standard))；離開這頁鏡頭就關。"
    }

    private func stream() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼"
            return
        }
        var recent: [Date] = []
        while !Task.isCancelled {
            do {
                let data = try await client.cameraFrame()
                guard let picture = UIImage(data: data) else {
                    failure = DeskText.failure(.badResponse)
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let now = Date()
                image = picture
                failure = nil
                frames += 1
                frameAt = now
                recent.append(now)
                recent.removeAll { now.timeIntervalSince($0) > 3 }
                perSecond = Double(recent.count) / 3
            } catch {
                if Task.isCancelled { return }
                if let text = DeskNetwork.shared.failureText(error) { failure = text }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
