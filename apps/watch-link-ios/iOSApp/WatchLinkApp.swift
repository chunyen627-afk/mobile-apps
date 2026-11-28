import SwiftUI
import WatchLinkCore

@main
struct WatchLinkApp: App {
    @StateObject private var model = WatchLinkModel()

    var body: some Scene {
        WindowGroup {
            WatchLinkContentView(model: model, service: model.service)
        }
    }
}
