import DeskRemoteCore
import SwiftUI

/// Entry point of the desk remote tool: PC list → Claude/Codex → conversations → chat.
/// The standalone app and the toolbox tab both show this view.
struct DeskRemoteRootView: View {
    @StateObject private var store = DeskStore()

    var body: some View {
        NavigationStack {
            DeskPCListView(store: store)
                .navigationDestination(for: DeskRoute.self) { route in
                    switch route {
                    case .pc(let id):
                        DeskPCView(store: store, pcID: id)
                    case .sessions(let id, let app):
                        DeskSessionListView(store: store, pcID: id, app: app)
                    case .chat(let id, let app, let session):
                        DeskChatView(store: store, pcID: id, app: app, session: session)
                    }
                }
        }
    }
}

enum DeskRoute: Hashable {
    case pc(UUID)
    case sessions(UUID, DeskApp)
    case chat(UUID, DeskApp, SessionSummary)
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
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(tint)
    }
}
