// SponsorBlock — owner: Module D (PLAN.md §6.4; `sponsorSegments`, §5.4).
//
// Pure pieces of the SponsorBlock client: categories, the request URL and the response parser.
// The app target (SponsorBlockService) computes the SHA-256 hash prefix with CryptoKit, which
// Core can't import (D3), fetches with URLSession and sends the result as `sponsorSegments`.
//
// API: https://wiki.sponsor.ajay.app/w/API_Docs › "GET /api/skipSegments/:sha256HashPrefix"
// (read 2026-11-25, page last edited 2026-11-07) and https://wiki.sponsor.ajay.app/w/Types.
//   - base URL https://sponsor.ajay.app; the prefix is the first 4–32 hex chars of
//     sha256(videoID), "4 is recommended".
//   - `category` and `actionType` "can be repeated" (the documented form we use; the JSON-array
//     `categories=[…]` form also works, but the doc's examples of it are malformed).
//   - response: `[{videoID, segments: [{segment: [start, end], UUID, category, actionType,
//     locked, votes, videoDuration, description}]}]`: every video whose hash shares the prefix,
//     so the caller must pick its own videoID.
//   - no segments: HTTP 404 with body `[]` (the docs only list 404 generically; checked live
//     2026-11-25 with prefix 5f6b, category=preview&actionType=chapter → 404 `[]`).

import Foundation

public enum SponsorBlock {
    /// SponsorBlock categories the app offers. Raw values are the API's names (Types › Category;
    /// `music_offtopic` isn't on the Types page but is served by the API, seen live 2026-11-25).
    public enum Category: String, CaseIterable, Codable, Sendable, Identifiable {
        case sponsor, selfpromo, interaction, intro, outro, preview
        case musicOfftopic = "music_offtopic"
        case filler

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .sponsor: "Sponsor"
            case .selfpromo: "Unpaid/self promotion"
            case .interaction: "Interaction reminder"
            case .intro: "Intro"
            case .outro: "Endcards/credits"
            case .preview: "Preview/recap"
            case .musicOfftopic: "Non-music section"
            case .filler: "Filler tangent"
            }
        }

        /// Default enabled set. `filler` is "very aggressive … not … by default" (Types page).
        public static let defaults: Set<Category> = [.sponsor, .selfpromo, .interaction]

        /// Parses persisted raw strings, dropping unknown ones.
        public static func set(fromRawValues raw: [String]) -> Set<Category> {
            Set(raw.compactMap(Category.init(rawValue:)))
        }

        /// Raw strings in `allCases` order (stable for persistence and URLs).
        public static func rawValues(_ set: Set<Category>) -> [String] {
            allCases.filter(set.contains).map(\.rawValue)
        }
    }

    public static let baseURL = "https://sponsor.ajay.app"
    /// Hash prefix length we send ("4 is recommended").
    public static let prefixLength = 4
    /// Segments shorter than this are dropped (too short to be worth a seek).
    public static let minimumSegmentSeconds = 1.0

    public enum RequestError: Error, Equatable, Sendable {
        case invalidPrefix(String)
        case noCategories
    }

    public enum ResponseError: Error, Equatable, Sendable {
        case httpStatus(Int)
        case malformed
    }

    /// `GET /api/skipSegments/<prefix>?category=…&actionType=skip`. `prefix` must be exactly
    /// `prefixLength` lowercase hex characters; categories go out in `allCases` order.
    public static func requestURL(hashPrefix prefix: String, categories: Set<Category>) throws -> URL {
        guard prefix.count == prefixLength,
              prefix.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })
        else { throw RequestError.invalidPrefix(prefix) }
        guard !categories.isEmpty else { throw RequestError.noCategories }
        var components = URLComponents(string: baseURL)!
        components.path = "/api/skipSegments/" + prefix
        components.queryItems = Category.rawValues(categories).map { URLQueryItem(name: "category", value: $0) }
            + [URLQueryItem(name: "actionType", value: "skip")]
        guard let url = components.url else { throw RequestError.invalidPrefix(prefix) }
        return url
    }

    /// The segments to skip in `videoId`, from a skipSegments response. 404 → []. Other non-2xx
    /// statuses and undecodable bodies throw. Keeps only `actionType == "skip"` segments of an
    /// allowed category with finite bounds, `start >= 0` and at least `minimumSegmentSeconds`
    /// long; sorts by start and merges overlapping or touching segments (the merged segment keeps
    /// the category of the one that starts first).
    public static func segments(from data: Data, statusCode: Int, videoId: String,
                                categories: Set<Category>) throws -> [SkipSegment] {
        if statusCode == 404 { return [] }
        guard (200..<300).contains(statusCode) else { throw ResponseError.httpStatus(statusCode) }
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            throw ResponseError.malformed
        }
        let allowed = Set(categories.map(\.rawValue))
        var kept: [SkipSegment] = []
        for entry in entries where entry.videoID == videoId {
            for raw in entry.segments ?? [] {
                guard (raw.actionType ?? "skip") == "skip",
                      let category = raw.category, allowed.contains(category),
                      let bounds = raw.segment, bounds.count == 2
                else { continue }
                let start = bounds[0], end = bounds[1]
                guard start.isFinite, end.isFinite, start >= 0, end - start >= minimumSegmentSeconds else { continue }
                kept.append(SkipSegment(start: start, end: end, category: category))
            }
        }
        return merged(kept)
    }

    /// Sorted by start; a segment that starts at or before the previous one's end is folded in.
    public static func merged(_ segments: [SkipSegment]) -> [SkipSegment] {
        let sorted = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [SkipSegment] = []
        for segment in sorted {
            if let last = out.last, segment.start <= last.end {
                out[out.count - 1].end = max(last.end, segment.end)
            } else {
                out.append(segment)
            }
        }
        return out
    }

    // Lenient wire types: unknown fields are ignored and one odd segment doesn't fail the rest.
    private struct Entry: Decodable {
        let videoID: String
        let segments: [RawSegment]?
    }

    private struct RawSegment: Decodable {
        let segment: [Double]?
        let category: String?
        let actionType: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segment = try? c.decodeIfPresent([Double].self, forKey: .segment)
            category = try? c.decodeIfPresent(String.self, forKey: .category)
            actionType = try? c.decodeIfPresent(String.self, forKey: .actionType)
        }

        enum CodingKeys: String, CodingKey { case segment, category, actionType }
    }
}
