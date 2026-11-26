// BrowseTab — owner: Module B (PLAN.md §6.2 "Browse tabs").
//
// One long-lived browse webview per m.youtube.com bottom-nav tab (D2, user decision 2026-11-25):
// switching tabs shows another webview instead of letting mweb re-render one page, so each tab
// keeps its DOM, its loaded feed pages and its scroll position. router.js mirrors `tab(forPath:)`;
// both are checked against TestVectors/browseTabs.json.

import Foundation

public enum BrowseTab: String, Codable, CaseIterable, Sendable {
    case home, subscriptions, you

    /// The paths that are this tab's root page. The first is where native loads the tab.
    /// `/feed/library` is the old name of You and redirects there (mweb, 2026-11).
    public var rootPaths: [String] {
        switch self {
        case .home: ["/"]
        case .subscriptions: ["/feed/subscriptions"]
        case .you: ["/feed/you", "/feed/library"]
        }
    }

    public var url: URL {
        URL(string: "https://m.youtube.com" + rootPaths[0])!
    }

    /// The tab whose root page `path` is, ignoring one trailing slash. Nil for any other page.
    public static func tab(forPath path: String) -> BrowseTab? {
        var p = path.isEmpty ? "/" : path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return allCases.first { $0.rootPaths.contains(p) }
    }

    /// The tab whose root page `url` is, for YouTube web hosts only.
    public static func tab(for url: URL) -> BrowseTab? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), webHosts.contains(host) else { return nil }
        return tab(forPath: url.path)
    }

    /// Hosts that serve the browse tabs (Router.youtubeHosts minus youtu.be and music).
    static let webHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com"]
}

/// What the browse side does with a `selectTab` request or an `openInBrowse` URL.
public enum BrowseTabDecision: Equatable, Sendable {
    /// Show `tab`'s webview, loading its root page first if it has never loaded one.
    case show(BrowseTab, loadFirst: Bool)
    /// Load the URL in the visible tab's webview.
    case loadInCurrent(URL)

    /// `loaded`: the tabs whose webview has started loading a page.
    public static func forURL(_ url: URL, loaded: Set<BrowseTab>) -> BrowseTabDecision {
        if let tab = BrowseTab.tab(for: url) { return select(tab, loaded: loaded) }
        return .loadInCurrent(url)
    }

    public static func select(_ tab: BrowseTab, loaded: Set<BrowseTab>) -> BrowseTabDecision {
        .show(tab, loadFirst: !loaded.contains(tab))
    }
}
