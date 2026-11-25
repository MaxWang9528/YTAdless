// sponsorblock.js (PLAN.md §5.4 `captionTracks`, `suggestedSegments`; §6.5): caption tracks for
// on-device detection, and suggested segments that are prompted, never skipped. Owner: Module D.
// The media fakes don't fire timeupdate/seeked when currentTime is set, so tests dispatch them.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector, commandVectors, fixture } from './harness.mjs';
import { playerPage, playerResponse } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js', 'sponsorblock.js'];
const ID = 'dQw4w9WgXcQ';     // media-fakes WATCH
const OTHER = 'jNQXAC9IVRw';
const TOAST = '#ytadless-sponsorblock-toast';
const MARKERS = '#ytadless-sponsorblock-markers';
const FIXTURE = ['player', '2026-11-24-player-dQw4w9WgXcQ.json'];

async function sbPage(t, options = {}) {
  const env = await playerPage(t, { scripts: SCRIPTS, ...options });
  const video = await env.addVideo({ playing: true, duration: 213 });
  const at = (time, type = 'timeupdate') => {
    video.currentTime = time;
    video.dispatchEvent(new env.win.Event(type));
  };
  const suggest = (segments, videoId = ID) => env.page.cmd('suggestedSegments', { videoId, segments });
  const send = (segments, videoId = ID) => env.page.cmd('sponsorSegments', { videoId, segments });
  const toast = () => env.page.document.querySelector(TOAST);
  const intents = [];
  env.ns.on('userIntent', (i) => intents.push({ ...i }));
  return { ...env, video, at, suggest, send, toast, intents };
}

const GUESS = { start: 61, end: 95, category: 'sponsor' };
const infoLogs = (page, re) => page.posted('log').filter((m) => m.source === 'sponsorblock.js' && re.test(m.message));
const marks = (page) => [...page.document.querySelectorAll(MARKERS + ' > div')];
const tap = (env) => env.toast().querySelector('button').dispatchEvent(new env.win.MouseEvent('click', { bubbles: true }));

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

// A page-realm player response (as hooks.js emits it) with the given caption tracks.
function prWithTracks(win, videoId, tracks) {
  return win.JSON.parse(JSON.stringify({
    ...playerResponse(videoId),
    captions: { playerCaptionsTracklistRenderer: { captionTracks: tracks } },
  }));
}
const track = (lang, extra = {}) => ({
  baseUrl: `/api/timedtext?v=x&lang=${lang}`, languageCode: lang, name: { simpleText: lang.toUpperCase() }, ...extra,
});

// ── captionTracks ────────────────────────────────────────────────────────────────────────────
test('sponsorblock.js › captionTracks commands.json vector › answers the page video with a tracks array', async (t) => {
  const { page } = await sbPage(t);
  const vector = commandVectors().commands.find((c) => c.name === 'captionTracks');
  assert.deepEqual(await page.cmd(vector.name, vector.args), { videoId: ID, tracks: [] });
  assertAll(page);
});

test('sponsorblock.js › captionTracks from a playerResponse fixture › absolute URLs, kind and name normalised', async (t) => {
  const { page, ns, win } = await sbPage(t);
  const raw = JSON.parse(fixture(...FIXTURE));
  const rawTracks = raw.captions.playerCaptionsTracklistRenderer.captionTracks;
  ns.emit('playerResponse', win.JSON.parse(fixture(...FIXTURE)), { source: 'fetch', url: 'https://m.youtube.com/youtubei/v1/player' });
  const result = await page.cmd('captionTracks', {});
  assert.equal(result.videoId, ID);
  assert.equal(result.tracks.length, rawTracks.length);
  result.tracks.forEach((tr, i) => {
    assert.deepEqual(Object.keys(tr).sort(), ['baseUrl', 'kind', 'languageCode', 'name']);
    assert.equal(tr.baseUrl, 'https://m.youtube.com' + rawTracks[i].baseUrl);
    assert.equal(new URL(tr.baseUrl).pathname, '/api/timedtext');
    assert.equal(tr.languageCode, rawTracks[i].languageCode);
    assert.equal(tr.kind, rawTracks[i].kind === 'asr' ? 'asr' : '');
    assert.equal(tr.name, rawTracks[i].name.runs.map((r) => r.text).join(''));
  });
  assert.deepEqual(result.tracks.slice(0, 2).map((tr) => [tr.languageCode, tr.kind, tr.name]),
    [['en', '', 'English'], ['en', 'asr', 'English (auto-generated)']]);
  assertAll(page);
});

