// Script manifest, injection plan and config prelude (PLAN.md §5.1, §5.2). Owner: P0.

import Foundation
import Testing
@testable import YTAssets
@testable import YTCore

@Suite("Scripts › manifest")
struct ScriptManifestTests {
    static func shipped() throws -> ScriptManifest {
        try ScriptManifest.parse(YTAssets.text("manifest.json"))
    }

    @Test("the shipped manifest decodes and has no problems")
    func shippedIsValid() throws {
        let manifest = try Self.shipped()
        #expect(manifest.version == 1)
        #expect(manifest.problems() == [])
    }

    @Test("order, roles, injection, frames and owners match PLAN.md §5.1")
    func matchesPlanTable() throws {
        let both: [WebRole] = [.browse, .player]
        let expected: [ScriptManifest.Entry] = [
            .init(file: "bridge.js", roles: both, injection: .start, mainFrameOnly: false, owner: "P0"),
            .init(file: "debug.js", roles: both, injection: .start, mainFrameOnly: false, owner: "B"),
            .init(file: "hooks.js", roles: both, injection: .start, mainFrameOnly: false, owner: "A"),
            .init(file: "player-ads.js", roles: both, injection: .start, mainFrameOnly: false, owner: "A"),
            .init(file: "feed-ads.js", roles: both, injection: .start, mainFrameOnly: false, owner: "A"),
            .init(file: "router.js", roles: both, injection: .start, mainFrameOnly: true, owner: "B"),
            .init(file: "player-bridge.js", roles: [.player], injection: .start, mainFrameOnly: true, owner: "D"),
            .init(file: "background.js", roles: [.player], injection: .start, mainFrameOnly: true, owner: "D"),
            .init(file: "media-session.js", roles: [.player], injection: .start, mainFrameOnly: true, owner: "D"),
            .init(file: "sponsorblock.js", roles: [.player], injection: .start, mainFrameOnly: true, owner: "D"),
            .init(file: "layout.js", roles: [.player], injection: .end, mainFrameOnly: true, owner: "C"),
        ]
        #expect(try Self.shipped().scripts == expected)
    }

    @Test("every listed file exists in the bundle, and every bundled script is listed")
    func filesExist() throws {
        let manifest = try Self.shipped()
        for entry in manifest.scripts {
            let text = try YTAssets.text("scripts/\(entry.file)")
            #expect(!text.isEmpty, "\(entry.file) is empty")
        }
        let bundled = try FileManager.default.contentsOfDirectory(atPath: YTAssets.url("scripts").path)
            .filter { $0.hasSuffix(".js") }
        #expect(Set(bundled) == Set(manifest.scripts.map(\.file)))
    }

    @Test("entries(for:) filters by role and keeps manifest order")
    func entriesForRole() throws {
        let manifest = try Self.shipped()
        #expect(manifest.entries(for: .browse).map(\.file)
                == ["bridge.js", "debug.js", "hooks.js", "player-ads.js", "feed-ads.js", "router.js"])
        #expect(manifest.entries(for: .player).map(\.file) == manifest.scripts.map(\.file))
    }

    @Test("problems() catches structural mistakes")
    func problems() {
        let bad = ScriptManifest(version: 2, scripts: [
            .init(file: "router.js", roles: [], injection: .start, mainFrameOnly: true, owner: "X"),
            .init(file: "router.js", roles: [.browse, .browse], injection: .start, mainFrameOnly: true, owner: "B"),
            .init(file: "../evil.js", roles: [.player], injection: .end, mainFrameOnly: true, owner: "B"),
        ])
        let problems = bad.problems()
        #expect(problems.contains("unsupported manifest version 2"))
        #expect(problems.contains("bridge.js must be the first script"))
        #expect(problems.contains("router.js is listed twice"))
        #expect(problems.contains("router.js has unknown owner X"))
        #expect(problems.contains("router.js has empty or duplicate roles"))
        #expect(problems.contains("../evil.js is not a plain .js file name"))
    }
}

