// ContentRuleLoader — owner: Module B (PLAN.md §6.1 layer 1, D10).
//
// Turns rules/network.txt and rules/cosmetic.txt (Module A's compiler, `ContentRules.compile`) into
// two WKContentRuleLists, one per file, at launch, before either webview loads a page. Two lists so
// Debug › Settings can switch "Block ad requests" and "Hide ad elements" independently
// (WebViewStore.applyContentRules). Neither file has exceptions (`@@`), so splitting changes nothing
// WebKit matches. For each kind:
//   1. compile its rule file to JSON; the identifier is "ytadless-" + FNV-1a of that JSON
//   2. look the identifier up in WKContentRuleListStore.default() — a hit costs no compile
//   3. on a miss, compile it and remember it as that kind's last good identifier
//   4. if compiling fails, use that kind's last good list (never removed until a newer one compiles)
// Then remove ytadless- lists that neither kind uses. An empty list ("[]") is "nothing to apply".

import Foundation
import WebKit
import YTAssets
import YTCore

@MainActor
final class ContentRuleLoader {
    static let identifierPrefix = "ytadless-"
    static let maxDiagnosticsLogged = 20
    private static let source = "ContentRules"

    enum Kind: String, CaseIterable {
        case network, cosmetic
        var lastGoodKey: String { "ytadless.contentRules.lastGoodIdentifier.\(rawValue)" }
    }

    /// The compiled lists; nil where there is none.
    struct Lists {
        var network: WKContentRuleList?
        var cosmetic: WKContentRuleList?
        subscript(kind: Kind) -> WKContentRuleList? {
            get { kind == .network ? network : cosmetic }
            set { if kind == .network { network = newValue } else { cosmetic = newValue } }
        }
    }

    private let log: DebugLog
    private let defaults: UserDefaults
    private var status: [Kind: String] = [:]

    init(log: DebugLog, defaults: UserDefaults = .standard) {
        self.log = log
        self.defaults = defaults
    }

    func load() async -> Lists {
        var lists = Lists()
        let network: String, cosmetic: String
        do {
            network = try YTAssets.text("rules/network.txt")
            cosmetic = try YTAssets.text("rules/cosmetic.txt")
        } catch {
            log.native(.error, Self.source, "rule files unreadable: \(error)")
            for kind in Kind.allCases {
                lists[kind] = await fallback(kind, excluding: nil, reason: "rule files unreadable")
            }
            publishStatus()
            return lists
        }
        guard let store = Self.store() else {
            log.native(.error, Self.source, "WKContentRuleListStore.default() unavailable")
            log.contentRulesStatus = "store unavailable"
            return lists
        }
        var compiledFresh = false
        for kind in Kind.allCases {
            let compiled = kind == .network
                ? ContentRules.compile(network: network, cosmetic: "")
                : ContentRules.compile(network: "", cosmetic: cosmetic)
            let (list, fresh) = await load(kind, compiled: compiled, store: store)
            lists[kind] = list
            compiledFresh = compiledFresh || fresh
        }
        if compiledFresh {
            let keep = Set([lists.network, lists.cosmetic].compactMap { $0?.identifier })
            await removeStale(keeping: keep, in: store)
        }
        publishStatus()
        return lists
    }

    /// One kind's list, and whether it was compiled just now.
    private func load(_ kind: Kind, compiled: CompiledRules, store: WKContentRuleListStore) async -> (WKContentRuleList?, Bool) {
        for diagnostic in compiled.diagnostics.prefix(Self.maxDiagnosticsLogged) {
            log.native(.warn, Self.source, "\(kind.rawValue) diagnostic \(diagnostic)")
        }
        if compiled.diagnostics.count > Self.maxDiagnosticsLogged {
            log.native(.warn, Self.source, "… \(compiled.diagnostics.count - Self.maxDiagnosticsLogged) more \(kind.rawValue) diagnostics")
        }
        if Self.isEmpty(compiled.json) {
            log.native(.info, Self.source, "\(kind.rawValue): no content rules to apply (empty list)")
            status[kind] = "none (empty list)"
            return (nil, false)
        }
        let identifier = compiled.identifier
        if let cached = await Self.lookUp(identifier, in: store) {
            defaults.set(identifier, forKey: kind.lastGoodKey)
            log.native(.info, Self.source, "\(kind.rawValue): using cached list \(identifier)")
            status[kind] = "\(identifier) (cached)"
            return (cached, false)
        }
        let started = Date()
        switch await Self.compile(identifier, json: compiled.json, in: store) {
        case .success(let list):
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            defaults.set(identifier, forKey: kind.lastGoodKey)
            log.native(.info, Self.source, "\(kind.rawValue): compiled \(identifier) in \(ms) ms (\(compiled.json.utf8.count) bytes of JSON)")
            status[kind] = "\(identifier) (compiled in \(ms) ms)"
            return (list, true)
        case .failure(let error):
            log.native(.error, Self.source, "\(kind.rawValue): compiling \(identifier) failed: \(Self.describe(error))")
            let list = await fallback(kind, excluding: identifier, reason: "compile failed: \(Self.describe(error))", store: store)
            return (list, false)
        }
    }

    private func publishStatus() {
        log.contentRulesStatus = Kind.allCases.map { "\($0.rawValue): \(status[$0] ?? "none")" }.joined(separator: "; ")
    }

    // MARK: Fallback and cleanup

    private func fallback(_ kind: Kind, excluding failed: String?, reason: String, store: WKContentRuleListStore? = nil) async -> WKContentRuleList? {
        guard let lastGood = defaults.string(forKey: kind.lastGoodKey), lastGood != failed,
              let store = store ?? Self.store(),
              let list = await Self.lookUp(lastGood, in: store)
        else {
            log.native(.error, Self.source, "\(kind.rawValue): no last good list to fall back to; running without it")
            status[kind] = "none (\(reason); no last good list)"
            return nil
        }
        log.native(.warn, Self.source, "\(kind.rawValue): falling back to last good list \(lastGood)")
        status[kind] = "\(lastGood) (last good; \(reason))"
        return list
    }

    private func removeStale(keeping identifiers: Set<String>, in store: WKContentRuleListStore) async {
        let available = await Self.availableIdentifiers(in: store)
        for stale in available where stale.hasPrefix(Self.identifierPrefix) && !identifiers.contains(stale) {
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
