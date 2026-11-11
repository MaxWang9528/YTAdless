# YTadless: Plan

Status (2026-11-11): plan and scaffold only. No app code yet. Read CLAUDE.md first; it holds the
conventions and the decisions this plan relies on (D1, D2, … below refer to CLAUDE.md §Decisions).

## 1. What we're building

A personal, never-distributed iOS app: a native SwiftUI shell around **m.youtube.com** running in
WKWebView. YouTube's own player plays the video. The app adds:

1. **Ad-free playback and browsing.** Three layers: a WKContentRuleList (network blocking plus
   static element hiding), document-start scripts that strip ad fields from player and feed data,
   and cosmetic hiding of promoted tiles and shelves.
2. **Watch while browsing.** Two WKWebViews, `browse` and `player`, share one data store (one
   login). Tapping a video in `browse` opens it in `player`. The player can be expanded, docked at
   the top, or a draggable mini-player.
3. **Background audio.** Playback continues when the app is backgrounded or the screen is locked.
4. **Picture-in-picture** over other apps, and **lock-screen / Control Center** controls showing
   title, duration, play/pause and seek.

Non-goals: a general-purpose browser, a native YouTube client (no innertube playback of our own),
downloads, distribution, iPad-specific UI.

## 2. Findings that shape the design

| # | Finding | Consequence | Verified how |
|---|---------|-------------|--------------|
| F1 | `xtool.yml` `infoPath:` names a partial Info.plist that xtool **merges over its defaults; our keys win**. xtool's defaults allow **portrait only** on iPhone. | `Config/Info.plist` holds `UIBackgroundModes: [audio]`, the landscape orientations, and (in Phase 0) the file-sharing keys. | xtool source (`PackLib/Planner.swift`), plus the scaffold's built `Info.plist` |
| F2 | xtool walks SwiftPM dependencies and copies each resource bundle (`<Package>_<Target>.bundle`) into the `.app`. `Bundle.module` resolves it through `Bundle.main.resourceURL`. Local path packages work. | Scripts and rules ship as resources of a `YTAssets` target in the Core package. | Test project built with `xtool dev build`. Bundle present in `.app`; accessor inspected |
| F3 | `swift test` builds **every** target in a package. An iOS target that imports SwiftUI fails on Linux (`no such module 'SwiftUI'`). | Pure logic lives in a **separate local package** `Core/` (D3). `swift test --package-path Core` passed on Linux, including `Bundle.module` resource loading. | Ran both in the scratchpad |
| F4 | Toolchain: Swift 6.4.2, xtool 1.24.0, iOS SDK **27.1**, device iOS 27.2. | Deployment target `iOS 26.0` (D18). | `xtool sdk status`, SDKSettings.json |
| F5 | **Node is not installed** in WSL. | It must be installed before the JS tests run (CLAUDE.md §Setup). | `which node` |
| F6 | uBO's m.youtube.com rules: `set ytInitialPlayerResponse.{adPlacements,playerAds,adSlots}`; `json-prune playerResponse.adPlacements … adSlots`; `json-prune-fetch-response` on `/player`, `/get_watch`, `resolve_url` (`endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.*`); Shorts `entries.[-].command.reelWatchEndpoint.adClientParams.isAd` on `reel_watch_sequence`; `json-edit-fetch-response ..itemSectionRenderer.contents.*[?.adSlotRenderer]` on `/get_watch`. mweb routes watch-page navigations through **`/youtubei/v1/get_watch`**, which returns an array (`[].playerResponse…`). | These rules are the starting point for layer 2. The JSON path engine speaks uBO's `json-prune` dialect so upstream fixes port line by line (D8). | `uAssets/filters/filters.txt`, `quick-fixes.txt` |
| F7 | EasyList's m.youtube.com cosmetic rules: `ytm-companion-slot[data-content-type] > ytm-companion-ad-renderer`, `ytm-rich-item-renderer > ad-slot-renderer`, `lazy-list > ad-slot-renderer`. | Starting content for `rules/cosmetic.txt`. | `easylist_specific_hide.txt` |
| F8 | WKContentRuleList: actions `block`, `block-cookies`, `css-display-none`, `ignore-previous-rules`, `make-https`. **At most one condition per trigger** (`if-domain`/`unless-domain`/`if-top-url`/`unless-top-url`). Domains must be lowercase ASCII. The regex subset has no `\|` and no `{n}`. **A `css-display-none` rule with an invalid selector is silently skipped.** | The Swift RuleCompiler validates rules itself, and unsupported or invalid syntax fails the tests (D9). | WebKit `ContentExtensionParser.cpp`, `ContentExtensionError.cpp` |
| F9 | When an app with an inline video goes to the background, WebKit **pauses the video first, then fires `visibilitychange`**. Calling `play()` resumes audio in the background (given `UIBackgroundModes: audio` and a `.playback` session). Brave iOS's `MediaBackgroundingScript` relies on this: it spoofs `visibilityState`, tracks pauses that page code initiated, and re-plays system pauses. | `background.js` follows the same approach, plus intent tracking (D12). | Apple forums thread 819235 (DTS answer); Brave source |
| F10 | YouTube (Jan–Feb 2026) made background play **Premium-only in mobile browsers**: playback stops seconds after the screen goes dark. Brave's `brave-video-bg-play` scriptlet counters it with visibility spoofing, `_lact` refresh, `mediaSession` handler wrapping, and pause→replay. | Background play is the **highest-risk feature**. All of its countermeasures live in one file. | 9to5Google 2026-02-02; `brave/adblock-resources` |
| F11 | **Automatic PiP from inline WKWebView playback is not possible.** Apple DTS: PiP must come from a user-initiated action. `autopictureinpicture` works only when leaving *fullscreen*. Swipe-home from WebKit's fullscreen video does enter PiP. | PiP comes from a button tap, or from fullscreen video plus swipe home (D13). | Apple forums thread 819235 |
| F12 | **WebKit publishes Now Playing itself** for WKWebView media, and overrides the app's own `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` settings. WebKit supports `navigator.mediaSession` (metadata, `setPositionState`, action handlers). | Recommended: drive lock-screen controls from JS through Media Session. Native MP* is the fallback (D11, **needs your approval**; it changes the original spec). | Apple forums (WKWebView overriding Now Playing; hiding WKWebView lock-screen controls); WebKit bugs about Now Playing SPI |
| F13 | iOS lets only one video-with-audio media session play at a time. | The browse view must never play media (D14). | WebKit `MediaSessionManagerIOS` restrictions |
| F14 | No Mac means no Safari Web Inspector. | The app must be its own debugger: JS console and errors forwarded to an in-app log, plus an on-device capture of the DOM and original responses for fixtures (D19). | — |

