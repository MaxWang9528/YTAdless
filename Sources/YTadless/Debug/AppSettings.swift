// AppSettings — owner: Module B (PLAN.md §6.2 Debug tooling › Settings).
//
// User settings shown in Debug › Settings, persisted in UserDefaults ("ytadless.settings.*").
// Each one takes effect where it is read:
//   appearance          → every window's overrideUserInterfaceStyle (webviews follow via prefers-color-scheme)
//   player              → PlayerLayoutView's PresentationTuning (PlayerPreferences.tuning, YTCore)
//   videoSwipeToMinimize→ PlayerLayoutView gates VideoSwipeDown.isActive
//   blockAdRequests /
//   hideAdElements      → WebViewStore.applyContentRules (adds/removes the compiled rule lists)
//   keepScreenAwake     → DebugEntryView sets UIApplication.isIdleTimerDisabled while playing
//   debugButtonOffset   → DebugEntryView's vertical position
//   sponsorBlockEnabled /
//   sponsorBlockCategories → SponsorBlockService (Module D) observes them and re-sends segments
//   aiSponsorDetection  → SponsorDetectionService (Module D): on-device guesses when SponsorBlock has none
//   sponsorBlockAutoSkip / aiSponsorAutoSkip → the services send them as `autoSkip` (Skip button when off)
// Defaults reproduce the app's behaviour before settings existed.

