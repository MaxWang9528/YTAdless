# YTadless

Replicates the YouTube mobile app UI (kinda), but ad-free.

YTadless is a personal iPhone app. It wraps **m.youtube.com** (YouTube's mobile website) in a native
SwiftUI shell, strips the ads out, and adds what the website lacks in Safari: a separate
player you can keep watching while you browse, background audio, picture-in-picture,
lock-screen controls, a sleep timer and sponsor skipping. YouTube's own website and player do the
actual playback. YTadless doesn't download or re-stream video.

It's built and installed entirely from Windows/WSL with [xtool](https://github.com/xtool-org/xtool),
with no Mac or Xcode.

---

## Features

### Ad-free YouTube
- **No video ads:** no pre-rolls, mid-rolls or ad breaks.
- **No promoted content:** promoted tiles, shelves, banners and "sponsored" search results
  are removed from Home, Search, Subscriptions and the watch page.
- **Ad and tracker requests are blocked** at the network level.

### Sponsor skipping
- **SponsorBlock** (on by default) looks up community-marked segments (sponsors, self-promotion,
  intros, etc.) from [sponsor.ajay.app](https://sponsor.ajay.app). They're drawn on the seek
  bar, and a **Skip** button appears when one starts. You can switch on "Skip automatically",
  which skips them with an **Undo** button. Privacy: only the first 4 characters of a SHA-256
  hash of the video ID are sent, never the ID itself.
- **On-device AI detection** (on by default) covers videos SponsorBlock has nothing for. The
  video's transcript is analysed **on the iPhone** with Apple Intelligence, and likely ad reads
  are marked as "possible sponsors" (dashed marks, with a Skip prompt). The transcript never
  leaves the phone. Requires an iPhone with Apple Intelligence.

### Extra
- **Picutre-in-picture:** Keep a video overlay on screen when other apps are in foreground
- **Sleep timer**: automatically stop video playback after set time or when the video ends.
- **Background play**: keep video playing when in background or when phone is locked.


### Settings
Open the **Debug panel** (the small ladybug button on the left edge, or shake the iPhone) →
**Settings**:


### Built-in debugging
There's no Web Inspector without a Mac, so the app is its own debugger. The Debug panel has:
- **Log:** page console warnings/errors, script errors and app events, filterable by view and level.
- **Segments:** what SponsorBlock and the AI found for the current video, with timestamps.
- **Counters:** how often each ad-blocking rule fired.
- **Capture** (a button in the panel's toolbar): saves the page and the original (un-stripped) YouTube responses to the
  Files app, so a breakage can be reproduced and fixed off the phone.

---

## Details

### The big picture

```
┌──────────────── SwiftUI app (Sources/YTadless) ────────────────┐
│  PlayerLayoutView                                              │
│   ├─ browse WKWebView × 3  (Home / Subscriptions / You)        │
│   └─ player WKWebView      (expanded · mini · full screen)     │
│  WebViewStore · Router · MediaCoordinator · Debug/Settings     │
└───────────────▲──────────────────────────────┬─────────────────┘
   BridgeMessage│ webkit.messageHandlers        │ JSCommand (callAsyncJavaScript)
┌───────────────┴──────────────────────────────▼─────────────────┐
│  Injected scripts in each page (Core/Sources/YTAssets/scripts)  │
│  bridge → debug → hooks → player-ads → feed-ads → router →      │
│  player-bridge → background → media-session → sponsorblock →    │
│  layout                                                         │
└─────────────────────────────────────────────────────────────────┘
  + WKContentRuleLists compiled from rules/network.txt + rules/cosmetic.txt
```

The app is a thin native layer around long-lived `WKWebView`s that all load m.youtube.com and
share one website data store, so there's a single YouTube login:

- **Browse views**, one per bottom-nav tab (Home, Subscriptions, You). The one on screen is
  visible; the others stay in the view tree at opacity 0, so each tab keeps its page and scroll.
  Browse views are configured so they **never play media**
  (`mediaTypesRequiringUserActionForPlayback = .all`), because iOS allows only one playing video
  with audio at a time.
- **The player view** plays whatever video you open. It is moved, scaled and clipped between
  expanded, mini and full-screen layouts, but it is **never recreated or re-parented**, because
  detaching a playing web view can pause or reload it. That's why transitions never interrupt
  the video.

All the YouTube-specific behaviour lives in plain JavaScript files injected into every page at
document start, plus two filter-rule files. Native Swift and the scripts talk over a small,
typed bridge.

### Ad blocking: three layers

1. **Network and element rules.** `rules/network.txt` (an Adblock Plus subset, e.g.
   `||doubleclick.net^`, `||youtube.com/pagead/`) and `rules/cosmetic.txt` (`domain##selector`)
   are compiled by a Swift `RuleCompiler` into WebKit `WKContentRuleList`s. They block ad and
   tracker requests and hide ad elements before they render. The compiler rejects syntax WebKit
   would silently ignore, and the tests fail on any diagnostic. Compiled lists are cached by a
   hash of their JSON, and if a compile ever fails the last good list is kept.
2. **Stripping ads from YouTube's data** (`hooks.js` + `player-ads.js`). Before YouTube's own code
   sees them, `hooks.js` intercepts `JSON.parse`, `fetch`, `XMLHttpRequest` and the inline page
   globals (`ytInitialPlayerResponse`, `ytInitialData`). `player-ads.js` then deletes ad fields
   (`adPlacements`, `playerAds`, `adSlots`, …) using the same path syntax as uBlock Origin's
   `json-prune`, so upstream uBO fixes port line by line. If an ad ever plays anyway, a fallback
   mutes it, jumps to its end, clicks Skip and records `ad-skip-fallback` in the Debug counters.
3. **Feed ads** (`feed-ads.js`). It walks feed, search and watch-page responses and removes
   any item whose renderer is a known ad type (`adSlotRenderer`, `promotedVideoRenderer`,
   `searchPyvRenderer`, …). The cosmetic rules are the backstop.

Requests YouTube needs for playback or uses to detect blockers (`googlevideo.com` media,
`/api/stats/playback|watchtime|qoe`, `/youtubei/v1/log_event`) are deliberately never blocked.

### Routing: why taps open the player

`router.js` catches link taps in the capture phase and classifies the URL. A tap on a video in a
browse view is cancelled and sent to native as a `route` message. As backstops, a hook on
`history.pushState` catches single-page navigations that slip through, and the navigation
delegate catches full loads, new windows and external links. Everything ends in one Swift
decision, `Router.decide` (in `YTCore/Routing`):

| From | Link | Result |
|---|---|---|
| browse | video, Short, live, `youtu.be` | open in the player |
| browse | YouTube page (home, channel, search, playlist) | stay in browse |
| player | another video (related, autoplay, playlist) | stay in the player |
| player | non-video YouTube page | collapse the player, open the page in browse |
| any | Google sign-in / consent | allow |
| any | other site, `youtube.com/redirect` | open in Safari |

Opening a video does a full load of a clean watch URL (`https://m.youtube.com/watch?v=…`, keeping
only `t`, `list` and `index`) in the player view. Swift and JS share the same test cases
(`TestVectors/routing.json`), so both classifiers agree.

### Player layout

`PlayerLayoutView` asks `PresentationLayout` (pure, tested code in `YTCore/Presentation`) for
every frame, scale and corner radius in each mode, and only feeds those numbers to fixed
SwiftUI containers. The gesture logic (when a drag minimizes, expands, snaps or closes) is a
tested state machine too. Inside the page, `layout.js` restyles m.youtube.com's watch page
to look like the app: it hides the site's top bar and bottom nav, puts the video at the top and
lets it scroll with the page, and in mini/full-screen mode pins the video to fill its frame.
YouTube's full-screen button is redirected to the app's own landscape layout, so in-page
controls like the Skip button stay visible.

### Background audio, PiP and lock screen

- **Audio session.** `.playback` / `.moviePlayback`, set at launch but not activated (so
  launching doesn't stop your music). WebKit activates it when a video starts. The app declares the
  `audio` background mode.
- **Staying alive in the background** (`background.js`). When the app goes to the background,
  WebKit pauses the video, and YouTube's mobile site stops background play for non-Premium users.
  The script hides the signals the site watches (`document.hidden`/`visibilityState`,
  `visibilitychange`, focus/blur, idle timers, "Are you still watching?"). Native also pushes the
  app's lifecycle state early (at `willResignActive`), so the script can tell a **system** pause
  from a **user** pause and resume only the former. A pause from a page tap, the lock screen, PiP,
  an audio interruption or the end of the video is never resumed, and automatic resumes are
  capped so the script can't loop against YouTube.
- **Lock screen and Control Center** (`media-session.js`). WebKit publishes Now Playing for web
  media itself, so the app drives it through the web Media Session API. It sets the title,
  channel, artwork and position, and handles play/pause/seek/±10 s. YouTube's own Media Session
  calls are ignored.
- **Picture-in-picture.** WebKit can't start PiP automatically from inline playback, so it starts
  from the PiP button (native → `player-bridge.js` → `webkitSetPresentationMode`). Restoring from
  PiP brings the player back expanded.
- **Sleep timer.** The decisions are pure code (`YTCore/Playback/SleepTimer`). When it fires it
  sends a native "pause" that `background.js` treats as intentional.

### SponsorBlock and on-device detection

- **SponsorBlock** (`Media/SponsorBlockService.swift`). For each video it requests
  `sponsor.ajay.app/api/skipSegments/<first 4 hex chars of sha256(videoId)>`, keeps only this
  video's segments in your enabled categories, merges overlaps and caches the result.
  `sponsorblock.js` draws the segments on YouTube's seek bar and shows the Skip/Undo buttons or
  skips automatically. It never skips while an ad is showing.
- **On-device AI** (`Media/SponsorDetectionService.swift`, `SponsorDetector.swift`). It only runs
  when SponsorBlock has nothing for a video. It gets the video's English captions, from the page's
  caption tracks or, when those need a token YouTube won't give out, from an anonymous
  `/youtubei/v1/player` request. It cuts the transcript into overlapping windows, uses a keyword
  prefilter to drop windows that clearly aren't ad reads, and asks Apple's on-device model
  (FoundationModels) to mark sponsor reads in the rest. Answers are validated, snapped to caption
  times and merged in tested YTCore code, then sent to the page as "possible sponsor" segments.

### The native ↔ page bridge

- **Page → native.** `bridge.js` sets up `window.__ytadless` with `post`, `on`/`emit`, `guard`,
  `log` and `filterHit`. Scripts send typed messages (`route`, `playback`, `videoMeta`,
  `scriptError`, `filterHit`, …) through one message handler, `ytadless`, and Swift decodes them
  into a `BridgeMessage` enum (`YTCore/Bridge`).
- **Native → page.** Commands (`play`, `pause`, `seek`, `pip`, `sponsorSegments`, `capture`, …)
  are encoded as `JSCommand`s and run with `callAsyncJavaScript`, with arguments passed as a JSON
  string, never by building JavaScript source.
- **Safety.** Every script body and callback runs inside `__ytadless.guard(...)`, so a missing
  selector or a changed YouTube key logs an error instead of breaking the page. Anything YouTube
  can change (keys, URL patterns, selectors, timings) sits in a `CONFIG`/`RULES` table at the
  top of the script, with a note on where it came from.
- **Order.** `manifest.json` is the single source of script order, roles (browse/player) and
  frames. The app and the tests both read it.

### Other details

- The web views identify as Safari (`applicationNameForUserAgent`), so Google sign-in and YouTube
  behave normally.
- `Config/Info.plist` adds the audio background mode, landscape orientations and file sharing
  (for Debug captures) on top of xtool's defaults.

---

## Repository layout

```
Package.swift, xtool.yml       app package (iOS only)
Config/Info.plist              partial Info.plist merged over xtool's defaults
Sources/YTadless/
  App/                         app entry, composition root, RootView
  Shared/                      PlayerSession, bridge hub, WebViewContainer (contracts)
  Web/                         WebViewStore, navigation delegate, content-rule loader
  Debug/                       Debug panel, log, capture, Settings
  Player/                      PlayerLayoutView, header/mini-player chrome, gestures, full screen
  Media/                       audio session, lifecycle, sleep timer, SponsorBlock, AI detection
Core/                          separate pure-Swift package, testable on Linux
  Sources/YTCore/              routing, bridge types, playback state, presentation geometry,
                               rule compiler, SponsorBlock, sponsor detection, sleep timer
  Sources/YTAssets/            the shipped scripts/*.js, rules/*.txt and manifest.json
  Tests/YTCoreTests/           Swift tests
TestVectors/                   test cases shared by the Swift and Node tests
js/                            Node test project (jsdom harness, fixtures, tools); nothing ships
tools/                         ad hoc distribution script (see tools/README.md)
PLAN.md                        architecture, interfaces and design decisions in full
CLAUDE.md                      conventions, environment, decisions and the device checklist
```

`Core/` is separate because `swift test` builds every target in a package, and the iOS app target
can't build on Linux. Keeping the logic there means it is tested, and the app target stays a thin
adapter.

---

## Building and testing

Requirements: WSL2/Linux, Swift 6.4+, xtool with the Darwin/iPhoneOS SDK, Node 26 for the JS
tests.

```bash
xtool dev build                       # compile and package → xtool/YTadless.app
xtool dev run                         # build, sign, install and launch on a connected iPhone
swift test --package-path Core        # Swift tests (plain `swift test` fails by design)
(cd js && npm ci && npm test)         # injected-script tests in a simulated page (jsdom)
(cd js && npm run report)             # per-rule ad-blocking hit counts per fixture
```

There is no simulator, so testing has three tiers:

1. **Swift (Linux).** Routing, bridge decoding, command encoding, the manifest, the rule compiler
   (every shipped rule must compile with zero diagnostics), the playback reducer, presentation
   geometry, SponsorBlock parsing, sponsor-detection merging, and the sleep timer.
2. **JavaScript (Node + jsdom).** The harness loads the real scripts in manifest order into a fake
   page with a fake bridge, `fetch` and XHR, and feeds them saved YouTube responses
   (`js/fixtures/`). Player and feed fixtures must come out with no known ad keys and the content
   intact. An unknown-ad-key scan flags new ad-like keys, and every cosmetic selector must be valid
   and match the ad nodes in DOM fixtures.
3. **Device.** WebView behaviour, audio, PiP, the lock screen, gestures and sign-in, using the
   checklist in CLAUDE.md.

### When YouTube changes something
Open the Debug log on the phone (script errors, rule counters, `ad-skip-fallback` > 0), run
Debug › Capture, copy the capture into `js/fixtures/local/`, and run `npm test` and
`npm run report` to see which rule stopped matching. Most fixes are an edit to one file:
`player-ads.js` RULES for video ads, `rules/cosmetic.txt` or `feed-ads.js` for promoted tiles,
`rules/network.txt` for requests, `background.js` for background play, and `router.js` /
`YTCore/Routing` for taps opening in the wrong place. The full loop is in CLAUDE.md.

---

## Installing on other iPhones

`tools/adhoc-ipa.sh` builds an ad hoc–signed `.ipa` for the iPhones registered in a
provisioning profile, which can then be installed from a link or a cable. See
[tools/README.md](tools/README.md).

## Disclaimer

A personal project, not affiliated with YouTube or Google. Stripping ads goes against YouTube's
Terms of Service. Use at your own risk.
