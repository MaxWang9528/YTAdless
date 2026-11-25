// Transcript fallback through /youtubei/v1/player (PLAN.md §6.5). Owner: Module D.
// Fixtures: js/fixtures/html/2026-11-24-watch-0e3GPea1Tyg.html (watch-page tracks carry
// `exp=xpo,xwmhp,xpe`, which made timedtext answer 200 with 0 bytes on 2026-11-25) and
// js/fixtures/player/2026-11-24-player-dQw4w9WgXcQ.json (an anonymous MWEB /player response whose
// tracks have no `exp` and served json3).

import Foundation
import Testing
@testable import YTCore

@Suite("SponsorDetection › /player captions")
struct InnertubeCaptionsTests {
    static let playerFixture = "js/fixtures/player/2026-11-24-player-dQw4w9WgXcQ.json"
    static let watchFixture = "js/fixtures/html/2026-11-24-watch-0e3GPea1Tyg.html"

    /// Every timedtext baseUrl in a file, JSON-unescaped.
    static func baseUrls(in relativePath: String) throws -> [String] {
        let text = try #require(String(data: try Repo.data(relativePath), encoding: .utf8))
        var urls: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: #""baseUrl":"/api/timedtext"#) {
            let from = rest.index(start.lowerBound, offsetBy: #""baseUrl":""#.count)
            guard let end = rest[from...].firstIndex(of: "\"") else { break }
            urls.append(String(rest[from..<end]).replacingOccurrences(of: "\\" + "u0026", with: "&"))  // JSON-escaped `&` in the inline HTML
            rest = rest[end...]
        }
        return urls
    }

