// hooks.js: path engine, interception points, originals, playerResponse (PLAN.md §5.2, §6.1).
// Owner: Module A.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector } from './harness.mjs';

const API = 'https://m.youtube.com/youtubei/v1/';
const plain = (v) => JSON.parse(JSON.stringify(v));

async function hooksPage(t, options = {}) {
  const page = await createPage({ role: 'player', scripts: ['hooks.js'], ...options });
  t.after(() => page.close());
  return { page, hooks: page.window.__ytadless.hooks, ns: page.window.__ytadless };
}

function assertMessages(page) {
  page.messages.forEach((m, i) => assertMatchesVector(m, `message ${i}`));
}

// ── Path engine (uBO json-prune dialect; cases from the F6 uBO lines) ────────────────────────

const PATH_CASES = [
  {
    name: 'top-level keys (json-prune adPlacements playerAds adSlots)',
    path: 'adPlacements',
    input: { adPlacements: [1], videoDetails: { videoId: 'x' } },
    output: { videoDetails: { videoId: 'x' } },
    count: 1,
  },
  {
    name: 'nested key (playerResponse.adPlacements)',
    path: 'playerResponse.adPlacements',
    input: { playerResponse: { adPlacements: [], streamingData: {} }, adPlacements: 'keep' },
    output: { playerResponse: { streamingData: {} }, adPlacements: 'keep' },
    count: 1,
  },
  {
    name: '[] every element (get_watch [].playerResponse.adSlots)',
    path: '[].playerResponse.adSlots',
    input: [{ playerResponse: { adSlots: [1], a: 1 } }, { response: {} }, { playerResponse: { adSlots: [2] } }],
    output: [{ playerResponse: { a: 1 } }, { response: {} }, { playerResponse: {} }],
    count: 2,
  },
  {
    name: '[-] removes the containing element (Shorts entries.[-]…isAd)',
    path: 'entries.[-].command.reelWatchEndpoint.adClientParams.isAd',
    input: { entries: [
      { command: { reelWatchEndpoint: { videoId: 'a' } } },
      { command: { reelWatchEndpoint: { videoId: 'ad', adClientParams: { isAd: true } } } },
      { command: { reelWatchEndpoint: { videoId: 'b' } } },
      { command: { reelWatchEndpoint: { videoId: 'ad2', adClientParams: { isAd: true } } } },
    ] },
    output: { entries: [{ command: { reelWatchEndpoint: { videoId: 'a' } } }, { command: { reelWatchEndpoint: { videoId: 'b' } } }] },
    count: 2,
  },
  {
    name: '..key at any depth with *[?.key] filter (json-edit ..itemSectionRenderer.contents.*[?.adSlotRenderer])',
    path: '..itemSectionRenderer.contents.*[?.adSlotRenderer]',
    input: { contents: { a: [{ itemSectionRenderer: { contents: [{ videoRenderer: 1 }, { adSlotRenderer: {} }, { videoRenderer: 2 }] } }],
      b: { deep: { itemSectionRenderer: { contents: [{ adSlotRenderer: { x: 1 } }] } } } } },
    output: { contents: { a: [{ itemSectionRenderer: { contents: [{ videoRenderer: 1 }, { videoRenderer: 2 }] } }],
      b: { deep: { itemSectionRenderer: { contents: [] } } } } },
    count: 2,
  },
  {
    name: '* any key',
    path: 'a.*.ad',
    input: { a: { x: { ad: 1, k: 1 }, y: { k: 2 }, z: [{ ad: 3 }] } },
    output: { a: { x: { k: 1 }, y: { k: 2 }, z: [{ ad: 3 }] } },
    count: 1,
  },
  {
    name: 'missing paths and primitives are a no-op',
    path: 'nope.deeper[].x',
    input: { nope: 'string', other: null },
    output: { nope: 'string', other: null },
    count: 0,
  },
];

for (const c of PATH_CASES) {
  test(`hooks.js › path engine › ${c.name}`, async (t) => {
    const { page, hooks } = await hooksPage(t);
    const value = structuredClone(c.input);
    assert.equal(hooks.prune(value, c.path), c.count);
    assert.deepEqual(plain(value), c.output);
    assertClean(page);
  });
}

