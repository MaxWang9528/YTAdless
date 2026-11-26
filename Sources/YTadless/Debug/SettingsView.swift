// SettingsView — owner: Module B (PLAN.md §6.2 Debug tooling › Settings).
//
// The Settings tab of the Debug panel. Every control writes AppSettings (persisted); see
// AppSettings.swift for where each one takes effect.

import SwiftUI
import YTCore

struct SettingsView: View {
    let store: WebViewStore

    @Bindable private var settings = AppSettings.shared
    @State private var confirmsReset = false
    /// Set when a content-rule toggle changed: the open pages keep what they already loaded.
    @State private var rulesChangedSinceReload = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                slider("Size", value: $settings.miniWidthFraction, in: PlayerPreferences.miniWidthFractionRange,
                       step: 0.05, format: { "\(Int(($0 * 100).rounded())) %" })
                slider("Corner radius", value: $settings.miniCornerRadius, in: PlayerPreferences.miniCornerRadiusRange,
                       step: 1, format: { "\(Int($0)) pt" })
                slider("Margin", value: $settings.miniMargin, in: PlayerPreferences.miniMarginRange,
                       step: 1, format: { "\(Int($0)) pt" })
                Toggle("Progress line", isOn: $settings.showsMiniProgress)
            } header: {
                Text("Mini player")
            } footer: {
                Text("Size is the width as a share of the screen's short side. Collapse the player to see changes live.")
            }

            Section {
                Toggle("Swipe down on video to minimize", isOn: $settings.videoSwipeToMinimize)
                slider("Drag distance", value: $settings.dragDistance, in: PlayerPreferences.dragDistanceRange,
                       step: 10, format: { "\(Int($0)) pt" })
            } header: {
                Text("Gestures")
            } footer: {
                Text("How far a drag (with its fling) must travel to minimize, expand or close the player. The header and mini player always take drags.")
            }

            Section {
                Toggle("Block ad requests", isOn: $settings.blockAdRequests)
                    .disabled(store.contentRuleLists.network == nil)
                Toggle("Hide ad elements", isOn: $settings.hideAdElements)
                    .disabled(store.contentRuleLists.cosmetic == nil)
                if rulesChangedSinceReload {
                    Button("Reload both pages to apply", systemImage: "arrow.clockwise") {
                        reloadBoth()
                    }
                }
            } header: {
                Text("Ad blocking")
            } footer: {
                Text("Content rules (rules/network.txt, rules/cosmetic.txt). New requests use the change at once; open pages need a reload. Video-ad and promoted-tile removal in the injected scripts stays on.")
            }

            Section {
                Toggle("Keep screen awake while playing", isOn: $settings.keepScreenAwake)
            } header: {
                Text("Playback")
            }

            Section {
                Toggle("Use SponsorBlock", isOn: $settings.sponsorBlockEnabled)
                Toggle("Skip automatically", isOn: $settings.sponsorBlockAutoSkip)
                    .disabled(!settings.sponsorBlockEnabled)
                ForEach(SponsorBlock.Category.allCases) { category in
                    Toggle(category.displayName, isOn: categoryBinding(category))
                        .disabled(!settings.sponsorBlockEnabled)
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text("Finds segments the SponsorBlock community marked (sponsor.ajay.app). With \"Skip automatically\" on they are skipped with an Undo button; off, a Skip button appears when one starts. To look a video up, only the first 4 characters of a SHA-256 hash of its ID are sent, never the ID itself. The data is crowd-sourced and can be wrong.")
            }

            Section {
                Toggle("Detect sponsors with on-device AI", isOn: $settings.aiSponsorDetection)
                Toggle("Skip automatically", isOn: $settings.aiSponsorAutoSkip)
                    .disabled(!settings.aiSponsorDetection)
                let status = SponsorDetector.status
                if !status.isAvailable {
                    Label(status.message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Runs only when SponsorBlock is off or has no segments for a video. The video's transcript is analysed on this iPhone with Apple Intelligence and never leaves the phone. Guesses are shown as dashed marks on the seek bar. With \"Skip automatically\" off a Skip button appears when one starts; on, they are skipped with an Undo button (guesses can be wrong).")
            }

            Section {
                Toggle("Hide segment marks in full screen", isOn: $settings.hideMarkersInFullscreen)
            } footer: {
                Text("Hides the SponsorBlock and on-device AI marks on the seek bar in landscape full screen. Skip and Undo buttons still appear.")
            }

            Section {
                Toggle("Show Debug button", isOn: $settings.showsDebugButton)
            } header: {
                Text("Debug")
            } footer: {
                Text("When hidden, shake the iPhone to open Debug and Settings.")
            }

            Section("Pages") {
                Button("Reload browse", systemImage: "arrow.clockwise") { store.reloadBrowseTabs() }
                Button("Reload player", systemImage: "arrow.clockwise") { store.playerWebView.reload() }
                    .disabled(store.playerWebView.url == nil)
                Button("Reset Debug button position", systemImage: "arrow.uturn.backward") {
                    settings.debugButtonOffset = 0
                }
                .disabled(settings.debugButtonOffset == 0)
            }

            Section {
                Button("Reset to defaults", role: .destructive) { confirmsReset = true }
                    .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmsReset, titleVisibility: .visible) {
                        Button("Reset", role: .destructive) { settings.resetToDefaults() }
                    }
            }
        }
        .onChange(of: settings.blockAdRequests) { rulesChanged() }
        .onChange(of: settings.hideAdElements) { rulesChanged() }
    }

    private func rulesChanged() {
        store.applyContentRules(settings)
        rulesChangedSinceReload = true
    }

    private func reloadBoth() {
        store.reloadBrowseTabs()
        if store.playerWebView.url != nil { store.playerWebView.reload() }
        rulesChangedSinceReload = false
    }

    private func categoryBinding(_ category: SponsorBlock.Category) -> Binding<Bool> {
        Binding(
            get: { settings.sponsorBlockCategories.contains(category) },
            set: { isOn in
                if isOn { settings.sponsorBlockCategories.insert(category) }
                else { settings.sponsorBlockCategories.remove(category) }
            }
        )
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: format(value.wrappedValue))
            Slider(value: value, in: range, step: step)
        }
    }
}
