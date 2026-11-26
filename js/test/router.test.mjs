// router.js (PLAN.md §6.2) against TestVectors/routing.json. Owner: Module B.
//
// router.js only decides whether a URL leaves its view (decision !== 'allow'); Router.swift makes
// the full decision from the same vectors (RoutingTests).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, routingVectors, readJSON, PATHS, NAMESPACE } from './harness.mjs';

const HOME = 'https://m.youtube.com/';
const WATCH = 'https://m.youtube.com/watch?v=dQw4w9WgXcQ';
const pageURL = (role) => (role === 'player' ? WATCH : HOME);

async function routerPage(t, role, options = {}) {
  const page = await createPage({
    role,
    url: pageURL(role),
    scripts: ['router.js'],
    html: '<html><head><title>YouTube</title></head><body><div id="app"></div></body></html>',
    ...options,
  });
  t.after(() => page.close());
  return page;
}

/** Clicks an <a href> and reports whether the page saw the default prevented. */
function clickLink(page, href, { inner = false } = {}) {
  const { document, window } = page;
  const a = document.createElement('a');
  a.setAttribute('href', href);
  const target = inner ? a.appendChild(document.createElement('span')) : a;
  if (inner) target.textContent = 'thumb';
  document.getElementById('app').appendChild(a);
  let pageListenerRan = false;
  a.addEventListener('click', () => { pageListenerRan = true; });
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, composed: true, button: 0 });
  target.dispatchEvent(event);
  a.remove();
  return { prevented: event.defaultPrevented, pageListenerRan };
}

function checkMessages(page, label) {
  for (const m of page.messages) assertMatchesVector(m, label);
  assertClean(page, label);
}

const { decide } = routingVectors();

