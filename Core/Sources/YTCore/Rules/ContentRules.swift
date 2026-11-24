// ContentRules compiler — owner: Module A (PLAN.md §5.6, §6.1).
//
// Compiles `rules/network.txt` (an Adblock Plus subset) and `rules/cosmetic.txt`
// (`domain##selector`) into WKContentRuleList JSON. Everything WebKit would reject, or would
// silently drop (an invalid `css-display-none` selector, F8), is a diagnostic instead, and the
// test suite fails on any diagnostic (D9). Output is deterministic: the same input always gives
// the same bytes, so the FNV-1a identifier changes only when the rules do (D10).
//
// Rule order in the output: network blocks, then cosmetic rules, then every `@@` exception
// (`ignore-previous-rules` only undoes rules that come before it).

import Foundation

public enum ContentRules {
    /// Where `:has()` selectors go. Spike S-B2 checks whether WebKit honours `:has()` inside
    /// `css-display-none`. If it doesn't, flip this to `.stylesheet`: the compiler then leaves
    /// those selectors out of the rule list and `stylesheet(cosmetic:)` returns them as CSS for
    /// the app to inject. This is the one place that switch lives (PLAN.md §6.1).
    public enum HasSelectorStrategy: String, Sendable, CaseIterable {
        case contentRule
        case stylesheet
    }

    public static let hasSelectorStrategy: HasSelectorStrategy = .contentRule

    /// Compiles `rules/network.txt` and `rules/cosmetic.txt` to WKContentRuleList JSON.
    public static func compile(network: String, cosmetic: String) -> CompiledRules {
        compile(network: network, cosmetic: cosmetic, hasStrategy: hasSelectorStrategy)
    }

    public static func compile(network: String, cosmetic: String, hasStrategy: HasSelectorStrategy) -> CompiledRules {
        var diagnostics: [RuleDiagnostic] = []
        let net = NetworkRuleParser.parse(network, file: RuleFiles.network)
        let css = CosmeticRuleParser.parse(cosmetic, file: RuleFiles.cosmetic)
        diagnostics += net.diagnostics
        diagnostics += css.diagnostics

        var rules: [ContentRule] = net.blocks
        for item in css.rules where !(hasStrategy == .stylesheet && item.usesHas) {
            rules.append(item.rule)
        }
        rules += net.exceptions

        if rules.isEmpty {
            diagnostics.append(RuleDiagnostic(file: RuleFiles.network, line: 0,
                                              message: "no rules: WebKit rejects an empty rule list"))
        }
        let json = "[" + rules.map(\.json).joined(separator: ",") + "]"
        return CompiledRules(json: json, identifier: identifier(for: json), diagnostics: diagnostics)
    }

    /// CSS for the cosmetic selectors that the strategy keeps out of the rule list
    /// (`selector { display: none !important; }` per line); empty under `.contentRule`.
    /// Domain-scoped rules are included only for the YouTube hosts, which is all the app loads.
    public static func stylesheet(cosmetic: String, hasStrategy: HasSelectorStrategy = hasSelectorStrategy) -> String {
        guard hasStrategy == .stylesheet else { return "" }
        return CosmeticRuleParser.parse(cosmetic, file: RuleFiles.cosmetic).rules
            .filter(\.usesHas)
            .map { $0.selector + " { display: none !important; }\n" }
            .joined()
    }

    /// `"ytadless-"` + 16 lowercase hex digits of the 64-bit FNV-1a hash of the UTF-8 JSON (D10).
    public static func identifier(for json: String) -> String {
        "ytadless-" + FNV1a.hex64(json)
    }
}

