// App entry point. Owner: P0 (frozen).

import SwiftUI

@main
struct YTadlessApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(services: AppServices.shared)
        }
    }
}