// A link to another bottom-nav tab's root, tapped in the browse view (owned by Home here), shows
// that tab's own webview instead (tab-switch.test.mjs); it is never a route.
const TAB_ROOTS = new Map(readJSON(PATHS.vectors, 'browseTabs.json').cases.filter((c) => c.tab).map((c) => [c.path, c.tab]));
function otherTab(c) {
  if (c.role !== 'browse') return null;
  const url = new URL(c.url);
  if (!['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(url.hostname)) return null;
  const tab = TAB_ROOTS.get(url.pathname) ?? null;
  return tab === 'home' ? null : tab;
}

for (const c of decide.filter((v) => otherTab(v) !== null)) {
  test(`router.js › routing.json ${c.name} › click shows the ${otherTab(c)} tab in browse`, async (t) => {
    const page = await routerPage(t, c.role);
    const { prevented, pageListenerRan } = clickLink(page, c.url, { inner: true });
    assert.equal(prevented, true);
    assert.equal(pageListenerRan, false);
    assert.deepEqual(page.posted('route'), []);
    assert.deepEqual(page.posted('selectTab').map((m) => m.tab), [otherTab(c)]);
    checkMessages(page, c.name);
  });
}

for (const c of decide.filter((v) => otherTab(v) === null)) {
  const leaves = c.expect.decision !== 'allow';
  test(`router.js › routing.json ${c.name} › click ${leaves ? 'is routed' : 'stays'} in ${c.role}`, async (t) => {
    const page = await routerPage(t, c.role);
    const { prevented, pageListenerRan } = clickLink(page, c.url, { inner: true });
    assert.equal(prevented, leaves, 'defaultPrevented');
    assert.equal(pageListenerRan, !leaves, 'page listeners run only for links that stay');
    const routes = page.posted('route');
    if (leaves) {
      assert.deepEqual(routes.map((m) => [m.url, m.trigger]), [[new URL(c.url).href, 'click']]);
    } else {
      assert.deepEqual(routes, []);
    }
    checkMessages(page, c.name);
  });
}

// pushState can only take same-origin URLs, so the history backstop runs on the m.youtube.com cases.
for (const c of decide.filter((v) => new URL(v.url).origin === 'https://m.youtube.com')) {
  const leaves = c.expect.decision !== 'allow';
  test(`router.js › routing.json ${c.name} › pushState ${leaves ? 'posts route{history}' : 'posts no route'} in ${c.role}`, async (t) => {
    const url = new URL(c.url).href;
    const start = url === pageURL(c.role) ? `${HOME}feed/library` : pageURL(c.role);
    const page = await routerPage(t, c.role, { url: start });
    const events = [];
    page.window[NAMESPACE].on('navigation', (e) => events.push(e.url));
    page.window.history.pushState({}, '', url);
    assert.equal(page.window.location.href, url, 'the page navigated');
    assert.deepEqual(page.posted('pageChanged').map((m) => m.url), [url]);
    assert.deepEqual(events, [url]);
    const routes = page.posted('route').map((m) => [m.url, m.trigger]);
    assert.deepEqual(routes, leaves ? [[url, 'history']] : []);
    checkMessages(page, c.name);
  });
}

for (const c of decide.filter((v) => v.trigger === 'windowOpen' || v.name.includes('external') || v.name.includes('redirect'))) {
  const leaves = c.expect.decision !== 'allow';
  test(`router.js › routing.json ${c.name} › window.open ${leaves ? 'is routed' : 'is passed on'} in ${c.role}`, async (t) => {
    const opened = [];
    const page = await routerPage(t, c.role, {
      beforeScripts: (win) => { win.open = (...args) => { opened.push(args[0]); return 'native-window'; }; },
    });
    const result = page.window.open(c.url, '_blank');
    if (leaves) {
      assert.equal(result, null);
      assert.deepEqual(opened, []);
      assert.deepEqual(page.posted('route').map((m) => [m.url, m.trigger]), [[new URL(c.url).href, 'windowOpen']]);
    } else {
      assert.equal(result, 'native-window');
      assert.deepEqual(opened, [c.url]);
    }
    checkMessages(page, c.name);
  });
}

test('router.js › browse › javascript:, about: and fragment links are never intercepted', async (t) => {
  const page = await routerPage(t, 'browse');
  for (const href of ['javascript:void(0)', 'about:blank', '#', '#menu', '', 'blob:https://m.youtube.com/x']) {
    assert.equal(clickLink(page, href).prevented, false, href);
  }
  assert.deepEqual(page.posted('route'), []);
  checkMessages(page, 'in-place');
});

test('router.js › player › relative links resolve against the page', async (t) => {
  const page = await routerPage(t, 'player');
  assert.equal(clickLink(page, '/watch?v=jNQXAC9IVRw').prevented, false, 'related video stays');
  assert.equal(clickLink(page, '/@RickAstleyYT').prevented, true, 'channel leaves');
  assert.equal(clickLink(page, '/shorts/aqz-KE-bpKQ').prevented, false, 'shorts stay');
  assert.deepEqual(page.posted('route').map((m) => m.url), ['https://m.youtube.com/@RickAstleyYT']);
  checkMessages(page, 'relative');
});

test('router.js › browse › a click outside any link, on a link without href, or with download does nothing', async (t) => {
  const page = await routerPage(t, 'browse');
  const { document, window } = page;
  const div = document.getElementById('app');
  const plain = new window.MouseEvent('click', { bubbles: true, cancelable: true });
  div.dispatchEvent(plain);
  assert.equal(plain.defaultPrevented, false);
  const noHref = document.createElement('a');
  div.appendChild(noHref);
  const e2 = new window.MouseEvent('click', { bubbles: true, cancelable: true });
  noHref.dispatchEvent(e2);
  assert.equal(e2.defaultPrevented, false);
  const dl = document.createElement('a');
  dl.setAttribute('href', '/watch?v=dQw4w9WgXcQ');
  dl.setAttribute('download', '');
  div.appendChild(dl);
  const e3 = new window.MouseEvent('click', { bubbles: true, cancelable: true });
  dl.dispatchEvent(e3);
  assert.equal(e3.defaultPrevented, false);
  // An SVG <a> has an SVGAnimatedString href; it is left to the page.
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  const svgA = document.createElementNS('http://www.w3.org/2000/svg', 'a');
  svgA.setAttribute('href', '/watch?v=dQw4w9WgXcQ');
  svg.appendChild(svgA);
  div.appendChild(svg);
  const e4 = new window.MouseEvent('click', { bubbles: true, cancelable: true });
  svgA.dispatchEvent(e4);
  assert.equal(e4.defaultPrevented, false);
  assert.deepEqual(page.posted('route'), []);
  checkMessages(page, 'no link');
});

test('router.js › browse › a link inside a shadow root is found through composedPath', async (t) => {
  const page = await routerPage(t, 'browse');
  const { document, window } = page;
  const host = document.createElement('div');
  document.getElementById('app').appendChild(host);
  const root = host.attachShadow({ mode: 'open' });
  const a = document.createElement('a');
  a.setAttribute('href', '/shorts/aqz-KE-bpKQ');
  const img = a.appendChild(document.createElement('img'));
  root.appendChild(a);
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, composed: true });
  img.dispatchEvent(event);
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(page.posted('route').map((m) => m.url), ['https://m.youtube.com/shorts/aqz-KE-bpKQ']);
  checkMessages(page, 'shadow');
});