    @Test("PO token: watch-page tracks (exp=…,xpe) need one; /player tracks don't")
    func poTokenDetection() throws {
        let page = try Self.baseUrls(in: Self.watchFixture)
        #expect(!page.isEmpty)
        for url in page { #expect(Captions.requiresPoToken(baseUrl: "https://m.youtube.com" + url), "\(url)") }
        let api = try Self.baseUrls(in: Self.playerFixture)
        #expect(!api.isEmpty)
        for url in api { #expect(!Captions.requiresPoToken(baseUrl: "https://m.youtube.com" + url), "\(url)") }
        #expect(Captions.requiresPoToken(baseUrl: "https://m.youtube.com/api/timedtext?v=x&exp=xpe"))
        #expect(!Captions.requiresPoToken(baseUrl: "https://m.youtube.com/api/timedtext?v=x&exp=xpo,xpex"))
        #expect(!Captions.requiresPoToken(baseUrl: "https://m.youtube.com/api/timedtext?v=x&xpe=1"))
        #expect(!Captions.requiresPoToken(baseUrl: "not a url"))
    }

    @Test("/player request: anonymous MWEB body with the page's client version and signatureTimestamp")
    func playerRequest() throws {
        let client = InnertubeClient(clientVersion: "2.20261123.09.00", signatureTimestamp: 20779)
        let request = try #require(Captions.playerRequest(videoId: "dQw4w9WgXcQ", client: client))
        #expect(request.url.absoluteString == "https://m.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.headers["X-YouTube-Client-Name"] == "2")
        #expect(request.headers["X-YouTube-Client-Version"] == "2.20261123.09.00")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["videoId"] as? String == "dQw4w9WgXcQ")
        let c = try #require((body["context"] as? [String: Any])?["client"] as? [String: Any])
        #expect(c["clientName"] as? String == "MWEB")
        #expect(c["clientVersion"] as? String == "2.20261123.09.00")
        #expect(c["visitorData"] == nil, "anonymous: no visitor id")
        let playback = (body["playbackContext"] as? [String: Any])?["contentPlaybackContext"] as? [String: Any]
        #expect(playback?["signatureTimestamp"] as? Int == 20779)

        #expect(Captions.playerRequest(videoId: "short", client: client) == nil)
        #expect(Captions.playerRequest(videoId: "dQw4w9WgXc\"", client: client) == nil)
        #expect(Captions.playerRequest(videoId: "dQw4w9WgXcQ", client: .init(clientVersion: "2.x\"", signatureTimestamp: 1)) == nil)
        #expect(Captions.playerRequest(videoId: "dQw4w9WgXcQ", client: .init(clientVersion: "2.1", signatureTimestamp: 0)) == nil)
        #expect(Captions.playerRequest(videoId: "dQw4w9WgXcQ", client: .fallback) != nil)
    }

    @Test("/player response: fixture tracks become absolute, token-free json3-able URLs")
    func playerResponseFixture() throws {
        let tracks = try Captions.captionTracks(fromPlayerResponse: try Repo.data(Self.playerFixture), videoId: "dQw4w9WgXcQ")
        #expect(tracks.count == (try Self.baseUrls(in: Self.playerFixture)).count)
        #expect(Array(tracks.prefix(2).map { [$0.languageCode, $0.kind, $0.name] })
            == [["en", "", "English"], ["en", "asr", "English (auto-generated)"]])
        for track in tracks {
            #expect(track.baseUrl.hasPrefix("https://m.youtube.com/api/timedtext?"))
            #expect(Captions.json3URL(baseUrl: track.baseUrl) != nil)
            #expect(!Captions.requiresPoToken(baseUrl: track.baseUrl))
        }
        guard case .track(let chosen) = Captions.chooseTrack(tracks) else {
            Issue.record("no English track chosen")
            return
        }
        #expect(chosen.languageCode == "en" && !chosen.isAutoGenerated)
    }

    @Test("/player response: unplayable, another video, malformed, foreign URLs")
    func playerResponseErrors() throws {
        func data(_ s: String) -> Data { Data(s.utf8) }
        #expect(throws: Captions.PlayerResponseError.unplayable(status: "UNPLAYABLE", reason: "The page needs to be reloaded.")) {
            try Captions.captionTracks(fromPlayerResponse: data(
                #"{"playabilityStatus":{"status":"UNPLAYABLE","reason":"The page needs to be reloaded."}}"#), videoId: "dQw4w9WgXcQ")
        }
        #expect(throws: Captions.PlayerResponseError.unplayable(status: "missing", reason: nil)) {
            try Captions.captionTracks(fromPlayerResponse: data("{}"), videoId: "dQw4w9WgXcQ")
        }
        #expect(throws: Captions.PlayerResponseError.otherVideo("jNQXAC9IVRw")) {
            try Captions.captionTracks(fromPlayerResponse: data(
                #"{"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"jNQXAC9IVRw"}}"#), videoId: "dQw4w9WgXcQ")
        }
        #expect(throws: Captions.PlayerResponseError.malformed) {
            try Captions.captionTracks(fromPlayerResponse: data("[]"), videoId: "dQw4w9WgXcQ")
        }
        let mixed = #"""
            {"playabilityStatus":{"status":"OK"},"videoDetails":{"videoId":"dQw4w9WgXcQ"},
             "captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
               {"baseUrl":"https://evil.example/api/timedtext?v=x","languageCode":"en"},
               {"baseUrl":"/watch?v=x","languageCode":"en"},
               {"baseUrl":"/api/timedtext?v=x&lang=en","languageCode":"en","kind":"asr","name":{"simpleText":"English"}}
             ]}}}
            """#
        #expect(try Captions.captionTracks(fromPlayerResponse: data(mixed), videoId: "dQw4w9WgXcQ")
            == [Captions.CaptionTrack(baseUrl: "https://m.youtube.com/api/timedtext?v=x&lang=en", languageCode: "en", kind: "asr", name: "English")])
        // No captions at all: an empty list, not an error.
        #expect(try Captions.captionTracks(fromPlayerResponse: data(#"{"playabilityStatus":{"status":"OK"}}"#), videoId: "dQw4w9WgXcQ").isEmpty)
    }

    @Test("captionTracks reply: optional client decoded; missing or malformed reads as nil")
    func replyClient() throws {
        let ok = try Captions.captionTracks(fromJSON:
            #"{"videoId":"dQw4w9WgXcQ","tracks":[],"client":{"clientVersion":"2.20261123.09.00","signatureTimestamp":20779}}"#)
        #expect(ok.client == InnertubeClient(clientVersion: "2.20261123.09.00", signatureTimestamp: 20779))
        for json in [#"{"videoId":"x","tracks":[]}"#, #"{"tracks":[],"client":null}"#,
                     #"{"tracks":[],"client":{"clientVersion":"2.1"}}"#,
                     #"{"tracks":[],"client":{"clientVersion":"bad version","signatureTimestamp":1}}"#,
                     #"{"tracks":[],"client":{"clientVersion":"2.1","signatureTimestamp":"20779"}}"#] {
            #expect(try Captions.captionTracks(fromJSON: json).client == nil, "\(json)")
        }
    }
}