/// 64-bit FNV-1a. CryptoKit isn't available on Linux (D10).
public enum FNV1a {
    public static func hash64<S: Sequence<UInt8>>(_ bytes: S) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func hex64(_ string: String) -> String {
        let hex = String(hash64(string.utf8), radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

enum RuleFiles {
    static let network = "rules/network.txt"
    static let cosmetic = "rules/cosmetic.txt"
}

// ── The WKContentRuleList model (only what the compiler emits) ─────────────────────────────────

struct ContentRule: Equatable, Sendable {
    enum ActionType: String, Sendable {
        case block
        case cssDisplayNone = "css-display-none"
        case ignorePreviousRules = "ignore-previous-rules"
    }

    enum Condition: Equatable, Sendable {
        case ifDomain([String])
        case unlessDomain([String])
    }

    var urlFilter: String
    var resourceTypes: [String] = []
    var loadType: [String] = []
    var condition: Condition?
    var action: ActionType
    var selector: String?

    /// Fixed key order, formatted like `JSON.stringify`, so the bytes (and the identifier) are stable.
    var json: String {
        var trigger = ["\"url-filter\":" + ScriptConfig.jsonString(urlFilter)]
        if !resourceTypes.isEmpty { trigger.append("\"resource-type\":" + Self.list(resourceTypes)) }
        if !loadType.isEmpty { trigger.append("\"load-type\":" + Self.list(loadType)) }
        switch condition {
        case .ifDomain(let domains): trigger.append("\"if-domain\":" + Self.list(domains))
        case .unlessDomain(let domains): trigger.append("\"unless-domain\":" + Self.list(domains))
        case nil: break
        }
        var act = ["\"type\":" + ScriptConfig.jsonString(action.rawValue)]
        if let selector { act.append("\"selector\":" + ScriptConfig.jsonString(selector)) }
        return "{\"trigger\":{" + trigger.joined(separator: ",") + "},\"action\":{" + act.joined(separator: ",") + "}}"
    }

    private static func list(_ items: [String]) -> String {
        "[" + items.map(ScriptConfig.jsonString).joined(separator: ",") + "]"
    }
}

// ── Shared helpers ─────────────────────────────────────────────────────────────────────────────

enum RuleText {
    /// Lines with their 1-based numbers, trimmed; blank lines and `!` comments dropped.
    static func lines(_ text: String) -> [(number: Int, text: String)] {
        var out: [(Int, String)] = []
        var number = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let line = raw.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
            if line.isEmpty || line.hasPrefix("!") { continue }
            out.append((number, line))
        }
        return out
    }

    /// A domain WebKit accepts in `if-domain`/`unless-domain`: lowercase ASCII labels (F8).
    static func domainProblem(_ domain: String) -> String? {
        if domain.isEmpty { return "empty domain" }
        if domain.contains("*") { return "wildcard in domain \"\(domain)\" (subdomains are always included)" }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        if domain.lowercased() != domain && domain.allSatisfy(\.isASCII) {
            return "domain \"\(domain)\" must be lowercase"
        }
        if !domain.allSatisfy({ allowed.contains($0) }) {
            return "domain \"\(domain)\" must be lowercase ASCII (punycode)"
        }
        if domain.hasPrefix(".") || domain.hasSuffix(".") || domain.contains("..") {
            return "malformed domain \"\(domain)\""
        }
        return nil
    }

    /// `["a.com", "~b.com"]` → one condition, or a problem (WebKit allows one condition per trigger).
    static func condition(_ entries: [String]) -> Result<ContentRule.Condition?, RuleProblem> {
        var include: [String] = []
        var exclude: [String] = []
        for entry in entries {
            let negated = entry.hasPrefix("~")
            let domain = negated ? String(entry.dropFirst()) : entry
            if let problem = domainProblem(domain) { return .failure(RuleProblem(problem)) }
            if negated { exclude.append("*" + domain) } else { include.append("*" + domain) }
        }
        if !include.isEmpty && !exclude.isEmpty {
            return .failure(RuleProblem("mixes included and excluded domains; WebKit allows one condition per rule (F8)"))
        }
        if !include.isEmpty { return .success(.ifDomain(include)) }
        if !exclude.isEmpty { return .success(.unlessDomain(exclude)) }
        return .success(nil)
    }
}

struct RuleProblem: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}
