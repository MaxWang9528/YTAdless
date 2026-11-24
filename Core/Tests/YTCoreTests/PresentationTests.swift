// Presentation state machine and player geometry (PLAN.md §6.3). Owner: Module C.

import Testing
@testable import YTCore

typealias PresentationCorner = PlayerPresentation.Corner

/// iPhone 16-class portrait window and its landscape rotation.
private let portrait = PresentationViewport(size: PlanarVector(393, 852), safeArea: PlanarInsets(top: 59, bottom: 34))
private let landscape = PresentationViewport(size: PlanarVector(852, 393), safeArea: PlanarInsets(leading: 59, bottom: 21, trailing: 59))
private let tuning = PresentationTuning.standard

private let visibleModes: [PlayerPresentation] = [.expanded, .docked] + PresentationCorner.allCases.map { .mini($0) }
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
        #expect(mode.next(after: .closeButton, in: landscape) == .close)
    }

    @Test("collapse steps down the ladder expanded → docked → mini; mini stays put")
    func collapseLadder() {
        #expect(PlayerPresentation.expanded.next(after: .collapseButton, in: portrait) == .present(.docked))
        #expect(PlayerPresentation.docked.next(after: .collapseButton, in: portrait) == .present(.mini(.bottomTrailing)))
        for corner in PresentationCorner.allCases {
            #expect(PlayerPresentation.mini(corner).next(after: .collapseButton, in: portrait) == .present(.mini(corner)))
        }
    }

    @Test("every mode × gesture pair yields a defined outcome, and only close gestures close")
    func exhaustive() {
        let gestures: [PresentationGesture] = [.tap, .expandButton, .collapseButton, .closeButton, drag(0, 0), drag(5, 5)]
        for mode in allModes {
            for gesture in gestures {
                let outcome = mode.next(after: gesture, in: portrait)
                if outcome == .close { #expect(gesture == .closeButton, "\(mode) \(gesture)") }
            }
            // A drag that doesn't move leaves the mode alone.
            #expect(mode.next(after: drag(0, 0), in: portrait) == .present(mode), "\(mode)")
        }
    }
}

