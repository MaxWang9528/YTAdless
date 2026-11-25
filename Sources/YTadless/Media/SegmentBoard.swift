// SegmentBoard — owner: Module D (PLAN.md §6.5).
//
// What was last sent to the player for skipping: SponsorBlock's segments (`sponsorSegments`) and
// the on-device guesses (`suggestedSegments`), per video. SponsorBlockService and
// SponsorDetectionService write it when they send; Debug › Segments reads it. It holds no logic.

import Foundation
import Observation
import YTCore

@MainActor @Observable
final class SegmentBoard {
    struct Entry: Equatable {
        let videoId: String
        let segments: [SkipSegment]
        let sentAt: Date
    }

    /// The last `sponsorSegments` sent (an empty list means SponsorBlock found none, or was turned off).
    private(set) var sponsorBlock: Entry?
    /// The last `suggestedSegments` sent.
    private(set) var suggested: Entry?

    func sentSponsorBlock(videoId: String, segments: [SkipSegment]) {
        sponsorBlock = Entry(videoId: videoId, segments: segments, sentAt: Date())
    }

    func sentSuggestions(videoId: String, segments: [SkipSegment]) {
        suggested = Entry(videoId: videoId, segments: segments, sentAt: Date())
    }
}
