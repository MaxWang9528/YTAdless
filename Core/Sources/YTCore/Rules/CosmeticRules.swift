// Cosmetic rule parser and CSS selector validator — owner: Module A (PLAN.md §5.6, F8).
//
// `##selector` or `a.com,b.com##selector` (or `~a.com##…`) → `css-display-none`. WebKit silently
// skips a css-display-none rule whose selector it can't parse, so every selector is checked here
// against the standard selector grammar plus an allowlist of pseudo-classes. Procedural and
// extended syntax (`:has-text()`, `:upward()`, `:xpath()`, `:-abp-…`, `#?#`, `#@#`, `##+js(…)`,
// `##^…`) is a diagnostic: that kind of logic belongs in the JS layer.

import Foundation

enum CosmeticRuleParser {
    struct Item {
        var rule: ContentRule
        var selector: String
        var usesHas: Bool
    }

    struct Output {
        var rules: [Item] = []
        var diagnostics: [RuleDiagnostic] = []
    }

    static func parse(_ text: String, file: String) -> Output {
        var out = Output()
        for (number, line) in RuleText.lines(text) {
            switch parseLine(line) {
            case .success(let item): out.rules.append(item)
            case .failure(let problem):
                out.diagnostics.append(RuleDiagnostic(file: file, line: number, message: "\(problem.message): \(line)"))
            }
        }
        return out
    }

    static func parseLine(_ line: String) -> Result<Item, RuleProblem> {
        let unsupported: [(String, String)] = [
            ("#@#", "element-hiding exceptions (#@#)"),
            ("#?#", "procedural cosmetic filters (#?#)"),
            ("#$#", "CSS injection (#$#)"),
            ("#%#", "scriptlets (#%#)"),
            ("##+js(", "scriptlets (##+js)"),
            ("##^", "HTML filters (##^)"),
        ]
        for (marker, what) in unsupported where line.contains(marker) {
            return .failure(RuleProblem("\(what) are not supported; do this in the JS layer"))
        }
        guard let range = line.range(of: "##") else {
            return .failure(RuleProblem("not a cosmetic rule (expected domain##selector or ##selector)"))
        }
        let domainPart = line[..<range.lowerBound]
        let selector = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if selector.isEmpty { return .failure(RuleProblem("empty selector")) }

        var condition: ContentRule.Condition?
        if !domainPart.isEmpty {
            let entries = domainPart.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            switch RuleText.condition(entries) {
            case .success(let c): condition = c
            case .failure(let problem): return .failure(problem)
            }
        }
        if let problem = SelectorValidator.problem(selector) {
            return .failure(RuleProblem("selector: \(problem)"))
        }
        let rule = ContentRule(urlFilter: ".*", condition: condition, action: .cssDisplayNone, selector: selector)
        return .success(Item(rule: rule, selector: selector, usesHas: SelectorValidator.usesHas(selector)))
    }
}

/// A recursive-descent check of CSS selector lists (Selectors Level 4 subset WebKit supports).
enum SelectorValidator {
    /// Pseudo-classes without arguments that WebKit supports and that make sense for hiding.
    static let simplePseudoClasses: Set<String> = [
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type",
        "empty", "root", "link", "visited", "checked", "disabled", "enabled", "required", "optional",
        "defined", "scope",
    ]
    /// Pseudo-classes taking a selector list. `:has()` takes relative selectors (`:has(> x)`).
    static let selectorPseudoClasses: Set<String> = ["not", "is", "where", "has", "matches"]
    /// Pseudo-classes taking an An+B argument.
    static let nthPseudoClasses: Set<String> = ["nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type"]

    static func usesHas(_ selector: String) -> Bool {
        selector.range(of: ":has(", options: .caseInsensitive) != nil
    }

