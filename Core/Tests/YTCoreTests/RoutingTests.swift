// Router against TestVectors/routing.json, plus unit cases (PLAN.md §6.2). Owner: Module B.

import Foundation
import Testing
@testable import YTCore

@Suite("Routing › vectors")
struct RoutingVectorTests {
    static func file() throws -> [String: Any] { try Repo.jsonObject("TestVectors/routing.json") }

    struct BadVector: Error { let detail: String }

    static func urlField(_ object: [String: Any], _ key: String) throws -> URL {
        guard let text = object[key] as? String, let url = URL(string: text) else { throw BadVector(detail: "\(key) is not a URL") }
        return url
    }

    /// The vector's `expect` as a RouteDecision.
    static func expected(_ expect: [String: Any]) throws -> RouteDecision {
        switch expect["decision"] as? String {
        case "allow": return .allow
        case "cancel": return .cancel
        case "openInBrowse": return .openInBrowse(try urlField(expect, "url"))
        case "openExternally": return .openExternally(try urlField(expect, "url"))
        case "openInPlayer":
            let r = try #require(expect["request"] as? [String: Any])
            return .openInPlayer(VideoRequest(
                id: try #require(r["id"] as? String),
                kind: try #require(VideoRequest.Kind(rawValue: r["kind"] as? String ?? "")),
                startSeconds: r["startSeconds"] as? Int,
                playlistID: r["playlistID"] as? String,
                playlistIndex: r["playlistIndex"] as? Int,
                watchURL: try urlField(r, "watchURL")
            ))
        default:
            Issue.record("unknown decision \(String(describing: expect["decision"]))")
            return .cancel
        }
    }

    @Test("every normalize case")
    func normalize() throws {
        let cases = try #require(try Self.file()["normalize"] as? [[String: Any]])
        for c in cases {
            let input = try Self.urlField(c, "url")
            let expect = try #require(c["expect"] as? String)
            #expect(Router.normalize(input).absoluteString == expect, "normalize(\(input.absoluteString))")
        }
    }

    @Test("every decide case")
    func decide() throws {
        let cases = try #require(try Self.file()["decide"] as? [[String: Any]])
        #expect(cases.count >= 25)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let url = try Self.urlField(c, "url")
            let role = try #require(WebRole(rawValue: c["role"] as? String ?? ""), "\(name): role")
            let trigger = try #require(NavigationTrigger(rawValue: c["trigger"] as? String ?? ""), "\(name): trigger")
            let expectObject = try #require(c["expect"] as? [String: Any], "\(name): expect")
            let expected = try Self.expected(expectObject)
            let actual = Router.decide(url, role: role, trigger: trigger)
            #expect(actual == expected, "routing.json › \(name)")
            // watchURL equality above is URL equality; pin the exact text too.
            if case .openInPlayer(let a) = actual, case .openInPlayer(let e) = expected {
                #expect(a.watchURL.absoluteString == e.watchURL.absoluteString, "\(name): watchURL text")
            }
        }
    }

    @Test("the decision never depends on the trigger")
    func triggerIndependent() throws {
        let cases = try #require(try Self.file()["decide"] as? [[String: Any]])
        for c in cases {
            let url = try #require(URL(string: c["url"] as? String ?? ""))
            let role = try #require(WebRole(rawValue: c["role"] as? String ?? ""))
            let decisions = NavigationTrigger.allCases.map { Router.decide(url, role: role, trigger: $0) }
            #expect(Set(decisions.map { "\($0)" }).count == 1, "\(c["name"] ?? "?")")
        }
    }
}

@Suite("Routing › classify")
struct RoutingClassifyTests {
    func url(_ s: String) -> URL { URL(string: s)! }

    @Test("in-place schemes are ignored and allowed in both roles")
    func inPlace() {
        for s in ["about:blank", "javascript:void(0)", "blob:https://m.youtube.com/1234", "data:text/plain,hi"] {
            #expect(Router.classify(url(s)) == .ignore, "\(s)")
            for role in WebRole.allCases {
                #expect(Router.decide(url(s), role: role, trigger: .click) == .allow, "\(s) in \(role)")
            }
        }
    }

