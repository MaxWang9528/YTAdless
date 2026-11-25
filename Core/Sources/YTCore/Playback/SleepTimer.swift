// Sleep timer (PLAN.md §6.4). Owner: Module D.
//
// The pure state machine behind SleepTimerController (Sources/YTadless/Media). Time is injected
// (`now`), and there is no Timer or Task here, so every branch is tested on Linux.
//
// - Duration: pause once `now` reaches the deadline. The adapter checks on a deadline task, on
//   every `playback` message and on returning to the foreground, so a late wake-up can't overshoot
//   by much. A passed deadline always pauses: `pause` is idempotent, and a stale snapshot must not
//   let a playing video through.
// - End of video: armed on the current videoId. It pauses when that video ends, or when a
//   different video is playing (YouTube's autoplay of the next one). mweb reports `ended` before
//   autoplay starts the next video, so after `ended` the timer is off for the UI but keeps a
//   short guard that pauses the first different video to start playing.
// - A video the user opens from the browse view (a new `VideoRequest`) turns end-of-video off
//   instead of pausing it; closing the player turns everything off.
//
// No volume fade: WebKit on iOS ignores HTMLMediaElement.volume, and routing the video through
// Web Audio to fade it risks breaking background audio and PiP.

import Foundation

public struct SleepTimer: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case off
        /// Pause at `deadline`; `armedAt` is when it was set (the countdown's lower bound).
        case until(deadline: Date, armedAt: Date)
        /// Pause when `videoId` ends or another video plays.
        case endOfVideo(videoId: String)
    }

    /// What the user picks in the menu.
    public enum Choice: Equatable, Sendable {
        case minutes(Int)
        case endOfVideo
    }

    /// What the adapter should do after `evaluate`.
    public enum Action: Equatable, Sendable {
        case none
        /// Send `pause`. The timer has already turned itself off.
        case pause(reason: String)
    }

    /// After `ended`: pause the first video other than `endedVideoId` that plays before `until`.
    struct AutoplayGuard: Equatable, Sendable {
        var endedVideoId: String?
        var until: Date
    }

    /// The menu's durations, in minutes.
    public static let presetMinutes = [15, 30, 45, 60, 90]
    /// How long after `ended` the next (autoplayed) video is still paused. mweb's autoplay
    /// countdown is a few seconds; this leaves room for a slow load in the background.
    public static let autoplayGuardSeconds: TimeInterval = 60

    public private(set) var mode: Mode = .off
    private(set) var autoplayGuard: AutoplayGuard?

    public init() {}

    public var isArmed: Bool { mode != .off }

    public var deadline: Date? {
        if case .until(let deadline, _) = mode { return deadline }
        return nil
    }

    /// Seconds left in duration mode (never negative); nil otherwise.
    public func remaining(now: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The video end-of-video would arm on: the snapshot's id, else the metadata's.
    public static func currentVideoId(of playback: PlaybackState) -> String? {
        playback.snapshot.videoId ?? playback.meta?.videoId
    }

    /// Arms the timer, replacing any earlier setting. Returns false (and changes nothing) for
    /// end-of-video with no video loaded, or for a non-positive duration.
    @discardableResult
    public mutating func arm(_ choice: Choice, now: Date, playback: PlaybackState) -> Bool {
        switch choice {
        case .minutes(let minutes):
            guard minutes > 0 else { return false }
            mode = .until(deadline: now.addingTimeInterval(TimeInterval(minutes) * 60), armedAt: now)
        case .endOfVideo:
            guard let id = Self.currentVideoId(of: playback) else { return false }
            mode = .endOfVideo(videoId: id)
        }
        autoplayGuard = nil
        return true
    }

    /// Turns the timer off (the menu's "Turn off", or the player closed).
    public mutating func disarm() {
        mode = .off
        autoplayGuard = nil
    }

    /// The player loaded a video the user chose (`VideoRequest.id`), or nothing (nil = closed).
    /// Closing turns everything off; a different video turns end-of-video off without pausing it.
    public mutating func requestChanged(to videoId: String?) {
        guard let videoId else { return disarm() }
        if case .endOfVideo(let armed) = mode, armed != videoId { mode = .off }
        if let autoplayGuard, autoplayGuard.endedVideoId != videoId { self.autoplayGuard = nil }
    }

    /// Decides whether to pause now. `snapshot` is the player's latest playback state; pass it
    /// on deadline wake-ups and foreground checks too.
    public mutating func evaluate(now: Date, snapshot: PlaybackSnapshot) -> Action {
        if let autoplayGuard {
            if now >= autoplayGuard.until {
                self.autoplayGuard = nil
            } else if let id = snapshot.videoId, id != autoplayGuard.endedVideoId,
                      snapshot.status == .playing || snapshot.status == .buffering {
                self.autoplayGuard = nil
                return .pause(reason: "the next video started after the timed video ended")
            }
        }

        switch mode {
        case .off:
            return .none
        case .until(let deadline, _):
            guard now >= deadline else { return .none }
            disarm()
            return .pause(reason: "time is up")
        case .endOfVideo(let armed):
            let id = snapshot.videoId
            if snapshot.status == .ended, id == nil || id == armed {
                mode = .off
                autoplayGuard = AutoplayGuard(endedVideoId: armed,
                                              until: now.addingTimeInterval(Self.autoplayGuardSeconds))
                return .pause(reason: "the video ended")
            }
            // Only a video that is actually playing: a pause during `loading` would be undone by
            // the player starting the new video.
            if let id, id != armed, snapshot.status == .playing || snapshot.status == .buffering {
                disarm()
                return .pause(reason: "another video started")
            }
            return .none
        }
    }
}
