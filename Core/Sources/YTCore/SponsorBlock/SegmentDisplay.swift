// What the Debug › Segments tab shows for a segment (PLAN.md §6.5). Owner: Module D.
// Pure so it's tested on Linux; the colours match sponsorblock.js CONFIG.CATEGORY_COLORS
// (SponsorBlock extension config.ts barTypes, 2026-11).

import Foundation

public enum SegmentDisplay {
    /// The seek-bar colour of a category, as "#rrggbb" (unknown categories: sponsor green).
    public static func colorHex(_ category: String) -> String {
        switch category {
        case "sponsor": "#00d400"
        case "selfpromo": "#ffff00"
        case "interaction": "#cc00ff"
        case "intro": "#00ffff"
        case "outro": "#0202ed"
        case "preview": "#008fd6"
        case "music_offtopic": "#ff9900"
        case "filler": "#7300ff"
        default: "#00d400"
        }
    }

    /// `#rrggbb` → (r, g, b) in 0…1; nil if malformed.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    /// The category's name for people (SponsorBlock's), or the raw string when unknown.
    public static func name(_ category: String) -> String {
        SponsorBlock.Category(rawValue: category)?.displayName ?? category
    }

    /// A video timestamp: `m:ss`, or `h:mm:ss` from an hour. Rounds down; negative or non-finite → 0:00.
    public static func timestamp(_ seconds: Double) -> String {
        let total = seconds.isFinite && seconds > 0 ? Int(seconds.rounded(.down)) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1:05 – 1:44" for a segment.
    public static func range(_ segment: SkipSegment) -> String {
        timestamp(segment.start) + " – " + timestamp(segment.end)
    }

    /// The segment's length, rounded: "39 s", or "2 min 5 s" from a minute.
    public static func length(_ segment: SkipSegment) -> String {
        let total = max(0, Int((segment.end - segment.start).rounded()))
        return total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
    }

    /// Total skippable time of a list of segments, in seconds (segments are assumed disjoint).
    public static func totalSeconds(_ segments: [SkipSegment]) -> Double {
        segments.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }
}
