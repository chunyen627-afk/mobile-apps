import SwiftUI

@main
struct LightboxApp: App {
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
        }
    }
}
