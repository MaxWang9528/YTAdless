// Presentation state machine + player geometry — owner: Module C (PLAN.md §6.3).
//
// Everything PlayerLayoutView decides is computed here, so it is tested on Linux and the view
// stays a thin adapter: where each webview container goes in each mode (`PresentationLayout`),
// which page layout the player page gets, and what a gesture or button does (`next(after:in:)`).
// Plain Doubles rather than CoreGraphics types: CGSize/CGPoint conformances differ between Darwin
// and Linux Foundation.
//
// Transition table (portrait; `drag` = release point projected with UIScrollView deceleration):
//
// | from       | tap / expand | collapse   | close | drag                                                   |
// |------------|--------------|------------|-------|--------------------------------------------------------|
// | hidden     | hidden       | hidden     | hidden| hidden                                                 |
// | expanded   | expanded     | docked     | close | down < cancel: expanded · < dockFraction·H: docked · else mini(nearest corner) |
// | docked     | expanded     | mini(↘)    | close | sideways off-screen: close · down ≥ cancel: mini(nearest corner) · else docked |
// | mini(c)    | expanded     | mini(c)    | close | centre projected off-screen: close · else mini(nearest corner) |
//
// Expanded in landscape is a full-screen video with no native chrome, so it ignores drags.

import Foundation

// MARK: - Geometry primitives

/// A 2-D point, size or velocity in points (points/second for velocities).
public struct PlanarVector: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PlanarVector(0, 0)

    public static func + (a: PlanarVector, b: PlanarVector) -> PlanarVector { PlanarVector(a.x + b.x, a.y + b.y) }
    public static func - (a: PlanarVector, b: PlanarVector) -> PlanarVector { PlanarVector(a.x - b.x, a.y - b.y) }
    public static func * (a: PlanarVector, k: Double) -> PlanarVector { PlanarVector(a.x * k, a.y * k) }
}

/// An axis-aligned rectangle; `origin` is the top-leading corner.
public struct PlanarRect: Equatable, Hashable, Sendable {
    public var origin: PlanarVector
    public var size: PlanarVector

    public init(origin: PlanarVector, size: PlanarVector) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: PlanarVector(x, y), size: PlanarVector(width, height))
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.x }
    public var maxY: Double { origin.y + size.y }
    public var width: Double { size.x }
    public var height: Double { size.y }
    public var center: PlanarVector { PlanarVector(origin.x + size.x / 2, origin.y + size.y / 2) }
}

/// Safe-area insets in points.
public struct PlanarInsets: Equatable, Hashable, Sendable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = PlanarInsets()
}

/// The space PlayerLayoutView lays out in: the whole window (it ignores the safe area itself)
/// plus the window's safe-area insets.
public struct PresentationViewport: Equatable, Hashable, Sendable {
    public var size: PlanarVector
    public var safeArea: PlanarInsets

    public init(size: PlanarVector, safeArea: PlanarInsets = .zero) {
        self.size = size
        self.safeArea = safeArea
    }

    public var isLandscape: Bool { size.x > size.y }
    public var bounds: PlanarRect { PlanarRect(origin: .zero, size: size) }
}

// MARK: - Tuning

/// Every number the player UI uses. Defaults are first guesses, to be tuned on device (S-C1).
public struct PresentationTuning: Equatable, Sendable {
    /// Native strip above the expanded watch page (grabber, collapse, close).
    public var headerHeight: Double
    /// Native control bar under the docked video (title, play/pause, PiP, expand, close).
    public var dockedBarHeight: Double
    /// In landscape the docked video is at most this fraction of the height.
    public var dockedMaxHeightFraction: Double
    /// Mini-player width as a fraction of the viewport's shorter side, capped by `miniMaxWidth`.
    public var miniWidthFraction: Double
    public var miniMaxWidth: Double
    /// Gap between the mini-player and the safe area.
    public var miniMargin: Double
    /// Extra clearance at the top and bottom so the mini-player doesn't cover YouTube's top bar
    /// (48 pt: `.sticky-player{top:48px}`, mweb CSS 2026-11-24) or its bottom pivot bar.
    public var miniTopClearance: Double
    public var miniBottomClearance: Double
    /// Corner radius of the mini-player, in visual (scaled) points.
    public var miniCornerRadius: Double
    /// UIScrollView.DecelerationRate.normal; used to project a release point from velocity.
    public var decelerationRate: Double
    /// A drag whose projected travel is shorter than this changes nothing.
    public var dragCancelDistance: Double
    /// Expanded: a projected drag down shorter than this fraction of the height docks;
    /// a longer one goes to mini.
    public var dockFraction: Double