    @Test("other schemes open externally")
    func otherSchemes() {
        for s in ["mailto:a@example.com", "tel:+15551234", "itms-apps://apps.apple.com/app/id1"] {
            #expect(Router.decide(url(s), role: .browse, trigger: .click) == .openExternally(url(s)), "\(s)")
        }
    }

    @Test("a /watch without a valid 11-character v is a YouTube page")
    func invalidWatch() {
        for s in ["https://m.youtube.com/watch", "https://m.youtube.com/watch?v=short", "https://m.youtube.com/watch?v=dQw4w9WgXcQx",
                  "https://m.youtube.com/watch?v=dQw4w9WgX%21Q", "https://m.youtube.com/shorts/", "https://m.youtube.com/shorts/abc"] {
            #expect(Router.classify(url(s)) == .youtubePage(url(s)), "\(s)")
            #expect(Router.decide(url(s), role: .browse, trigger: .click) == .allow, "\(s)")
        }
    }

    @Test("first v wins; shorts and live accept a trailing slash")
    func pathForms() {
        if case .video(let r) = Router.classify(url("https://m.youtube.com/watch?v=dQw4w9WgXcQ&v=jNQXAC9IVRw")) {
            #expect(r.id == "dQw4w9WgXcQ")
        } else { Issue.record("expected video") }
        if case .video(let r) = Router.classify(url("https://m.youtube.com/shorts/aqz-KE-bpKQ/")) {
            #expect(r.kind == .short)
        } else { Issue.record("expected short") }
        #expect(Router.classify(url("https://m.youtube.com/shorts/aqz-KE-bpKQ/extra")) == .youtubePage(url("https://m.youtube.com/shorts/aqz-KE-bpKQ/extra")))
        if case .video(let r) = Router.classify(url("https://youtube.com/live/jfKfPfyJRdk?t=10")) {
            #expect(r.kind == .live)
            #expect(r.watchURL.absoluteString == "https://m.youtube.com/watch?v=jfKfPfyJRdk&t=10s")
        } else { Issue.record("expected live") }
    }

    @Test("start times")
    func startSeconds() {
        let cases: [(String, Int?)] = [
            ("90", 90), ("90s", 90), ("1m30s", 90), ("1h2m3s", 3723), ("2h", 7200), ("5m", 300), ("0", 0),
            ("", nil), ("s", nil), ("1m30", nil), ("30s1m", nil), ("1x", nil), ("-5", nil), ("12345678", nil), ("1h1h", nil),
        ]
        for (text, expected) in cases {
            #expect(Router.parseStartSeconds(text) == expected, "t=\(text)")
        }
    }

    @Test("an invalid playlist id or index is dropped")
    func invalidParams() {
        guard case .video(let r) = Router.classify(url("https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=a%20b&index=x&t=zz")) else {
            Issue.record("expected video"); return
        }
        #expect(r.playlistID == nil && r.playlistIndex == nil && r.startSeconds == nil)
        #expect(r.watchURL.absoluteString == "https://m.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    @Test("a /redirect without a web q opens the redirect itself")
    func redirectFallback() {
        let bad = url("https://m.youtube.com/redirect?q=javascript%3Aalert(1)")
        #expect(Router.decide(bad, role: .browse, trigger: .click) == .openExternally(bad))
        let none = url("https://m.youtube.com/redirect")
        #expect(Router.decide(none, role: .player, trigger: .click) == .openExternally(none))
    }

    @Test("hosts are case-insensitive; other YouTube subdomains are external")
    func hosts() {
        #expect(Router.normalize(url("HTTPS://WWW.YouTube.com/feed/library")).absoluteString == "https://m.youtube.com/feed/library")
        #expect(Router.normalize(url("https://youtube.com")).absoluteString == "https://m.youtube.com/")
        #expect(Router.normalize(url("https://youtu.be/")).absoluteString == "https://m.youtube.com/")
        #expect(Router.normalize(url("https://m.youtube.com/watch?v=dQw4w9WgXcQ#t=30")).absoluteString == "https://m.youtube.com/watch?v=dQw4w9WgXcQ#t=30")
        let studio = url("https://studio.youtube.com/")
        #expect(Router.decide(studio, role: .browse, trigger: .click) == .openExternally(studio))
        #expect(Router.decide(url("https://ACCOUNTS.google.com/x"), role: .player, trigger: .location) == .allow)
    }
}
