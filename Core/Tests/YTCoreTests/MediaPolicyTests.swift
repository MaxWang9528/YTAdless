// Media policy helpers (PLAN.md §6.4). Owner: Module D.

import Testing
@testable import YTCore

@Suite("Playback › media policy")
struct MediaPolicyTests {
    @Test("lifecycle: willResignActive is pushed as inactive, the earliest point (D12)",
          arguments: [
              (MediaPolicy.AppEvent.willResignActive, AppLifecycle.inactive),
              (.didEnterBackground, .background),
              (.willEnterForeground, .inactive),
              (.didBecomeActive, .active),
          ])
    func lifecycle(event: MediaPolicy.AppEvent, expected: AppLifecycle) {
        #expect(MediaPolicy.lifecycle(for: event) == expected)
    }

    @Test("lifecycle commands encode as background.js expects")
    func lifecycleCommand() {
        #expect(JSCommand.lifecycle(MediaPolicy.lifecycle(for: .willResignActive)).argumentsJSON == #"{"state":"inactive"}"#)
    }

    @Test("interruption raw values mirror AVAudioSession.InterruptionType")
    func interruptionRawValues() {
        #expect(MediaPolicy.InterruptionType(rawValue: 1) == .began)
        #expect(MediaPolicy.InterruptionType(rawValue: 0) == .ended)
        #expect(MediaPolicy.InterruptionType(rawValue: 7) == nil)
    }

    @Test("interruption began → audioInterruption{began}; shouldResume is ignored on began")
    func interruptionBegan() {
        #expect(MediaPolicy.interruptionCommand(type: .began, shouldResume: true)
                == .audioInterruption(began: true, shouldResume: false))
    }

    @Test("interruption began for a suspended app is stale and ignored")
    func interruptionStale() {
        #expect(MediaPolicy.interruptionCommand(type: .began, shouldResume: false, wasSuspended: true) == nil)
    }

    @Test("interruption ended carries shouldResume through", arguments: [true, false])
    func interruptionEnded(shouldResume: Bool) {
        let command = MediaPolicy.interruptionCommand(type: .ended, shouldResume: shouldResume)
        #expect(command == .audioInterruption(began: false, shouldResume: shouldResume))
        #expect(command?.argumentsJSON == #"{"phase":"ended","shouldResume":\#(shouldResume)}"#)
    }

    @Test("route change: only oldDeviceUnavailable pauses, and only with a video loaded")
    func routeChange() {
        #expect(MediaPolicy.RouteChangeReason(rawValue: 2) == .oldDeviceUnavailable)
        #expect(MediaPolicy.routeChangeCommand(reason: .oldDeviceUnavailable, hasVideo: true) == .pause)
        #expect(MediaPolicy.routeChangeCommand(reason: .oldDeviceUnavailable, hasVideo: false) == nil)
        for reason in [MediaPolicy.RouteChangeReason.newDeviceAvailable, .categoryChange, .override, .unknown,
                       .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange] {
            #expect(MediaPolicy.routeChangeCommand(reason: reason, hasVideo: true) == nil, "\(reason)")
        }
        #expect(MediaPolicy.routeChangeCommand(reason: nil, hasVideo: true) == nil)
    }

    @Test("PiP restore: pip → inline while playing expands a docked or mini player")
    func pipRestore() {
        for player in [PlayerPresentation.docked, .mini(.topLeading), .mini(.bottomTrailing)] {
            for status in [PlaybackStatus.playing, .buffering, .loading] {
                #expect(MediaPolicy.presentationAfter(previous: .pip, current: .inline, status: status, player: player) == .expanded,
                        "\(player) \(status)")
            }
        }
    }

    @Test("PiP close (X pauses first) leaves the layout alone")
    func pipClose() {
        for status in [PlaybackStatus.paused, .ended, .idle] {
            #expect(MediaPolicy.presentationAfter(previous: .pip, current: .inline, status: status, player: .mini(.topTrailing)) == nil)
        }
    }

    @Test("other presentation changes never move the player")
    func otherTransitions() {
        let pairs: [(MediaPresentation, MediaPresentation)] = [
            (.inline, .pip), (.inline, .fullscreen), (.fullscreen, .inline), (.pip, .fullscreen), (.pip, .pip), (.inline, .inline),
        ]
        for (previous, current) in pairs {
            #expect(MediaPolicy.presentationAfter(previous: previous, current: current, status: .playing, player: .docked) == nil,
                    "\(previous) → \(current)")
        }
        #expect(MediaPolicy.presentationAfter(previous: .pip, current: .inline, status: .playing, player: .hidden) == nil)
        #expect(MediaPolicy.presentationAfter(previous: .pip, current: .inline, status: .playing, player: .expanded) == nil)
    }

    @Test("state reply decodes the bridge shapes, with null meta and null duration")
    func stateReplyDecode() throws {
        let json = #"{"meta":null,"playback":{"duration":null,"position":0,"rate":1,"status":"idle","videoId":null},"presentation":"inline"}"#
        let reply = try PlayerStateReply.decode(json)
        #expect(reply == PlayerStateReply(meta: nil, playback: .idle, presentation: .inline))
    }

    @Test("state reply applies through the reducer")
    func stateReplyApply() throws {
        let json = """
        {"meta":{"author":"Rick Astley","isLive":false,"lengthSeconds":213,"thumbnailURL":null,"title":"T","videoId":"dQw4w9WgXcQ"},\
        "playback":{"duration":213,"position":42,"rate":1,"status":"paused","videoId":"dQw4w9WgXcQ"},"presentation":"pip"}
        """
        var state = PlaybackState(snapshot: PlaybackSnapshot(status: .playing, position: 1, videoId: "dQw4w9WgXcQ"))
        try PlayerStateReply.decode(json).apply(to: &state)
        #expect(state.meta?.title == "T")
        #expect(state.snapshot == PlaybackSnapshot(status: .paused, position: 42, duration: 213, rate: 1, videoId: "dQw4w9WgXcQ"))
        #expect(state.presentation == .pip)
    }

    @Test("state reply with an error-shaped or malformed body throws")
    func stateReplyMalformed() {
        #expect(throws: (any Error).self) { try PlayerStateReply.decode(#"{"error":"no-bridge"}"#) }
        #expect(throws: (any Error).self) { try PlayerStateReply.decode("[]") }
    }
}
