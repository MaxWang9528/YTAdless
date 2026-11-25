// sponsorblock.js — owner: Module D (PLAN.md §5.4 `sponsorSegments`, §6.4).
//
// Skips SponsorBlock segments in the player's main video. Native (SponsorBlockService) fetches
// them from sponsor.ajay.app and sends them; this file never touches the network.
//   handles  `sponsorSegments {videoId, segments: [{start, end, category}]}` → {ok: true, count}
//            (invalid segments are dropped one by one; segments for another video than the page's
//            are ignored, count 0). A re-send for the same video keeps what was already skipped.
//   listens  `videoElement` (player-bridge.js) for re-attachments; also looks the video up itself,
//            because that event doesn't replay emissions from before this file's listener.
//   emits    `userIntent` {action:'seek', source:'page'} before the Undo seek (a real tap), and
//            NOT before automatic skips: a userIntent makes background.js treat a pause in the
//            next ~1.5 s as intentional (D12), so a skip while locked could leave a system pause
//            unresumed. An automatic skip isn't the user's intent.
// Each segment is skipped at most once per load: seeking back into it plays it. A toast over the
// player says what was skipped and offers Undo (seek back to the segment's start).
// Markers: every segment is drawn as a coloured span on YouTube's seek bar (SponsorBlock's
// colours), so you can see what will be skipped. When no seek bar is found (its classes are
// unverified on device), a thin strip along the bottom of the player shows them instead. The
// first render logs which one was used.
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
    let toast = null;
    let toastTimer = null;
    let markers = null;        // {el, host, duration, key, fallback}
    let markersCheckedAt = -Infinity;
    let loggedMarkerHost = '';

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

    function check() {
      if (videoId === null || segments.length === 0 || pageVideoId() !== videoId) return;
      const v = currentVideo();
      if (!v || finiteOr(v.readyState, 0) < CONFIG.HAVE_METADATA || adShowing()) return;
      const t = finiteOr(v.currentTime, null);
      if (t === null) return;
      const duration = finiteOr(v.duration, 0);
      for (const segment of segments) {
        if (segment.start > t) break;
        if (done.has(segment.key) || t >= segment.end - CONFIG.END_EPSILON_S) continue;
        if (duration > 0 && segment.start >= duration - CONFIG.END_GUARD_S) continue;
        skip(v, segment, t, duration);
        return;
      }
    }

    function skip(v, segment, from, duration) {
      done.add(segment.key);
      const to = duration > 0 ? Math.min(segment.end, duration) : segment.end;
      seek(v, to);
      ns.log('info', SOURCE, 'skipped ' + segment.category + ' ' + from.toFixed(1) + ' → ' + to.toFixed(1) +
        ' s (segment ' + segment.start + '–' + segment.end + ')');
      showToast(segment);
    }

    function undo(segment) {
      hideToast();
      const v = currentVideo();
      if (!v) return;
      seek(v, segment.start, true);
      ns.log('info', SOURCE, 'undo: back to ' + segment.start + ' s; ' + segment.category + ' stays un-skipped');
    }

    // ── toast ───────────────────────────────────────────────────────────────────────────────
    function hideToast() {
      if (toastTimer !== null) clearTimeout(toastTimer);
      toastTimer = null;
      if (toast && toast.parentNode) toast.parentNode.removeChild(toast);
      toast = null;
    }

    function stopPropagation(el) {
      // Keep YouTube's player from treating taps on the toast as taps on the video.
      for (const type of ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'mousedown', 'mouseup', 'click']) {
        el.addEventListener(type, (e) => ns.guard(SOURCE, () => e.stopPropagation()), { passive: true });
      }
    }

    function showToast(segment) {
      hideToast();
      let container = null;
      for (const selector of CONFIG.TOAST_CONTAINER_SELECTORS) {
        container = document.querySelector(selector);
        if (container) break;
      }
      const root = container || document.body;
      if (!root) return;

      const box = document.createElement('div');
      box.id = CONFIG.TOAST_ID;
      box.setAttribute('role', 'status');
      Object.assign(box.style, {
        position: container ? 'absolute' : 'fixed', left: '12px', bottom: '48px', zIndex: '2147483647',
        display: 'flex', alignItems: 'center', gap: '12px', padding: '8px 12px', borderRadius: '8px',
        background: 'rgba(0,0,0,0.8)', color: '#fff', font: '14px/1.3 -apple-system, sans-serif',
        pointerEvents: 'auto', maxWidth: 'calc(100% - 24px)', boxSizing: 'border-box',
      });
      const label = document.createElement('span');
      label.textContent = 'Skipped ' + (CONFIG.CATEGORY_LABELS[segment.category] || segment.category);
      const button = document.createElement('button');
      button.type = 'button';
      button.textContent = 'Undo';
      Object.assign(button.style, {
        border: '0', borderRadius: '6px', padding: '4px 10px', background: 'rgba(255,255,255,0.2)',
        color: '#fff', font: 'inherit', fontWeight: '600',
      });
      stopPropagation(box);
      button.addEventListener('click', (e) => ns.guard(SOURCE, () => {
        e.preventDefault();
        undo(segment);
      }));
      box.appendChild(label);
      box.appendChild(button);
      root.appendChild(box);
      toast = box;
      toastTimer = setTimeout(() => ns.guard(SOURCE, () => {
        toastTimer = null;
        if (toast === box) hideToast();
      }), CONFIG.TOAST_MS);
    }

    // ── markers ─────────────────────────────────────────────────────────────────────────────
    function removeMarkers() {
      if (markers && markers.el.parentNode) markers.el.parentNode.removeChild(markers.el);
      markers = null;
    }

    function findSeekBar() {
      for (const selector of CONFIG.SEEK_BAR_SELECTORS) {
        try {
          const found = document.querySelector(selector);
          if (found) return { el: found, selector };
        } catch (_) { /* invalid selector: try the next */ }
      }
      return null;
    }

    function findPlayer() {
      for (const selector of CONFIG.TOAST_CONTAINER_SELECTORS) {
        const found = document.querySelector(selector);
        if (found) return found;
      }
      return null;
    }

    // `force` re-renders now (new segments, new duration, new video element); otherwise the host
    // is re-checked at most every MARKER_CHECK_MS, and nothing is rebuilt while it's unchanged.
    function renderMarkers(force) {
      const t = Date.now();
      if (!force && t - markersCheckedAt < CONFIG.MARKER_CHECK_MS) return;
      markersCheckedAt = t;

      const v = currentVideo();
      const duration = v ? finiteOr(v.duration, 0) : 0;
      if (videoId === null || segments.length === 0 || pageVideoId() !== videoId || !(duration > 0)) {
        removeMarkers();
        return;
      }
      const bar = findSeekBar();
      const host = bar ? bar.el : findPlayer();
      if (!host) {
        removeMarkers();
        return;
      }
      const key = segments.map((s) => s.key).join(',') + '@' + duration;
      if (markers && markers.host === host && markers.key === key && markers.el.parentNode === host) return;

      removeMarkers();
      const fallback = !bar;
      const box = document.createElement('div');
      box.id = CONFIG.MARKERS_ID;
      box.setAttribute('aria-hidden', 'true');
      Object.assign(box.style, fallback
        ? { position: 'absolute', left: '0', right: '0', bottom: '0', height: CONFIG.FALLBACK_STRIP_PX + 'px',
            pointerEvents: 'none', zIndex: '2147483646' }
        : { position: 'absolute', left: '0', top: '0', width: '100%', height: '100%', pointerEvents: 'none', zIndex: '1' });
      for (const segment of segments) {
        const from = Math.max(0, Math.min(1, segment.start / duration));
        const to = Math.max(0, Math.min(1, segment.end / duration));
        if (to <= from) continue;
        const mark = document.createElement('div');
        mark.dataset.category = segment.category;
        Object.assign(mark.style, {
          position: 'absolute', top: '0', height: '100%',
          left: (from * 100).toFixed(3) + '%', width: ((to - from) * 100).toFixed(3) + '%',
          background: CONFIG.CATEGORY_COLORS[segment.category] || CONFIG.DEFAULT_COLOR,
          opacity: CONFIG.MARKER_OPACITY,
        });
        box.appendChild(mark);
      }
      // An absolutely positioned child needs a positioned host; only a static one is changed.
      try {
        if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
      } catch (_) { /* keep going: worst case the markers are offset */ }
      host.appendChild(box);
      markers = { el: box, host, key, fallback };

      const where = bar ? 'seek bar ' + bar.selector : 'fallback strip (no seek bar matched)';
      if (where !== loggedMarkerHost) {
        loggedMarkerHost = where;
        ns.log('info', SOURCE, 'markers on ' + where);
      }
    }

    // ── command ─────────────────────────────────────────────────────────────────────────────
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

    // Contract stubs (2026-11-25); filled in by the on-device detection work.
    ns.command('captionTracks', () => ({ videoId: pageVideoId(), tracks: [] }));
    ns.command('suggestedSegments', (args) => ({ ok: true, count: Array.isArray(args.segments) ? args.segments.length : 0 }));

    ns.command('sponsorSegments', (args) => {
      const id = typeof args.videoId === 'string' && CONFIG.QUERY_ID.test(args.videoId) ? args.videoId : null;
      if (id === null || id !== pageVideoId()) {
        ns.log('debug', SOURCE, 'sponsorSegments for another video ignored:', args.videoId);
        return { ok: true, count: 0 };
      }
      if (id !== videoId) {
        done.clear();
        hideToast();
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
