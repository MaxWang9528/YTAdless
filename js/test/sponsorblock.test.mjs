// sponsorblock.js (PLAN.md §5.4 `sponsorSegments`, §6.4): validation, skipping, undo. Owner: Module D.
// The media fakes don't fire timeupdate/seeked when currentTime is set, so tests dispatch them.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector, commandVectors } from './harness.mjs';
import { playerPage, systemPause } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js', 'sponsorblock.js'];
const ID = 'dQw4w9WgXcQ';  // media-fakes WATCH
const TOAST = '#ytadless-sponsorblock-toast';

async function sbPage(t, options = {}) {
  const env = await playerPage(t, { scripts: SCRIPTS, ...options });
  const video = await env.addVideo({ playing: true, duration: 213 });
  const at = (time, type = 'timeupdate') => {
    video.currentTime = time;
    video.dispatchEvent(new env.win.Event(type));
  };
  const send = (segments, videoId = ID) => env.page.cmd('sponsorSegments', { videoId, segments });
  return { ...env, video, at, send };
}

const SPONSOR = { start: 10, end: 30.5, category: 'sponsor' };
const skips = (page) => page.posted('log').filter((m) => m.source === 'sponsorblock.js' && /^skipped /.test(m.message));

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

test('sponsorblock.js › commands.json vector › accepted with its count', async (t) => {
  const { page } = await sbPage(t);
  const vector = commandVectors().commands.find((c) => c.name === 'sponsorSegments');
  assert.deepEqual(await page.cmd(vector.name, vector.args), { ok: true, count: 1 });
  assertAll(page);
});

test('sponsorblock.js › invalid segments › dropped one by one, never a scriptError', async (t) => {
  const { page, send } = await sbPage(t);
  const result = await send([
    SPONSOR,
    { start: 50, end: 40, category: 'sponsor' },        // inverted
    { start: '1', end: 5, category: 'sponsor' },         // string number
    { start: 1, end: Infinity, category: 'sponsor' },    // JSON can't say Infinity; null does
    { start: 1, end: null, category: 'sponsor' },
    { start: -1, end: 5, category: 'sponsor' },
    { start: 60, end: 70, category: 7 },
    { start: 60, end: 70, category: '' },
    null, 'x', 42,
    { start: 80, end: 90, category: 'selfpromo' },
  ]);
  assert.deepEqual(result, { ok: true, count: 2 });
  assert.deepEqual(await page.cmd('sponsorSegments', { videoId: ID, segments: 'nope' }), { ok: true, count: 0 });
  assert.deepEqual(await page.cmd('sponsorSegments', {}), { ok: true, count: 0 });
  assertAll(page);
});

test('sponsorblock.js › segments for another video › ignored, nothing skipped', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  assert.deepEqual(await send([SPONSOR], 'jNQXAC9IVRw'), { ok: true, count: 0 });
  at(12);
  assert.equal(video.currentTime, 12);
  assert.equal(skips(page).length, 0);
  assertAll(page);
});

test('sponsorblock.js › entering a segment › seeks to its end, logs, shows a toast', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  at(9.5);
  assert.equal(video.currentTime, 9.5, 'before the segment: untouched');
  at(10.2);
  assert.equal(video.currentTime, 30.5);
  assert.equal(skips(page).length, 1);
  const toast = page.document.querySelector(TOAST);
  assert.ok(toast, 'toast shown');
  assert.equal(page.document.querySelector('#movie_player').contains(toast), true, 'over the player');
  assert.match(toast.textContent, /Skipped sponsor/);
  assertAll(page);
});

test('sponsorblock.js › outside segments, at their very end, or past them › no skip', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR, { start: 100, end: 120, category: 'intro' }]);
  for (const time of [0, 5, 30.3, 31, 99.9, 150]) {
    at(time);
    assert.equal(video.currentTime, time, `t=${time}`);
  }
  assert.equal(skips(page).length, 0);
  assertAll(page);
});

test('sponsorblock.js › seeking back into a skipped segment › plays it (skip once per load)', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  at(11);
  assert.equal(video.currentTime, 30.5);
  at(15, 'seeked');
  assert.equal(video.currentTime, 15);
  at(16);
  assert.equal(video.currentTime, 16);
  // A re-send for the same video (second videoMeta, settings change) keeps that.
  assert.deepEqual(await send([SPONSOR]), { ok: true, count: 1 });
  at(17);
  assert.equal(video.currentTime, 17);
  assert.equal(skips(page).length, 1);
  assertAll(page);
});

