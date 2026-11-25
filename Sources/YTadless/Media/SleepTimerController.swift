// SleepTimerController — owner: Module D (PLAN.md §6.4).
//
// The adapter around `SleepTimer` (YTCore, tested on Linux). It owns the timer value and decides
// *when* to ask it:
// - a deadline task (ContinuousClock, so it keeps counting while the phone sleeps),
// - every main-frame `playback`/`videoMeta` message from the player webview,
// - the app returning to the foreground,
// so a late wake-up can't overshoot by much. When the timer fires it sends `pause`, which
// player-bridge.js marks as native intent, so background.js keeps it paused (D12;
// js/test/sleep-timer-pause.test.mjs). `session.request` changes are observed to turn the timer
// off when the player closes, and end-of-video off when the user opens another video.
//
// No volume fade: WebKit on iOS ignores HTMLMediaElement.volume, and fading through Web Audio
// risks breaking background audio and PiP.

import Foundation
import Observation
import os
import UIKit
import YTCore

@MainActor
@Observable
final class SleepTimerController {
    private(set) var timer = SleepTimer()

    /// Sends a command to the player (MediaCoordinator's ordered queue, with a background task).
    @ObservationIgnored var send: (@MainActor (JSCommand) -> Void)?

    @ObservationIgnored private let session: PlayerSession
    @ObservationIgnored private let hub: BridgeEventHub
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscription: AnyObject?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var lastRequestId: String?

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "SleepTimer")

    init(session: PlayerSession, hub: BridgeEventHub) {
        self.session = session
        self.hub = hub
    }

    /// Called from MediaCoordinator.start(), after AppServices subscribed its reducer, so
    /// `session.playback` already holds each message this sees.
    func start() {
        guard !started else { return }
        started = true
        lastRequestId = session.request?.id
        subscription = hub.subscribe { [weak self] event in
            self?.handle(event)
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check("foreground")
            }
        })
        observeRequest()
    }

    // MARK: Menu

    /// End of video needs a loaded video.
    var canArmEndOfVideo: Bool {
        session.request != nil && SleepTimer.currentVideoId(of: session.playback) != nil
    }

    func arm(_ choice: SleepTimer.Choice) {
        guard timer.arm(choice, now: .now, playback: session.playback) else { return }
        switch timer.mode {
        case .until(let deadline, _):
            log(.info, "armed: pause at \(deadline.formatted(date: .omitted, time: .standard))")
        case .endOfVideo(let id):
            log(.info, "armed: pause at the end of \(id)")
        case .off:
            break
        }
        scheduleDeadline()
    }

    func disarm() {
        guard timer.isArmed else { return }
        timer.disarm()
        scheduleDeadline()
        log(.info, "turned off")
    }

    // MARK: Checks

    private func handle(_ event: BridgeEventHub.Event) {
        guard event.role == .player, event.isMainFrame else { return }
        switch event.message {
        case .playback, .videoMeta:
            check("playback")
        default:
            break
        }
    }

    private func check(_ trigger: String) {
        // Backstop for the request observation: nothing loaded means the player is closed.
        if session.request == nil, timer != SleepTimer() {
            requestChanged(to: nil)
            return
        }
        let wasArmed = timer.isArmed
        let action = timer.evaluate(now: .now, snapshot: session.playback.snapshot)
        if wasArmed != timer.isArmed { scheduleDeadline() }
        guard case .pause(let reason) = action else { return }
        log(.info, "pausing: \(reason) (\(trigger))")
        if let send {
            send(.pause)
        } else {
            log(.warn, "pause not sent: not started")
        }
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let remaining = timer.remaining(now: .now) else { return }
        deadlineTask = Task { [weak self] in
            // ContinuousClock (Task.sleep's default) keeps advancing while the device sleeps.
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.deadlineReached()
        }
    }

    private func deadlineReached() {
        deadlineTask = nil
        check("deadline")
        // Woke a little early (or the clock moved): sleep again for what is left.
        if timer.deadline != nil, deadlineTask == nil { scheduleDeadline() }
    }

    // MARK: Request (player opened / closed)

    private func observeRequest() {
        withObservationTracking {
            _ = session.request?.id
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let id = self.session.request?.id
                if id != self.lastRequestId { self.requestChanged(to: id) }
                self.observeRequest()
            }
        }
    }

    private func requestChanged(to id: String?) {
        lastRequestId = id
        let wasArmed = timer.isArmed
        timer.requestChanged(to: id)
        guard wasArmed != timer.isArmed else { return }
        scheduleDeadline()
        log(.info, id == nil ? "turned off: player closed" : "turned off: opened another video")
    }

    // MARK: Logging

    private func log(_ level: LogLevel, _ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        // Never reached during AppServices.init (only from menu taps, events and timers).
        AppServices.shared.store.debugLog.native(level, "SleepTimer", message)
    }
}
