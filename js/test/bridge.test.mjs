// bridge.js: post, guard, log, event bus, commands, hooks slot (PLAN.md §5.2). Owner: P0.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertMatchesVector, readText, PATHS, NAMESPACE } from './harness.mjs';

async function bridgePage(t, options = {}) {
  const page = await createPage({ role: 'browse', scripts: [], ...options });
  t.after(() => page.close());
  return { page, ns: page.window[NAMESPACE] };
}

test('bridge.js › post › adds v, type and frame, which payload fields cannot override', async (t) => {
  const { page, ns } = await bridgePage(t);
  assert.equal(ns.post('filterHit', { rule: 'r', count: 2, v: 9, type: 'x', frame: 'sub' }), true);
  const [hit] = page.posted('filterHit');
  assert.deepEqual(hit, { rule: 'r', count: 2, v: 1, type: 'filterHit', frame: 'main' });
  assertMatchesVector(hit, 'filterHit');
});

test('bridge.js › post › sanitizes payloads to plain JSON and never throws', async (t) => {
  const { page, ns } = await bridgePage(t);
  const cyclic = {};
  cyclic.self = cyclic;
  assert.equal(ns.post('playback', { status: 'loading', position: 0, duration: NaN, rate: 1, fn() {}, missing: undefined }), true);
  assert.equal(ns.post('log', cyclic), true);           // unserializable → empty payload
  assert.equal(ns.post('log', 'not an object'), true);  // non-object → empty payload
  assert.equal(ns.post(''), false);
  assert.equal(ns.post(42), false);
  const [playback] = page.posted('playback');
  assert.deepEqual(playback, { status: 'loading', position: 0, duration: null, rate: 1, v: 1, type: 'playback', frame: 'main' });
  assertMatchesVector(playback, 'playback with NaN duration');
  assert.deepEqual(page.posted('log').map((m) => Object.keys(m).sort()), [['frame', 'type', 'v'], ['frame', 'type', 'v']]);
});

test('bridge.js › post › is a no-op without the message handler', async (t) => {
  const { page, ns } = await bridgePage(t, { webkit: false });
  assert.ok(ns, 'the namespace still installs');
  assert.equal(ns.post('log', { level: 'info' }), false);
  assert.equal(ns.guard('x.js', () => { throw new Error('boom'); }), undefined);
  assert.deepEqual(page.pageErrors, []);
});

test('bridge.js › post › uses the JSON functions captured before other scripts wrap them', async (t) => {
  const { page, ns } = await bridgePage(t);
  page.window.JSON.stringify = () => { throw new Error('wrapped'); };
  page.window.JSON.parse = () => { throw new Error('wrapped'); };
  assert.equal(ns.post('filterHit', { rule: 'r', count: 1 }), true);
  assert.equal(page.posted('filterHit').length, 1);
});

test('bridge.js › guard › returns the value, reports throws and rejections as scriptError', async (t) => {
  const { page, ns } = await bridgePage(t);
  assert.equal(ns.guard('a.js', () => 7), 7);
  assert.equal(ns.guard('b.js', () => { throw new TypeError('bad thing'); }), undefined);
  ns.guard('c.js', async () => { throw new Error('async bad'); });
  await page.flush();
  const errors = page.scriptErrors();
  assert.deepEqual(errors.map((e) => [e.source, e.message]), [['b.js', 'TypeError: bad thing'], ['c.js', 'Error: async bad']]);
  for (const e of errors) {
    assertMatchesVector(e, 'scriptError');
    assert.match(e.stack, /ytadless|inline|bridge/);
  }
  assert.deepEqual(page.pageErrors, []);
});

test('bridge.js › guard › stops reporting a source after 50 errors', async (t) => {
  const { page, ns } = await bridgePage(t);
  for (let i = 0; i < 60; i += 1) ns.guard('noisy.js', () => { throw new Error(String(i)); });
  assert.equal(page.scriptErrors().length, 50);
});

test('bridge.js › log › formats arguments, validates the level, drops debug unless config.debug', async (t) => {
  const { page, ns } = await bridgePage(t);
  ns.log('warn', 'x.js', 'count', 3, { a: 1 }, new Error('e'), null, undefined);
  ns.log('fatal', 'x.js', 'unknown level');
  ns.log('debug', 'x.js', 'hidden');
  const logs = page.posted('log');
  assert.deepEqual(logs.map((l) => [l.level, l.message]), [
    ['warn', 'count 3 {"a":1} Error: e null undefined'],
    ['info', 'unknown level'],
  ]);
  for (const l of logs) assertMatchesVector(l, 'log');

  const debugPage = await createPage({ scripts: [], debug: true });
  t.after(() => debugPage.close());
  debugPage.window[NAMESPACE].log('debug', 'x.js', 'shown');
  assert.equal(debugPage.posted('log')[0].message, 'shown');
});