## 3. Architecture

```
┌──────────────────────────── App target  Sources/YTadless  (iOS only) ──────────────────────────┐
│ RootView[P0] ── PlayerLayoutView[C] ── WebViewContainer(browse)   WebViewContainer(player)        │
│                    │ reads/writes presentation      ▲ hosts long-lived WKWebViews (never re-parented)│
│              PlayerSession[P0] (@Observable: request, presentation, PlaybackState)                │
│                ▲                         ▲                                                        │
│  MediaCoordinator[D]               WebViewStore[B] owns both WKWebViews (shared data store):      │
│   AVAudioSession, lifecycle,        configuration · user scripts from manifest · content rules ·  │
│   interruptions → JS commands       message handler → BridgeEventHub[P0] · Router · JS commands    │
└────────────────────────────────┬───────────────────────────────────────────▲─────────────────────┘
          JSCommand ─ callAsyncJavaScript (page world)        BridgeMessage ─ webkit.messageHandlers.ytadless
                                 ▼                                           │
┌─────────── page world of each WKWebView  (Core/Sources/YTAssets/scripts, order from manifest.json) ┐
│ config prelude → bridge.js[P0] → debug.js[B] → hooks.js · player-ads.js · feed-ads.js[A] →          │
│ router.js[B] → player-bridge.js[P0→D] · background.js · media-session.js[D] → layout.js[C]          │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
  + WKContentRuleList compiled at launch from rules/network.txt + rules/cosmetic.txt [A], applied by [B]

Core package (pure Swift, Linux-testable): YTCore = Router · Bridge types · PlaybackState ·
PlayerPresentation · RuleCompiler · ScriptManifest/ScriptConfig;  YTAssets = scripts/, rules/, manifest.json
```

[P0] = written in Phase 0. [A]–[D] = module that owns it.

## 4. Repository layout and ownership

```
YTadless/
├── CLAUDE.md  PLAN.md
├── Package.swift          P0   app package (iOS); depends on ./Core
├── xtool.yml              P0
├── Config/Info.plist      P0   partial plist merged by xtool
├── Sources/YTadless/
│   ├── App/               P0   YTadlessApp, AppServices (composition root), RootView
│   ├── Shared/            P0   PlayerSession, BridgeEventHub, PlayerControlling, WebViewContainer
│   ├── Web/               B    WebViewStore, configuration, navigation/UI delegates, rule-list loader
│   ├── Debug/             B    log store + viewer, capture/export
│   ├── Player/            C    PlayerLayoutView and everything it uses
│   └── Media/             D    MediaCoordinator, audio session, lifecycle, PiP glue, (fallback) NowPlaying
├── Core/                       SwiftPM package "YTCore". No UIKit/WebKit/AVFoundation.
│   ├── Package.swift      P0
│   ├── Sources/YTCore/
│   │   ├── Bridge/        P0   BridgeMessage, JSCommand, decoding
│   │   ├── Scripts/       P0   ScriptManifest, ScriptConfig (prelude)
│   │   ├── Playback/      P0, then D   PlaybackState reducer; D adds pure policy helpers
│   │   ├── Routing/       P0 types, B logic
│   │   ├── Presentation/  P0 type, C state machine + mini-player geometry
│   │   └── Rules/         P0 API stub, A compiler + validator
│   ├── Sources/YTAssets/  resource target: YTAssets.swift (P0), manifest.json (P0),
│   │   ├── scripts/       bridge.js P0 · debug.js, router.js B · hooks.js, player-ads.js, feed-ads.js A
│   │   │                  player-bridge.js P0→D · background.js, media-session.js D · layout.js C
│   │   └── rules/         network.txt, cosmetic.txt A
│   └── Tests/YTCoreTests/ one file per area: BridgeTests (P0), RoutingTests (B), RulesTests (A), …
├── TestVectors/           cross-language cases read by Swift AND Node tests (routing.json, bridge/*.json)
└── js/                    Node test project. Nothing in here ships.
    ├── package.json       P0   node --test; jsdom is the only devDependency
    ├── test/harness.mjs   P0   simulated page: loads manifest scripts, fake bridge, fake fetch/XHR
    ├── test/<script>.test.mjs  owned by the script's owner
    ├── fixtures/          player/ feed/ html/ dom/ bridge/  (local/ is gitignored: signed-in captures)
    └── tools/             capture.mjs, report.mjs (A)
```

**Ownership rules** (these are what make parallel worktrees safe):

1. A module edits only the paths it owns. Phase-0 files are **frozen** once Phase 0 is merged:
   `Package.swift` (both), `xtool.yml`, `Config/Info.plist`, `App/`, `Shared/`, `Bridge/`,
   `Scripts/`, `manifest.json`, `bridge.js`, `js/package.json`, `js/test/harness.mjs`.
