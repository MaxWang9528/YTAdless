// Content-rule types (PLAN.md §5.5, §5.6). Owner: P0 (frozen contract). The compiler is Module A's.

import Foundation

public struct RuleDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int
    public var message: String

    public init(file: String, line: Int, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }

    public var description: String { "\(file):\(line): \(message)" }
}

public struct CompiledRules: Sendable {
    /// WKContentRuleList JSON (an array of rules).
    public let json: String
    /// `"ytadless-" + FNV-1a(json)`; the WKContentRuleListStore identifier (D10).
    public let identifier: String
    /// Any diagnostic fails `swift test` (D9).
    public let diagnostics: [RuleDiagnostic]

    public init(json: String, identifier: String, diagnostics: [RuleDiagnostic]) {
        self.json = json
        self.identifier = identifier
        self.diagnostics = diagnostics
    }
}
