// Presentation state machine and player geometry (PLAN.md §6.3). Owner: Module C.
// App-style UI: expanded watch view, and a mini bar above m.youtube.com's bottom nav.

import Testing
@testable import YTCore

/// iPhone 16-class portrait window and its landscape rotation.
private let portrait = PresentationViewport(size: PlanarVector(393, 852), safeArea: PlanarInsets(top: 59, bottom: 34))
private let landscape = PresentationViewport(size: PlanarVector(852, 393), safeArea: PlanarInsets(leading: 59, bottom: 21, trailing: 59))
private let tuning = PresentationTuning.standard

/// Every mode the frozen contract has that is drawn as the mini bar.
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

    @Test("collapse goes to the mini bar", arguments: visibleModes)
    func collapse(mode: PlayerPresentation) {
        #expect(mode.next(after: .collapseButton, in: portrait) == .present(.miniBar))
    }

    @Test("expanded › a short drag down springs back")
    func expandedShortDrag() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 40), in: portrait) == .present(.expanded))
        #expect(PlayerPresentation.expanded.next(after: drag(0, -300), in: portrait) == .present(.expanded))
    }

    @Test("expanded › a drag or flick down minimizes to the bar")
    func expandedDragDown() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 200), in: portrait) == .present(.miniBar))
        #expect(PlayerPresentation.expanded.next(after: drag(0, 20, velocity: 0, 1500), in: portrait) == .present(.miniBar))
    }

    @Test("expanded in landscape ignores drags")
    func landscapeIgnoresDrags() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 300, velocity: 0, 3000), in: landscape) == .present(.expanded))
    }

    @Test("mini bar › drag up expands", arguments: miniModes)
    func miniDragUp(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(0, -120), in: portrait) == .present(.expanded))
        #expect(mode.next(after: drag(0, -10, velocity: 0, -1500), in: portrait) == .present(.expanded))
    }

    @Test("mini bar › drag down closes", arguments: miniModes)
    func miniDragDown(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(0, 120), in: portrait) == .close)
    }

    @Test("mini bar › a sideways fling closes, a small one stays", arguments: miniModes)
    func miniSideways(mode: PlayerPresentation) {
        #expect(mode.next(after: drag(150, 5, velocity: 2000, 0), in: portrait) == .close)
        #expect(mode.next(after: drag(-150, 5, velocity: -2000, 0), in: portrait) == .close)
        #expect(mode.next(after: drag(30, 5), in: portrait) == .present(mode))
        // Diagonal: neither clearly sideways nor far enough vertically.
        #expect(mode.next(after: drag(90, 60), in: portrait) == .present(mode))
    }

    @Test("isMiniBar covers docked and every corner, nothing else")
    func isMiniBar() {
        for mode in miniModes { #expect(mode.isMiniBar) }
        #expect(!PlayerPresentation.expanded.isMiniBar)
        #expect(!PlayerPresentation.hidden.isMiniBar)
        #expect(PlayerPresentation.miniBar.isMiniBar)
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

    @Test("the bar sits right above the bottom nav and the safe area")
    func barFrame() {
        let bar = MiniPlayerGeometry.barFrame(in: portrait)
        #expect(bar.maxY == 852 - 34 - tuning.bottomNavHeight)
        #expect(bar.height == tuning.miniBarHeight)
        #expect(bar.minX == 0 && bar.width == 393)
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

    @Test("mini bar: the scaled video fills the bar's height on its left; browse stays interactive", arguments: miniModes)
    func miniBar(mode: PlayerPresentation) {
        for viewport in [portrait, landscape] {
            let layout = PresentationLayout.layout(for: mode, in: viewport)
            let bar = MiniPlayerGeometry.barFrame(in: viewport)
            #expect(layout.chrome == .miniBar)
            #expect(layout.chromeFrame == bar)
            #expect(layout.pageLayout == .video)
            #expect(layout.isBrowseInteractive)
            #expect(layout.browse == viewport.bounds)
            let visual = layout.playerVisualFrame
            #expect(visual.minX == viewport.safeArea.leading)
            #expect(visual.minY == bar.minY)
            #expect(approx(visual.height, tuning.miniBarHeight - tuning.progressHeight, 0.01))
            #expect(visual.width < viewport.size.x / 3)
        }
    }

    @Test("all mini-bar modes share one layout, so switching between them never moves the player")
    func miniModesIdentical() {
        let reference = PresentationLayout.layout(for: .miniBar, in: portrait)
        for mode in miniModes { #expect(PresentationLayout.layout(for: mode, in: portrait) == reference) }
    }
}
