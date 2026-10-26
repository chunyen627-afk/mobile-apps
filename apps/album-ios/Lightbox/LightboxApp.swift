import SwiftUI

@main
struct LightboxApp: App {
    var body: some Scene {
        WindowGroup {
            AlbumRootView()
                .albumDiagnosticsLifecycle()
        }
    }
}
