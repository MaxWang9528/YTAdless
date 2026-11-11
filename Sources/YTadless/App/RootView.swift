// Root view. Owner: P0 (frozen).
//
// PlayerLayoutView (Module C) lays out both webviews. DebugEntryView (Module B) is a full-screen
// overlay above everything; it must let touches through wherever it draws nothing.

import SwiftUI

struct RootView: View {
    let services: AppServices

    var body: some View {
        PlayerLayoutView(store: services.store, session: services.session)
            .overlay {
                DebugEntryView(store: services.store, hub: services.hub, session: services.session)
            }
    }
}