2. "P0 → X" means Phase 0 writes a first version and X owns the file from then on.
3. Shared directories (`TestVectors/`, `js/fixtures/`, `Core/Tests/YTCoreTests/`) are
   **add-only**. Add new files; never modify or delete a file another module created.
4. If a module needs a frozen contract to change, it stops and asks the user rather than editing.
   Phase 0 defines the full contract up front (§5) so this should be rare.

## 5. Interfaces

### 5.1 Script manifest (`Core/Sources/YTAssets/manifest.json`, P0, frozen)

Swift (`ScriptManifest`) and the Node harness both read this file, so the device and the tests
load the same scripts in the same order. All scripts run in the **page** content world (D5).

| # | file | roles | injection | frames | owner |
|---|------|-------|-----------|--------|-------|
| 0 | *(generated config prelude)* | both | start | all | P0 |
| 1 | bridge.js | both | start | all | P0 |
| 2 | debug.js | both | start | all | B |
| 3 | hooks.js | both | start | all | A |
| 4 | player-ads.js | both | start | all | A |
| 5 | feed-ads.js | both | start | all | A |
| 6 | router.js | both | start | main | B |
| 7 | player-bridge.js | player | start | main | P0→D |
| 8 | background.js | player | start | main | D |
| 9 | media-session.js | player | start | main | D |
| 10 | layout.js | player | end | main | C |

```json
{ "version": 1,
  "scripts": [ { "file": "bridge.js", "roles": ["browse","player"], "injection": "start", "mainFrameOnly": false, "owner": "P0" } ] }
```

### 5.2 In-page runtime: `window.__ytadless` (bridge.js, P0)

A non-enumerable, frozen namespace. The name is a single constant in bridge.js and ScriptConfig.

| member | purpose |
|---|---|
| `config` | `{role: 'browse'\|'player', debug: bool, build: string}`, from the generated prelude |
| `post(type, payload)` | `webkit.messageHandlers.ytadless.postMessage({v:1, type, frame:'main'\|'sub', ...payload})`; no-op when the handler is missing (tests use a fake) |
| `on(evt, fn)` / `emit(evt, data)` | event bus between scripts in the page |
| `command(name, fn)` | registers a native→JS command handler; each name has exactly one owner (§5.4) |
| `cmd(name, argsJSON)` | entry point for native code; returns a JSON-safe result or `{error}`; never throws |
| `log(level, source, ...args)` | posts `log` |
| `guard(source, fn)` | runs `fn` and reports exceptions as `scriptError`; every script body runs inside it |
| `hooks` | set by hooks.js (A): `addPruner({name, urls?, paths?, fn?})`, `originals` (debug ring buffer of pre-prune responses) |

In-page events:

| event | payload | emitter | listeners |
|---|---|---|---|
| `playerResponse` | `(pr, {source:'initial'\|'fetch'\|'xhr', url})`, after pruning | hooks.js (A) | player-bridge.js, media-session.js |
| `navigation` | `{url}` on every SPA URL change | router.js (B) | player-bridge.js, layout.js |
| `videoElement` | the main `<video>` each time it is (re)attached | player-bridge.js | background.js, media-session.js |
| `userIntent` | `{action:'play'\|'pause'\|'seek', source:'page'\|'native'\|'remote'}` | player-bridge.js, media-session.js | background.js |

### 5.3 JS → native messages (handler name `ytadless`, page world)

Every message carries `v: 1`, `type`, and `frame: 'main' | 'sub'`. Native code logs and ignores
unknown types. Each type has a sample JSON file in `TestVectors/bridge/` that Swift decodes and
the Node tests compare against.

| type | fields | posted by | consumed by |
|---|---|---|---|
| `ready` | `role, url` | bridge.js | B: debug log; re-queries `state` |
| `log` | `level, source, message` | any (debug.js forwards `console.warn/error`) | B: Debug log |
| `scriptError` | `source, message, stack?` | `guard` | B: Debug log + badge |
| `route` | `url, trigger: 'click'\|'history'\|'windowOpen'` | router.js | B → `Router.decide` |
| `pageChanged` | `url, title?` | router.js | B → `PlayerSession` |
| `filterHit` | `rule, count` | hooks.js and the ad scripts | B: Debug counters |
| `videoMeta` | `videoId, title, author, lengthSeconds?, thumbnailURL?, isLive` | player-bridge.js | `PlaybackState` → C, D |
| `playback` | `status, position, duration?, rate, videoId?` | player-bridge.js (~1 Hz while playing, plus on every change) | `PlaybackState` |
| `presentation` | `mode: 'inline'\|'pip'\|'fullscreen'` | player-bridge.js | `PlaybackState`; D (PiP restore → expand) |

### 5.4 Native → JS commands

Native sends commands with
`callAsyncJavaScript("return window.__ytadless ? __ytadless.cmd(name, args) : {error:'no-bridge'}", arguments: ["name": …, "args": <JSON string>], in: nil, contentWorld: .page)`.
Arguments always travel as a JSON string, never interpolated into source.

| command | args → result | handler (owner) | sent by |
|---|---|---|---|
| `play`, `pause` | — | player-bridge.js (D) | C buttons, D |
| `seek` | `{to}` | player-bridge.js | C, D |
| `seekBy` | `{delta}` | player-bridge.js | C |
| `pip` | `{enter}` | player-bridge.js (D) | C's PiP button, **called inside the tap handler** |
| `state` | → `{meta, playback, presentation}` | player-bridge.js | B on `ready` and on foreground |
| `lifecycle` | `{state:'active'\|'inactive'\|'background'}` | background.js (D) | D |
| `audioInterruption` | `{phase:'began'\|'ended', shouldResume}` | background.js (D) | D |
| `layout` | `{mode:'page'\|'video'}` | layout.js (C) | C |
| `capture` | → `{url, title, html, originals[], counters, log[]}` | debug.js (B) | B Debug menu |

