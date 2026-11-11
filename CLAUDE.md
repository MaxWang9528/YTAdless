# YTadless

A personal, never-distributed iOS app: a SwiftUI shell around m.youtube.com in WKWebView, with ads
removed, a separate player view you can keep watching while you browse, background audio, PiP, and
lock-screen controls. It is sideloaded with xtool from Windows/WSL. **PLAN.md** has the
architecture, module ownership, interfaces and build order; read it before changing structure.

## Environment (facts, not preferences)

- WSL2 Linux on Windows. **No Xcode, no simulator, no Mac, no Safari Web Inspector.**
- Swift 6.4.2 (swiftly), xtool 1.24.0, Darwin SDK with **iPhoneOS 27.1**. Device: iPhone on iOS 27.2.
- Node 26.13.1 LTS is installed with fnm (`~/.local/share/fnm`, set up in `~/.bashrc`). In a
  non-interactive shell, first run `export PATH="$HOME/.local/share/fnm:$PATH"; eval "$(fnm env --shell bash)"`.
  The JS tests use `node --test`, and jsdom (pinned in `js/package.json`) is the only dev dependency.
  Run `npm ci` in `js/` once per checkout.
- The repo is on `/mnt/c` (slow 9P filesystem). Builds work but are slower than under `~/`.

## Commands

```bash
xtool dev build                     # compile and package the app → xtool/YTadless.app (the only type check for the app target)
xtool dev run                       # build, sign, install, launch on the iPhone; the USER runs this (`! xtool dev run`)
swift test --package-path Core      # tier 1: pure Swift tests (Linux)
(cd js && npm test)                 # tier 2: injected-script tests (Node + jsdom)
(cd js && npm run report)           # per-rule hit counts per fixture (Module A)
(cd js && node tools/capture.mjs <videoId>…)   # refresh anonymous fixtures (Module A)
```

