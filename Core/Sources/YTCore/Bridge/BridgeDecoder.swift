// Bridge decoding (PLAN.md §5.3). Owner: P0 (frozen).
//
// The body is re-serialised with JSONSerialization and decoded with JSONDecoder, so every
// payload is checked by Codable. `isValidJSONObject` runs first: on Darwin,
// `JSONSerialization.data` raises an Objective-C exception (a crash) for NaN or non-JSON values.

import Foundation

enum BridgeDecoder {
    private struct Envelope: Decodable {
        let v: Int?
        let type: String?
        let frame: String?
    }

    private struct Ready: Decodable { let role: WebRole; let url: String }
    private struct Log: Decodable { let level: LogLevel; let source: String; let message: String }
    private struct ScriptError: Decodable { let source: String; let message: String; let stack: String? }
    private struct Route: Decodable { let url: String; let trigger: NavigationTrigger }
    private struct PageChanged: Decodable { let url: String; let title: String? }
    private struct FilterHit: Decodable { let rule: String; let count: Int }
    private struct Presentation: Decodable { let mode: MediaPresentation }
    private struct SelectTab: Decodable { let tab: BrowseTab }

    static func decode(_ body: Any) throws -> (message: BridgeMessage, isMainFrame: Bool) {
        guard body is [String: Any] || body is NSDictionary,
              JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { throw BridgeDecodingError.notAnObject }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            throw BridgeDecodingError.notAnObject
        }
        guard envelope.v == BridgeMessage.protocolVersion else {
            throw BridgeDecodingError.unsupportedVersion(envelope.v)
        }
        guard let type = envelope.type, !type.isEmpty else { throw BridgeDecodingError.missingType }
        let isMainFrame: Bool
        switch envelope.frame {
        case "main": isMainFrame = true
        case "sub": isMainFrame = false
        default: throw BridgeDecodingError.invalidFrame(envelope.frame)
        }

        func payload<T: Decodable>(_: T.Type) throws -> T {
            do {
                return try decoder.decode(T.self, from: data)
            } catch let error as DecodingError {
                throw BridgeDecodingError.invalidFields(type: type, detail: describe(error))
            }
        }

        let message: BridgeMessage
        switch type {
        case "ready":
            let p = try payload(Ready.self)
            message = .ready(role: p.role, url: p.url)
        case "log":
            let p = try payload(Log.self)
            message = .log(level: p.level, source: p.source, message: p.message)
        case "scriptError":
            let p = try payload(ScriptError.self)
            message = .scriptError(source: p.source, message: p.message, stack: p.stack)
        case "route":
            let p = try payload(Route.self)
            message = .route(url: p.url, trigger: p.trigger)
        case "pageChanged":
            let p = try payload(PageChanged.self)
            message = .pageChanged(url: p.url, title: p.title)
        case "filterHit":
            let p = try payload(FilterHit.self)
            message = .filterHit(rule: p.rule, count: p.count)
        case "videoMeta":
            message = .videoMeta(try payload(VideoMeta.self))
        case "playback":
            message = .playback(try payload(PlaybackSnapshot.self))
        case "presentation":
            message = .presentation(try payload(Presentation.self).mode)
        case "selectTab":
            message = .selectTab(try payload(SelectTab.self).tab)
        default:
            message = .unknown(type: type)
        }
        return (message, isMainFrame)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .valueNotFound(_, let context): return "null \(path(context))"
        case .typeMismatch(_, let context): return "wrong type for \(path(context))"
        case .dataCorrupted(let context): return "bad value for \(path(context))"
        @unknown default: return "undecodable"
        }
    }
}