### 5.5 Swift contracts (Phase 0 writes every signature; owners fill in bodies)

```swift
// ── Core/Sources/YTCore (public, Sendable, Linux-clean) ─────────────────────────────
public enum WebRole: String, Codable, Sendable { case browse, player }

// Routing — types P0, logic B
public struct VideoRequest: Hashable, Sendable {
    public enum Kind: String, Sendable { case video, short, live }
    public var id: String; public var kind: Kind
    public var startSeconds: Int?; public var playlistID: String?; public var playlistIndex: Int?
    public var watchURL: URL                       // canonical https://m.youtube.com/... to load
}
public enum LinkKind: Equatable, Sendable { case video(VideoRequest), youtubePage(URL), signIn(URL), external(URL), ignore }
public enum NavigationTrigger: String, Codable, Sendable { case click, history, windowOpen, location, initial }
public enum RouteDecision: Equatable, Sendable { case allow, openInPlayer(VideoRequest), openInBrowse(URL), openExternally(URL), cancel }
public enum Router {
    public static func normalize(_ url: URL) -> URL    // www./music. → m., http → https, youtu.be → watch
    public static func classify(_ url: URL) -> LinkKind
    public static func decide(_ url: URL, role: WebRole, trigger: NavigationTrigger) -> RouteDecision
}

// Bridge — P0
public enum LogLevel: String, Codable, Sendable { case debug, info, warn, error }
public enum BridgeMessage: Equatable, Sendable {
    case ready(role: WebRole, url: String)
    case log(level: LogLevel, source: String, message: String)
    case scriptError(source: String, message: String, stack: String?)
    case route(url: String, trigger: NavigationTrigger)
    case pageChanged(url: String, title: String?)
    case filterHit(rule: String, count: Int)
    case videoMeta(VideoMeta)
    case playback(PlaybackSnapshot)
    case presentation(MediaPresentation)
    case unknown(type: String)
    /// `body` is WKScriptMessage.body (an NSDictionary bridged to Any).
    public static func decode(_ body: Any) throws -> (message: BridgeMessage, isMainFrame: Bool)
}
public enum AppLifecycle: String, Sendable { case active, inactive, background }
public enum PageLayout: String, Sendable { case page, video }
public enum JSCommand: Equatable, Sendable {
    case play, pause, seek(to: Double), seekBy(Double), pip(enter: Bool), state
    case lifecycle(AppLifecycle), audioInterruption(began: Bool, shouldResume: Bool)
    case layout(PageLayout), capture
    public var name: String { get }
    public var argumentsJSON: String { get }
}

// Playback — P0 (D may add pure helpers alongside)
public enum PlaybackStatus: String, Codable, Sendable { case idle, loading, playing, paused, buffering, ended }
public enum MediaPresentation: String, Codable, Sendable { case inline, pip, fullscreen }
public struct VideoMeta: Codable, Equatable, Sendable { videoId, title, author: String; lengthSeconds: Double?; thumbnailURL: String?; isLive: Bool }
public struct PlaybackSnapshot: Codable, Equatable, Sendable { status: PlaybackStatus; position: Double; duration: Double?; rate: Double; videoId: String? }
public struct PlaybackState: Equatable, Sendable {
    public var meta: VideoMeta?; public var snapshot: PlaybackSnapshot; public var presentation: MediaPresentation
    public mutating func apply(_ message: BridgeMessage)          // ignores messages it doesn't care about
}

// Presentation — type P0, state machine + geometry C
public enum PlayerPresentation: Equatable, Sendable {
    public enum Corner: Sendable { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    case hidden, expanded, docked, mini(Corner)
}

// Scripts — P0
public struct ScriptManifest: Decodable, Sendable {           // decodes manifest.json
    public struct Entry: Decodable, Sendable { file: String; roles: [WebRole]; injection: Injection; mainFrameOnly: Bool; owner: String }
    public enum Injection: String, Decodable, Sendable { case start, end }
    public func entries(for role: WebRole) -> [Entry]
}
public enum ScriptConfig { public static func prelude(role: WebRole, debug: Bool, build: String) -> String }

// Rules — API P0 (stub returns an empty list), implementation A
public struct RuleDiagnostic: Equatable, Sendable { file: String; line: Int; message: String }
public struct CompiledRules: Sendable { public let json: String; public let identifier: String; public let diagnostics: [RuleDiagnostic] }
public enum ContentRules { public static func compile(network: String, cosmetic: String) -> CompiledRules }  // identifier = "ytadless-" + FNV-1a(json)

// ── Core/Sources/YTAssets ───────────────────────────────────────────────────────────
public enum YTAssets { public static func text(_ relativePath: String) throws -> String }  // "manifest.json", "scripts/x.js", "rules/y.txt"

// ── Sources/YTadless/Shared (P0, frozen) ────────────────────────────────────────────
@MainActor @Observable final class PlayerSession {
    var request: VideoRequest?                       // nil = nothing loaded in the player
    var presentation: PlayerPresentation = .hidden
    var playback = PlaybackState()
    var browseTitle: String?
    func collapseForBrowsing()                       // .expanded → .mini(.bottomTrailing); other modes unchanged
}
@MainActor protocol PlayerControlling: AnyObject {
    func open(_ request: VideoRequest)               // load in player webview; .hidden → .expanded
    func close()                                     // pause, blank the player, → .hidden
    @discardableResult func send(_ command: JSCommand) async throws -> String?   // JSON result
}
@MainActor final class BridgeEventHub {
    struct Event { let role: WebRole; let isMainFrame: Bool; let message: BridgeMessage }
    func subscribe(_ handler: @escaping @MainActor (Event) -> Void) -> AnyObject   // keep the token; drop it to unsubscribe
    func publish(_ event: Event)
}
struct WebViewContainer: UIViewRepresentable { let webView: WKWebView }   // hosts an existing view; never creates one

// ── Module entry points, created as stubs in P0, owned by their module ──────────────
@MainActor final class WebViewStore: PlayerControlling {      // B (P0 writes a working minimal version)
    let browseWebView: WKWebView; let playerWebView: WKWebView
    init(session: PlayerSession, hub: BridgeEventHub)
}
@MainActor final class MediaCoordinator { init(session: PlayerSession, player: any PlayerControlling, hub: BridgeEventHub); func start() }  // D
struct PlayerLayoutView: View { init(store: WebViewStore, session: PlayerSession) }                                                      // C
```

