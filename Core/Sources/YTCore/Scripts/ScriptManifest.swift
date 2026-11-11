// ScriptManifest (PLAN.md §5.1). Owner: P0 (frozen contract).
//
// `manifest.json` (in YTAssets) is the only place script order, roles and frames live (D7).
// Swift and the Node harness (`js/test/harness.mjs` → `injectionPlan`) build the same plan from
// it: the generated config prelude first, then each manifest file for the role, in order.

import Foundation

public struct ScriptManifest: Decodable, Equatable, Sendable {
    public enum Injection: String, Codable, Sendable { case start, end }

    public struct Entry: Decodable, Equatable, Sendable {
        /// File name under `scripts/`.
        public var file: String
        public var roles: [WebRole]
        public var injection: Injection
        public var mainFrameOnly: Bool
        /// Module that owns the file: "P0", "A", "B", "C" or "D".
        public var owner: String

        public init(file: String, roles: [WebRole], injection: Injection, mainFrameOnly: Bool, owner: String) {
            self.file = file
            self.roles = roles
            self.injection = injection
            self.mainFrameOnly = mainFrameOnly
            self.owner = owner
        }
    }

    public var version: Int
    public var scripts: [Entry]

    public init(version: Int = 1, scripts: [Entry]) {
        self.version = version
        self.scripts = scripts
    }

    public static func parse(_ json: String) throws -> ScriptManifest {
        try JSONDecoder().decode(ScriptManifest.self, from: Data(json.utf8))
    }

    /// The manifest entries injected into `role`'s webview, in manifest order.
    public func entries(for role: WebRole) -> [Entry] {
        scripts.filter { $0.roles.contains(role) }
    }

    /// Structural problems; empty for a valid manifest.
    public func problems() -> [String] {
        var problems: [String] = []
        if version != 1 { problems.append("unsupported manifest version \(version)") }
        if scripts.first?.file != "bridge.js" { problems.append("bridge.js must be the first script") }
        var seen = Set<String>()
        for entry in scripts {
            if !seen.insert(entry.file).inserted { problems.append("\(entry.file) is listed twice") }
            if !entry.file.hasSuffix(".js") || entry.file.contains("/") || entry.file.hasPrefix(".") {
                problems.append("\(entry.file) is not a plain .js file name")
            }
            if entry.roles.isEmpty || Set(entry.roles).count != entry.roles.count {
                problems.append("\(entry.file) has empty or duplicate roles")
            }
            if !["P0", "A", "B", "C", "D"].contains(entry.owner) {
                problems.append("\(entry.file) has unknown owner \(entry.owner)")
            }
        }
        return problems
    }

    /// The user scripts for one webview: the config prelude, then every entry for `role`.
    /// `load` receives a bundle-relative path (`"scripts/bridge.js"`) and returns its text.
    /// Each source gets a `//# sourceURL=ytadless/<file>` line so stacks name the file.
    public func injectionPlan(for role: WebRole, debug: Bool, build: String,
                              load: (String) throws -> String) rethrows -> [InjectedScript] {
        var plan = [InjectedScript(
            name: InjectedScript.preludeName,
            source: InjectedScript.withSourceURL(ScriptConfig.prelude(role: role, debug: debug, build: build),
                                                 name: InjectedScript.preludeName),
            injection: .start,
            mainFrameOnly: false
        )]
        for entry in entries(for: role) {
            let text = try load("scripts/" + entry.file)
            plan.append(InjectedScript(name: entry.file,
                                       source: InjectedScript.withSourceURL(text, name: entry.file),
                                       injection: entry.injection,
                                       mainFrameOnly: entry.mainFrameOnly))
        }
        return plan
    }
}

/// One `WKUserScript` to add, in order, in the page content world (D5).
public struct InjectedScript: Equatable, Sendable {
    public static let preludeName = "prelude.js"

    public var name: String
    public var source: String
    public var injection: ScriptManifest.Injection
    public var mainFrameOnly: Bool

    public init(name: String, source: String, injection: ScriptManifest.Injection, mainFrameOnly: Bool) {
        self.name = name
        self.source = source
        self.injection = injection
        self.mainFrameOnly = mainFrameOnly
    }

    static func withSourceURL(_ source: String, name: String) -> String {
        source + (source.hasSuffix("\n") ? "" : "\n") + "//# sourceURL=ytadless/\(name)\n"
    }
}
