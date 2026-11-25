// Player preferences → PresentationTuning — owner: Module B (PLAN.md §6.2 Debug › Settings).
//
// The user-adjustable part of `PresentationTuning` (Debug › Settings). Values coming from
// UserDefaults can be anything, so `tuning` clamps each one into its range before PlayerLayoutView
// uses it; the defaults are exactly `PresentationTuning.standard`.

import Foundation

public struct PlayerPreferences: Equatable, Sendable {
    /// Mini player width as a fraction of the screen's short side.
    public var miniWidthFraction: Double
    public var miniCornerRadius: Double
    /// Gap between the mini player and the screen edge / the site's bottom nav.
    public var miniMargin: Double
    /// The red progress line along the bottom of the mini player.
    public var showsMiniProgress: Bool
    /// Projected drag travel needed to minimize, expand or close.
    public var dragDistance: Double

    public static let miniWidthFractionRange: ClosedRange<Double> = 0.35...0.7
    public static let miniCornerRadiusRange: ClosedRange<Double> = 0...24
    public static let miniMarginRange: ClosedRange<Double> = 0...32
    public static let dragDistanceRange: ClosedRange<Double> = 40...200

    public init(
        miniWidthFraction: Double = PresentationTuning.standard.miniWidthFraction,
        miniCornerRadius: Double = PresentationTuning.standard.miniCornerRadius,
        miniMargin: Double = PresentationTuning.standard.miniMargin,
        showsMiniProgress: Bool = true,
        dragDistance: Double = PresentationTuning.standard.dragCancelDistance
    ) {
        self.miniWidthFraction = miniWidthFraction
        self.miniCornerRadius = miniCornerRadius
        self.miniMargin = miniMargin
        self.showsMiniProgress = showsMiniProgress
        self.dragDistance = dragDistance
    }

    public static let standard = PlayerPreferences()

    /// `base` with these preferences applied, each clamped into its range (NaN → the default).
    public func tuning(base: PresentationTuning = .standard) -> PresentationTuning {
        var tuning = base
        tuning.miniWidthFraction = Self.clamp(miniWidthFraction, Self.miniWidthFractionRange, fallback: base.miniWidthFraction)
        tuning.miniCornerRadius = Self.clamp(miniCornerRadius, Self.miniCornerRadiusRange, fallback: base.miniCornerRadius)
        tuning.miniMargin = Self.clamp(miniMargin, Self.miniMarginRange, fallback: base.miniMargin)
        tuning.dragCancelDistance = Self.clamp(dragDistance, Self.dragDistanceRange, fallback: base.dragCancelDistance)
        tuning.progressHeight = showsMiniProgress ? base.progressHeight : 0
        return tuning
    }

    public static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return min(range.upperBound, max(range.lowerBound, fallback)) }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
