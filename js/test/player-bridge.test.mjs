// player-bridge.js (PLAN.md §6.4). Owner: Module D (Phase 0 wrote these for the minimal version).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, commandVectors, NAMESPACE } from './harness.mjs';
import * as fakes from './media-fakes.mjs';

const WATCH = 'https://m.youtube.com/watch?v=dQw4w9WgXcQ';
const PLAYER_HTML = '<html><head><title>Never Gonna Give You Up - YouTube</title></head><body><div id="movie_player"></div></body></html>';

// jsdom has no media playback: make the HTMLMediaElement state settable and play/pause work.
function installMediaFakes(win) {
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

async function playerPage(t, options = {}) {
  let mediaState;
  const page = await createPage({
    role: 'player',
    url: WATCH,
    scripts: ['player-bridge.js'],
    html: PLAYER_HTML,
    beforeScripts: (win) => { mediaState = installMediaFakes(win); },
    ...options,
  });
  t.after(() => page.close());
  const ns = page.window[NAMESPACE];
  const addVideo = async () => {
    const video = page.document.createElement('video');
    video.className = 'html5-main-video';
    page.document.getElementById('movie_player').appendChild(video);
    await page.flush();  // MutationObserver
    return video;
  };
  return { page, ns, addVideo, media: (el) => mediaState(el) };
}

const playerResponse = (videoId, extra = {}) => ({
  videoDetails: {
    videoId,
    title: 'Never Gonna Give You Up',
    author: 'Rick Astley',
    lengthSeconds: '213',
    isLive: false,
    isLiveContent: false,
    thumbnail: { thumbnails: [{ url: 'https://i.ytimg.com/small.jpg', width: 120 }, { url: 'https://i.ytimg.com/big.jpg', width: 480 }] },
    ...extra,
  },
});

function assertAllMatchVectors(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
}

test('player-bridge.js › watch page › attaches to the main video, emits videoElement, posts playback', async (t) => {
  const { page, ns, addVideo } = await playerPage(t);
  const seen = [];
  ns.on('videoElement', (v) => seen.push(v));
  const video = await addVideo();
  assert.equal(seen.length, 1);
  assert.equal(seen[0], video);
  const [playback] = page.posted('playback');
  assert.deepEqual(playback, { status: 'idle', position: 0, duration: null, rate: 1, videoId: 'dQw4w9WgXcQ', v: 1, type: 'playback', frame: 'main' });
  assertAllMatchVectors(page);
  assertClean(page);
});

test('player-bridge.js › playerResponse › posts videoMeta with lengthSeconds as a number and the widest thumbnail', async (t) => {
  const { page, ns } = await playerPage(t);
  ns.emit('playerResponse', playerResponse('dQw4w9WgXcQ'), { source: 'initial', url: WATCH });
  ns.emit('playerResponse', playerResponse('dQw4w9WgXcQ'), { source: 'fetch', url: WATCH });  // same → no repost
  const metas = page.posted('videoMeta');
  assert.equal(metas.length, 1);
  assert.deepEqual(metas[0], {
    videoId: 'dQw4w9WgXcQ', title: 'Never Gonna Give You Up', author: 'Rick Astley', lengthSeconds: 213,
    thumbnailURL: 'https://i.ytimg.com/big.jpg', isLive: false, v: 1, type: 'videoMeta', frame: 'main',
  });
  assertAllMatchVectors(page);
});

test('player-bridge.js › playerResponse › a prefetched response for another video waits until the page navigates there', async (t) => {
  const { page, ns } = await playerPage(t);
  ns.emit('playerResponse', playerResponse('jNQXAC9IVRw', { title: 'Me at the zoo', lengthSeconds: '19' }), { source: 'fetch', url: 'x' });
  assert.equal(page.posted('videoMeta').length, 0);
  page.window.history.pushState({}, '', '/watch?v=jNQXAC9IVRw');
  ns.emit('navigation', { url: page.window.location.href });
  assert.deepEqual(page.posted('videoMeta').map((m) => [m.videoId, m.title, m.lengthSeconds]), [['jNQXAC9IVRw', 'Me at the zoo', 19]]);
});

test('player-bridge.js › DOM fallback › without a playerResponse, videoMeta comes from the page title', async (t) => {
  const { page, addVideo } = await playerPage(t);
  const video = await addVideo();
  video.dispatchEvent(new page.window.Event('loadedmetadata'));
  const [meta] = page.posted('videoMeta');
  assert.deepEqual(
    { videoId: meta.videoId, title: meta.title, author: meta.author, lengthSeconds: meta.lengthSeconds },
    { videoId: 'dQw4w9WgXcQ', title: 'Never Gonna Give You Up', author: '', lengthSeconds: null },
  );
  assertAllMatchVectors(page);
});

test('player-bridge.js › commands › every player-bridge.js command in commands.json is registered', async (t) => {
  const { page } = await playerPage(t);
  for (const c of commandVectors().commands.filter((c) => c.handler === 'player-bridge.js')) {
    const result = await page.cmd(c.name, c.args);
    assert.ok(!(result && typeof result.error === 'string' && result.error.startsWith('unknown-command')), `${c.name} is registered`);
  }
});

test('player-bridge.js › commands › without a video, transport commands answer {error: no-video}', async (t) => {
  const { page } = await playerPage(t);
  for (const name of ['play', 'pause', 'seek', 'seekBy', 'pip']) {
    assert.deepEqual(await page.cmd(name, { to: 1, delta: 1, enter: true }), { error: 'Error: no-video' }, name);
  }
});

test('player-bridge.js › play/pause › call the original methods, emit userIntent{native}, post playback', async (t) => {
  const { page, ns, addVideo, media } = await playerPage(t);
  const video = await addVideo();
  const intents = [];
  ns.on('userIntent', (i) => intents.push({ ...i }));
  assert.deepEqual(await page.cmd('play'), { ok: true });
  assert.equal(media(video).plays, 1);
  assert.equal(page.posted('playback').at(-1).status, 'playing');
  assert.deepEqual(await page.cmd('pause'), { ok: true });
  assert.equal(media(video).pauses, 1);
  assert.equal(page.posted('playback').at(-1).status, 'paused');
  assert.deepEqual(intents, [{ action: 'play', source: 'native' }, { action: 'pause', source: 'native' }]);
  assertAllMatchVectors(page);
});

test('player-bridge.js › seek › clamps to [0, duration]; seekBy is relative; bad args are errors', async (t) => {
  const { page, addVideo } = await playerPage(t);
  const video = await addVideo();
  video.duration = 213;
  video.currentTime = 100;
  assert.deepEqual(await page.cmd('seek', { to: 500 }), { ok: true, position: 213 });
  assert.deepEqual(await page.cmd('seek', { to: -5 }), { ok: true, position: 0 });
  video.currentTime = 100;
  assert.deepEqual(await page.cmd('seekBy', { delta: -10 }), { ok: true, position: 90 });
  assert.equal(video.currentTime, 90);
  assert.match((await page.cmd('seek', { to: 'soon' })).error, /`to` must be a number/);
});

test('player-bridge.js › playback › NaN duration posts null; timeupdate is throttled to ~1 Hz', async (t) => {
  const { page, addVideo } = await playerPage(t);
  const video = await addVideo();
  video.paused = false;
  video.readyState = 4;
  const before = page.posted('playback').length;
  for (let i = 0; i < 10; i += 1) video.dispatchEvent(new page.window.Event('timeupdate'));
  assert.ok(page.posted('playback').length - before <= 1, 'at most one timeupdate post');
  video.dispatchEvent(new page.window.Event('playing'));
  const last = page.posted('playback').at(-1);
  assert.equal(last.duration, null);
  assert.equal(last.status, 'playing');
  assertAllMatchVectors(page);
});

test('player-bridge.js › presentation › posts pip / inline on webkitpresentationmodechanged', async (t) => {
  const { page, addVideo } = await playerPage(t);
  const video = await addVideo();
  Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: 'picture-in-picture' });
  video.dispatchEvent(new page.window.Event('webkitpresentationmodechanged'));
  video.webkitPresentationMode = 'inline';
  video.dispatchEvent(new page.window.Event('webkitpresentationmodechanged'));
  assert.deepEqual(page.posted('presentation').map((m) => m.mode), ['pip', 'inline']);
  assertAllMatchVectors(page);
});

