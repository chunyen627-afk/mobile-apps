import DeskRemoteCore
import SwiftUI

/// Entry point of the desk remote tool: PC list → Claude/Codex → conversations → chat.
/// The standalone app and the toolbox tab both show this view.
struct DeskRemoteRootView: View {
    @StateObject private var store = DeskStore()
    @State private var path: [DeskRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            DeskPCListView(store: store)
                .navigationDestination(for: DeskRoute.self) { route in
                    switch route {
                    case .pc(let id):
                        DeskPCView(store: store, pcID: id)
                    case .sessions(let id, let app):
                        DeskSessionListView(store: store, pcID: id, app: app) { session in
                            path.append(.chat(id, app, session))
                        }
                    case .chat(let id, let app, let session):
                        DeskChatView(store: store, pcID: id, app: app, session: session)
                    case .screen(let id):
                        DeskScreenView(store: store, pcID: id)
                    }
                }
        }
        .onOpenURL { url in open(url) }
        .onAppear {
            // UI tests hand the link in at launch: a link opened from outside goes through a
            // system confirmation first.
            if store.uiTest, let link = ProcessInfo.processInfo.environment["DESK_UI_OPEN_URL"], let url = URL(string: link) {
                open(url)
            }
        }
    }

    /// A notification's link: straight to that PC's conversation (or its administrator
    /// requests, which are on the PC page). The PC is matched by name, else the only PC.
    private func open(_ url: URL) {
        guard let link = DeskLink(url) else { return }
        guard let pc = store.pcs.first(where: { $0.name == link.pc }) ?? (store.pcs.count == 1 ? store.pcs.first : nil)
        else { return }
        var route: [DeskRoute] = [.pc(pc.id)]
        if let app = link.app, let session = link.session {
            route += [.sessions(pc.id, app), .chat(pc.id, app, SessionSummary(id: session, title: link.title ?? "對話"))]
        }
        path = route
    }
}

enum DeskRoute: Hashable {
    case pc(UUID)
    case sessions(UUID, DeskApp)
    case chat(UUID, DeskApp, SessionSummary)
    case screen(UUID)
}

extension View {
    /// Runs `action` now and then every `seconds` while the app is in the foreground and the view
    /// is on screen; leaving the foreground cancels it (the app never reads in the background).
    func deskForegroundLoop(every seconds: UInt64, _ action: @escaping @MainActor () async -> Void) -> some View {
        modifier(DeskForegroundLoop(seconds: seconds, action: action))
    }
}

private struct DeskForegroundLoop: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let seconds: UInt64
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }
}

/// Error or note strip at the top of a list.
struct DeskNotice: View {
    let text: String
    var systemImage = "exclamationmark.triangle"
    var tint: Color = .orange

    var body: some View {
        // Combined so the caller's identifier lands on one element holding the text, not the icon.
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}
