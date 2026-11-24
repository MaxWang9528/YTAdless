// DebugEntryView — owner: Module B (PLAN.md §5.5, §6.2 Debug tooling).
//
// RootView overlays this view over the whole screen, above the player. It draws one small
// button on the leading edge (drag it up or down to move it) with a badge for unseen script
// errors; everything else is empty layout space, which SwiftUI doesn't hit-test, so touches pass
// through to the webviews. The button opens the Debug panel as a sheet.

import SwiftUI

struct DebugEntryView: View {
    let store: WebViewStore
    let hub: BridgeEventHub
    let session: PlayerSession

    @State private var showsPanel = false
    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?

    private static let size: CGFloat = 30
    /// Starting point: a little below the vertical middle, clear of YouTube's top bar and bottom
    /// nav and of the mini-player's default bottom-trailing corner.
    private static let initialOffsetFraction: CGFloat = 0.12

    init(store: WebViewStore, hub: BridgeEventHub, session: PlayerSession) {
        self.store = store
        self.hub = hub
        self.session = session
    }

    var body: some View {
        GeometryReader { geometry in
            let limit = max(0, geometry.size.height / 2 - Self.size)
            let start = geometry.size.height * Self.initialOffsetFraction
            button
                .offset(y: min(limit, max(-limit, start + offset)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsPanel) {
            DebugPanelView(store: store, session: session, log: store.debugLog)
        }
    }

    private var button: some View {
        let unseen = store.debugLog.unseenErrorCount
        return Image(systemName: "ladybug.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(unseen > 0 ? Color.red.opacity(0.85) : Color.black.opacity(0.35)))
            .overlay(alignment: .topTrailing) {
                if unseen > 0 {
                    Text(unseen > 99 ? "99+" : "\(unseen)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 6, y: -6)
                }
            }
            .contentShape(Circle())
            .padding(.leading, 2)
            .onTapGesture {
                store.debugLog.markErrorsSeen()
                showsPanel = true
            }
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if dragStart == nil { dragStart = offset }
                        offset = (dragStart ?? 0) + value.translation.height
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityLabel(unseen > 0 ? "Debug, \(unseen) new script errors" : "Debug")
            .accessibilityAddTraits(.isButton)
    }
}
