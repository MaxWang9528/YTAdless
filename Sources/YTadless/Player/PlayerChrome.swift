// Native player chrome — owner: Module C (PLAN.md §6.3).
//
// Styled after the YouTube app (user decision, 2026-11-24):
// - Expanded: a slim strip above the watch view with the collapse chevron, a grabber and PiP.
//   Drag it, or the video itself (VideoSwipeDown), down — or tap the chevron — to minimize.
//   YouTube's own controls do the rest.
// - Mini bar: pinned above the site's bottom nav. The scaled player webview sits in its leading
//   slot (PlayerLayoutView draws it there); this overlay leaves that slot clear and adds title,
//   channel, play/pause, close and a progress line. Tap or drag up expands; drag down closes.
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

/// The bar's background, drawn *behind* the player webview so the video shows on top of it.
struct MiniBarBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .top) { Divider() }
            .shadow(color: .black.opacity(0.12), radius: 6, y: -2)
    }
}

/// The bar's controls, drawn above the player webview. `videoWidth` is the clear leading slot.
struct MiniBarOverlay: View {
    let actions: PlayerChromeActions
    let meta: VideoMeta?
    let videoWidth: CGFloat
    let progress: Double
    let progressHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // The video slot: transparent, but it still takes the tap (expand) and the drag.
            Color.clear
                .frame(width: videoWidth)
                .contentShape(Rectangle())
                .onTapGesture { actions.onGesture(.tap) }

            VStack(alignment: .leading, spacing: 2) {
                Text(meta?.title ?? "Loading…")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let author = meta?.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .contentShape(Rectangle())
            .onTapGesture { actions.onGesture(.tap) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Expands the player")

            ChromeButton(systemName: actions.isPlaying ? "pause.fill" : "play.fill",
                         label: actions.isPlaying ? "Pause" : "Play", action: actions.onPlayPause)
            ChromeButton(systemName: "xmark", label: "Close player") { actions.onGesture(.closeButton) }
                .padding(.trailing, 4)
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
        .accessibilityElement(children: .contain)
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
