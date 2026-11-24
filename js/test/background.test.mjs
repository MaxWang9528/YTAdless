// background.js (PLAN.md §6.4: visibility spoofing, resume policy, interruptions). Owner: Module D.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector, loadManifestScripts, NAMESPACE } from './harness.mjs';
import { playerPage, systemPause, playerResponse } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js'];

async function bgPage(t, options = {}) {
  const env = await playerPage(t, { scripts: SCRIPTS, ...options });
  const video = await env.addVideo({ playing: true });
  return { ...env, video };
}

const logs = (page, re) => page.posted('log').filter((m) => m.source === 'background.js' && re.test(m.message));

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

// ── visibility ────────────────────────────────────────────────────────────────────────────────

test('background.js › hidden page › document looks visible and page listeners never hear about it', async (t) => {
  const { page, win, visibility } = await bgPage(t);
  const doc = page.document;
  let heard = 0;
  doc.addEventListener('visibilitychange', () => { heard += 1; });
  doc.addEventListener('webkitvisibilitychange', () => { heard += 1; });
  win.addEventListener('visibilitychange', () => { heard += 1; }, true);
  doc.onvisibilitychange = () => { heard += 1; };
  visibility.set(true);
  doc.dispatchEvent(new win.Event('webkitvisibilitychange'));
  assert.equal(heard, 0);
  assert.equal(doc.hidden, false);
  assert.equal(doc.visibilityState, 'visible');
  assert.equal(doc.webkitHidden, false);
  assert.equal(doc.webkitVisibilityState, 'visible');
  assert.equal(typeof doc.onvisibilitychange, 'function', 'the handler reads back, but is never called');
  assertAll(page);
});

test('background.js › background › document.hasFocus() is true; window blur is stopped, element blur is not', async (t) => {
  const { page, win } = await bgPage(t);
  await page.cmd('lifecycle', { state: 'background' });
  assert.equal(page.document.hasFocus(), true);
  let windowBlur = 0;
  let inputBlur = 0;
  win.addEventListener('blur', (e) => { if (e.target === win) windowBlur += 1; });
  const input = page.document.createElement('input');
  page.document.body.appendChild(input);
  input.addEventListener('blur', () => { inputBlur += 1; });
  win.dispatchEvent(new win.FocusEvent('blur'));
  input.dispatchEvent(new win.FocusEvent('blur'));
  assert.equal(windowBlur, 0);
  assert.equal(inputBlur, 1);
  assertAll(page);
});

// ── resume policy table ───────────────────────────────────────────────────────────────────────
// Each row: what happens before a pause, what the pause is, and whether background.js resumes it.

const ROWS = [
  { name: 'system pause while lifecycle background', setup: async ({ page }) => page.cmd('lifecycle', { state: 'background' }), resumes: true },
  { name: 'system pause while lifecycle inactive (willResignActive came first, D12)', setup: async ({ page }) => page.cmd('lifecycle', { state: 'inactive' }), resumes: true },
  { name: 'system pause while active and visible (nothing to undo)', setup: async () => {}, resumes: false },
  {
    name: 'remote pause (lock screen) in background',
    setup: async ({ page, ns }) => { await page.cmd('lifecycle', { state: 'background' }); ns.emit('userIntent', { action: 'pause', source: 'remote' }); },
    resumes: false,
  },
  {
    name: 'native pause intent 1.4 s earlier',
    setup: async ({ page, ns, clock }) => { await page.cmd('lifecycle', { state: 'background' }); ns.emit('userIntent', { action: 'pause', source: 'native' }); clock.advance(1400); },
    resumes: false,
  },
  {
    name: 'pause intent 1.6 s earlier is stale',
    setup: async ({ page, ns, clock }) => { await page.cmd('lifecycle', { state: 'background' }); ns.emit('userIntent', { action: 'pause', source: 'remote' }); clock.advance(1600); },
    resumes: true,
  },
  {
    name: 'a play intent never makes a pause intentional',
    setup: async ({ page, ns }) => { await page.cmd('lifecycle', { state: 'background' }); ns.emit('userIntent', { action: 'play', source: 'remote' }); },
    resumes: true,
  },
  {
    name: 'video in PiP',
    setup: async ({ page, video }) => {
      await page.cmd('lifecycle', { state: 'background' });
      Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: 'picture-in-picture' });
    },
    resumes: false,
  },
  {
    name: 'video left PiP 0.5 s earlier (the PiP close X)',
    setup: async ({ page, win, video, clock }) => {
      await page.cmd('lifecycle', { state: 'background' });
      Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: 'picture-in-picture' });
      video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
      video.webkitPresentationMode = 'inline';
      video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
      clock.advance(500);
    },
    resumes: false,
  },
  {
    name: 'video ended',
    setup: async ({ page, video }) => { await page.cmd('lifecycle', { state: 'background' }); video.ended = true; },
    resumes: false,
  },
  {
    name: 'audio interruption active',
    setup: async ({ page }) => { await page.cmd('lifecycle', { state: 'inactive' }); await page.cmd('audioInterruption', { phase: 'began', shouldResume: false }); },
    resumes: false,
  },
];

