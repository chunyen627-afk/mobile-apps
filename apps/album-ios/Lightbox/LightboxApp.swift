import SwiftUI

@main
struct LightboxApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(Color(red: 0.16, green: 0.36, blue: 0.29))
        }
    }
}
