// DebugPlayerMenu — owner: Module C (PLAN.md §6.3: "Open test video" until Module B's router).
//
// DEBUG builds only (`xtool dev build`/`run` default to debug). A small floating button at the
// leading edge opens the player without the router: a fixed test video, or the video the browse
// view is showing (browse is paused first; two playing views pause each other, F13). It can also
// force each presentation mode, for spike S-C1. Hidden while the player is expanded.

#if DEBUG
import SwiftUI
import YTCore

struct DebugPlayerMenu: View {
    let store: WebViewStore
    let session: PlayerSession
    let viewport: PresentationViewport

    private static let testVideos: [(title: String, id: String)] = [
        ("Rick Astley — Never Gonna Give You Up", "dQw4w9WgXcQ"),
        ("Me at the zoo (19 s)", "jNQXAC9IVRw"),
    ]

    var body: some View {
        let isExpanded = session.request != nil && session.presentation == .expanded
        Menu {
            Section("Open in player") {
                // Read at tap time: the browse URL isn't observable, so the menu can't show it.
                Button("The video open in browse") {
                    if let request = Self.request(from: store.browseWebView.url) { open(request) }
                }
                ForEach(Self.testVideos, id: \.id) { video in
                    Button(video.title) { open(Self.videoRequest(id: video.id)) }
                }
            }
            if session.request != nil {
                Section("Presentation") {
                    Button("Expanded") { set(.expanded) }
                    Button("Docked") { set(.docked) }
                    ForEach(PlayerPresentation.Corner.allCases, id: \.self) { corner in
                        Button("Mini \(String(describing: corner))") { set(.mini(corner)) }
                    }
                    Button("Close", role: .destructive) { store.close() }
                }
            }
        } label: {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.purple.opacity(0.75), in: Circle())
        }
        .accessibilityLabel("Debug: open test video")
        .offset(x: viewport.safeArea.leading + 6, y: viewport.size.y * 0.62)
        .opacity(isExpanded ? 0 : 1)
        .allowsHitTesting(!isExpanded)
    }

    private func open(_ request: VideoRequest) {
        store.browseWebView.pauseAllMediaPlayback(completionHandler: nil)
        store.open(request)
    }

    private func set(_ presentation: PlayerPresentation) {
        withAnimation(PlayerAnimation.mode) { session.presentation = presentation }
    }

    /// Canonical watch URL (PLAN.md §6.2), built by hand because Router is still a stub.
    static func videoRequest(id: String, kind: VideoRequest.Kind = .video) -> VideoRequest {
        let url = kind == .short
            ? URL(string: "https://m.youtube.com/shorts/\(id)")!
            : URL(string: "https://m.youtube.com/watch?v=\(id)")!
        return VideoRequest(id: id, kind: kind, watchURL: url)
    }

    /// `/watch?v=ID`, `/shorts/ID` or `/live/ID` on a YouTube host, else nil.
    static func request(from url: URL?) -> VideoRequest? {
        guard let url, let host = url.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let isID = { (s: String) in s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        let parts = url.path.split(separator: "/").map(String.init)
        if url.path == "/watch",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           isID(id) {
            return videoRequest(id: id)
        }
        if parts.count >= 2, isID(parts[1]) {
            switch parts[0] {
            case "shorts": return videoRequest(id: parts[1], kind: .short)
            case "live": return VideoRequest(id: parts[1], kind: .live, watchURL: URL(string: "https://m.youtube.com/watch?v=\(parts[1])")!)
            default: break
            }
        }
        return nil
    }
}
#endif