for (const row of ROWS) {
  test(`background.js › resume policy › ${row.name} → ${row.resumes ? 'resumed' : 'stays paused'}`, async (t) => {
    const env = await bgPage(t);
    await row.setup(env);
    const plays = env.media(env.video).plays;
    systemPause(env.win, env.video);
    await env.page.flush();
    assert.equal(env.media(env.video).plays - plays, row.resumes ? 1 : 0, 'plays');
    assert.equal(env.video.paused, !row.resumes, 'paused');
    assertAll(env.page);
  });
}

test('background.js › YouTube gating › a page pause() without a gesture in background is reversed', async (t) => {
  const { page, video, media } = await bgPage(t);
  await page.cmd('lifecycle', { state: 'background' });
  video.pause();  // YouTube's own call, no user activation
  await page.flush();
  assert.equal(video.paused, false);
  assert.equal(media(video).plays, 1);
  assert.equal(logs(page, /resuming a system pause/).length, 1);
  assertAll(page);
});

test('background.js › page tap › a page pause() during user activation emits userIntent{page} and is kept', async (t) => {
  const { page, ns, video, activation, visibility } = await bgPage(t);
  const intents = [];
  ns.on('userIntent', (i) => intents.push({ ...i }));
  activation.isActive = true;
  video.pause();          // YouTube's pause button handler
  activation.isActive = false;
  visibility.set(true);   // and then the user locks the phone
  await page.cmd('lifecycle', { state: 'background' });
  await page.flush();
  assert.deepEqual(intents, [{ action: 'pause', source: 'page' }]);
  assert.equal(video.paused, true);
  assertAll(page);
});

// ── the 2 s window before the real visibilitychange (F9) ────────────────────────────────────

test('background.js › pending pause › real visibilitychange to hidden within 2 s resumes it', async (t) => {
  const { page, win, video, media, clock, visibility } = await bgPage(t);
  systemPause(win, video);
  assert.equal(media(video).plays, 0, 'not resumed while visible and active');
  clock.advance(1500);
  visibility.set(true);
  await page.flush();
  assert.equal(media(video).plays, 1);
  assert.equal(video.paused, false);
  assertAll(page);
});

test('background.js › pending pause › lifecycle inactive within 2 s resumes it', async (t) => {
  const { page, win, video, media, clock } = await bgPage(t);
  systemPause(win, video);
  clock.advance(800);
  await page.cmd('lifecycle', { state: 'inactive' });
  assert.equal(media(video).plays, 1);
  assertAll(page);
});

test('background.js › pending pause › after 2 s it stays paused', async (t) => {
  const { page, win, video, media, clock, visibility } = await bgPage(t);
  systemPause(win, video);
  clock.advance(2100);
  visibility.set(true);
  await page.cmd('lifecycle', { state: 'background' });
  assert.equal(media(video).plays, 0);
  assert.equal(video.paused, true);
  assertAll(page);
});

