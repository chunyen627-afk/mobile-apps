// NOT COMPILED, NOT VISUALLY TESTED: written without Swift/Xcode available.
//
// Every launch starts in the offline demo. Live mode reads a user-configured URL with GET only,
// and only while the app is in the foreground. There are no mining controls.

import MinerStatusCore
import SwiftUI

@main
struct MinerStatusApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()
    @State private var selection: String?
    @State private var showingSettings = false

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    OverviewList(model: model, selection: $selection) { showingSettings = true }
                } detail: {
                    NavigationStack {
                        if let selection {
                            MachineDetailView(model: model, machineId: selection)
                        } else {
                            Text("請選擇一台機器").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                NavigationStack {
                    OverviewList(model: model, selection: nil) { showingSettings = true }
                        .navigationDestination(for: String.self) { MachineDetailView(model: model, machineId: $0) }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ModeBanner(model: model) }
        .sheet(isPresented: $showingSettings) { SourceSettingsView(model: model) }
        .onChange(of: scenePhase) { phase in
            model.setForeground(phase == .active)
        }
    }
}

/// Always visible: says whether the screen shows built-in demo data or a user-configured source.
struct ModeBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch model.mode {
            case .demo:
                Label("示範模式：人工編寫資料，非真實礦機連線", systemImage: "theatermasks.fill").font(.footnote.bold())
                if !model.demoNotice.isEmpty { Text(model.demoNotice).font(.caption2) }
                Text("模擬時鐘（已凍結，非目前時間）：\(model.demoClock.map { demoTimestamp($0.wall) } ?? DisplayText.noData)")
                    .font(.caption2.monospacedDigit())
            case .live:
                Label("自訂來源（唯讀）：\(model.endpoint?.url.host ?? DisplayText.noData)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote.bold())
                Text(model.isPolling ? "僅在 App 位於前景時讀取" : "已暫停：App 不在前景時不讀取")
                    .font(.caption2)
                if model.sourceSentDemoData {
                    Text("注意：來源回傳的資料標示為示範資料").font(.caption2.bold())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(model.mode == .demo ? Color.orange.opacity(0.25) : Color.blue.opacity(0.15))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mode-banner")
    }
}
