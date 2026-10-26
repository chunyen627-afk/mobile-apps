// Every launch starts in the offline demo. Live mode reads a user-configured URL with GET only,
// and only while the app is in the foreground. The screens live in RootView.swift so the
// toolbox app (apps/toolbox-ios) can show the same miner status as one of its tools.

import SwiftUI

@main
struct MinerStatusApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}
