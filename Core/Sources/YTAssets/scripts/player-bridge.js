// player-bridge.js — owner: Module D (PLAN.md §6.4).
//
// Tracks the main <video> of the player webview and reports it to native:
//   posts   `playback` (~1 Hz while playing, plus every state change), `videoMeta`, `presentation`
//   emits   `videoElement` (each time the main video is (re)attached),
//           `userIntent` {source:'native'} for native commands, and {source:'page'} when page code
//           calls play()/pause() on the main video within a trusted user gesture (a tap on
//           YouTube's controls). A page call without a gesture (for example YouTube's own
//           background gating) is not intent, so background.js may reverse it.
//   handles commands play · pause · seek {to} · seekBy {delta} · pip {enter} · state
// videoMeta comes from the `playerResponse` event (hooks.js, Module A); ytInitialPlayerResponse
// and then the DOM are fallbacks.
//
// PiP (D13): native sends `pip` from inside the tap handler of its button (spike S-D3). If WebKit
// doesn't count that as user activation, PiP doesn't start; this file then shows an in-page PiP
// button on the player (the fallback), whose tap is a real page gesture, and remembers that for
// later loads. Presentation changes are watched by a window capture listener, which is registered
// before background.js's stopper for YouTube's `webkitpresentationmodechanged` reactions.
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
    // A page play()/pause() this soon after a trusted gesture is the user's (§6.4: ~1.5 s).
    GESTURE_WINDOW_MS: 1500,
    GESTURE_EVENTS: ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'mousedown', 'click', 'keydown'],
    // In-page PiP button (D13 fallback). 'auto' = shown once a native `pip {enter}` didn't start PiP.
    PIP_BUTTON: 'auto',                       // 'auto' | 'always' | 'never'
    PIP_BUTTON_ID: 'ytadless-pip-button',
    PIP_CHECK_MS: 1500,                       // native pip → presentation 'pip' within this, or fallback
    PIP_STORAGE_KEY: 'ytadless.pipFallback',  // localStorage '1' once the fallback was needed
    // Where the button goes: the mweb player container (2026-11 DOM; unverified on device).
    PIP_CONTAINER_SELECTORS: ['#movie_player', '#player-container-id', '#player'],
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
    const PRESENTATION_EVENTS = [  // watched at window capture, filtered to the main video
      'webkitpresentationmodechanged', 'enterpictureinpicture', 'leavepictureinpicture',
      'webkitbeginfullscreen', 'webkitendfullscreen',
    ];

    let video = null;
    let lastPlaybackAt = 0;
    let presentation = 'inline';
    let postedMeta = null;          // last videoMeta payload posted
    let postedMetaKey = '';
    const metaCache = new Map();    // videoId → meta from a playerResponse
    let lastGestureAt = -Infinity;
    let pipAttempt = null;          // {reached} for the latest native `pip {enter}`

    const now = () => Date.now();
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
      if (mode === 'pip' && pipAttempt) pipAttempt.reached = true;
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

    function onPresentationEvent(event) {
      ns.guard(SOURCE, () => {
        if (video && event.target === video) syncPresentation();
      });
    }
    for (const type of PRESENTATION_EVENTS) window.addEventListener(type, onPresentationEvent, true);

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
      }
      video = next;
      if (!video) return;
      for (const type of MEDIA_EVENTS) video.addEventListener(type, onMediaEvent);
      ns.emit('videoElement', video);
      syncPresentation();
      postPlayback();
    }

    function scan() {
      if (video && video.isConnected) return;
      attach(findVideo());
    }

    // ── page intent: a tap on YouTube's own controls ────────────────────────────────────────
    function onGesture(event) {
      ns.guard(SOURCE, () => {
        if (event.isTrusted) lastGestureAt = now();
      });
    }
    for (const type of CONFIG.GESTURE_EVENTS) {
      window.addEventListener(type, onGesture, { capture: true, passive: true });
    }

    function inGesture() {
      try {
        const activation = navigator.userActivation;
        if (activation && activation.isActive === true) return true;
      } catch (_) { /* not supported */ }
      return now() - lastGestureAt <= CONFIG.GESTURE_WINDOW_MS;
    }

    function notePageCall(el, action) {
      ns.guard(SOURCE, () => {
        if (el === video && inGesture()) ns.emit('userIntent', { action, source: 'page' });
      });
    }

    // Page code (YouTube) calls these; they report intent, then always call the original.
    // Native commands below call origPlay/origPause directly and report their own intent.
    HTMLMediaElement.prototype.play = function play() {
      notePageCall(this, 'play');
      return origPlay.apply(this, arguments);
    };
    HTMLMediaElement.prototype.pause = function pause() {
      notePageCall(this, 'pause');
      return origPause.apply(this, arguments);
    };

    // ── in-page PiP button (D13 fallback) ───────────────────────────────────────────────────
    let pipButton = null;
    let pipButtonWanted = CONFIG.PIP_BUTTON === 'always';
    if (CONFIG.PIP_BUTTON === 'auto') {
      try { pipButtonWanted = window.localStorage.getItem(CONFIG.PIP_STORAGE_KEY) === '1'; } catch (_) { /* no storage */ }
    }

    // Synchronous up to the WebKit call, so the tap that led here is still the activation.
    function setPiP(v, enter) {
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
    }

    function onPipButton(event) {
      ns.guard(SOURCE, () => {
        event.preventDefault();
        event.stopPropagation();
        scan();
        if (!video) return;
        pipAttempt = null;  // this tap is not a test of the native path
        const result = setPiP(video, presentationOf(video) !== 'pip');
        if (result && typeof result.then === 'function') {
          result.then(undefined, (e) => ns.log('warn', SOURCE, 'in-page pip failed:', e));
        }
      });
    }

    function makePipButton() {
      const b = document.createElement('button');
      b.id = CONFIG.PIP_BUTTON_ID;
      b.type = 'button';
      b.setAttribute('aria-label', 'Picture in picture');
      b.textContent = '⧉';
      Object.assign(b.style, {
        position: 'absolute', top: '8px', right: '8px', zIndex: '2147483647',
        width: '36px', height: '36px', padding: '0', border: '0', borderRadius: '18px',
        background: 'rgba(0,0,0,0.55)', color: '#fff', fontSize: '20px', lineHeight: '36px',
      });
      b.addEventListener('click', onPipButton, true);
      // Keep YouTube's player from also treating the tap as a tap on the video.
      for (const type of ['pointerdown', 'pointerup', 'touchstart', 'touchend', 'mousedown', 'mouseup']) {
        b.addEventListener(type, (e) => ns.guard(SOURCE, () => e.stopPropagation()), { passive: true });
      }
      return b;
    }

    function placePipButton() {
      if (!pipButtonWanted || CONFIG.PIP_BUTTON === 'never') return;
      if (pipButton && pipButton.isConnected) return;
      let container = null;
      for (const selector of CONFIG.PIP_CONTAINER_SELECTORS) {
        container = document.querySelector(selector);
        if (container) break;
      }
      if (!container) return;
      if (!pipButton) pipButton = makePipButton();
      container.appendChild(pipButton);
    }

    function wantPipButton(reason) {
      if (CONFIG.PIP_BUTTON === 'never' || pipButtonWanted) return;
      pipButtonWanted = true;
      try { window.localStorage.setItem(CONFIG.PIP_STORAGE_KEY, '1'); } catch (_) { /* no storage */ }
      ns.log('warn', SOURCE, 'native pip did not start (' + reason + '); showing the in-page PiP button (S-D3 fallback)');
      placePipButton();
    }

    // A native pip that worked undoes an earlier fallback (one bad attempt must not latch forever:
    // localStorage survives reinstalls, D20).
    function nativePipWorks() {
      if (CONFIG.PIP_BUTTON !== 'auto' || !pipButtonWanted) return;
      pipButtonWanted = false;
      try { window.localStorage.removeItem(CONFIG.PIP_STORAGE_KEY); } catch (_) { /* no storage */ }
      if (pipButton) pipButton.remove();
      ns.log('info', SOURCE, 'native pip works; in-page PiP button removed');
    }

    new MutationObserver(() => ns.guard(SOURCE, () => { scan(); placePipButton(); }))
      .observe(document, { childList: true, subtree: true });
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
      const attempt = enter ? { reached: false } : null;
      pipAttempt = attempt;
      const result = setPiP(v, enter);
      if (attempt) {
        // PiP reached at any point counts (the user may enter and leave it within the check).
        setTimeout(() => ns.guard(SOURCE, () => {
          if (attempt.reached || presentationOf(video) === 'pip') nativePipWorks();
          else wantPipButton('no PiP within ' + CONFIG.PIP_CHECK_MS + ' ms');
        }), CONFIG.PIP_CHECK_MS);
      }
      return result;
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
