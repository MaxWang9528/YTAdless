// Media policy helpers (PLAN.md §6.4). Owner: Module D.
//
// The pure decisions behind MediaCoordinator (Sources/YTadless/Media): which JSCommand an audio
// interruption, a route change or an app-lifecycle notification turns into, and when a PiP restore
// expands the player. No AVFoundation or UIKit here (D3): the app target maps the system values
// onto these mirrors, so every branch is tested on Linux.

import Foundation

public enum MediaPolicy {
    // MARK: Lifecycle (D12)

    /// The UIApplication notifications MediaCoordinator observes, in the order iOS sends them.
    public enum AppEvent: String, CaseIterable, Sendable {
        case willResignActive, didEnterBackground, willEnterForeground, didBecomeActive
    }

    /// `willResignActive` is the earliest signal, and is pushed as `inactive` so background.js
    /// knows before WebKit pauses the video. Coming back, the app is `inactive` until it is active.
    public static func lifecycle(for event: AppEvent) -> AppLifecycle {
        switch event {
        case .willResignActive, .willEnterForeground: return .inactive
        case .didEnterBackground: return .background
        case .didBecomeActive: return .active
        }
    }

    // MARK: Audio interruptions

    /// Mirrors `AVAudioSession.InterruptionType` (raw values match).
    public enum InterruptionType: UInt, Sendable { case ended = 0, began = 1 }

    /// The `audioInterruption` command for an interruption notification, or nil to ignore it.
    ///
    /// - `shouldResume` is `AVAudioSession.InterruptionOptions.shouldResume` (only meaningful on `ended`).
    /// - `wasSuspended` is `InterruptionReason.appWasSuspended`: iOS delivers a stale `began` when a
    ///   suspended app wakes up. Nothing actually stopped playback just now, so it is ignored.
    public static func interruptionCommand(type: InterruptionType, shouldResume: Bool,
                                           wasSuspended: Bool = false) -> JSCommand? {
        switch type {
        case .began:
            return wasSuspended ? nil : .audioInterruption(began: true, shouldResume: false)
        case .ended:
            return .audioInterruption(began: false, shouldResume: shouldResume)
        }
    }

    // MARK: Route changes

    /// Mirrors `AVAudioSession.RouteChangeReason` (raw values match; 5 is unused by iOS).
    public enum RouteChangeReason: UInt, Sendable {
        case unknown = 0, newDeviceAvailable = 1, oldDeviceUnavailable = 2, categoryChange = 3
        case override = 4, wakeFromSleep = 6, noSuitableRouteForCategory = 7, routeConfigurationChange = 8
    }

    /// Headphones unplugged (or a Bluetooth route lost) pauses with native intent, so background.js
    /// treats the pause as the user's and it stays paused. Other reasons change nothing.
    public static func routeChangeCommand(reason: RouteChangeReason?, hasVideo: Bool) -> JSCommand? {
        guard hasVideo, reason == .oldDeviceUnavailable else { return nil }
        return .pause
    }

    // MARK: PiP restore

    /// The player presentation after a `presentation` message, or nil to leave it alone.
    ///
    /// Leaving PiP for inline while the video still plays is the PiP "restore" button: the player
    /// expands. Closing PiP with its X pauses first, so a paused video leaves the layout unchanged.
    /// Nothing loaded (`.hidden`) is never expanded.
    public static func presentationAfter(previous: MediaPresentation, current: MediaPresentation,
                                         status: PlaybackStatus,
                                         player: PlayerPresentation) -> PlayerPresentation? {
        guard previous == .pip, current == .inline, player != .hidden, player != .expanded else { return nil }
        switch status {
        case .playing, .buffering, .loading: return .expanded
        case .idle, .paused, .ended: return nil
        }
    }
}

// MARK: - `state` command reply

/// The reply of the `state` command (§5.4): `{meta, playback, presentation}` in bridge shapes.
public struct PlayerStateReply: Decodable, Equatable, Sendable {
    public var meta: VideoMeta?
    public var playback: PlaybackSnapshot
    public var presentation: MediaPresentation

    public init(meta: VideoMeta? = nil, playback: PlaybackSnapshot, presentation: MediaPresentation) {
        self.meta = meta
        self.playback = playback
        self.presentation = presentation
    }

    /// Decodes the JSON string `PlayerControlling.send(.state)` returns.
    public static func decode(_ json: String) throws -> PlayerStateReply {
        try JSONDecoder().decode(PlayerStateReply.self, from: Data(json.utf8))
    }

    /// Feeds the reply through the reducer as the three bridge messages it stands for, so the
    /// reducer's meta/snapshot consistency rules still hold.
    public func apply(to state: inout PlaybackState) {
        if let meta { state.apply(.videoMeta(meta)) }
        state.apply(.playback(playback))
        state.apply(.presentation(presentation))
    }
}
