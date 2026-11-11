// Every script loads in both roles with no scriptError; ready is posted; the ytInitial* trap works
// in the harness (PLAN.md §8 step 6). Owner: P0.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, readManifest, readText, PATHS, NAMESPACE } from './harness.mjs';

const ROLES = ['browse', 'player'];

for (const role of ROLES) {
  test(`all scripts › ${role} › load in manifest order with no scriptError`, async (t) => {
    const page = await createPage({ role, url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ' });
    t.after(() => page.close());
    const expected = ['prelude.js', ...readManifest().scripts.filter((s) => s.roles.includes(role)).map((s) => s.file)];
    // `end` scripts load after `start` scripts, whatever their manifest position.
    const order = (name) => (readManifest().scripts.find((s) => s.file === name)?.injection === 'end' ? 1 : 0);
    assert.deepEqual(page.loaded, [...expected].sort((a, b) => order(a) - order(b) || expected.indexOf(a) - expected.indexOf(b)));
    assertClean(page, role);
  });

  test(`bridge.js › ${role} › posts ready with the role and URL`, async (t) => {
    const url = 'https://m.youtube.com/results?search_query=x';
    const page = await createPage({ role, url });
    t.after(() => page.close());
    const ready = page.posted('ready');
    assert.equal(ready.length, 1);
    assert.equal(ready[0].role, role);
    assert.equal(ready[0].url, url);
    assert.equal(ready[0].frame, 'main');
    assertMatchesVector(ready[0], 'ready');
  });

  test(`bridge.js › ${role} › installs a frozen, non-enumerable namespace with the prelude config`, async (t) => {
    const page = await createPage({ role, debug: true, build: '1.2 (3)' });
    t.after(() => page.close());
    const win = page.window;
    const descriptor = Object.getOwnPropertyDescriptor(win, NAMESPACE);
    assert.ok(descriptor, 'namespace exists');
    assert.equal(descriptor.enumerable, false);
    assert.equal(descriptor.writable, false);
    assert.equal(descriptor.configurable, false);
    assert.ok(Object.isFrozen(win[NAMESPACE]));
    assert.deepEqual({ ...win[NAMESPACE].config }, { role, debug: true, build: '1.2 (3)' });
    assert.ok(!Object.keys(win).includes(NAMESPACE));
  });
}

test('all scripts › sub frame › only frame-agnostic scripts load, and messages say frame sub', async (t) => {
  const page = await createPage({ role: 'player', frame: 'sub' });
  t.after(() => page.close());
  const expected = ['prelude.js', ...readManifest().scripts.filter((s) => s.roles.includes('player') && !s.mainFrameOnly).map((s) => s.file)];
  assert.deepEqual(page.loaded, expected);
  assertClean(page, 'sub frame');
  const [ready] = page.posted('ready');
  assert.equal(ready.frame, 'sub');
  assertMatchesVector(ready, 'ready (sub)');
});

test('all scripts › start scripts › run before <head> and <body> exist', async (t) => {
  let seen = null;
  const page = await createPage({
    role: 'player',
    until: 'start',
    beforeScripts: (win) => { seen = { head: win.document.head, body: win.document.body, readyState: win.document.readyState }; },
  });
  t.after(() => page.close());
  assert.deepEqual(seen, { head: null, body: null, readyState: 'loading' });
  assertClean(page, 'document start');
  page.finishLoading({ html: '<html><head><title>T</title></head><body><div id="app"></div></body></html>' });
  assert.equal(page.document.title, 'T');
  assert.equal(page.document.readyState, 'complete');
  assertClean(page, 'after load');
});

test('harness › inline script › `var ytInitialPlayerResponse = …` goes through an accessor trap', async (t) => {
  const page = await createPage({ role: 'player', until: 'start' });
  t.after(() => page.close());
  // What hooks.js (Module A) will do at document start.
  page.runInline(`
    window.__trapHits = [];
    let stored;
    Object.defineProperty(window, 'ytInitialPlayerResponse', {
      configurable: true,
      get() { return stored; },
      set(value) { window.__trapHits.push(Object.keys(value).join(',')); delete value.adPlacements; stored = value; },
    });
  `, 'trap.js');
  page.finishLoading({
    html: '<html><body><script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"dQw4w9WgXcQ"},"adPlacements":[1]};</script></body></html>',
  });
  const win = page.window;
  assert.deepEqual([...win.__trapHits], ['videoDetails,adPlacements']);
  assert.equal(win.ytInitialPlayerResponse.adPlacements, undefined);
  assert.equal(win.ytInitialPlayerResponse.videoDetails.videoId, 'dQw4w9WgXcQ');
  const descriptor = Object.getOwnPropertyDescriptor(win, 'ytInitialPlayerResponse');
  assert.equal(typeof descriptor.set, 'function', 'the accessor survives the var declaration');
  assert.deepEqual(page.pageErrors, []);
});

test('all scripts › headers › each file names itself and its owner, wraps its body in guard, has a config table', () => {
  // The convention (CLAUDE.md › JavaScript): line 1 is `// <file> — owner: Module <X> (…)`
  // (bridge.js: `Owner: P0`); the body runs inside `__ytadless.guard(…)` (any spelling of the
  // namespace reference); a `const CONFIG`/`RULES`/other UPPER_CASE table sits near the top.
  for (const entry of readManifest().scripts) {
    const text = readText(PATHS.scripts, entry.file);
    const firstLine = text.split('\n', 1)[0];
    assert.ok(firstLine.startsWith(`// ${entry.file} — `), `${entry.file}: line 1 starts with "// ${entry.file} — "`);
    const owner = entry.file === 'bridge.js' ? /Owner: P0\b/ : new RegExp(`owner: Module ${entry.owner}\\b`, 'i');
    assert.match(firstLine, owner, `${entry.file}: line 1 names owner ${entry.owner}`);
    if (entry.file === 'bridge.js') continue;  // it defines guard
    assert.match(text, /\.guard\(/, `${entry.file}: body runs inside guard`);
    assert.match(text, /\bconst [A-Z][A-Z0-9_]* = /, `${entry.file}: has an UPPER_CASE config table`);
  }
});