test('sponsorblock.js › captionTracks with foreign or non-timedtext URLs › those tracks dropped', async (t) => {
  const { page, ns, win } = await sbPage(t);
  ns.emit('playerResponse', prWithTracks(win, ID, [
    track('en', { kind: 'asr' }),
    track('a', { baseUrl: '//evil.example/api/timedtext?v=x' }),
    track('b', { baseUrl: 'https://evil.example/api/timedtext?v=x' }),
    track('c', { baseUrl: 'http://m.youtube.com/api/timedtext?v=x' }),
    track('d', { baseUrl: 'https://music.youtube.com/api/timedtext?v=x' }),
    track('e', { baseUrl: 'https://m.youtube.com:8443/api/timedtext?v=x' }),
    track('f', { baseUrl: '/watch?v=x' }),
    track('g', { baseUrl: 'javascript:alert(1)' }),
    track('h', { baseUrl: 42 }),
    track('i', { baseUrl: undefined }),
    track('www', { baseUrl: 'https://www.youtube.com/api/timedtext?v=x&lang=www', kind: 'forced', name: 7 }),
    null, 'x',
  ]), { source: 'xhr', url: 'x' });
  const { tracks } = await page.cmd('captionTracks', {});
  assert.deepEqual(tracks, [
    { baseUrl: 'https://m.youtube.com/api/timedtext?v=x&lang=en', languageCode: 'en', kind: 'asr', name: 'EN' },
    { baseUrl: 'https://www.youtube.com/api/timedtext?v=x&lang=www', languageCode: 'www', kind: '', name: '' },
  ]);
  assertAll(page);
});

test('sponsorblock.js › captionTracks per-video cache › each video answers with its own tracks', async (t) => {
  const { page, ns, win } = await sbPage(t);
  ns.emit('playerResponse', prWithTracks(win, ID, [track('en')]), { source: 'initial', url: 'x' });
  ns.emit('playerResponse', prWithTracks(win, OTHER, [track('de'), track('fr')]), { source: 'fetch', url: 'x' });
  assert.deepEqual((await page.cmd('captionTracks', {})).tracks.map((tr) => tr.languageCode), ['en']);
  win.history.pushState({}, '', '/watch?v=' + OTHER);
  assert.deepEqual(await page.cmd('captionTracks', {}).then((r) => [r.videoId, r.tracks.map((tr) => tr.languageCode)]),
    [OTHER, ['de', 'fr']]);
  win.history.pushState({}, '', '/watch?v=' + ID);
  assert.deepEqual((await page.cmd('captionTracks', {})).tracks.map((tr) => tr.languageCode), ['en']);
  assertAll(page);
});

test('sponsorblock.js › captionTracks after a prefetch of the next video › still the current video', async (t) => {
  const { page, ns, win } = await sbPage(t);
  ns.emit('playerResponse', prWithTracks(win, ID, [track('en')]), { source: 'initial', url: 'x' });
  // get_watch / next prefetch of a different video, and a later caption-less response for this one.
  ns.emit('playerResponse', prWithTracks(win, OTHER, [track('ja')]), { source: 'fetch', url: 'x' });
  ns.emit('playerResponse', win.JSON.parse(JSON.stringify(playerResponse(ID))), { source: 'fetch', url: 'x' });
  const result = await page.cmd('captionTracks', {});
  assert.equal(result.videoId, ID);
  assert.deepEqual(result.tracks.map((tr) => tr.languageCode), ['en']);
  assertAll(page);
});

