// Routing types (PLAN.md §5.5, §6.2). Owner: P0 (frozen contract). Logic lives in Router.swift (B).

import Foundation

public struct VideoRequest: Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case video, short, live }

    public var id: String
    public var kind: Kind
    public var startSeconds: Int?
    public var playlistID: String?
    public var playlistIndex: Int?
    /// Canonical `https://m.youtube.com/...` URL the player loads (form defined in PLAN.md §6.2).
    public var watchURL: URL

    public init(id: String, kind: Kind, startSeconds: Int? = nil, playlistID: String? = nil,
                playlistIndex: Int? = nil, watchURL: URL) {
        self.id = id
        self.kind = kind
        self.startSeconds = startSeconds
        self.playlistID = playlistID
        self.playlistIndex = playlistIndex
        self.watchURL = watchURL
    }
}

public enum LinkKind: Equatable, Sendable {
    case video(VideoRequest)
    case youtubePage(URL)
    case signIn(URL)
    case external(URL)
    case ignore
}

public enum NavigationTrigger: String, Codable, CaseIterable, Sendable {
    case click, history, windowOpen, location, initial
}

public enum RouteDecision: Equatable, Sendable {
    case allow
    case openInPlayer(VideoRequest)
    case openInBrowse(URL)
    case openExternally(URL)
    case cancel
}