    public init(
        headerHeight: Double = 36,
        dockedBarHeight: Double = 52,
        dockedMaxHeightFraction: Double = 0.5,
        miniWidthFraction: Double = 0.5,
        miniMaxWidth: Double = 240,
        miniMargin: Double = 12,
        miniTopClearance: Double = 48,
        miniBottomClearance: Double = 56,
        miniCornerRadius: Double = 10,
        decelerationRate: Double = 0.998,
        dragCancelDistance: Double = 80,
        dockFraction: Double = 0.4
    ) {
        self.headerHeight = headerHeight
        self.dockedBarHeight = dockedBarHeight
        self.dockedMaxHeightFraction = dockedMaxHeightFraction
        self.miniWidthFraction = miniWidthFraction
        self.miniMaxWidth = miniMaxWidth
        self.miniMargin = miniMargin
        self.miniTopClearance = miniTopClearance
        self.miniBottomClearance = miniBottomClearance
        self.miniCornerRadius = miniCornerRadius
        self.decelerationRate = decelerationRate
        self.dragCancelDistance = dragCancelDistance
        self.dockFraction = dockFraction
    }

    public static let standard = PresentationTuning()
}

// MARK: - State machine

/// A gesture or control that may change the player's presentation.
public enum PresentationGesture: Equatable, Sendable {
    /// A tap on the docked bar or the mini-player.
    case tap
    /// A drag on the expanded header, the docked bar or the mini-player, in window points.
    case dragEnded(translation: PlanarVector, velocity: PlanarVector)
    case expandButton
    /// The chevron: one step down the ladder expanded → docked → mini.
    case collapseButton
    case closeButton
}

/// What a gesture asks for. `close` is separate from `.present(.hidden)` because closing has to
/// go through `PlayerControlling.close()` (pause, blank the page), not just hide the view.
public enum PresentationOutcome: Equatable, Sendable {
    case present(PlayerPresentation)
    case close
}

extension PlayerPresentation {
    public var isVisible: Bool { self != .hidden }

    /// The transition table at the top of this file.
    public func next(
        after gesture: PresentationGesture,
        in viewport: PresentationViewport,
        tuning: PresentationTuning = .standard
    ) -> PresentationOutcome {
        if self == .hidden { return .present(.hidden) }
        switch gesture {
        case .tap, .expandButton:
            return .present(.expanded)
        case .closeButton:
            return .close
        case .collapseButton:
            switch self {
            case .expanded: return .present(.docked)
            case .docked: return .present(.mini(.bottomTrailing))
            default: return .present(self)
            }
        case .dragEnded(let translation, let velocity):
            return dragEnded(translation: translation, velocity: velocity, in: viewport, tuning: tuning)
        }
    }

    private func dragEnded(
        translation: PlanarVector,
        velocity: PlanarVector,
        in viewport: PresentationViewport,
        tuning: PresentationTuning
    ) -> PresentationOutcome {
        let travel = translation + MiniPlayerGeometry.projectionDistance(velocity: velocity, decelerationRate: tuning.decelerationRate)
        let layout = PresentationLayout.layout(for: self, in: viewport, tuning: tuning)
        // Where the centre of the player would come to rest.
        let restingCenter = layout.playerVisualFrame.center + travel
        switch self {
        case .hidden:
            return .present(.hidden)
        case .expanded:
            if viewport.isLandscape || travel.y < tuning.dragCancelDistance { return .present(.expanded) }
            if travel.y < viewport.size.y * tuning.dockFraction { return .present(.docked) }
            return .present(.mini(MiniPlayerGeometry.nearestCorner(to: restingCenter, container: viewport.size)))
        case .docked:
            if MiniPlayerGeometry.isOffScreen(PlanarVector(restingCenter.x, layout.playerVisualFrame.center.y), container: viewport.size) {
                return .close
            }
            if travel.y < tuning.dragCancelDistance { return .present(.docked) }
            return .present(.mini(MiniPlayerGeometry.nearestCorner(to: restingCenter, container: viewport.size)))
        case .mini:
            if MiniPlayerGeometry.isOffScreen(restingCenter, container: viewport.size) { return .close }
            return .present(.mini(MiniPlayerGeometry.nearestCorner(to: restingCenter, container: viewport.size)))
        }
    }
}

