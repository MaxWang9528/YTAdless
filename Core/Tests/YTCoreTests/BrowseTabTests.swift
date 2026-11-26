// BrowseTab (PLAN.md §6.2 "Browse tabs"): one browse webview per bottom-nav tab. Owner: Module B.

import Foundation
import Testing
@testable import YTCore

@Suite("Routing › browse tabs")
struct BrowseTabTests {
    @Test("TestVectors/browseTabs.json: tab(forPath:)")
    func vectors() throws {
        let file = try Repo.jsonObject("TestVectors/browseTabs.json")
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.count > 5)
        for c in cases {
            let path = try #require(c["path"] as? String)
            let expected = (c["tab"] as? String).flatMap(BrowseTab.init(rawValue:))
            #expect(BrowseTab.tab(forPath: path) == expected, "\(path)")
        }
    }

    @Test("every tab's first root path maps back to it, and its URL is on m.youtube.com")
    func roots() {
        for tab in BrowseTab.allCases {
            #expect(BrowseTab.tab(forPath: tab.rootPaths[0]) == tab)
            #expect(tab.url.host == "m.youtube.com")
            #expect(BrowseTab.tab(for: tab.url) == tab)
        }
    }

    @Test("tab(for:) only accepts YouTube web hosts")
    func hosts() {
        #expect(BrowseTab.tab(for: URL(string: "https://www.youtube.com/feed/subscriptions")!) == .subscriptions)
        #expect(BrowseTab.tab(for: URL(string: "https://youtube.com/")!) == .home)
        #expect(BrowseTab.tab(for: URL(string: "https://m.youtube.com/feed/library?app=m")!) == .you)
        #expect(BrowseTab.tab(for: URL(string: "https://example.com/")!) == nil)
        #expect(BrowseTab.tab(for: URL(string: "https://music.youtube.com/")!) == nil)
        #expect(BrowseTab.tab(for: URL(string: "https://youtu.be/")!) == nil)
        #expect(BrowseTab.tab(for: URL(string: "https://m.youtube.com/results?search_query=x")!) == nil)
    }

    @Test("decisions: a tab root shows that tab (loading it the first time); other pages load in the current tab")
    func decisions() {
        let subs = URL(string: "https://m.youtube.com/feed/subscriptions")!
        let channel = URL(string: "https://m.youtube.com/@SmarterEveryDay")!
        #expect(BrowseTabDecision.forURL(subs, loaded: [.home]) == .show(.subscriptions, loadFirst: true))
        #expect(BrowseTabDecision.forURL(subs, loaded: [.home, .subscriptions]) == .show(.subscriptions, loadFirst: false))
        #expect(BrowseTabDecision.forURL(channel, loaded: [.home]) == .loadInCurrent(channel))
        #expect(BrowseTabDecision.select(.you, loaded: []) == .show(.you, loadFirst: true))
        #expect(BrowseTabDecision.select(.home, loaded: [.home]) == .show(.home, loadFirst: false))
    }
}
