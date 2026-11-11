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
    @State private var lastBytes = 0
    /// Off = data saver (the default, about 15 KB a frame); on = the clear picture (about 34 KB).
    @State private var clear = false
    /// The light the PC watches in this picture (helper 0.5.45), read every half minute while here.
    @State private var light: LightReport?

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
            if let light {
                DeskLightPanel(light: light)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $clear) { Label("清晰", systemImage: clear ? "sparkles" : "leaf") }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("camera-clear")
                    .accessibilityHint("關著是省流量，打開是清晰")
            }
        }
        // Restarted whenever the scene phase changes: in the background nothing is asked for,
        // and the PC closes the camera on its own.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await stream()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await watchLight()
        }
    }

    private var note: String {
        let mode = clear ? "清晰" : "省流量"
        guard let frameAt, frames > 0 else { return "\(mode)模式。鏡頭只在這一頁開著時開啟，離開這頁就關掉。" }
        let kb = (Double(lastBytes) / 1024).formatted(.number.precision(.fractionLength(0)))
        return "\(mode)：每秒約 \(perSecond.formatted(.number.precision(.fractionLength(1)))) 張、每張約 \(kb) KB，最新畫面 \(frameAt.formatted(date: .omitted, time: .standard))；離開這頁鏡頭就關。"
    }

    /// Today's changes of the watched light, refreshed every 30 seconds; a PC that watches no
    /// light (404) is asked once more a minute later, in case the helper was just restarted.
    private func watchLight() async {
        guard let client = store.client(pcID) else { return }
        while !Task.isCancelled {
            do {
                light = try await client.light(days: 1)
                try? await Task.sleep(for: .seconds(30))
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stream() async {
        guard let client = store.client(pcID) else {
            failure = "沒有連線密碼"
            return
        }
        var recent: [Date] = []
        while !Task.isCancelled {
            do {
                let data = try await client.cameraFrame(clear: clear)
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
                lastBytes = data.count
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

/// What the PC's light watch says (helper 0.5.45): the light's state now and today's changes.
/// The long record is light_log.csv on the PC (the user 11/11: 長時間紀錄統計的資料存在電腦就好).
struct DeskLightPanel: View {
    let light: LightReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // A Label would put the identifier on its image (CI 11/11: the test found an Image whose
            // label is the symbol name); the text carries it.
            HStack(spacing: 6) {
                Image(systemName: light.on == true && light.watching ? "lightbulb.fill" : "lightbulb")
                    .accessibilityHidden(true)
                Text(headline)
                    .accessibilityIdentifier("camera-light")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(light.on == true && light.watching ? Color.orange : Color.primary)
            Text(today)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("camera-light-today")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private var headline: String {
        let state: String
        if !light.watching {
            state = "非監看時段"
        } else if let on = light.on {
            state = on ? "亮著" : "暗的"
        } else {
            state = light.error ?? "判斷中"
        }
        var line = "\(light.name)：\(state)"
        if light.watching, let level = light.level {
            line += "（亮度 \(Int(level.rounded()))）"
        }
        if light.watching, light.on != nil, let since = light.summary.sinceTime {
            line += "，自 \(since)"
        }
        if light.on != nil, let error = light.error {
            line += "（\(error)）"
        }
        return line
    }

    private var today: String {
        let window = light.hours.count == 2 ? "\(light.weekdaysOnly ? "上班日 " : "")\(light.hours[0]):00–\(light.hours[1]):00 監看" : ""
        guard let day = light.days.first else { return window }
        if day.changes.isEmpty {
            return "今天還沒有變化" + (window.isEmpty ? "" : "；" + window)
        }
        let changes = day.changes.map { "\($0.time.prefix(5)) \($0.on ? "亮" : "暗")" }.joined(separator: "、")
        return "今天：" + changes + (window.isEmpty ? "" : "；" + window)
    }
}