test('player-bridge.js › pip › uses webkitSetPresentationMode when available', async (t) => {
  const { page, addVideo } = await playerPage(t);
  const video = await addVideo();
  const modes = [];
  video.webkitSetPresentationMode = (mode) => modes.push(mode);
  assert.deepEqual(await page.cmd('pip', { enter: true }), { ok: true });
  assert.deepEqual(await page.cmd('pip', { enter: false }), { ok: true });
  assert.deepEqual(modes, ['picture-in-picture', 'inline']);
});

test('player-bridge.js › state › returns meta, playback and presentation in bridge shapes', async (t) => {
  const { page, ns, addVideo } = await playerPage(t);
  await addVideo();
  ns.emit('playerResponse', playerResponse('dQw4w9WgXcQ'), { source: 'initial', url: WATCH });
  const state = await page.cmd('state');
  assert.deepEqual(Object.keys(state).sort(), ['meta', 'playback', 'presentation']);
  assertMatchesVector({ v: 1, type: 'videoMeta', frame: 'main', ...state.meta }, 'state.meta');
  assertMatchesVector({ v: 1, type: 'playback', frame: 'main', ...state.playback }, 'state.playback');
  assertMatchesVector({ v: 1, type: 'presentation', frame: 'main', mode: state.presentation }, 'state.presentation');
  assertClean(page);
});

