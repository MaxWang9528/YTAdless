// PlayerLayoutView — owner: Module C (PLAN.md §6.3).
//
// Lays out both long-lived webviews for the current presentation. Every number comes from
// `PresentationLayout` (YTCore, tested); this view only maps it onto SwiftUI.
//
// D2: each WebViewContainer sits in one fixed place in the tree with one fixed modifier chain.
// Modes only change the values fed to that chain (frame, scale, offset, clip, hit testing), so
// SwiftUI never re-creates a container and the WKWebView is never re-parented, paused or
// reloaded. Never wrap a container in an `if`, a `.transition` or a changing `.id`. The native
// chrome (expanded header, mini bar) is plain SwiftUI and may come and go freely.

import SwiftUI
import UIKit
import YTCore

struct PlayerLayoutView: View {
    let store: WebViewStore
    let session: PlayerSession

    /// Live finger offset while dragging the header, the expanded video or the mini player.
    @State private var dragOffset: CGSize = .zero
    @State private var layoutSync = PageLayoutSync()
    /// Swipe down on the video (inside the webview) to minimize.
    @State private var videoSwipe = VideoSwipeDown()

    init(store: WebViewStore, session: PlayerSession) {
        self.store = store
        self.session = session
    }

    /// Mini-player size, corners, margin, progress line and drag distance from Debug › Settings
    /// (`PresentationTuning.standard` by default). Reading it in `body` makes changes live.
    private var tuning: PresentationTuning { AppSettings.shared.tuning }

