// The harness itself: lifecycle, network fakes, injection plan (PLAN.md §5.7). Owner: P0.
// Module tests rely on these behaviours, so they are pinned here.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, injectionPlan, readManifest, IPHONE_SAFARI_UA } from './harness.mjs';

test('harness › lifecycle › start scripts see loading → interactive → DOMContentLoaded → end scripts → complete → load', async (t) => {
  const page = await createPage({
    role: 'player',
    scripts: [],
    beforeScripts: (win) => {
      win.__events = [];
      const doc = win.document;
      doc.addEventListener('readystatechange', () => win.__events.push('rs:' + doc.readyState));
      doc.addEventListener('DOMContentLoaded', () => win.__events.push('DOMContentLoaded'));
      win.addEventListener('load', () => win.__events.push('load'));
    },
    html: '<html><body><script>window.__events.push("inline:" + document.readyState)</script></body></html>',
  });
  t.after(() => page.close());
  assert.deepEqual([...page.window.__events], ['inline:loading', 'rs:interactive', 'DOMContentLoaded', 'rs:complete', 'load']);
});

test('harness › lifecycle › inline JSON blocks and external scripts are not executed', async (t) => {
  const page = await createPage({
    scripts: 'none',
    html: '<html><body><script type="application/json">{"x":1}</script><script src="https://example.com/x.js"></script><script>window.ran = (window.ran || 0) + 1</script></body></html>',
  });
  t.after(() => page.close());
  assert.equal(page.window.ran, 1);
  assert.deepEqual(page.pageErrors, []);
});

test('harness › lifecycle › a throwing script is recorded and the next scripts still load', async (t) => {
  const page = await createPage({ scripts: 'none', html: '<html><body><script>throw new Error("page bug")</script><script>window.after = true</script></body></html>' });
  t.after(() => page.close());
  assert.equal(page.window.after, true);
  assert.deepEqual(page.pageErrors.map((e) => e.error.message), ['page bug']);
});

test('harness › environment › iPhone Safari user agent; visible document; top-level frame', async (t) => {
  const page = await createPage({ scripts: 'none' });
  t.after(() => page.close());
  assert.equal(page.window.navigator.userAgent, IPHONE_SAFARI_UA);
  assert.equal(page.document.visibilityState, 'visible');
  assert.equal(page.window.top, page.window);
});

test('harness › injectionPlan › prelude first, role filter, `only`, sub-frame filter', () => {
  const manifest = readManifest();
  const player = injectionPlan({ role: 'player' });
  assert.deepEqual(player.map((s) => s.name), ['prelude.js', ...manifest.scripts.map((s) => s.file)]);
  assert.ok(player.every((s) => s.source.endsWith(`\n//# sourceURL=ytadless/${s.name}\n`)));
  const browse = injectionPlan({ role: 'browse' });
  assert.deepEqual(browse.map((s) => s.name), ['prelude.js', ...manifest.scripts.filter((s) => s.roles.includes('browse')).map((s) => s.file)]);
  assert.deepEqual(injectionPlan({ role: 'player', only: ['layout.js'] }).map((s) => s.name), ['prelude.js', 'bridge.js', 'layout.js']);
  assert.ok(injectionPlan({ role: 'player', frame: 'sub' }).every((s) => !s.mainFrameOnly));
});

test('harness › fetch › routes answer with text bodies, url/status/headers preserved, json() in the page realm', async (t) => {
  const page = await createPage({
    scripts: 'none',
    routes: [{ match: '/youtubei/v1/player', method: 'POST', body: { playabilityStatus: { status: 'OK' } } }],
  });
  t.after(() => page.close());
  const win = page.window;
  const result = await page.runInline(`(async () => {
    const res = await fetch('/youtubei/v1/player?prettyPrint=false', { method: 'POST', body: '{}' });
    const copy = res.clone();
    const data = await res.json();
    return { url: res.url, copyURL: copy.url, status: res.status, type: res.headers.get('content-type'),
             text: await copy.text(), pageRealm: Object.getPrototypeOf(data) === Object.prototype,
             isResponse: res instanceof Response };
  })()`);
  assert.deepEqual({ ...result }, {
    url: 'https://m.youtube.com/youtubei/v1/player?prettyPrint=false',
    copyURL: 'https://m.youtube.com/youtubei/v1/player?prettyPrint=false',
    status: 200,
    type: 'application/json',
    text: '{"playabilityStatus":{"status":"OK"}}',
    pageRealm: true,
    isResponse: true,
  });
  assert.deepEqual(page.requests, [{ api: 'fetch', method: 'POST', url: 'https://m.youtube.com/youtubei/v1/player?prettyPrint=false', body: '{}' }]);
  assert.equal(typeof win.Response, 'function');
});

