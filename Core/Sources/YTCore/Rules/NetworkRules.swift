// Network rule parser (ABP subset → WKContentRuleList block / ignore-previous-rules)
// — owner: Module A (PLAN.md §5.6).
//
// Supported, per §5.6: `||domain^`, `||host/path` prefixes, `|` anchors, `*`, `^`, `/regex/`,
// `@@` exceptions, `$script,image,stylesheet,xhr,media,font,ping,subdocument`,
// `$third-party`/`$~third-party`, `$domain=a|b` or `$domain=~a|~b`. Everything else is a diagnostic.

import Foundation

enum NetworkRuleParser {
    struct Output {
        var blocks: [ContentRule] = []
        var exceptions: [ContentRule] = []
        var diagnostics: [RuleDiagnostic] = []
    }

    /// ABP type option → WebKit `resource-type` values. Verified against WebKit's
    /// `readResourceType` (Source/WebCore/loader/ResourceLoadInfo.cpp, main, 2026-11-24).
    static let resourceTypes: [String: [String]] = [
        "script": ["script"],
        "image": ["image"],
        "stylesheet": ["style-sheet"],
        "xhr": ["fetch", "raw"],
        "xmlhttprequest": ["fetch", "raw"],
        "media": ["media"],
        "font": ["font"],
        "ping": ["ping"],
        "subdocument": ["child-document"],
    ]

    /// Options that exist in ABP/uBO but are deliberately unsupported (logic belongs in JS).
    static let rejectedOptions: Set<String> = [
        "replace", "redirect", "redirect-rule", "removeparam", "queryprune", "csp", "important",
        "rewrite", "header", "permissions", "urltransform", "uritransform", "denyallow", "to", "from",
        "method", "badfilter", "popup", "document", "doc", "generichide", "elemhide", "all",
    ]

    static func parse(_ text: String, file: String) -> Output {
        var out = Output()
        for (number, line) in RuleText.lines(text) {
            switch parseLine(line) {
            case .success(let parsed):
                if parsed.isException { out.exceptions.append(parsed.rule) } else { out.blocks.append(parsed.rule) }
            case .failure(let problem):
                out.diagnostics.append(RuleDiagnostic(file: file, line: number, message: "\(problem.message): \(line)"))
            }
        }
        return out
    }

    struct Parsed {
        var rule: ContentRule
        var isException: Bool
    }

    static func parseLine(_ line: String) -> Result<Parsed, RuleProblem> {
        for marker in ["#@#", "#?#", "#$#", "#%#", "##"] where line.contains(marker) {
            return .failure(RuleProblem("cosmetic or scriptlet syntax \"\(marker)\" does not belong in network.txt"))
        }
        if line.hasPrefix("[") { return .failure(RuleProblem("filter list header is not supported")) }

        var body = Substring(line)
        let isException = body.hasPrefix("@@")
        if isException { body = body.dropFirst(2) }

        // Options follow the last `$`; for a /regex/ only a `$` right after its closing slash counts.
        var pattern = String(body)
        var optionText: String?
        if body.hasPrefix("/") {
            if let range = body.range(of: "/$", options: .backwards), range.lowerBound > body.startIndex {
                optionText = String(body[range.upperBound...])
                pattern = String(body[..<body.index(after: range.lowerBound)])
            }
        } else if let dollar = body.lastIndex(of: "$") {
            optionText = String(body[body.index(after: dollar)...])
            pattern = String(body[..<dollar])
        }
        if optionText == "" { return .failure(RuleProblem("empty option list after $")) }

        var rule = ContentRule(urlFilter: "", action: isException ? .ignorePreviousRules : .block)
        if let optionText {
            if case .failure(let problem) = applyOptions(optionText, to: &rule) { return .failure(problem) }
        }

        switch URLFilter.fromABP(pattern) {
        case .success(let filter): rule.urlFilter = filter
        case .failure(let problem): return .failure(problem)
        }
        if pattern.isEmpty || pattern == "*" {
            if rule.condition == nil && rule.resourceTypes.isEmpty {
                return .failure(RuleProblem("a rule with no pattern needs a $domain or a type option"))
            }
        }
        return .success(Parsed(rule: rule, isException: isException))
    }

    static func applyOptions(_ text: String, to rule: inout ContentRule) -> Result<Void, RuleProblem> {
        var types: [String] = []
        for option in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            let lower = option.lowercased()
            if lower.isEmpty { return .failure(RuleProblem("empty option")) }
            if lower == "third-party" || lower == "3p" {
                rule.loadType = ["third-party"]
            } else if lower == "~third-party" || lower == "1p" || lower == "first-party" {
                rule.loadType = ["first-party"]
            } else if lower.hasPrefix("domain=") {
                if rule.condition != nil { return .failure(RuleProblem("$domain given twice")) }
                let entries = option.dropFirst("domain=".count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                switch RuleText.condition(entries) {
                case .success(let condition): rule.condition = condition
                case .failure(let problem): return .failure(problem)
                }
            } else if let mapped = resourceTypes[lower] {
                for type in mapped where !types.contains(type) { types.append(type) }
            } else if lower.hasPrefix("~"), resourceTypes[String(lower.dropFirst())] != nil {
                return .failure(RuleProblem("negated type option \"\(option)\" is not supported"))
            } else {
                let name = String(lower.split(separator: "=", maxSplits: 1).first ?? "")
                if rejectedOptions.contains(name) {
                    return .failure(RuleProblem("unsupported option \"$\(name)\" (do this in the JS layer)"))
                }
                return .failure(RuleProblem("unknown option \"\(option)\""))
            }
        }
        rule.resourceTypes = types
        return .success(())
    }
}