test('background.js › pending pause › an intent after the pause cancels it', async (t) => {
  const { page, ns, win, video, media, visibility } = await bgPage(t);
  systemPause(win, video);
  ns.emit('userIntent', { action: 'pause', source: 'native' });
  visibility.set(true);
  assert.equal(media(video).plays, 0);
  assertAll(page);
});

// ── cap ──────────────────────────────────────────────────────────────────────────────────────

test('background.js › cap › at most 3 auto-resumes per 30 s, then it logs and gives up', async (t) => {
  const { page, win, video, media, clock } = await bgPage(t);
  await page.cmd('lifecycle', { state: 'background' });
  for (let i = 0; i < 5; i += 1) {
    systemPause(win, video);
    clock.advance(2000);
  }
  await page.flush();
  assert.equal(media(video).plays, 3);
  assert.equal(video.paused, true);
  assert.equal(logs(page, /cap reached/).length, 1, 'logged once');
  assert.equal(page.posted('log').find((m) => /cap reached/.test(m.message)).level, 'warn');
  clock.advance(30_000);
  systemPause(win, video);
  assert.equal(media(video).plays, 4, 'a new window allows resuming again');
  assertAll(page);
});

test('background.js › refused play() › is logged, never a scriptError', async (t) => {
  const { page, win, video, media } = await bgPage(t);
  await page.cmd('lifecycle', { state: 'background' });
  media(video).refusePlay = true;
  systemPause(win, video);
  await page.flush();
  assert.equal(logs(page, /resume was refused/).length, 1);
  assertAll(page);
});

// ── audio interruptions ─────────────────────────────────────────────────────────────────────

test('background.js › interruption › ended with shouldResume resumes a video that was playing', async (t) => {
  const { page, win, video, media } = await bgPage(t);
  assert.deepEqual(await page.cmd('audioInterruption', { phase: 'began', shouldResume: false }), { ok: true });
  systemPause(win, video);
  assert.equal(media(video).plays, 0);
  assert.deepEqual(await page.cmd('audioInterruption', { phase: 'ended', shouldResume: true }), { ok: true, resumed: true });
  assert.equal(video.paused, false);
  assertAll(page);
});

test('background.js › interruption › ended without shouldResume stays paused', async (t) => {
  const { page, win, video } = await bgPage(t);
  await page.cmd('audioInterruption', { phase: 'began', shouldResume: false });
  systemPause(win, video);
  assert.deepEqual(await page.cmd('audioInterruption', { phase: 'ended', shouldResume: false }), { ok: true, resumed: false });
  assert.equal(video.paused, true);
  assertAll(page);
});

test('background.js › interruption › a video the user had paused is not resumed by shouldResume', async (t) => {
  const { page, video } = await bgPage(t);
  await page.cmd('pause');
  await page.cmd('audioInterruption', { phase: 'began', shouldResume: false });
  assert.deepEqual(await page.cmd('audioInterruption', { phase: 'ended', shouldResume: true }), { ok: true, resumed: false });
  assert.equal(video.paused, true);
  assertAll(page);
});

test('background.js › interruption › began right after an auto-resume (call while inactive) pauses again', async (t) => {
  const { page, win, video, media, clock } = await bgPage(t);
  await page.cmd('lifecycle', { state: 'inactive' });
  systemPause(win, video);  // WebKit pauses for the call before `began` reaches JS
  assert.equal(video.paused, false, 'auto-resumed');
  clock.advance(500);
  await page.cmd('audioInterruption', { phase: 'began', shouldResume: false });
  assert.equal(video.paused, true, 'undone');
  assert.equal(media(video).plays, 1);
  assert.deepEqual(await page.cmd('audioInterruption', { phase: 'ended', shouldResume: true }), { ok: true, resumed: true });
  assertAll(page);
});

