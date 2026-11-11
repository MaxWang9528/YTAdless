// YTAssets resource access (PLAN.md §5.5, D4). Owner: P0.

import Testing
@testable import YTAssets

@Suite("Assets")
struct AssetsTests {
    @Test("manifest, scripts and rule files load from the bundle", arguments: [
        "manifest.json", "scripts/bridge.js", "rules/network.txt", "rules/cosmetic.txt",
    ])
    func loads(_ path: String) throws {
        #expect(!(try YTAssets.text(path)).isEmpty)
    }

    @Test("paths outside the bundle are rejected", arguments: [
        "", "/etc/passwd", "../Package.swift", "scripts/../manifest.json", "scripts//bridge.js", "./manifest.json",
    ])
    func rejectsBadPaths(_ path: String) {
        #expect(throws: YTAssetsError.invalidPath(path)) { try YTAssets.text(path) }
    }

    @Test("a missing file is notFound")
    func missing() {
        #expect(throws: YTAssetsError.notFound("scripts/nope.js")) { try YTAssets.text("scripts/nope.js") }
    }
}
