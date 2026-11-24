// CaptureWriter — owner: Module B (PLAN.md §6.2 Debug tooling; CLAUDE.md maintenance loop).
//
// Debug › Capture: sends `capture` (debug.js) to both webviews and writes one timestamped folder
// to Documents, which Files › YTadless and the Windows Apple Devices app show (UIFileSharingEnabled):
//
//   Documents/captures/<YYYY-MM-DD-HHmmss>/
//     <role>.html             the DOM at capture time
//     <role>-originals.json   Module A's pre-prune responses (hooks.originals), for js/fixtures/local/
//     <role>-page.json        url, title, debug.js counters and log lines (or the error)
//     native-log.json         the Debug log
//     info.json               build, time, player request and state, filterHit totals, content rules
//
// Captures made while signed in hold account data: they belong in js/fixtures/local/ only.

import Foundation
import YTCore

@MainActor
enum CaptureWriter {
    struct Result {
        let folder: URL
        let notes: [String]
    }

    static func capture(store: WebViewStore, session: PlayerSession, log: DebugLog) async throws -> Result {
        let now = Date()
        let folder = try folderURL(for: now)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var notes: [String] = []
        var roles: [String: Any] = [:]
        for role in WebRole.allCases {
            do {
                guard let json = try await store.send(.capture, to: role),
                      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                else {
                    throw CaptureError.emptyResult
                }
                let html = object["html"] as? String ?? ""
                try Data(html.utf8).write(to: folder.appendingPathComponent("\(role.rawValue).html"), options: .atomic)
                try writeJSON(object["originals"] ?? [], to: folder.appendingPathComponent("\(role.rawValue)-originals.json"))
                var page = object
                page.removeValue(forKey: "html")
                page.removeValue(forKey: "originals")
                try writeJSON(page, to: folder.appendingPathComponent("\(role.rawValue)-page.json"))
                let count = (object["originals"] as? [Any])?.count ?? 0
                notes.append("\(role.rawValue): \(html.utf8.count / 1024) KB DOM, \(count) originals")
                roles[role.rawValue] = ["url": object["url"] ?? NSNull(), "ok": true]
            } catch {
                notes.append("\(role.rawValue): \(error)")
                roles[role.rawValue] = ["ok": false, "error": String(describing: error)]
                try writeJSON(["error": String(describing: error)], to: folder.appendingPathComponent("\(role.rawValue)-page.json"))
            }
        }

        try writeJSON(log.exportedEntries(), to: folder.appendingPathComponent("native-log.json"))
        let formatter = ISO8601DateFormatter()
        var info: [String: Any] = [
            "time": formatter.string(from: now),
            "build": WebViewStore.buildString,
            "userAgentApplicationName": SafariUserAgent.applicationName,
            "contentRules": log.contentRulesStatus,
            "filterHits": log.filterHits,
            "scriptErrors": log.scriptErrorCount,
            "presentation": String(describing: session.presentation),
            "roles": roles,
        ]
        if let request = session.request {
            info["request"] = ["id": request.id, "kind": request.kind.rawValue, "watchURL": request.watchURL.absoluteString]
        }
        if let meta = session.playback.meta {
            info["meta"] = ["videoId": meta.videoId, "title": meta.title, "author": meta.author]
        }
        info["playback"] = [
            "status": session.playback.snapshot.status.rawValue,
            "position": session.playback.snapshot.position,
            "presentation": session.playback.presentation.rawValue,
        ]
        try writeJSON(info, to: folder.appendingPathComponent("info.json"))
        log.native(.info, "Capture", "wrote captures/\(folder.lastPathComponent): \(notes.joined(separator: "; "))")
        return Result(folder: folder, notes: notes)
    }

    private enum CaptureError: Error, CustomStringConvertible {
        case emptyResult, noDocuments
        var description: String {
            switch self {
            case .emptyResult: "capture returned nothing"
            case .noDocuments: "no Documents directory"
            }
        }
    }

    private static func folderURL(for date: Date) throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CaptureError.noDocuments
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return documents.appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        let safe = JSONSerialization.isValidJSONObject(value) ? value : ["unserializable": String(describing: value)]
        let data = try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
