// TestVectors/routing.json is well-formed (PLAN.md §5.8, §6.2). Owner: P0.
//
// This checks the vectors themselves, not the Router: RoutingTests (Module B) runs Router
// against them, and router.js's tests run the JS classifier against the same file.

import Foundation
import Testing
@testable import YTCore

@Suite("TestVectors › routing.json")
struct RoutingVectorSchemaTests {
    static func file() throws -> [String: Any] { try Repo.jsonObject("TestVectors/routing.json") }
    static func decideCases() throws -> [[String: Any]] {
        try #require(try file()["decide"] as? [[String: Any]])
    }

    static let decisions: Set<String> = ["allow", "openInPlayer", "openInBrowse", "openExternally", "cancel"]

    /// The canonical watchURL form (PLAN.md §6.2).
    static func canonicalWatchURL(id: String, kind: String, start: Int?, list: String?, index: Int?) -> String {
        if kind == "short" { return "https://m.youtube.com/shorts/\(id)" }
        var url = "https://m.youtube.com/watch?v=\(id)"
        if let start { url += "&t=\(start)s" }
        if let list { url += "&list=\(list)" }
        if let index { url += "&index=\(index)" }
        return url
    }

    @Test("version 1, at least 25 decide cases with unique names, and normalize cases")
    func shape() throws {
        let file = try Self.file()
        #expect(file["version"] as? Int == 1)
        let cases = try Self.decideCases()
        #expect(cases.count >= 25)
        let names = cases.compactMap { $0["name"] as? String }
        #expect(names.count == cases.count)
        #expect(Set(names).count == names.count, "names are unique")
        let normalize = try #require(file["normalize"] as? [[String: Any]])
        #expect(!normalize.isEmpty)
        for entry in normalize {
            #expect(URL(string: entry["url"] as? String ?? "") != nil)
            #expect(URL(string: entry["expect"] as? String ?? "") != nil)
        }
    }

    @Test("every decide case is well-formed")
    func cases() throws {
        for c in try Self.decideCases() {
            let name = c["name"] as? String ?? "?"
            #expect(WebRole(rawValue: c["role"] as? String ?? "") != nil, "\(name): role")
            #expect(NavigationTrigger(rawValue: c["trigger"] as? String ?? "") != nil, "\(name): trigger")
            #expect(URL(string: c["url"] as? String ?? "") != nil, "\(name): url")
            let expect = try #require(c["expect"] as? [String: Any], "\(name): expect")
            let decision = expect["decision"] as? String ?? ""
            #expect(Self.decisions.contains(decision), "\(name): decision \(decision)")
            switch decision {
            case "openInPlayer":
                let request = try #require(expect["request"] as? [String: Any], "\(name): request")
                #expect(Set(request.keys) == ["id", "kind", "startSeconds", "playlistID", "playlistIndex", "watchURL"], "\(name): request keys")
                let id = try #require(request["id"] as? String)
                #expect(id.wholeMatch(of: /[A-Za-z0-9_-]{11}/) != nil, "\(name): id")
                let kind = try #require(request["kind"] as? String)
                #expect(VideoRequest.Kind(rawValue: kind) != nil, "\(name): kind")
                let start = request["startSeconds"] as? Int
                let list = request["playlistID"] as? String
                let index = request["playlistIndex"] as? Int
                #expect(request["watchURL"] as? String
                        == Self.canonicalWatchURL(id: id, kind: kind, start: start, list: list, index: index),
                        "\(name): canonical watchURL")
            case "openInBrowse", "openExternally":
                #expect(URL(string: expect["url"] as? String ?? "") != nil, "\(name): url")
            default:
                #expect(expect.count == 1, "\(name): no extra fields")
            }
        }
    }

    @Test("every row of the §6.2 decision table has cases")
    func coversTable() throws {
        let pairs = Set(try Self.decideCases().map { c in
            "\(c["role"] as? String ?? "")/\((c["expect"] as? [String: Any])?["decision"] as? String ?? "")"
        })
        for pair in ["browse/openInPlayer", "browse/allow", "player/allow", "player/openInBrowse",
                     "browse/openExternally", "player/openExternally"] {
            #expect(pairs.contains(pair), "\(pair)")
        }
    }
}