test('sponsorblock.js › captionTracks with no event seen › ytInitialPlayerResponse fallback (this video only)', async (t) => {
  const { page, win } = await sbPage(t);
  win.ytInitialPlayerResponse = prWithTracks(win, OTHER, [track('de')]);
  assert.deepEqual(await page.cmd('captionTracks', {}), { videoId: ID, tracks: [] }, 'another video: not used');
  win.ytInitialPlayerResponse = prWithTracks(win, ID, [{ ...track('en'), name: { runs: [{ text: 'Eng' }, { text: 'lish' }] } }]);
  assert.deepEqual(await page.cmd('captionTracks', {}), {
    videoId: ID,
    tracks: [{ baseUrl: 'https://m.youtube.com/api/timedtext?v=x&lang=en', languageCode: 'en', kind: '', name: 'English' }],
  });
  assertAll(page);
});

test('sponsorblock.js › captionTracks with no captions anywhere › tracks [] and no error', async (t) => {
  const { page, ns, win } = await sbPage(t);
  ns.emit('playerResponse', win.JSON.parse(JSON.stringify(playerResponse(ID))), { source: 'fetch', url: 'x' });
  ns.emit('playerResponse', null, { source: 'fetch', url: 'x' });
  ns.emit('playerResponse', win.JSON.parse('{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":"nope"}}}'), { source: 'fetch', url: 'x' });
  win.ytInitialPlayerResponse = 'garbage';
  assert.deepEqual(await page.cmd('captionTracks', {}), { videoId: ID, tracks: [] });
  win.history.pushState({}, '', '/feed/subscriptions');
  assert.deepEqual(await page.cmd('captionTracks', {}), { videoId: null, tracks: [] });
  assertAll(page);
});

// ── suggestedSegments ────────────────────────────────────────────────────────────────────────
test('sponsorblock.js › suggestedSegments commands.json vector › accepted with its count', async (t) => {
  const { page } = await sbPage(t);
  const vector = commandVectors().commands.find((c) => c.name === 'suggestedSegments');
  assert.deepEqual(await page.cmd(vector.name, vector.args), { ok: true, count: 1 });
  assertAll(page);
});

test('sponsorblock.js › suggestedSegments validation › invalid ones dropped like sponsorSegments', async (t) => {
  const { page, suggest } = await sbPage(t);
  assert.deepEqual(await suggest([
    GUESS,
    { start: 50, end: 40, category: 'sponsor' },
    { start: '1', end: 5, category: 'sponsor' },
    { start: 1, end: null, category: 'sponsor' },
    { start: -1, end: 5, category: 'sponsor' },
    { start: 60, end: 70, category: '' },
    null, 'x',
    { start: 150, end: 160, category: 'selfpromo' },
  ]), { ok: true, count: 2 });
  assert.deepEqual(await page.cmd('suggestedSegments', { videoId: ID, segments: 'nope' }), { ok: true, count: 0 });
  assert.deepEqual(await page.cmd('suggestedSegments', {}), { ok: true, count: 0 });
  assertAll(page);
});

test('sponsorblock.js › suggestedSegments for another video › ignored: count 0, no prompt, no markers', async (t) => {
  const { page, suggest, at, toast } = await sbPage(t);
  assert.deepEqual(await suggest([GUESS], OTHER), { ok: true, count: 0 });
  at(70);
  assert.equal(toast(), null);
  assert.equal(page.document.querySelector(MARKERS), null);
  assertAll(page);
});

test('sponsorblock.js › entering a suggested segment › shows "Possible sponsor" and does NOT seek', async (t) => {
  const { page, suggest, at, video, toast, intents } = await sbPage(t);
  await suggest([GUESS]);
  at(57.9);
  assert.equal(toast(), null, 'more than 3 s before it: no prompt');
  at(58.2);
  assert.ok(toast(), 'prompted 3 s early (CONFIG.PROMPT_LEAD_S)');
  assert.equal(video.currentTime, 58.2);
  at(61.2);
  assert.equal(video.currentTime, 61.2, 'never skipped by itself');
  const box = toast();
  assert.ok(box, 'prompt shown');
  assert.equal(box.dataset.kind, 'suggest');
  assert.equal(box.parentNode, page.document.body, 'fixed on body, over the player');
  assert.match(box.querySelector('span').textContent, /^Possible sponsor$/);
  assert.equal(box.querySelector('button').textContent, 'Skip');
  at(70);
  assert.equal(video.currentTime, 70);
  assert.equal(toast(), box, 'still the same prompt while inside');
  assert.deepEqual(intents, []);
  assert.equal(infoLogs(page, /^suggestion: possible sponsor/).length, 1);
  assert.equal(infoLogs(page, /^skipped /).length, 0);
  assertAll(page);
});

