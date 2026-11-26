// App full screen — owner: Module C (PLAN.md §6.3).
//
// YouTube's fullscreen button reaches native as `fullscreenRequest {enter}` (player-bridge.js)
// instead of WebKit's video full screen, so the page — and the SponsorBlock Skip button — stays
// on screen. The app's full screen is its expanded landscape layout (`PresentationLayout`). The
// page never actually enters full screen, so its button keeps saying "enter": a request to enter
// while already landscape is a toggle back to portrait.

public enum AppFullscreen {
    public enum Orientation: Equatable, Sendable {
        case portrait, landscape
    }

    /// Where to rotate for a request, or nil to leave the orientation alone.
    public static func target(enter: Bool, isLandscape: Bool) -> Orientation? {
        switch (enter, isLandscape) {
        case (true, false): .landscape
        case (true, true), (false, true): .portrait
        case (false, false): nil
        }
    }

    /// The player presentation to use when going full screen: full screen is the expanded layout.
    public static func presentation(entering target: Orientation, from current: PlayerPresentation) -> PlayerPresentation {
        target == .landscape && current != .hidden ? .expanded : current
    }
}
