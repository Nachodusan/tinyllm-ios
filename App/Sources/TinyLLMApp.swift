import SwiftUI

@main
struct TinyLLMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Launched with `-headless 1`: run the sweep and report to
                    // stdout instead of waiting for a tap.
                    if Headless.isRequested { await Headless.run() }
                }
        }
    }
}