test('sponsorblock.js › Skip on a suggestion › emits userIntent page, seeks to the end, tap not propagated', async (t) => {
  const env = await sbPage(t);
  const { page, suggest, at, video, toast, intents } = env;
  await suggest([GUESS]);
  at(65);
  let bubbled = 0;
  page.document.querySelector('#movie_player').addEventListener('click', () => { bubbled += 1; });
  tap(env);
  assert.equal(video.currentTime, 95);
  assert.deepEqual(intents, [{ action: 'seek', source: 'page' }]);
  assert.equal(bubbled, 0, 'the tap does not reach the player');
  assert.equal(toast(), null, 'prompt hidden');
  assert.equal(infoLogs(page, /^suggestion skipped by tap: sponsor 65\.0 → 95\.0/).length, 1);
  assertAll(page);
});

test('sponsorblock.js › Skip on a suggestion past the video end › clamped to the duration', async (t) => {
  const env = await sbPage(t);
  await env.suggest([{ start: 190, end: 400, category: 'outro' }]);
  env.at(191);
  assert.match(env.toast().textContent, /Possible outro/);
  tap(env);
  assert.equal(env.video.currentTime, 213);
  assertAll(env.page);
});

test('sponsorblock.js › leaving a suggested segment › the prompt hides', async (t) => {
  const { page, suggest, at, toast } = await sbPage(t);
  await suggest([GUESS]);
  at(62);
  assert.ok(toast());
  at(94.9);  // inside END_EPSILON of the end counts as out
  assert.equal(toast(), null);
  at(80, 'seeked');
  assert.equal(toast(), null, 'not again within the same pass');
  assertAll(page);
});

test('sponsorblock.js › suggestion prompt timeout › hides after ~11 s (3 s lead + 8 s) and stays hidden while inside', async (t) => {
  const { page, suggest, at, toast } = await sbPage(t);
  await suggest([GUESS]);
  at(62);
  assert.ok(toast());
  await page.flush(4100);
  assert.ok(toast(), 'longer-lived than the 4 s skip toast');
  await page.flush(4100);
  assert.ok(toast(), 'still there at ~8 s: the 3 s lead is added');
  await page.flush(3100);
  assert.equal(toast(), null);
  at(70);
  assert.equal(toast(), null, 'shown once');
  assertAll(page);
});

test('sponsorblock.js › suggestion prompt › once per load, again after seeking back before its start', async (t) => {
  const { page, suggest, at, toast } = await sbPage(t);
  await suggest([GUESS]);
  at(62);
  at(100);
  assert.equal(toast(), null);
  at(70, 'seeked');  // back into it, but not before its start
  assert.equal(toast(), null, 'not re-prompted');
  // A re-send for the same video keeps that.
  assert.deepEqual(await suggest([GUESS]), { ok: true, count: 1 });
  at(71);
  assert.equal(toast(), null);
  at(50, 'seeked');
  assert.equal(toast(), null);
  at(61, 'timeupdate');
  assert.ok(toast(), 're-armed by seeking back before the start');
  assert.equal(infoLogs(page, /^suggestion: possible/).length, 2);
  assertAll(page);
});

test('sponsorblock.js › suggestion prompt guards › no prompt during an ad, before metadata, or at the very end', async (t) => {
  const { page, suggest, at, video, toast } = await sbPage(t);
  await suggest([GUESS, { start: 212.8, end: 213, category: 'sponsor' }]);
  video.readyState = 0;
  at(62);
  assert.equal(toast(), null);
  video.readyState = 4;
  page.document.querySelector('#movie_player').classList.add('ad-showing');
  at(63);
  assert.equal(toast(), null);
  page.document.querySelector('#movie_player').classList.remove('ad-showing');
  at(64);
  assert.ok(toast());
  at(212.8);
  assert.equal(toast(), null, 'a guess at the very end is not prompted');
  assertAll(page);
});