// ── Module D additions: page intent and the in-page PiP fallback (PLAN.md §6.4, D13) ─────────

test('player-bridge.js › page intent › page play()/pause() during user activation emit userIntent{page}', async (t) => {
  const { page, ns, addVideo, activation, media } = await fakes.playerPage(t, { scripts: ['player-bridge.js'] });
  const video = await addVideo();
  const intents = [];
  ns.on('userIntent', (i) => intents.push(`${i.action}:${i.source}`));
  activation.isActive = true;
  await video.play();
  video.pause();
  activation.isActive = false;
  video.pause();  // no gesture: YouTube's own call, not intent
  const other = page.document.createElement('video');
  activation.isActive = true;
  other.pause();  // not the main video
  assert.deepEqual(intents, ['play:page', 'pause:page']);
  assert.equal(media(video).plays, 1, 'the original play still runs');
  assert.equal(media(video).pauses, 2, 'the original pause still runs');
  assertClean(page);
});

test('player-bridge.js › pip fallback › no PiP within 1.5 s of a native pip shows the in-page button, persisted', async (t) => {
  const { page, addVideo } = await fakes.playerPage(t, { scripts: ['player-bridge.js'] });
  const video = await addVideo();
  const modes = [];
  video.webkitSetPresentationMode = (mode) => modes.push(mode);  // WebKit ignores it: no activation
  assert.deepEqual(await page.cmd('pip', { enter: true }), { ok: true });
  assert.equal(page.document.getElementById('ytadless-pip-button'), null);
  await page.flush(1600);
  const button = page.document.getElementById('ytadless-pip-button');
  assert.ok(button, 'button shown');
  assert.equal(button.parentElement.id, 'movie_player');
  assert.equal(page.window.localStorage.getItem('ytadless.pipFallback'), '1');
  assert.ok(page.posted('log').some((m) => m.level === 'warn' && /S-D3 fallback/.test(m.message)));
  button.click();
  assert.deepEqual(modes, ['picture-in-picture', 'picture-in-picture']);
  assertClean(page);
});

test('player-bridge.js › pip fallback › a native pip that works shows no button', async (t) => {
  const { page, win, addVideo } = await fakes.playerPage(t, { scripts: ['player-bridge.js'] });
  const video = await addVideo();
  video.webkitSetPresentationMode = (mode) => {
    Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: mode });
    video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
  };
  await page.cmd('pip', { enter: true });
  await page.flush(1600);
  assert.equal(page.document.getElementById('ytadless-pip-button'), null);
  assert.deepEqual(page.posted('presentation').map((m) => m.mode), ['pip']);
  assertClean(page);
});

test('player-bridge.js › pip fallback › entering and leaving PiP within the check window does not latch the fallback', async (t) => {
  const { page, win, addVideo } = await fakes.playerPage(t, { scripts: ['player-bridge.js'] });
  const video = await addVideo();
  const setMode = (mode) => {
    Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: mode });
    video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
  };
  video.webkitSetPresentationMode = setMode;
  await page.cmd('pip', { enter: true });
  setMode('inline');  // the user closes PiP right away
  await page.flush(1600);
  assert.equal(page.document.getElementById('ytadless-pip-button'), null);
  assert.equal(page.window.localStorage.getItem('ytadless.pipFallback'), null);
  assertClean(page);
});