    static func problem(_ selector: String) -> String? {
        guard selector.allSatisfy(\.isASCII) else { return "non-ASCII selector" }
        var parser = Parser(Array(selector))
        do {
            try parser.selectorList(relative: false)
            parser.skipSpace()
            if !parser.atEnd { throw RuleProblem("unexpected \"\(parser.peek!)\" at offset \(parser.i)") }
            return nil
        } catch let error as RuleProblem {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    struct Parser {
        var s: [Character]
        var i = 0
        init(_ s: [Character]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        var peek: Character? { atEnd ? nil : s[i] }

        mutating func skipSpace() { while let c = peek, c.isWhitespace { i += 1 } }

        mutating func selectorList(relative: Bool) throws {
            repeat {
                skipSpace()
                try complexSelector(relative: relative)
                skipSpace()
            } while eat(",")
        }

        mutating func eat(_ c: Character) -> Bool {
            if peek == c { i += 1; return true }
            return false
        }

        mutating func complexSelector(relative: Bool) throws {
            skipSpace()
            if relative, let c = peek, ">+~".contains(c) {
                i += 1
                skipSpace()
            }
            try compoundSelector()
            while true {
                let before = i
                skipSpace()
                guard let c = peek, c != ",", c != ")" else { return }
                if ">+~".contains(c) {
                    i += 1
                    skipSpace()
                } else if i == before {
                    return  // no whitespace and no combinator: caller decides
                }
                try compoundSelector()
            }
        }

        mutating func compoundSelector() throws {
            var any = false
            if eat("*") {
                any = true
            } else if peek.map(Self.isIdentStart) == true || peek == "-" || peek == "\\" {
                _ = try ident()
                any = true
            }
            while let c = peek {
                switch c {
                case "#":
                    i += 1
                    _ = try ident(allowDigitStart: true)
                case ".":
                    i += 1
                    _ = try ident()
                case "[":
                    try attribute()
                case ":":
                    try pseudo()
                default:
                    if !any { throw RuleProblem(atEnd ? "expected a selector" : "unexpected \"\(c)\" at offset \(i)") }
                    return
                }
                any = true
            }
            if !any { throw RuleProblem("expected a selector") }
        }

        mutating func attribute() throws {
            i += 1  // [
            skipSpace()
            _ = try ident()
            skipSpace()
            if eat("]") { return }
            if let c = peek, "~|^$*".contains(c) {
                i += 1
                guard eat("=") else { throw RuleProblem("expected = after \(c) in attribute selector") }
            } else if !eat("=") {
                throw RuleProblem("bad attribute selector at offset \(i)")
            }
            skipSpace()
            if peek == "\"" || peek == "'" {
                try string()
            } else {
                _ = try ident(allowDigitStart: true)
            }
            skipSpace()
            if let c = peek, c == "i" || c == "s" || c == "I" || c == "S" {
                i += 1
                skipSpace()
            }
            guard eat("]") else { throw RuleProblem("unterminated attribute selector") }
        }

        mutating func string() throws {
            let quote = s[i]
            i += 1
            while let c = peek {
                i += 1
                if c == "\\" { i += 1; continue }
                if c == quote { return }
                if c == "\n" { break }
            }
            throw RuleProblem("unterminated string")
        }

        mutating func pseudo() throws {
            i += 1  // :
            if eat(":") { throw RuleProblem("pseudo-elements (::) cannot be hidden with display:none rules") }
            let name = try ident().lowercased()
            if eat("(") {
                if SelectorValidator.selectorPseudoClasses.contains(name) {
                    try selectorList(relative: name == "has")
                } else if SelectorValidator.nthPseudoClasses.contains(name) {
                    let start = i
                    while let c = peek, c != ")" { i += 1 }
                    let arg = String(s[start..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                    if arg.wholeMatch(of: /odd|even|[+-]?\d+|[+-]?\d*n(\s*[+-]\s*\d+)?/) == nil {
                        throw RuleProblem("bad :\(name)() argument \"\(arg)\"")
                    }
                } else {
                    throw RuleProblem("unsupported pseudo-class :\(name)() (procedural filters belong in the JS layer)")
                }
                skipSpace()
                guard eat(")") else { throw RuleProblem("unterminated :\(name)(") }
            } else if !SelectorValidator.simplePseudoClasses.contains(name) {
                throw RuleProblem("unsupported pseudo-class :\(name)")
            }
        }

        static func isIdentStart(_ c: Character) -> Bool {
            c == "_" || (c.isASCII && c.isLetter)
        }

        static func isIdentChar(_ c: Character) -> Bool {
            c == "_" || c == "-" || (c.isASCII && (c.isLetter || c.isNumber))
        }

        mutating func ident(allowDigitStart: Bool = false) throws -> String {
            let start = i
            if peek == "-" { i += 1 }
            if peek == "-" { i += 1 }
            guard let first = peek, Self.isIdentStart(first) || first == "\\" || (allowDigitStart && first.isNumber) || (i > start && first.isNumber == false && Self.isIdentChar(first)) else {
                throw RuleProblem(atEnd ? "expected a name at the end" : "expected a name at offset \(i)")
            }
            while let c = peek {
                if c == "\\" {
                    i += 2
                    if i > s.count { throw RuleProblem("trailing backslash") }
                } else if Self.isIdentChar(c) {
                    i += 1
                } else {
                    break
                }
            }
            return String(s[start..<min(i, s.count)])
        }
    }
}
