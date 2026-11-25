// SponsorBlockService — owner: Module D (PLAN.md §6.4; `sponsorSegments`, §5.4).
//
// Native fetches, JS skips: for each player-role main-frame `videoMeta`, when Settings ›
// SponsorBlock is on, this fetches the video's segments from sponsor.ajay.app (URLSession, so the
// page's CSP doesn't matter and nothing is fetched while the setting is off) and sends
// `sponsorSegments` to the player; sponsorblock.js does the skipping.
// - Privacy: only the first 4 hex chars of sha256(videoId) leave the device (API_Docs, "4 is
//   recommended"); the URL and parsing are YTCore's SponsorBlock (tested on Linux).
// - D15 loads every video fresh, so JS forgets its segments each load: the segments are re-sent
//   on EVERY videoMeta, from an in-memory LRU cache when possible.
// - Settings changes (including Reset to defaults) are observed with withObservationTracking:
//   off → empty segments for the current video; on / categories changed → fetch and send.
// - Live videos are skipped. Failures go to the Debug log, never crash.
// - `segmentsForDetection` lets SponsorDetectionService (on-device AI) run only when SponsorBlock
//   has nothing for the video; it shares this cache and in-flight requests.

import CryptoKit
import Foundation
import Observation
import YTCore

@MainActor
final class SponsorBlockService {
    private static let source = "SponsorBlock"
    private static let cacheLimit = 32
    private static let requestTimeout: TimeInterval = 6
    private static let resourceTimeout: TimeInterval = 10

    private let session: PlayerSession
    private let player: any PlayerControlling
    private let hub: BridgeEventHub
    private let settings: AppSettings
    private let log: DebugLog?
    private let urlSession: URLSession

    private var started = false
    private var subscription: AnyObject?
    /// The player's current video (from its last videoMeta): id and whether it is live.
    private var current: (videoId: String, isLive: Bool)?
    /// Settings last acted on, so a change that doesn't alter them does nothing.
    private var applied: (enabled: Bool, categories: Set<SponsorBlock.Category>)
    /// Cache key ("<videoId>|<categories>") → segments, most recent last.
    private var cache: [String: [SkipSegment]] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<[SkipSegment]?, Never>] = [:]

    init(session: PlayerSession, player: any PlayerControlling, hub: BridgeEventHub,
         settings: AppSettings = .shared, log: DebugLog?) {
        self.session = session
        self.player = player
        self.hub = hub
        self.settings = settings
        self.log = log
        applied = (settings.sponsorBlockEnabled, settings.sponsorBlockCategories)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
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

    // MARK: Events

    private func handle(_ event: BridgeEventHub.Event) {
        guard event.role == .player, event.isMainFrame, case .videoMeta(let meta) = event.message else { return }
        current = (meta.videoId, meta.isLive)
        guard settings.sponsorBlockEnabled, !meta.isLive else { return }
        update(videoId: meta.videoId)
    }

    private func observeSettings() {
        withObservationTracking {
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
        let enabled = settings.sponsorBlockEnabled
        let categories = settings.sponsorBlockCategories
        guard enabled != applied.enabled || categories != applied.categories else { return }
        applied = (enabled, categories)
        guard session.request != nil, let current, !current.isLive else { return }
        if enabled {
            update(videoId: current.videoId)
        } else {
            send(videoId: current.videoId, segments: [])
        }
    }

    // MARK: Fetch and send

    private static func key(_ videoId: String, _ categories: Set<SponsorBlock.Category>) -> String {
        videoId + "|" + SponsorBlock.Category.rawValues(categories).joined(separator: ",")
    }

    /// Sends the segments for `videoId` under the current settings, fetching them if needed.
    private func update(videoId: String) {
        let categories = settings.sponsorBlockCategories
        guard !categories.isEmpty else {
            send(videoId: videoId, segments: [])
            return
        }
        let key = Self.key(videoId, categories)
        if let cached = cache[key] {
            touch(key)
            send(videoId: videoId, segments: cached)
            return
        }
        Task { [weak self] in
            guard let segments = await self?.lookup(videoId: videoId, categories: categories), let self else { return }
            // Still the same video and settings? (The user may have moved on while we fetched.)
            guard self.current?.videoId == videoId, self.settings.sponsorBlockEnabled,
                  self.settings.sponsorBlockCategories == categories
            else { return }
            self.send(videoId: videoId, segments: segments)
        }
    }

    /// SponsorBlock's segments for `videoId` under the current settings, for on-device detection
    /// (SponsorDetectionService runs only when this is empty). [] when SponsorBlock is off or has
    /// no categories, when the video has no segments, and when the lookup failed (so the guess
    /// can still help offline-ish cases; the failure is logged). Shares the cache and any
    /// in-flight request with the normal path, so it never fetches twice.
    func segmentsForDetection(videoId: String) async -> [SkipSegment] {
        let categories = settings.sponsorBlockCategories
        guard settings.sponsorBlockEnabled, !categories.isEmpty else { return [] }
        return await lookup(videoId: videoId, categories: categories) ?? []
    }

    /// Cached segments, else the in-flight request's, else a new fetch (stored on success).
    /// nil on failure.
    private func lookup(videoId: String, categories: Set<SponsorBlock.Category>) async -> [SkipSegment]? {
        let key = Self.key(videoId, categories)
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        let task = inFlight[key] ?? Task { [weak self] in
            await self?.fetch(videoId: videoId, categories: categories)
        }
        inFlight[key] = task
        let segments = await task.value
        inFlight[key] = nil
        if let segments { store(segments, for: key) }
        return segments
    }

    /// nil on failure (logged); [] when the video has no segments.
    private func fetch(videoId: String, categories: Set<SponsorBlock.Category>) async -> [SkipSegment]? {
        do {
            let url = try SponsorBlock.requestURL(hashPrefix: Self.hashPrefix(videoId), categories: categories)
            let (data, response) = try await urlSession.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let segments = try SponsorBlock.segments(from: data, statusCode: status, videoId: videoId,
                                                     categories: categories)
            log?.native(.info, Self.source, "\(videoId): \(segments.count) segment(s) (HTTP \(status))")
            return segments
        } catch {
            log?.native(.warn, Self.source, "\(videoId): fetch failed: \(error)")
            return nil
        }
    }

    /// Debug › Segments shows what was last sent (set by MediaCoordinator).
    var board: SegmentBoard?

    private func send(videoId: String, segments: [SkipSegment]) {
        board?.sentSponsorBlock(videoId: videoId, segments: segments)
        let command = JSCommand.sponsorSegments(videoId: videoId, segments: segments)
        Task { [player, log] in
            do {
                try await player.send(command)
            } catch JSCommandError.rejected(let reason) where reason == "no-bridge" {
                // The player is on about:blank or between loads; the next videoMeta re-sends.
            } catch {
                log?.native(.warn, Self.source, "sponsorSegments: \(error)")
            }
        }
    }

    // MARK: Cache (small LRU)

    private func store(_ segments: [SkipSegment], for key: String) {
        cache[key] = segments
        touch(key)
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    /// The first `SponsorBlock.prefixLength` lowercase hex chars of sha256(videoId).
    private static func hashPrefix(_ videoId: String) -> String {
        let hex = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(SponsorBlock.prefixLength))
    }
}