test('player-bridge.js › pip fallback › a later native pip that works removes the button and clears the flag', async (t) => {
  const page = await createPage({
    role: 'player', url: fakes.WATCH, scripts: ['player-bridge.js'], html: fakes.PLAYER_HTML,
    beforeScripts: (win) => { win.localStorage.setItem('ytadless.pipFallback', '1'); fakes.installMediaFakes(win); },
  });
  t.after(() => page.close());
  const win = page.window;
  const video = page.document.createElement('video');
  page.document.getElementById('movie_player').appendChild(video);
  await page.flush();
  assert.ok(page.document.getElementById('ytadless-pip-button'));
  video.webkitSetPresentationMode = (mode) => {
    Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: mode });
    video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
  };
  await page.cmd('pip', { enter: true });
  await page.flush(1600);
  assert.equal(page.document.getElementById('ytadless-pip-button'), null);
  assert.equal(win.localStorage.getItem('ytadless.pipFallback'), null);
  assertClean(page);
});

test('player-bridge.js › pip fallback › once needed, the button is placed on the next load and after DOM swaps', async (t) => {
  const page = await createPage({
    role: 'player', url: fakes.WATCH, scripts: ['player-bridge.js'], html: fakes.PLAYER_HTML,
    beforeScripts: (win) => { win.localStorage.setItem('ytadless.pipFallback', '1'); fakes.installMediaFakes(win); },
  });
  t.after(() => page.close());
  await page.flush();
  assert.ok(page.document.querySelector('#movie_player > #ytadless-pip-button'));
  const player = page.document.getElementById('movie_player');
  player.replaceWith(player.cloneNode(false));  // YouTube rebuilds the player
  await page.flush();
  assert.ok(page.document.querySelector('#movie_player > #ytadless-pip-button'), 're-placed');
  assertClean(page);
});

// ── app full screen (CONFIG.FULLSCREEN_*) ────────────────────────────────────────────────────
// jsdom has no fullscreen API: give it WebKit's names, recording calls that reach the originals.
function installFullscreenFakes(win) {
  const reached = [];
  win.HTMLVideoElement.prototype.webkitEnterFullscreen = function () { reached.push('webkitEnterFullscreen'); };
  win.HTMLVideoElement.prototype.webkitExitFullscreen = function () { reached.push('webkitExitFullscreen'); };
  win.Element.prototype.requestFullscreen = function () { reached.push('requestFullscreen'); return win.Promise.resolve(); };
  win.Document.prototype.exitFullscreen = function () { reached.push('exitFullscreen'); return win.Promise.resolve(); };
  return reached;
}

async function fullscreenPage(t) {
  let reached;
  const { page, addVideo, ...rest } = await playerPage(t, {
    beforeScripts: (win) => { installMediaFakes(win); reached = installFullscreenFakes(win); },
  });
  const video = await addVideo();
  return { page, video, reached: () => reached, requests: () => page.posted('fullscreenRequest').map((m) => m.enter), ...rest };
}

test('player-bridge.js › fullscreen › video.webkitEnterFullscreen posts fullscreenRequest{enter:true} and never reaches WebKit', async (t) => {
  const { page, video, reached, requests } = await fullscreenPage(t);
  video.webkitEnterFullscreen();
  assert.deepEqual(requests(), [true]);
  assert.deepEqual(reached(), [], 'WebKit video full screen is not entered');
  assertAllMatchVectors(page);
  assertClean(page, 'fullscreen');
});

test('player-bridge.js › fullscreen › requestFullscreen on the player container is the app full screen; other elements are untouched', async (t) => {
  const { page, reached, requests } = await fullscreenPage(t);
  const result = page.document.getElementById('movie_player').requestFullscreen();
  assert.equal(typeof result.then, 'function', 'still returns a promise');
  assert.deepEqual(requests(), [true]);
  await page.flush(700);
  const other = page.document.createElement('div');
  page.document.body.appendChild(other);
  other.requestFullscreen();
  assert.deepEqual(requests(), [true], 'an element without the video is not the player');
  assert.deepEqual(reached(), ['requestFullscreen']);
  assertClean(page, 'element fullscreen');
});

test('player-bridge.js › fullscreen › variants tried for one tap post one request; exits post enter:false', async (t) => {
  const { page, video, requests } = await fullscreenPage(t);
  page.document.getElementById('movie_player').requestFullscreen();
  video.webkitEnterFullscreen();
  assert.deepEqual(requests(), [true], 'debounced');
  await page.flush(700);
  page.document.exitFullscreen();
  assert.deepEqual(requests(), [true, false]);
  await page.flush(700);
  video.webkitExitFullscreen();
  assert.deepEqual(requests(), [true, false, false]);
  assertAllMatchVectors(page);
  assertClean(page, 'exits');
});
