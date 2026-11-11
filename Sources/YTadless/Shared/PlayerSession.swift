// PlayerSession: the shared, observable player state (PLAN.md §5.5). Owner: P0 (frozen).

import Observation
import YTCore

@MainActor
@Observable
final class PlayerSession {
    /// What the player webview has loaded; nil = nothing.
    var request: VideoRequest?
    var presentation: PlayerPresentation = .hidden
    /// Fed by AppServices from the player webview's main-frame bridge messages.
    var playback = PlaybackState()
    var browseTitle: String?

    init() {}

    /// Called when the player sends the user to the browse view: `.expanded` → `.mini(.bottomTrailing)`;
    /// other modes are unchanged.
    func collapseForBrowsing() {
        if presentation == .expanded {
            presentation = .mini(.bottomTrailing)
        }
    }
}