test('sponsorblock.js › Undo › seeks back to the start and the segment stays un-skipped', async (t) => {
  const { page, send, at, video, win } = await sbPage(t);
  await send([SPONSOR]);
  at(10);
  assert.equal(video.currentTime, 30.5);
  const intents = [];
  page.window.__ytadless.on('userIntent', (i) => intents.push({ ...i }));
  let bubbled = 0;
  page.document.querySelector('#movie_player').addEventListener('click', () => { bubbled += 1; });
  page.document.querySelector(TOAST + ' button').dispatchEvent(new win.MouseEvent('click', { bubbles: true }));
  assert.equal(video.currentTime, 10);
  assert.deepEqual(intents, [{ action: 'seek', source: 'page' }]);
  assert.equal(bubbled, 0, 'the tap does not reach the player');
  assert.equal(page.document.querySelector(TOAST), null, 'toast hidden');
  at(10.3);
  at(20);
  assert.equal(video.currentTime, 20);
  assertAll(page);
});

test('sponsorblock.js › toast › hides by itself after ~4 s', async (t) => {
  const { page, send, at } = await sbPage(t);
  await send([SPONSOR]);
  at(10);
  assert.ok(page.document.querySelector(TOAST));
  await page.flush(4100);
  assert.equal(page.document.querySelector(TOAST), null);
  assertAll(page);
});

test('sponsorblock.js › skip › an automatic skip emits no userIntent', async (t) => {
  const { page, ns, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  const seen = [];
  ns.on('userIntent', (i) => seen.push({ ...i }));
  at(12);
  assert.deepEqual(seen, []);
  assert.equal(video.currentTime, 30.5);
  assertAll(page);
});

test('sponsorblock.js › skip while locked, then a system pause › background.js still resumes it (D12)', async (t) => {
  const { page, send, at, video, media, win } = await sbPage(t);
  await page.cmd('lifecycle', { state: 'background' });
  await send([SPONSOR]);
  at(12);
  assert.equal(video.currentTime, 30.5);
  const plays = media(video).plays;
  systemPause(win, video);
  await page.flush();
  assert.ok(media(video).plays > plays, 'the system pause right after a skip is resumed');
  assertAll(page);
});

test('sponsorblock.js › already inside a segment when the command arrives › skips at once', async (t) => {
  const { page, send, video } = await sbPage(t);
  video.currentTime = 0;
  await send([{ start: 0, end: 8, category: 'intro' }]);
  assert.equal(video.currentTime, 8);
  assert.match(page.document.querySelector(TOAST).textContent, /Skipped intro/);
  assertAll(page);
});

test('sponsorblock.js › segment to the end of the video › clamped to duration; one starting at the end is left alone', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([{ start: 200, end: 400, category: 'outro' }, { start: 212.8, end: 213, category: 'sponsor' }]);
  at(201);
  assert.equal(video.currentTime, 213);
  at(212.8);
  assert.equal(video.currentTime, 212.8);
  assertAll(page);
});

test('sponsorblock.js › no metadata yet, or an ad showing › no skip', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  video.readyState = 0;
  at(12);
  assert.equal(video.currentTime, 12);
  video.readyState = 4;
  page.document.querySelector('#movie_player').classList.add('ad-showing');
  at(13);
  assert.equal(video.currentTime, 13);
  page.document.querySelector('#movie_player').classList.remove('ad-showing');
  at(14);
  assert.equal(video.currentTime, 30.5);
  assertAll(page);
});

test('sponsorblock.js › video re-attached › the new element is watched', async (t) => {
  const { page, send, win, addVideo, video: first } = await sbPage(t);
  await send([SPONSOR]);
  first.remove();
  const second = await addVideo({ playing: true, duration: 213 });
  second.currentTime = 11;
  second.dispatchEvent(new win.Event('timeupdate'));
  assert.equal(second.currentTime, 30.5);
  assertAll(page);
});

