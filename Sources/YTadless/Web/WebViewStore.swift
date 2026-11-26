// WebViewStore — owner: Module B (PLAN.md §5.5, §6.2).
//
// Owns the long-lived WKWebViews (D2): the player, and one browse view per bottom-nav tab
// (BrowseTab: Home, Subscriptions, You), so switching tabs keeps each tab's page, feed and scroll.
// All are created once, share WKWebsiteDataStore.default() (one login), and are never recreated;
// a tab's view loads its root page the first time it is shown. They have the manifest's scripts in the page world (D5, D7), one message handler
// (`ytadless`) feeding BridgeEventHub, the Safari user-agent token (D17), and the content-rule
// list (D10), which is added before any view loads its first page. router.js posts `selectTab`
// for a tap on another tab; `browseWebView` is always the tab on screen.
//
// Routing: router.js posts `route` for in-page taps, SPA pushes and window.open; the navigation
// and UI delegates (WebNavigationDelegate.swift) catch full loads and new windows. All of them
// end in Router.decide and `perform`.

import Observation
import os
import UIKit
import WebKit
import YTAssets
import YTCore

@MainActor
final class WebViewStore: PlayerControlling {
    /// One browse webview per tab, created at launch and never recreated (D2).
    let browseWebViews: [BrowseTab: WKWebView]
    /// Which tab is on screen and which tabs have loaded; PlayerLayoutView observes it.
    let tabs = BrowseTabState()
    let playerWebView: WKWebView

    /// The browse webview on screen.
    var browseWebView: WKWebView { browseWebView(for: tabs.selected) }

    func browseWebView(for tab: BrowseTab) -> WKWebView {
        guard let view = browseWebViews[tab] else { preconditionFailure("every BrowseTab has a webview") }
        return view
    }

    /// Every webview: the browse tabs in BrowseTab order, then the player.
    var allWebViews: [WKWebView] { BrowseTab.allCases.map(browseWebView(for:)) + [playerWebView] }
    /// The in-app Debug log (DebugEntryView shows it). Subscribed before anything loads.
    let debugLog: DebugLog

    static let homeURL = URL(string: "https://m.youtube.com/")!
    static let blankURL = URL(string: "about:blank")!
    /// The first page loads without content rules if the rule list isn't ready by then.
    static let contentRulesTimeout: Duration = .seconds(3)
    /// A tap can post both a click route and a history route; one open is enough.
    static let duplicateOpenWindow: TimeInterval = 1

    private let session: PlayerSession
    private let hub: BridgeEventHub
    /// WKWebView holds its navigation and UI delegates weakly.
    private var delegates: [WebNavigationDelegate] = []
    private var hubSubscription: AnyObject?
    private var foregroundObserver: NSObjectProtocol?
    private var titleObservations: [NSKeyValueObservation] = []