test('harness › fetch › unmatched requests reject with a page-realm TypeError; `times` limits a route', async (t) => {
  const page = await createPage({ scripts: 'none', routes: [{ match: /\/once$/, body: 'x', times: 1 }] });
  t.after(() => page.close());
  const out = await page.runInline(`(async () => {
    const first = await (await fetch('https://m.youtube.com/once')).text();
    let second;
    try { await fetch('https://m.youtube.com/once'); second = 'resolved'; } catch (e) { second = e instanceof TypeError ? 'TypeError' : 'other'; }
    return [first, second];
  })()`);
  assert.deepEqual([...out], ['x', 'TypeError']);
  assert.deepEqual(page.unmatched.map((u) => u.url), ['https://m.youtube.com/once']);
});

test('harness › fetch › Request resolves relative URLs against the page, and fetch(Request) records its body', async (t) => {
  const page = await createPage({ scripts: 'none', url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ', routes: [{ match: '/youtubei/v1/player', body: '{}' }] });
  t.after(() => page.close());
  const out = await page.runInline(`(async () => {
    const req = new Request('/youtubei/v1/player?key=k', { method: 'POST', body: '{"videoId":"dQw4w9WgXcQ"}' });
    const res = await fetch(req);
    return { reqURL: req.url, resURL: res.url };
  })()`);
  assert.deepEqual({ ...out }, {
    reqURL: 'https://m.youtube.com/youtubei/v1/player?key=k',
    resURL: 'https://m.youtube.com/youtubei/v1/player?key=k',
  });
  assert.deepEqual(page.requests, [{ api: 'fetch', method: 'POST', url: 'https://m.youtube.com/youtubei/v1/player?key=k', body: '{"videoId":"dQw4w9WgXcQ"}' }]);
});

test('harness › XMLHttpRequest › readyState sequence, handlers and listeners, text and json responses', async (t) => {
  const page = await createPage({ scripts: 'none', routes: [{ match: '/youtubei/v1/next', body: { contents: [1, 2] }, headers: { 'X-Test': 'yes' } }] });
  t.after(() => page.close());
  const out = await page.runInline(`new Promise((resolve) => {
    const states = [];
    const xhr = new XMLHttpRequest();
    xhr.onreadystatechange = () => states.push(xhr.readyState);
    xhr.addEventListener('load', () => {
      const json = new XMLHttpRequest();
      json.responseType = 'json';
      json.open('GET', '/youtubei/v1/next');
      json.onload = () => resolve({ states, text: xhr.responseText, status: xhr.status, header: xhr.getResponseHeader('x-test'),
                                    url: xhr.responseURL, json: json.response, jsonRealm: Object.getPrototypeOf(json.response) === Object.prototype });
      json.send();
    });
    xhr.open('POST', '/youtubei/v1/next');
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.send('{"videoId":"x"}');
  })`);
  assert.deepEqual(JSON.parse(JSON.stringify(out)), {
    states: [1, 2, 3, 4],
    text: '{"contents":[1,2]}',
    status: 200,
    header: 'yes',
    url: 'https://m.youtube.com/youtubei/v1/next',
    json: { contents: [1, 2] },
    jsonRealm: true,
  });
  assert.equal(page.requests[0].headers['content-type'], 'application/json');
});

test('harness › XMLHttpRequest › responseText/response/open/send live on the prototype, so hooks can wrap them', async (t) => {
  const page = await createPage({ scripts: 'none' });
  t.after(() => page.close());
  const proto = page.window.XMLHttpRequest.prototype;
  for (const key of ['responseText', 'response', 'readyState', 'status', 'onload', 'onreadystatechange']) {
    assert.equal(typeof Object.getOwnPropertyDescriptor(proto, key)?.get, 'function', key);
  }
  for (const key of ['open', 'send', 'setRequestHeader', 'abort']) assert.equal(typeof proto[key], 'function', key);
  assert.equal(page.window.XMLHttpRequest.DONE, 4);
});

test('harness › XMLHttpRequest › unmatched requests end with error, status 0', async (t) => {
  const page = await createPage({ scripts: 'none' });
  t.after(() => page.close());
  const out = await page.runInline(`new Promise((resolve) => {
    const xhr = new XMLHttpRequest();
    xhr.onerror = () => resolve({ status: xhr.status, readyState: xhr.readyState });
    xhr.open('GET', 'https://www.youtube.com/nothing');
    xhr.send();
  })`);
  assert.deepEqual({ ...out }, { status: 0, readyState: 4 });
  assert.equal(page.unmatched.length, 1);
});