test('sponsorblock.js › video added only after the command (no videoElement replay needed) › still skips', async (t) => {
  const env = await playerPage(t, { scripts: SCRIPTS });
  assert.deepEqual(await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SPONSOR] }), { ok: true, count: 1 });
  const video = await env.addVideo({ playing: true });
  video.currentTime = 20;
  video.dispatchEvent(new env.win.Event('playing'));
  assert.equal(video.currentTime, 30.5);
  assertAll(env.page);
});

test('sponsorblock.js › page navigated to another video › old segments no longer apply', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  page.window.history.pushState({}, '', '/watch?v=jNQXAC9IVRw');
  at(12);
  assert.equal(video.currentTime, 12);
  assertAll(page);
});

test('sponsorblock.js › empty segments (SponsorBlock turned off) › nothing skipped', async (t) => {
  const { page, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  assert.deepEqual(await send([]), { ok: true, count: 0 });
  at(12);
  assert.equal(video.currentTime, 12);
  assertAll(page);
});

// ── markers (what will be skipped) ───────────────────────────────────────────────────────────
const MARKERS = '#ytadless-sponsorblock-markers';
const BAR_CLASS = 'ytProgressBarLineProgressBarLine';
const marks = (page) => [...page.document.querySelectorAll(MARKERS + ' > div')];

test('sponsorblock.js › markers › no seek bar → a strip along the player bottom, one span per segment', async (t) => {
  const { page, send } = await sbPage(t);
  await send([SPONSOR, { start: 100, end: 120, category: 'intro' }]);
  const box = page.document.querySelector(MARKERS);
  assert.ok(box, 'markers drawn');
  assert.equal(box.parentNode.id, 'movie_player');
  assert.equal(box.style.bottom, '0px');
  assert.equal(box.style.pointerEvents, 'none');
  const [a, b] = marks(page);
  assert.equal(marks(page).length, 2);
  assert.equal(a.dataset.category, 'sponsor');
  assert.equal(a.style.left, (10 / 213 * 100).toFixed(3) + '%');
  assert.equal(a.style.width, (20.5 / 213 * 100).toFixed(3) + '%');
  assert.equal(b.dataset.category, 'intro');
  assert.notEqual(a.style.background, b.style.background, 'categories have their own colours');
  assert.equal(page.posted('log').filter((m) => m.source === 'sponsorblock.js' && /markers on fallback strip/.test(m.message)).length, 1);
  assertAll(page);
});

test('sponsorblock.js › markers › YouTube seek bar present → drawn inside it', async (t) => {
  const { page, send } = await sbPage(t);
  const bar = page.document.createElement('div');
  bar.className = BAR_CLASS;
  page.document.querySelector('#movie_player').appendChild(bar);
  await send([SPONSOR]);
  const box = page.document.querySelector(MARKERS);
  assert.equal(box.parentNode, bar);
  assert.equal(bar.style.position, 'relative', 'a static host is positioned');
  assert.equal(marks(page).length, 1);
  assert.ok(page.posted('log').some((m) => m.source === 'sponsorblock.js' && m.message.includes('seek bar #movie_player .' + BAR_CLASS)));
  assertAll(page);
});

test('sponsorblock.js › markers › seek bar rendered later → markers move to it on the next check', async (t) => {
  const { page, send, at, clock } = await sbPage(t);
  await send([SPONSOR]);
  assert.equal(page.document.querySelector(MARKERS).parentNode.id, 'movie_player');
  const bar = page.document.createElement('div');
  bar.className = BAR_CLASS;
  page.document.querySelector('#movie_player').appendChild(bar);
  clock.advance(1100);
  at(1);
  assert.equal(page.document.querySelector(MARKERS).parentNode, bar);
  assert.equal(page.document.querySelectorAll(MARKERS).length, 1, 'never two marker sets');
  assertAll(page);
});

test('sponsorblock.js › markers › YouTube re-renders its controls → markers re-attached', async (t) => {
  const { page, send, at, clock } = await sbPage(t);
  const player = page.document.querySelector('#movie_player');
  let bar = page.document.createElement('div');
  bar.className = BAR_CLASS;
  player.appendChild(bar);
  await send([SPONSOR]);
  bar.remove();
  bar = page.document.createElement('div');
  bar.className = BAR_CLASS;
  player.appendChild(bar);
  clock.advance(1100);
  at(1);
  assert.equal(page.document.querySelector(MARKERS).parentNode, bar);
  assertAll(page);
});

test('sponsorblock.js › markers › empty segments or another video → removed', async (t) => {
  const { page, send } = await sbPage(t);
  await send([SPONSOR]);
  assert.ok(page.document.querySelector(MARKERS));
  await send([]);
  assert.equal(page.document.querySelector(MARKERS), null);
  assertAll(page);
});

test('sponsorblock.js › markers › unknown duration → nothing drawn until durationchange', async (t) => {
  const { page, send, video, win } = await sbPage(t);
  video.duration = NaN;
  await send([SPONSOR]);
  assert.equal(page.document.querySelector(MARKERS), null);
  video.duration = 100;
  video.dispatchEvent(new win.Event('durationchange'));
  assert.equal(parseFloat(marks(page)[0].style.left), 10);
  assertAll(page);
});

// ── markers: seek bar found by shape (device 2026-11-25: no class selector matched) ─────────────
function rect(el, { left, top, width, height }) {
  el.getBoundingClientRect = () => ({ left, top, width, height, right: left + width, bottom: top + height, x: left, y: top });
}

function shapedPlayer(page) {
  const doc = page.document;
  const player = doc.querySelector('#movie_player');
  rect(player, { left: 0, top: 0, width: 400, height: 225 });
  // A slider hit area (tall) around the visible line (thin, inset 12 px each side), with a
  // played portion inside it — like mweb's bar, under class names none of the selectors know.
  const slider = doc.createElement('div');
  slider.setAttribute('role', 'slider');
  slider.className = 'ytmNewScrubberHitArea';
  rect(slider, { left: 0, top: 190, width: 400, height: 30 });
  const line = doc.createElement('div');
  line.className = 'ytmNewProgressLine track';
  rect(line, { left: 12, top: 203, width: 376, height: 4 });
  const played = doc.createElement('div');
  played.className = 'ytmNewProgressPlayed';
  rect(played, { left: 12, top: 203, width: 150, height: 4 });
  line.appendChild(played);
  slider.appendChild(line);
  player.appendChild(slider);
  return { player, slider, line };
}

test('sponsorblock.js › markers › unknown seek-bar classes → the thin, wide track line is found by shape', async (t) => {
  const { page, send } = await sbPage(t);
  const { line } = shapedPlayer(page);
  await send([SPONSOR]);
  const box = page.document.querySelector(MARKERS);
  assert.equal(box.parentNode, line, 'inside the visible line, not the slider hit area or the played part');
  assert.equal(box.style.top, '0px');
  const log = page.posted('log').find((m) => m.source === 'sponsorblock.js' && /^markers on /.test(m.message));
  assert.match(log.message, /seek bar shape div\.ytmNewProgressLine\.track/);
  assertAll(page);
});

test('sponsorblock.js › markers › bar hidden later → the strip keeps the bar\'s insets', async (t) => {
  const { page, send, at, clock } = await sbPage(t);
  const { slider } = shapedPlayer(page);
  await send([SPONSOR]);
  slider.remove();  // controls hidden
  clock.advance(1100);
  at(1);
  const box = page.document.querySelector(MARKERS);
  assert.equal(box.parentNode.id, 'movie_player');
  assert.equal(parseFloat(box.style.left), 3);   // 12 / 400
  assert.equal(parseFloat(box.style.right), 3);
  assert.equal(box.style.bottom, '0px');
  assert.ok(page.posted('log').some((m) => m.source === 'sponsorblock.js' && /fallback strip \(aligned to the last seek bar\)/.test(m.message)));
  assertAll(page);
});

test('sponsorblock.js › markers › nothing bar-shaped (too narrow or too tall) → full-width strip', async (t) => {
  const { page, send } = await sbPage(t);
  const doc = page.document;
  const player = doc.querySelector('#movie_player');
  rect(player, { left: 0, top: 0, width: 400, height: 225 });
  const narrow = doc.createElement('div');
  narrow.className = 'progress-chip';
  rect(narrow, { left: 0, top: 0, width: 80, height: 4 });
  const tall = doc.createElement('div');
  tall.setAttribute('role', 'slider');
  rect(tall, { left: 0, top: 0, width: 400, height: 120 });
  player.append(narrow, tall);
  await send([SPONSOR]);
  const box = page.document.querySelector(MARKERS);
  assert.equal(box.parentNode, player);
  assert.equal(box.style.left, '0px');
  assert.equal(box.style.right, '0px');
  assertAll(page);
});