test('sponsorblock.js › suggested markers › striped, fainter and data-suggested="1"', async (t) => {
  const { page, suggest } = await sbPage(t);
  await suggest([GUESS]);
  const [mark] = marks(page);
  assert.equal(marks(page).length, 1);
  assert.equal(mark.dataset.suggested, '1');
  assert.equal(mark.dataset.category, 'sponsor');
  assert.match(mark.style.background, /repeating-linear-gradient/);
  assert.ok(parseFloat(mark.style.opacity) < 0.85, 'fainter than a real segment');
  assert.equal(mark.style.left, (61 / 213 * 100).toFixed(3) + '%');
  assert.equal(mark.style.width, (34 / 213 * 100).toFixed(3) + '%');
  assertAll(page);
});

test('sponsorblock.js › suggestions with real segments › both drawn; an overlapping guess yields to the real one', async (t) => {
  const { page, suggest, send, at, video, toast } = await sbPage(t);
  await send([{ start: 10, end: 30.5, category: 'sponsor' }]);
  await suggest([{ start: 20, end: 40, category: 'sponsor' }, GUESS]);
  const all = marks(page);
  assert.equal(all.length, 2);
  assert.deepEqual(all.map((m) => [m.dataset.suggested ?? '', m.style.left]),
    [['', (10 / 213 * 100).toFixed(3) + '%'], ['1', (61 / 213 * 100).toFixed(3) + '%']]);
  assert.match(all[0].style.background, /^rgb\(/, 'the real one is solid');
  // Real segment still auto-skips with its own toast; the overlapping guess is never prompted.
  at(11);
  assert.equal(video.currentTime, 30.5);
  assert.equal(toast().dataset.kind, 'skip');
  at(35);
  assert.equal(toast().dataset.kind, 'skip', 'the overlapping guess is not prompted');
  // Empty real segments leave the suggestions in place.
  await send([]);
  assert.deepEqual(marks(page).map((m) => m.dataset.suggested), ['1', '1']);
  assertAll(page);
});

test('sponsorblock.js › skip toast showing when a suggestion is entered › skip toast kept, prompt shown after', async (t) => {
  const { page, suggest, send, at, video, toast } = await sbPage(t);
  await suggest([{ start: 31, end: 60, category: 'sponsor' }]);
  await send([{ start: 10, end: 31, category: 'sponsor' }]);
  at(11);
  assert.equal(video.currentTime, 31);
  at(31.5);
  assert.equal(toast().dataset.kind, 'skip', 'the auto-skip toast takes precedence');
  await page.flush(4100);
  assert.equal(toast(), null);
  at(36);
  assert.equal(toast().dataset.kind, 'suggest', 'prompted once the skip toast is gone');
  assertAll(page);
});

test('sponsorblock.js › an auto-skip while a prompt shows › replaces the prompt', async (t) => {
  const { page, suggest, send, at, toast } = await sbPage(t);
  await suggest([GUESS]);
  at(62);
  assert.equal(toast().dataset.kind, 'suggest');
  await send([{ start: 95, end: 120, category: 'selfpromo' }]);
  at(96);
  assert.equal(toast().dataset.kind, 'skip');
  assert.equal(page.document.querySelectorAll(TOAST).length, 1, 'one toast at a time');
  assertAll(page);
});

test('sponsorblock.js › empty suggestedSegments › clears suggestion markers and the prompt', async (t) => {
  const { page, suggest, send, at, toast } = await sbPage(t);
  await send([{ start: 10, end: 30.5, category: 'sponsor' }]);
  await suggest([GUESS]);
  at(62);
  assert.ok(toast());
  assert.deepEqual(await suggest([]), { ok: true, count: 0 });
  assert.equal(toast(), null);
  assert.deepEqual(marks(page).map((m) => m.dataset.suggested ?? ''), [''], 'real markers remain');
  await send([]);
  assert.equal(page.document.querySelector(MARKERS), null);
  at(70);
  assert.equal(toast(), null);
  assertAll(page);
});

test('sponsorblock.js › page navigated to another video › suggestions no longer apply', async (t) => {
  const { page, suggest, at, toast, win } = await sbPage(t);
  await suggest([GUESS]);
  at(62);
  assert.ok(toast());
  win.history.pushState({}, '', '/watch?v=' + OTHER);
  at(63);
  assert.equal(toast(), null);
  assertAll(page);
});
