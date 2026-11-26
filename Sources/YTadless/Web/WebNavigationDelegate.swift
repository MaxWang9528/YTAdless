// WebNavigationDelegate — owner: Module B (PLAN.md §6.2 layer 3).
//
// WKNavigationDelegate + WKUIDelegate for one webview. Full loads, server redirects,
// target=_blank and window.open all go through WebViewStore.route (Router.decide). In-page taps
// and SPA pushes are router.js's; they never reach here.

import UIKit
import WebKit
import YTCore

@MainActor
final class WebNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let role: WebRole
    private weak var store: WebViewStore?

    /// NSURLErrorCancelled, and WebKit's "frame load interrupted by policy change" (our own cancels).
    private static let ignoredErrors: Set<Int> = [NSURLErrorCancelled, 102]

    init(role: WebRole, store: WebViewStore) {
        self.role = role
        self.store = store
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let store, let url = navigationAction.request.url else { return .allow }
        guard let targetFrame = navigationAction.targetFrame else {
            // target=_blank: route it, and keep an allowed web page in this webview.
            if store.route(url, role: role, trigger: .windowOpen), Self.isWebURL(url) {
                webView.load(navigationAction.request)
            }
            return .cancel
        }
        guard targetFrame.isMainFrame else { return .allow }
        let trigger: NavigationTrigger =
            navigationAction.navigationType == .linkActivated ? .click : (webView.url == nil ? .initial : .location)
        return store.route(url, role: role, trigger: trigger) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if role == .browse {
            store?.updateBrowseTitle(webView.title, from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error, phase: "load", in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error, phase: "provisional load", in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store?.debugLog.native(.error, "WebView", "\(role.rawValue): web content process terminated; reloading \(webView.url?.absoluteString ?? "-")")
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// window.open that slipped past router.js: route it and never create a second webview.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let store, let url = navigationAction.request.url, Self.isWebURL(url) else { return nil }
        if store.route(url, role: role, trigger: .windowOpen) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: Helpers

    private func report(_ error: Error, phase: String, in webView: WKWebView) {
        let ns = error as NSError
        if Self.ignoredErrors.contains(ns.code) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? webView.url?.absoluteString ?? "-"
        store?.debugLog.native(.warn, "WebView", "\(role.rawValue) \(phase) failed (\(ns.domain) \(ns.code)): \(ns.localizedDescription) — \(failing)")
    }

    private static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }
}
