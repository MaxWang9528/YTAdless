// Presentation state machine and player geometry (PLAN.md §6.3). Owner: Module C.
// App-style UI: expanded watch view, and a floating mini player bottom-right, above m.youtube.com's bottom nav.

import Testing
@testable import YTCore

/// iPhone 16-class portrait window and its landscape rotation.
private let portrait = PresentationViewport(size: PlanarVector(393, 852), safeArea: PlanarInsets(top: 59, bottom: 34))
private let landscape = PresentationViewport(size: PlanarVector(852, 393), safeArea: PlanarInsets(leading: 59, bottom: 21, trailing: 59))
private let tuning = PresentationTuning.standard

/// Every mode the frozen contract has that is drawn as the mini player.
private let miniModes: [PlayerPresentation] = [.docked] + PlayerPresentation.Corner.allCases.map { .mini($0) }
private let visibleModes: [PlayerPresentation] = [.expanded] + miniModes
private let allModes: [PlayerPresentation] = [.hidden] + visibleModes

private func drag(_ dx: Double, _ dy: Double, velocity vx: Double = 0, _ vy: Double = 0) -> PresentationGesture {
    .dragEnded(translation: PlanarVector(dx, dy), velocity: PlanarVector(vx, vy))
}

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

@Suite("Presentation › state machine")
struct PresentationStateMachineTests {
    @Test("hidden ignores every gesture", arguments: [
        PresentationGesture.tap, .expandButton, .collapseButton, .closeButton, drag(0, 500, velocity: 0, 3000),
    ])
    func hiddenIgnores(gesture: PresentationGesture) {
        #expect(PlayerPresentation.hidden.next(after: gesture, in: portrait) == .present(.hidden))
    }

    @Test("tap and expand open the full player from every visible mode", arguments: visibleModes)
    func tapExpands(mode: PlayerPresentation) {
        #expect(mode.next(after: .tap, in: portrait) == .present(.expanded))
        #expect(mode.next(after: .expandButton, in: portrait) == .present(.expanded))
        #expect(mode.next(after: .expandButton, in: landscape) == .present(.expanded))
    }

    @Test("close asks for close(), never just .hidden", arguments: visibleModes)
    func closeCloses(mode: PlayerPresentation) {
        #expect(mode.next(after: .closeButton, in: portrait) == .close)
    }

    @Test("collapse goes to the mini player", arguments: visibleModes)
    func collapse(mode: PlayerPresentation) {
        #expect(mode.next(after: .collapseButton, in: portrait) == .present(.miniPlayer))
    }

    @Test("expanded › a short drag down springs back")
    func expandedShortDrag() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 40), in: portrait) == .present(.expanded))
        #expect(PlayerPresentation.expanded.next(after: drag(0, -300), in: portrait) == .present(.expanded))
    }

    @Test("expanded › a drag or flick down minimizes to the mini player")
    func expandedDragDown() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 200), in: portrait) == .present(.miniPlayer))
        #expect(PlayerPresentation.expanded.next(after: drag(0, 20, velocity: 0, 1500), in: portrait) == .present(.miniPlayer))
    }

    @Test("expanded in landscape ignores drags")
    func landscapeIgnoresDrags() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 300, velocity: 0, 3000), in: landscape) == .present(.expanded))
    }

    @Test("mini player › drag up expands", arguments: miniModes)
    func miniDragUp(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(0, -120), in: portrait) == .present(.expanded))
        #expect(mode.next(after: drag(0, -10, velocity: 0, -1500), in: portrait) == .present(.expanded))
    }

    @Test("mini player › drag down closes", arguments: miniModes)
    func miniDragDown(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(0, 120), in: portrait) == .close)
    }

    @Test("mini player › a sideways fling closes, a small one stays", arguments: miniModes)
    func miniSideways(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(150, 5, velocity: 2000, 0), in: portrait) == .close)
        #expect(mode.next(after: drag(-150, 5, velocity: -2000, 0), in: portrait) == .close)
        #expect(mode.next(after: drag(30, 5), in: portrait) == .present(mode))
        // Diagonal: neither clearly sideways nor far enough vertically.
        #expect(mode.next(after: drag(90, 60), in: portrait) == .present(mode))
    }

    @Test("isMini covers docked and every corner, nothing else; the one produced is bottom-trailing")
    func isMini() {
        for mode in miniModes { #expect(mode.isMini) }
        #expect(!PlayerPresentation.expanded.isMini)
        #expect(!PlayerPresentation.hidden.isMini)
        #expect(PlayerPresentation.miniPlayer == .mini(.bottomTrailing))
    }
}

@Suite("Presentation › geometry")
struct PresentationGeometryTests {
    @Test("projection follows UIScrollView deceleration")
    func projection() {
        let d = MiniPlayerGeometry.projectionDistance(velocity: PlanarVector(1000, -1000))
        #expect(approx(d.x, 499))
        #expect(approx(d.y, -499))
        #expect(MiniPlayerGeometry.projectionDistance(velocity: PlanarVector(1000, 0), decelerationRate: 1) == .zero)
    }