Don't run `xtool dev run` yourself. It signs with the user's Apple account and needs the phone
connected. Build, then ask the user to run it. Plain `swift test` at the repo root **fails by
design** (the app target can't build on Linux); always pass `--package-path Core`.

## Layout and ownership

The tree and per-path owners are in PLAN.md §4. The short version:

- `Package.swift` and `xtool.yml` at the root belong to the app package (iOS only). `Config/Info.plist`
  is a *partial* plist that xtool merges over its defaults, and our keys win. Add any custom key there.
- `Sources/YTadless/{App,Shared}` = composition root + contracts · `Web/`, `Debug/` = Module B ·
  `Player/` = Module C · `Media/` = Module D.
- `Core/` is a separate SwiftPM package (`YTCore` logic, `YTAssets` resources). It must never import
  UIKit, WebKit, AVFoundation, MediaPlayer, SwiftUI or CryptoKit.
- `Core/Sources/YTAssets/scripts/*.js`, `rules/*.txt` and `manifest.json` are the injected scripts
  and filter rules. They ship as resources (`YTCore_YTAssets.bundle`), and the JS tests read the
  same files.
- `TestVectors/` holds cases shared by the Swift and Node tests. `js/` is the Node test project;
  nothing in it ships.
- **Worktree rule:** edit only the paths your module owns. Phase-0 contract files are frozen. Shared
  directories (`TestVectors/`, `js/fixtures/`, `Core/Tests/YTCoreTests/`) are add-only. If a
  contract has to change, stop and ask the user.

## Conventions

**Swift**
- Swift 6 language mode, strict concurrency. App-target types touching UIKit or WebKit are `@MainActor`.
- Logic that can be pure goes in `YTCore` with tests, so app-target code stays a thin adapter.
  App-target code has no unit tests; `xtool dev build` is its only check.
- The two WKWebViews are created once (in `WebViewStore`) and hosted by `WebViewContainer`. Never
  create a WKWebView in `makeUIView`, never put one in a conditional SwiftUI branch, never re-parent one.
- Bridge: JS→native messages are `BridgeMessage` (decoded in YTCore). Native→JS calls go through
  `JSCommand` and `callAsyncJavaScript` with arguments as a JSON string. Never build JS source by
  string interpolation.

**JavaScript (injected scripts)**
- Plain ES2022 **classic scripts**, with no modules, bundler, transpiler or runtime dependencies.
  The file on disk is exactly what runs.
- Each script is one IIFE whose body runs inside `__ytadless.guard('<file>', () => { … })`. A
  script must never throw into the page and never break YouTube when a selector or key is missing.
  Wrap callbacks too (listeners, observers, timers): `(e) => ns.guard(SOURCE, () => …)`.
- Line 1 of every script is `// <file> — owner: Module <X> (PLAN.md §…).`, and the smoke test
  checks it. The runtime API is in PLAN.md §5.2, and the Node harness in §5.7.
- Anything YouTube can change (keys, paths, URL patterns, selectors, timings) goes in a
  `const CONFIG`/`RULES` table at the top of the file. Each entry cites where it came from (uBO
  line, fixture, date).
- Talk to native only through `__ytadless.post` and `__ytadless.command`, and to other scripts only
  through `__ytadless.on`/`emit` (the event names are in PLAN.md §5.2). Keep a reference to every
  native you wrap (`const origPlay = HTMLMediaElement.prototype.play`) and call the original.
- Report work with `filterHit` (ad scripts) and `log` (with your file name as `source`). This is
  the only way to see what happens on device.
- Script order, roles and frames come only from `manifest.json`. Don't reorder it to fix a bug;
  fix the dependency.

**Rule files**: `rules/network.txt` (Adblock Plus subset) and `rules/cosmetic.txt` (`domain##selector`).
The supported syntax is in PLAN.md §5.6. Unsupported syntax is a compile diagnostic, and **any
diagnostic fails `swift test`**.

## Testing strategy

There is no simulator, so design every feature for off-device tests first.

1. **Tier 1 — `swift test --package-path Core`.** Covers routing (plus `TestVectors/routing.json`),
   bridge decoding (plus `TestVectors/bridge/*.json`), command encoding, the manifest (every listed
   file exists), the rule compiler (including "every shipped rule compiles with zero diagnostics"
   and checks against WebKit's regex and condition limits), the playback reducer, and presentation
   state and geometry.
2. **Tier 2 — `cd js && npm test`.** `test/harness.mjs` builds a simulated page (jsdom), injects
   the manifest's scripts for a role in order, and fakes `webkit.messageHandlers`, `fetch` and
   `XMLHttpRequest`. Tests feed saved fixtures through the real scripts:
   - Player and feed fixtures must come out with **no known ad keys** and **content intact**.
   - An **unknown-ad-key scan** flags new ad-like keys (allowlist: `js/fixtures/ad-key-allowlist.json`).
   - Every cosmetic selector must be valid and match the ad nodes in the DOM fixtures.

   Name tests `<script> › <fixture> › <expectation>` so a failure says what broke and where.
3. **Tier 3 — device.** WebView, audio, PiP, lock screen, gestures and sign-in can only be checked
   on the phone. Use the checklist below. Ask the user to run it; report results honestly.

**Fixtures.** `js/fixtures/{player,feed,html,dom}/` are committed and come from *anonymous*
captures (`tools/capture.mjs`). Signed-in captures from the device contain account data. They go in
`js/fixtures/local/` (gitignored) and are never committed. Name fixtures `<YYYY-MM-DD>-<what>-<id>.<ext>`.

### When YouTube breaks something (the usual maintenance loop)

1. On device, open the Debug log: script errors, `filterHit` counters, and `ad-skip-fallback` > 0
   (which means pruning failed).
2. Debug › Capture writes the DOM and the **original** (pre-prune) responses to Files › YTadless.
   Copy the capture into `js/fixtures/local/<date>-<what>/` (Files app → cloud drive, or the Windows
   Apple Devices app → Files).
3. Run `npm test` and `npm run report`. They show which rule stopped hitting and which new ad-like
   keys appeared.
4. Fix it in **one file**:

   | symptom | file to edit |
   |---|---|
   | video ads are back | `player-ads.js` RULES |
   | promoted tiles or shelves are back | `rules/cosmetic.txt`, or `AD_RENDERER_KEYS` in `feed-ads.js` |
   | ad or tracker requests get through | `rules/network.txt` |
   | background play stops | `background.js` |
   | a tap opens in browse instead of the player | `router.js` or `YTCore/Routing` |
5. Check upstream for the same breakage. Look for `m.youtube.com` lines in uBO's
   `quick-fixes.txt`/`filters.txt`, and in Brave's `brave-video-bg-play*.js`. RULES use uBO's
   `json-prune` path dialect, so most fixes port line by line.
6. If the case is new, add an anonymous fixture for it. Rebuild, ask the user to install, and
   re-run the relevant checklist items.

### Device checklist (short; run the items your change touches, or all of them before a merge)

1. Launch → m.youtube.com loads; signed-in state persists across relaunch and reinstall.
2. Home, search, subscriptions: no promoted tiles, shelves or banners.
3. Tap a thumbnail, a title, a search result, a Shorts item and a shared youtu.be link. Each one
   opens in the player, and browse doesn't navigate.
4. 5 known ad-carrying videos: no pre-roll or mid-roll; Debug `ad-skip-fallback` = 0.
5. Player modes: expanded ↔ docked ↔ mini, drag and snap the mini-player, fling to close. Video
   never pauses or reloads on a transition. Rotate to landscape for full screen.
6. Browse while docked or mini: browse never plays media and the player keeps playing.
7. Home button while playing: audio continues. Lock the screen for 10+ min: audio continues.
   Unlock: the UI matches the real state.
8. Lock screen and Control Center: title, channel, artwork, duration and position are correct.
   Play, pause, scrub and ±10 s work.
9. Phone call or Siri mid-playback: pauses, and resumes only if iOS says so. Unplug headphones:
   pauses and stays paused.
10. PiP button → PiP over another app; restore from PiP → player expanded and playing. Fullscreen
    video → swipe home → PiP.
11. Pause via the page, the lock screen and PiP: none of them auto-resumes.
12. Debug log: no `scriptError` during the above.

## Decisions (don't re-argue these without new evidence; full context in PLAN.md §2)

- **D1** Use WKWebView through `UIViewRepresentable`, not the iOS 26 SwiftUI `WebView`/`WebPage`.
  The app needs the full `WKWebViewConfiguration` (inline playback, PiP, content rule lists,
  content worlds, user scripts) and long-lived instances.
- **D2** Two long-lived WKWebViews share `WKWebsiteDataStore.default()`, so there is one login.
  They are never recreated or re-parented, and mode changes only move or scale their containers.
  Detaching a playing webview risks pauses and reloads.
- **D3** Pure logic lives in a separate local package `Core/`. `swift test` builds every target in
  a package, and the iOS app target can't build on Linux (verified).
- **D4** Scripts and rules are resources of the `YTAssets` target, so Swift tests validate the
  shipped rules and the app and Node tests read the same files. xtool packs `YTCore_YTAssets.bundle`
  into the `.app` (verified).
- **D5** All scripts run in the `.page` content world, with one message handler `ytadless`. The
  hooks must patch page globals (`fetch`, `JSON.parse`, `pushState`, `Document.prototype`).
  Accepted cost: the page can see `window.webkit.messageHandlers`.
- **D6** Scripts are classic JS, have no build step, keep their config table at the top, and each
  has one owner. A fix is then an edit to one file, and that file is what runs.
- **D7** Script order and roles live only in `manifest.json`, which both Swift and the Node harness
  read, so device and tests load the same scripts in the same order.
- **D8** Ad stripping is hand-rolled, follows uBO's m.youtube.com rules, and uses uBO's
  `json-prune` path dialect. The alternative, vendoring AdGuard Scriptlets + SafariConverterLib,
  was rejected: GPL dependencies and a build step for about 10 relevant rules. Revisit if upkeep
  grows.
- **D9** Rules are written in an ABP subset and compiled by our Swift `RuleCompiler`; unsupported
  syntax fails tests. WebKit silently drops invalid `css-display-none` selectors, so a typo would
  otherwise do nothing silently.
- **D10** The content-rule-list identifier is a hash (FNV-1a) of the compiled JSON. Recompile only
  when it changes, and if compiling fails, keep the last good list. CryptoKit isn't available on Linux.
- **D11** *(pending user approval)* Lock-screen and Control Center controls go through
  `navigator.mediaSession` in `media-session.js`. WebKit publishes Now Playing for WKWebView media
  and overrides native `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`. The native route is a
  fallback only if spike S-D1 shows Media Session isn't surfaced.
- **D12** The background-resume decision is made synchronously in JS (`background.js`), using
  lifecycle state that native pushes early (at `willResignActive`). WebKit pauses the video before
  `visibilitychange`, and a native round-trip may not arrive before the process is suspended.
- **D13** There is no auto-PiP from inline playback; WebKit can't do it (Apple DTS). PiP starts
  from a user tap (native button → JS, or an in-page button as fallback) or from WebKit fullscreen
  followed by swipe home.
- **D14** The browse view never plays media: `mediaTypesRequiringUserActionForPlayback = .all`, and
  every video link routes to the player. iOS allows one playing video-with-audio session, so
  browse playback would pause the player. The player view uses `[]` so routed videos autoplay.
  Both views set `allowsInlineMediaPlayback = true`.
- **D15** Opening a video does a full load of the watch URL in the player view, not SPA navigation.
  Document-start scripts then run fresh, which is simplest. Optimize later if needed.
- **D16** AVAudioSession is set to `.playback`/`.moviePlayback` at launch and is **not activated**
  at launch, because activating it would stop other apps' audio. WebKit activates it when playback
  starts.
- **D17** The user agent appends a Safari token through `applicationNameForUserAgent`, so Google
  sign-in and YouTube treat the view as Safari.
- **D18** Deployment target is iOS 26.0 (the SDK is 27.1, the device 27.2).
- **D19** The app is its own debugger. JS console warnings and errors and script errors go to an
  in-app log, and Debug › Capture exports the DOM and pre-prune responses for fixtures. There is no
  Web Inspector on Windows.
- **D20** One bundle ID (`com.example.YTadless`) for every worktree and build. Installs replace
  each other and keep the signed-in data container, and Apple ID App-ID limits stay untouched.

## Don'ts

- Don't block `googlevideo.com` media, `/api/stats/{playback,watchtime,qoe}` or
  `/youtubei/v1/log_event`. They carry playback or are used to detect blockers.
- Don't call `AVAudioSession.setActive(true)` at launch, and don't set `MPNowPlayingInfoCenter`
  while D11 stands.
- Don't commit anything from `js/fixtures/local/`, or any capture made while signed in.
- Don't add npm runtime dependencies or a JS bundler, and don't add Swift dependencies to `Core`
  without asking.
