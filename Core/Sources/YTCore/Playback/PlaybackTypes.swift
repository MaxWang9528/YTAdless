// Playback value types (PLAN.md §5.5). Owner: P0 (frozen contract).
// Their Codable keys are the bridge field names of `videoMeta` and `playback` (§5.3).

import Foundation

public enum PlaybackStatus: String, Codable, CaseIterable, Sendable {
    case idle, loading, playing, paused, buffering, ended
}

public enum MediaPresentation: String, Codable, CaseIterable, Sendable {
    case inline, pip, fullscreen
}

public struct VideoMeta: Codable, Equatable, Sendable {
    public var videoId: String
    public var title: String
    public var author: String
    public var lengthSeconds: Double?
    public var thumbnailURL: String?
    public var isLive: Bool

    public init(videoId: String, title: String, author: String, lengthSeconds: Double? = nil,
                thumbnailURL: String? = nil, isLive: Bool = false) {
        self.videoId = videoId
        self.title = title
        self.author = author
        self.lengthSeconds = lengthSeconds
        self.thumbnailURL = thumbnailURL
        self.isLive = isLive
    }
}

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var status: PlaybackStatus
    public var position: Double
    public var duration: Double?
    public var rate: Double
    public var videoId: String?

    public init(status: PlaybackStatus, position: Double = 0, duration: Double? = nil,
                rate: Double = 1, videoId: String? = nil) {
        self.status = status
        self.position = position
        self.duration = duration
        self.rate = rate
        self.videoId = videoId
    }

    /// Nothing loaded.
    public static let idle = PlaybackSnapshot(status: .idle)
}
