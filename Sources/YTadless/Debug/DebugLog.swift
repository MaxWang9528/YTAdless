// DebugLog — owner: Module B (PLAN.md §6.2 Debug tooling, D19).
//
// The in-app log: bridge `log`/`scriptError`/`ready`/`pageChanged` lines from both webviews,
// `filterHit` totals, and native lines (routing decisions, content-rule loading, navigation
// failures, capture). WebViewStore creates it and subscribes it to the hub before the first page
// loads, so nothing posted at launch is missed. Every line is mirrored to os.Logger.

import Foundation
import Observation
import os
import YTCore

@MainActor
@Observable
final class DebugLog {
    struct Entry: Identifiable, Sendable {
        enum Origin: String, CaseIterable, Sendable { case browse, player, native }
        let id: Int
        let date: Date
        let origin: Origin
        let isMainFrame: Bool
        let level: LogLevel
        let source: String
        let message: String
    }

    static let maxEntries = 2000

    private(set) var entries: [Entry] = []
    /// `filterHit` totals per rule, summed over both webviews.
    private(set) var filterHits: [String: Int] = [:]
    private(set) var scriptErrorCount = 0
    /// scriptErrors since the viewer was last opened (the badge).
    private(set) var unseenErrorCount = 0
    /// One line about the content-rule list in use (set by ContentRuleLoader).
    var contentRulesStatus = "not loaded yet"

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var subscription: AnyObject?
    @ObservationIgnored private let logger = Logger(subsystem: "com.example.YTadless", category: "DebugLog")

    init() {}

    func attach(to hub: BridgeEventHub) {
        subscription = hub.subscribe { [weak self] event in
            self?.consume(event)
        }
    }

    func markErrorsSeen() {
        unseenErrorCount = 0
    }

    func clear() {
        entries.removeAll()
        filterHits.removeAll()
        scriptErrorCount = 0
        unseenErrorCount = 0
    }

    /// A native line.
    func native(_ level: LogLevel, _ source: String, _ message: String) {
        append(origin: .native, isMainFrame: true, level: level, source: source, message: message)
    }

    private func consume(_ event: BridgeEventHub.Event) {
        let origin: Entry.Origin = event.role == .browse ? .browse : .player
        func line(_ level: LogLevel, _ source: String, _ message: String) {
            append(origin: origin, isMainFrame: event.isMainFrame, level: level, source: source, message: message)
        }
        switch event.message {
        case .ready(_, let url):
            line(.info, "bridge.js", "ready \(url)")
        case .log(let level, let source, let message):
            line(level, source, message)
        case .scriptError(let source, let message, let stack):
            scriptErrorCount += 1
            unseenErrorCount += 1
            line(.error, source, stack.map { "\(message)\n\($0)" } ?? message)
        case .filterHit(let rule, let count):
            filterHits[rule, default: 0] += count  // totals only (Counters tab); a line per hit would flood the log
        case .pageChanged(let url, let title):
            line(.debug, "router.js", "pageChanged \(url)" + (title.map { " — \($0)" } ?? ""))
        case .videoMeta(let meta):
            line(.info, "player-bridge.js", "videoMeta \(meta.videoId) “\(meta.title)” by \(meta.author)")
        case .presentation(let mode):
            line(.info, "player-bridge.js", "presentation \(mode.rawValue)")
        case .unknown(let type):
            line(.warn, "bridge", "unknown message type \(type)")
        case .route, .playback, .selectTab:
            break  // routes and tab switches are logged by WebViewStore; playback is ~1 Hz noise
        }
    }

    private func append(origin: Entry.Origin, isMainFrame: Bool, level: LogLevel, source: String, message: String) {
        nextID += 1
        entries.append(Entry(id: nextID, date: Date(), origin: origin, isMainFrame: isMainFrame,
                             level: level, source: source, message: message))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        let text = "[\(origin.rawValue)\(isMainFrame ? "" : "/sub")] \(source): \(message)"
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .warn: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
    }

    /// The log as JSON-ready dictionaries (for captures and Copy).
    func exportedEntries() -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { entry in
            [
                "time": formatter.string(from: entry.date),
                "origin": entry.origin.rawValue,
                "frame": entry.isMainFrame ? "main" : "sub",
                "level": entry.level.rawValue,
                "source": entry.source,
                "message": entry.message,
            ]
        }
    }

    func exportedText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return entries.map { entry in
            "\(formatter.string(from: entry.date)) \(entry.level.rawValue.uppercased()) [\(entry.origin.rawValue)\(entry.isMainFrame ? "" : "/sub")] \(entry.source): \(entry.message)"
        }.joined(separator: "\n")
    }
}
