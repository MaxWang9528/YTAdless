// The app compiles network.txt and cosmetic.txt as two separate lists so Debug › Settings can
// toggle each (ContentRuleLoader, PLAN.md §6.2). Owner: Module B.

import Foundation
import Testing
@testable import YTAssets
@testable import YTCore

@Suite("ContentRules › split lists")
struct ContentRulesSplitTests {
    static let network = (try? YTAssets.text("rules/network.txt")) ?? ""
    static let cosmetic = (try? YTAssets.text("rules/cosmetic.txt")) ?? ""

    @Test("network.txt alone compiles to a non-empty list with zero diagnostics")
    func networkAlone() {
        let compiled = ContentRules.compile(network: Self.network, cosmetic: "")
        #expect(compiled.diagnostics.isEmpty, "\(compiled.diagnostics)")
        #expect(compiled.json != "[]")
        #expect(!compiled.json.contains("css-display-none"))
    }

    @Test("cosmetic.txt alone compiles to a non-empty list with zero diagnostics")
    func cosmeticAlone() {
        let compiled = ContentRules.compile(network: "", cosmetic: Self.cosmetic)
        #expect(compiled.diagnostics.isEmpty, "\(compiled.diagnostics)")
        #expect(compiled.json != "[]")
        #expect(!compiled.json.contains("\"block\""))
    }

    @Test("the two lists have different identifiers")
    func distinctIdentifiers() {
        let a = ContentRules.compile(network: Self.network, cosmetic: "").identifier
        let b = ContentRules.compile(network: "", cosmetic: Self.cosmetic).identifier
        #expect(a != b)
    }

    @Test("network.txt has no exceptions, so splitting the lists changes no match (ignore-previous-rules is per list)")
    func noExceptions() {
        let compiled = ContentRules.compile(network: Self.network, cosmetic: "")
        #expect(!compiled.json.contains("ignore-previous-rules"))
    }
}
