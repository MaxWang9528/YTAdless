// Presentation state machine + player geometry — owner: Module C (PLAN.md §6.3).
//
// Everything PlayerLayoutView decides is computed here, so it is tested on Linux and the view
// stays a thin adapter: where each webview container goes in each mode (`PresentationLayout`),
// which page layout the player page gets, and what a gesture or button does (`next(after:in:)`).
// Plain Doubles rather than CoreGraphics types: CGSize/CGPoint conformances differ between Darwin
// and Linux Foundation.
//
// The UI follows the YouTube app (user decisions, 2026-11-24): an expanded watch view, and a
// floating mini player in the bottom-right corner, above m.youtube.com's own bottom nav (the video
// with play/pause, close and a progress line on it). The frozen `PlayerPresentation` contract
// still has `docked` and four mini corners; all of them render as that mini player, and
// `PlayerPresentation.miniPlayer` (= `.mini(.bottomTrailing)`) is the one this file produces.
//
// Transition table (portrait; `drag` = release travel projected with UIScrollView deceleration,
// +y is down):
//
// | from     | tap / expand | collapse | close | drag                                                        |
// |----------|--------------|----------|-------|-------------------------------------------------------------|
// | hidden   | hidden       | hidden   | hidden| hidden                                                      |
// | expanded | expanded     | mini     | close | down ≥ cancel: mini · else expanded                         |
// | mini     | expanded     | mini     | close | up ≥ cancel: expanded · down ≥ cancel or sideways fling: close · else mini |
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
    /// Native strip above the expanded watch view (collapse chevron, grabber, PiP).
    public var headerHeight: Double
    /// Width of the floating mini player as a fraction of the screen's short side (16:9 video).
    public var miniWidthFraction: Double
    /// Gap between the mini player and the screen edge / the site's bottom nav.
    public var miniMargin: Double
    /// The mini player's corner radius, on screen.
    public var miniCornerRadius: Double
    /// m.youtube.com's bottom nav above the safe area: `[has-pivot-bar=true] ytm-app{padding-bottom:48px}`
    /// and `ytm-pivot-bar-renderer{… padding: 0 env(safe-area-inset-…)}` (mweb CSS, 2026-11-24).
    public var bottomNavHeight: Double
    /// Thickness of the progress line along the bottom of the mini player.
    public var progressHeight: Double
    /// UIScrollView.DecelerationRate.normal; used to project a release point from velocity.
    public var decelerationRate: Double
    /// A drag whose projected travel is shorter than this changes nothing.
    public var dragCancelDistance: Double
    /// Mini player: a drag closes sideways only when its projected sideways travel is this many
    /// times its vertical travel.
    public var sidewaysDominance: Double

    public init(
        headerHeight: Double = 32,
        miniWidthFraction: Double = 0.5,
        miniMargin: Double = 8,
        miniCornerRadius: Double = 10,
        bottomNavHeight: Double = 48,
        progressHeight: Double = 2,
        decelerationRate: Double = 0.998,
        dragCancelDistance: Double = 80,
        sidewaysDominance: Double = 2
    ) {
        self.headerHeight = headerHeight
        self.miniWidthFraction = miniWidthFraction
        self.miniMargin = miniMargin
        self.miniCornerRadius = miniCornerRadius
        self.bottomNavHeight = bottomNavHeight
        self.progressHeight = progressHeight
        self.decelerationRate = decelerationRate
        self.dragCancelDistance = dragCancelDistance
        self.sidewaysDominance = sidewaysDominance
    }

    public static let standard = PresentationTuning()
}

// MARK: - State machine

/// A gesture or control that may change the player's presentation.
public enum PresentationGesture: Equatable, Sendable {
    /// A tap on the mini player.
    case tap
    /// A drag on the expanded header, the expanded video or the mini player, in window points.
    case dragEnded(translation: PlanarVector, velocity: PlanarVector)
    case expandButton
    /// The chevron on the expanded header.
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
    /// The floating mini player. Every `.mini(_)` and `.docked` render as it; this is the one we produce.
    public static let miniPlayer = PlayerPresentation.mini(.bottomTrailing)

    public var isVisible: Bool { self != .hidden }

    /// True for every mode drawn as the mini player (`docked` and all four corners).
    public var isMini: Bool {
        switch self {
        case .docked, .mini: return true
        case .hidden, .expanded: return false
        }
    }

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
            return .present(.miniPlayer)
        case .dragEnded(let translation, let velocity):
            let travel = translation + MiniPlayerGeometry.projectionDistance(velocity: velocity, decelerationRate: tuning.decelerationRate)
            if self == .expanded {
                if viewport.isLandscape || travel.y < tuning.dragCancelDistance { return .present(.expanded) }
                return .present(.miniPlayer)
            }
            // Mini player.
            if travel.y <= -tuning.dragCancelDistance { return .present(.expanded) }
            if travel.y >= tuning.dragCancelDistance { return .close }
            let sideways = abs(travel.x) > tuning.sidewaysDominance * abs(travel.y)
                && abs(translation.x) >= tuning.dragCancelDistance
                && abs(travel.x) >= viewport.size.x / 2
            return sideways ? .close : .present(self)
        }
    }
}

// MARK: - Mini-player geometry

public enum MiniPlayerGeometry {
    /// The unscaled size the player page lays out at in the mini player: the full-width 16:9
    /// video (the mini player shows it scaled down, so the page doesn't reflow at a tiny width,
    /// §6.3). In landscape the width is capped so the height stays within half the screen.
    public static func videoSize(in viewport: PresentationViewport) -> PlanarVector {
        let width = viewport.size.x
        let height = (width * 9 / 16).rounded()
        let maxHeight = (viewport.size.y / 2).rounded()
        guard height > maxHeight, maxHeight > 0 else { return PlanarVector(width, height) }
        return PlanarVector((maxHeight * 16 / 9).rounded(), maxHeight)
    }

