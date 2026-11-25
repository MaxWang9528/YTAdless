// MediaCoordinator — owner: Module D (PLAN.md §6.4).
//
// - AVAudioSession is set to `.playback`/`.moviePlayback` at launch and NOT activated (D16):
//   WebKit activates it when playback starts, so launching never stops other apps' audio.
// - Interruptions → `audioInterruption`; headphones unplugged → `pause` (native intent);
//   app lifecycle → `lifecycle`, starting at `willResignActive` so background.js knows before
//   WebKit pauses (D12). Decisions are MediaPolicy (YTCore), tested on Linux; this is the adapter.
// - PiP restore (pip → inline while playing) expands the player.
// - Coming back to the foreground re-reads `state`, so the UI matches the real playback.
// - SponsorBlockService (created in start()) sends `sponsorSegments` after each videoMeta.
// - Now Playing is media-session.js's job (D11): nothing here touches MPNowPlayingInfoCenter.
//
// Commands go out one at a time, in order, and never throw: the player may be on about:blank
// (`no-bridge`) or have no video (`no-video`), which is normal.

import AVFoundation
import os
import UIKit
import YTCore

@MainActor
final class MediaCoordinator {
    private let session: PlayerSession
    private let player: any PlayerControlling
    private let hub: BridgeEventHub

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var subscription: AnyObject?
    private var sendChain: Task<Void, Never>?
    private var lifecycle: AppLifecycle = .active
    private var lastPresentation: MediaPresentation = .inline
    private var sponsorBlock: SponsorBlockService?

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "Media")

    init(session: PlayerSession, player: any PlayerControlling, hub: BridgeEventHub) {
        self.session = session
        self.player = player
        self.hub = hub
    }

    /// Called once by AppServices after everything is wired.
    func start() {
        guard !started else { return }
        started = true
        configureAudioSession()
        observeAudioSession()
        observeLifecycle()
        subscription = hub.subscribe { [weak self] event in
            self?.handle(event)
        }
        // SponsorBlock (off by default): fetches segments natively, sponsorblock.js skips them.
        sponsorBlock = SponsorBlockService(session: session, player: player, hub: hub,
                                           log: (player as? WebViewStore)?.debugLog)
        sponsorBlock?.start()
    }

    // MARK: Audio session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            Self.logger.error("audio session category: \(String(describing: error), privacy: .public)")
        }
        // Deliberately no setActive(true) here (D16).
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let audio = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: audio,
                                            queue: .main) { [weak self] note in
            let info = note.userInfo
            let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let reasonRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.interruption(typeRaw: typeRaw, optionsRaw: optionsRaw, reasonRaw: reasonRaw)
            }
        })

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: audio,
                                            queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.routeChange(reasonRaw: reasonRaw)
            }
        })
    }

    private func interruption(typeRaw: UInt?, optionsRaw: UInt, reasonRaw: UInt?) {
        guard let typeRaw, let type = MediaPolicy.InterruptionType(rawValue: typeRaw) else { return }
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
        // InterruptionReason.appWasSuspended == 1 (compared raw to avoid its deprecation warning).
        let wasSuspended = reasonRaw == 1
        Self.logger.info("audio interruption \(type == .began ? "began" : "ended", privacy: .public) shouldResume=\(shouldResume) suspended=\(wasSuspended)")
        guard session.request != nil,
              let command = MediaPolicy.interruptionCommand(type: type, shouldResume: shouldResume, wasSuspended: wasSuspended)
        else { return }
        enqueue(command)
    }

    private func routeChange(reasonRaw: UInt?) {
        let reason = reasonRaw.flatMap(MediaPolicy.RouteChangeReason.init(rawValue:))
        guard let command = MediaPolicy.routeChangeCommand(reason: reason, hasVideo: session.request != nil) else { return }
        Self.logger.info("audio route lost; pausing")
        enqueue(command)
    }

    // MARK: Lifecycle (D12)

    private func observeLifecycle() {
        let center = NotificationCenter.default
        let events: [(Notification.Name, MediaPolicy.AppEvent)] = [
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
        ]
        for (name, event) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appEvent(event)
                }
            })
        }
    }

    private func appEvent(_ event: MediaPolicy.AppEvent) {
        let state = MediaPolicy.lifecycle(for: event)
        let changed = state != lifecycle
        lifecycle = state
        guard session.request != nil else { return }
        if changed {
            enqueue(.lifecycle(state), keepAliveInBackground: state != .active)
        }
        if event == .didBecomeActive {
            refreshState()
        }
    }

    /// Re-reads the player's real state (checklist item 7: after unlock, the UI matches).
    private func refreshState() {
        enqueue(.state) { [weak self] json in
            guard let self, let json else { return }
            do {
                try PlayerStateReply.decode(json).apply(to: &self.session.playback)
            } catch {
                Self.logger.debug("state reply: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Bridge events

    private func handle(_ event: BridgeEventHub.Event) {
        guard event.role == .player, event.isMainFrame else { return }
        switch event.message {
        case .ready:
            // A new document starts with lifecycle 'active' and inline presentation. If it loaded
            // while we are not active (e.g. the web process restarted in the background), say so.
            lastPresentation = .inline
            if lifecycle != .active, session.request != nil {
                enqueue(.lifecycle(lifecycle), keepAliveInBackground: true)
            }
        case .presentation(let mode):
            // AppServices subscribed first, so session.playback already holds this message.
            let previous = lastPresentation
            lastPresentation = mode
            if let next = MediaPolicy.presentationAfter(previous: previous, current: mode,
                                                        status: session.playback.snapshot.status,
                                                        player: session.presentation) {
                Self.logger.info("PiP restored; expanding the player")
                session.presentation = next
            }
        default:
            break
        }
    }

    // MARK: Sending

    /// Sends `command` after every command enqueued before it. Failures are logged, never thrown.
    /// `keepAliveInBackground` holds a background task until the command has been delivered.
    private func enqueue(_ command: JSCommand, keepAliveInBackground: Bool = false,
                         then completion: (@MainActor (String?) -> Void)? = nil) {
        let backgroundTask = keepAliveInBackground ? BackgroundTask(name: "ytadless.\(command.name)") : nil
        let previous = sendChain
        sendChain = Task { [player] in
            await previous?.value
            var result: String?
            do {
                result = try await player.send(command)
            } catch {
                Self.logger.debug("\(command.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            completion?(result)
            backgroundTask?.end()
        }
    }
}

/// A UIKit background task that ends exactly once, from `end()` or on expiry.
@MainActor
private final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
