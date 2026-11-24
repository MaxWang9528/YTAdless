// Cross-module checks: real scripts from different modules, loaded together in manifest order
// (PLAN.md §8 Phase 2). Owner: integration.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean } from './harness.mjs';

const API = 'https://m.youtube.com/youtubei/v1/';

test('integration › background.js + hooks.js › youThereRenderer pruned from a fetch, one filterHit with a count', async (t) => {
  const url = API + 'next?prettyPrint=false';
  const page = await createPage({
    role: 'player',
    url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    routes: [{ match: url, status: 200, headers: { 'content-type': 'application/json' },
      body: { contents: [{ youThereRenderer: { text: 'Still watching?' } }, { videoPrimaryInfoRenderer: {} }] } }],
  });
  t.after(() => page.close());
  const res = await page.window.fetch(url, { method: 'POST', body: '{}' });
  assert.deepEqual(JSON.parse(await res.text()), { contents: [{ videoPrimaryInfoRenderer: {} }] });
  const hits = page.posted('filterHit').filter((m) => m.rule === 'youThereRenderer');
  assert.deepEqual(hits.map((m) => m.count), [1]);
  for (const m of page.posted('filterHit')) assert.equal(typeof m.count, 'number', `filterHit ${m.rule}: count is a number`);
  assertClean(page);
});

test('integration › background.js + hooks.js › an unrelated response posts no youThereRenderer hit', async (t) => {
  const url = API + 'browse?prettyPrint=false';
  const page = await createPage({
    role: 'player',
    url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    routes: [{ match: url, status: 200, headers: { 'content-type': 'application/json' }, body: { contents: [{ videoPrimaryInfoRenderer: {} }] } }],
  });
  t.after(() => page.close());
  await (await page.window.fetch(url, { method: 'POST', body: '{}' })).text();
  assert.equal(page.posted('filterHit').filter((m) => m.rule === 'youThereRenderer').length, 0);
  assertClean(page);
});

test('integration › hooks.js + debug.js + ad-fixtures loader › an inline player response with ads is captured pre-prune and replays as a player case', async (t) => {
  const { casesFromCaptureData, runCase, remainingKnownAdKeys } = await import('./ad-fixtures.mjs');
  const page = await createPage({ role: 'player', url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ' });
  t.after(() => page.close());
  const response = { adPlacements: [{ adPlacementRenderer: {} }], playerAds: [{}], videoDetails: { videoId: 'dQw4w9WgXcQ' } };
  page.runInline(`var ytInitialPlayerResponse = ${JSON.stringify(response)};`);
  assert.equal(page.window.ytInitialPlayerResponse.adPlacements, undefined, 'pruned in the page');

  const capture = await page.cmd('capture');
  // CaptureWriter.swift writes capture.originals as <role>-originals.json.
  const written = JSON.parse(JSON.stringify(capture.originals));
  const initial = written.find((e) => e.source === 'initial' && e.target === 'window.ytInitialPlayerResponse');
  assert.ok(initial, 'the inline player response is in the capture');
  assert.ok(JSON.parse(initial.text).adPlacements, 'captured before pruning');

  const cases = casesFromCaptureData(written, 'capture/player-originals.json');
  const playerCase = cases.find((c) => c.endpoint === 'player');
  assert.ok(playerCase, `replayed from the player endpoint: ${cases.map((c) => c.endpoint).join(', ')}`);
  assert.ok(JSON.parse(playerCase.text).adPlacements, 'the case carries the ads, so the test can check the pruning');
  assertClean(page);

  // Replayed through the real scripts, as npm test does for js/fixtures/local/ captures.
  const run = await runCase(createPage, playerCase);
  t.after(() => run.page.close());
  assert.deepEqual(remainingKnownAdKeys(run.value), [], 'no known ad keys after the replay');
  assert.equal(run.value.videoDetails.videoId, 'dQw4w9WgXcQ', 'content intact');
});