    /// `request == nil` means nothing is loaded, whatever `presentation` says.
    private var presentation: PlayerPresentation {
        session.request == nil ? .hidden : session.presentation
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = Self.viewport(proxy)
            let layout = PresentationLayout.layout(for: presentation, in: viewport, tuning: tuning)
            content(layout: layout, viewport: viewport)
                .ignoresSafeArea()
                .onChange(of: layout.pageLayout, initial: true) { _, pageLayout in
                    layoutSync.request(pageLayout, store: store)
                }
                .onChange(of: layout.chrome == .header && AppSettings.shared.videoSwipeToMinimize, initial: true) { _, active in
                    videoSwipe.isActive = active
                }
                .onChange(of: viewport, initial: true) { _, viewport in
                    connectVideoSwipe(viewport: viewport)
                }
        }
        .animation(PlayerAnimation.mode, value: presentation)
        // A drag the system cancelled never reaches onEnded; don't leave the player offset.
        .onChange(of: presentation) { dragOffset = .zero }
        .onChange(of: session.request) { layoutSync.resend(store: store) }
        .onChange(of: session.playback.meta?.videoId) { layoutSync.resend(store: store) }
        .task {
            layoutSync.attach(store: store)
            let log = store.debugLog
            videoSwipe.log = { level, message in log.native(level, "VideoSwipeDown", message) }
            await videoSwipe.install(on: store.playerWebView, scrollPan: store.playerWebView.scrollView.panGestureRecognizer)
        }
    }

    @ViewBuilder
    private func content(layout: PlayerLayout, viewport: PresentationViewport) -> some View {
        let live = liveOffset(for: layout)
        let isMini = layout.chrome == .miniPlayer
        let bar = layout.chromeFrame ?? PlanarRect(x: 0, y: 0, width: 0, height: 0)
        let miniRadius = tuning.miniCornerRadius
        // WebKit fullscreen (the page's own fullscreen button) covers everything; hide ours.
        let showsChrome = session.playback.presentation != .fullscreen
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)

            // One browse webview per bottom-nav tab, all always in the tree (D2); only the tab on
            // screen is visible and takes touches.
            ForEach(BrowseTab.allCases, id: \.self) { tab in
                let shown = tab == store.tabs.selected
                WebViewContainer(webView: store.browseWebView(for: tab))
                    .frame(width: layout.browse.width, height: layout.browse.height)
                    .offset(x: layout.browse.minX, y: layout.browse.minY)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown && layout.isBrowseInteractive)
                    .accessibilityHidden(!shown || !layout.isBrowseInteractive)
            }

            // Behind the status bar and the expanded header, so the strip above the page isn't
            // see-through; it follows the drag with the player.
            Color(uiColor: .systemBackground)
                .frame(width: viewport.size.x, height: layout.chrome == .header ? bar.maxY : 0)
                .offset(x: 0, y: live.height)
                .allowsHitTesting(false)

            // The mini player's shadow, behind the video.
            MiniPlayerBackground(cornerRadius: miniRadius)
                .frame(width: bar.width, height: bar.height)
                .offset(x: bar.minX + live.width, y: bar.minY + live.height)
                .opacity(isMini && showsChrome ? 1 : 0)
                .allowsHitTesting(false)

            WebViewContainer(webView: store.playerWebView)
                .frame(width: layout.player.width, height: layout.player.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: layout.playerCornerRadius, style: .continuous))
                .scaleEffect(layout.playerScale, anchor: .topLeading)
                .offset(x: layout.player.minX + live.width, y: layout.player.minY + live.height)
                // Mini player: the overlay takes every touch (tap, drag), so the page never sees them.
                .allowsHitTesting(layout.isPlayerVisible && !isMini)
                .accessibilityHidden(!layout.isPlayerVisible)

            if showsChrome, let frame = layout.chromeFrame {
                chrome(layout: layout, frame: frame, live: live, viewport: viewport)
            }
        }
        .frame(width: viewport.size.x, height: viewport.size.y, alignment: .topLeading)
        .statusBarHidden(layout.hidesStatusBar)
        .persistentSystemOverlays(layout.hidesStatusBar ? .hidden : .automatic)
    }

    @ViewBuilder
    private func chrome(layout: PlayerLayout, frame: PlanarRect, live: CGSize, viewport: PresentationViewport) -> some View {
        let actions = PlayerChromeActions(
            playback: session.playback,
            onGesture: { gesture in perform(gesture, in: viewport) },
            onPlayPause: togglePlayback,
            onPiP: startPiP,
            sleepTimer: AppServices.shared.media.sleepTimer
        )
        switch layout.chrome {
        case .none:
            EmptyView()
        case .header:
            ExpandedHeader(actions: actions)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX + live.width, y: frame.minY + live.height)
                .gesture(dragGesture(viewport: viewport))
        case .miniPlayer:
            let snapshot = session.playback.snapshot
            MiniPlayerOverlay(
                actions: actions,
                progress: MiniPlayerGeometry.progress(position: snapshot.position, duration: snapshot.duration ?? session.playback.meta?.lengthSeconds),
                progressHeight: tuning.progressHeight,
                cornerRadius: tuning.miniCornerRadius
            )
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX + live.width, y: frame.minY + live.height)
            .gesture(dragGesture(viewport: viewport))
        }
    }

    // MARK: Gestures

    private func dragGesture(viewport: PresentationViewport) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                perform(.dragEnded(translation: PlanarVector(value.translation), velocity: PlanarVector(value.velocity)),
                        in: viewport)
            }
    }

    /// The video swipe feeds the same offset and state machine as the header drag.
    private func connectVideoSwipe(viewport: PresentationViewport) {
        videoSwipe.onChanged = { translation in dragOffset = translation }
        videoSwipe.onEnded = { translation, velocity in
            perform(.dragEnded(translation: PlanarVector(translation), velocity: PlanarVector(velocity)), in: viewport)
        }
        videoSwipe.onCancelled = {
            withAnimation(PlayerAnimation.mode) { dragOffset = .zero }
        }
    }

    /// How the finger moves the player: expanded follows downward only; the mini player follows
    /// the finger (damped upward, since up means expand).
    private func liveOffset(for layout: PlayerLayout) -> CGSize {
        switch layout.chrome {
        case .header:
            return CGSize(width: 0, height: max(0, dragOffset.height))
        case .miniPlayer:
            let dx = dragOffset.width, dy = dragOffset.height
            return CGSize(width: dx, height: dy < 0 ? dy / 3 : dy)
        case .none:
            return .zero
        }
    }

    private func perform(_ gesture: PresentationGesture, in viewport: PresentationViewport) {
        let outcome = presentation.next(after: gesture, in: viewport, tuning: tuning)
        switch outcome {
        case .present(let next):
            withAnimation(PlayerAnimation.mode) {
                session.presentation = next
                dragOffset = .zero
            }
        case .close:
            close(after: gesture)
        }
    }

    /// A fling carries on in its direction, then the player closes (pause, blank, hidden).
    private func close(after gesture: PresentationGesture) {
        guard case .dragEnded(let translation, let velocity) = gesture else {
            withAnimation(PlayerAnimation.mode) {
                dragOffset = .zero
                store.close()
            }
            return
        }
        let carry = MiniPlayerGeometry.projectionDistance(velocity: velocity)
        withAnimation(PlayerAnimation.fling) {
            dragOffset = CGSize(width: translation.x + carry.x, height: translation.y + carry.y)
        }
        Task { @MainActor in
            try? await Task.sleep(for: PlayerAnimation.flingDuration)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                store.close()
                dragOffset = .zero
            }
        }
    }

    // MARK: Controls

    private func togglePlayback() {
        let command: JSCommand = session.playback.snapshot.status.isPlayingOrWaiting ? .pause : .play
        Task { try? await store.send(command) }
    }

    /// Called synchronously inside the tap handler so WebKit has the best chance of treating it
    /// as user activation (spike S-D3). `store.send` would only run after the tap returns.
    private func startPiP() {
        let command = JSCommand.pip(enter: session.playback.presentation != .pip)
        store.playerWebView.callAsyncJavaScript(
            JSCommand.functionBody,
            arguments: ["name": command.name, "args": command.argumentsJSON],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: Viewport

    /// The whole window (the content ignores the safe area) plus its safe-area insets.
    private static func viewport(_ proxy: GeometryProxy) -> PresentationViewport {
        let insets = proxy.safeAreaInsets
        let size = PlanarVector(
            proxy.size.width + insets.leading + insets.trailing,
            proxy.size.height + insets.top + insets.bottom
        )
        return PresentationViewport(
            size: size,
            safeArea: PlanarInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing)
        )
    }
}

enum PlayerAnimation {
    static let mode = Animation.spring(response: 0.38, dampingFraction: 0.86)
    static let flingDuration = Duration.milliseconds(220)
    static let fling = Animation.easeOut(duration: 0.22)
}

extension PlanarVector {
    init(_ size: CGSize) {
        self.init(Double(size.width), Double(size.height))
    }
}

extension PlaybackStatus {
    /// Playing, or about to (the play/pause button shows pause).
    var isPlayingOrWaiting: Bool {
        self == .playing || self == .buffering || self == .loading
    }
}