// MARK: - Mini-player geometry

public enum MiniPlayerGeometry {
    /// Height of the docked 16:9 strip for a given container width.
    public static func dockedHeight(forWidth width: Double) -> Double {
        (width * 9 / 16).rounded()
    }

    /// The unscaled size of the docked video, which the mini-player reuses with a scale so the
    /// page doesn't reflow (§6.3). Full width in portrait; in landscape at most
    /// `dockedMaxHeightFraction` of the height, keeping 16:9.
    public static func dockedVideoSize(in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> PlanarVector {
        let width = viewport.size.x
        let height = dockedHeight(forWidth: width)
        let maxHeight = (viewport.size.y * tuning.dockedMaxHeightFraction).rounded()
        guard height > maxHeight, maxHeight > 0 else { return PlanarVector(width, height) }
        return PlanarVector((maxHeight * 16 / 9).rounded(), maxHeight)
    }

    /// The scale that turns the docked video into the mini-player.
    public static func miniScale(in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> Double {
        let docked = dockedVideoSize(in: viewport, tuning: tuning)
        guard docked.x > 0 else { return 1 }
        let shortSide = min(viewport.size.x, viewport.size.y)
        let width = min(shortSide * tuning.miniWidthFraction, tuning.miniMaxWidth)
        return min(1, width / docked.x)
    }

    /// The on-screen (scaled) frame of the mini-player in `corner`.
    public static func miniFrame(_ corner: PlayerPresentation.Corner, in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> PlanarRect {
        let docked = dockedVideoSize(in: viewport, tuning: tuning)
        let size = docked * miniScale(in: viewport, tuning: tuning)
        let safe = viewport.safeArea
        let left = safe.leading + tuning.miniMargin
        let right = viewport.size.x - safe.trailing - tuning.miniMargin - size.x
        let top = safe.top + tuning.miniTopClearance + tuning.miniMargin
        let bottom = viewport.size.y - safe.bottom - tuning.miniBottomClearance - tuning.miniMargin - size.y
        switch corner {
        case .topLeading: return PlanarRect(origin: PlanarVector(left, top), size: size)
        case .topTrailing: return PlanarRect(origin: PlanarVector(right, top), size: size)
        case .bottomLeading: return PlanarRect(origin: PlanarVector(left, bottom), size: size)
        case .bottomTrailing: return PlanarRect(origin: PlanarVector(right, bottom), size: size)
        }
    }

    /// How far a release at `velocity` (pt/s) carries on with UIScrollView-style deceleration
    /// (`v / 1000 · r / (1 − r)`, the formula from Apple's WWDC 2018 "Designing Fluid Interfaces").
    public static func projectionDistance(velocity: PlanarVector, decelerationRate: Double = PresentationTuning.standard.decelerationRate) -> PlanarVector {
        guard decelerationRate > 0, decelerationRate < 1 else { return .zero }
        return velocity * (decelerationRate / (1 - decelerationRate) / 1000)
    }

    /// The corner whose quadrant contains `point`.
    public static func nearestCorner(to point: PlanarVector, container: PlanarVector) -> PlayerPresentation.Corner {
        let leading = point.x < container.x / 2
        let top = point.y < container.y / 2
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    /// True when a centre point lies outside the container: more than half the player is gone.
    public static func isOffScreen(_ center: PlanarVector, container: PlanarVector) -> Bool {
        center.x < 0 || center.x > container.x || center.y < 0 || center.y > container.y
    }

    /// The corner a mini-player released with its centre at `position` and `velocity` snaps to.
    public static func snapCorner(position: PlanarVector, velocity: PlanarVector, container: PlanarVector) -> PlayerPresentation.Corner {
        nearestCorner(to: position + projectionDistance(velocity: velocity), container: container)
    }
}

// MARK: - Layout

/// Which native controls sit over or next to the player.
public enum PlayerChrome: Equatable, Sendable {
    case none
    /// The expanded header strip (`chromeFrame`): grabber, collapse, close.
    case header
    /// The bar under the docked video (`chromeFrame`).
    case dockedBar
    /// The mini-player overlay, covering `chromeFrame` (= the mini's visual frame).
    case mini
}

/// Where everything goes for one presentation, in viewport points.
public struct PlayerLayout: Equatable, Sendable {
    /// The player container's *unscaled* frame. Its size is the size the page lays out at.
    public var player: PlanarRect
    /// Scale applied around `player.origin` (top-leading). < 1 only for mini.
    public var playerScale: Double
    /// Corner radius in unscaled points (so it looks `miniCornerRadius` after scaling).
    public var playerCornerRadius: Double
    public var browse: PlanarRect
    public var chrome: PlayerChrome
    public var chromeFrame: PlanarRect?
    /// What the player page should be told with the `layout` command.
    public var pageLayout: PageLayout
    public var isPlayerVisible: Bool
    /// Whether the browse view takes touches (it's covered when expanded).
    public var isBrowseInteractive: Bool
    public var hidesStatusBar: Bool

    /// The player's frame on screen, after scaling.
    public var playerVisualFrame: PlanarRect {
        PlanarRect(origin: player.origin, size: player.size * playerScale)
    }
}

public enum PresentationLayout {
    public static func layout(for presentation: PlayerPresentation, in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> PlayerLayout {
        let full = viewport.bounds
        let size = viewport.size
        switch presentation {
        case .hidden:
            // Off-screen below the window, still in the hierarchy (D2). Full size, so opening
            // slides it up without a reflow.
            return PlayerLayout(
                player: PlanarRect(origin: PlanarVector(0, size.y), size: size), playerScale: 1, playerCornerRadius: 0,
                browse: full, chrome: .none, chromeFrame: nil, pageLayout: .page,
                isPlayerVisible: false, isBrowseInteractive: true, hidesStatusBar: false)

        case .expanded where viewport.isLandscape:
            return PlayerLayout(
                player: full, playerScale: 1, playerCornerRadius: 0,
                browse: full, chrome: .none, chromeFrame: nil, pageLayout: .video,
                isPlayerVisible: true, isBrowseInteractive: false, hidesStatusBar: true)

        case .expanded:
            let header = PlanarRect(x: 0, y: viewport.safeArea.top, width: size.x, height: tuning.headerHeight)
            let player = PlanarRect(x: 0, y: header.maxY, width: size.x, height: max(0, size.y - header.maxY))
            return PlayerLayout(
                player: player, playerScale: 1, playerCornerRadius: 0,
                browse: full, chrome: .header, chromeFrame: header, pageLayout: .page,
                isPlayerVisible: true, isBrowseInteractive: false, hidesStatusBar: false)

        case .docked:
            let video = MiniPlayerGeometry.dockedVideoSize(in: viewport, tuning: tuning)
            let player = PlanarRect(origin: PlanarVector(((size.x - video.x) / 2).rounded(), viewport.safeArea.top), size: video)
            let bar = PlanarRect(x: 0, y: player.maxY, width: size.x, height: tuning.dockedBarHeight)
            let browse = PlanarRect(x: 0, y: bar.maxY, width: size.x, height: max(0, size.y - bar.maxY))
            return PlayerLayout(
                player: player, playerScale: 1, playerCornerRadius: 0,
                browse: browse, chrome: .dockedBar, chromeFrame: bar, pageLayout: .video,
                isPlayerVisible: true, isBrowseInteractive: true, hidesStatusBar: false)

        case .mini(let corner):
            let video = MiniPlayerGeometry.dockedVideoSize(in: viewport, tuning: tuning)
            let scale = MiniPlayerGeometry.miniScale(in: viewport, tuning: tuning)
            let visual = MiniPlayerGeometry.miniFrame(corner, in: viewport, tuning: tuning)
            return PlayerLayout(
                player: PlanarRect(origin: visual.origin, size: video), playerScale: scale,
                playerCornerRadius: scale > 0 ? tuning.miniCornerRadius / scale : 0,
                browse: full, chrome: .mini, chromeFrame: visual, pageLayout: .video,
                isPlayerVisible: true, isBrowseInteractive: true, hidesStatusBar: false)
        }
    }
}