@Suite("Presentation › drags")
struct PresentationDragTests {
    @Test("expanded: a short drag down springs back")
    func expandedShortDrag() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 60), in: portrait) == .present(.expanded))
        #expect(PlayerPresentation.expanded.next(after: drag(0, -300), in: portrait) == .present(.expanded))
    }

    @Test("expanded: a slow medium drag down docks")
    func expandedDocks() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 200), in: portrait) == .present(.docked))
        #expect(PlayerPresentation.expanded.next(after: drag(0, 330), in: portrait) == .present(.docked))
    }

    @Test("expanded: a long drag or a flick down goes to the mini-player on the side it heads to")
    func expandedToMini() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 500), in: portrait) == .present(.mini(.bottomTrailing)))
        #expect(PlayerPresentation.expanded.next(after: drag(-30, 500), in: portrait) == .present(.mini(.bottomLeading)))
        // 120 pt of travel plus a 1500 pt/s flick projects ~750 pt.
        #expect(PlayerPresentation.expanded.next(after: drag(0, 120, velocity: 0, 1500), in: portrait) == .present(.mini(.bottomTrailing)))
    }

    @Test("expanded in landscape is full-screen video and ignores drags")
    func expandedLandscape() {
        #expect(PlayerPresentation.expanded.next(after: drag(0, 300, velocity: 0, 2000), in: landscape) == .present(.expanded))
    }

    @Test("docked: drag down goes to mini; a small drag stays docked")
    func dockedDrag() {
        #expect(PlayerPresentation.docked.next(after: drag(0, 40), in: portrait) == .present(.docked))
        #expect(PlayerPresentation.docked.next(after: drag(0, -200), in: portrait) == .present(.docked))
        #expect(PlayerPresentation.docked.next(after: drag(0, 400), in: portrait) == .present(.mini(.bottomTrailing)))
        #expect(PlayerPresentation.docked.next(after: drag(-120, 400), in: portrait) == .present(.mini(.bottomLeading)))
    }

    @Test("docked: a sideways fling off-screen closes")
    func dockedFling() {
        #expect(PlayerPresentation.docked.next(after: drag(150, 0, velocity: 1500, 0), in: portrait) == .close)
        #expect(PlayerPresentation.docked.next(after: drag(-150, 0, velocity: -1500, 0), in: portrait) == .close)
        #expect(PlayerPresentation.docked.next(after: drag(60, 0), in: portrait) == .present(.docked))
    }

    @Test("mini: a drag snaps to the quadrant the centre comes to rest in")
    func miniSnaps() {
        let from = PlayerPresentation.mini(.bottomTrailing)
        #expect(from.next(after: drag(0, -20), in: portrait) == .present(.mini(.bottomTrailing)))
        #expect(from.next(after: drag(-180, 0), in: portrait) == .present(.mini(.bottomLeading)))
        #expect(from.next(after: drag(0, -500), in: portrait) == .present(.mini(.topTrailing)))
        #expect(from.next(after: drag(-180, -500), in: portrait) == .present(.mini(.topLeading)))
        // Velocity alone carries it: 40 pt of travel, 1200 pt/s up → ~600 pt.
        #expect(from.next(after: drag(0, -40, velocity: 0, -1200), in: portrait) == .present(.mini(.topTrailing)))
    }

    @Test("realistic repositioning flicks snap, never close (regressions)")
    func flicksSnap() {
        // A toss across the screen lands in the far corner.
        #expect(PlayerPresentation.mini(.bottomTrailing).next(after: drag(-120, 0, velocity: -900, 0), in: portrait) == .present(.mini(.bottomLeading)))
        #expect(PlayerPresentation.mini(.bottomTrailing).next(after: drag(-120, 0, velocity: -400, 0), in: portrait) == .present(.mini(.bottomLeading)))
        #expect(PlayerPresentation.mini(.bottomTrailing).next(after: drag(0, -100, velocity: 0, -1500), in: portrait) == .present(.mini(.topTrailing)))
        #expect(PlayerPresentation.mini(.bottomTrailing).next(after: drag(-150, -300, velocity: -2500, -4000), in: portrait) == .present(.mini(.topLeading)))
        #expect(PlayerPresentation.mini(.topLeading).next(after: drag(150, 0, velocity: 2500, 0), in: portrait) == .present(.mini(.topTrailing)))
        #expect(PlayerPresentation.mini(.topLeading).next(after: drag(0, 200, velocity: 0, 3000), in: portrait) == .present(.mini(.bottomLeading)))
        // A diagonal pull down from docked goes to mini.
        #expect(PlayerPresentation.docked.next(after: drag(40, 300, velocity: 500, 1500), in: portrait) == .present(.mini(.bottomTrailing)))
        #expect(PlayerPresentation.docked.next(after: drag(-90, 250, velocity: -800, 1200), in: portrait) == .present(.mini(.bottomLeading)))
        // A quick sideways flick without real travel doesn't close the docked player.
        #expect(PlayerPresentation.docked.next(after: drag(30, 0, velocity: 2000, 0), in: portrait) == .present(.docked))
    }

    @Test("snapCorner clamps the projected point into the container first")
    func snapClamps() {
        let c = portrait.size
        #expect(MiniPlayerGeometry.snapCorner(restingCenter: PlanarVector(-500, 700), container: c) == .bottomLeading)
        #expect(MiniPlayerGeometry.snapCorner(restingCenter: PlanarVector(900, -50), container: c) == .topTrailing)
    }

    @Test("leavesThroughNearEdge only counts the two edges the corner sits against")
    func nearEdges() {
        let c = portrait.size
        #expect(MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(400, 700), corner: .bottomTrailing, container: c))
        #expect(MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(300, 900), corner: .bottomTrailing, container: c))
        #expect(!MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(-10, 700), corner: .bottomTrailing, container: c))
        #expect(!MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(300, -10), corner: .bottomTrailing, container: c))
        #expect(MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(-10, 100), corner: .topLeading, container: c))
        #expect(!MiniPlayerGeometry.leavesThroughNearEdge(PlanarVector(400, 900), corner: .topLeading, container: c))
    }

    @Test("mini: a fling that carries the centre out through its own edges closes", arguments: PresentationCorner.allCases)
    func miniFlingCloses(corner: PresentationCorner) {
        let mini = PlayerPresentation.mini(corner)
        let towardsEdge: Double = (corner == .topLeading || corner == .bottomLeading) ? -1 : 1
        #expect(mini.next(after: drag(towardsEdge * 60, 0, velocity: towardsEdge * 1500, 0), in: portrait) == .close)
        let down: Double = (corner == .topLeading || corner == .topTrailing) ? -1 : 1
        #expect(mini.next(after: drag(0, down * 40, velocity: 0, down * 1500), in: portrait) == .close)
        // A slow drag that stays on screen never closes.
        #expect(mini.next(after: drag(towardsEdge * 20, 0), in: portrait) == .present(mini))
    }
}