test('hooks.js › addPruner › rejects a bad spec with a scriptError and returns false', async (t) => {
  const { page, hooks } = await hooksPage(t);
  assert.equal(hooks.addPruner({ name: 'bad', paths: ['a[?.b'] }), false);
  assert.equal(hooks.addPruner({ paths: ['a'] }), false);
  assert.equal(hooks.addPruner({ name: 'empty' }), false);
  assert.equal(hooks.addPruner({ name: 'ok', paths: ['a'] }), true);
  assert.equal(page.scriptErrors().length, 3);
});

// ── fetch ────────────────────────────────────────────────────────────────────────────────

test('hooks.js › fetch › a matching response is pruned and rewrapped with url, status and headers kept', async (t) => {
  const url = API + 'player?prettyPrint=false';
  const { page, hooks } = await hooksPage(t, {
    routes: [{ match: url, status: 200, headers: { 'x-test': 'kept', 'content-type': 'application/json' }, body: { adPlacements: [1], videoDetails: { videoId: 'abc' } } }],
  });
  hooks.addPruner({ name: 'test.ads', urls: ['/youtubei/v1/player'], paths: ['adPlacements'] });
  const res = await page.window.fetch(url, { method: 'POST', body: '{}' });
  assert.equal(res.url, url);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('x-test'), 'kept');
  assert.deepEqual(plain(await res.clone().json()), { videoDetails: { videoId: 'abc' } });
  assert.deepEqual(JSON.parse(await res.text()), { videoDetails: { videoId: 'abc' } });
  assert.deepEqual(page.posted('filterHit').map((m) => [m.rule, m.count]), [['test.ads', 1]]);
  assert.equal(hooks.originals.length, 1);
  assert.deepEqual(Object.keys(hooks.originals[0]).sort(), ['source', 'target', 'text', 'time', 'url']);
  assert.equal(hooks.originals[0].source, 'fetch');
  assert.match(hooks.originals[0].text, /adPlacements/);
  assertMessages(page);
  assertClean(page);
});

test('hooks.js › fetch › a Request object and a response with nothing to prune pass through unchanged', async (t) => {
  const url = API + 'browse?prettyPrint=false';
  const body = '{"contents":{"x":1}}';
  const { page, hooks } = await hooksPage(t, { routes: [{ match: url, body }] });
  hooks.addPruner({ name: 'test.ads', paths: ['adPlacements'] });
  const res = await page.window.fetch(new page.window.Request(url, { method: 'POST', body: '{}' }));
  assert.equal(await res.text(), body);
  assert.equal(page.posted('filterHit').length, 0);
  assertClean(page);
});

test('hooks.js › fetch › non-innertube URLs, non-JSON bodies and network errors are left alone', async (t) => {
  const { page, hooks } = await hooksPage(t, {
    routes: [
      { match: 'https://m.youtube.com/other.json', body: '{"adPlacements":1}' },
      { match: API + 'next', body: 'not json' },
    ],
  });
  hooks.addPruner({ name: 'test.ads', paths: ['adPlacements'] });
  const win = page.window;
  assert.equal(await (await win.fetch('/other.json')).text(), '{"adPlacements":1}');
  assert.equal(await (await win.fetch(API + 'next')).text(), 'not json');
  await assert.rejects(win.fetch(API + 'missing'), (e) => e.name === 'TypeError');
  assert.equal(hooks.originals.length, 1, 'only the innertube response was kept');
  assertClean(page);
});

test('hooks.js › fetch and JSON.parse › wrapped with Proxies, so toString still looks native', async (t) => {
  const { page } = await hooksPage(t);
  const win = page.window;
  assert.match(win.Function.prototype.toString.call(win.JSON.parse), /\[native code\]/);
  assert.match(win.Function.prototype.toString.call(win.fetch), /\[native code\]|fetch/);
  assert.equal(win.JSON.parse.name, 'parse');
  assert.equal(win.fetch.name, 'fetch');
});

// ── XMLHttpRequest ───────────────────────────────────────────────────────────────────────

function xhr(win, url, responseType = '') {
  return new Promise((resolve) => {
    const req = new win.XMLHttpRequest();
    req.open('POST', url);
    req.responseType = responseType;
    req.onload = () => resolve(req);
    req.send('{}');
  });
}

test('hooks.js › XMLHttpRequest › responseText and response are pruned; json responseType too', async (t) => {
  const url = API + 'player?prettyPrint=false';
  const { page, hooks } = await hooksPage(t, { routes: [{ match: url, body: { adSlots: [1], videoDetails: { videoId: 'v' } } }] });
  hooks.addPruner({ name: 'test.ads', urls: ['/player'], paths: ['adSlots'] });
  const win = page.window;
  const text = await xhr(win, url);
  assert.deepEqual(JSON.parse(text.responseText), { videoDetails: { videoId: 'v' } });
  assert.equal(text.response, text.responseText);
  const json = await xhr(win, url, 'json');
  assert.deepEqual(plain(json.response), { videoDetails: { videoId: 'v' } });
  assert.deepEqual(page.posted('filterHit').map((m) => m.count), [1, 1], 'one hit per response, not per read');
  assertMessages(page);
  assertClean(page);
});

