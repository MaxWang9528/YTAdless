// WebViewStore — owner: Module B (PLAN.md §5.5, §6.2). Phase 0 wrote this minimal working version.
//
// Owns the two long-lived WKWebViews (D2): created once, sharing WKWebsiteDataStore.default()
// (one login), with the manifest's scripts in the page world (D5, D7) and one message handler
// (`ytadless`) feeding BridgeEventHub. Not yet here (Module B): content rules, user agent,
// router.js `route` messages, Debug log/capture.

import os
import UIKit
import WebKit
import YTAssets
import YTCore

@MainActor
final class WebViewStore: PlayerControlling {
    let browseWebView: WKWebView
    let playerWebView: WKWebView

    static let homeURL = URL(string: "https://m.youtube.com/")!
    static let blankURL = URL(string: "about:blank")!

    private let session: PlayerSession
    private let hub: BridgeEventHub
    /// WKWebView holds its navigation delegate weakly.
    private var navigationDelegates: [WebNavigationDelegate] = []

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "WebViewStore")

    init(session: PlayerSession, hub: BridgeEventHub) {
        self.session = session
        self.hub = hub
        let plans = Self.injectionPlans()
        browseWebView = Self.makeWebView(role: .browse, scripts: plans[.browse] ?? [], hub: hub)
        playerWebView = Self.makeWebView(role: .player, scripts: plans[.player] ?? [], hub: hub)
        for role in WebRole.allCases {
            let delegate = WebNavigationDelegate(role: role, store: self)
            navigationDelegates.append(delegate)
            webView(for: role).navigationDelegate = delegate
        }
        browseWebView.load(URLRequest(url: Self.homeURL))
    }

    func webView(for role: WebRole) -> WKWebView {
        role == .browse ? browseWebView : playerWebView
    }

    // MARK: PlayerControlling

    func open(_ request: VideoRequest) {
        session.request = request
        session.playback = PlaybackState()
        playerWebView.load(URLRequest(url: request.watchURL))  // full load (D15)
        if session.presentation == .hidden {
            session.presentation = .expanded
        }
    }

    func close() {
        playerWebView.pauseAllMediaPlayback(completionHandler: nil)
        playerWebView.stopLoading()
        playerWebView.load(URLRequest(url: Self.blankURL))
        session.request = nil
        session.presentation = .hidden
        session.playback = PlaybackState()
    }

    @discardableResult
    func send(_ command: JSCommand) async throws -> String? {
        try await send(command, to: .player)
    }

    /// Runs a command in either webview (`capture` goes to both, from the Debug menu).
    @discardableResult
    func send(_ command: JSCommand, to role: WebRole) async throws -> String? {
        let result = try await webView(for: role).callAsyncJavaScript(
            JSCommand.functionBody,
            arguments: ["name": command.name, "args": command.argumentsJSON],
            in: nil,
            contentWorld: .page
        )
        return try JSCommandResult.json(from: result)
    }

    // MARK: Routing

    /// Carries out a router decision. Returns true when the navigation itself should proceed.
    func perform(_ decision: RouteDecision) -> Bool {
        switch decision {
        case .allow:
            return true
        case .cancel:
            return false
        case .openInPlayer(let request):
            open(request)
            return false
        case .openInBrowse(let url):
            browseWebView.load(URLRequest(url: url))
            session.collapseForBrowsing()
            return false
        case .openExternally(let url):
            UIApplication.shared.open(url)
            return false
        }
    }

    // MARK: Construction

    private static func makeWebView(role: WebRole, scripts: [InjectedScript], hub: BridgeEventHub) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()                  // one login for both views (D2)
        configuration.allowsInlineMediaPlayback = true               // both views (D14)
        configuration.allowsPictureInPictureMediaPlayback = true
        // Browse never starts media on its own; routed videos autoplay in the player (D14).
        configuration.mediaTypesRequiringUserActionForPlayback = role == .browse ? .all : []

        let controller = WKUserContentController()
        for script in scripts {
            controller.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.injection == .start ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: script.mainFrameOnly,
                in: .page
            ))
        }
        controller.add(ScriptMessageProxy(role: role, hub: hub), contentWorld: .page,
                       name: ScriptConfig.messageHandlerName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = role == .browse
        return webView
    }

    private static func injectionPlans() -> [WebRole: [InjectedScript]] {
        do {
            let manifest = try ScriptManifest.parse(YTAssets.text("manifest.json"))
            for problem in manifest.problems() {
                logger.error("manifest: \(problem, privacy: .public)")
            }
            var plans: [WebRole: [InjectedScript]] = [:]
            for role in WebRole.allCases {
                plans[role] = try manifest.injectionPlan(for: role, debug: isDebugBuild, build: buildString,
                                                         load: YTAssets.text)
            }
            return plans
        } catch {
            logger.fault("injected scripts unavailable: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static var buildString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Decodes `webkit.messageHandlers.ytadless` messages and publishes them. Holds the hub weakly:
/// WKUserContentController retains its handlers.
@MainActor
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let role: WebRole
    private weak var hub: BridgeEventHub?

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "Bridge")

    init(role: WebRole, hub: BridgeEventHub) {
        self.role = role
        self.hub = hub
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        do {
            let decoded = try BridgeMessage.decode(message.body)
            hub?.publish(.init(role: role, isMainFrame: decoded.isMainFrame, message: decoded.message))
        } catch {
            Self.logger.error("\(self.role.rawValue, privacy: .public): undecodable bridge message: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Routes main-frame navigations through `Router.decide` (a stub returning `.allow` until Module B).
@MainActor
final class WebNavigationDelegate: NSObject, WKNavigationDelegate {
    private let role: WebRole
    private weak var store: WebViewStore?

    init(role: WebRole, store: WebViewStore) {
        self.role = role
        self.store = store
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let store, let url = navigationAction.request.url else { return .allow }
        guard let targetFrame = navigationAction.targetFrame else {
            // target=_blank / window.open: route it, and keep allowed pages in this webview.
            if store.perform(Router.decide(url, role: role, trigger: .windowOpen)) {
                webView.load(navigationAction.request)
            }
            return .cancel
        }
        guard targetFrame.isMainFrame else { return .allow }
        let trigger: NavigationTrigger =
            navigationAction.navigationType == .linkActivated ? .click : (webView.url == nil ? .initial : .location)
        return store.perform(Router.decide(url, role: role, trigger: trigger)) ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
