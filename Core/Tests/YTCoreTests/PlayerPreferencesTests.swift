// Player preferences → PresentationTuning (PLAN.md §6.2 Debug › Settings). Owner: Module B.

import Testing
@testable import YTCore

private let portrait = PresentationViewport(size: PlanarVector(393, 852), safeArea: PlanarInsets(top: 59, bottom: 34))

@Suite("PlayerPreferences › tuning")
struct PlayerPreferencesTests {
    @Test("defaults map to PresentationTuning.standard")
    func defaultsAreStandard() {
        #expect(PlayerPreferences.standard.tuning() == PresentationTuning.standard)
    }

    @Test("defaults lie inside their ranges")
    func defaultsInRange() {
        let p = PlayerPreferences.standard
        #expect(PlayerPreferences.miniWidthFractionRange.contains(p.miniWidthFraction))
        #expect(PlayerPreferences.miniCornerRadiusRange.contains(p.miniCornerRadius))
        #expect(PlayerPreferences.miniMarginRange.contains(p.miniMargin))
        #expect(PlayerPreferences.dragDistanceRange.contains(p.dragDistance))
    }

    @Test("out-of-range values are clamped")
    func clamps() {
        let low = PlayerPreferences(miniWidthFraction: 0, miniCornerRadius: -5, miniMargin: -1, dragDistance: 1).tuning()
        #expect(low.miniWidthFraction == PlayerPreferences.miniWidthFractionRange.lowerBound)
        #expect(low.miniCornerRadius == 0)
        #expect(low.miniMargin == 0)
        #expect(low.dragCancelDistance == PlayerPreferences.dragDistanceRange.lowerBound)
        let high = PlayerPreferences(miniWidthFraction: 5, miniCornerRadius: 500, miniMargin: 500, dragDistance: 9999).tuning()
        #expect(high.miniWidthFraction == PlayerPreferences.miniWidthFractionRange.upperBound)
        #expect(high.miniCornerRadius == PlayerPreferences.miniCornerRadiusRange.upperBound)
        #expect(high.miniMargin == PlayerPreferences.miniMarginRange.upperBound)
        #expect(high.dragCancelDistance == PlayerPreferences.dragDistanceRange.upperBound)
    }

    @Test("NaN falls back to the default")
    func nanFallsBack() {
        let t = PlayerPreferences(miniWidthFraction: .nan, dragDistance: .infinity).tuning()
        #expect(t.miniWidthFraction == PresentationTuning.standard.miniWidthFraction)
        #expect(t.dragCancelDistance == PresentationTuning.standard.dragCancelDistance)
    }

    @Test("hiding the progress line sets its height to 0; other numbers stay")
    func progressToggle() {
        let t = PlayerPreferences(showsMiniProgress: false).tuning()
        #expect(t.progressHeight == 0)
        #expect(t.headerHeight == PresentationTuning.standard.headerHeight)
        #expect(t.bottomNavHeight == PresentationTuning.standard.bottomNavHeight)
    }

    @Test("a bigger fraction gives a bigger mini player, still bottom-right")
    func sizeTakesEffect() {
        let small = PresentationLayout.layout(for: .miniPlayer, in: portrait, tuning: PlayerPreferences(miniWidthFraction: 0.35).tuning())
        let big = PresentationLayout.layout(for: .miniPlayer, in: portrait, tuning: PlayerPreferences(miniWidthFraction: 0.7).tuning())
        #expect(big.playerVisualFrame.width > small.playerVisualFrame.width)
        #expect(abs(big.playerVisualFrame.maxX - small.playerVisualFrame.maxX) < 1)
        #expect(big.chromeFrame?.width == (393 * 0.7).rounded())
    }

    @Test("drag distance changes what a drag does")
    func dragDistanceTakesEffect() {
        let drag = PresentationGesture.dragEnded(translation: PlanarVector(0, 100), velocity: .zero)
        let loose = PlayerPreferences(dragDistance: 60).tuning()
        let strict = PlayerPreferences(dragDistance: 150).tuning()
        #expect(PlayerPresentation.expanded.next(after: drag, in: portrait, tuning: loose) == .present(.miniPlayer))
        #expect(PlayerPresentation.expanded.next(after: drag, in: portrait, tuning: strict) == .present(.expanded))
    }
}
