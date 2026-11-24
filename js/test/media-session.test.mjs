// media-session.js (PLAN.md §6.4 Now Playing, D11) against a mocked navigator.mediaSession.
// Owner: Module D.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector, createPage } from './harness.mjs';
import { playerPage, playerResponse, systemPause, WATCH } from './media-fakes.mjs';

const ONLY_MS = ['player-bridge.js', 'media-session.js'];
const ALL_D = ['player-bridge.js', 'background.js', 'media-session.js'];

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

test('media-session.js › watch page › installs play, pause, seekto and ±10 s; no track buttons outside a playlist', async (t) => {
  const { page, session } = await playerPage(t, { scripts: ONLY_MS });
  assert.deepEqual([...session.handlers.keys()].sort(), ['pause', 'play', 'seekbackward', 'seekforward', 'seekto']);
  assertAll(page);
});

test('media-session.js › playlist page › adds previoustrack / nexttrack, and drops them when leaving the playlist', async (t) => {
  const { page, ns, session } = await playerPage(t, { scripts: ONLY_MS, url: WATCH + '&list=PL1234567890' });
  assert.ok(session.handlers.has('nexttrack') && session.handlers.has('previoustrack'));
  page.window.history.pushState({}, '', '/watch?v=jNQXAC9IVRw');
  ns.emit('navigation', { url: page.window.location.href });
  assert.ok(!session.handlers.has('nexttrack') && !session.handlers.has('previoustrack'));
  assertAll(page);
});

test("media-session.js › YouTube's writes › setActionHandler, metadata, setPositionState and playbackState are ignored", async (t) => {
  const { page, win, session } = await playerPage(t, { scripts: ONLY_MS });
  const ours = session.handlers.get('pause');
  const ms = win.navigator.mediaSession;
  ms.setActionHandler('pause', () => 'youtube');
  ms.setActionHandler('play', null);
  ms.metadata = new win.MediaMetadata({ title: 'YouTube says' });
  ms.setPositionState({ duration: 1, position: 0 });
  ms.playbackState = 'none';
  assert.equal(session.handlers.get('pause'), ours);
  assert.ok(session.handlers.has('play'));
  assert.equal(session.metadata, null);
  assert.equal(session.positionCalls, 0);
  assert.equal(session.playbackState, 'none');
  ms.setActionHandler('skipad', () => {});  // not ours: passes through to the original
  assert.ok(session.handlers.has('skipad'));
  assertAll(page);
});

test('media-session.js › playerResponse › sets MediaMetadata with title, channel and artwork (smallest first)', async (t) => {
  const { page, ns, session } = await playerPage(t, { scripts: ONLY_MS });
  ns.emit('playerResponse', playerResponse('dQw4w9WgXcQ'), { source: 'initial', url: WATCH });
  const m = session.metadata;
  assert.equal(m.title, 'Never Gonna Give You Up');
  assert.equal(m.artist, 'Rick Astley');
  assert.deepEqual(m.artwork, [
    { src: 'https://i.ytimg.com/small.jpg', sizes: '120x90' },
    { src: 'https://i.ytimg.com/big.jpg', sizes: '480x360' },
  ]);
  assertAll(page);
});

test('media-session.js › playerResponse › a prefetched response for another video is held until navigation', async (t) => {
  const { page, ns, session } = await playerPage(t, { scripts: ONLY_MS });
  ns.emit('playerResponse', playerResponse('jNQXAC9IVRw', { title: 'Me at the zoo' }), { source: 'fetch', url: 'x' });
  assert.equal(session.metadata, null);
  page.window.history.pushState({}, '', '/watch?v=jNQXAC9IVRw');
  ns.emit('navigation', { url: page.window.location.href });
  assert.equal(session.metadata.title, 'Me at the zoo');
  assertAll(page);
});

test('media-session.js › DOM fallback › without a playerResponse, the page title is used on loadedmetadata', async (t) => {
  const { page, win, addVideo, session } = await playerPage(t, { scripts: ONLY_MS });
  const video = await addVideo();
  video.dispatchEvent(new win.Event('loadedmetadata'));
  assert.equal(session.metadata.title, 'Never Gonna Give You Up');
  assertAll(page);
});

test('media-session.js › position state › set on play/pause/seeked/ratechange, clamped, and cleared for live', async (t) => {
  const { page, win, addVideo, session } = await playerPage(t, { scripts: ONLY_MS });
  const video = await addVideo({ duration: 213 });
  video.currentTime = 50;
  await page.cmd('play');
  assert.deepEqual(session.position, { duration: 213, playbackRate: 1, position: 50 });
  assert.equal(session.playbackState, 'playing');
  video.currentTime = 999;  // past the end: clamped instead of throwing
  video.playbackRate = 0;   // invalid for setPositionState: reported as 1
  video.dispatchEvent(new win.Event('ratechange'));
  assert.deepEqual(session.position, { duration: 213, playbackRate: 1, position: 213 });
  await page.cmd('pause');
  assert.equal(session.playbackState, 'paused');
  video.duration = Infinity;  // live
  video.dispatchEvent(new win.Event('durationchange'));
  assert.equal(session.position, null);
  assertAll(page);
});

