// ContentRules API contract (PLAN.md §5.5, D9, D10). Owner: P0. Module A adds RulesTests for the
// compiler itself.

import Testing
@testable import YTAssets
@testable import YTCore

@Suite("Rules › contract")
struct ContentRulesContractTests {
    @Test("every shipped rule compiles with zero diagnostics")
    func shippedRulesCompileClean() throws {
        let compiled = ContentRules.compile(network: try YTAssets.text("rules/network.txt"),
                                            cosmetic: try YTAssets.text("rules/cosmetic.txt"))
        #expect(compiled.diagnostics == [], "\(compiled.diagnostics.map(\.description))")
        #expect(compiled.identifier == ContentRules.identifier(for: compiled.json))
    }

    @Test("identifier is ytadless- plus 16 hex digits of FNV-1a 64")
    func identifierFormat() {
        let identifier = ContentRules.identifier(for: "[]")
        #expect(identifier.wholeMatch(of: /ytadless-[0-9a-f]{16}/) != nil)
        #expect(identifier == ContentRules.identifier(for: "[]"))
        #expect(identifier != ContentRules.identifier(for: "[ ]"))
    }

    @Test("FNV-1a 64 reference values", arguments: [
        ("", "cbf29ce484222325"),
        ("a", "af63dc4c8601ec8c"),
        ("foobar", "85944171f73967e8"),
    ])
    func fnv(_ input: String, _ hex: String) {
        #expect(FNV1a.hex64(input) == hex)
    }
}
