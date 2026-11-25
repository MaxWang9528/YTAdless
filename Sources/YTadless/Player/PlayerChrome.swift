// Native player chrome — owner: Module C (PLAN.md §6.3).
//
// Styled after the YouTube app (user decision, 2026-11-24):
// - Expanded: a slim strip above the watch view with the collapse chevron, a grabber, the sleep
//   timer (moon; its countdown next to it when armed) and PiP.
//   Drag it, or the video itself (VideoSwipeDown), down — or tap the chevron — to minimize.
//   YouTube's own controls do the rest.
// - Mini player: a small floating video in the bottom-right corner, above the site's bottom nav.
//   PlayerLayoutView draws the scaled player webview there; this overlay adds close, play/pause
//   and a progress line on top. Tap or drag up expands; drag down or fling sideways closes.
// None of these hold a webview, so they can be created and dropped freely.

import SwiftUI
import UIKit
import YTCore

/// What the chrome can ask PlayerLayoutView to do.
struct PlayerChromeActions {
    let playback: PlaybackState
    let onGesture: (PresentationGesture) -> Void
    let onPlayPause: () -> Void
    let onPiP: () -> Void
    let sleepTimer: SleepTimerController

    var isPlaying: Bool { playback.snapshot.status.isPlayingOrWaiting }
    var isInPiP: Bool { playback.presentation == .pip }
}

struct ExpandedHeader: View {
    let actions: PlayerChromeActions

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 36, height: 5)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                ChromeButton(systemName: "chevron.down", label: "Minimize player") { actions.onGesture(.collapseButton) }
                Spacer(minLength: 0)
                SleepTimerMenu(controller: actions.sleepTimer)
                ChromeButton(systemName: actions.isInPiP ? "pip.exit" : "pip.enter",
                             label: "Picture in Picture", action: actions.onPiP)
            }
            .padding(.horizontal, 2)
        }
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
        .accessibilityHint("Drag down to minimize")
    }
}

/// The moon button: a menu of durations, end of video and (when armed) turn off. When armed, the
/// time left is shown next to it; `Text(timerInterval:)` counts down without re-rendering.
private struct SleepTimerMenu: View {
    let controller: SleepTimerController

    var body: some View {
        let timer = controller.timer
        Menu {
            Section("Sleep timer") {
                ForEach(SleepTimer.presetMinutes, id: \.self) { minutes in
                    Button("\(minutes) minutes") { controller.arm(.minutes(minutes)) }
                }
                Button("End of video") { controller.arm(.endOfVideo) }
                    .disabled(!controller.canArmEndOfVideo)
                if timer.isArmed {
                    Button("Turn off", role: .destructive) { controller.disarm() }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: timer.isArmed ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title3)
                switch timer.mode {
                case .until(let deadline, let armedAt):
                    // armedAt ≤ deadline always holds; a range built from `.now` could trap once it passed.
                    Text(timerInterval: armedAt...deadline, countsDown: true)
                        .font(.caption.monospacedDigit())
                case .endOfVideo:
                    Text("End").font(.caption)
                case .off:
                    EmptyView()
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(accessibilityValue(timer.mode))
    }

    private func accessibilityValue(_ mode: SleepTimer.Mode) -> String {
        switch mode {
        case .off: "Off"
        case .until(let deadline, _): "Pauses at \(deadline.formatted(date: .omitted, time: .shortened))"
        case .endOfVideo: "Pauses at the end of the video"
        }
    }
}

/// The mini player's shadow and backing, drawn *behind* the player webview.
struct MiniPlayerBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black)
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

/// The mini player's controls, drawn over the scaled video: a tap anywhere else expands.
struct MiniPlayerOverlay: View {
    let actions: PlayerChromeActions
    let progress: Double
    let progressHeight: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            // Takes the tap (expand) and the drag; the page never sees them.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { actions.onGesture(.tap) }
                .accessibilityElement()
                .accessibilityLabel("Mini player")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Expands the player")

            // Keeps the buttons readable over a bright frame.
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MiniButton(systemName: "xmark", label: "Close player") { actions.onGesture(.closeButton) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    MiniButton(systemName: actions.isPlaying ? "pause.fill" : "play.fill",
                               label: actions.isPlaying ? "Pause" : "Play", action: actions.onPlayPause)
                    Spacer(minLength: 0)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.red)
                    .frame(width: proxy.size.width * progress, height: progressHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

/// A small icon on the video; the hit area stays 36 pt.
private struct MiniButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct ChromeButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}
