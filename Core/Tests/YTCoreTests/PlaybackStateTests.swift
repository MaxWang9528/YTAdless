// PlaybackState reducer (PLAN.md §5.5). Owner: P0.

import Testing
@testable import YTCore

@Suite("Playback › reducer")
struct PlaybackStateTests {
    static let meta = VideoMeta(videoId: "dQw4w9WgXcQ", title: "T", author: "A", lengthSeconds: 213)
    static let other = VideoMeta(videoId: "jNQXAC9IVRw", title: "Zoo", author: "jawed", lengthSeconds: 19)

    @Test("starts idle, inline, without metadata")
    func initial() {
        let state = PlaybackState()
        #expect(state.meta == nil)
        #expect(state.snapshot == .idle)
        #expect(state.snapshot.rate == 1)
        #expect(state.presentation == .inline)
    }

    @Test("playback replaces the snapshot")
    func playback() {
        var state = PlaybackState()
        let snapshot = PlaybackSnapshot(status: .playing, position: 3, duration: 213, rate: 1.5, videoId: "dQw4w9WgXcQ")
        state.apply(.playback(snapshot))
        #expect(state.snapshot == snapshot)
    }

    @Test("videoMeta for the playing video keeps the snapshot")
    func metaSameVideo() {
        var state = PlaybackState()
        let snapshot = PlaybackSnapshot(status: .playing, position: 3, duration: 213, rate: 1, videoId: "dQw4w9WgXcQ")
        state.apply(.playback(snapshot))
        state.apply(.videoMeta(Self.meta))
        #expect(state.meta == Self.meta)
        #expect(state.snapshot == snapshot)
    }

    @Test("videoMeta for another video resets the snapshot to loading, keeping the rate")
    func metaNewVideo() {
        var state = PlaybackState()
        state.apply(.playback(PlaybackSnapshot(status: .playing, position: 99, duration: 213, rate: 2, videoId: "dQw4w9WgXcQ")))
        state.apply(.videoMeta(Self.other))
        #expect(state.meta == Self.other)
        #expect(state.snapshot == PlaybackSnapshot(status: .loading, position: 0, duration: 19, rate: 2, videoId: "jNQXAC9IVRw"))
    }

    @Test("videoMeta before any snapshot leaves the snapshot alone")
    func metaFirst() {
        var state = PlaybackState()
        state.apply(.videoMeta(Self.meta))
        #expect(state.meta == Self.meta)
        #expect(state.snapshot == .idle)
    }

    @Test("a snapshot for another video drops stale metadata; one without an id keeps it")
    func staleMeta() {
        var state = PlaybackState()
        state.apply(.videoMeta(Self.meta))
        state.apply(.playback(PlaybackSnapshot(status: .loading, videoId: nil)))
        #expect(state.meta == Self.meta)
        state.apply(.playback(PlaybackSnapshot(status: .loading, videoId: "jNQXAC9IVRw")))
        #expect(state.meta == nil)
    }

    @Test("presentation updates")
    func presentation() {
        var state = PlaybackState()
        state.apply(.presentation(.pip))
        #expect(state.presentation == .pip)
        state.apply(.presentation(.inline))
        #expect(state.presentation == .inline)
    }

    @Test("other messages are ignored", arguments: [
        BridgeMessage.ready(role: .player, url: "u"),
        .log(level: .info, source: "s", message: "m"),
        .scriptError(source: "s", message: "m", stack: nil),
        .route(url: "u", trigger: .click),
        .pageChanged(url: "u", title: nil),
        .filterHit(rule: "r", count: 1),
        .unknown(type: "x"),
    ])
    func ignored(_ message: BridgeMessage) {
        var state = PlaybackState(meta: Self.meta, snapshot: PlaybackSnapshot(status: .paused, position: 5), presentation: .fullscreen)
        let before = state
        state.apply(message)
        #expect(state == before)
    }
}
