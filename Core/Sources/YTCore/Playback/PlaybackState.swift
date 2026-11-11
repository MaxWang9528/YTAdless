// PlaybackState reducer (PLAN.md §5.5). Owner: P0 (frozen contract); Module D may add pure
// helpers in other files of this directory.
//
// AppServices feeds it every bridge message from the player webview's main frame.

import Foundation

public struct PlaybackState: Equatable, Sendable {
    public var meta: VideoMeta?
    public var snapshot: PlaybackSnapshot
    public var presentation: MediaPresentation

    public init(meta: VideoMeta? = nil, snapshot: PlaybackSnapshot = .idle,
                presentation: MediaPresentation = .inline) {
        self.meta = meta
        self.snapshot = snapshot
        self.presentation = presentation
    }

    /// Applies `videoMeta`, `playback` and `presentation`; ignores every other message.
    ///
    /// Meta and snapshot never describe different videos: metadata for a new video resets the
    /// snapshot to `.loading`, and a snapshot for another video drops the stale metadata.
    public mutating func apply(_ message: BridgeMessage) {
        switch message {
        case .videoMeta(let newMeta):
            meta = newMeta
            if let current = snapshot.videoId, current != newMeta.videoId {
                snapshot = PlaybackSnapshot(status: .loading, duration: newMeta.lengthSeconds,
                                            rate: snapshot.rate, videoId: newMeta.videoId)
            }
        case .playback(let newSnapshot):
            snapshot = newSnapshot
            if let id = newSnapshot.videoId, let current = meta, current.videoId != id {
                meta = nil
            }
        case .presentation(let mode):
            presentation = mode
        case .ready, .log, .scriptError, .route, .pageChanged, .filterHit, .unknown:
            break
        }
    }
}
