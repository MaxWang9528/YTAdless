import SwiftUI
import WebKit

/// Scaffold only: one WKWebView showing m.youtube.com.
/// Phase 0 (see PLAN.md) replaces this with WebViewStore + WebViewContainer.
struct YouTubeWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // iPhone defaults to fullscreen-only video; YouTube's player must play inline.
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
