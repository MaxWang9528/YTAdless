import SwiftUI

@main
struct YTadlessApp: App {
    var body: some Scene {
        WindowGroup {
            YouTubeWebView(url: URL(string: "https://m.youtube.com/")!)
        }
    }
}
