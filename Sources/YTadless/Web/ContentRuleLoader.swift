// ContentRuleLoader — owner: Module B (PLAN.md §6.1 layer 1, D10).
//
// Turns rules/network.txt + rules/cosmetic.txt (Module A's compiler, `ContentRules.compile`) into
// a WKContentRuleList, at launch, before either webview loads a page:
//   1. compile the rule files to JSON; the identifier is "ytadless-" + FNV-1a of that JSON
//   2. look the identifier up in WKContentRuleListStore.default() — a hit costs no compile
//   3. on a miss, compile it, remember it as the last good identifier, remove stale ytadless- lists
//   4. if compiling fails, use the last good list (never removed until a newer one compiles)
// An empty list ("[]", Module A's Phase 0 stub) is "nothing to apply", not a failure.

import Foundation
import WebKit
import YTAssets
import YTCore

@MainActor
final class ContentRuleLoader {
    static let identifierPrefix = "ytadless-"
    static let lastGoodKey = "ytadless.contentRules.lastGoodIdentifier"
    static let maxDiagnosticsLogged = 20
    private static let source = "ContentRules"

    private let log: DebugLog
    private let defaults: UserDefaults

    init(log: DebugLog, defaults: UserDefaults = .standard) {
        self.log = log
        self.defaults = defaults
    }

    /// The list to add to both webviews, or nil when there is none.
    func load() async -> WKContentRuleList? {
        let compiled: CompiledRules
        do {
            compiled = ContentRules.compile(network: try YTAssets.text("rules/network.txt"),
                                            cosmetic: try YTAssets.text("rules/cosmetic.txt"))
        } catch {
            log.native(.error, Self.source, "rule files unreadable: \(error)")
            return await fallback(excluding: nil, reason: "rule files unreadable")
        }
        for diagnostic in compiled.diagnostics.prefix(Self.maxDiagnosticsLogged) {
            log.native(.warn, Self.source, "diagnostic \(diagnostic)")
        }
        if compiled.diagnostics.count > Self.maxDiagnosticsLogged {
            log.native(.warn, Self.source, "… \(compiled.diagnostics.count - Self.maxDiagnosticsLogged) more diagnostics")
        }
        if Self.isEmpty(compiled.json) {
            log.native(.info, Self.source, "no content rules to apply (empty list)")
            log.contentRulesStatus = "none (the rule files compile to an empty list)"
            return nil
        }

        guard let store = Self.store() else {
            log.native(.error, Self.source, "WKContentRuleListStore.default() unavailable")
            log.contentRulesStatus = "store unavailable"
            return nil
        }
        let identifier = compiled.identifier

        if let cached = await Self.lookUp(identifier, in: store) {
            defaults.set(identifier, forKey: Self.lastGoodKey)
            log.native(.info, Self.source, "using cached list \(identifier)")
            log.contentRulesStatus = "\(identifier) (cached)"
            return cached
        }

        let started = Date()
        switch await Self.compile(identifier, json: compiled.json, in: store) {
        case .success(let list):
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            defaults.set(identifier, forKey: Self.lastGoodKey)
            log.native(.info, Self.source, "compiled \(identifier) in \(ms) ms (\(compiled.json.utf8.count) bytes of JSON)")
            log.contentRulesStatus = "\(identifier) (compiled in \(ms) ms)"
            await removeStale(keeping: identifier, in: store)
            return list
        case .failure(let error):
            log.native(.error, Self.source, "compiling \(identifier) failed: \(Self.describe(error))")
            return await fallback(excluding: identifier, reason: "compile failed: \(Self.describe(error))", store: store)
        }
    }

    // MARK: Fallback and cleanup

    private func fallback(excluding failed: String?, reason: String, store: WKContentRuleListStore? = nil) async -> WKContentRuleList? {
        guard let lastGood = defaults.string(forKey: Self.lastGoodKey), lastGood != failed,
              let store = store ?? Self.store(),
              let list = await Self.lookUp(lastGood, in: store)
        else {
            log.native(.error, Self.source, "no last good list to fall back to; running without content rules")
            log.contentRulesStatus = "none (\(reason); no last good list)"
            return nil
        }
        log.native(.warn, Self.source, "falling back to last good list \(lastGood)")
        log.contentRulesStatus = "\(lastGood) (last good; \(reason))"
        return list
    }

    private func removeStale(keeping identifier: String, in store: WKContentRuleListStore) async {
        let identifiers = await Self.availableIdentifiers(in: store)
        for stale in identifiers where stale.hasPrefix(Self.identifierPrefix) && stale != identifier {
            if let error = await Self.remove(stale, from: store) {
                log.native(.warn, Self.source, "removing stale list \(stale) failed: \(Self.describe(error))")
            } else {
                log.native(.debug, Self.source, "removed stale list \(stale)")
            }
        }
    }

    // MARK: WebKit wrappers (completion-handler API, called and answered on the main thread)

    private static func store() -> WKContentRuleListStore? {
        let store: WKContentRuleListStore? = WKContentRuleListStore.default()
        return store
    }

    private static func lookUp(_ identifier: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    private static func compile(_ identifier: String, json: String, in store: WKContentRuleListStore) async -> Result<WKContentRuleList, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<WKContentRuleList, Error>, Never>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: .success(list))
                } else {
                    continuation.resume(returning: .failure(error ?? CompileError.noList))
                }
            }
        }
    }

    private static func availableIdentifiers(in store: WKContentRuleListStore) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: identifiers ?? [])
            }
        }
    }

    private static func remove(_ identifier: String, from store: WKContentRuleListStore) async -> Error? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private enum CompileError: Error, CustomStringConvertible {
        case noList
        var description: String { "WebKit returned neither a list nor an error" }
    }

    static func isEmpty(_ json: String) -> Bool {
        json.filter { !$0.isWhitespace } == "[]"
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}