    /// The scale that shrinks the laid-out video to the mini player's width.
    public static func miniScale(in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> Double {
        let video = videoSize(in: viewport)
        guard video.x > 0 else { return 1 }
        return min(1, miniFrame(in: viewport, tuning: tuning).width / video.x)
    }

    /// The floating mini player on screen: bottom-right, inside the safe area, just above the
    /// site's bottom nav.
    public static func miniFrame(in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> PlanarRect {
        let shortSide = min(viewport.size.x, viewport.size.y)
        let width = (shortSide * tuning.miniWidthFraction).rounded()
        let height = (width * 9 / 16).rounded()
        let x = viewport.size.x - viewport.safeArea.trailing - tuning.miniMargin - width
        let y = viewport.size.y - viewport.safeArea.bottom - tuning.bottomNavHeight - tuning.miniMargin - height
        return PlanarRect(x: x, y: max(viewport.safeArea.top, y), width: width, height: height)
    }

    /// How far a release at `velocity` (pt/s) carries on with UIScrollView-style deceleration
    /// (`v / 1000 · r / (1 − r)`, the formula from Apple's WWDC 2018 "Designing Fluid Interfaces").
    public static func projectionDistance(velocity: PlanarVector, decelerationRate: Double = PresentationTuning.standard.decelerationRate) -> PlanarVector {
        guard decelerationRate > 0, decelerationRate < 1 else { return .zero }
        return velocity * (decelerationRate / (1 - decelerationRate) / 1000)
    }

    /// Playback progress in 0…1 for the mini player's line; 0 when the duration is unknown or live.
    public static func progress(position: Double, duration: Double?) -> Double {
        guard let duration, duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
}

// MARK: - Layout

/// Which native controls sit over or next to the player.
public enum PlayerChrome: Equatable, Sendable {
    case none
    /// The expanded header strip (`chromeFrame`): collapse, grabber, PiP.
    case header
    /// The floating mini player (`chromeFrame` = the video on screen): play/pause, close, progress.
    case miniPlayer
}

/// Where everything goes for one presentation, in viewport points.
public struct PlayerLayout: Equatable, Sendable {
    /// The player container's *unscaled* frame. Its size is the size the page lays out at.
    public var player: PlanarRect
    /// Scale applied around `player.origin` (top-leading). < 1 only for the mini player.
    public var playerScale: Double
    /// Corner radius in unscaled points (so it is `miniCornerRadius` on screen after scaling).
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
    /// The browse view starts below the status bar / Dynamic Island. m.youtube.com sets
    /// `viewport-fit=cover` but its top bar has no `env(safe-area-inset-top)` padding (mweb only
    /// runs in Safari, whose own chrome covers that strip), so a full-screen webview puts the
    /// logo and search button under the island (device, 2026-11-25). The bottom stays full: the
    /// bottom nav pads itself with `env(safe-area-inset-bottom)` (see `bottomNavHeight`).
    public static func browseFrame(in viewport: PresentationViewport) -> PlanarRect {
        let top = viewport.safeArea.top
        return PlanarRect(x: 0, y: top, width: viewport.size.x, height: max(0, viewport.size.y - top))
    }

    public static func layout(for presentation: PlayerPresentation, in viewport: PresentationViewport, tuning: PresentationTuning = .standard) -> PlayerLayout {
        let full = viewport.bounds
        let size = viewport.size
        let browse = browseFrame(in: viewport)
        switch presentation {
        case .hidden:
            // Off-screen below the window, still in the hierarchy (D2). Full size, so opening
            // slides it up without a reflow.
            return PlayerLayout(
                player: PlanarRect(origin: PlanarVector(0, size.y), size: size), playerScale: 1, playerCornerRadius: 0,
                browse: browse, chrome: .none, chromeFrame: nil, pageLayout: .page,
                isPlayerVisible: false, isBrowseInteractive: true, hidesStatusBar: false)

        case .expanded where viewport.isLandscape:
            return PlayerLayout(
                player: full, playerScale: 1, playerCornerRadius: 0,
                browse: browse, chrome: .none, chromeFrame: nil, pageLayout: .video,
                isPlayerVisible: true, isBrowseInteractive: false, hidesStatusBar: true)

        case .expanded:
            let header = PlanarRect(x: 0, y: viewport.safeArea.top, width: size.x, height: tuning.headerHeight)
            let player = PlanarRect(x: 0, y: header.maxY, width: size.x, height: max(0, size.y - header.maxY))
            return PlayerLayout(
                player: player, playerScale: 1, playerCornerRadius: 0,
                browse: browse, chrome: .header, chromeFrame: header, pageLayout: .page,
                isPlayerVisible: true, isBrowseInteractive: false, hidesStatusBar: false)

        case .docked, .mini:
            let frame = MiniPlayerGeometry.miniFrame(in: viewport, tuning: tuning)
            let video = MiniPlayerGeometry.videoSize(in: viewport)
            let scale = MiniPlayerGeometry.miniScale(in: viewport, tuning: tuning)
            return PlayerLayout(
                player: PlanarRect(origin: frame.origin, size: video),
                playerScale: scale, playerCornerRadius: scale > 0 ? tuning.miniCornerRadius / scale : 0,
                browse: browse, chrome: .miniPlayer, chromeFrame: frame, pageLayout: .video,
                isPlayerVisible: true, isBrowseInteractive: true, hidesStatusBar: false)
        }
    }
}