@Suite("Scripts › injection plan")
struct InjectionPlanTests {
    @Test("prelude first, then the role's files, each tagged with a sourceURL", arguments: WebRole.allCases)
    func plan(_ role: WebRole) throws {
        let manifest = try ScriptManifestTests.shipped()
        var loaded: [String] = []
        let plan = try manifest.injectionPlan(for: role, debug: true, build: "b") { path in
            loaded.append(path)
            return try YTAssets.text(path)
        }
        let entries = manifest.entries(for: role)
        #expect(plan.map(\.name) == [InjectedScript.preludeName] + entries.map(\.file))
        #expect(loaded == entries.map { "scripts/\($0.file)" })

        let prelude = try #require(plan.first)
        #expect(prelude.injection == .start)
        #expect(prelude.mainFrameOnly == false)
        #expect(prelude.source == ScriptConfig.prelude(role: role, debug: true, build: "b")
                + "//# sourceURL=ytadless/prelude.js\n")

        for (script, entry) in zip(plan.dropFirst(), entries) {
            #expect(script.injection == entry.injection)
            #expect(script.mainFrameOnly == entry.mainFrameOnly)
            #expect(script.source.hasPrefix(try YTAssets.text("scripts/\(entry.file)")))
            #expect(script.source.hasSuffix("\n//# sourceURL=ytadless/\(entry.file)\n"))
        }
    }

    @Test("a source without a trailing newline gets one before the sourceURL")
    func sourceURLNewline() throws {
        let manifest = ScriptManifest(scripts: [
            .init(file: "bridge.js", roles: [.browse], injection: .start, mainFrameOnly: false, owner: "P0"),
        ])
        let plan = manifest.injectionPlan(for: .browse, debug: false, build: "") { _ in "x()" }
        #expect(plan.last?.source == "x()\n//# sourceURL=ytadless/bridge.js\n")
    }
}

@Suite("Scripts › config prelude")
struct ScriptConfigTests {
    @Test("matches TestVectors/prelude.json byte for byte")
    func preludeVectors() throws {
        let file = try Repo.jsonObject("TestVectors/prelude.json")
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.count >= 3)
        for testCase in cases {
            let role = try #require(WebRole(rawValue: testCase["role"] as? String ?? ""))
            let debug = try #require(testCase["debug"] as? Bool)
            let build = try #require(testCase["build"] as? String)
            let source = try #require(testCase["source"] as? String)
            #expect(ScriptConfig.prelude(role: role, debug: debug, build: build) == source, "\(role) \(debug) \(build)")
        }
    }

    @Test("configJSON is valid JSON with the given values")
    func configJSON() throws {
        let json = ScriptConfig.configJSON(role: .player, debug: true, build: "1.0 \"beta\"")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["role"] as? String == "player")
        #expect(object["debug"] as? Bool == true)
        #expect(object["build"] as? String == "1.0 \"beta\"")
    }

    @Test("jsonString mirrors JSON.stringify", arguments: [
        ("plain", #""plain""#),
        ("q\"b\\s", #""q\"b\\s""#),
        ("\n\t\r\u{08}\u{0C}", #""\n\t\r\b\f""#),
        ("\u{01}\u{1F}", #""\u0001\u001f""#),
        ("é 🎵 \u{2028}", "\"é 🎵 \u{2028}\""),
        ("</script>", #""</script>""#),
    ])
    func jsonString(_ input: String, _ expected: String) {
        #expect(ScriptConfig.jsonString(input) == expected)
    }

    @Test("names shared with bridge.js")
    func sharedNames() throws {
        let bridge = try YTAssets.text("scripts/bridge.js")
        #expect(bridge.contains("const NS = '\(ScriptConfig.namespace)';"))
        #expect(bridge.contains("const HANDLER = '\(ScriptConfig.messageHandlerName)';"))
        #expect(bridge.contains("const PROTOCOL_VERSION = \(BridgeMessage.protocolVersion);"))
    }
}
