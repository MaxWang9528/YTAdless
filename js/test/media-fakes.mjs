// Media fakes for Module D's tests (PLAN.md §5.7: jsdom has no media playback and no Media
// Session; install these in `beforeScripts`). Owner: Module D.

import { createPage, NAMESPACE } from './harness.mjs';

export const WATCH = 'https://m.youtube.com/watch?v=dQw4w9WgXcQ';
export const PLAYER_HTML =
  '<html><head><title>Never Gonna Give You Up - YouTube</title></head><body><div id="movie_player"></div></body></html>';

/** Settable HTMLMediaElement state; play()/pause() fire events. Returns `state(el)`. */
export function installMediaFakes(win) {
  const states = new WeakMap();
  const state = (el) => {
    if (!states.has(el)) {
      states.set(el, { paused: true, currentTime: 0, duration: NaN, readyState: 0, ended: false, playbackRate: 1, plays: 0, pauses: 0 });
    }
    return states.get(el);
  };
  const proto = win.HTMLMediaElement.prototype;
  for (const key of ['paused', 'currentTime', 'duration', 'readyState', 'ended', 'playbackRate']) {
    Object.defineProperty(proto, key, {
      configurable: true,
      get() { return state(this)[key]; },
      set(value) { state(this)[key] = value; },
    });
  }
  proto.play = function play() {
    const s = state(this);
    s.plays += 1;
    if (s.refusePlay) return win.Promise.reject(new win.DOMException('not allowed', 'NotAllowedError'));
    s.paused = false;
    s.readyState = 4;
    this.dispatchEvent(new win.Event('play'));
    this.dispatchEvent(new win.Event('playing'));
    return win.Promise.resolve();
  };
  proto.pause = function pause() {
    const s = state(this);
    s.pauses += 1;
    s.paused = true;
    this.dispatchEvent(new win.Event('pause'));
  };
  return state;
}

/** A system pause: WebKit pauses the element itself, without calling pause(). */
export function systemPause(win, video) {
  video.paused = true;
  video.dispatchEvent(new win.Event('pause'));
}

/** `Date.now` under test control. */
export function installClock(win, start = 1_700_000_000_000) {
  const clock = { t: start, advance(ms) { clock.t += ms; } };
  win.Date.now = () => clock.t;
  return clock;
}

/** Real visibility, as the original Document.prototype.hidden getter reports it. */
export function installVisibility(win) {
  const vis = { hidden: false };
  Object.defineProperty(win.Document.prototype, 'hidden', { configurable: true, enumerable: true, get: () => vis.hidden });
  Object.defineProperty(win.Document.prototype, 'visibilityState', {
    configurable: true, enumerable: true, get: () => (vis.hidden ? 'hidden' : 'visible'),
  });
  vis.set = (hidden) => {
    vis.hidden = hidden;
    win.document.dispatchEvent(new win.Event('visibilitychange'));
  };
  return vis;
}

/** navigator.userActivation.isActive under test control (jsdom events are never trusted). */
export function installUserActivation(win) {
  const activation = { isActive: false, hasBeenActive: false };
  Object.defineProperty(win.navigator, 'userActivation', { configurable: true, get: () => activation });
  return activation;
}

const ACTIONS = new Set(['play', 'pause', 'seekbackward', 'seekforward', 'previoustrack', 'nexttrack', 'skipad',
  'stop', 'seekto', 'togglemicrophone', 'togglecamera', 'hangup']);

/** A WebKit-like navigator.mediaSession: validates like the spec, records what was set. */
export function installMediaSession(win) {
  class MediaMetadata {
    constructor(init = {}) {
      this.title = init.title ?? '';
      this.artist = init.artist ?? '';
      this.album = init.album ?? '';
      this.artwork = (init.artwork ?? []).map((a) => ({ ...a }));
    }
  }
  const record = { handlers: new Map(), metadata: null, playbackState: 'none', position: undefined, positionCalls: 0 };
  class MediaSession {
    setActionHandler(action, handler) {
      if (!ACTIONS.has(action)) throw new win.TypeError(`unknown action ${action}`);
      if (handler) record.handlers.set(action, handler);
      else record.handlers.delete(action);
    }
    setPositionState(state) {
      record.positionCalls += 1;
      if (state === undefined) { record.position = null; return; }
      const { duration, playbackRate = 1, position = 0 } = state;
      if (!Number.isFinite(duration) || duration < 0) throw new win.TypeError('bad duration');
      if (!Number.isFinite(position) || position < 0 || position > duration) throw new win.TypeError('bad position');
      if (!Number.isFinite(playbackRate) || playbackRate === 0) throw new win.TypeError('bad rate');
      record.position = { duration, playbackRate, position };
    }
    get metadata() { return record.metadata; }
    set metadata(value) { record.metadata = value; }
    get playbackState() { return record.playbackState; }
    set playbackState(value) { record.playbackState = value; }
  }
  win.MediaMetadata = MediaMetadata;
  win.MediaSession = MediaSession;
  Object.defineProperty(win.navigator, 'mediaSession', { configurable: true, value: new MediaSession() });
  return record;
}

/**
 * A player page with the given D scripts and fakes. Returns helpers; the page closes after `t`.
 * `fakes`: subset of ['media', 'clock', 'visibility', 'activation', 'mediaSession'] (default all).
 */
export async function playerPage(t, { scripts, url = WATCH, html = PLAYER_HTML, fakes, ...options } = {}) {
  const want = new Set(fakes ?? ['media', 'clock', 'visibility', 'activation', 'mediaSession']);
  const env = {};
  const page = await createPage({
    role: 'player',
    url,
    scripts,
    html,
    beforeScripts: (win) => {
      if (want.has('media')) env.media = installMediaFakes(win);
      if (want.has('clock')) env.clock = installClock(win);
      if (want.has('visibility')) env.visibility = installVisibility(win);
      if (want.has('activation')) env.activation = installUserActivation(win);
      if (want.has('mediaSession')) env.session = installMediaSession(win);
    },
    ...options,
  });
  t.after(() => page.close());
  const ns = page.window[NAMESPACE];
  const addVideo = async ({ playing = false, duration = 213 } = {}) => {
    const video = page.document.createElement('video');
    video.className = 'html5-main-video';
    page.document.getElementById('movie_player').appendChild(video);
    await page.flush();  // MutationObserver
    video.duration = duration;
    if (playing) {
      video.paused = false;
      video.readyState = 4;
    }
    return video;
  };
  return { page, ns, win: page.window, addVideo, ...env };
}

export const playerResponse = (videoId, extra = {}) => ({
  videoDetails: {
    videoId,
    title: 'Never Gonna Give You Up',
    author: 'Rick Astley',
    lengthSeconds: '213',
    isLive: false,
    isLiveContent: false,
    thumbnail: {
      thumbnails: [
        { url: 'https://i.ytimg.com/big.jpg', width: 480, height: 360 },
        { url: 'https://i.ytimg.com/small.jpg', width: 120, height: 90 },
      ],
    },
    ...extra,
  },
});
