import SwiftUI

/// The standalone app's only @main file. The toolbox leaves this file out and shows
/// `DeskRemoteRootView` in its own tab instead.
@main
struct DeskRemoteApp: App {
    var body: some Scene {
        WindowGroup { DeskRemoteRootView() }
    }
}
