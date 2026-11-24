// media-session.js — owner: Module D (PLAN.md §6.4 Now Playing).
//
// Owns navigator.mediaSession for the lock screen and Control Center (D11, pending approval).
// WebKit publishes Now Playing for the page's media itself (F12); this file decides what it shows:
//   - YouTube's own setActionHandler / metadata / setPositionState / playbackState writes are
//     ignored (the prototype members are wrapped; this file calls the originals)
//   - MediaMetadata (title, channel, artwork) comes from the `playerResponse` event, with
//     ytInitialPlayerResponse and then document.title as fallbacks
//   - setPositionState runs on loadedmetadata, durationchange, play, pause, seeked, ratechange
//   - handlers: play, pause, seekto, seekbackward / seekforward (10 s); previoustrack / nexttrack
//     only on playlist pages (on iOS they replace the ±10 s buttons). Each handler emits
//     userIntent{source:'remote'} before acting, so background.js never reverses that pause.
// Does nothing when the page has no Media Session (the smoke test's jsdom page).
(() => {
  'use strict';

  const SOURCE = 'media-session.js';
  const CONFIG = Object.freeze({
    // false = leave navigator.mediaSession entirely to YouTube and WebKit (spike S-D1's "without"
    // build). Then lock-screen pauses carry no userIntent and background.js may resume them.
    ENABLED: true,
    SEEK_OFFSET_S: 10,
    TRANSPORT_ACTIONS: ['play', 'pause', 'seekto', 'seekbackward', 'seekforward'],
    PLAYLIST_ACTIONS: ['previoustrack', 'nexttrack'],
    PLAYLIST_PARAM: 'list',            // /watch?v=…&list=… (PLAN.md §6.2)
    PREVIOUS_RESTARTS_AFTER_S: 3,      // previoustrack past this point restarts the video
    // mweb playlist controls, first match wins (2026-11 DOM guesses; unverified on device).
    NEXT_SELECTORS: ['.player-controls-next-button', 'button[aria-label="Next video"]', '.ytp-next-button'],
    PREVIOUS_SELECTORS: ['.player-controls-prev-button', 'button[aria-label="Previous video"]', '.ytp-prev-button'],
    POSITION_EVENTS: ['loadedmetadata', 'durationchange', 'play', 'pause', 'seeked', 'ratechange'],
    PATH_ID: /^\/(?:shorts|live)\/([A-Za-z0-9_-]{11})(?:[/?#]|$)/,  // = player-bridge.js
    QUERY_ID: /^[A-Za-z0-9_-]{11}$/,
    TITLE_SUFFIX: /\s+-\s+YouTube$/,
    META_CACHE_SIZE: 8,
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    if (!CONFIG.ENABLED) {
      ns.log('info', SOURCE, 'disabled (CONFIG.ENABLED = false)');
      return;
    }
    const session = navigator.mediaSession;
    const MediaSessionClass = window.MediaSession;
    if (!session || typeof MediaSessionClass !== 'function') {
      ns.log('debug', SOURCE, 'no navigator.mediaSession; Now Playing is left to WebKit');
      return;
    }

    const origPlay = HTMLMediaElement.prototype.play;
    const origPause = HTMLMediaElement.prototype.pause;
    const proto = MediaSessionClass.prototype;
    const origSetActionHandler = proto.setActionHandler;
    const origSetPositionState = proto.setPositionState;
    const metadataDescriptor = Object.getOwnPropertyDescriptor(proto, 'metadata');
    const playbackStateDescriptor = Object.getOwnPropertyDescriptor(proto, 'playbackState');
    const OURS = new Set([...CONFIG.TRANSPORT_ACTIONS, ...CONFIG.PLAYLIST_ACTIONS]);
    const finite = (x) => typeof x === 'number' && Number.isFinite(x);

    // ── ignore the page's writes ────────────────────────────────────────────────────────────
    if (typeof origSetActionHandler === 'function') {
      proto.setActionHandler = function setActionHandler(action) {
        if (OURS.has(action)) return undefined;  // ours stay installed
        return origSetActionHandler.apply(this, arguments);
      };
    }
    if (typeof origSetPositionState === 'function') {
      proto.setPositionState = function setPositionState() { return undefined; };
    }
    for (const [prop, descriptor] of [['metadata', metadataDescriptor], ['playbackState', playbackStateDescriptor]]) {
      if (!descriptor || !descriptor.configurable || typeof descriptor.get !== 'function') continue;
      Object.defineProperty(proto, prop, {
        configurable: true,
        enumerable: descriptor.enumerable,
        get: descriptor.get,
        set() { /* page writes ignored */ },
      });
    }

    function setOwn(descriptor, value) {
      if (descriptor && typeof descriptor.set === 'function') descriptor.set.call(session, value);
    }

    // ── video ───────────────────────────────────────────────────────────────────────────────
    let video = null;
    const metaCache = new Map();   // videoId → {title, artist, artwork}
    let appliedKey = '';

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

    function isPlaylist() {
      try { return Boolean(new URLSearchParams(location.search).get(CONFIG.PLAYLIST_PARAM)); } catch (_) { return false; }
    }

    // ── metadata ────────────────────────────────────────────────────────────────────────────
    function metaFromPlayerResponse(pr) {
      const d = pr && typeof pr === 'object' ? pr.videoDetails : null;
      if (!d || typeof d.videoId !== 'string' || d.videoId === '') return null;
      const thumbs = d.thumbnail && Array.isArray(d.thumbnail.thumbnails) ? d.thumbnail.thumbnails : [];
      const artwork = thumbs
        .filter((t) => t && typeof t.url === 'string')
        .sort((a, b) => (finite(a.width) ? a.width : 0) - (finite(b.width) ? b.width : 0))
        .map((t) => (finite(t.width) && finite(t.height) ? { src: t.url, sizes: t.width + 'x' + t.height } : { src: t.url }));
      return {
        videoId: d.videoId,
        title: typeof d.title === 'string' ? d.title : '',
        artist: typeof d.author === 'string' ? d.author : '',
        artwork,
      };
    }

    function remember(meta) {
      metaCache.delete(meta.videoId);
      metaCache.set(meta.videoId, meta);
      while (metaCache.size > CONFIG.META_CACHE_SIZE) metaCache.delete(metaCache.keys().next().value);
    }

    function fallbackMeta(id) {
      try {
        const initial = metaFromPlayerResponse(window.ytInitialPlayerResponse);
        if (initial && initial.videoId === id) return initial;
      } catch (_) { /* DOM next */ }
      const title = typeof document.title === 'string' ? document.title.replace(CONFIG.TITLE_SUFFIX, '').trim() : '';
      return title ? { videoId: id, title, artist: '', artwork: [] } : null;
    }

    function applyMetadata(allowFallback) {
      const id = pageVideoId();
      if (!id || typeof window.MediaMetadata !== 'function') return;
      let meta = metaCache.get(id) || null;
      if (!meta && allowFallback) meta = fallbackMeta(id);
      if (!meta) return;
      const key = JSON.stringify(meta);
      if (key === appliedKey) return;
      appliedKey = key;
      setOwn(metadataDescriptor, new window.MediaMetadata({ title: meta.title, artist: meta.artist, album: '', artwork: meta.artwork }));
    }

    // ── position / playback state ───────────────────────────────────────────────────────────
    function updatePosition() {
      const v = video;
      if (!v || typeof origSetPositionState !== 'function') return;
      const duration = v.duration;
      try {
        if (!finite(duration) || duration <= 0) {
          origSetPositionState.call(session);  // live or unknown: clear it
          return;
        }
        const rate = finite(v.playbackRate) && v.playbackRate > 0 ? v.playbackRate : 1;
        const position = Math.min(Math.max(finite(v.currentTime) ? v.currentTime : 0, 0), duration);
        origSetPositionState.call(session, { duration, playbackRate: rate, position });
      } catch (e) {
        ns.log('debug', SOURCE, 'setPositionState refused:', e);
      }
    }

    function onMediaEvent(event) {
      ns.guard(SOURCE, () => {
        if (event.target !== video) return;
        if (event.type === 'play') setOwn(playbackStateDescriptor, 'playing');
        if (event.type === 'pause') setOwn(playbackStateDescriptor, 'paused');
        if (event.type === 'loadedmetadata' || event.type === 'play') applyMetadata(true);
        updatePosition();
      });
    }

    ns.on('videoElement', (v) => {
      if (video) for (const type of CONFIG.POSITION_EVENTS) video.removeEventListener(type, onMediaEvent);
      video = v;
      for (const type of CONFIG.POSITION_EVENTS) v.addEventListener(type, onMediaEvent);
      updatePosition();
    });

    // ── action handlers ─────────────────────────────────────────────────────────────────────
    function intent(action) {
      ns.emit('userIntent', { action, source: 'remote' });
    }

    function withVideo(action, fn) {
      return (details) => ns.guard(SOURCE, () => {
        const v = video;
        if (!v) {
          ns.log('warn', SOURCE, 'remote ' + action + ' with no video');
          return;
        }
        fn(v, details || {});
      });
    }

    function seekTo(v, target, fast) {
      const duration = finite(v.duration) && v.duration > 0 ? v.duration : Infinity;
      const to = Math.min(Math.max(target, 0), duration);
      intent('seek');
      if (fast && typeof v.fastSeek === 'function') v.fastSeek(to);
      else v.currentTime = to;
      updatePosition();
    }

    function clickFirst(selectors) {
      for (const selector of selectors) {
        const el = document.querySelector(selector);
        if (el && typeof el.click === 'function') {
          el.click();
          return true;
        }
      }
      return false;
    }

    const handlers = {
      play: withVideo('play', (v) => {
        intent('play');
        const result = origPlay.call(v);
        if (result && typeof result.then === 'function') {
          result.then(undefined, (e) => ns.log('warn', SOURCE, 'remote play refused:', e));
        }
      }),
      pause: withVideo('pause', (v) => {
        intent('pause');
        origPause.call(v);
      }),
      seekto: withVideo('seekto', (v, d) => {
        if (finite(d.seekTime)) seekTo(v, d.seekTime, d.fastSeek === true);
      }),
      seekbackward: withVideo('seekbackward', (v, d) => {
        const offset = finite(d.seekOffset) && d.seekOffset > 0 ? d.seekOffset : CONFIG.SEEK_OFFSET_S;
        seekTo(v, (finite(v.currentTime) ? v.currentTime : 0) - offset, false);
      }),
      seekforward: withVideo('seekforward', (v, d) => {
        const offset = finite(d.seekOffset) && d.seekOffset > 0 ? d.seekOffset : CONFIG.SEEK_OFFSET_S;
        seekTo(v, (finite(v.currentTime) ? v.currentTime : 0) + offset, false);
      }),
      previoustrack: withVideo('previoustrack', (v) => {
        if (finite(v.currentTime) && v.currentTime > CONFIG.PREVIOUS_RESTARTS_AFTER_S) {
          seekTo(v, 0, false);
          return;
        }
        intent('seek');
        if (!clickFirst(CONFIG.PREVIOUS_SELECTORS)) ns.log('warn', SOURCE, 'previoustrack: no previous button found');
      }),
      nexttrack: withVideo('nexttrack', () => {
        intent('seek');
        if (!clickFirst(CONFIG.NEXT_SELECTORS)) ns.log('warn', SOURCE, 'nexttrack: no next button found');
      }),
    };

    function install(action, handler) {
      if (typeof origSetActionHandler !== 'function') return;
      try {
        origSetActionHandler.call(session, action, handler);
      } catch (e) {
        ns.log('debug', SOURCE, 'setActionHandler(' + action + ') unsupported:', e);
      }
    }

    let playlistInstalled = null;
    function syncPlaylistHandlers() {
      const want = isPlaylist();
      if (want === playlistInstalled) return;
      playlistInstalled = want;
      for (const action of CONFIG.PLAYLIST_ACTIONS) install(action, want ? handlers[action] : null);
    }

    for (const action of CONFIG.TRANSPORT_ACTIONS) install(action, handlers[action]);
    syncPlaylistHandlers();

    ns.on('playerResponse', (pr) => {
      const meta = metaFromPlayerResponse(pr);
      if (!meta) return;
      remember(meta);
      applyMetadata(false);
    });
    ns.on('navigation', () => {
      syncPlaylistHandlers();
      applyMetadata(false);
    });
  });
})();