test('bridge.js › event bus › emit passes every argument, isolates throwing listeners, on() returns off', async (t) => {
  const { page, ns } = await bridgePage(t);
  const calls = [];
  const off = ns.on('playerResponse', (pr, info) => calls.push(['first', pr.id, info.source]));
  ns.on('playerResponse', () => { throw new Error('listener bug'); });
  ns.on('playerResponse', (pr) => calls.push(['third', pr.id]));
  assert.equal(ns.emit('playerResponse', { id: 1 }, { source: 'fetch' }), 3);
  off();
  ns.emit('playerResponse', { id: 2 }, { source: 'xhr' });
  assert.equal(ns.emit('nobody-listens', 1), 0);
  assert.deepEqual(calls, [['first', 1, 'fetch'], ['third', 1], ['third', 2]]);
  assert.deepEqual(page.scriptErrors().map((e) => e.source), ['on:playerResponse', 'on:playerResponse']);
});

test('bridge.js › commands › cmd parses JSON args, sanitizes results, reports errors as {error}', async (t) => {
  const { page, ns } = await bridgePage(t);
  assert.equal(ns.command('echo', (args) => ({ got: args, nan: NaN, skip: undefined })), true);
  assert.equal(ns.command('echo', () => 'second'), false, 'a second owner is refused');
  ns.command('nothing', () => undefined);
  ns.command('throws', () => { throw new Error('handler bug'); });
  ns.command('async', async (args) => ({ doubled: args.n * 2 }));
  ns.command('rejects', async () => { throw new Error('async handler bug'); });

  assert.deepEqual(await page.cmd('echo', { to: 1.5 }), { got: { to: 1.5 }, nan: null });
  assert.equal(await page.cmd('nothing'), null);
  assert.deepEqual(await page.cmd('throws'), { error: 'Error: handler bug' });
  assert.deepEqual(await page.cmd('async', { n: 21 }), { doubled: 42 });
  assert.deepEqual(await page.cmd('rejects'), { error: 'Error: async handler bug' });
  assert.deepEqual(await page.cmd('missing'), { error: 'unknown-command: missing' });
  assert.deepEqual(JSON.parse(JSON.stringify(ns.cmd('echo', '{not json'))), { error: 'invalid-args' });
  assert.deepEqual(JSON.parse(JSON.stringify(ns.cmd('echo', '[1,2]'))).got, {});
  assert.deepEqual(JSON.parse(JSON.stringify(ns.cmd('echo'))).got, {});
  assert.deepEqual(
    page.scriptErrors().map((e) => e.source),
    ['bridge.js', 'cmd:throws', 'cmd:rejects'],
  );
});

test('bridge.js › namespace › cannot be replaced by the page, and a second bridge.js is a no-op', async (t) => {
  const { page, ns } = await bridgePage(t);
  const win = page.window;
  page.runInline(`window.${NAMESPACE} = { evil: true }; delete window.${NAMESPACE};`, 'page.js');  // sloppy page code
  assert.equal(win[NAMESPACE], ns);
  assert.throws(() => { ns.post = null; }, TypeError, 'frozen');
  const before = page.messages.length;
  page.runInline(readText(PATHS.scripts, 'bridge.js'), 'ytadless/bridge-again.js');
  assert.equal(win[NAMESPACE], ns);
  assert.equal(page.messages.length, before, 'no second ready');
});

test('bridge.js › hooks › can be set once (by hooks.js), later sets are refused', async (t) => {
  const { page, ns } = await bridgePage(t);
  assert.equal(ns.hooks, undefined);
  const hooks = { addPruner() {} };
  ns.hooks = hooks;
  assert.equal(ns.hooks, hooks);
  ns.hooks = { other: true };
  assert.equal(ns.hooks, hooks);
  assert.deepEqual(page.scriptErrors().map((e) => e.message), ['Error: __ytadless.hooks is already set']);
});

test('bridge.js › missing prelude › falls back to the browse default config', async (t) => {
  const page = await createPage({ scripts: 'none' });
  t.after(() => page.close());
  page.runInline(readText(PATHS.scripts, 'bridge.js'), 'ytadless/bridge.js');
  assert.deepEqual({ ...page.window[NAMESPACE].config }, { role: 'browse', debug: false, build: 'unknown' });
  assert.equal(page.posted('ready')[0].role, 'browse');
});
