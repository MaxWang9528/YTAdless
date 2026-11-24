// debug.js (PLAN.md §6.2 Debug tooling, §5.4 `capture`). Owner: Module B.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, NAMESPACE } from './harness.mjs';

const HTML = '<html><head><title>Home - YouTube</title></head><body><div id="app"><p>hello</p></div></body></html>';

async function debugPage(t, options = {}) {
  const page = await createPage({ role: 'browse', scripts: ['debug.js'], html: HTML, ...options });
  t.after(() => page.close());
  return page;
}

function logs(page) {
  return page.posted('log').filter((m) => m.source === 'debug.js');
}

function checkMessages(page, label) {
  for (const m of page.messages) assertMatchesVector(m, label);
  assertClean(page, label);
}

test('debug.js › console › warn and error are forwarded and still reach the console', async (t) => {
  const page = await debugPage(t);
  page.runInline(`console.warn('something odd', 42, {a: 1, b: 2}, [1, 2, 3]); console.error(new TypeError('bad thing'));`);
  assert.deepEqual(logs(page).map((m) => [m.level, m.message]), [
    ['warn', 'console.warn: something odd 42 {a,b} [Array(3)]'],
    ['error', 'console.error: TypeError: bad thing'],
  ]);
  const seen = page.console.filter((c) => c.level === 'warn' || c.level === 'error').map((c) => c.level);
  assert.deepEqual(seen, ['warn', 'error'], 'originals were called');
  checkMessages(page, 'console');
});

test('debug.js › console › log and info are not forwarded', async (t) => {
  const page = await debugPage(t);
  page.runInline(`console.log('x'); console.info('y');`);
  assert.deepEqual(logs(page), []);
  checkMessages(page, 'log/info');
});

test('debug.js › console › big objects are summarized, not stringified', async (t) => {
  const page = await debugPage(t);
  page.runInline(`
    const big = {}; for (let i = 0; i < 20; i++) big['k' + i] = { deep: 'x'.repeat(1000) };
    const cyclic = { name: 'c' }; cyclic.self = cyclic;
    console.warn(big, cyclic, 'y'.repeat(5000), new Map(), () => 1);
  `);
  const [m] = logs(page);
  assert.match(m.message, /^console\.warn: \{k0,k1,k2,k3,k4,k5,k6,k7,…\} \{name,self\} y{600}… \[Map\] \[function anonymous\]$/);
  checkMessages(page, 'summaries');
});

test('debug.js › console › repeats and floods are capped per document', async (t) => {
  const page = await debugPage(t);
  page.runInline(`for (let i = 0; i < 10; i++) console.warn('same');`);
  assert.equal(logs(page).length, 3, 'MAX_REPEATS');
  page.runInline(`for (let i = 0; i < 400; i++) console.warn('line ' + i);`);
  const all = logs(page);
  assert.equal(all.length, 300 + 1, 'MAX_FORWARDED plus one suppressed notice');
  assert.match(all.at(-1).message, /more than 300 log lines/);
  const capture = await page.cmd('capture');
  assert.equal(capture.counters.consoleWarn, 410);
  assert.equal(capture.counters.suppressed, 3 + 400 - 300, 'distinct lines past the cap');
  assert.equal(capture.log.length, 200, 'LOG_BUFFER_SIZE');
  assert.equal(capture.log.at(-1).message, 'console.warn: line 399');
  checkMessages(page, 'caps');
});

test('debug.js › page errors › uncaught errors and unhandled rejections are forwarded', async (t) => {
  const page = await debugPage(t);
  const { window } = page;
  window.dispatchEvent(new window.ErrorEvent('error', {
    message: 'Uncaught boom', filename: 'https://m.youtube.com/s/app.js', lineno: 3, colno: 7, error: new window.Error('boom'),
  }));
  window.dispatchEvent(new window.Event('error'));  // a failed resource load: ignored
  const rejection = new window.Event('unhandledrejection');
  rejection.reason = new window.Error('nope');
  window.dispatchEvent(rejection);
  assert.deepEqual(logs(page).map((m) => [m.level, m.message]), [
    ['error', 'uncaught: Error: boom @ https://m.youtube.com/s/app.js:3:7'],
    ['warn', 'unhandledrejection: Error: nope'],
  ]);
  checkMessages(page, 'page errors');
});

test('debug.js › capture › returns the page, the DOM, the originals, counters and the log', async (t) => {
  const page = await debugPage(t, {
    url: 'https://m.youtube.com/results?search_query=x',
    until: 'start',
    beforeScripts: () => {},
  });
  page.window[NAMESPACE].hooks = { addPruner() {}, originals: [{ url: '/youtubei/v1/player', body: '{"adPlacements":[]}' }] };
  page.finishLoading();
  page.runInline(`console.error('e1')`);
  const capture = await page.cmd('capture');
  assert.deepEqual(Object.keys(capture).sort(), ['counters', 'html', 'log', 'originals', 'title', 'url']);
  assert.equal(capture.url, 'https://m.youtube.com/results?search_query=x');
  assert.equal(capture.title, 'Home - YouTube');
  assert.match(capture.html, /^<!DOCTYPE html>\n<html><head><title>Home - YouTube<\/title><\/head><body><div id="app"><p>hello<\/p><\/div>/);
  assert.deepEqual(capture.originals, [{ url: '/youtubei/v1/player', body: '{"adPlacements":[]}' }]);
  assert.equal(capture.counters.consoleError, 1);
  assert.deepEqual(capture.log.map((l) => [l.level, l.message]), [['error', 'console.error: e1']]);
  assert.equal(typeof capture.log[0].time, 'number');
  checkMessages(page, 'capture');
});

test('debug.js › capture › originals may be missing or a non-array ring buffer', async (t) => {
  const page = await debugPage(t);
  assert.deepEqual((await page.cmd('capture')).originals, [], 'no hooks');
  const other = await debugPage(t, { until: 'start' });
  other.window[NAMESPACE].hooks = { originals: { snapshot: () => [{ n: 1 }, { n: 2 }] } };
  other.finishLoading();
  assert.deepEqual((await other.cmd('capture')).originals, [{ n: 1 }, { n: 2 }]);
  checkMessages(page, 'no hooks');
  checkMessages(other, 'snapshot');
});

test('debug.js › sub frame › forwards with frame sub', async (t) => {
  const page = await createPage({ role: 'player', frame: 'sub', scripts: ['debug.js'] });
  t.after(() => page.close());
  page.runInline(`console.warn('from a frame')`);
  const [m] = logs(page);
  assert.equal(m.frame, 'sub');
  assert.equal(m.message, 'console.warn: from a frame');
  checkMessages(page, 'sub frame');
});

test('debug.js › all scripts › capture works with every script loaded, in both roles', async (t) => {
  for (const role of ['browse', 'player']) {
    const page = await createPage({ role, url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ', html: HTML });
    t.after(() => page.close());
    const capture = await page.cmd('capture');
    assert.equal(capture.error, undefined, role);
    assert.ok(capture.html.includes('<p>hello</p>'), role);
    assert.ok(Array.isArray(capture.originals), role);
    checkMessages(page, `all scripts ${role}`);
  }
});