    /// The compiled content-rule lists (empty until loaded); `applyContentRules` installs them.
    private(set) var contentRuleLists = ContentRuleLoader.Lists()
    private var rulesReady = false
    private var pendingUntilRulesReady: [@MainActor () -> Void] = []
    private var lastOpen: (request: VideoRequest, date: Date)?

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "WebViewStore")

    init(session: PlayerSession, hub: BridgeEventHub) {
        self.session = session
        self.hub = hub
        let log = DebugLog()
        log.attach(to: hub)
        debugLog = log
        let plans = Self.injectionPlans(log: log)
        var browse: [BrowseTab: WKWebView] = [:]
        for tab in BrowseTab.allCases {
            browse[tab] = Self.makeWebView(role: .browse, scripts: plans[.browse] ?? [], hub: hub, log: log)
        }
        browseWebViews = browse
        playerWebView = Self.makeWebView(role: .player, scripts: plans[.player] ?? [], hub: hub, log: log)
        for (role, view) in BrowseTab.allCases.map({ (WebRole.browse, browse[$0]!) }) + [(.player, playerWebView)] {
            let delegate = WebNavigationDelegate(role: role, store: self)
            delegates.append(delegate)
            view.navigationDelegate = delegate
            view.uiDelegate = delegate
        }
        updateScrollsToTop()
        hubSubscription = hub.subscribe { [weak self] event in
            self?.handle(event)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayerState(reason: "foreground") }
        }
        // WebKit's title follows document.title after SPA navigations too; pageChanged's title is
        // read right after pushState, before YouTube updates it.
        for view in browse.values {
            titleObservations.append(view.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.updateBrowseTitle(webView.title, from: webView) }
            })
        }
        debugLog.native(.info, "WebViewStore", "user agent application name: \(SafariUserAgent.applicationName)")

        showTab(.home, reason: "launch")
        Task { [weak self] in
            guard let self else { return }
            contentRuleLists = await ContentRuleLoader(log: debugLog).load()
            applyContentRules(AppSettings.shared)
            markRulesReady()
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.contentRulesTimeout)
            guard let self, !rulesReady else { return }
            debugLog.native(.warn, "ContentRules", "rule list not ready after \(Self.contentRulesTimeout); loading without it")
            markRulesReady()
        }
    }

    /// The player, or the browse tab on screen.
    func webView(for role: WebRole) -> WKWebView {
        role == .browse ? browseWebView : playerWebView
    }

    // MARK: Browse tabs

    /// Shows `tab`'s webview, loading its root page the first time.
    func showTab(_ tab: BrowseTab, reason: String) {
        if case .show(_, let loadFirst) = BrowseTabDecision.select(tab, loaded: tabs.loaded), loadFirst {
            tabs.loaded.insert(tab)
            let view = browseWebView(for: tab)
            whenRulesReady { view.load(URLRequest(url: tab.url)) }
        }
        let previous = tabs.selected
        tabs.selected = tab
        updateScrollsToTop()
        updateBrowseTitle(browseWebView.title, from: browseWebView)
        debugLog.native(.info, "Tabs", "\(previous.rawValue) → \(tab.rawValue) (\(reason))")
    }

    /// The status-bar tap scrolls a scroll view to the top only when exactly one on screen allows it.
    private func updateScrollsToTop() {
        for tab in BrowseTab.allCases {
            browseWebView(for: tab).scrollView.scrollsToTop = tab == tabs.selected
        }
    }

    // MARK: PlayerControlling

    func open(_ request: VideoRequest) {
        if let lastOpen, lastOpen.request == request, Date().timeIntervalSince(lastOpen.date) < Self.duplicateOpenWindow {
            return
        }
        lastOpen = (request, Date())
        // Tapping the video the player already shows (e.g. from the mini-player's browse page)
        // brings it back instead of reloading it.
        if request.startSeconds == nil, session.request != nil, let current = playerWebView.url,
           case .video(let loaded) = Router.classify(current), loaded.id == request.id {
            session.presentation = .expanded
            debugLog.native(.info, "WebViewStore", "open \(request.id): already loaded; expanding")
            return
        }
        session.request = request
        session.playback = PlaybackState()
        whenRulesReady { [weak self] in
            self?.playerWebView.load(URLRequest(url: request.watchURL))  // full load (D15)
        }
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
        lastOpen = nil
    }

    @discardableResult
    func send(_ command: JSCommand) async throws -> String? {
        try await send(command, to: .player)
    }

    /// Runs a command in either webview (the Debug menu's `capture` goes to both).
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
            switch BrowseTabDecision.forURL(url, loaded: tabs.loaded) {
            case .show(let tab, _):
                showTab(tab, reason: "open \(url.absoluteString)")
            case .loadInCurrent(let url):
                let view = browseWebView
                whenRulesReady { view.load(URLRequest(url: url)) }
            }
            session.collapseForBrowsing()
            return false
        case .openExternally(let url):
            UIApplication.shared.open(url)
            return false
        }
    }

    /// Decides, logs and performs. Returns true when the navigation should proceed in `role`.
    func route(_ url: URL, role: WebRole, trigger: NavigationTrigger) -> Bool {
        let decision = Router.decide(url, role: role, trigger: trigger)
        let level: LogLevel = decision == .allow ? .debug : .info
        debugLog.native(level, "Router", "\(role.rawValue) \(trigger.rawValue) \(url.absoluteString) → \(Self.describe(decision))")
        return perform(decision)
    }

    /// A `route` message from router.js: the page already stopped the navigation (click,
    /// window.open) or has already moved (history).
    private func handleRoute(_ text: String, trigger: NavigationTrigger, role: WebRole) {
        guard let url = URL(string: text) else {
            debugLog.native(.warn, "Router", "route with an invalid URL: \(text)")
            return
        }
        let view = webView(for: role)
        if route(url, role: role, trigger: trigger) {
            // router.js and Router.decide disagree. The page cancelled a tap or window.open, so
            // carry the navigation out here; a history push already happened.
            debugLog.native(.warn, "Router", "router.js routed a URL that Router allows: \(text)")
            if trigger == .click || trigger == .windowOpen {
                view.load(URLRequest(url: url))
            }
            return
        }
        // The SPA already shows the page that belongs elsewhere: take it back.
        if trigger == .history, view.canGoBack {
            view.goBack()
        }
    }

    // MARK: Bridge events

    private func handle(_ event: BridgeEventHub.Event) {
        guard event.isMainFrame else { return }
        switch event.message {
        case .route(let url, let trigger):
            handleRoute(url, trigger: trigger, role: event.role)
        case .ready where event.role == .player:
            refreshPlayerState(reason: "ready")
        case .selectTab(let tab) where event.role == .browse:
            showTab(tab, reason: "tap")
        default:
            break
        }
    }

    /// Only the tab on screen names the browse page.
    func updateBrowseTitle(_ title: String?, from view: WKWebView) {
        guard view === browseWebView else { return }
        if let title, !title.isEmpty { session.browseTitle = title }
    }

    /// Reloads every browse tab that has loaded a page.
    func reloadBrowseTabs() {
        for tab in tabs.loaded { browseWebView(for: tab).reload() }
    }

    private struct PlayerStateResult: Decodable {
        let meta: VideoMeta?
        let playback: PlaybackSnapshot?
        let presentation: MediaPresentation?
    }

    /// Re-queries `state` (PLAN.md §5.4) and applies it to the session.
    func refreshPlayerState(reason: String) {
        guard session.request != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let json = try await send(.state, to: .player) else { return }
                let state = try JSONDecoder().decode(PlayerStateResult.self, from: Data(json.utf8))
                if let meta = state.meta { session.playback.apply(.videoMeta(meta)) }
                if let playback = state.playback { session.playback.apply(.playback(playback)) }
                if let presentation = state.presentation { session.playback.apply(.presentation(presentation)) }
            } catch {
                debugLog.native(.debug, "WebViewStore", "state (\(reason)) failed: \(error)")
            }
        }
    }

    // MARK: Content rules (Debug › Settings toggles them)

    /// Adds the lists the settings enable to every webview and removes the others. WebKit uses the
    /// change for new requests; the current page keeps what it already loaded until a reload.
    func applyContentRules(_ settings: AppSettings) {
        let enabled = [
            settings.blockAdRequests ? contentRuleLists.network : nil,
            settings.hideAdElements ? contentRuleLists.cosmetic : nil,
        ].compactMap { $0 }
        for view in allWebViews {
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            for list in enabled { controller.add(list) }
        }
        debugLog.native(.info, "ContentRules", "applied: block requests \(settings.blockAdRequests ? "on" : "off"), hide elements \(settings.hideAdElements ? "on" : "off") (\(enabled.count) list(s))")
    }

    // MARK: Content-rule gate

    private func whenRulesReady(_ action: @escaping @MainActor () -> Void) {
        if rulesReady {
            action()
        } else {
            pendingUntilRulesReady.append(action)
        }
    }

    private func markRulesReady() {
        guard !rulesReady else { return }
        rulesReady = true
        let pending = pendingUntilRulesReady
        pendingUntilRulesReady = []
        for action in pending { action() }
    }

    // MARK: Construction

    private static func makeWebView(role: WebRole, scripts: [InjectedScript], hub: BridgeEventHub, log: DebugLog) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()                  // one login for every view (D2)
        configuration.allowsInlineMediaPlayback = true               // every view (D14)
        configuration.allowsPictureInPictureMediaPlayback = true
        // Browse never starts media on its own; routed videos autoplay in the player (D14).
        configuration.mediaTypesRequiringUserActionForPlayback = role == .browse ? .all : []
        configuration.applicationNameForUserAgent = SafariUserAgent.applicationName  // D17

        let controller = WKUserContentController()
        for script in scripts {
            controller.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.injection == .start ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: script.mainFrameOnly,
                in: .page
            ))
        }
        controller.add(ScriptMessageProxy(role: role, hub: hub, log: log), contentWorld: .page,
                       name: ScriptConfig.messageHandlerName)
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = role == .browse
        return webView
    }

    private static func injectionPlans(log: DebugLog) -> [WebRole: [InjectedScript]] {
        do {
            let manifest = try ScriptManifest.parse(YTAssets.text("manifest.json"))
            for problem in manifest.problems() {
                logger.error("manifest: \(problem, privacy: .public)")
                log.native(.error, "manifest", problem)
            }
            var plans: [WebRole: [InjectedScript]] = [:]
            for role in WebRole.allCases {
                plans[role] = try manifest.injectionPlan(for: role, debug: isDebugBuild, build: buildString,
                                                         load: YTAssets.text)
            }
            return plans
        } catch {
            logger.fault("injected scripts unavailable: \(String(describing: error), privacy: .public)")
            log.native(.error, "manifest", "injected scripts unavailable: \(error)")
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

    static var buildString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static func describe(_ decision: RouteDecision) -> String {
        switch decision {
        case .allow: "allow"
        case .cancel: "cancel"
        case .openInPlayer(let request): "openInPlayer \(request.kind.rawValue) \(request.watchURL.absoluteString)"
        case .openInBrowse(let url): "openInBrowse \(url.absoluteString)"
        case .openExternally(let url): "openExternally \(url.absoluteString)"
        }
    }
}

/// The browse tab on screen, and the tabs whose webview has started loading (PLAN.md §6.2).
@MainActor
@Observable
final class BrowseTabState {
    var selected: BrowseTab = .home
    var loaded: Set<BrowseTab> = []
}

/// `applicationNameForUserAgent` (D17): WKWebView's UA plus Safari's tokens, so Google sign-in and
/// YouTube treat the view as Mobile Safari. Safari's `Version/` follows the OS major.minor.
enum SafariUserAgent {
    static let mobileToken = "Mobile/15E148"
    static let safariToken = "Safari/604.1"

    static var applicationName: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) \(mobileToken) \(safariToken)"
    }
}

/// Decodes `webkit.messageHandlers.ytadless` messages and publishes them. Holds the hub weakly:
/// WKUserContentController retains its handlers.
@MainActor
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private let role: WebRole
    private weak var hub: BridgeEventHub?
    private weak var log: DebugLog?

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "Bridge")

    init(role: WebRole, hub: BridgeEventHub, log: DebugLog) {
        self.role = role
        self.hub = hub
        self.log = log
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        do {
            let decoded = try BridgeMessage.decode(message.body)
            hub?.publish(.init(role: role, isMainFrame: decoded.isMainFrame, message: decoded.message))
        } catch {
            Self.logger.error("\(self.role.rawValue, privacy: .public): undecodable bridge message: \(String(describing: error), privacy: .public)")
            log?.native(.error, "bridge", "\(role.rawValue): undecodable message: \(error)")
        }
    }
}