### 5.6 Rule file formats (A)

`rules/network.txt` is a small subset of Adblock Plus syntax. `!` starts a comment.

| syntax | becomes |
|---|---|
| `\|\|example.com^` | `block`; `url-filter` matching the domain and its subdomains |
| `\|\|youtube.com/pagead/` | `block` on a URL prefix |
| `$script,image,stylesheet,xhr,media,font,ping,subdocument` | `resource-type` (`xhr` → `fetch` + `raw`, `subdocument` → `child-document`) |
| `$third-party` / `$~third-party` | `load-type` |
| `$domain=a.com\|b.com` / `$domain=~a.com` | `if-domain: ["*a.com", …]` / `unless-domain` (one condition per rule, F8) |
| `@@…` | `ignore-previous-rules`; the compiler emits all exceptions after all blocks |
| `/regex/` | raw `url-filter`, validated against WebKit's regex subset |

`rules/cosmetic.txt` uses `domain##selector` or `##selector`, compiled to `css-display-none`.

Anything else is a **diagnostic, and the test suite fails on any diagnostic**: `##+js(…)`,
`#?#`, `:has-text()`, `#@#`, `$replace`, `$redirect`, `$removeparam`. Logic like that belongs in
the JS layer.

## 6. Feature designs

### 6.1 Ad blocking (Module A)

**Layer 1, WKContentRuleList.** Compiled at launch from the two rule files. Each block below runs
at launch:

1. `ContentRules.compile` produces the JSON and an identifier (a hash of the JSON).
2. The app looks up that identifier in `WKContentRuleListStore.default()`.
3. If the lookup misses, it compiles the list and removes stale identifiers.
4. If compiling fails, it falls back to the last good identifier and logs the error (D10).

The list is applied to both webviews before the first page load. Starting network rules:
`||doubleclick.net^`, `||googlesyndication.com^`, `||googleadservices.com^`,
`||youtube.com/pagead/`, `||youtube.com/api/stats/ads`, `||youtube.com/ptracking`,
`||youtube.com/youtubei/v1/player/ad_break`, `||youtube.com/get_midroll_`.

**Never block** `googlevideo.com` media, `/api/stats/{playback,watchtime,qoe}`, or `/youtubei/v1/log_event`.
YouTube uses them for playback and for detecting blockers, and uBO leaves them alone on mweb.

Cosmetic rules start from F7, plus candidates to confirm against DOM fixtures:
`ytm-promoted-sparkles-web-renderer`, `ytm-promoted-video-renderer`,
`ytm-rich-item-renderer:has(> ad-slot-renderer)`, `ytm-mealbar-promo-renderer`,
`ytm-statement-banner-renderer`.

Spike S-B2 checks whether `:has()` works inside `css-display-none` on device. If it doesn't, the
compiler emits `:has()` selectors into an injected stylesheet instead. That switch lives in one
place, the compiler.

**Layer 2, player-response stripping** (`hooks.js` engine plus the `player-ads.js` RULES table).

`hooks.js` installs each interception point once and dispatches to the registered pruners:

- a `JSON.parse` wrapper
- a `fetch` wrapper that re-wraps matching responses in a new `Response` and preserves `url`, `status` and `headers`
- an `XMLHttpRequest` wrapper (`responseText`/`response`)
- accessor traps on `window.ytInitialPlayerResponse`, `ytInitialData` and `ytplayer`, so
  `var ytInitialPlayerResponse = {…}` in an inline script goes through our setter

The path engine implements the uBO `json-prune` subset: `a.b`, `*`, `[]`, `..key`, `[-]` (remove
the containing array element), and `[?.key]`. It also supports text replacement
(`"adPlacements"` → `"no_ads"`), uBO's other strategy. Each RULES entry carries a comment with
the uBO line it came from. Initial RULES are the F6 lines that apply to m.youtube.com.

Last resort: an `ad-showing` watcher on `#movie_player`. If an ad still renders, it mutes, jumps
to the end, clicks Skip, and reports `filterHit('ad-skip-fallback')`. That fallback firing means
pruning failed, which shows up in the Debug log.

**Layer 3, feed ads** (`feed-ads.js`). An `AD_RENDERER_KEYS` table drives a generic walk over
`ytInitialData` and the `/youtubei/v1/{browse,search,next,get_watch,guide,reel/*}` responses. The
walk removes any array element whose own key, or whose `richItemRenderer.content` /
`richSectionRenderer.content` key, is in the table.

