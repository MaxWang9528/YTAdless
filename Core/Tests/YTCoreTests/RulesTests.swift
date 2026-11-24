// RuleCompiler: ABP → WKContentRuleList conversion, WebKit-subset validation, shipped rules
// (PLAN.md §5.6, §6.1, D9, D10). Owner: Module A.

import Foundation
import Testing
@testable import YTAssets
@testable import YTCore

private func compileNetwork(_ text: String) -> CompiledRules {
    ContentRules.compile(network: text, cosmetic: "")
}

private func rules(_ compiled: CompiledRules) throws -> [[String: Any]] {
    try #require(JSONSerialization.jsonObject(with: Data(compiled.json.utf8)) as? [[String: Any]])
}

private func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
private func action(_ rule: [String: Any]) -> [String: Any] { rule["action"] as? [String: Any] ?? [:] }

/// Evaluates a url-filter the way WebKit does by default (case-insensitive, unanchored).
private func matches(_ filter: String, _ url: String) throws -> Bool {
    let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
    return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

@Suite("Rules › network")
struct NetworkRulesTests {
    @Test("||domain^ blocks the domain and its subdomains, not look-alikes")
    func domainAnchor() throws {
        let compiled = compileNetwork("||doubleclick.net^")
        #expect(compiled.diagnostics == [])
        let rule = try #require(try rules(compiled).first)
        #expect(action(rule)["type"] as? String == "block")
        let filter = try #require(trigger(rule)["url-filter"] as? String)
        #expect(try matches(filter, "https://doubleclick.net/x"))
        #expect(try matches(filter, "https://ad.g.doubleclick.net/pagead/id"))
        #expect(try matches(filter, "http://stats.doubleclick.net:443/"))
        #expect(try !matches(filter, "https://notdoubleclick.net/"))
        #expect(try !matches(filter, "https://doubleclick.network/"))
        #expect(try !matches(filter, "https://example.com/?u=https://doubleclick.net/"))
    }

    @Test("||host/path blocks a URL prefix on the host and its subdomains")
    func pathPrefix() throws {
        let rule = try #require(try rules(compileNetwork("||youtube.com/pagead/")).first)
        let filter = try #require(trigger(rule)["url-filter"] as? String)
        #expect(try matches(filter, "https://m.youtube.com/pagead/viewthroughconversion/1"))
        #expect(try matches(filter, "https://www.youtube.com/pagead/x"))
        #expect(try !matches(filter, "https://m.youtube.com/watch?v=pagead"))
        #expect(try !matches(filter, "https://m.youtube.com/api/pagead/"))
    }

    @Test("| anchors, * wildcards and regex escaping")
    func anchorsAndEscaping() throws {
        let compiled = compileNetwork("|https://a.com/x?y=1|\n/ads/*.js\n")
        #expect(compiled.diagnostics == [])
        let filters = try rules(compiled).map { trigger($0)["url-filter"] as? String }
        #expect(filters == ["^https://a\\.com/x\\?y=1$", "/ads/.*\\.js"])
        #expect(try matches(filters[1]!, "https://cdn.example/ads/banner.js"))
    }

    @Test("options map to resource-type, load-type and one domain condition")
    func options() throws {
        let compiled = compileNetwork("""
        ||ads.example^$script,image,stylesheet,xhr,media,font,ping,subdocument,third-party
        ||b.example^$~third-party,domain=m.youtube.com|youtube.com
        ||c.example^$domain=~m.youtube.com
        """)
        #expect(compiled.diagnostics == [])
        let list = try rules(compiled)
        #expect(trigger(list[0])["resource-type"] as? [String] == ["script", "image", "style-sheet", "fetch", "raw", "media", "font", "ping", "child-document"])
        #expect(trigger(list[0])["load-type"] as? [String] == ["third-party"])
        #expect(trigger(list[1])["load-type"] as? [String] == ["first-party"])
        #expect(trigger(list[1])["if-domain"] as? [String] == ["*m.youtube.com", "*youtube.com"])
        #expect(trigger(list[2])["unless-domain"] as? [String] == ["*m.youtube.com"])
        #expect(trigger(list[2])["if-domain"] == nil)
    }

    @Test("@@ exceptions become ignore-previous-rules and come after every block and cosmetic rule")
    func exceptionsLast() throws {
        let compiled = ContentRules.compile(network: "@@||a.example/ok^\n||a.example^\n", cosmetic: "##.ad")
        #expect(compiled.diagnostics == [])
        let types = try rules(compiled).map { action($0)["type"] as? String }
        #expect(types == ["block", "css-display-none", "ignore-previous-rules"])
    }

    @Test("valid /regex/ passes through unchanged")
    func regexPassThrough() throws {
        // `|` is unsupported by WebKit, so this one must fail…
        let compiled = compileNetwork("/^https?://[a-z]+\\.example/(ads|track)+/")
        #expect(compiled.diagnostics.map(\.message).contains { $0.contains("disjunction") })
        // …and this one passes through without its delimiters, options split off after `/$`.
        let ok = compileNetwork("/^https?://([a-z0-9-]+\\.)?example\\.com/ad[sx]?\\//$script\n/track$/")
        #expect(ok.diagnostics == [])
        let list = try rules(ok)
        #expect(list.map { trigger($0)["url-filter"] as? String } == ["^https?://([a-z0-9-]+\\.)?example\\.com/ad[sx]?\\/", "track$"])
        #expect(trigger(list[0])["resource-type"] as? [String] == ["script"])
    }

    @Test("WebKit regex subset: rejected constructs", arguments: [
        "a|b", "a{2}", "\\d+", "\\w", "a\\b", "(?:a)", "(?=a)", "a^", "$a", "(a", "a)", "[abc", "*a", "a**", "é", "()",
    ])
    func regexRejected(_ regex: String) {
        #expect(URLFilter.webKitProblem(regex) != nil, "\(regex) should be rejected")
    }

    @Test("WebKit regex subset: accepted constructs", arguments: [
        "^https?://", "a.*b", "[^a-z0-9_.%-]", "(ab)+c?", "\\.js$", "[]a]", "\\/\\?\\(",
    ])
    func regexAccepted(_ regex: String) {
        #expect(URLFilter.webKitProblem(regex) == nil, "\(regex): \(URLFilter.webKitProblem(regex) ?? "")")
    }

    @Test("unsupported syntax is a diagnostic with file and line", arguments: [
        "||a.com^$replace=/x/y/",
        "||a.com^$redirect=noop.js",
        "||a.com^$removeparam=utm",
        "||a.com^$important",
        "||a.com^$~script",
        "||a.com^$domain=a.com|~b.com",
        "||a.com^$domain=A.com",
        "||a.com^$domain=*.a.com",
        "||a.com^$frobnicate",
        "m.youtube.com##.ad",
        "m.youtube.com##+js(set, x, 1)",
        "/a{3}/",
        "[Adblock Plus 2.0]",
        "$third-party",
    ])
    func networkDiagnostics(_ line: String) {
        let compiled = ContentRules.compile(network: "! header\n\n" + line + "\n", cosmetic: "##.x")
        #expect(compiled.diagnostics.count == 1, "\(line)")
        #expect(compiled.diagnostics.first?.file == "rules/network.txt")
        #expect(compiled.diagnostics.first?.line == 3)
    }
}

@Suite("Rules › cosmetic")
struct CosmeticRulesTests {
    @Test("domain##selector → css-display-none with if-domain; ##selector applies everywhere")
    func conversion() throws {
        let compiled = ContentRules.compile(network: "", cosmetic: "m.youtube.com##ytm-promoted-video-renderer\n##.banner\n~a.com,~b.com##x-y")
        #expect(compiled.diagnostics == [])
        let list = try rules(compiled)
        #expect(list.count == 3)
        #expect(action(list[0])["type"] as? String == "css-display-none")
        #expect(action(list[0])["selector"] as? String == "ytm-promoted-video-renderer")
        #expect(trigger(list[0])["url-filter"] as? String == ".*")
        #expect(trigger(list[0])["if-domain"] as? [String] == ["*m.youtube.com"])
        #expect(trigger(list[1])["if-domain"] == nil)
        #expect(trigger(list[2])["unless-domain"] as? [String] == ["*a.com", "*b.com"])
    }

    @Test("valid selectors", arguments: [
        "ytm-companion-slot[data-content-type] > ytm-companion-ad-renderer",
        "ytm-rich-item-renderer:has(> ad-slot-renderer)",
        "lazy-list > ad-slot-renderer",
        "div.a#b[c='d'][e^=\"f\" i]:not(.g, .h) ~ p + span",
        "a:nth-child(2n + 1), b:first-child",
        "*[data-x]",
        "ytm-item-section-renderer:is(.a, .b) :where(c)",
        "#id-1.cls_2",
        "div:has(+ span, ~ p)",
    ])
    func validSelectors(_ selector: String) {
        #expect(SelectorValidator.problem(selector) == nil, "\(selector): \(SelectorValidator.problem(selector) ?? "")")
    }

    @Test("invalid or procedural selectors are diagnostics", arguments: [
        "div:has-text(Sponsored)",
        "div:upward(2)",
        "div:xpath(//a)",
        "div:-abp-has(.ad)",
        "div:matches-css(display: block)",
        "div::before",
        "div[",
        "div[x=]",
        "div >",
        "> div",
        ", div",
        "div:nth-child(foo)",
        "div!",
        "div:hover-ish",
        "dïv",
        ".",
        "#",
    ])
    func invalidSelectors(_ selector: String) {
        #expect(SelectorValidator.problem(selector) != nil, "\(selector) should be rejected")
    }

    @Test("extended cosmetic syntax is a diagnostic", arguments: [
        "m.youtube.com#@#.ad",
        "m.youtube.com#?#div:has-text(Ad)",
        "m.youtube.com##+js(json-prune, adPlacements)",
        "m.youtube.com#$#body { color: red }",
        "m.youtube.com##^script",
        "m.youtube.com##div:has-text(Ad)",
        "M.youtube.com##.x",
        "a.com,~b.com##.x",
        "just text",
        "m.youtube.com##",
    ])
    func cosmeticDiagnostics(_ line: String) {
        let compiled = ContentRules.compile(network: "||a.com^", cosmetic: line)
        #expect(compiled.diagnostics.count == 1, "\(line)")
        #expect(compiled.diagnostics.first?.file == "rules/cosmetic.txt")
        #expect(compiled.diagnostics.first?.line == 1)
    }

    @Test(":has() strategy: stylesheet moves :has() selectors out of the rule list")
    func hasStrategy() throws {
        let cosmetic = "m.youtube.com##a:has(> b)\nm.youtube.com##c"
        let inline = ContentRules.compile(network: "", cosmetic: cosmetic, hasStrategy: .contentRule)
        let moved = ContentRules.compile(network: "", cosmetic: cosmetic, hasStrategy: .stylesheet)
        #expect(try rules(inline).count == 2)
        #expect(try rules(moved).map { action($0)["selector"] as? String } == ["c"])
        #expect(ContentRules.stylesheet(cosmetic: cosmetic, hasStrategy: .stylesheet) == "a:has(> b) { display: none !important; }\n")
        #expect(ContentRules.stylesheet(cosmetic: cosmetic, hasStrategy: .contentRule) == "")
        #expect(ContentRules.hasSelectorStrategy == .contentRule, "flip only after spike S-B2 (PLAN.md §6.1)")
    }
}

@Suite("Rules › output")
struct RulesOutputTests {
    @Test("an empty rule list is a diagnostic (WebKit rejects it)")
    func emptyList() {
        #expect(ContentRules.compile(network: "! only comments", cosmetic: "").diagnostics.count == 1)
    }

    @Test("output is deterministic and the identifier tracks the JSON")
    func deterministic() {
        let a = ContentRules.compile(network: "||a.com^\n||b.com^", cosmetic: "##.x")
        let b = ContentRules.compile(network: "||a.com^\n||b.com^", cosmetic: "##.x")
        let c = ContentRules.compile(network: "||a.com^", cosmetic: "##.x")
        #expect(a.json == b.json)
        #expect(a.identifier == b.identifier)
        #expect(a.identifier != c.identifier)
        #expect(a.json == #"[{"trigger":{"url-filter":"^[a-z][a-z0-9.+-]*://([^/:]*\\.)?a\\.com[^a-z0-9_.%-]"},"action":{"type":"block"}},{"trigger":{"url-filter":"^[a-z][a-z0-9.+-]*://([^/:]*\\.)?b\\.com[^a-z0-9_.%-]"},"action":{"type":"block"}},{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".x"}}]"#)
    }
}

@Suite("Rules › shipped")
struct ShippedRulesTests {
    static let compiled = ContentRules.compile(network: (try? YTAssets.text("rules/network.txt")) ?? "",
                                               cosmetic: (try? YTAssets.text("rules/cosmetic.txt")) ?? "")

    @Test("compile with zero diagnostics and only WebKit-valid output")
    func clean() throws {
        let compiled = Self.compiled
        #expect(compiled.diagnostics == [], "\(compiled.diagnostics.map(\.description))")
        let list = try rules(compiled)
        #expect(list.count > 0)
        let knownTypes: Set<String> = ["document", "top-document", "child-document", "image", "style-sheet", "script", "font",
                                       "raw", "websocket", "fetch", "other", "svg-document", "media", "popup", "ping", "csp-report"]
        for rule in list {
            let t = trigger(rule)
            let filter = try #require(t["url-filter"] as? String)
            #expect(URLFilter.webKitProblem(filter) == nil, "\(filter)")
            _ = try NSRegularExpression(pattern: filter)
            for type in t["resource-type"] as? [String] ?? [] { #expect(knownTypes.contains(type), "\(type)") }
            let conditions = ["if-domain", "unless-domain", "if-top-url", "unless-top-url", "if-frame-url", "unless-frame-url"].filter { t[$0] != nil }
            #expect(conditions.count <= 1)
            for domain in (t["if-domain"] as? [String] ?? []) + (t["unless-domain"] as? [String] ?? []) {
                #expect(domain == domain.lowercased() && domain.allSatisfy(\.isASCII))
            }
            if action(rule)["type"] as? String == "css-display-none" {
                #expect(SelectorValidator.problem(try #require(action(rule)["selector"] as? String)) == nil)
            }
        }
    }

    /// CLAUDE.md "Don'ts": these carry playback or are used to detect blockers.
    @Test("never block playback, stats and log_event URLs", arguments: [
        "https://rr3---sn-a5mekn7s.googlevideo.com/videoplayback?expire=1&itag=18&mime=video%2Fmp4",
        "https://rr1---sn-ab5l6nr6.googlevideo.com/initplayback?source=youtube",
        "https://m.youtube.com/api/stats/playback?ns=yt&el=detailpage&docid=x",
        "https://m.youtube.com/api/stats/watchtime?ns=yt&docid=x",
        "https://m.youtube.com/api/stats/qoe?fmt=243&docid=x",
        "https://m.youtube.com/youtubei/v1/log_event?alt=json",
        "https://m.youtube.com/youtubei/v1/player?prettyPrint=false",
        "https://m.youtube.com/youtubei/v1/get_watch?prettyPrint=false",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        "https://m.youtube.com/s/player/abc/player-plasma-ias-phone-en_US.vflset/base.js",
        "https://accounts.google.com/ServiceLogin?continue=https://m.youtube.com/",
    ])
    func neverBlocked(_ url: String) throws {
        for rule in try rules(Self.compiled) where action(rule)["type"] as? String == "block" {
            let filter = try #require(trigger(rule)["url-filter"] as? String)
            #expect(try !matches(filter, url), "\(filter) blocks \(url)")
        }
    }

    @Test("the PLAN.md §6.1 ad URLs are blocked", arguments: [
        "https://googleads.g.doubleclick.net/pagead/id",
        "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
        "https://www.googleadservices.com/pagead/conversion/1/",
        "https://m.youtube.com/pagead/viewthroughconversion/1/?backend=innertube",
        "https://m.youtube.com/api/stats/ads?ver=2&ns=1",
        "https://m.youtube.com/ptracking?ptk=youtube_single&video_id=x",
        "https://m.youtube.com/youtubei/v1/player/ad_break?prettyPrint=false",
        "https://m.youtube.com/get_midroll_info?ei=x",
    ])
    func adsBlocked(_ url: String) throws {
        let blocked = try rules(Self.compiled).contains { rule in
            action(rule)["type"] as? String == "block" && ((try? matches(trigger(rule)["url-filter"] as? String ?? "", url)) ?? false)
        }
        #expect(blocked, "\(url)")
    }
}