test('hooks.js › XMLHttpRequest › other URLs are untouched', async (t) => {
  const { page, hooks } = await hooksPage(t, { routes: [{ match: '/api/other', body: '{"adSlots":1}' }] });
  hooks.addPruner({ name: 'test.ads', paths: ['adSlots'] });
  assert.equal((await xhr(page.window, 'https://m.youtube.com/api/other')).responseText, '{"adSlots":1}');
  assertClean(page);
});

// ── JSON.parse ───────────────────────────────────────────────────────────────────────────

test('hooks.js › JSON.parse › prunes innertube-shaped results only', async (t) => {
  const { page, hooks } = await hooksPage(t);
  hooks.addPruner({ name: 'test.parse', urls: ['JSON.parse'], paths: ['playerResponse.adPlacements'] });
  const win = page.window;
  const innertube = win.JSON.parse('{"responseContext":{},"playerResponse":{"adPlacements":[1],"videoDetails":{}}}');
  assert.deepEqual(plain(innertube), { responseContext: {}, playerResponse: { videoDetails: {} } });
  const other = win.JSON.parse('{"playerResponseX":{"adPlacements":[1]}}');
  assert.deepEqual(plain(other), { playerResponseX: { adPlacements: [1] } });
  assert.equal(win.JSON.parse('3'), 3);
  assert.throws(() => win.JSON.parse('{'), (e) => e.name === 'SyntaxError');
  assertClean(page);
});

// ── Accessor traps on the ytInitial* globals ─────────────────────────────────────────────

test('hooks.js › traps › `var ytInitialPlayerResponse = null` then `= {…}` is pruned and emitted once', async (t) => {
  const { page, hooks, ns } = await hooksPage(t, { until: 'start' });
  hooks.addPruner({ name: 'test.initial', urls: ['window.ytInitialPlayerResponse'], paths: ['adPlacements'] });
  const seen = [];
  ns.on('playerResponse', (pr, info) => seen.push([pr.videoDetails.videoId, info.source, info.url]));
  page.finishLoading({
    html: '<html><body><script>var ytInitialPlayerResponse = null;</script>' +
      '<script>var ytInitialPlayerResponse = {"videoDetails":{"videoId":"dQw4w9WgXcQ"},"adPlacements":[1]};' +
      'window.ytplayer = window.ytplayer || {}; window.ytplayer.bootstrapPlayerResponse = window["ytInitialPlayerResponse"];</script></body></html>',
  });
  const win = page.window;
  assert.equal(win.ytInitialPlayerResponse.adPlacements, undefined);
  assert.equal(win.ytInitialPlayerResponse.videoDetails.videoId, 'dQw4w9WgXcQ');
  assert.equal(win.ytplayer.bootstrapPlayerResponse, win.ytInitialPlayerResponse);
  assert.deepEqual(seen, [['dQw4w9WgXcQ', 'initial', 'https://m.youtube.com/']]);
  assert.deepEqual(page.posted('filterHit').map((m) => [m.rule, m.count]), [['test.initial', 1]]);
  assert.equal(hooks.originals[0].source, 'initial');
  assert.equal(hooks.originals[0].target, 'window.ytInitialPlayerResponse');
  assertMessages(page);
  assertClean(page);
});

test('hooks.js › traps › ytInitialData is stored as a string, then pruned when parsed and reassigned', async (t) => {
  const { page, hooks } = await hooksPage(t, { until: 'start' });
  const calls = [];
  hooks.addPruner({ name: 'test.data', urls: ['window.ytInitialData'], fn: (v, ctx) => { calls.push(ctx.target); delete v.ad; return 1; } });
  page.finishLoading({
    html: `<html><body><script>var ytInitialData = '\\x7b\\x22ad\\x22:1,\\x22contents\\x22:2\\x7d';</script>` +
      `<script>window.__typeBefore = typeof window['ytInitialData']; window['ytInitialData'] = JSON.parse(window['ytInitialData']);</script></body></html>`,
  });
  const win = page.window;
  assert.equal(win.__typeBefore, 'string');
  assert.deepEqual(plain(win.ytInitialData), { contents: 2 });
  assert.deepEqual(calls, ['window.ytInitialData']);
  assertClean(page);
});