Known keys: `adSlotRenderer`, `promotedSparklesWebRenderer`, `promotedVideoRenderer`,
`compactPromotedVideoRenderer`, `searchPyvRenderer`. Candidates to confirm against fixtures:
`promotedSparklesTextSearchRenderer`, `statementBannerRenderer`, `mealbarPromoRenderer`,
`brandVideoShelfRenderer`, `brandVideoSingletonRenderer`. CSS from layer 1 is the backstop.
There is no DOM-based procedural filtering in v1.

**Generic fixture assertions** apply to every player/feed fixture:

1. No known ad key remains anywhere after pruning.
2. Content survives: `videoDetails`, `streamingData`, and the count of non-ad feed items are unchanged.
3. An **unknown-ad-key scan** lists any remaining key matching `/(^|[a-z])(ad|ads|promo|promoted|sponsor)[A-Z_]/i`
   that isn't in `js/fixtures/ad-key-allowlist.json`. This is how a renamed ad renderer surfaces
   as soon as a fresh fixture lands.

`npm run report` prints hits per rule per fixture, which shows which rule stopped matching new
captures.

### 6.2 Routing and watch-while-browsing (Module B)

Routing has three layers. The JS click handler has to decide synchronously, so JS carries a small
classifier, and both implementations are checked against `TestVectors/routing.json`.

1. **Click capture** (router.js, primary). A capture-phase `click` on `document` finds the
   nearest `a[href]`. If the role/kind pair should leave this view (browse + video, or player +
   non-video page), it calls `preventDefault` and `stopImmediatePropagation`, then posts
   `route{trigger:'click'}`.
2. **History hook** (backstop). Wraps `pushState`/`replaceState` and listens for `popstate`.
   SPA URL changes post `pageChanged` and emit `navigation`. A video URL pushed in the browse
   view (a navigation that slipped past click capture) posts `route{trigger:'history'}`. Native
   then opens the player and calls `history.back()` in browse. `window.open` is hooked the same
   way.
3. **WKNavigationDelegate / WKUIDelegate.** Handles full loads, `target=_blank`, and external
   links. All three layers end up in `Router.decide`.

Decision table (`Router.decide`):

| role | link | decision |
|---|---|---|
| browse | video / short / live / youtu.be | `openInPlayer` |
| browse | YouTube page (home, channel, search, playlist page) | `allow` |
| any | Google sign-in / consent | `allow` |
| player | video (related, playlist next, autoplay) | `allow` (stays in the player) |
| player | YouTube non-video page | `openInBrowse` + `session.collapseForBrowsing()` |
| any | `youtube.com/redirect?q=…` | `openExternally(q)` |
| any | other site | `openExternally` |

Opening a video does a full `load` of `VideoRequest.watchURL` in the player view (D15).
`m.youtube.com` and `www.` links are normalized.

Other B work:

- **User agent.** `applicationNameForUserAgent` set to the Safari token
  (`Version/… Mobile/15E148 Safari/604.1`), so Google sign-in and YouTube treat the view as Safari
  (spike S-B1).
- **Debug tooling.** Log viewer (bridge `log`, `scriptError`, `filterHit`), and Capture, which
  calls the JS `capture` command and writes a timestamped folder to Documents. The Phase 0
  Info.plist enables `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, so captures
  appear in Files and in the Windows Apple Devices app's file sharing.

### 6.3 Player UI (Module C)

`PlayerLayoutView` lays out both webviews. Each one lives in a single persistent container that is
**never removed or re-parented** (D2); mode changes only animate frame, offset and scale.

| mode | player | browse |
|---|---|---|
| hidden | off-screen; the WKWebView stays in the hierarchy | full screen |
| expanded | full screen, normal watch page (`layout: page`) | behind |
| docked | top strip, 16:9, `layout: video` | below the strip |
| mini(corner) | floating 16:9; the docked-size view with a `CGAffineTransform` scale so the page doesn't reflow at a tiny width; `layout: video` | full screen |

Expanded in landscape becomes a full-screen video (`layout: video`); the landscape orientations
come from Config/Info.plist. Gestures: drag down from expanded goes to mini (or to docked, past a
threshold); tap mini to expand; drag mini to snap to a corner; fling it off-screen to `close()`.

The native chrome for docked and mini has play/pause, close, expand, and PiP, driven by
`session.playback`. In expanded mode, YouTube's own controls are used.

`layout.js` adds a class plus a stylesheet on `<html>`. In `video` mode it hides the top bar and
everything else, and pins the player container to the viewport.

Pure parts go in `YTCore/Presentation`: the transition rules (`next(after: gesture)`) and the
mini-player geometry (snap targets, velocity projection, docked height). They are tested there.

Until B merges, C can open videos through a `#if DEBUG` "Open test video" entry inside its own files.

### 6.4 Background audio, PiP, Now Playing (Module D)

**Audio session.** Set `.playback` with mode `.moviePlayback` at launch, without activating it
(D16). Observers:

- `interruptionNotification` sends `audioInterruption`.
- `routeChangeNotification` with `.oldDeviceUnavailable` (headphones unplugged) sends `pause`
  with native intent.
- Scene phase sends `lifecycle`, starting at `willResignActive` (the earliest point), so JS knows
  before WebKit pauses.

**background.js.** It neutralizes these signals, and the list in the file is the source of truth:

- `Document.prototype.hidden`, `visibilityState`, `webkitHidden`, `webkitVisibilityState`, `onvisibilitychange`
- page listeners for `visibilitychange` and `webkitvisibilitychange` (ours runs first and stops propagation)
- `document.hasFocus()` → `true`
- window `blur`
- `_lact` refresh every few minutes
- `youThereRenderer` ("Are you still watching?"), pruned through `hooks.addPruner`
- YouTube's `webkitpresentationmodechanged` reactions

