// sponsorblock.js (PLAN.md §5.4 `sponsorSegments`, §6.4): validation, skipping, undo. Owner: Module D.
// The media fakes don't fire timeupdate/seeked when currentTime is set, so tests dispatch them.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector, commandVectors } from './harness.mjs';
import { playerPage } from './media-fakes.mjs';

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
  assert.deepEqual(intents, [{ action: 'seek', source: 'native' }]);
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

test('sponsorblock.js › skip › userIntent seek is emitted before currentTime changes', async (t) => {
  const { page, ns, send, at, video } = await sbPage(t);
  await send([SPONSOR]);
  const seen = [];
  ns.on('userIntent', (i) => seen.push({ ...i, currentTime: video.currentTime }));
  at(12);
  assert.deepEqual(seen, [{ action: 'seek', source: 'native', currentTime: 12 }]);
  assert.equal(video.currentTime, 30.5);
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
