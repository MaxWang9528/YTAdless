// sponsorblock.js — owner: Module D (PLAN.md §5.4 `sponsorSegments`, `captionTracks`, `suggestedSegments`; §6.4, §6.5).
//
// Skips SponsorBlock segments in the player's main video, shows on-device *guesses* without
// skipping them, and hands native the caption tracks those guesses are made from. Native
// (SponsorBlockService, on-device detection) does all network work; this file never fetches.
//   handles  `sponsorSegments {videoId, segments: [{start, end, category}]}` → {ok: true, count}
//            (invalid segments are dropped one by one; segments for another video than the page's
//            are ignored, count 0). A re-send for the same video keeps what was already skipped.
//            `suggestedSegments {videoId, segments: [{start, end, category}]}` → {ok: true, count}
//            Same validation and video check. Suggestions are NEVER skipped by themselves: they
//            are drawn striped (outlined, fainter) on the seek bar, and when the playhead enters one a "Possible
//            sponsor" toast offers Skip (once per segment per load; seeking back before its start
//            re-arms it). A suggestion overlapping a real segment is not drawn or prompted.
//            `captionTracks {}` → {videoId: string|null, tracks: [{baseUrl, languageCode, kind, name}]}
//            for the page's current video, from the `playerResponse` event (per-video cache, so a
//            prefetch of the next video doesn't replace it) or window.ytInitialPlayerResponse.
//            baseUrl is absolute and only ever https://{m.,www.,}youtube.com/api/timedtext…;
//            kind is 'asr' or ''; name is plain text. No tracks → tracks: [] (never an error).
//   listens  `videoElement` (player-bridge.js) for re-attachments; also looks the video up itself,
//            because that event doesn't replay emissions from before this file's listener.
//            `playerResponse` (hooks.js) for caption tracks.
//   emits    `userIntent` {action:'seek', source:'page'} before the Undo seek and the suggestion
//            Skip seek (real taps), and NOT before automatic skips: a userIntent makes
//            background.js treat a pause in the next ~1.5 s as intentional (D12), so a skip while
//            locked could leave a system pause unresumed. An automatic skip isn't the user's intent.
// Each segment is skipped at most once per load: seeking back into it plays it. A toast over the
// player says what was skipped and offers Undo (seek back to the segment's start). One toast at a
// time; an automatic-skip toast replaces a suggestion prompt, never the other way round.
// Markers: every segment is drawn as a coloured span on YouTube's seek bar (SponsorBlock's
// colours), so you can see what will be skipped; suggestions are striped, fainter and carry
// data-suggested="1". When no seek bar is found (its classes are unverified on device), a thin
// strip along the bottom of the player shows them instead. The first render logs which one was used.
(() => {
  'use strict';

  const SOURCE = 'sponsorblock.js';
  const CONFIG = Object.freeze({
    // Same as player-bridge.js CONFIG (mweb DOM, 2026-11; no fixture yet).
    VIDEO_SELECTORS: ['#movie_player video', 'video.html5-main-video', 'video'],
    PATH_ID: /^\/(?:shorts|live)\/([A-Za-z0-9_-]{11})(?:[/?#]|$)/,
    QUERY_ID: /^[A-Za-z0-9_-]{11}$/,
    // Media events that can land the playhead in a segment.
    MEDIA_EVENTS: ['timeupdate', 'seeked', 'playing', 'loadedmetadata', 'durationchange'],
    HAVE_METADATA: 1,           // HTMLMediaElement.readyState: currentTime/duration are meaningful
    // Inside [start, end - END_EPSILON_S) counts as "in the segment": at its very end a seek
    // gains nothing (timeupdate fires ~4 Hz, i.e. every ~0.25 s, per the HTML spec's 15–250 ms).
    END_EPSILON_S: 0.3,
    // A segment starting this close to the video's end isn't skipped: the seek would only race
    // the natural `ended` (and YouTube's autoplay of the next video).
    END_GUARD_S: 0.5,
    MAX_SEGMENTS: 200,          // a sane cap on what native may send
    MAX_CATEGORY_CHARS: 40,
    // While an ad plays, currentTime is the ad's (player-ads.js CONFIG.AD_CLASS on #movie_player).
    AD_SHOWING_SELECTOR: '#movie_player.ad-showing',
    // Toast over the player (player-bridge.js PIP_CONTAINER_SELECTORS; unverified on device).
    TOAST_CONTAINER_SELECTORS: ['#movie_player', '#player-container-id', '#player'],
    TOAST_ID: 'ytadless-sponsorblock-toast',
    TOAST_MS: 4000,
    // Seek bar the markers go in, first match wins. mweb class names as of 2024–2026 (the
    // SponsorBlock extension's mobile selectors and YouTube's shared progress bar); NOT in a
    // fixture and unverified on device (2026-11-25): Debug › Capture a watch page to confirm.
    SEEK_BAR_SELECTORS: [
      '#movie_player .ytProgressBarLineProgressBarLine',
      '#movie_player .YtmProgressBarProgressBarLine',
      '#movie_player .ytm-progress-bar',
      '#movie_player .ytp-progress-bar',
    ],
    // When none of those match (the case on device, 2026-11-25: "markers on fallback strip"), the
    // bar is found by shape: among these candidates inside the player, the thinnest element at
    // least BAR_MIN_WIDTH_FRACTION of the player wide and at most BAR_MAX_HEIGHT_PX tall is the
    // visible track line (a slider's hit area is taller than its line). Found by geometry, so it
    // survives class renames; the log names what it picked, so a capture isn't needed to learn it.
    SEEK_BAR_CANDIDATES: [
      '#movie_player [role="slider"]',
      '#movie_player [class*="progress" i]',
      '#movie_player [class*="scrubber" i]',
      '#movie_player [class*="timebar" i]',
    ],
    BAR_MIN_WIDTH_FRACTION: 0.4,
    BAR_MAX_HEIGHT_PX: 40,
    MARKERS_ID: 'ytadless-sponsorblock-markers',
    FALLBACK_STRIP_PX: 3,       // height of the strip along the player's bottom edge
    MARKER_OPACITY: '0.85',
    MARKER_CHECK_MS: 1000,      // re-find the bar at most this often (YouTube re-renders controls)
    // SponsorBlock's default category colours (extension config.ts barTypes, 2026-11).
    CATEGORY_COLORS: Object.freeze({
      sponsor: '#00d400',
      selfpromo: '#ffff00',
      interaction: '#cc00ff',
      intro: '#00ffff',
      outro: '#0202ed',
      preview: '#008fd6',
      music_offtopic: '#ff9900',
      filler: '#7300ff',
    }),
    DEFAULT_COLOR: '#00d400',
    // Suggested (on-device guess) markers: stripes in the category colour, fainter than real
    // ones, with an outline so a thin span still reads as "maybe" (our own style, 2026-11-25).
    SUGGESTED_OPACITY: '0.6',
    SUGGESTED_STRIPE_PX: 4,
    // Suggestion prompt: visible while the playhead is inside the segment, at most this long.
    SUGGEST_TOAST_MS: 8000,
    // Caption tracks (player fixtures 2026-11-24-player-*.json: captions.playerCaptionsTracklistRenderer
    // .captionTracks[] with a relative baseUrl `/api/timedtext?v=…&lang=…`, languageCode, kind
    // 'asr' on auto-captions only, name {runs:[{text}]}; {simpleText} in older responses).
    CAPTION_TRACKS_PATH: ['captions', 'playerCaptionsTracklistRenderer', 'captionTracks'],
    CAPTION_HOSTS: ['m.youtube.com', 'www.youtube.com', 'youtube.com'],
    CAPTION_PATH_PREFIX: '/api/timedtext',
    CAPTION_CACHE_SIZE: 8,      // videos remembered (prefetch of the next video; player-bridge.js META_CACHE_SIZE)
    MAX_CAPTION_TRACKS: 100,    // the 2026-11-24 fixtures have 6–18
    MAX_CAPTION_TEXT_CHARS: 200,
    // Labels (SponsorBlock categories: https://wiki.sponsor.ajay.app/w/Types, read 2026-11-25).
    CATEGORY_LABELS: Object.freeze({
      sponsor: 'sponsor',
      selfpromo: 'self-promotion',
      interaction: 'interaction reminder',
      intro: 'intro',
      outro: 'outro',
      preview: 'preview',
      music_offtopic: 'non-music section',
      filler: 'filler',
    }),
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    let video = null;
    let videoId = null;        // the video the stored segments belong to
    let segments = [];         // [{start, end, category, key}] sorted by start
    const done = new Set();    // keys skipped (or undone) in this load: never skipped again
    let suggestVideoId = null; // the video the stored suggestions belong to
    let suggestions = [];      // same shape as segments; never skipped automatically
    const prompted = new Set();  // suggestion keys prompted in this load (seeking back before the start re-arms)
    let toast = null;
    let toastTimer = null;
    let toastKind = '';        // 'skip' (automatic skip, Undo) | 'suggest' (prompt, Skip) | ''
    let toastKey = '';         // the segment the toast is about
    let markers = null;        // {el, host, key, fallback}
    let markersCheckedAt = -Infinity;
    let loggedMarkerHost = '';
    // The last seek bar seen, as insets of the player's width (0–1), so the fallback strip lines
    // up with YouTube's bar while the controls are hidden. null until a bar was measured.
    let barInsets = null;
    const captionCache = new Map();  // videoId → normalised caption tracks from a playerResponse

    const finiteOr = (value, fallback) => (typeof value === 'number' && Number.isFinite(value) ? value : fallback);

    function pageVideoId() {
      try {
        const path = CONFIG.PATH_ID.exec(location.pathname);
        if (path) return path[1];
        if (location.pathname === '/watch') {
          const v = new URLSearchParams(location.search).get('v');
          if (v && CONFIG.QUERY_ID.test(v)) return v;
        }
      } catch (_) { /* fall through */ }
      return null;
    }

    // Segments that apply to the page's current video right now.
    function realSegments(id) {
      return videoId !== null && id === videoId ? segments : [];
    }

    // Suggestions for the current video, minus any that overlap a real segment (that one wins).
    function activeSuggestions(id) {
      if (suggestVideoId === null || id !== suggestVideoId || suggestions.length === 0) return [];
      const real = realSegments(id);
      if (real.length === 0) return suggestions;
      return suggestions.filter((s) => !real.some((r) => s.start < r.end && r.start < s.end));
    }

    // ── video ───────────────────────────────────────────────────────────────────────────────
    function onMediaEvent(e) {
      ns.guard(SOURCE, () => {
        check();
        renderMarkers(e && (e.type === 'durationchange' || e.type === 'loadedmetadata'));
      });
    }

    function attach(next) {
      if (next === video) return;
      if (video) for (const type of CONFIG.MEDIA_EVENTS) video.removeEventListener(type, onMediaEvent);
      video = next && typeof next.addEventListener === 'function' ? next : null;
      if (video) for (const type of CONFIG.MEDIA_EVENTS) video.addEventListener(type, onMediaEvent);
    }

    function findVideo() {
      for (const selector of CONFIG.VIDEO_SELECTORS) {
        const found = document.querySelector(selector);
        if (found) return found;
      }
      return null;
    }

    function currentVideo() {
      if (!video || !video.isConnected) attach(findVideo());
      return video;
    }

    ns.on('videoElement', (el) => ns.guard(SOURCE, () => {
      attach(el);
      check();
      renderMarkers(true);
    }));

    // ── skipping ────────────────────────────────────────────────────────────────────────────
    function adShowing() {
      try { return document.querySelector(CONFIG.AD_SHOWING_SELECTOR) !== null; } catch (_) { return false; }
    }

    function seek(v, to, byUser = false) {
      if (byUser) ns.emit('userIntent', { action: 'seek', source: 'page' });
      v.currentTime = to;
    }

    // The playhead is "in" a segment from its start until END_EPSILON_S before its end; a
    // segment starting within END_GUARD_S of the video's end is left alone.
    const inside = (segment, t, duration) => segment.start <= t && t < segment.end - CONFIG.END_EPSILON_S &&
      !(duration > 0 && segment.start >= duration - CONFIG.END_GUARD_S);

    function check() {
      const id = pageVideoId();
      const real = realSegments(id);
      const suggested = activeSuggestions(id);
      if (real.length === 0 && suggested.length === 0) {
        if (toastKind === 'suggest') hideToast();
        return;
      }
      const v = currentVideo();
      if (!v || finiteOr(v.readyState, 0) < CONFIG.HAVE_METADATA || adShowing()) {
        if (toastKind === 'suggest') hideToast();
        return;
      }
      const t = finiteOr(v.currentTime, null);
      if (t === null) return;
      const duration = finiteOr(v.duration, 0);
      for (const segment of real) {
        if (segment.start > t) break;
        if (done.has(segment.key) || !inside(segment, t, duration)) continue;
        skip(v, segment, t, duration);
        return;
      }
      checkSuggestions(suggested, t, duration);
    }

    function skip(v, segment, from, duration) {
      done.add(segment.key);
      const to = duration > 0 ? Math.min(segment.end, duration) : segment.end;
      seek(v, to);
      ns.log('info', SOURCE, 'skipped ' + segment.category + ' ' + from.toFixed(1) + ' → ' + to.toFixed(1) +
        ' s (segment ' + segment.start + '–' + segment.end + ')');
      showToast({
        kind: 'skip', key: segment.key, ms: CONFIG.TOAST_MS, button: 'Undo',
        text: 'Skipped ' + (CONFIG.CATEGORY_LABELS[segment.category] || segment.category),
        onTap: () => undo(segment),
      });
    }

    function undo(segment) {
      hideToast();
      const v = currentVideo();
      if (!v) return;
      seek(v, segment.start, true);
      ns.log('info', SOURCE, 'undo: back to ' + segment.start + ' s; ' + segment.category + ' stays un-skipped');
    }

    // ── suggestions (prompted, never skipped by themselves) ──────────────────────────────────
    function checkSuggestions(list, t, duration) {
      // Being before a prompted segment's start means the user seeked back: prompt it again.
      for (const s of list) if (t < s.start) prompted.delete(s.key);
      const here = list.find((s) => inside(s, t, duration)) || null;
      if (toastKind === 'suggest' && (!here || here.key !== toastKey)) hideToast();
      // An automatic-skip toast takes precedence; the prompt waits (unprompted) until it is gone.
      if (!here || prompted.has(here.key) || toastKind === 'skip') return;
      prompted.add(here.key);
      ns.log('info', SOURCE, 'suggestion: possible ' + here.category + ' at ' + t.toFixed(1) + ' s (segment ' +
        here.start + '–' + here.end + '); prompting, not skipping');
      showToast({
        kind: 'suggest', key: here.key, ms: CONFIG.SUGGEST_TOAST_MS, button: 'Skip',
        text: 'Possible ' + (CONFIG.CATEGORY_LABELS[here.category] || here.category),
        onTap: () => skipSuggestion(here),
      });
    }

    function skipSuggestion(segment) {
      hideToast();
      const v = currentVideo();
      if (!v || finiteOr(v.readyState, 0) < CONFIG.HAVE_METADATA || adShowing()) return;
      const duration = finiteOr(v.duration, 0);
      const to = duration > 0 ? Math.min(segment.end, duration) : segment.end;
      const from = finiteOr(v.currentTime, 0);
      prompted.add(segment.key);
      seek(v, to, true);  // a real tap: userIntent, unlike automatic skips
      ns.log('info', SOURCE, 'suggestion skipped by tap: ' + segment.category + ' ' + from.toFixed(1) + ' → ' +
        to.toFixed(1) + ' s (segment ' + segment.start + '–' + segment.end + ')');
    }

    // ── toast ───────────────────────────────────────────────────────────────────────────────
    function hideToast() {
      if (toastTimer !== null) clearTimeout(toastTimer);
      toastTimer = null;
      if (toast && toast.parentNode) toast.parentNode.removeChild(toast);
      toast = null;
      toastKind = '';
      toastKey = '';
    }

    function stopPropagation(el) {
      // Keep YouTube's player from treating taps on the toast as taps on the video.
      for (const type of ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'mousedown', 'mouseup', 'click']) {
        el.addEventListener(type, (e) => ns.guard(SOURCE, () => e.stopPropagation()), { passive: true });
      }
    }

    // One toast at a time (one id): a new one replaces the old.
    function showToast({ kind, key, text, button: buttonText, onTap, ms }) {
      hideToast();
      const container = findPlayer();
      const root = container || document.body;
      if (!root) return;

      const box = document.createElement('div');
      box.id = CONFIG.TOAST_ID;
      box.dataset.kind = kind;
      box.setAttribute('role', 'status');
      Object.assign(box.style, {
        position: container ? 'absolute' : 'fixed', left: '12px', bottom: '48px', zIndex: '2147483647',
        display: 'flex', alignItems: 'center', gap: '12px', padding: '8px 12px', borderRadius: '8px',
        background: 'rgba(0,0,0,0.8)', color: '#fff', font: '14px/1.3 -apple-system, sans-serif',
        pointerEvents: 'auto', maxWidth: 'calc(100% - 24px)', boxSizing: 'border-box',
      });
      const label = document.createElement('span');
      label.textContent = text;
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = buttonText;
      Object.assign(button.style, {
        border: '0', borderRadius: '6px', padding: '4px 10px', background: 'rgba(255,255,255,0.2)',
        color: '#fff', font: 'inherit', fontWeight: '600',
      });
      stopPropagation(box);
      button.addEventListener('click', (e) => ns.guard(SOURCE, () => {
        e.preventDefault();
        onTap();
      }));
      box.appendChild(label);
      box.appendChild(button);
      root.appendChild(box);
      toast = box;
      toastKind = kind;
      toastKey = key;
      toastTimer = setTimeout(() => ns.guard(SOURCE, () => {
        toastTimer = null;
        if (toast === box) hideToast();
      }), ms);
    }

    // ── markers ─────────────────────────────────────────────────────────────────────────────
    function removeMarkers() {
      if (markers && markers.el.parentNode) markers.el.parentNode.removeChild(markers.el);
      markers = null;
    }

    function describe(el) {
      const classes = typeof el.className === 'string' ? el.className.trim().split(/\s+/).filter(Boolean).slice(0, 3) : [];
      const role = el.getAttribute && el.getAttribute('role');
      return el.tagName.toLowerCase() + classes.map((c) => '.' + c).join('') + (role ? '[role=' + role + ']' : '');
    }

    function rectOf(el) {
      try {
        const r = el.getBoundingClientRect();
        return r && Number.isFinite(r.width) && Number.isFinite(r.height) ? r : null;
      } catch (_) { return null; }
    }

    // The visible track line, by shape (see CONFIG.SEEK_BAR_CANDIDATES).
    function findBarByShape(player) {
      const playerRect = player ? rectOf(player) : null;
      if (!playerRect || !(playerRect.width > 0)) return null;
      const seen = new Set();
      let best = null;
      for (const selector of CONFIG.SEEK_BAR_CANDIDATES) {
        let list = [];
        try { list = document.querySelectorAll(selector); } catch (_) { continue; }
        for (const el of list) {
          if (seen.has(el) || el.id === CONFIG.MARKERS_ID || el.closest('#' + CONFIG.MARKERS_ID) ||
              el.closest('#' + CONFIG.TOAST_ID)) continue;
          seen.add(el);
          const r = rectOf(el);
          if (!r || !(r.height > 0) || r.height > CONFIG.BAR_MAX_HEIGHT_PX ||
              r.width < playerRect.width * CONFIG.BAR_MIN_WIDTH_FRACTION) continue;
          if (!best || r.height < best.rect.height || (r.height === best.rect.height && r.width > best.rect.width)) {
            best = { el, rect: r };
          }
        }
      }
      if (!best) return null;
      return { el: best.el, selector: 'shape ' + describe(best.el), rect: best.rect, playerRect };
    }

    function findSeekBar(player) {
      for (const selector of CONFIG.SEEK_BAR_SELECTORS) {
        try {
          const found = document.querySelector(selector);
          if (found) return { el: found, selector };
        } catch (_) { /* invalid selector: try the next */ }
      }
      return findBarByShape(player);
    }

    function rememberInsets(bar, player) {
      const r = bar.rect || rectOf(bar.el);
      const p = bar.playerRect || (player ? rectOf(player) : null);
      if (!r || !p || !(p.width > 0) || !(r.width > 0)) return;
      const left = Math.max(0, Math.min(0.45, (r.left - p.left) / p.width));
      const right = Math.max(0, Math.min(0.45, (p.right - r.right) / p.width));
      barInsets = { left, right };
    }

    function findPlayer() {
      for (const selector of CONFIG.TOAST_CONTAINER_SELECTORS) {
        const found = document.querySelector(selector);
        if (found) return found;
      }
      return null;
    }

    function markerStyle(segment, suggested) {
      const color = CONFIG.CATEGORY_COLORS[segment.category] || CONFIG.DEFAULT_COLOR;
      if (!suggested) return { background: color, opacity: CONFIG.MARKER_OPACITY };
      const px = CONFIG.SUGGESTED_STRIPE_PX;
      return {
        background: 'repeating-linear-gradient(135deg, ' + color + ' 0px, ' + color + ' ' + px + 'px, transparent ' +
          px + 'px, transparent ' + (2 * px) + 'px)',
        boxShadow: 'inset 0 0 0 1px ' + color,
        boxSizing: 'border-box',
        opacity: CONFIG.SUGGESTED_OPACITY,
      };
    }

    // `force` re-renders now (new segments, new duration, new video element); otherwise the host
    // is re-checked at most every MARKER_CHECK_MS, and nothing is rebuilt while it's unchanged.
    function renderMarkers(force) {
      const t = Date.now();
      if (!force && t - markersCheckedAt < CONFIG.MARKER_CHECK_MS) return;
      markersCheckedAt = t;

      const v = currentVideo();
      const duration = v ? finiteOr(v.duration, 0) : 0;
      const id = pageVideoId();
      const real = realSegments(id);
      const suggested = activeSuggestions(id);
      if ((real.length === 0 && suggested.length === 0) || !(duration > 0)) {
        removeMarkers();
        return;
      }
      const player = findPlayer();
      const bar = findSeekBar(player);
      if (bar) rememberInsets(bar, player);
      const host = bar ? bar.el : player;
      if (!host) {
        removeMarkers();
        return;
      }
      const insets = bar ? null : barInsets;
      const key = real.map((s) => s.key).join(',') + '/' + suggested.map((s) => s.key).join(',') + '@' + duration +
        (insets ? '|' + insets.left.toFixed(4) + ',' + insets.right.toFixed(4) : '');
      if (markers && markers.host === host && markers.key === key && markers.el.parentNode === host) return;

      removeMarkers();
      const fallback = !bar;
      const box = document.createElement('div');
      box.id = CONFIG.MARKERS_ID;
      box.setAttribute('aria-hidden', 'true');
      Object.assign(box.style, fallback
        ? { position: 'absolute', bottom: '0', height: CONFIG.FALLBACK_STRIP_PX + 'px',
            left: insets ? (insets.left * 100).toFixed(3) + '%' : '0',
            right: insets ? (insets.right * 100).toFixed(3) + '%' : '0',
            pointerEvents: 'none', zIndex: '2147483646' }
        : { position: 'absolute', left: '0', top: '0', width: '100%', height: '100%', pointerEvents: 'none', zIndex: '1' });
      // Real segments first (so existing consumers see them in order), then suggestions.
      const all = real.map((s) => [s, false]).concat(suggested.map((s) => [s, true]));
      for (const [segment, isSuggested] of all) {
        const from = Math.max(0, Math.min(1, segment.start / duration));
        const to = Math.max(0, Math.min(1, segment.end / duration));
        if (to <= from) continue;
        const mark = document.createElement('div');
        mark.dataset.category = segment.category;
        if (isSuggested) mark.dataset.suggested = '1';
        Object.assign(mark.style, {
          position: 'absolute', top: '0', height: '100%',
          left: (from * 100).toFixed(3) + '%', width: ((to - from) * 100).toFixed(3) + '%',
        }, markerStyle(segment, isSuggested));
        box.appendChild(mark);
      }
      // An absolutely positioned child needs a positioned host; only a static one is changed.
      try {
        if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
      } catch (_) { /* keep going: worst case the markers are offset */ }
      host.appendChild(box);
      markers = { el: box, host, key, fallback };

      const where = bar ? 'seek bar ' + bar.selector
        : 'fallback strip (' + (insets ? 'aligned to the last seek bar' : 'no seek bar matched') + ')';
      if (where !== loggedMarkerHost) {
        loggedMarkerHost = where;
        ns.log('info', SOURCE, 'markers on ' + where);
      }
    }

    // ── caption tracks ──────────────────────────────────────────────────────────────────────
    function plainText(value) {
      let text = '';
      if (typeof value === 'string') text = value;
      else if (value && typeof value === 'object') {
        if (typeof value.simpleText === 'string') text = value.simpleText;
        else if (Array.isArray(value.runs)) {
          text = value.runs.map((r) => (r && typeof r.text === 'string' ? r.text : '')).join('');
        }
      }
      return text.slice(0, CONFIG.MAX_CAPTION_TEXT_CHARS);
    }

    // Same-site timedtext URLs only, made absolute; anything else → null.
    function captionURL(baseUrl) {
      if (typeof baseUrl !== 'string' || baseUrl === '') return null;
      let url;
      try { url = new URL(baseUrl, location.origin); } catch (_) { return null; }
      if (url.protocol !== 'https:' || url.username !== '' || url.password !== '') return null;
      if (!CONFIG.CAPTION_HOSTS.includes(url.host)) return null;  // `host` includes a port: rejected
      if (!url.pathname.startsWith(CONFIG.CAPTION_PATH_PREFIX)) return null;
      return url.href;
    }

    // {videoId, tracks} from a player response, or null when it names no video.
    function captionsFromPlayerResponse(pr) {
      const details = pr && typeof pr === 'object' ? pr.videoDetails : null;
      const id = details && typeof details.videoId === 'string' && CONFIG.QUERY_ID.test(details.videoId)
        ? details.videoId : null;
      if (id === null) return null;
      let list = pr;
      for (const key of CONFIG.CAPTION_TRACKS_PATH) list = list && typeof list === 'object' ? list[key] : undefined;
      const tracks = [];
      if (Array.isArray(list)) {
        for (const track of list) {
          if (tracks.length >= CONFIG.MAX_CAPTION_TRACKS) break;
          if (!track || typeof track !== 'object') continue;
          const baseUrl = captionURL(track.baseUrl);
          if (baseUrl === null) continue;
          tracks.push({
            baseUrl,
            languageCode: typeof track.languageCode === 'string'
              ? track.languageCode.slice(0, CONFIG.MAX_CAPTION_TEXT_CHARS) : '',
            kind: track.kind === 'asr' ? 'asr' : '',
            name: plainText(track.name),
          });
        }
      }
      return { videoId: id, tracks };
    }

    function rememberCaptions(found) {
      // A later response without captions (a partial prefetch, say) doesn't erase known tracks.
      const known = captionCache.get(found.videoId);
      if (known && known.length > 0 && found.tracks.length === 0) return;
      captionCache.delete(found.videoId);
      captionCache.set(found.videoId, found.tracks);
      while (captionCache.size > CONFIG.CAPTION_CACHE_SIZE) captionCache.delete(captionCache.keys().next().value);
    }

    ns.on('playerResponse', (pr) => ns.guard(SOURCE, () => {
      const found = captionsFromPlayerResponse(pr);
      if (found) rememberCaptions(found);
    }));

    function captionTracks() {
      const id = pageVideoId();
      if (id === null) return { videoId: null, tracks: [] };
      let tracks = captionCache.get(id);
      if (!tracks) {
        // No event for this video (yet): the inline player response, when it is this video's.
        let initial = null;
        try { initial = captionsFromPlayerResponse(window.ytInitialPlayerResponse); } catch (_) { /* none */ }
        if (initial && initial.videoId === id) tracks = initial.tracks;
      }
      return { videoId: id, tracks: (tracks || []).map((track) => ({ ...track })) };
    }

    // ── commands ────────────────────────────────────────────────────────────────────────────
    function validSegments(list) {
      const out = [];
      if (!Array.isArray(list)) return out;
      for (const s of list) {
        if (out.length >= CONFIG.MAX_SEGMENTS) break;
        if (!s || typeof s !== 'object') continue;
        const { start, end, category } = s;
        if (typeof start !== 'number' || typeof end !== 'number' || !Number.isFinite(start) ||
            !Number.isFinite(end) || start < 0 || end <= start) continue;
        if (typeof category !== 'string' || category === '' || category.length > CONFIG.MAX_CATEGORY_CHARS) continue;
        out.push({ start, end, category, key: start + '|' + end + '|' + category });
      }
      out.sort((a, b) => a.start - b.start || a.end - b.end);
      return out;
    }

    // The args' videoId when it is the page's current video, else null.
    function currentId(args, command) {
      const id = typeof args.videoId === 'string' && CONFIG.QUERY_ID.test(args.videoId) ? args.videoId : null;
      if (id === null || id !== pageVideoId()) {
        ns.log('debug', SOURCE, command + ' for another video ignored:', args.videoId);
        return null;
      }
      return id;
    }

    ns.command('captionTracks', () => captionTracks());

    ns.command('suggestedSegments', (args) => {
      const id = currentId(args, 'suggestedSegments');
      if (id === null) return { ok: true, count: 0 };
      if (id !== suggestVideoId) prompted.clear();
      suggestVideoId = id;
      suggestions = validSegments(args.segments);
      if (toastKind === 'suggest' && !suggestions.some((s) => s.key === toastKey)) hideToast();
      currentVideo();
      check();
      renderMarkers(true);
      return { ok: true, count: suggestions.length };
    });

    ns.command('sponsorSegments', (args) => {
      const id = currentId(args, 'sponsorSegments');
      if (id === null) return { ok: true, count: 0 };
      if (id !== videoId) {
        done.clear();
        if (toastKind === 'skip') hideToast();
      }
      videoId = id;
      segments = validSegments(args.segments);
      currentVideo();
      check();
      renderMarkers(true);
      return { ok: true, count: segments.length };
    });
  });
})();
