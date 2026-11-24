// background.js — owner: Module D (PLAN.md §6.4).
//
// Keeps playback alive when the app is in the background or the screen is locked (D12, F9, F10).
// CONFIG below is the source of truth for every countermeasure. They are:
//   - the page always looks visible: Document.prototype hidden / visibilityState / webkitHidden /
//     webkitVisibilityState, and the onvisibilitychange / onwebkitvisibilitychange handlers
//   - page listeners never see visibilitychange / webkitvisibilitychange (ours runs first, at
//     window capture, and stops it); document.hasFocus() is true; window `blur` is stopped
//   - `_lact` (YouTube's "last activity" time) is refreshed, and a synthetic mousemove reaches the
//     player now and then, against "Are you still watching?"
//   - `youThereRenderer` is pruned from responses (through hooks.addPruner when hooks.js provides it)
//   - YouTube's `webkitpresentationmodechanged` reactions are stopped (player-bridge.js has already
//     seen the event: its window capture listener is registered first)
//   - the resume policy: a pause that isn't intentional, while native lifecycle is inactive or
//     background (or up to 2 s before the real visibilitychange), is reversed with the original
//     play(), at most 3 times per 30 s.
// A pause is intentional when: a userIntent (page tap, native command, remote command) other than
// `play` arrived within ~1.5 s; the video is in PiP or left PiP within 1 s (the PiP X pauses);
// an audio interruption is active; or the video ended.
//
// Handles commands: lifecycle {state} · audioInterruption {phase, shouldResume}.
(() => {
  'use strict';

  const SOURCE = 'background.js';
  const CONFIG = Object.freeze({
    // Spoofed Document properties → value (Brave MediaBackgroundingScript.js, brave-video-bg-play-update.js).
    VISIBILITY_PROPS: Object.freeze({ hidden: false, webkitHidden: false, visibilityState: 'visible', webkitVisibilityState: 'visible' }),
    VISIBILITY_HANDLER_PROPS: ['onvisibilitychange', 'onwebkitvisibilitychange'],
    VISIBILITY_EVENTS: ['visibilitychange', 'webkitvisibilitychange'],
    // Stopped at window capture so YouTube doesn't react to PiP / fullscreen changes
    // (Brave MediaBackgroundingScript.js stops webkitpresentationmodechanged).
    PRESENTATION_EVENTS: ['webkitpresentationmodechanged'],
    // Resume policy (PLAN.md §6.4).
    INTENT_WINDOW_MS: 1500,
    PENDING_PAUSE_MS: 2000,      // WebKit pauses, then fires visibilitychange (F9; Brave waits 2 s)
    PIP_EXIT_GRACE_MS: 1000,     // the PiP close X pauses around the time it leaves PiP
    RESUME_CAP: 3,
    RESUME_CAP_WINDOW_MS: 30000,
    INTERRUPTION_UNDO_MS: 2000,  // an auto-resume this close before `began` is undone (calls, Siri)
    // Keep-alive (brave-video-bg-play-update.js, 2026): _lact every 5 min; mousemove every 10 min.
    LACT_KEY: '_lact',
    LACT_REFRESH_MS: 5 * 60 * 1000,
    ACTIVITY_INTERVAL_MS: 10 * 60 * 1000,
    ACTIVITY_SELECTOR: '#movie_player',
    // "Are you still watching?" (PLAN.md §6.4). Unverified against a fixture as of 2026-11.
    YOU_THERE_KEY: 'youThereRenderer',
    PRUNE_MAX_DEPTH: 40,
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const origPlay = HTMLMediaElement.prototype.play;
    const origPause = HTMLMediaElement.prototype.pause;
    const now = () => Date.now();
    const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

    // ── state ───────────────────────────────────────────────────────────────────────────────
    let lifecycle = 'active';
    let video = null;
    let lastIntent = { at: -Infinity, action: '' };
    let pending = null;               // {at, video}: a suspect pause while still active and visible
    let resumes = [];                 // auto-resume times within the cap window
    let gaveUpLogged = false;
    let lastAutoResumeAt = -Infinity;
    let lastUnintendedPauseAt = -Infinity;
    let pipExitedAt = -Infinity;
    let wasPiP = false;
    const interruption = { active: false, wasPlaying: false };

    // ── visibility spoofing ─────────────────────────────────────────────────────────────────
    const proto = Document.prototype;
    const origDescriptors = {};
    for (const prop of Object.keys(CONFIG.VISIBILITY_PROPS)) {
      origDescriptors[prop] = Object.getOwnPropertyDescriptor(proto, prop);
    }

    // The real visibility, read through the original getter.
    function realHidden() {
      try {
        const d = origDescriptors.hidden;
        if (d && typeof d.get === 'function') return d.get.call(document) === true;
        const w = origDescriptors.webkitHidden;
        if (w && typeof w.get === 'function') return w.get.call(document) === true;
      } catch (_) { /* fall through */ }
      return false;
    }

    function spoof(target, prop, descriptor) {
      try {
        const existing = Object.getOwnPropertyDescriptor(target, prop);
        if (existing && !existing.configurable) return false;
        Object.defineProperty(target, prop, descriptor);
        return true;
      } catch (_) {
        return false;
      }
    }

    for (const [prop, value] of Object.entries(CONFIG.VISIBILITY_PROPS)) {
      const descriptor = { configurable: true, enumerable: true, get() { return value; } };
      if (!spoof(proto, prop, descriptor)) spoof(document, prop, descriptor);
    }

    const handlerSlots = new WeakMap();  // document → {prop: handler}; stored, never called
    for (const prop of CONFIG.VISIBILITY_HANDLER_PROPS) {
      const descriptor = {
        configurable: true,
        enumerable: true,
        get() { const slots = handlerSlots.get(this); return slots && hasOwn(slots, prop) ? slots[prop] : null; },
        set(fn) {
          let slots = handlerSlots.get(this);
          if (!slots) handlerSlots.set(this, (slots = {}));
          slots[prop] = typeof fn === 'function' ? fn : null;
        },
      };
      if (!spoof(proto, prop, descriptor)) spoof(document, prop, descriptor);
    }

    const origHasFocus = proto.hasFocus;
    if (typeof origHasFocus === 'function') {
      proto.hasFocus = function hasFocus() {
        if (lifecycle !== 'active' || realHidden()) return true;
        return origHasFocus.apply(this, arguments);
      };
    }

    function onVisibilityEvent(event) {
      ns.guard(SOURCE, () => {
        event.stopImmediatePropagation();
        if (event.type === 'visibilitychange' && realHidden()) resolvePending('hidden');
      });
    }
    for (const type of CONFIG.VISIBILITY_EVENTS) window.addEventListener(type, onVisibilityEvent, true);

    window.addEventListener('blur', (event) => ns.guard(SOURCE, () => {
      if (event.target === window) event.stopImmediatePropagation();
    }), true);

    // ── presentation ────────────────────────────────────────────────────────────────────────
    function isPiP(v) {
      if (!v) return false;
      try {
        if (v.webkitPresentationMode === 'picture-in-picture') return true;
        return document.pictureInPictureElement === v;
      } catch (_) {
        return false;
      }
    }

    function syncPiP() {
      const pip = isPiP(video);
      if (wasPiP && !pip) pipExitedAt = now();
      wasPiP = pip;
    }

    function onPresentationEvent(event) {
      ns.guard(SOURCE, () => {
        if (video && event.target === video) syncPiP();
        event.stopImmediatePropagation();
      });
    }
    for (const type of CONFIG.PRESENTATION_EVENTS) window.addEventListener(type, onPresentationEvent, true);
    for (const type of ['enterpictureinpicture', 'leavepictureinpicture']) {
      window.addEventListener(type, (event) => ns.guard(SOURCE, () => {
        if (video && event.target === video) syncPiP();
      }), true);
    }

    // ── resume policy (D12) ─────────────────────────────────────────────────────────────────
    function intentionalReason(v) {
      if (v.ended) return 'ended';
      if (interruption.active) return 'interruption';
      if (isPiP(v)) return 'pip';
      if (now() - pipExitedAt <= CONFIG.PIP_EXIT_GRACE_MS) return 'pip-exit';
      if (lastIntent.action !== 'play' && now() - lastIntent.at <= CONFIG.INTENT_WINDOW_MS) return 'intent:' + lastIntent.action;
      return null;
    }

    function resume(v, why) {
      const t = now();
      resumes = resumes.filter((at) => t - at < CONFIG.RESUME_CAP_WINDOW_MS);
      if (resumes.length >= CONFIG.RESUME_CAP) {
        if (!gaveUpLogged) {
          gaveUpLogged = true;
          ns.log('warn', SOURCE, 'auto-resume cap reached (' + CONFIG.RESUME_CAP + ' per ' + CONFIG.RESUME_CAP_WINDOW_MS + ' ms); leaving the video paused');
        }
        return false;
      }
      gaveUpLogged = false;
      resumes.push(t);
      lastAutoResumeAt = t;
      ns.log('info', SOURCE, 'resuming a system pause (' + why + ', lifecycle ' + lifecycle + ')');
      try {
        const result = origPlay.call(v);
        if (result && typeof result.then === 'function') {
          result.then(undefined, (e) => ns.log('warn', SOURCE, 'resume was refused:', e));
        }
      } catch (e) {
        ns.log('warn', SOURCE, 'resume threw:', e);
      }
      return true;
    }

    function onPause(event) {
      ns.guard(SOURCE, () => {
        const v = event.target;
        if (v !== video) return;
        const reason = intentionalReason(v);
        if (reason) {
          pending = null;
          ns.log('debug', SOURCE, 'pause kept (' + reason + ')');
          return;
        }
        lastUnintendedPauseAt = now();
        if (lifecycle !== 'active' || realHidden()) {
          pending = null;
          resume(v, 'background');
        } else {
          pending = { at: now(), video: v };
        }
      });
    }

    // A suspect pause becomes a system pause once the app turns out to be leaving the foreground.
    function resolvePending(why) {
      const p = pending;
      pending = null;
      if (!p || now() - p.at > CONFIG.PENDING_PAUSE_MS) return;
      const v = p.video;
      if (v !== video || !v.paused || intentionalReason(v)) return;
      resume(v, 'before ' + why);
    }

    function onPlay(event) {
      if (event.target === video) pending = null;
    }

    ns.on('videoElement', (v) => {
      if (video) {
        video.removeEventListener('pause', onPause);
        video.removeEventListener('play', onPlay);
      }
      video = v;
      pending = null;
      wasPiP = isPiP(v);
      v.addEventListener('pause', onPause);
      v.addEventListener('play', onPlay);
    });

    ns.on('userIntent', (i) => {
      if (!i || typeof i.action !== 'string') return;
      lastIntent = { at: now(), action: i.action };
      if (i.action !== 'play') pending = null;
    });

    // ── commands ────────────────────────────────────────────────────────────────────────────
    const LIFECYCLE_STATES = ['active', 'inactive', 'background'];
    ns.command('lifecycle', (args) => {
      if (!LIFECYCLE_STATES.includes(args.state)) throw new Error('lifecycle: unknown state ' + String(args.state));
      lifecycle = args.state;
      if (lifecycle === 'active') pending = null;
      else resolvePending(lifecycle);
      return { ok: true };
    });

    ns.command('audioInterruption', (args) => {
      if (args.phase !== 'began' && args.phase !== 'ended') throw new Error('audioInterruption: unknown phase ' + String(args.phase));
      const v = video;
      const t = now();
      if (args.phase === 'began') {
        pending = null;
        const recentlyResumed = t - lastAutoResumeAt <= CONFIG.INTERRUPTION_UNDO_MS;
        interruption.active = true;
        interruption.wasPlaying = Boolean(v) && !v.ended &&
          (!v.paused || recentlyResumed || t - lastUnintendedPauseAt <= CONFIG.INTERRUPTION_UNDO_MS);
        if (v && !v.paused && recentlyResumed) {
          ns.log('info', SOURCE, 'audio interruption began right after an auto-resume; pausing again');
          origPause.call(v);
        }
        return { ok: true };
      }
      const shouldResume = args.shouldResume === true;
      const wasPlaying = interruption.wasPlaying;
      interruption.active = false;
      interruption.wasPlaying = false;
      let resumed = false;
      if (shouldResume && wasPlaying && v && v.paused && !v.ended) {
        resumed = true;
        const result = origPlay.call(v);
        if (result && typeof result.then === 'function') {
          result.then(undefined, (e) => ns.log('warn', SOURCE, 'resume after interruption was refused:', e));
        }
      }
      return { ok: true, resumed };
    });

    // ── keep-alive ──────────────────────────────────────────────────────────────────────────
    setInterval(() => ns.guard(SOURCE, () => {
      if (hasOwn(window, CONFIG.LACT_KEY) && window[CONFIG.LACT_KEY] !== undefined) window[CONFIG.LACT_KEY] = now();
    }), CONFIG.LACT_REFRESH_MS);

    setInterval(() => ns.guard(SOURCE, () => {
      const target = document.querySelector(CONFIG.ACTIVITY_SELECTOR);
      if (target) target.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
      if (hasOwn(window, CONFIG.LACT_KEY) && window[CONFIG.LACT_KEY] !== undefined) window[CONFIG.LACT_KEY] = now();
    }), CONFIG.ACTIVITY_INTERVAL_MS);

    // ── "Are you still watching?" ───────────────────────────────────────────────────────────
    // Removes every `youThereRenderer` (the key, or the array element that holds it) in place.
    function pruneYouThere(root) {
      let removed = 0;
      const walk = (node, depth) => {
        if (!node || typeof node !== 'object' || depth > CONFIG.PRUNE_MAX_DEPTH) return;
        if (Array.isArray(node)) {
          for (let i = node.length - 1; i >= 0; i -= 1) {
            const el = node[i];
            if (el && typeof el === 'object' && !Array.isArray(el) && hasOwn(el, CONFIG.YOU_THERE_KEY)) {
              node.splice(i, 1);
              removed += 1;
            } else {
              walk(el, depth + 1);
            }
          }
          return;
        }
        for (const key of Object.keys(node)) {
          if (key === CONFIG.YOU_THERE_KEY) {
            delete node[key];
            removed += 1;
          } else {
            walk(node[key], depth + 1);
          }
        }
      };
      walk(root, 0);
      if (removed > 0) ns.log('info', SOURCE, 'pruned ' + removed + ' ' + CONFIG.YOU_THERE_KEY);
      return root;
    }

    const hooks = ns.hooks;
    if (hooks && typeof hooks.addPruner === 'function') {
      // Assumed contract (§5.2; hooks.js unmerged): fn(json) prunes in place, and returns the
      // same object in case the engine uses the return value.
      ns.guard(SOURCE, () => hooks.addPruner({
        name: CONFIG.YOU_THERE_KEY,
        fn: (json) => { ns.guard(SOURCE, () => pruneYouThere(json)); return json; },
      }));
    } else {
      ns.log('debug', SOURCE, 'hooks.addPruner unavailable; youThereRenderer pruned only from playerResponse events');
    }
    ns.on('playerResponse', (pr) => { pruneYouThere(pr); });
  });
})();
