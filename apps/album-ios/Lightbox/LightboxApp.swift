import SwiftUI

@main
struct LightboxApp: App {
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if SimulatorFixtures.active { SimulatorFixturesView() }
                else { LibraryView() }
                #else
                LibraryView()
                #endif
            }
                .tint(Color(red: 0.16, green: 0.36, blue: 0.29))
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
}