test('router.js › browse › replaceState and popstate post pageChanged and navigation but never route', async (t) => {
  const page = await routerPage(t, 'browse');
  const { window, document } = page;
  const events = [];
  window[NAMESPACE].on('navigation', (e) => events.push(e.url));
  document.title = 'Subscriptions - YouTube';
  window.history.pushState({}, '', '/feed/subscriptions');
  window.history.replaceState({}, '', '/feed/subscriptions');  // same URL: nothing
  window.history.replaceState({}, '', '/watch?v=dQw4w9WgXcQ');  // no entry to go back from
  window.history.pushState({}, '', '/feed/library');
  window.history.back();
  await new Promise((resolve) => window.addEventListener('popstate', () => setTimeout(resolve, 0), { once: true }));
  const urls = [
    'https://m.youtube.com/feed/subscriptions',
    'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    'https://m.youtube.com/feed/library',
    'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
  ];
  assert.deepEqual(page.posted('pageChanged').map((m) => m.url), urls);
  assert.equal(page.posted('pageChanged')[0].title, 'Subscriptions - YouTube');
  assert.deepEqual(events, urls);
  assert.deepEqual(page.posted('route'), []);
  checkMessages(page, 'replace/pop');
});

test('router.js › pageChanged › an empty title is omitted', async (t) => {
  const page = await routerPage(t, 'browse', { html: '<html><head></head><body><div id="app"></div></body></html>' });
  page.window.history.pushState({}, '', '/feed/trending');
  const [m] = page.posted('pageChanged');
  assert.equal(Object.hasOwn(m, 'title'), false);
  checkMessages(page, 'no title');
});

test('router.js › history › a throwing pushState still throws into the page, and nothing is posted', async (t) => {
  const page = await routerPage(t, 'browse');
  assert.throws(() => page.window.history.pushState({}, '', 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'), (e) => e.name === 'SecurityError');
  assert.deepEqual(page.posted('pageChanged'), []);
  assert.deepEqual(page.scriptErrors(), []);
});

test('router.js › history › the wrappers keep the History.prototype method shape', async (t) => {
  const page = await routerPage(t, 'browse');
  for (const name of ['pushState', 'replaceState']) {
    const d = Object.getOwnPropertyDescriptor(page.window.History.prototype, name);
    assert.equal(typeof d.value, 'function');
    assert.equal(d.value.name, name);
    assert.equal(d.enumerable, true);
    assert.equal(d.writable, true);
    assert.equal(d.configurable, true);
  }
});

test('router.js › sub frame › not injected (mainFrameOnly)', async (t) => {
  const page = await createPage({ role: 'browse', frame: 'sub', scripts: ['router.js'] });
  t.after(() => page.close());
  assert.equal(page.loaded.includes('router.js'), false);
});

test('router.js › all scripts › routing still works with every script loaded', async (t) => {
  for (const role of ['browse', 'player']) {
    const page = await createPage({
      role,
      url: pageURL(role),
      html: '<html><head><title>YouTube</title></head><body><div id="app"></div></body></html>',
    });
    t.after(() => page.close());
    const href = role === 'browse' ? '/watch?v=jNQXAC9IVRw' : '/results?search_query=x';
    assert.equal(clickLink(page, href).prevented, true, role);
    assert.equal(page.posted('route').length, 1, role);
    checkMessages(page, `all scripts ${role}`);
  }
});
