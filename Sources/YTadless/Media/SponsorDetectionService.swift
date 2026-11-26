// SponsorDetectionService — owner: Module D (PLAN.md §6.5; `captionTracks`, `suggestedSegments`, §5.4).
//
// On-device sponsor detection (Settings › "Detect sponsors with on-device AI", off by default).
// For each player-role main-frame `videoMeta` (not live), when the setting is on:
//   1. Ask SponsorBlockService: if SponsorBlock is on and has any segment for the video, stop
//      (and clear any earlier guesses). A failed SponsorBlock lookup counts as "nothing".
//   2. Check the model (Apple Intelligence may be off, or the device not eligible).
//   3. `captionTracks` → decode (YTCore Captions) → choose an English track → GET
//      `baseUrl&fmt=json3` over an ephemeral URLSession (no cookies). Watch-page tracks carry
//      `exp=…,xpe` and answer 200 with 0 bytes without a PO token (checked 2026-11-25), so for
//      those, or when the page's track comes back empty, native POSTs an anonymous MWEB
//      /youtubei/v1/player with the page's ytcfg client version + signatureTimestamp and uses
//      its token-free tracks (YTCore InnertubeCaptions) → SponsorDetector (FoundationModels,
//      off the main actor). When both fail, one log line names every step that failed.
//   4. Cache the result per video (LRU of 32, including "none found") and send
//      `suggestedSegments` with `autoSkip` = Settings › "Skip automatically" (off by default):
//      sponsorblock.js shows them as dashed marks with a Skip button, or skips them with Undo.
// D15 reloads the page for each video, so suggestions are re-sent (from the cache) on every
// `videoMeta`. Setting off → in-flight runs are cancelled and empty suggestions sent. Switching
// videos cancels the old run (a 3-hour podcast shouldn't keep the model busy).
// Not cached, so they are retried on the next load: no track (the JS handler may be a stub that
// answers `tracks: []`), no transcript from either source, the model
// being unavailable, fetch failures, and runs where a chunk
// failed (e.g. while the app was in the background).
// The transcript never leaves the phone: the only network requests go to m.youtube.com (the
// /player lookup and the caption fetch), anonymous, the same ones the page itself makes.

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
    private var appliedAutoSkip: Bool
    private var appliedHideMarkers: Bool
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
        appliedAutoSkip = settings.aiSponsorAutoSkip
        appliedHideMarkers = settings.hideMarkersInFullscreen
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
            _ = settings.aiSponsorAutoSkip
            _ = settings.hideMarkersInFullscreen
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
        let autoSkipChanged = settings.aiSponsorAutoSkip != appliedAutoSkip
        appliedAutoSkip = settings.aiSponsorAutoSkip
        let hideMarkersChanged = settings.hideMarkersInFullscreen != appliedHideMarkers
        appliedHideMarkers = settings.hideMarkersInFullscreen
        guard session.request != nil, let current, !current.isLive else { return }
        if enabled, autoSkipChanged || hideMarkersChanged, inFlight[current.videoId] == nil,
           let shown = board?.suggested, shown.videoId == current.videoId {
            // Only the mode changed: re-send what is shown (a running task sends with the new mode).
            send(videoId: current.videoId, segments: shown.segments)
            return
        }
        // Only the full-screen marks setting changed and nothing is shown: nothing to re-run.
        if hideMarkersChanged, !toggled, !autoSkipChanged { return }
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
        // Transcript: the page's track first, unless its URL needs a PO token; then fresh,
        // token-free tracks from /youtubei/v1/player (YTCore InnertubeCaptions.swift says why).
        guard let (track, data) = await transcript(videoId: videoId, reply: reply) else { return nil }
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
            // transcript() already checked for lines; not cached.
            log?.native(.warn, Self.source, "\(videoId): AI: no transcript — \(track.languageCode) json3 had 0 lines")
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

    // MARK: Transcript

    /// What one json3 fetch gave.
    private enum Fetched {
        case transcript(Data)
        /// Why not, for the log ("HTTP 403 …", "empty body …", "0 caption lines …").
        case failed(String)
    }

    /// The chosen track and its json3 body (with at least one line), or nil, logged with every
    /// step that failed, so "no transcript" always says why.
    private func transcript(videoId: String, reply: Captions.CaptionTracksReply) async -> (Captions.CaptionTrack, Data)? {
        var notes: [String] = []
        switch Captions.chooseTrack(reply.tracks) {
        case .track(let track):
            if Captions.requiresPoToken(baseUrl: track.baseUrl) {
                notes.append("page track needs a PO token (exp=xpe)")
            } else {
                switch await fetchJSON3(track) {
                case .transcript(let data):
                    log?.native(.info, Self.source, "\(videoId): transcript from the page's caption track")
                    return (track, data)
                case .failed(let why):
                    notes.append("page track: \(why)")
                }
            }
        case .none(let reason):
            // Other languages only: /player lists the same tracks.
            if !reply.tracks.isEmpty {
                log?.native(.info, Self.source, "\(videoId): skipped: \(reason)")
                return nil
            }
            notes.append("page: \(reason)")
        }
        guard !Task.isCancelled else { return nil }

        // Fallback: anonymous MWEB /youtubei/v1/player.
        let client = reply.client ?? .fallback
        if reply.client == nil { notes.append("no ytcfg client from the page, used the built-in one") }
        guard let request = Captions.playerRequest(videoId: videoId, client: client) else {
            notes.append("/player: bad request values")
            return giveUp(videoId, notes)
        }
        let tracks: [Captions.CaptionTrack]
        do {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = request.body
            for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
            let (body, response) = try await urlSession.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                notes.append("/player HTTP \(status)")
                return giveUp(videoId, notes)
            }
            tracks = try Captions.captionTracks(fromPlayerResponse: body, videoId: videoId)
        } catch {
            if Task.isCancelled { return nil }
            notes.append("/player: \(error)")
            return giveUp(videoId, notes)
        }
        let track: Captions.CaptionTrack
        switch Captions.chooseTrack(tracks) {
        case .track(let chosen): track = chosen
        case .none(let reason):
            notes.append("/player: \(reason)")
            return giveUp(videoId, notes)
        }
        switch await fetchJSON3(track) {
        case .transcript(let data):
            log?.native(.info, Self.source, "\(videoId): transcript via /player (\(notes.joined(separator: "; ")))")
            return (track, data)
        case .failed(let why):
            notes.append("/player track: \(why)")
            return giveUp(videoId, notes)
        }
    }

    private func giveUp(_ videoId: String, _ notes: [String]) -> (Captions.CaptionTrack, Data)? {
        if !Task.isCancelled {
            log?.native(.warn, Self.source, "\(videoId): AI: no transcript — \(notes.joined(separator: "; "))")
        }
        return nil
    }

    /// GET `baseUrl&fmt=json3` right away (signed, short-lived URLs: results are cached, URLs never)
    /// and check that it has caption lines (parsed off the main actor).
    private func fetchJSON3(_ track: Captions.CaptionTrack) async -> Fetched {
        guard let url = Captions.json3URL(baseUrl: track.baseUrl) else { return .failed("unexpected caption URL") }
        do {
            let (body, response) = try await urlSession.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failed("HTTP \(status), \(body.count) bytes") }
            guard !body.isEmpty else { return .failed("HTTP \(status) with an empty body (wants a PO token?)") }
            let lines = await Task.detached(priority: .utility) { (try? Captions.cues(fromJSON3: body))?.count }.value
            guard let lines else { return .failed("not json3 (\(body.count) bytes)") }
            guard lines > 0 else { return .failed("0 caption lines in \(body.count) bytes") }
            return .transcript(body)
        } catch {
            return .failed("fetch failed: \(error.localizedDescription)")
        }
    }

    /// Debug › Segments shows what was last sent (set by MediaCoordinator).
    var board: SegmentBoard?

    private func send(videoId: String, segments: [SkipSegment]) {
        let autoSkip = settings.aiSponsorAutoSkip
        board?.sentSuggestions(videoId: videoId, segments: segments, autoSkip: autoSkip)
        let command = JSCommand.suggestedSegments(videoId: videoId, segments: segments, autoSkip: autoSkip,
                                                  hideMarkersInFullscreen: settings.hideMarkersInFullscreen)
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
