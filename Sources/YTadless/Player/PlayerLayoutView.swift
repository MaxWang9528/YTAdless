// PlayerLayoutView — owner: Module C (PLAN.md §6.3).
//
// Lays out both long-lived webviews for the current presentation. Every number comes from
// `PresentationLayout` (YTCore, tested); this view only maps it onto SwiftUI.
//
// D2: each WebViewContainer sits in one fixed place in the tree with one fixed modifier chain.
// Modes only change the values fed to that chain (frame, scale, offset, clip, hit testing), so
// SwiftUI never re-creates a container and the WKWebView is never re-parented, paused or
// reloaded. Never wrap a container in an `if`, a `.transition` or a changing `.id`. The native
// chrome (header, docked bar, mini overlay) is plain SwiftUI and may come and go freely.

import SwiftUI
import UIKit
import YTCore

struct PlayerLayoutView: View {
    let store: WebViewStore
    let session: PlayerSession

    /// Live finger offset while dragging the header, docked bar or mini-player.
    @State private var dragOffset: CGSize = .zero
    @State private var layoutSync = PageLayoutSync()

    init(store: WebViewStore, session: PlayerSession) {
        self.store = store
        self.session = session
    }

    /// `request == nil` means nothing is loaded, whatever `presentation` says.
    private var presentation: PlayerPresentation {
        session.request == nil ? .hidden : session.presentation
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = Self.viewport(proxy)
            let layout = PresentationLayout.layout(for: presentation, in: viewport)
            content(layout: layout, viewport: viewport)
                .ignoresSafeArea()
                .onChange(of: layout.pageLayout, initial: true) { _, pageLayout in
                    layoutSync.request(pageLayout, store: store)
                }
        }
        .animation(PlayerAnimation.mode, value: presentation)
        // A drag the system cancelled never reaches onEnded; don't leave the player offset.
        .onChange(of: presentation) { dragOffset = .zero }
        .onChange(of: session.request) { layoutSync.resend(store: store) }
        .onChange(of: session.playback.meta?.videoId) { layoutSync.resend(store: store) }
        .task { layoutSync.attach(store: store) }
    }

    @ViewBuilder
    private func content(layout: PlayerLayout, viewport: PresentationViewport) -> some View {
        let live = liveOffset(for: layout)
        // WebKit fullscreen (the page's own fullscreen button) covers everything; hide ours.
        let showsChrome = session.playback.presentation != .fullscreen
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)

            WebViewContainer(webView: store.browseWebView)
                .frame(width: layout.browse.width, height: layout.browse.height)
                .offset(x: layout.browse.minX, y: layout.browse.minY)
                .allowsHitTesting(layout.isBrowseInteractive)
                .accessibilityHidden(!layout.isBrowseInteractive)

            // Behind the status bar and the header/bar, so the strip above the video isn't see-through.
            Color(uiColor: .systemBackground)
                .frame(width: viewport.size.x, height: layout.chrome == .none ? 0 : (layout.chromeFrame?.maxY ?? 0))
                .opacity(layout.chrome == .header || layout.chrome == .dockedBar ? 1 : 0)
                .allowsHitTesting(false)

            // The mini-player's shadow, drawn by a sibling so the webview itself carries no shadow.
            RoundedRectangle(cornerRadius: layout.playerCornerRadius, style: .continuous)
                .fill(Color.black)
                .frame(width: layout.player.width, height: layout.player.height)
                .scaleEffect(layout.playerScale, anchor: .topLeading)
                .shadow(color: .black.opacity(layout.chrome == .mini ? 0.35 : 0), radius: 8, y: 3)
                .offset(x: layout.player.minX + live.width, y: layout.player.minY + live.height)
                .allowsHitTesting(false)

            WebViewContainer(webView: store.playerWebView)
                .frame(width: layout.player.width, height: layout.player.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: layout.playerCornerRadius, style: .continuous))
                .scaleEffect(layout.playerScale, anchor: .topLeading)
                .offset(x: layout.player.minX + live.width, y: layout.player.minY + live.height)
                // Mini: the overlay takes every touch (tap, drag), so the page never sees them.
                .allowsHitTesting(layout.isPlayerVisible && layout.chrome != .mini)
                .accessibilityHidden(!layout.isPlayerVisible)

            if showsChrome, let frame = layout.chromeFrame {
                chrome(layout.chrome, frame: frame, live: live, viewport: viewport)
            }

            #if DEBUG
            DebugPlayerMenu(store: store, session: session, viewport: viewport)
            #endif
        }
        .frame(width: viewport.size.x, height: viewport.size.y, alignment: .topLeading)
        .statusBarHidden(layout.hidesStatusBar)
        .persistentSystemOverlays(layout.hidesStatusBar ? .hidden : .automatic)
    }

    @ViewBuilder
    private func chrome(_ chrome: PlayerChrome, frame: PlanarRect, live: CGSize, viewport: PresentationViewport) -> some View {
        let actions = PlayerChromeActions(
            playback: session.playback,
            onGesture: { gesture in perform(gesture, in: viewport) },
            onPlayPause: togglePlayback,
            onPiP: startPiP
        )
        switch chrome {
        case .none:
            EmptyView()
        case .header:
            ExpandedHeader(actions: actions)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX + live.width, y: frame.minY + live.height)
                .gesture(dragGesture(viewport: viewport))
        case .dockedBar:
            DockedBar(actions: actions, meta: session.playback.meta)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX + live.width, y: frame.minY + live.height)
                .gesture(dragGesture(viewport: viewport))
        case .mini:
            MiniOverlay(actions: actions)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .offset(x: frame.minX + live.width, y: frame.minY + live.height)
                .onTapGesture { perform(.tap, in: viewport) }
                .gesture(dragGesture(viewport: viewport))
        }
    }

    // MARK: Gestures

    /// Window coordinates, so the scaled mini-player reports real points.
    private func dragGesture(viewport: PresentationViewport) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in dragOffset = value.translation }
            .onEnded { value in
                perform(.dragEnded(translation: PlanarVector(value.translation), velocity: PlanarVector(value.velocity)),
                        in: viewport)
            }
    }

    /// How the finger moves the player for the current mode: expanded and docked only follow
    /// downward (docked also sideways, for fling-to-close); mini follows freely.
    private func liveOffset(for layout: PlayerLayout) -> CGSize {
        switch layout.chrome {
        case .header: return CGSize(width: 0, height: max(0, dragOffset.height))
        case .dockedBar: return CGSize(width: dragOffset.width, height: max(0, dragOffset.height))
        case .mini: return dragOffset
        case .none: return .zero
        }
    }

    private func perform(_ gesture: PresentationGesture, in viewport: PresentationViewport) {
        let outcome = presentation.next(after: gesture, in: viewport)
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