**Resume policy** runs synchronously in JS (D12) and is table-tested. A pause is *intentional*
when any of these hold:

- a `userIntent` arrived within about 1.5 s (page tap, native button, or remote command)
- the video is in PiP (any PiP pause is the user's)
- an audio interruption is active
- the video `ended`

Any other pause while native lifecycle is `inactive` or `background`, or during the ≤2 s window
before the real `visibilitychange`, is reversed by calling the **original** `HTMLMediaElement.prototype.play`.
There is a cap of 3 automatic resumes per 30 s, then it gives up and logs, so it never loops
against YouTube.

**player-bridge.js.** Tracks the main `<video>` (MutationObserver plus `navigation`) and emits
`playback`, `videoMeta` (from the `playerResponse` event; the DOM is the fallback) and
`presentation`. It implements play/pause/seek/seekBy/pip/state. `pip` calls
`video.webkitSetPresentationMode('picture-in-picture')`, falling back to `requestPictureInPicture()`.

**PiP** (D13). Two entry points: C's button, or WebKit fullscreen followed by swipe home.
Restoring from PiP (`presentation` inline, still playing) makes MediaCoordinator set
`presentation = .expanded`.

Spike S-D3 checks that a native button calling `callAsyncJavaScript` counts as user activation.
If it doesn't, the fallback injects a PiP button into YouTube's player DOM so the tap happens
inside the page.

**Now Playing** (D11, recommended, needs your approval). `media-session.js` owns
`navigator.mediaSession`:

- It wraps `MediaSession.prototype.setActionHandler` and the `metadata` setter so YouTube's writes are ignored.
- It sets `MediaMetadata` (title, channel, thumbnail) from `videoMeta`.
- It calls `setPositionState` on `loadedmetadata`, `play`, `pause`, `seeked` and `ratechange`.
- Its handlers cover `play`, `pause`, `seekto`, `seekbackward` / `seekforward` (10 s), and
  `previoustrack` / `nexttrack` (playlists). Each handler emits `userIntent{source:'remote'}`
  before acting.

Fallback, only if spike S-D1 shows WebKit doesn't surface Media Session in Control Center:
`Media/NowPlayingController` using `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`, fed from
`PlaybackState` and sending `JSCommand`s.

## 7. Testing strategy (details and commands in CLAUDE.md)

| tier | runs where | covers |
|---|---|---|
| 1. `swift test --package-path Core` | Linux/WSL | Router (+TestVectors), bridge decoding (+TestVectors/bridge), JSCommand encoding, ScriptManifest (every file exists; order), RuleCompiler (conversions, WebKit-subset validation, **all shipped rules compile with zero diagnostics**), PlaybackState reducer, presentation state machine and geometry |
| 2. `cd js && npm test` | Linux/WSL, Node + jsdom | every injected script, loaded by the harness in manifest order into a simulated page with a fake bridge, fetch and XHR; fixture-driven ad tests (§6.1); router click and history tests against TestVectors; background resume-policy tables; media-session against a mocked `navigator.mediaSession`; layout.js against a DOM fixture |
| 3. Device checklist | iPhone | WebView, audio, PiP, lock screen, gestures, sign-in. Short list in CLAUDE.md |

`xtool dev build` is the only type check for the app target, and no unit tests run there, so app
code stays thin.

## 8. Build order

### Phase 0: Foundation (one session, sequential). **Must merge before A–D start.**

1. `git init`; commit the scaffold.
2. Create `Core/` (YTCore, YTAssets, YTCoreTests). The app package depends on it. Both build and test.
3. Write every §5 contract: Swift types with real implementations for Bridge, Scripts,
   PlaybackState and ScriptConfig; signature-only stubs returning safe defaults for Router
   (`.allow`), ContentRules (empty list), and Presentation geometry.
4. `manifest.json` with all 11 entries; `bridge.js` complete; every other script a stub IIFE
   wrapped in `guard` with an owner header; a minimal `player-bridge.js` (find the video; emit
   `playback`/`videoMeta`; handle play/pause/seek/state); empty rule files with format headers.
5. App: `AppServices` builds `PlayerSession`, `BridgeEventHub`, `WebViewStore` (two webviews,
   shared `WKWebsiteDataStore.default()`, the final config flags from D14, scripts injected from
   the manifest, handler → hub, `send` through `callAsyncJavaScript`, `open`/`close`),
   `MediaCoordinator` stub, and `PlayerLayoutView` stub (browse full screen; player as a plain
   overlay when `request != nil`). Add the file-sharing keys to Info.plist.
6. `js/`: `package.json` (`"type":"module"`, `"test": "node --test"`, jsdom), `harness.mjs`
   (`createPage({role, url, html?})`, `loadManifestScripts`, `runInline(src)`, fake
   `webkit.messageHandlers`, `fakeFetch(routes)`, `FakeXHR`), and `smoke.test.mjs`: every
   script loads in both roles with no `scriptError`, `ready` is posted, and the
   `var ytInitialPlayerResponse = …` trap fires in the harness.
7. `TestVectors/routing.json` (≥25 cases) and `TestVectors/bridge/*.json` (one per message type).
8. Done when `swift test`, `npm test` and `xtool dev build` are green, and m.youtube.com still
   loads and plays inline on the device. Message flow is covered off-device by the smoke test and
   the decode tests; on device it first becomes visible when B's Debug log lands. Then tag `phase0`.

### Phase 1: four parallel modules (separate worktrees from `phase0`)

| module | owns (§4) | delivers | first device spike | done when |
|---|---|---|---|---|
| **A. Ad filtering** | hooks.js, player-ads.js, feed-ads.js, rules/, YTCore/Rules, js/tools, ad fixtures | §6.1 complete; `capture.mjs` (anonymous fixtures via Node fetch with an iPhone Safari UA: watch HTML → `ytInitialPlayerResponse`/`ytInitialData`, innertube `player`/`get_watch`/`browse`/`search`, `reel_watch_sequence`); ≥3 videos with ads, one Short, home and search feeds; `report.mjs` | (after B's rule loader merges) S-B2 `:has()` in `css-display-none` | tests green; on device, no pre-roll or mid-roll on 5 ad-carrying videos; no promoted tiles on home or search; `ad-skip-fallback` stays at 0 |
| **B. WebView, routing, debug** | Web/, Debug/, YTCore/Routing, router.js, debug.js | §6.2: Router, router.js, delegates, content-rule loader with last-good fallback, UA, Debug log and Capture | S-B1 Google sign-in in the webview; S-B2 rule-list compile on device | routing vectors green; on device, every tap path (thumbnail, title, Shorts shelf, search result, notification, shared youtu.be) opens the player and browse stays put |
| **C. Player UI** | Player/, YTCore/Presentation, layout.js | §6.3 | S-C1: a playing WKWebView keeps playing through frame and scale animations and survives mini ↔ expanded with no reload | gestures and modes work on device; no pause or reload on any transition; landscape full screen |
| **D. Media** | Media/, YTCore/Playback (helpers), player-bridge.js, background.js, media-session.js | §6.4 | **S-D1 first** (what WebKit shows in Control Center with and without our Media Session), then S-D2 background and lock, then S-D3 PiP | the checklist's background, lock, PiP and lock-screen items pass, including after 10+ min locked |

Any module that needs a device run builds with `xtool dev build`, then asks you to run
`! xtool dev run`. Every worktree uses the same bundle ID (D20), so installs replace each other and
the login survives.

```bash
# after Phase 0 is committed on main and tagged phase0
git worktree add ../YTadless-A -b module/a-adblock phase0
git worktree add ../YTadless-B -b module/b-web     phase0
git worktree add ../YTadless-C -b module/c-player  phase0
git worktree add ../YTadless-D -b module/d-media   phase0
# then, in each: claude  → "Implement Module X per PLAN.md §8; stay inside your owned paths."
```

### Phase 2: Integration (sequential)

Merge in this order: **B → A → D → C**. B makes the others testable on device: rules applied,
routing, debug log. Paths are disjoint, so merges should be conflict-free; a conflict means an
ownership rule was broken. After each merge, run `swift test`, `npm test` and `xtool dev build`,
then the relevant checklist items. Finish with the full checklist and a CLAUDE.md update for
anything learned.

## 9. Risks and open questions

| risk | likelihood | mitigation |
|---|---|---|
| YouTube's 2026 Premium gating defeats background play in web clients (F10) | **high** | every known countermeasure lives in background.js; check Brave's `brave-video-bg-play*` for new tricks; PiP still works as a fallback |
| Google blocks sign-in inside embedded webviews | medium | Safari UA token (S-B1). If it still blocks, try signing in at `accounts.google.com/ServiceLogin?continue=https://m.youtube.com/` with the full Safari UA. Last resort is undecided |
| YouTube moves ads server-side (SSAI) or adds the attestation and "network machine" checks uBO already fights on www | medium, growing | the ad-skip fallback covers SSAI-ish cases; RULES speak uBO's dialect so fixes port fast; the fixtures show what changed |
| YouTube grabs a pristine `fetch`/`JSON` from a fresh iframe (uBO's `trusted-prevent-dom-bypass` on www) | low on mweb today | hooks.js also patches `HTMLIFrameElement.prototype.contentWindow` if this shows up |
| WebKit Now Playing interplay (F12) | medium | Media Session first; native fallback only after S-D1 |
| A native tap → `callAsyncJavaScript` doesn't count as user activation for PiP | low–medium | in-page PiP button fallback |
| Two webviews in one app: anything playing in browse pauses the player (F13) | medium | D14: browse requires a user action for all media, and every video link routes away |
| Builds on `/mnt/c` are slow (9P filesystem) | low | optional: keep the repo under `~/` in WSL |
| Free Apple ID: app expires after 7 days; App ID limits | if applicable | one bundle ID; re-run `xtool dev run` weekly |

## 10. Sources

- xtool `Sources/PackLib/{PackSchema,Planner,Packer}.swift`: github.com/xtool-org/xtool
- uBO filters: github.com/uBlockOrigin/uAssets `filters/filters.txt`, `filters/quick-fixes.txt`
- EasyList: github.com/easylist/easylist `easylist/easylist_specific_hide.txt`
- WebKit content blockers: `Source/WebCore/contentextensions/ContentExtensionParser.cpp`, `ContentExtensionError.cpp`; `loader/ResourceLoadInfo.cpp`
- Brave: `brave/adblock-resources` `resources/brave-video-bg-play*.js`; `brave/brave-core` `ios/brave-ios/.../Paged/MediaBackgroundingScript.js`
- Apple forums: [PiP on background from inline WKWebView](https://developer.apple.com/forums/thread/819235), [WKWebView background audio](https://developer.apple.com/forums/thread/781787), [hide WKWebView lock-screen controls](https://developer.apple.com/forums/thread/785925)
- [MPNowPlayingInfoCenter not working with WKWebView playback](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/35208744/mpnowplayinginfocenter-not-working-with-wkwebview-playback)
- [9to5Google: YouTube background playback workarounds not working (2026-02-02)](https://9to5google.com/2026/02/02/youtube-background-playback-workarounds-not-working-third-party-browsers/)
