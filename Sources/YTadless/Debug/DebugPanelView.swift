// DebugPanelView — owner: Module B (PLAN.md §6.2 Debug tooling, D19).
//
// The Debug sheet: the log (filter by origin and minimum level, newest first, selectable text),
// filterHit counters and status, and actions: Capture (→ Files › YTadless › captures), Copy log,
// Clear, reload either webview.

import SwiftUI
import UIKit
import YTCore

struct DebugPanelView: View {
    let store: WebViewStore
    let session: PlayerSession
    let log: DebugLog

    enum Tab: String, CaseIterable { case log = "Log", counters = "Counters" }
    enum OriginFilter: String, CaseIterable { case all = "All", browse = "Browse", player = "Player", native = "Native" }

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .log
    @State private var origin: OriginFilter = .all
    @State private var minimumLevel: LogLevel = .info
    @State private var captureStatus: String?
    @State private var capturing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                if let captureStatus {
                    Text(captureStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                        .textSelection(.enabled)
                }

                switch tab {
                case .log: logList
                case .counters: countersList
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Copy log", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = log.exportedText()
                        }
                        Button("Reload browse", systemImage: "arrow.clockwise") { store.browseWebView.reload() }
                        Button("Reload player", systemImage: "arrow.clockwise") { store.playerWebView.reload() }
                        Button("Clear log", systemImage: "trash", role: .destructive) { log.clear() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await capture() }
                    } label: {
                        if capturing { ProgressView() } else { Label("Capture", systemImage: "square.and.arrow.down") }
                    }
                    .disabled(capturing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { log.markErrorsSeen() }
        .onDisappear { log.markErrorsSeen() }
    }

    // MARK: Log

    private var filteredEntries: [DebugLog.Entry] {
        let minimum = Self.rank(minimumLevel)
        return log.entries.reversed().filter { entry in
            guard Self.rank(entry.level) >= minimum else { return false }
            switch origin {
            case .all: return true
            case .browse: return entry.origin == .browse
            case .player: return entry.origin == .player
            case .native: return entry.origin == .native
            }
        }
    }

    private var logList: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Origin", selection: $origin) {
                    ForEach(OriginFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Spacer()
                Picker("Level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { Text("≥ \($0.rawValue)").tag($0) }
                }
            }
            .padding(.horizontal)
            List(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Self.time(entry.date))
                        Text(entry.level.rawValue.uppercased()).foregroundStyle(Self.color(entry.level)).bold()
                        Text(entry.origin.rawValue + (entry.isMainFrame ? "" : "/sub"))
                        Text(entry.source).foregroundStyle(.secondary)
                    }
                    .font(.caption2.monospaced())
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .overlay {
                if filteredEntries.isEmpty {
                    ContentUnavailableView("No log lines", systemImage: "text.alignleft",
                                           description: Text("Lower the level or pick another origin."))
                }
            }
        }
    }

    // MARK: Counters

    private var countersList: some View {
        List {
            Section("Status") {
                LabeledContent("Script errors", value: "\(log.scriptErrorCount)")
                LabeledContent("Content rules", value: log.contentRulesStatus)
                LabeledContent("Build", value: WebViewStore.buildString)
                LabeledContent("Player", value: session.request?.watchURL.absoluteString ?? "—")
                LabeledContent("Presentation", value: String(describing: session.presentation))
            }
            Section("filterHit (both views)") {
                let hits = log.filterHits.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                if hits.isEmpty {
                    Text("No hits yet").foregroundStyle(.secondary)
                }
                ForEach(hits, id: \.key) { hit in
                    LabeledContent {
                        Text("\(hit.value)").monospacedDigit()
                    } label: {
                        Text(hit.key)
                            .font(.caption.monospaced())
                            .foregroundStyle(hit.key == "ad-skip-fallback" ? Color.red : Color.primary)
                    }
                }
            }
        }
    }

    // MARK: Capture

    private func capture() async {
        capturing = true
        defer { capturing = false }
        do {
            let result = try await CaptureWriter.capture(store: store, session: session, log: log)
            captureStatus = "Saved to Files › YTadless › captures/\(result.folder.lastPathComponent)\n" +
                result.notes.joined(separator: "\n")
        } catch {
            captureStatus = "Capture failed: \(error)"
            log.native(.error, "Capture", "failed: \(error)")
        }
    }

    // MARK: Formatting

    private static func rank(_ level: LogLevel) -> Int {
        switch level {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    private static func color(_ level: LogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warn: .orange
        case .error: .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