test('hooks.js › traps › ytplayer.config.args.raw_player_response is pruned', async (t) => {
  const { page, hooks } = await hooksPage(t, { until: 'start' });
  hooks.addPruner({ name: 'test.ytplayer', urls: ['window.ytplayer'], paths: ['playerAds'] });
  page.finishLoading({
    html: '<html><body><script>window.ytplayer = window.ytplayer || {};' +
      'window.ytplayer.config = {args: {raw_player_response: {"videoDetails":{"videoId":"x"},"playerAds":[1]}}};</script></body></html>',
  });
  assert.deepEqual(plain(page.window.ytplayer.config.args.raw_player_response), { videoDetails: { videoId: 'x' } });
  assert.deepEqual(page.posted('filterHit').map((m) => m.rule), ['test.ytplayer']);
  assertClean(page);
});

// ── playerResponse event, originals, text rules ──────────────────────────────────────────

test('hooks.js › playerResponse › emitted after pruning for /player and for get_watch [].playerResponse', async (t) => {
  const { page, hooks, ns } = await hooksPage(t, {
    routes: [
      { match: API + 'player', body: { videoDetails: { videoId: 'aaaaaaaaaaa' }, adSlots: [1] } },
      { match: API + 'get_watch', body: [{ playerResponse: { videoDetails: { videoId: 'bbbbbbbbbbb' } } }, { response: {} }] },
    ],
  });
  hooks.addPruner({ name: 'test.ads', paths: ['adSlots'] });
  const seen = [];
  ns.on('playerResponse', (pr, info) => seen.push([pr.videoDetails.videoId, info.source, Object.keys(pr).join(','), info.url]));
  await (await page.window.fetch(API + 'player')).text();
  await (await page.window.fetch(API + 'get_watch')).text();
  assert.deepEqual(seen, [
    ['aaaaaaaaaaa', 'fetch', 'videoDetails', API + 'player'],
    ['bbbbbbbbbbb', 'fetch', 'videoDetails', API + 'get_watch'],
  ]);
  assertClean(page);
});

test('hooks.js › originals › bounded ring buffer, newest last', async (t) => {
  const { page, hooks } = await hooksPage(t, { routes: [{ match: API, body: { n: 1 } }] });
  hooks.addPruner({ name: 'test.noop', paths: ['nothing'] });
  for (let i = 0; i < 30; i += 1) await (await page.window.fetch(API + 'browse?i=' + i)).text();
  assert.equal(hooks.originals.length, 24);
  assert.match(hooks.originals.at(-1).url, /i=29$/);
  assert.match(hooks.originals[0].url, /i=6$/);
  assertClean(page);
});

test('hooks.js › text rules › raw-text replacement ("adPlacements" → "no_ads") on fetch', async (t) => {
  const { page, hooks } = await hooksPage(t, { routes: [{ match: API + 'player', body: '{"adPlacements":[1],"x":"adPlacements"}' }] });
  hooks.addPruner({ name: 'test.text', urls: ['/player'], text: [['"adPlacements"', '"no_ads"']] });
  assert.equal(await (await page.window.fetch(API + 'player')).text(), '{"no_ads":[1],"x":"no_ads"}');
  assert.deepEqual(page.posted('filterHit').map((m) => [m.rule, m.count]), [['test.text', 2]]);
  assertClean(page);
});

test('hooks.js › pruner errors › a throwing pruner is reported and the others still run', async (t) => {
  const { page, hooks } = await hooksPage(t, { routes: [{ match: API + 'next', body: { a: 1, b: 2 } }] });
  hooks.addPruner({ name: 'boom', fn: () => { throw new Error('pruner bug'); } });
  hooks.addPruner({ name: 'test.b', paths: ['b'] });
  assert.deepEqual(JSON.parse(await (await page.window.fetch(API + 'next')).text()), { a: 1 });
  assert.deepEqual(page.scriptErrors().map((e) => [e.source, e.message]), [['hooks.js:boom', 'Error: pruner bug']]);
});

test('hooks.js › hooks slot › set once with addPruner and originals', async (t) => {
  const { page, hooks } = await hooksPage(t);
  assert.equal(typeof hooks.addPruner, 'function');
  assert.ok(Array.isArray(hooks.originals));
  assert.ok(Object.isFrozen(hooks));
  assertClean(page);
});
