// PlayerLayoutView — owner: Module C (PLAN.md §6.3). Phase 0 stub.
//
// Browse fills the screen; the player covers it while something is loaded. Both containers are
// always in the tree, in one fixed place each (D2): the player is hidden with opacity and
// hit-testing, never with an `if`.

import SwiftUI

struct PlayerLayoutView: View {
    let store: WebViewStore
    let session: PlayerSession

    init(store: WebViewStore, session: PlayerSession) {
        self.store = store
        self.session = session
    }

    var body: some View {
        let showsPlayer = session.request != nil
        ZStack {
            WebViewContainer(webView: store.browseWebView)
            WebViewContainer(webView: store.playerWebView)
                .opacity(showsPlayer ? 1 : 0)
                .allowsHitTesting(showsPlayer)
                .accessibilityHidden(!showsPlayer)
        }
        .overlay(alignment: .topTrailing) {
            if showsPlayer {
                Button {
                    store.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .padding()
                }
                .accessibilityLabel("Close player")
            }
        }
    }
}