    @Test("the video lays out at full width 16:9 in portrait, capped to half the height in landscape")
    func videoSize() {
        #expect(MiniPlayerGeometry.videoSize(in: portrait) == PlanarVector(393, 221))
        let l = MiniPlayerGeometry.videoSize(in: landscape)
        #expect(l.y <= 393 / 2 + 1)
        #expect(approx(l.x / l.y, 16.0 / 9, 0.02))
    }

    @Test("the mini player floats bottom-right, above the bottom nav, inside the safe area")
    func miniFrame() {
        let mini = MiniPlayerGeometry.miniFrame(in: portrait)
        #expect(mini.maxY == 852 - 34 - tuning.bottomNavHeight - tuning.miniMargin)
        #expect(mini.maxX == 393 - tuning.miniMargin)
        #expect(mini.width == (393 * tuning.miniWidthFraction).rounded())
        #expect(approx(mini.width / mini.height, 16.0 / 9, 0.02))
        let l = MiniPlayerGeometry.miniFrame(in: landscape)
        #expect(l.maxX == 852 - 59 - tuning.miniMargin)
        #expect(l.width == (393 * tuning.miniWidthFraction).rounded(), "sized by the short side, same as portrait")
        #expect(l.minY >= 0)
    }

    @Test("progress is clamped, and 0 without a usable duration")
    func progress() {
        #expect(MiniPlayerGeometry.progress(position: 30, duration: 120) == 0.25)
        #expect(MiniPlayerGeometry.progress(position: 500, duration: 120) == 1)
        #expect(MiniPlayerGeometry.progress(position: -3, duration: 120) == 0)
        #expect(MiniPlayerGeometry.progress(position: 30, duration: nil) == 0)
        #expect(MiniPlayerGeometry.progress(position: 30, duration: 0) == 0)
        #expect(MiniPlayerGeometry.progress(position: 30, duration: .infinity) == 0)
    }
}

@Suite("Presentation › layout")
struct PresentationLayoutTests {
    @Test("every mode keeps the player full-size or scaled, never reflowed to a tiny width", arguments: allModes)
    func playerNeverTiny(mode: PlayerPresentation) {
        for viewport in [portrait, landscape] {
            let layout = PresentationLayout.layout(for: mode, in: viewport)
            #expect(layout.player.width >= 300, "\(mode) lays the page out at \(layout.player.width) pt")
        }
    }

    @Test("hidden is off-screen below, full size, browse takes touches")
    func hidden() {
        let layout = PresentationLayout.layout(for: .hidden, in: portrait)
        #expect(layout.player.minY == 852)
        #expect(layout.player.size == portrait.size)
        #expect(!layout.isPlayerVisible)
        #expect(layout.isBrowseInteractive)
        #expect(layout.chrome == .none)
    }

    @Test("expanded portrait: header under the status bar, watch page below, browse covered")
    func expandedPortrait() {
        let layout = PresentationLayout.layout(for: .expanded, in: portrait)
        #expect(layout.chrome == .header)
        #expect(layout.chromeFrame == PlanarRect(x: 0, y: 59, width: 393, height: tuning.headerHeight))
        #expect(layout.player.minY == 59 + tuning.headerHeight)
        #expect(layout.player.maxY == 852)
        #expect(layout.pageLayout == .page)
        #expect(!layout.isBrowseInteractive)
        #expect(layout.playerScale == 1)
    }

    @Test("expanded landscape: full-screen video, no chrome, status bar hidden")
    func expandedLandscape() {
        let layout = PresentationLayout.layout(for: .expanded, in: landscape)
        #expect(layout.player == landscape.bounds)
        #expect(layout.chrome == .none)
        #expect(layout.pageLayout == .video)
        #expect(layout.hidesStatusBar)
    }

    @Test("mini player: the scaled video fills the floating frame; browse stays interactive", arguments: miniModes)
    func miniPlayer(mode: PlayerPresentation) {
        for viewport in [portrait, landscape] {
            let layout = PresentationLayout.layout(for: mode, in: viewport)
            let mini = MiniPlayerGeometry.miniFrame(in: viewport)
            #expect(layout.chrome == .miniPlayer)
            #expect(layout.chromeFrame == mini)
            #expect(layout.pageLayout == .video)
            #expect(layout.isBrowseInteractive)
            #expect(layout.browse == viewport.bounds)
            let visual = layout.playerVisualFrame
            #expect(visual.origin == mini.origin)
            #expect(approx(visual.width, mini.width, 0.01))
            #expect(approx(visual.height, mini.height, 1))
            #expect(visual.minX > viewport.size.x / 3, "on the right side")
            #expect(approx(layout.playerCornerRadius * layout.playerScale, tuning.miniCornerRadius))
        }
    }

    @Test("all mini modes share one layout, so switching between them never moves the player")
    func miniModesIdentical() {
        let reference = PresentationLayout.layout(for: .miniPlayer, in: portrait)
        for mode in miniModes { #expect(PresentationLayout.layout(for: mode, in: portrait) == reference) }
    }
}
