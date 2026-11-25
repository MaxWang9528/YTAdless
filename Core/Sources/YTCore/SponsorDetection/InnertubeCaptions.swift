// InnertubeCaptions — owner: Module D (PLAN.md §6.5 on-device sponsor detection).
//
// Why this exists (verified 2026-11-25 with anonymous requests from WSL):
// - The caption tracks in the watch page's inline player response carry `exp=xpo,xwmhp,xpe`
//   (fixture js/fixtures/html/2026-11-24-watch-0e3GPea1Tyg.html). `xpe` means timedtext wants a
//   PO token (`pot=`): without one it answers HTTP 200 with an EMPTY body. D15 loads every video
//   as a full watch page, so on device every transcript came back empty.
// - The tracks from an anonymous `POST /youtubei/v1/player` (MWEB, with signatureTimestamp) have
//   no `exp` at all (fixtures js/fixtures/player/2026-11-24-player-*.json) and timedtext serves
//   the full json3 for them (dQw4w9WgXcQ: 8 kB, WWfjoGZmrTo: 316 kB). Without a
//   signatureTimestamp /player answers UNPLAYABLE "The page needs to be reloaded" and no captions.
// So native asks /player for fresh, token-free caption URLs when the page's need a token or come
// back empty. The client version and signatureTimestamp come from the page's ytcfg
// (`captionTracks` reply `client`), with `InnertubeClient.fallback` as a last resort.
// The request is anonymous (no cookies, no visitorData): the same request m.youtube.com makes.

import Foundation

/// The MWEB client values /player needs, from the page's `ytcfg`.
public struct InnertubeClient: Equatable, Sendable {
    /// `ytcfg.INNERTUBE_CLIENT_VERSION`, e.g. "2.20261123.09.00".
    public var clientVersion: String
    /// `ytcfg.STS`: the player script's signatureTimestamp, e.g. 20779.
    public var signatureTimestamp: Int

    public init(clientVersion: String, signatureTimestamp: Int) {
        self.clientVersion = clientVersion
        self.signatureTimestamp = signatureTimestamp
    }

    /// From the watch fixture's ytcfg (2026-11-24). Used only when the page sent none; YouTube
    /// may reject it once the player script moves on (then /player says UNPLAYABLE).
    public static let fallback = InnertubeClient(clientVersion: "2.20261123.09.00", signatureTimestamp: 20779)

    /// A version like "2.20261123.09.00": digits and dots, 1–40 chars.
    static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 40 && version.allSatisfy { $0 == "." || ("0"..."9").contains($0) }
    }
}

extension Captions {
    // MARK: PO-token detection

    /// Whether timedtext will want a PO token for this URL: its `exp` parameter lists `xpe`
    /// (watch-page tracks: `exp=xpo,xwmhp,xpe`). Such URLs answer 200 with an empty body.
    public static func requiresPoToken(baseUrl: String) -> Bool {
        // Split by hand: the signed query is compared, not decoded or re-encoded.
        guard let query = baseUrl.split(separator: "?", maxSplits: 1).dropFirst().first else { return false }
        let fragmentless = query.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return fragmentless.split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "exp" else { return false }
            let value = parts[1].replacingOccurrences(of: "%2C", with: ",").replacingOccurrences(of: "%2c", with: ",")
            return value.split(separator: ",").contains("xpe")
        }
    }

    // MARK: /youtubei/v1/player

    public static let playerEndpoint = URL(string: "https://m.youtube.com/youtubei/v1/player?prettyPrint=false")!
    /// Relative timedtext URLs in a /player response are resolved against this origin.
    static let captionOrigin = URL(string: "https://m.youtube.com")!

    /// The pieces of an anonymous MWEB /player request (URLRequest is in FoundationNetworking on
    /// Linux, so the app builds the request). nil for a malformed videoId or client version.
    public struct PlayerRequest: Equatable, Sendable {
        public var url: URL
        public var headers: [String: String]
        public var body: Data
    }

    public static func playerRequest(videoId: String, client: InnertubeClient) -> PlayerRequest? {
        guard isVideoId(videoId), InnertubeClient.isValidVersion(client.clientVersion),
              client.signatureTimestamp > 0 else { return nil }
        let object: [String: Any] = [
            "context": ["client": ["clientName": "MWEB", "clientVersion": client.clientVersion, "hl": "en", "gl": "US"]],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": client.signatureTimestamp]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return PlayerRequest(
            url: playerEndpoint,
            headers: [
                "Content-Type": "application/json",
                "X-YouTube-Client-Name": "2",  // MWEB
                "X-YouTube-Client-Version": client.clientVersion,
            ],
            body: body)
    }

    public enum PlayerResponseError: Error, Equatable, Sendable, CustomStringConvertible {
        case malformed
        /// `playabilityStatus.status` wasn't OK (with its reason, when there is one).
        case unplayable(status: String, reason: String?)
        /// The response is for another video.
        case otherVideo(String)

        public var description: String {
            switch self {
            case .malformed: "malformed /player response"
            case let .unplayable(status, reason): "/player says \(status)" + (reason.map { ": \($0)" } ?? "")
            case let .otherVideo(id): "/player answered for \(id)"
            }
        }
    }

    /// Caption tracks from a /player response body, with absolute timedtext URLs. Tracks whose URL
    /// isn't an https youtube.com `/api/timedtext` URL are dropped (as in sponsorblock.js).
    public static func captionTracks(fromPlayerResponse data: Data, videoId: String) throws -> [CaptionTrack] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayerResponseError.malformed
        }
        let playability = object["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "missing"
        guard status == "OK" else {
            throw PlayerResponseError.unplayable(status: status, reason: playability?["reason"] as? String)
        }
        if let answered = (object["videoDetails"] as? [String: Any])?["videoId"] as? String, answered != videoId {
            throw PlayerResponseError.otherVideo(answered)
        }
        let renderer = (object["captions"] as? [String: Any])?["playerCaptionsTracklistRenderer"] as? [String: Any]
        let raw = renderer?["captionTracks"] as? [Any] ?? []
        return raw.compactMap { item -> CaptionTrack? in
            guard let t = item as? [String: Any], let relative = t["baseUrl"] as? String,
                  let languageCode = t["languageCode"] as? String,
                  let absolute = URL(string: relative, relativeTo: captionOrigin)?.absoluteURL.absoluteString,
                  json3URL(baseUrl: absolute) != nil
            else { return nil }
            return CaptionTrack(baseUrl: absolute, languageCode: languageCode,
                                kind: t["kind"] as? String == "asr" ? "asr" : "", name: plainText(t["name"]))
        }
    }

    /// `{simpleText}` or `{runs: [{text}]}` → text.
    static func plainText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let o = value as? [String: Any] else { return "" }
        if let s = o["simpleText"] as? String { return s }
        let runs = o["runs"] as? [Any] ?? []
        return runs.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { s in
            s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_")
        }
    }
}
