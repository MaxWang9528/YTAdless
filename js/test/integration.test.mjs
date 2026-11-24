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