@Suite("Presentation › geometry")
struct PresentationGeometryTests {
    @Test("docked height is 16:9 of the width, rounded")
    func dockedHeight() {
        #expect(MiniPlayerGeometry.dockedHeight(forWidth: 393) == 221)
        #expect(MiniPlayerGeometry.dockedHeight(forWidth: 320) == 180)
        #expect(MiniPlayerGeometry.dockedHeight(forWidth: 0) == 0)
    }

    @Test("docked video is full width in portrait and capped at half the height in landscape")
    func dockedVideoSize() {
        #expect(MiniPlayerGeometry.dockedVideoSize(in: portrait) == PlanarVector(393, 221))
        let wide = MiniPlayerGeometry.dockedVideoSize(in: landscape)
        #expect(wide.y == 197)  // 393 · 0.5, rounded
        #expect(approx(wide.x / wide.y, 16.0 / 9.0, 0.01))
        #expect(wide.x < landscape.size.x)
    }

    @Test("projection follows UIScrollView deceleration: v/1000 · r/(1−r)")
    func projection() {
        let p = MiniPlayerGeometry.projectionDistance(velocity: PlanarVector(1000, -2000), decelerationRate: 0.998)
        #expect(approx(p.x, 499) && approx(p.y, -998))
        #expect(MiniPlayerGeometry.projectionDistance(velocity: PlanarVector(1000, 0), decelerationRate: 1) == .zero)
        #expect(MiniPlayerGeometry.projectionDistance(velocity: .zero) == .zero)
    }

    @Test("snapCorner projects the release point, then picks its quadrant")
    func snapCorner() {
        let container = portrait.size
        #expect(MiniPlayerGeometry.snapCorner(position: PlanarVector(100, 100), velocity: .zero, container: container) == .topLeading)
        #expect(MiniPlayerGeometry.snapCorner(position: PlanarVector(300, 700), velocity: .zero, container: container) == .bottomTrailing)
        #expect(MiniPlayerGeometry.snapCorner(position: PlanarVector(100, 700), velocity: PlanarVector(800, -1000), container: container) == .topTrailing)
    }

    @Test("off-screen means the centre is outside the container")
    func offScreen() {
        let c = portrait.size
        #expect(!MiniPlayerGeometry.isOffScreen(PlanarVector(0, 0), container: c))
        #expect(!MiniPlayerGeometry.isOffScreen(PlanarVector(393, 852), container: c))
        #expect(MiniPlayerGeometry.isOffScreen(PlanarVector(-1, 400), container: c))
        #expect(MiniPlayerGeometry.isOffScreen(PlanarVector(200, 853), container: c))
    }

    @Test("mini frames sit inside the safe area, clear of YouTube's bars, and keep 16:9", arguments: PresentationCorner.allCases)
    func miniFrames(corner: PresentationCorner) {
        for viewport in [portrait, landscape] {
            let frame = MiniPlayerGeometry.miniFrame(corner, in: viewport)
            let safe = viewport.safeArea
            #expect(frame.minX >= safe.leading + tuning.miniMargin - 0.001)
            #expect(frame.maxX <= viewport.size.x - safe.trailing - tuning.miniMargin + 0.001)
            #expect(frame.minY >= safe.top + tuning.miniTopClearance)
            #expect(frame.maxY <= viewport.size.y - safe.bottom - tuning.miniBottomClearance)
            #expect(approx(frame.width / frame.height, MiniPlayerGeometry.dockedVideoSize(in: viewport).x / MiniPlayerGeometry.dockedVideoSize(in: viewport).y))
            #expect(frame.width <= tuning.miniMaxWidth)
            // Each corner frame lies in its own quadrant, so snapping from it is stable.
            #expect(MiniPlayerGeometry.nearestCorner(to: frame.center, container: viewport.size) == corner)
        }
    }

    @Test("mini is 50% of the short side in portrait, capped at 240 pt")
    func miniWidth() {
        #expect(approx(MiniPlayerGeometry.miniFrame(.bottomTrailing, in: portrait).width, 196.5))
        let big = PresentationViewport(size: PlanarVector(600, 1000))
        #expect(approx(MiniPlayerGeometry.miniFrame(.bottomTrailing, in: big).width, 240))
    }
}