import SwiftUI
import UIKit
import YTCore

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    enum Appearance: String, CaseIterable, Identifiable {
        case dark = "Dark", light = "Light", system = "System"
        var id: String { rawValue }
        var style: UIUserInterfaceStyle {
            switch self {
            case .dark: .dark
            case .light: .light
            case .system: .unspecified
            }
        }
    }

    var appearance: Appearance { didSet { save(appearance.rawValue, .appearance); applyAppearance() } }
    var miniWidthFraction: Double { didSet { save(miniWidthFraction, .miniWidthFraction) } }
    var miniCornerRadius: Double { didSet { save(miniCornerRadius, .miniCornerRadius) } }
    var miniMargin: Double { didSet { save(miniMargin, .miniMargin) } }
    var showsMiniProgress: Bool { didSet { save(showsMiniProgress, .showsMiniProgress) } }
    var dragDistance: Double { didSet { save(dragDistance, .dragDistance) } }
    var videoSwipeToMinimize: Bool { didSet { save(videoSwipeToMinimize, .videoSwipeToMinimize) } }
    var blockAdRequests: Bool { didSet { save(blockAdRequests, .blockAdRequests) } }
    var hideAdElements: Bool { didSet { save(hideAdElements, .hideAdElements) } }
    var keepScreenAwake: Bool { didSet { save(keepScreenAwake, .keepScreenAwake) } }
    /// Vertical offset of the Debug button from its starting point (points).
    var debugButtonOffset: Double { didSet { save(debugButtonOffset, .debugButtonOffset) } }
    /// Off by default: when on, a 4-char SHA-256 prefix of each video ID goes to sponsor.ajay.app.
    var sponsorBlockEnabled: Bool { didSet { save(sponsorBlockEnabled, .sponsorBlockEnabled) } }
    /// Enabled SponsorBlock categories, persisted as their API names.
    var sponsorBlockCategories: Set<SponsorBlock.Category> {
        didSet { save(SponsorBlock.Category.rawValues(sponsorBlockCategories), .sponsorBlockCategories) }
    }
    /// Off by default: when on, the transcript of a video SponsorBlock has nothing for is analysed
    /// on the iPhone (Apple Intelligence) and likely sponsor reads are suggested (see aiSponsorAutoSkip).
    var aiSponsorDetection: Bool { didSet { save(aiSponsorDetection, .aiSponsorDetection) } }
    /// Off by default: SponsorBlock segments show a Skip button instead of being skipped.
    var sponsorBlockAutoSkip: Bool { didSet { save(sponsorBlockAutoSkip, .sponsorBlockAutoSkip) } }
    /// Off by default: on-device guesses show a Skip button instead of being skipped.
    var aiSponsorAutoSkip: Bool { didSet { save(aiSponsorAutoSkip, .aiSponsorAutoSkip) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var windowObserver: NSObjectProtocol?

    private enum Key: String {
        case appearance, miniWidthFraction, miniCornerRadius, miniMargin, showsMiniProgress, dragDistance
        case videoSwipeToMinimize, blockAdRequests, hideAdElements, keepScreenAwake, debugButtonOffset
        case sponsorBlockEnabled, sponsorBlockCategories, aiSponsorDetection
        case sponsorBlockAutoSkip, aiSponsorAutoSkip
        var name: String { "ytadless.settings." + rawValue }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let p = PlayerPreferences.standard
        appearance = defaults.string(forKey: Key.appearance.name).flatMap(Appearance.init(rawValue:)) ?? .dark
        miniWidthFraction = Self.double(defaults, .miniWidthFraction) ?? p.miniWidthFraction
        miniCornerRadius = Self.double(defaults, .miniCornerRadius) ?? p.miniCornerRadius
        miniMargin = Self.double(defaults, .miniMargin) ?? p.miniMargin
        showsMiniProgress = Self.bool(defaults, .showsMiniProgress) ?? p.showsMiniProgress
        dragDistance = Self.double(defaults, .dragDistance) ?? p.dragDistance
        videoSwipeToMinimize = Self.bool(defaults, .videoSwipeToMinimize) ?? true
        blockAdRequests = Self.bool(defaults, .blockAdRequests) ?? true
        hideAdElements = Self.bool(defaults, .hideAdElements) ?? true
        keepScreenAwake = Self.bool(defaults, .keepScreenAwake) ?? false
        debugButtonOffset = Self.double(defaults, .debugButtonOffset) ?? 0
        sponsorBlockEnabled = Self.bool(defaults, .sponsorBlockEnabled) ?? false
        sponsorBlockCategories = defaults.stringArray(forKey: Key.sponsorBlockCategories.name)
            .map(SponsorBlock.Category.set(fromRawValues:)) ?? SponsorBlock.Category.defaults
        aiSponsorDetection = Self.bool(defaults, .aiSponsorDetection) ?? false
        sponsorBlockAutoSkip = Self.bool(defaults, .sponsorBlockAutoSkip) ?? false
        aiSponsorAutoSkip = Self.bool(defaults, .aiSponsorAutoSkip) ?? false
        // A window that appears later (a new scene) gets the current appearance too.
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    var playerPreferences: PlayerPreferences {
        PlayerPreferences(miniWidthFraction: miniWidthFraction, miniCornerRadius: miniCornerRadius,
                          miniMargin: miniMargin, showsMiniProgress: showsMiniProgress, dragDistance: dragDistance)
    }

    /// What PlayerLayoutView lays out and decides gestures with.
    var tuning: PresentationTuning { playerPreferences.tuning() }

    func resetToDefaults() {
        let p = PlayerPreferences.standard
        appearance = .dark
        miniWidthFraction = p.miniWidthFraction
        miniCornerRadius = p.miniCornerRadius
        miniMargin = p.miniMargin
        showsMiniProgress = p.showsMiniProgress
        dragDistance = p.dragDistance
        videoSwipeToMinimize = true
        blockAdRequests = true
        hideAdElements = true
        keepScreenAwake = false
        debugButtonOffset = 0
        sponsorBlockEnabled = false
        sponsorBlockCategories = SponsorBlock.Category.defaults
        aiSponsorDetection = false
        sponsorBlockAutoSkip = false
        aiSponsorAutoSkip = false
    }

    /// Sets the style on every window of every scene. Called at launch and on change.
    func applyAppearance() {
        let style = appearance.style
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    // MARK: Persistence

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.name)
    }

    private static func double(_ defaults: UserDefaults, _ key: Key) -> Double? {
        guard defaults.object(forKey: key.name) != nil else { return nil }
        let value = defaults.double(forKey: key.name)
        return value.isFinite ? value : nil
    }

    private static func bool(_ defaults: UserDefaults, _ key: Key) -> Bool? {
        guard defaults.object(forKey: key.name) != nil else { return nil }
        return defaults.bool(forKey: key.name)
    }
}