test('media-session.js › handlers › each emits userIntent{remote} first, then acts on the video', async (t) => {
  const { page, ns, addVideo, session, media } = await playerPage(t, { scripts: ONLY_MS });
  const video = await addVideo({ duration: 213 });
  const intents = [];
  ns.on('userIntent', (i) => intents.push(`${i.action}:${i.source}:${video.paused ? 'paused' : 'playing'}`));
  session.handlers.get('play')({ action: 'play' });
  assert.equal(media(video).plays, 1);
  session.handlers.get('pause')({ action: 'pause' });
  assert.equal(media(video).pauses, 1);
  video.currentTime = 100;
  session.handlers.get('seekbackward')({ action: 'seekbackward' });
  assert.equal(video.currentTime, 90);
  session.handlers.get('seekforward')({ action: 'seekforward', seekOffset: 30 });
  assert.equal(video.currentTime, 120);
  session.handlers.get('seekto')({ action: 'seekto', seekTime: 500 });
  assert.equal(video.currentTime, 213);
  assert.deepEqual(intents, ['play:remote:paused', 'pause:remote:playing', 'seek:remote:paused', 'seek:remote:paused', 'seek:remote:paused']);
  assertAll(page);
});

test('media-session.js › handlers › without a video they log instead of throwing', async (t) => {
  const { page, session } = await playerPage(t, { scripts: ONLY_MS });
  session.handlers.get('play')({ action: 'play' });
  assert.ok(page.posted('log').some((m) => m.source === 'media-session.js' && /no video/.test(m.message)));
  assertAll(page);
});

test('media-session.js › playlist › nexttrack clicks the next button; previoustrack restarts past 3 s', async (t) => {
  const html = '<html><head><title>x - YouTube</title></head><body><div id="movie_player"></div>' +
    '<button class="player-controls-next-button"></button><button class="player-controls-prev-button"></button></body></html>';
  const { page, addVideo, session } = await playerPage(t, { scripts: ONLY_MS, url: WATCH + '&list=PL1234567890', html });
  const video = await addVideo();
  const clicks = [];
  page.document.querySelector('.player-controls-next-button').addEventListener('click', () => clicks.push('next'));
  page.document.querySelector('.player-controls-prev-button').addEventListener('click', () => clicks.push('prev'));
  session.handlers.get('nexttrack')({ action: 'nexttrack' });
  video.currentTime = 10;
  session.handlers.get('previoustrack')({ action: 'previoustrack' });
  assert.equal(video.currentTime, 0);
  session.handlers.get('previoustrack')({ action: 'previoustrack' });
  assert.deepEqual(clicks, ['next', 'prev']);
  assertAll(page);
});

test('media-session.js › no Media Session › loads cleanly and does nothing', async (t) => {
  const page = await createPage({ role: 'player', url: WATCH, scripts: ['media-session.js'] });
  t.after(() => page.close());
  assertClean(page);
});

// ── all of Module D's scripts together ──────────────────────────────────────────────────────

test('player-bridge + background + media-session › lock screen pause in background is never auto-resumed (item 11)', async (t) => {
  const { page, addVideo, session, media, clock } = await playerPage(t, { scripts: ALL_D });
  const video = await addVideo({ playing: true });
  await page.cmd('lifecycle', { state: 'background' });
  session.handlers.get('pause')({ action: 'pause' });
  await page.flush();
  assert.equal(video.paused, true);
  assert.equal(media(video).plays, 0);
  // …while an unexplained pause a few seconds later (after a remote play) is reversed.
  session.handlers.get('play')({ action: 'play' });
  clock.advance(5000);
  systemPause(page.window, video);
  assert.equal(video.paused, false);
  assertAll(page);
});

test('player-bridge + background + media-session › PiP pause stays paused and presentation is still posted', async (t) => {
  const { page, win, addVideo, media } = await playerPage(t, { scripts: ALL_D });
  const video = await addVideo({ playing: true });
  await page.cmd('lifecycle', { state: 'background' });
  Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: 'picture-in-picture' });
  video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
  systemPause(win, video);  // the pause button in the PiP window
  assert.equal(media(video).plays, 0);
  assert.deepEqual(page.posted('presentation').map((m) => m.mode), ['pip']);
  assertAll(page);
});

test('player-bridge + background + media-session › native pause in background stays paused', async (t) => {
  const { page, addVideo } = await playerPage(t, { scripts: ALL_D });
  const video = await addVideo({ playing: true });
  await page.cmd('lifecycle', { state: 'background' });
  assert.deepEqual(await page.cmd('pause'), { ok: true });
  await page.flush();
  assert.equal(video.paused, true);
  assertAll(page);
});
