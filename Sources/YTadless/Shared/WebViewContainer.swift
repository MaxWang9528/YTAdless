// WebViewContainer (PLAN.md §5.5, D2). Owner: P0 (frozen).
//
// Hosts one of WebViewStore's long-lived WKWebViews. It never creates one. Put each container in
// exactly one place that is always in the view tree (never in an `if`), and change modes by
// moving or scaling it, so SwiftUI never re-creates it and the webview is never re-parented.

import os
import SwiftUI
import WebKit

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "WebViewContainer")

    func makeUIView(context: Context) -> WKWebView {
        if webView.superview != nil {
            Self.logger.error("WebViewContainer re-parented a live WKWebView; keep each container in one fixed place (D2)")
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