// ── url-filter: ABP pattern → WebKit regex, and the WebKit regex-subset validator ──────────────

enum URLFilter {
    /// `||` = scheme plus any subdomains. WebKit matches url-filter against the whole URL, which
    /// always has a path after the host, so this cannot match `notdoubleclick.net`.
    static let domainAnchor = "^[a-z][a-z0-9.+-]*://([^/:]*\\.)?"
    /// ABP `^`: a separator (anything but a letter, digit, or `_ - . %`). WebKit URLs always have
    /// a `/` after the host, so a trailing `^` never needs to match end-of-string.
    static let separator = "[^a-z0-9_.%-]"

    static func fromABP(_ pattern: String) -> Result<String, RuleProblem> {
        if pattern.count >= 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let regex = String(pattern.dropFirst().dropLast())
            if let problem = webKitProblem(regex) { return .failure(RuleProblem("regex: \(problem)")) }
            return .success(regex)
        }
        guard pattern.allSatisfy(\.isASCII) else { return .failure(RuleProblem("non-ASCII pattern")) }
        if pattern.isEmpty || pattern == "*" { return .success(".*") }

        var rest = Substring(pattern)
        var out = ""
        if rest.hasPrefix("||") {
            out = domainAnchor
            rest = rest.dropFirst(2)
            if rest.isEmpty { return .failure(RuleProblem("|| with no domain")) }
        } else if rest.hasPrefix("|") {
            out = "^"
            rest = rest.dropFirst()
        }
        var endAnchor = false
        if rest.hasSuffix("|") {
            endAnchor = true
            rest = rest.dropLast()
        }
        for char in rest {
            switch char {
            case "*": out += ".*"
            case "^": out += separator
            case "|": return .failure(RuleProblem("| in the middle of a pattern"))
            case ".", "?", "+", "(", ")", "[", "]", "{", "}", "\\", "$":
                out += "\\" + String(char)
            default: out.append(char)
            }
        }
        if endAnchor { out += "$" }
        // Leading `.*` is the default for an unanchored filter and only slows WebKit down.
        while out.hasPrefix(".*") && out.count > 2 { out.removeFirst(2) }
        if let problem = webKitProblem(out) { return .failure(RuleProblem("compiled regex: \(problem)")) }
        return .success(out)
    }

    /// Checks a url-filter against the regex subset WebKit's URLFilterParser accepts (F8):
    /// ASCII only; `.`, character sets, groups, `*`/`+`/`?`; `^` only at the start and `$` only at
    /// the end; no `|` disjunction, no `{n,m}`, no backreferences, no `\d`/`\w`/`\s`/`\b`, no `(?…)`.
    /// Returns nil when the filter is acceptable.
    static func webKitProblem(_ regex: String) -> String? {
        if regex.isEmpty { return "empty url-filter" }
        guard regex.allSatisfy(\.isASCII) else { return "non-ASCII characters" }
        let chars = Array(regex)
        var i = 0
        var depth = 0
        var lastWasAtom = false
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                guard i + 1 < chars.count else { return "trailing backslash" }
                let next = chars[i + 1]
                if next.isLetter || next.isNumber { return "escape \\\(next) is not supported (only escaped punctuation)" }
                i += 2
                lastWasAtom = true
                continue
            case "[":
                var j = i + 1
                if j < chars.count && chars[j] == "^" { j += 1 }
                if j < chars.count && chars[j] == "]" { j += 1 }
                while j < chars.count && chars[j] != "]" {
                    if chars[j] == "\\" {
                        guard j + 1 < chars.count else { return "trailing backslash in a character set" }
                        if chars[j + 1].isLetter || chars[j + 1].isNumber { return "escape \\\(chars[j + 1]) is not supported" }
                        j += 1
                    }
                    j += 1
                }
                if j >= chars.count { return "unterminated character set" }
                i = j + 1
                lastWasAtom = true
                continue
            case "]": return "unbalanced ]"
            case "(":
                if i + 1 < chars.count && chars[i + 1] == "?" { return "(?…) groups and lookarounds are not supported" }
                depth += 1
                lastWasAtom = false
            case ")":
                if depth == 0 { return "unbalanced )" }
                if !lastWasAtom { return "empty group" }
                depth -= 1
                lastWasAtom = true
            case "|": return "disjunction | is not supported"
            case "{", "}": return "{n,m} quantifiers are not supported"
            case "*", "+", "?":
                if !lastWasAtom { return "quantifier \(c) with nothing to repeat" }
                if i + 1 < chars.count && "*+?".contains(chars[i + 1]) { return "stacked quantifiers" }
                lastWasAtom = false
            case "^":
                if i != 0 { return "^ is only supported at the start" }
                lastWasAtom = false
            case "$":
                if i != chars.count - 1 { return "$ is only supported at the end" }
                lastWasAtom = false
            default:
                lastWasAtom = true
            }
            i += 1
        }
        if depth != 0 { return "unbalanced (" }
        return nil
    }
}
