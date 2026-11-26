// DebugEntryView — owner: Module B (PLAN.md §5.5, §6.2 Debug tooling).
//
// RootView overlays this view over the whole screen, above the player. It draws one small
// button on the leading edge (drag it up or down to move it) with a badge for unseen script
// errors; everything else is empty layout space, which SwiftUI doesn't hit-test, so touches pass
// through to the webviews. The button opens the Debug panel as a sheet. Settings › Show Debug
// button can hide it; shaking the iPhone opens the panel either way (`UIWindow.motionEnded` below).

import SwiftUI
import UIKit

struct DebugEntryView: View {
    let store: WebViewStore
    let hub: BridgeEventHub
    let session: PlayerSession

    @State private var showsPanel = false
    /// Live while dragging; saved to `AppSettings.debugButtonOffset` when the drag ends.
    @State private var dragOffset: CGFloat?
    @State private var dragStart: CGFloat?

    private var settings: AppSettings { AppSettings.shared }
    private var offset: CGFloat { dragOffset ?? settings.debugButtonOffset }

    private static let size: CGFloat = 30
    /// Starting point: a little below the vertical middle, clear of YouTube's top bar and bottom
    /// nav and of the mini player in the bottom-trailing corner.
    private static let initialOffsetFraction: CGFloat = 0.25

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
                .opacity(settings.showsDebugButton ? 1 : 0)
                .allowsHitTesting(settings.showsDebugButton)
                .accessibilityHidden(!settings.showsDebugButton)
                .offset(y: min(limit, max(-limit, start + offset)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsPanel) {
            DebugPanelView(store: store, session: session, log: store.debugLog)
        }
        // This overlay exists from launch, so it applies the settings that live outside a view.
        .onAppear { settings.applyAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .ytadlessDeviceShaken)) { _ in
            guard !showsPanel else { return }
            store.debugLog.markErrorsSeen()
            showsPanel = true
        }
        .onChange(of: keepsScreenAwake, initial: true) { _, awake in
            UIApplication.shared.isIdleTimerDisabled = awake
        }
    }

    /// Settings › Keep screen awake: only while the player is playing (or about to).
    private var keepsScreenAwake: Bool {
        settings.keepScreenAwake && session.request != nil && session.playback.snapshot.status.isPlayingOrWaiting
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
                        dragOffset = (dragStart ?? 0) + value.translation.height
                    }
                    .onEnded { _ in
                        if let dragOffset { settings.debugButtonOffset = dragOffset }
                        dragOffset = nil
                        dragStart = nil
                    }
            )
            .accessibilityLabel(unseen > 0 ? "Debug, \(unseen) new script errors" : "Debug")
            .accessibilityAddTraits(.isButton)
    }
}

extension Notification.Name {
    /// Posted by `UIWindow.motionEnded` on a shake; DebugEntryView opens the Debug panel.
    static let ytadlessDeviceShaken = Notification.Name("ytadless.deviceShaken")
}

extension UIWindow {
    // Shake reaches the window at the end of the responder chain when nothing else handles it
    // (WKWebView doesn't). The only way into Debug and Settings when the button is hidden.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .ytadlessDeviceShaken, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
