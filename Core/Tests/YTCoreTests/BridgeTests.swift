// Bridge decoding and command encoding (PLAN.md §5.3, §5.4) against TestVectors. Owner: P0.

import Foundation
import Testing
@testable import YTCore

@Suite("Bridge › decode")
struct BridgeDecodeTests {
    /// What each TestVectors/bridge/<name>.json decodes to: (body, isMainFrame, minimal).
    static let expected: [String: (body: BridgeMessage, isMainFrame: Bool, minimal: BridgeMessage?)] = [
        "ready": (.ready(role: .player, url: "https://m.youtube.com/watch?v=dQw4w9WgXcQ"), true, nil),
        "log": (.log(level: .warn, source: "debug.js", message: "console.warn: something odd"), false, nil),
        "scriptError": (
            .scriptError(source: "hooks.js", message: "TypeError: x is not a function", stack: "addPruner@ytadless/hooks.js:12:3"),
            true,
            .scriptError(source: "hooks.js", message: "boom", stack: nil)
        ),
        "route": (.route(url: "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", trigger: .click), true, nil),
        "pageChanged": (
            .pageChanged(url: "https://m.youtube.com/feed/subscriptions", title: "Subscriptions - YouTube"),
            true,
            .pageChanged(url: "https://m.youtube.com/", title: nil)
        ),
        "filterHit": (.filterHit(rule: "playerResponse.adPlacements", count: 3), true, nil),
        "videoMeta": (
            .videoMeta(VideoMeta(videoId: "dQw4w9WgXcQ", title: "Rick Astley - Never Gonna Give You Up (Official Video)",
                                 author: "Rick Astley", lengthSeconds: 213,
                                 thumbnailURL: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", isLive: false)),
            true,
            .videoMeta(VideoMeta(videoId: "dQw4w9WgXcQ", title: "Never Gonna Give You Up", author: "", isLive: true))
        ),
        "playback": (
            .playback(PlaybackSnapshot(status: .playing, position: 12.5, duration: 213.1, rate: 1, videoId: "dQw4w9WgXcQ")),
            true,
            .playback(PlaybackSnapshot(status: .loading, position: 0, duration: nil, rate: 1, videoId: nil))
        ),
        "presentation": (.presentation(.pip), true, nil),
        "selectTab": (.selectTab(.subscriptions), true, nil),
        "unknown": (.unknown(type: "futureThing"), true, nil),
    ]

    static let knownTypes = ["ready", "log", "scriptError", "route", "pageChanged", "filterHit",
                             "videoMeta", "playback", "presentation", "selectTab"]

    @Test("every vector file has an expectation, and every message type has a vector")
    func vectorFilesMatchExpectations() throws {
        let files = try Repo.files(in: "TestVectors/bridge", withExtension: "json").map { String($0.dropLast(5)) }
        #expect(Set(files) == Set(Self.expected.keys))
        #expect(Set(Self.knownTypes).isSubset(of: Set(files)))
    }

    @Test("vector decodes", arguments: expected.keys.sorted())
    func decodesVector(_ name: String) throws {
        let vector = try Repo.jsonObject("TestVectors/bridge/\(name).json")
        let expectation = try #require(Self.expected[name])
        let body = try #require(vector["body"])
        let decoded = try BridgeMessage.decode(body)
        #expect(decoded.message == expectation.body)
        #expect(decoded.isMainFrame == expectation.isMainFrame)
        #expect(decoded.message.type == (vector["type"] as? String))

        if let minimal = vector["minimal"] {
            let decodedMinimal = try BridgeMessage.decode(minimal)
            #expect(decodedMinimal.message == expectation.minimal)
        } else {
            #expect(expectation.minimal == nil)
        }
    }

    @Test("an NSDictionary body (what WKScriptMessage delivers) decodes")
    func decodesNSDictionary() throws {
        let body = NSDictionary(dictionary: ["v": 1, "type": "presentation", "frame": "sub", "mode": "fullscreen"])
        let decoded = try BridgeMessage.decode(body)
        #expect(decoded.message == .presentation(.fullscreen))
        #expect(decoded.isMainFrame == false)
    }

    @Test("non-objects are rejected")
    func rejectsNonObjects() {
        #expect(throws: BridgeDecodingError.notAnObject) { try BridgeMessage.decode("ready") }
        #expect(throws: BridgeDecodingError.notAnObject) { try BridgeMessage.decode([1, 2, 3]) }
        #expect(throws: BridgeDecodingError.notAnObject) { try BridgeMessage.decode(42) }
    }

    @Test("NaN is rejected instead of crashing JSONSerialization")
    func rejectsNaN() {
        let body: [String: Any] = ["v": 1, "type": "playback", "frame": "main", "status": "playing",
                                   "position": Double.nan, "rate": 1]
        #expect(throws: BridgeDecodingError.notAnObject) { try BridgeMessage.decode(body) }
    }

    @Test("envelope errors: version, type, frame")
    func rejectsBadEnvelopes() {
        #expect(throws: BridgeDecodingError.unsupportedVersion(nil)) {
            try BridgeMessage.decode(["type": "ready", "frame": "main", "role": "browse", "url": "x"])
        }
        #expect(throws: BridgeDecodingError.unsupportedVersion(2)) {
            try BridgeMessage.decode(["v": 2, "type": "ready", "frame": "main", "role": "browse", "url": "x"])
        }
        #expect(throws: BridgeDecodingError.missingType) {
            try BridgeMessage.decode(["v": 1, "frame": "main"])
        }
        #expect(throws: BridgeDecodingError.missingType) {
            try BridgeMessage.decode(["v": 1, "type": "", "frame": "main"])
        }
        #expect(throws: BridgeDecodingError.invalidFrame(nil)) {
            try BridgeMessage.decode(["v": 1, "type": "ready", "role": "browse", "url": "x"])
        }
        #expect(throws: BridgeDecodingError.invalidFrame("top")) {
            try BridgeMessage.decode(["v": 1, "type": "ready", "frame": "top", "role": "browse", "url": "x"])
        }
    }

    @Test("field errors name the type", arguments: [
        ["v": 1, "type": "log", "frame": "main", "level": "fatal", "source": "x", "message": "m"],
        ["v": 1, "type": "log", "frame": "main", "level": "info", "source": "x"],
        ["v": 1, "type": "videoMeta", "frame": "main", "videoId": "a", "title": "t", "author": "", "lengthSeconds": "213", "isLive": false],
        ["v": 1, "type": "videoMeta", "frame": "main", "videoId": "a", "title": "t", "author": "", "isLive": 1],
        ["v": 1, "type": "filterHit", "frame": "main", "rule": "r", "count": 1.5],
        ["v": 1, "type": "playback", "frame": "main", "status": "stopped", "position": 0, "rate": 1],
        ["v": 1, "type": "route", "frame": "main", "url": "u", "trigger": "tap"],
        ["v": 1, "type": "ready", "frame": "main", "role": "both", "url": "u"],
    ] as [[String: any Sendable]])
    func rejectsBadFields(_ body: [String: any Sendable]) {
        let type = body["type"] as? String ?? ""
        do {
            _ = try BridgeMessage.decode(body as [String: Any])
            Issue.record("expected \(type) to be rejected")
        } catch let BridgeDecodingError.invalidFields(errorType, detail) {
            #expect(errorType == type)
            #expect(!detail.isEmpty)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("message type strings round-trip")
    func typeStrings() {
        for (name, expectation) in Self.expected where name != "unknown" {
            #expect(expectation.body.type == name)
        }
    }
}

@Suite("Bridge › commands")
struct JSCommandTests {
    /// In the order of TestVectors/commands.json.
    static let commands: [JSCommand] = [
        .play, .pause, .seek(to: 42.5), .seekBy(-10), .pip(enter: true), .state,
        .lifecycle(.background), .audioInterruption(began: false, shouldResume: true), .layout(.video), .capture,
        .sponsorSegments(videoId: "dQw4w9WgXcQ", segments: [SkipSegment(start: 10, end: 30.5, category: "sponsor")]),
        .captionTracks,
        .suggestedSegments(videoId: "dQw4w9WgXcQ", segments: [SkipSegment(start: 61, end: 95, category: "sponsor")]),
    ]

    @Test("names and arguments match TestVectors/commands.json")
    func matchesVectors() throws {
        let file = try Repo.jsonObject("TestVectors/commands.json")
        let vectors = try #require(file["commands"] as? [[String: Any]])
        try #require(vectors.count == Self.commands.count)
        for (command, vector) in zip(Self.commands, vectors) {
            #expect(command.name == vector["name"] as? String)
            let args = try JSONSerialization.jsonObject(with: Data(command.argumentsJSON.utf8))
            #expect(try canonicalJSON(args) == canonicalJSON(try #require(vector["args"])), "\(command.name)")
        }
        let names = Set(vectors.compactMap { $0["name"] as? String })
        #expect(names.count == vectors.count, "command names are unique")
    }

    @Test("arguments are a sorted-key JSON object")
    func argumentsJSONIsSorted() {
        #expect(JSCommand.audioInterruption(began: true, shouldResume: false).argumentsJSON
                == #"{"phase":"began","shouldResume":false}"#)
        #expect(JSCommand.play.argumentsJSON == "{}")
        #expect(JSCommand.lifecycle(.inactive).argumentsJSON == #"{"state":"inactive"}"#)
    }

    @Test("non-finite numbers become 0")
    func nonFinite() {
        #expect(JSCommand.seek(to: .nan).argumentsJSON == #"{"to":0}"#)
        #expect(JSCommand.seekBy(.infinity).argumentsJSON == #"{"delta":0}"#)
        #expect(JSCommand.sponsorSegments(videoId: "x", segments: [SkipSegment(start: .nan, end: .infinity, category: "intro")])
            .argumentsJSON == #"{"autoSkip":true,"segments":[{"category":"intro","end":0,"start":0}],"videoId":"x"}"#)
    }

    @Test("sponsorSegments: nested sorted keys; empty list")
    func sponsorSegments() {
        #expect(JSCommand.sponsorSegments(videoId: "dQw4w9WgXcQ", segments: []).argumentsJSON
                == #"{"autoSkip":true,"segments":[],"videoId":"dQw4w9WgXcQ"}"#)
        #expect(JSCommand.sponsorSegments(videoId: "a", segments: [SkipSegment(start: 1, end: 2.5, category: "sponsor")])
            .argumentsJSON == #"{"autoSkip":true,"segments":[{"category":"sponsor","end":2.5,"start":1}],"videoId":"a"}"#)
    }

    @Test("autoSkip: defaults (sponsor true, suggested false) and explicit values")
    func autoSkip() {
        #expect(JSCommand.sponsorSegments(videoId: "a", segments: [], autoSkip: false).argumentsJSON
                == #"{"autoSkip":false,"segments":[],"videoId":"a"}"#)
        #expect(JSCommand.suggestedSegments(videoId: "a", segments: []).argumentsJSON
                == #"{"autoSkip":false,"segments":[],"videoId":"a"}"#)
        #expect(JSCommand.suggestedSegments(videoId: "a", segments: [], autoSkip: true).argumentsJSON
                == #"{"autoSkip":true,"segments":[],"videoId":"a"}"#)
        #expect(JSCommand.sponsorSegments(videoId: "a", segments: [], autoSkip: false)
                != JSCommand.sponsorSegments(videoId: "a", segments: []))
    }

    @Test("the function body only references the named arguments")
    func functionBody() {
        #expect(JSCommand.functionBody
                == "return window.__ytadless ? window.__ytadless.cmd(name, args) : {error: 'no-bridge'}")
    }
}

