// Native player chrome — owner: Module C (PLAN.md §6.3).
//
// Expanded: a slim header above YouTube's watch page (collapse, grabber, close); YouTube's own
// controls do the rest. Docked: a bar under the video (title, play/pause, PiP, expand, close).
// Mini: an overlay on the floating video (play/pause, PiP, close; tap expands, drag moves).
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
        HStack(spacing: 0) {
            ChromeButton(systemName: "chevron.down", label: "Collapse player") { actions.onGesture(.collapseButton) }
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 40, height: 5)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            ChromeButton(systemName: "xmark", label: "Close player") { actions.onGesture(.closeButton) }
        }
        .padding(.horizontal, 4)
        .background(Color(uiColor: .systemBackground))
        .contentShape(Rectangle())
    }
}

struct DockedBar: View {
    let actions: PlayerChromeActions
    let meta: VideoMeta?

    var body: some View {
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meta?.title ?? "Loading…")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let author = meta?.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .contentShape(Rectangle())
            .onTapGesture { actions.onGesture(.tap) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Expands the player")

            ChromeButton(systemName: actions.isPlaying ? "pause.fill" : "play.fill",
                         label: actions.isPlaying ? "Pause" : "Play", action: actions.onPlayPause)
            ChromeButton(systemName: actions.isInPiP ? "pip.exit" : "pip.enter",
                         label: "Picture in Picture", action: actions.onPiP)
            ChromeButton(systemName: "arrow.up.left.and.arrow.down.right",
                         label: "Expand player") { actions.onGesture(.expandButton) }
            ChromeButton(systemName: "xmark", label: "Close player") { actions.onGesture(.closeButton) }
        }
        .padding(.trailing, 4)
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct MiniOverlay: View {
    let actions: PlayerChromeActions

    var body: some View {
        ZStack {
            // Catches taps and drags over the whole mini-player.
            Color.clear
            Button(action: actions.onPlayPause) {
                Image(systemName: actions.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .accessibilityLabel(actions.isPlaying ? "Pause" : "Play")
        }
        .overlay(alignment: .topTrailing) {
            MiniCornerButton(systemName: "xmark", label: "Close player") { actions.onGesture(.closeButton) }
        }
        .overlay(alignment: .topLeading) {
            MiniCornerButton(systemName: actions.isInPiP ? "pip.exit" : "pip.enter",
                             label: "Picture in Picture", action: actions.onPiP)
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Tap to expand; drag to move; fling away to close")
    }
}

private struct ChromeButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }
}

private struct MiniCornerButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: Circle())
                .frame(width: 40, height: 40)  // bigger hit area than the visible disc
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