test('background.js › commands › bad lifecycle state or phase is an error, not a throw into the page', async (t) => {
  const { page } = await bgPage(t);
  assert.match((await page.cmd('lifecycle', { state: 'asleep' })).error, /unknown state/);
  assert.match((await page.cmd('audioInterruption', { phase: 'maybe' })).error, /unknown phase/);
  assert.deepEqual(await page.cmd('lifecycle', { state: 'active' }), { ok: true });
  assert.equal(page.pageErrors.length, 0);
});

// ── presentation events, keep-alive, youThere ──────────────────────────────────────────────

test('background.js › webkitpresentationmodechanged › YouTube never sees it; player-bridge.js still posts presentation', async (t) => {
  const { page, win, video } = await bgPage(t);
  let youtube = 0;
  video.addEventListener('webkitpresentationmodechanged', () => { youtube += 1; });
  win.addEventListener('webkitpresentationmodechanged', () => { youtube += 1; }, true);
  Object.defineProperty(video, 'webkitPresentationMode', { configurable: true, writable: true, value: 'picture-in-picture' });
  video.dispatchEvent(new win.Event('webkitpresentationmodechanged'));
  assert.equal(youtube, 0);
  assert.deepEqual(page.posted('presentation').map((m) => m.mode), ['pip']);
  assertAll(page);
});

test('background.js › keep-alive › _lact is refreshed every 5 min and the player gets a mousemove every 10 min', async (t) => {
  const intervals = [];
  const { createPage } = await import('./harness.mjs');
  const page = await createPage({
    role: 'player',
    url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    scripts: ['background.js'],
    html: '<html><body><div id="movie_player"></div></body></html>',
    beforeScripts: (win) => {
      win.setInterval = (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; };
      win.Date.now = () => 42;
    },
  });
  t.after(() => page.close());
  const win = page.window;
  win._lact = 1;
  let moves = 0;
  page.document.getElementById('movie_player').addEventListener('mousemove', () => { moves += 1; });
  const lact = intervals.find((i) => i.ms === 5 * 60 * 1000);
  const activity = intervals.find((i) => i.ms === 10 * 60 * 1000);
  assert.ok(lact && activity, 'both intervals registered');
  lact.fn();
  assert.equal(win._lact, 42);
  activity.fn();
  assert.equal(moves, 1);
  assertClean(page);
});

test('background.js › youThereRenderer › pruned from playerResponse events', async (t) => {
  const { page, ns } = await bgPage(t);
  const pr = playerResponse('dQw4w9WgXcQ');
  pr.messages = [{ youThereRenderer: { text: 'Still watching?' } }, { mealbarPromoRenderer: {} }];
  pr.overlay = { youThereRenderer: {} };
  ns.emit('playerResponse', pr, { source: 'fetch', url: 'x' });
  assert.deepEqual(pr.messages, [{ mealbarPromoRenderer: {} }]);
  assert.deepEqual(pr.overlay, {});
  assertAll(page);
});

test('background.js › youThereRenderer › registered through hooks.addPruner when hooks.js provides it', async (t) => {
  const { createPage } = await import('./harness.mjs');
  const page = await createPage({ role: 'player', scripts: 'none', url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ' });
  t.after(() => page.close());
  loadManifestScripts(page, { only: ['bridge.js'] });
  const pruners = [];
  page.window[NAMESPACE].hooks = { addPruner: (p) => pruners.push(p), originals: [] };
  loadManifestScripts(page, { only: ['background.js'] });
  assert.equal(pruners.length, 1);
  assert.equal(pruners[0].name, 'youThereRenderer');
  const json = { contents: [{ youThereRenderer: {} }, { videoPrimaryInfoRenderer: {} }] };
  assert.equal(pruners[0].fn(json), 1, 'returns the number removed (hooks.js contract)');
  assert.deepEqual(json, { contents: [{ videoPrimaryInfoRenderer: {} }] });
  assertClean(page);
});