@Suite("Bridge › command results")
struct JSCommandResultTests {
    @Test("nothing → nil")
    func empty() throws {
        #expect(try JSCommandResult.json(from: nil) == nil)
        #expect(try JSCommandResult.json(from: NSNull()) == nil)
    }

    @Test("{error} → rejected")
    func error() {
        #expect(throws: JSCommandError.rejected("no-bridge")) {
            try JSCommandResult.json(from: ["error": "no-bridge"])
        }
        #expect(throws: JSCommandError.rejected("no-video")) {
            try JSCommandResult.json(from: NSDictionary(dictionary: ["error": "no-video"]))
        }
    }

    @Test("values → sorted JSON")
    func values() throws {
        #expect(try JSCommandResult.json(from: ["ok": true, "position": 12]) == #"{"ok":true,"position":12}"#)
        #expect(try JSCommandResult.json(from: "text") == #""text""#)
        #expect(try JSCommandResult.json(from: 42) == "42")
        let state: [String: Any] = ["meta": NSNull(), "presentation": "inline",
                                    "playback": ["status": "idle", "position": 0, "rate": 1]]
        let json = try #require(try JSCommandResult.json(from: state))
        #expect(json.hasPrefix(#"{"meta":null,"playback":{"#))
    }

    @Test("non-JSON values → invalidResult")
    func invalid() {
        #expect(throws: JSCommandError.invalidResult) { try JSCommandResult.json(from: Double.nan) }
        #expect(throws: JSCommandError.invalidResult) { try JSCommandResult.json(from: ["d": Date()]) }
    }
}
