// SponsorDetectionService — owner: Module D (PLAN.md §6.5; `captionTracks`, `suggestedSegments`, §5.4).
//
// On-device sponsor detection (Settings › "Detect sponsors with on-device AI", off by default).
// For each player-role main-frame `videoMeta` (not live), when the setting is on:
//   1. Ask SponsorBlockService: if SponsorBlock is on and has any segment for the video, stop
//      (and clear any earlier guesses). A failed SponsorBlock lookup counts as "nothing".
//   2. Check the model (Apple Intelligence may be off, or the device not eligible).
//   3. `captionTracks` → decode (YTCore Captions) → choose an English track → GET
//      `baseUrl&fmt=json3` over an ephemeral URLSession (no cookies; anonymous works, checked
//      2026-11-25) → SponsorDetector (FoundationModels, off the main actor).
//   4. Cache the result per video (LRU of 32, including "none found") and send
//      `suggestedSegments`. sponsorblock.js shows them as dashed marks with a Skip button and
//      never skips them by itself.
// D15 reloads the page for each video, so suggestions are re-sent (from the cache) on every
// `videoMeta`. Setting off → in-flight runs are cancelled and empty suggestions sent. Switching
// videos cancels the old run (a 3-hour podcast shouldn't keep the model busy).
// Not cached, so they are retried on the next load: no track (the JS handler may be a stub that
// answers `tracks: []`), an empty transcript (timedtext may one day need a PO token), the model
// being unavailable, fetch failures, and runs where a chunk
// failed (e.g. while the app was in the background).
// The transcript never leaves the phone: the only network request is the caption fetch from
// youtube.com, the same one the page itself would make.

import Foundation
import Observation
import YTCore

@MainActor
final class SponsorDetectionService {
    private static let source = "SponsorAI"
    private static let cacheLimit = 32
    private static let requestTimeout: TimeInterval = 8
    private static let resourceTimeout: TimeInterval = 20

    private let session: PlayerSession
    private let player: any PlayerControlling
    private let hub: BridgeEventHub
    private let settings: AppSettings
    private let sponsorBlock: SponsorBlockService?
    private let log: DebugLog?
    private let urlSession: URLSession
    private let detector = SponsorDetector()

    private var started = false
    private var subscription: AnyObject?
    private var current: (videoId: String, isLive: Bool)?
    private var applied: Bool
    /// videoId → suggestions (possibly []), most recent last.
    private var cache: [String: [SkipSegment]] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// A finished run: what to send, and whether it may be cached.
    private struct Outcome {
        var segments: [SkipSegment]
        var cacheable: Bool
    }

    init(session: PlayerSession, player: any PlayerControlling, hub: BridgeEventHub,
         sponsorBlock: SponsorBlockService?, settings: AppSettings = .shared, log: DebugLog?) {
        self.session = session
        self.player = player
        self.hub = hub
        self.sponsorBlock = sponsorBlock
        self.settings = settings
        self.log = log
        applied = settings.aiSponsorDetection
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        urlSession = URLSession(configuration: configuration)
    }

    func start() {
        guard !started else { return }
        started = true
        subscription = hub.subscribe { [weak self] event in
            self?.handle(event)
        }
        observeSettings()
    }

    // MARK: Events and settings

    private func handle(_ event: BridgeEventHub.Event) {
        guard event.role == .player, event.isMainFrame, case .videoMeta(let meta) = event.message else { return }
        current = (meta.videoId, meta.isLive)
        // A different video: stop working on the old one.
        for (videoId, task) in inFlight where videoId != meta.videoId {
            task.cancel()
            inFlight[videoId] = nil
        }
        guard settings.aiSponsorDetection, !meta.isLive else { return }
        update(videoId: meta.videoId)
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.aiSponsorDetection
            _ = settings.sponsorBlockEnabled
            _ = settings.sponsorBlockCategories
        } onChange: { [weak self] in
            // Fires before the new value is stored: read it on the next main-actor turn.
            Task { @MainActor [weak self] in
                self?.settingsChanged()
                self?.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        let enabled = settings.aiSponsorDetection
        let toggled = enabled != applied
        applied = enabled
        guard session.request != nil, let current, !current.isLive else { return }
        if !enabled {
            guard toggled else { return }
            for task in inFlight.values { task.cancel() }
            inFlight = [:]
            send(videoId: current.videoId, segments: [])
        } else {
            // Turned on, or SponsorBlock's settings changed (which decides whether we run).
            update(videoId: current.videoId)
        }
    }

    // MARK: Run

    private func update(videoId: String) {
        guard inFlight[videoId] == nil else { return }  // the running task sends when it's done
        inFlight[videoId] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(videoId: videoId)
            if !Task.isCancelled { self.inFlight[videoId] = nil }
            guard let outcome else { return }
            if outcome.cacheable { self.store(outcome.segments, for: videoId) }
            guard !Task.isCancelled, self.current?.videoId == videoId, self.settings.aiSponsorDetection else { return }
            self.send(videoId: videoId, segments: outcome.segments)
        }
    }

