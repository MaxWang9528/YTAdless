// Composition root (PLAN.md §3). Owner: P0 (frozen).
//
// Built exactly once (`shared`), so the two WKWebViews inside WebViewStore are created once for
// the life of the process (D2) no matter how often SwiftUI re-creates views.

import YTCore

@MainActor
final class AppServices {
    static let shared = AppServices()

    let session: PlayerSession
    let hub: BridgeEventHub
    let store: WebViewStore
    let media: MediaCoordinator

    private var playbackSubscription: AnyObject?

    private init() {
        session = PlayerSession()
        hub = BridgeEventHub()
        store = WebViewStore(session: session, hub: hub)
        media = MediaCoordinator(session: session, player: store, hub: hub)

        // The player's main frame is the only source of playback state.
        playbackSubscription = hub.subscribe { [session] event in
            guard event.role == .player, event.isMainFrame else { return }
            session.playback.apply(event.message)
        }

        media.start()
    }
}
