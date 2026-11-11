// Bridge: JS → native messages (PLAN.md §5.3). Owner: P0 (frozen contract).
//
// Every message posted by `__ytadless.post` is `{v: 1, type, frame: 'main'|'sub', ...fields}`.
// `TestVectors/bridge/<type>.json` holds one sample per type; Swift decodes it and the Node
// tests check that what the scripts actually post has the same shape.

import Foundation

/// Which of the two long-lived webviews a script or message belongs to (D2).
public enum WebRole: String, Codable, CaseIterable, Sendable {
    case browse, player
}

public enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug, info, warn, error
}

public enum BridgeMessage: Equatable, Sendable {
    case ready(role: WebRole, url: String)
    case log(level: LogLevel, source: String, message: String)
    case scriptError(source: String, message: String, stack: String?)
    case route(url: String, trigger: NavigationTrigger)
    case pageChanged(url: String, title: String?)
    case filterHit(rule: String, count: Int)
    case videoMeta(VideoMeta)
    case playback(PlaybackSnapshot)
    case presentation(MediaPresentation)
    /// A well-formed message whose `type` this build doesn't know. Native code logs and ignores it.
    case unknown(type: String)

    /// The wire `type` string of this message.
    public var type: String {
        switch self {
        case .ready: "ready"
        case .log: "log"
        case .scriptError: "scriptError"
        case .route: "route"
        case .pageChanged: "pageChanged"
        case .filterHit: "filterHit"
        case .videoMeta: "videoMeta"
        case .playback: "playback"
        case .presentation: "presentation"
        case .unknown(let type): type
        }
    }

    /// The protocol version every message carries as `v`.
    public static let protocolVersion = 1

    /// Decodes a `WKScriptMessage.body` (an NSDictionary bridged to `Any`).
    ///
    /// Throws `BridgeDecodingError` for anything that isn't a version-1 message object with a
    /// `type` and `frame`, or whose fields don't match the type. An unrecognised `type` is not an
    /// error: it decodes to `.unknown(type:)`.
    public static func decode(_ body: Any) throws -> (message: BridgeMessage, isMainFrame: Bool) {
        try BridgeDecoder.decode(body)
    }
}

public enum BridgeDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The body isn't a JSON-compatible object (for example NaN, a function, or not a dictionary).
    case notAnObject
    case unsupportedVersion(Int?)
    case missingType
    case invalidFrame(String?)
    /// A known type with missing or mistyped fields. `detail` names the field.
    case invalidFields(type: String, detail: String)

    public var description: String {
        switch self {
        case .notAnObject: "bridge message is not a JSON object"
        case .unsupportedVersion(let v): "unsupported bridge version \(v.map(String.init) ?? "nil")"
        case .missingType: "bridge message has no type"
        case .invalidFrame(let f): "invalid frame \(f ?? "nil")"
        case .invalidFields(let type, let detail): "invalid \(type) message: \(detail)"
        }
    }
}