    /// nil = nothing to send (logged).
    private func run(videoId: String) async -> Outcome? {
        if let sponsorBlock {
            let known = await sponsorBlock.segmentsForDetection(videoId: videoId)
            if !known.isEmpty {
                log?.native(.info, Self.source, "\(videoId): skipped: SponsorBlock has \(known.count) segment(s)")
                // SponsorBlock covers this video; clear any guess shown before it answered.
                return Outcome(segments: [], cacheable: false)
            }
        }
        if let cached = cache[videoId] {
            touch(videoId)
            return Outcome(segments: cached, cacheable: false)
        }
        let status = SponsorDetector.status
        guard status.isAvailable else {
            log?.native(.info, Self.source, "\(videoId): skipped: \(status.message)")
            return nil
        }

        // Caption tracks from the page.
        let reply: Captions.CaptionTracksReply
        do {
            guard let json = try await player.send(.captionTracks) else {
                log?.native(.warn, Self.source, "\(videoId): captionTracks returned nothing")
                return nil
            }
            reply = try Captions.captionTracks(fromJSON: json)
        } catch JSCommandError.rejected(let reason) where reason == "no-bridge" {
            return nil  // between loads; the next videoMeta retries
        } catch {
            log?.native(.warn, Self.source, "\(videoId): captionTracks: \(error)")
            return nil
        }
        if let pageVideo = reply.videoId, pageVideo != videoId {
            log?.native(.info, Self.source, "\(videoId): page is on \(pageVideo) now; skipped")
            return nil
        }
        let track: Captions.CaptionTrack
        switch Captions.chooseTrack(reply.tracks) {
        case .track(let chosen): track = chosen
        case .none(let reason):
            log?.native(.info, Self.source, "\(videoId): skipped: \(reason)")
            return nil
        }
        guard let url = Captions.json3URL(baseUrl: track.baseUrl) else {
            log?.native(.warn, Self.source, "\(videoId): unexpected caption URL; skipped")
            return nil
        }

        // Transcript: fetched right after captionTracks, because baseUrl is signed and expires
        // (URLs are never cached, only results).
        let data: Data
        do {
            let (body, response) = try await urlSession.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                log?.native(.warn, Self.source, "\(videoId): transcript HTTP \(status), \(body.count) bytes")
                return nil
            }
            guard !body.isEmpty else {
                log?.native(.warn, Self.source, "\(videoId): AI: transcript empty (HTTP \(status), 0 bytes) — timedtext may need a PO token")
                return nil
            }
            data = body
        } catch {
            if !Task.isCancelled { log?.native(.warn, Self.source, "\(videoId): transcript fetch failed: \(error)") }
            return nil
        }
        guard !Task.isCancelled else { return nil }

        // Model (off the main actor).
        log?.native(.info, Self.source, "\(videoId): analysing \(track.languageCode) transcript (\(data.count) bytes)")
        let outcome: SponsorDetector.Outcome
        do {
            outcome = try await detector.detect(json3: data)
        } catch {
            log?.native(.warn, Self.source, "\(videoId): transcript unreadable: \(error)")
            return nil
        }
        if outcome.cueCount == 0 {
            // Not "no captions": the page listed a track, but timedtext sent no text. Not cached.
            log?.native(.warn, Self.source, "\(videoId): AI: transcript empty (\(data.count) bytes, 0 lines) — timedtext may need a PO token")
            return nil
        }
        if Task.isCancelled {
            log?.native(.info, Self.source, "\(videoId): cancelled (video changed or setting off)")
            return nil
        }
        for error in outcome.errors.prefix(3) {
            log?.native(.warn, Self.source, "\(videoId): model: \(error)")
        }
        let kind = track.isAutoGenerated ? "auto" : "manual"
        log?.native(.info, Self.source,
                    "\(videoId): \(outcome.report.summary) (\(track.languageCode) \(kind), \(outcome.cueCount) lines)")
        return Outcome(segments: outcome.report.segments, cacheable: outcome.report.failed == 0)
    }

    private func send(videoId: String, segments: [SkipSegment]) {
        let command = JSCommand.suggestedSegments(videoId: videoId, segments: segments)
        Task { [player, log] in
            do {
                try await player.send(command)
            } catch JSCommandError.rejected(let reason) where reason == "no-bridge" {
                // The player is on about:blank or between loads; the next videoMeta re-sends.
            } catch {
                log?.native(.warn, Self.source, "suggestedSegments: \(error)")
            }
        }
    }

    // MARK: Cache (small LRU)

    private func store(_ segments: [SkipSegment], for videoId: String) {
        cache[videoId] = segments
        touch(videoId)
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func touch(_ videoId: String) {
        cacheOrder.removeAll { $0 == videoId }
        cacheOrder.append(videoId)
    }
}