@Suite("Presentation › layout")
struct PresentationLayoutTests {
    @Test("hidden: player off-screen below at full size, browse full screen and interactive")
    func hidden() {
        let l = PresentationLayout.layout(for: .hidden, in: portrait)
        #expect(l.player == PlanarRect(x: 0, y: 852, width: 393, height: 852))
        #expect(l.player.minY >= portrait.size.y)
        #expect(l.browse == portrait.bounds)
        #expect(!l.isPlayerVisible && l.isBrowseInteractive && l.chrome == .none)
    }

    @Test("expanded (portrait): header under the status bar, watch page below it, page layout")
    func expanded() {
        let l = PresentationLayout.layout(for: .expanded, in: portrait)
        #expect(l.chrome == .header)
        #expect(l.chromeFrame == PlanarRect(x: 0, y: 59, width: 393, height: tuning.headerHeight))
        #expect(l.player == PlanarRect(x: 0, y: 95, width: 393, height: 757))
        #expect(l.playerScale == 1)
        #expect(l.pageLayout == .page)
        #expect(!l.isBrowseInteractive && !l.hidesStatusBar)
    }

    @Test("expanded (landscape): full-screen video, no chrome, no status bar")
    func expandedLandscape() {
        let l = PresentationLayout.layout(for: .expanded, in: landscape)
        #expect(l.player == landscape.bounds)
        #expect(l.chrome == .none && l.chromeFrame == nil)
        #expect(l.pageLayout == .video)
        #expect(l.hidesStatusBar)
    }

    @Test("docked: 16:9 strip under the status bar, control bar, browse fills the rest")
    func docked() {
        let l = PresentationLayout.layout(for: .docked, in: portrait)
        #expect(l.player == PlanarRect(x: 0, y: 59, width: 393, height: 221))
        #expect(l.chromeFrame == PlanarRect(x: 0, y: 280, width: 393, height: tuning.dockedBarHeight))
        #expect(l.browse.minY == 280 + tuning.dockedBarHeight)
        #expect(l.browse.maxY == 852)
        #expect(l.pageLayout == .video && l.isBrowseInteractive && l.chrome == .dockedBar)
    }

    @Test("docked (landscape): centred, capped strip")
    func dockedLandscape() {
        let l = PresentationLayout.layout(for: .docked, in: landscape)
        #expect(l.player.height == 197)
        #expect(approx(l.player.center.x, landscape.size.x / 2, 1))
        #expect(l.browse.maxY == landscape.size.y && l.browse.height > 0)
    }

    @Test("mini: the docked-size page, scaled — no reflow between docked and mini", arguments: PresentationCorner.allCases)
    func mini(corner: PresentationCorner) {
        for viewport in [portrait, landscape] {
            let docked = PresentationLayout.layout(for: .docked, in: viewport)
            let l = PresentationLayout.layout(for: .mini(corner), in: viewport)
            #expect(l.player.size == docked.player.size, "same unscaled size as docked")
            #expect(l.playerScale < 1)
            #expect(l.playerVisualFrame == MiniPlayerGeometry.miniFrame(corner, in: viewport))
            #expect(l.chromeFrame == l.playerVisualFrame)
            #expect(approx(l.playerCornerRadius * l.playerScale, tuning.miniCornerRadius))
            #expect(l.browse == viewport.bounds && l.isBrowseInteractive && l.pageLayout == .video)
        }
    }

    @Test("page layout: page only when expanded in portrait (or hidden)")
    func pageLayout() {
        for mode in allModes {
            let expect: PageLayout = (mode == .expanded || mode == .hidden) ? .page : .video
            #expect(PresentationLayout.layout(for: mode, in: portrait).pageLayout == expect, "\(mode)")
        }
        #expect(PresentationLayout.layout(for: .expanded, in: landscape).pageLayout == .video)
    }

    @Test("visible modes put the player on screen; only hidden takes it off")
    func visibility() {
        for viewport in [portrait, landscape] {
            for mode in visibleModes {
                let l = PresentationLayout.layout(for: mode, in: viewport)
                #expect(l.isPlayerVisible, "\(mode)")
                let f = l.playerVisualFrame
                #expect(f.minX >= 0 && f.minY >= 0 && f.maxX <= viewport.size.x + 0.001 && f.maxY <= viewport.size.y + 0.001, "\(mode)")
            }
        }
    }
}
