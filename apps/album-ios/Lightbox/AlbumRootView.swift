import SwiftUI

/// The album below the scene: the standalone app's window and the toolbox's album tab both show
/// this.
struct AlbumRootView: View {
    var body: some View {
        Group {
            #if DEBUG && targetEnvironment(simulator)
            if SimulatorFixtures.active { SimulatorFixturesView() }
            else { LibraryView() }
            #else
            LibraryView()
            #endif
        }
        .tint(Color(red: 0.16, green: 0.36, blue: 0.29))
    }
}

extension View {
    /// Starts the album's diagnostics and tells them whether the app is in the foreground. Applied
    /// once at the window root, so it runs whichever screen or toolbox tab is showing.
    func albumDiagnosticsLifecycle() -> some View {
        modifier(AlbumDiagnosticsLifecycle())
    }
}

private struct AlbumDiagnosticsLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task {
                AppDiagnostics.shared.start()
                if scenePhase == .active { DiagnosticStore.shared.setActive(true) }
            }
            .onChange(of: scenePhase) { _, phase in
                AppDiagnostics.shared.start()
                if phase == .active { DiagnosticStore.shared.setActive(true) }
                else if phase == .background { DiagnosticStore.shared.setActive(false) }
            }
    }
}
