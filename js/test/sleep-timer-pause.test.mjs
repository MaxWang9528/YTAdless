// The sleep timer's pause (SleepTimerController sends the native `pause` command) must stick
// while the app is backgrounded or locked: player-bridge.js emits userIntent{native} before it
// pauses, so background.js's resume policy (D12) keeps it. Owner: Module D (PLAN.md §6.4).

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector } from './harness.mjs';
import { playerPage } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js', 'media-session.js'];

async function playing(t) {
  const env = await playerPage(t, { scripts: SCRIPTS });
  const video = await env.addVideo({ playing: true });
  return { ...env, video };
}

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

const resumeLogs = (page) => page.posted('log').filter((m) => m.source === 'background.js' && /resum/.test(m.message));

for (const lifecycle of ['background', 'inactive']) {
  test(`background.js › native pause while lifecycle ${lifecycle} › is kept, not resumed`, async (t) => {
    const { page, ns, video, media } = await playing(t);
    const intents = [];
    ns.on('userIntent', (i) => intents.push({ ...i }));
    await page.cmd('lifecycle', { state: lifecycle });
    const plays = media(video).plays;

    assert.deepEqual(await page.cmd('pause'), { ok: true });
    await page.flush();

    assert.deepEqual(intents, [{ action: 'pause', source: 'native' }]);
    assert.equal(video.paused, true);
    assert.equal(media(video).plays, plays, 'no auto-resume');
    assert.equal(resumeLogs(page).length, 0);
    assertAll(page);
  });
}

test('background.js › native pause while locked › stays paused through later lifecycle and visibility changes', async (t) => {
  const { page, video, media, clock, visibility } = await playing(t);
  await page.cmd('lifecycle', { state: 'inactive' });
  await page.cmd('lifecycle', { state: 'background' });
  visibility.set(true);
  const plays = media(video).plays;

  await page.cmd('pause');
  await page.flush();

  // Long after the 1.5 s intent window: the phone stays locked, then the user unlocks it.
  clock.advance(10 * 60 * 1000);
  await page.cmd('lifecycle', { state: 'background' });
  await page.cmd('lifecycle', { state: 'inactive' });
  visibility.set(false);
  await page.cmd('lifecycle', { state: 'active' });
  await page.flush();

  assert.equal(video.paused, true);
  assert.equal(media(video).plays, plays, 'never resumed');
  assert.equal(resumeLogs(page).length, 0);
  assertAll(page);
});

test('background.js › native pause just before locking › the following visibilitychange does not resume it', async (t) => {
  const { page, video, media, clock, visibility } = await playing(t);
  const plays = media(video).plays;
  await page.cmd('pause');            // the timer fires while the app is still active
  clock.advance(500);
  await page.cmd('lifecycle', { state: 'inactive' });
  visibility.set(true);               // the real visibilitychange (F9) within the 2 s window
  await page.cmd('lifecycle', { state: 'background' });
  await page.flush();
  assert.equal(video.paused, true);
  assert.equal(media(video).plays, plays);
  assert.equal(resumeLogs(page).length, 0);
  assertAll(page);
});

test('background.js › native pause, then an audio interruption with shouldResume › stays paused', async (t) => {
  const { page, video, media, clock } = await playing(t);
  await page.cmd('lifecycle', { state: 'background' });
  const plays = media(video).plays;
  await page.cmd('pause');
  clock.advance(60 * 1000);
  await page.cmd('audioInterruption', { phase: 'began', shouldResume: false });
  const result = await page.cmd('audioInterruption', { phase: 'ended', shouldResume: true });
  assert.equal(result.resumed, false);
  assert.equal(video.paused, true);
  assert.equal(media(video).plays, plays, 'never resumed');
  assertAll(page);
});
