import SwiftUI

/// The toolbox: one app on the phone (one Apple App ID, one renewal) with each tool as a tab.
/// It keeps the photo album's bundle identifier, so installing it over the album keeps the
/// album's settings and saved password. The tools' screens come from their own app folders
/// (apps/album-ios, apps/miner-status-ios); nothing is copied here.
@main
struct ToolboxApp: App {
    var body: some Scene {
        WindowGroup {
            ToolboxRoot()
                .albumDiagnosticsLifecycle()
        }
    }
}

enum ToolboxTool: String, CaseIterable {
    case album, miner
}

struct ToolboxRoot: View {
    /// The last tool used, opened again on the next launch.
    @AppStorage("toolbox.tool") private var tool = ToolboxTool.album.rawValue

    var body: some View {
        TabView(selection: $tool) {
            AlbumRootView()
                .tabItem { Label("相簿", systemImage: "photo.on.rectangle.angled") }
                .tag(ToolboxTool.album.rawValue)
            RootView()
                .tabItem { Label("礦機狀態", systemImage: "cpu") }
                .tag(ToolboxTool.miner.rawValue)
        }
        .onAppear { tool = Self.startTool(stored: tool) }
    }

    /// UI tests choose the starting tool. With TOOLBOX_TOOL unset, the album's own UI tests
    /// (LIGHTBOX_UI_TEST) start in the album as they do in the standalone album app.
    static func startTool(stored: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let requested = environment["TOOLBOX_TOOL"], ToolboxTool(rawValue: requested) != nil {
            return requested
        }
        if environment["LIGHTBOX_UI_TEST"] == "1" {
            return ToolboxTool.album.rawValue
        }
        return ToolboxTool(rawValue: stored) != nil ? stored : ToolboxTool.album.rawValue
    }
}
