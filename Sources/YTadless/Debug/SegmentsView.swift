// SegmentsView — owner: Module B (PLAN.md §6.2 Debug tooling; data from Module D, §6.5).
//
// The Segments tab of the Debug panel: for the video in the player, the SponsorBlock segments
// and on-device guesses last sent to sponsorblock.js (SegmentBoard) with their timestamps, and
// below them the skip history from the log (sponsorblock.js "skipped …", "undo …",
// "suggestion …" lines). Tapping a segment seeks the player to its start.

import SwiftUI
import YTCore

struct SegmentsView: View {
    let store: WebViewStore
    let session: PlayerSession
    let log: DebugLog
    let board: SegmentBoard

    @Bindable private var settings = AppSettings.shared

    private static let scriptSource = "sponsorblock.js"
    private static let historyPrefixes = ["skipped ", "undo", "suggestion"]

    private var videoId: String? { session.playback.meta?.videoId ?? session.playback.snapshot.videoId }
    private var position: Double { session.playback.snapshot.position }

    var body: some View {
        List {
            Section {
                if let meta = session.playback.meta {
                    LabeledContent("Video", value: meta.title.isEmpty ? meta.videoId : meta.title)
                    if let length = meta.lengthSeconds {
                        LabeledContent("Length", value: SegmentDisplay.timestamp(length))
                    }
                } else if videoId == nil {
                    Text("Nothing is playing.").foregroundStyle(.secondary)
                }
            }

            Section {
                segmentRows(board.sponsorBlock, suggested: false, emptyText: sponsorBlockEmptyText)
            } header: {
                Text("SponsorBlock (skipped automatically)")
            } footer: {
                total(board.sponsorBlock)
            }

            Section {
                segmentRows(board.suggested, suggested: true, emptyText: suggestionsEmptyText)
            } header: {
                Text("Possible sponsors (on-device AI, never skipped by itself)")
            } footer: {
                total(board.suggested)
            }

            Section {
                if history.isEmpty {
                    Text("No skips yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(history) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DebugPanelView.time(entry.date))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Skip history")
            } footer: {
                Text("Tap a segment to jump to its start. Times are video time (m:ss).")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func segmentRows(_ entry: SegmentBoard.Entry?, suggested: Bool, emptyText: String) -> some View {
        if let entry, entry.videoId == videoId, !entry.segments.isEmpty {
            ForEach(Array(entry.segments.enumerated()), id: \.offset) { _, segment in
                Button {
                    Task { try? await store.send(.seek(to: segment.start)) }
                } label: {
                    row(segment, suggested: suggested)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Jumps to the start of this segment")
            }
        } else {
            Text(emptyText).foregroundStyle(.secondary)
        }
    }

    private func row(_ segment: SkipSegment, suggested: Bool) -> some View {
        let playingInside = position >= segment.start && position < segment.end
        return HStack(spacing: 10) {
            swatch(segment.category, suggested: suggested)
            VStack(alignment: .leading, spacing: 2) {
                Text(SegmentDisplay.name(segment.category))
                Text(SegmentDisplay.range(segment))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if playingInside {
                Image(systemName: "play.fill").foregroundStyle(.tint).accessibilityLabel("Playing now")
            }
            Text(SegmentDisplay.length(segment))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func swatch(_ category: String, suggested: Bool) -> some View {
        let rgb = SegmentDisplay.rgb(SegmentDisplay.colorHex(category)) ?? (0, 0.83, 0)
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        return RoundedRectangle(cornerRadius: 3)
            .fill(suggested ? color.opacity(0.35) : color)
            .overlay {
                if suggested {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .frame(width: 14, height: 28)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func total(_ entry: SegmentBoard.Entry?) -> some View {
        if let entry, entry.videoId == videoId, !entry.segments.isEmpty {
            let seconds = SegmentDisplay.totalSeconds(entry.segments)
            Text("\(entry.segments.count) segment\(entry.segments.count == 1 ? "" : "s"), \(SegmentDisplay.timestamp(seconds)) in total")
        }
    }

    // MARK: Text

    private var sponsorBlockEmptyText: String {
        if !settings.sponsorBlockEnabled { return "SponsorBlock is off (Settings › SponsorBlock)." }
        if videoId == nil { return "No video." }
        if board.sponsorBlock?.videoId == videoId { return "SponsorBlock has no segments for this video." }
        return "Not looked up yet."
    }

    private var suggestionsEmptyText: String {
        if !settings.aiSponsorDetection { return "On-device detection is off (Settings › SponsorBlock)." }
        if videoId == nil { return "No video." }
        if board.suggested?.videoId == videoId { return "No possible sponsors found." }
        return "Not analysed (it runs only when SponsorBlock has nothing; see the SponsorAI log lines)."
    }

    private var history: [DebugLog.Entry] {
        log.entries.reversed().filter { entry in
            entry.source == Self.scriptSource && Self.historyPrefixes.contains { entry.message.hasPrefix($0) }
        }
    }
}
