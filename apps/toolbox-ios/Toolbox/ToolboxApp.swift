import SwiftUI

/// The toolbox: one app on the phone (one Apple App ID, one renewal) with each tool as a tab.
/// It keeps the photo album's bundle identifier, so installing it over the album keeps the
/// album's settings and saved password. The tools' screens come from their own app folders
/// (apps/album-ios, apps/miner-status-ios, apps/desk-remote-ios, apps/thermo-ios); nothing is
/// copied here.
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
    case album, miner, desk, thermo
}

struct ToolboxRoot: View {
    /// The last tool used, opened again on the next launch.
    @AppStorage("toolbox.tool") private var tool = ToolboxTool.album.rawValue
    /// A `deskremote://` link (the desk remote's notifications) on its way to the desk remote tab.
    @State private var deskLink: URL?

    var body: some View {
        TabView(selection: $tool) {
            AlbumRootView()
                .tabItem { Label("相簿", systemImage: "photo.on.rectangle.angled") }
                .tag(ToolboxTool.album.rawValue)
            RootView()
                .tabItem { Label("礦機狀態", systemImage: "cpu") }
                .tag(ToolboxTool.miner.rawValue)
            DeskRemoteRootView(link: $deskLink)
                .tabItem { Label("桌面遙控", systemImage: "desktopcomputer") }
                .tag(ToolboxTool.desk.rawValue)
            ThermoRootView()
                .tabItem { Label("溫濕度", systemImage: "thermometer.medium") }
                .tag(ToolboxTool.thermo.rawValue)
        }
        .onAppear { tool = Self.startTool(stored: tool) }
        // Logged with the album's diagnostics, so an unexpected end shows which tab was in use.
        .onChange(of: tool, initial: true) { _, value in
            AppDiagnostics.shared.showTool(ToolboxTool.allCases.firstIndex { $0.rawValue == value } ?? -1)
        }
        // The desk remote's tab may not exist yet while another tab is showing, so its link is
        // taken here: switch to that tab and hand the link over.
        .onOpenURL { url in
            guard Self.isDeskLink(url) else { return }
            tool = ToolboxTool.desk.rawValue
            deskLink = url
        }
    }

    static func isDeskLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "deskremote"
    }

    /// UI tests choose the starting tool. With TOOLBOX_TOOL unset, the album's own UI tests
    /// (LIGHTBOX_UI_TEST) start in the album and the desk remote's (DESK_UI_TEST) in the desk
    /// remote, as they do in their standalone apps.
    static func startTool(stored: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let requested = environment["TOOLBOX_TOOL"], ToolboxTool(rawValue: requested) != nil {
            return requested
        }
        if environment["LIGHTBOX_UI_TEST"] == "1" {
            return ToolboxTool.album.rawValue
        }
        if environment["DESK_UI_TEST"] == "1" {
            return ToolboxTool.desk.rawValue
        }
        return ToolboxTool(rawValue: stored) != nil ? stored : ToolboxTool.album.rawValue
    }
}
