// DebugEntryView — owner: Module B (PLAN.md §5.5, §6.2 Debug tooling). Phase 0 stub.
//
// RootView overlays this view over the whole screen, above the player. Module B puts the Debug
// log viewer and Capture behind it (e.g. a small floating button). Keep everything it doesn't
// draw transparent to touches.

import SwiftUI

struct DebugEntryView: View {
    let store: WebViewStore
    let hub: BridgeEventHub
    let session: PlayerSession

    init(store: WebViewStore, hub: BridgeEventHub, session: PlayerSession) {
        self.store = store
        self.hub = hub
        self.session = session
    }

    var body: some View {
        EmptyView()
    }
}
