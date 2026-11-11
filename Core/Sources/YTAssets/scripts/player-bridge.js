// player-bridge.js — owner: Module D (PLAN.md §6.4). Phase 0 wrote this minimal version.
//
// Tracks the main <video> of the player webview and reports it to native:
//   posts   `playback` (~1 Hz while playing, plus every state change), `videoMeta`, `presentation`
//   emits   `videoElement` (each time the main video is (re)attached), `userIntent` (native commands)
//   handles commands play · pause · seek {to} · seekBy {delta} · pip {enter} · state
// videoMeta comes from the `playerResponse` event (hooks.js, Module A); ytInitialPlayerResponse
// and then the DOM are fallbacks.
(() => {
  'use strict';

  const SOURCE = 'player-bridge.js';
  const CONFIG = Object.freeze({
    // Main player video on m.youtube.com, first match wins (mweb DOM, 2026-11; no fixture yet).
    VIDEO_SELECTORS: ['#movie_player video', 'video.html5-main-video', 'video'],
    PLAYBACK_INTERVAL_MS: 1000,  // §5.3: ~1 Hz while playing
    // Video id of the current page: /watch?v=ID, /shorts/ID, /live/ID (YouTube ids are 11 chars).
    PATH_ID: /^\/(?:shorts|live)\/([A-Za-z0-9_-]{11})(?:[/?#]|$)/,
    QUERY_ID: /^[A-Za-z0-9_-]{11}$/,
    TITLE_SUFFIX: /\s+-\s+YouTube$/,  // DOM fallback: document.title is "<title> - YouTube"
    META_CACHE_SIZE: 8,               // playerResponses seen for other ids (prefetch of next video)
    HAVE_FUTURE_DATA: 3,              // HTMLMediaElement.readyState
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const origPlay = HTMLMediaElement.prototype.play;
    const origPause = HTMLMediaElement.prototype.pause;

    const MEDIA_EVENTS = [
      'play', 'playing', 'pause', 'waiting', 'seeked', 'ratechange', 'durationchange', 'ended',
      'loadedmetadata', 'emptied', 'timeupdate',
    ];
    const PRESENTATION_EVENTS = [
      'webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture',
      'webkitbeginfullscreen', 'webkitendfullscreen',
    ];

    let video = null;
    let lastPlaybackAt = 0;
    let presentation = 'inline';
    let postedMeta = null;          // last videoMeta payload posted
    let postedMetaKey = '';
    const metaCache = new Map();    // videoId → meta from a playerResponse

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

    // ── videoMeta ───────────────────────────────────────────────────────────────────────────
    function metaFromPlayerResponse(pr) {
      const d = pr && typeof pr === 'object' ? pr.videoDetails : null;
      if (!d || typeof d.videoId !== 'string' || d.videoId === '') return null;
      const length = Number(d.lengthSeconds);  // a string ("212") in player responses
      const thumbs = d.thumbnail && Array.isArray(d.thumbnail.thumbnails) ? d.thumbnail.thumbnails : [];
      let best = null;
      for (const t of thumbs) {
        if (t && typeof t.url === 'string' && (!best || finiteOr(t.width, 0) >= finiteOr(best.width, 0))) best = t;
      }
      return {
        videoId: d.videoId,
        title: typeof d.title === 'string' ? d.title : '',
        author: typeof d.author === 'string' ? d.author : '',
        lengthSeconds: Number.isFinite(length) && length > 0 ? length : null,
        thumbnailURL: best ? best.url : null,
        isLive: d.isLive === true,
      };
    }

    function metaFromPage(id) {
      try {
        const fromInitial = metaFromPlayerResponse(window.ytInitialPlayerResponse);
        if (fromInitial && fromInitial.videoId === id) return fromInitial;
      } catch (_) { /* fall back to the DOM */ }
      const title = typeof document.title === 'string' ? document.title.replace(CONFIG.TITLE_SUFFIX, '').trim() : '';
      return { videoId: id, title, author: '', lengthSeconds: null, thumbnailURL: null, isLive: false };
    }

    function rememberMeta(meta) {
      metaCache.delete(meta.videoId);
      metaCache.set(meta.videoId, meta);
      while (metaCache.size > CONFIG.META_CACHE_SIZE) metaCache.delete(metaCache.keys().next().value);
    }

    // Posts videoMeta for the page's current video when it changed. `allowFallback` lets the DOM
    // stand in when no playerResponse for this id has been seen (e.g. hooks.js not installed).
    function syncMeta(allowFallback) {
      const id = pageVideoId();
      if (!id) return;
      let meta = metaCache.get(id) || null;
      if (!meta && allowFallback && (!postedMeta || postedMeta.videoId !== id)) meta = metaFromPage(id);
      if (!meta) return;
      const key = JSON.stringify(meta);
      if (key === postedMetaKey) return;
      postedMeta = meta;
      postedMetaKey = key;
      ns.post('videoMeta', meta);
    }

    // ── playback / presentation ─────────────────────────────────────────────────────────────
    function status(v) {
      if (!v) return 'idle';
      if (v.ended) return 'ended';
      if (!v.paused) return v.readyState < CONFIG.HAVE_FUTURE_DATA ? 'buffering' : 'playing';
      if (v.readyState === 0) return v.currentSrc || v.getAttribute('src') ? 'loading' : 'idle';
      return 'paused';
    }

    function snapshot() {
      const v = video;
      const duration = v ? finiteOr(v.duration, null) : null;
      return {
        status: status(v),
        position: v ? Math.max(0, finiteOr(v.currentTime, 0)) : 0,
        duration: duration !== null && duration > 0 ? duration : null,
        rate: v ? finiteOr(v.playbackRate, 1) : 1,
        videoId: pageVideoId(),
      };
    }

    function postPlayback() {
      lastPlaybackAt = Date.now();
      ns.post('playback', snapshot());
    }

    function presentationOf(v) {
      if (!v) return 'inline';
      const mode = typeof v.webkitPresentationMode === 'string' ? v.webkitPresentationMode : '';
      if (mode === 'picture-in-picture') return 'pip';
      if (mode === 'fullscreen') return 'fullscreen';
      if (document.pictureInPictureElement === v) return 'pip';
      if (v.webkitDisplayingFullscreen === true) return 'fullscreen';
      return 'inline';
    }

    function syncPresentation() {
      const mode = presentationOf(video);
      if (mode === presentation) return;
      presentation = mode;
      ns.post('presentation', { mode });
    }

    // ── video tracking ──────────────────────────────────────────────────────────────────────
    function onMediaEvent(event) {
      ns.guard(SOURCE, () => {
        if (event.type === 'timeupdate') {
          if (Date.now() - lastPlaybackAt < CONFIG.PLAYBACK_INTERVAL_MS) return;
        } else if (event.type === 'loadedmetadata' || event.type === 'play') {
          syncMeta(true);
        }
        postPlayback();
      });
    }

    function onPresentationEvent() {
      ns.guard(SOURCE, syncPresentation);
    }

    function findVideo() {
      for (const selector of CONFIG.VIDEO_SELECTORS) {
        const found = document.querySelector(selector);
        if (found) return found;
      }
      return null;
    }

    function attach(next) {
      if (next === video) return;
      if (video) {
        for (const type of MEDIA_EVENTS) video.removeEventListener(type, onMediaEvent);
        for (const type of PRESENTATION_EVENTS) video.removeEventListener(type, onPresentationEvent);
      }
      video = next;
      if (!video) return;
      for (const type of MEDIA_EVENTS) video.addEventListener(type, onMediaEvent);
      for (const type of PRESENTATION_EVENTS) video.addEventListener(type, onPresentationEvent);
      ns.emit('videoElement', video);
      syncPresentation();
      postPlayback();
    }

    function scan() {
      if (video && video.isConnected) return;
      attach(findVideo());
    }

    new MutationObserver(() => ns.guard(SOURCE, scan)).observe(document, { childList: true, subtree: true });
    scan();

    ns.on('playerResponse', (pr) => {
      const meta = metaFromPlayerResponse(pr);
      if (!meta) return;
      rememberMeta(meta);
      syncMeta(false);
    });
    ns.on('navigation', () => {
      syncMeta(false);
      scan();
    });

    // ── commands ────────────────────────────────────────────────────────────────────────────
    function requireVideo() {
      scan();
      if (!video) throw new Error('no-video');
      return video;
    }

    function intent(action) {
      ns.emit('userIntent', { action, source: 'native' });
    }

    ns.command('play', () => {
      const v = requireVideo();
      intent('play');
      const result = origPlay.call(v);
      return result && typeof result.then === 'function' ? result.then(() => ({ ok: true })) : { ok: true };
    });

    ns.command('pause', () => {
      const v = requireVideo();
      intent('pause');
      origPause.call(v);
      return { ok: true };
    });

    function seekTo(v, target) {
      const duration = finiteOr(v.duration, null);
      let to = Math.max(0, target);
      if (duration !== null && duration > 0) to = Math.min(to, duration);
      intent('seek');
      v.currentTime = to;
      return { ok: true, position: to };
    }

    ns.command('seek', (args) => {
      const v = requireVideo();
      const to = Number(args.to);
      if (!Number.isFinite(to)) throw new Error('seek: `to` must be a number');
      return seekTo(v, to);
    });

    ns.command('seekBy', (args) => {
      const v = requireVideo();
      const delta = Number(args.delta);
      if (!Number.isFinite(delta)) throw new Error('seekBy: `delta` must be a number');
      return seekTo(v, finiteOr(v.currentTime, 0) + delta);
    });

    ns.command('pip', (args) => {
      const v = requireVideo();
      const enter = args.enter === true;
      if (typeof v.webkitSetPresentationMode === 'function' &&
          (typeof v.webkitSupportsPresentationMode !== 'function' || v.webkitSupportsPresentationMode('picture-in-picture'))) {
        v.webkitSetPresentationMode(enter ? 'picture-in-picture' : 'inline');
        return { ok: true };
      }
      if (enter && typeof v.requestPictureInPicture === 'function') {
        return v.requestPictureInPicture().then(() => ({ ok: true }));
      }
      if (!enter && document.pictureInPictureElement && typeof document.exitPictureInPicture === 'function') {
        return document.exitPictureInPicture().then(() => ({ ok: true }));
      }
      throw new Error('pip: not supported');
    });

    ns.command('state', () => {
      scan();
      syncMeta(Boolean(video));
      const id = pageVideoId();
      return {
        meta: postedMeta && postedMeta.videoId === id ? postedMeta : null,
        playback: snapshot(),
        presentation: presentationOf(video),
      };
    });
  });
})();
