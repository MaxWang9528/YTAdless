// router.js browse tabs (PLAN.md §6.2 "Browse tabs", D2): each bottom-nav tab has its own browse
// webview. A tap on another tab's pivot item or root link posts selectTab instead of letting mweb
// re-render this view; a tap on the view's own tab stays mweb's. Owner: Module B.
//
// The pivot bar markup is mweb's as recorded in router.js TABS (not in an anonymous fixture).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, readJSON, PATHS } from './harness.mjs';

const ORIGIN = 'https://m.youtube.com';

async function tabPage(t, path, options = {}) {
  const page = await createPage({
    role: options.role || 'browse',
    url: ORIGIN + path,
    scripts: ['router.js'],
    html: '<html><head><title>YouTube</title></head><body><div id="app"></div>' +
      '<ytm-pivot-bar-renderer role="tablist">' +
      '<ytm-pivot-bar-item-renderer><div class="pivot-bar-item-tab pivot-w2w" role="tab"><div class="pivot-bar-item-title">Home</div></div></ytm-pivot-bar-item-renderer>' +
      '<ytm-pivot-bar-item-renderer><div class="pivot-bar-item-tab pivot-shorts" role="tab"><div class="pivot-bar-item-title">Shorts</div></div></ytm-pivot-bar-item-renderer>' +
      '<ytm-pivot-bar-item-renderer><div class="pivot-bar-item-tab pivot-subs" role="tab"><div class="pivot-bar-item-title">Subscriptions</div></div></ytm-pivot-bar-item-renderer>' +
      '<ytm-pivot-bar-item-renderer><div class="pivot-bar-item-tab pivot-library" role="tab"><div class="pivot-bar-item-title">You</div></div></ytm-pivot-bar-item-renderer>' +
      '</ytm-pivot-bar-renderer></body></html>',
    ...options,
  });
  t.after(() => page.close());
  return page;
}

/** Taps the title inside the pivot item with `cls`; reports whether mweb's listener saw it. */
function tapItem(page, cls) {
  const { document, window } = page;
  const item = document.querySelector('.' + cls).closest('ytm-pivot-bar-item-renderer');
  let pageListenerRan = false;
  item.addEventListener('click', () => { pageListenerRan = true; });
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, composed: true, button: 0 });
  item.querySelector('.pivot-bar-item-title').dispatchEvent(event);
  return { prevented: event.defaultPrevented, pageListenerRan };
}

function tapLink(page, href) {
  const { document, window } = page;
  const a = document.createElement('a');
  a.setAttribute('href', href);
  document.getElementById('app').appendChild(a);
  const event = new window.MouseEvent('click', { bubbles: true, cancelable: true, composed: true, button: 0 });
  a.dispatchEvent(event);
  a.remove();
  return event.defaultPrevented;
}

function check(page, label) {
  for (const m of page.messages) assertMatchesVector(m, label);
  assertClean(page, label);
}

const tabsPosted = (page) => page.posted('selectTab').map((m) => m.tab);

test('router.js › browseTabs.json › tabOfPath agrees with BrowseTab (via root links from a channel page)', async (t) => {
  const { cases } = readJSON(PATHS.vectors, 'browseTabs.json');
  assert.ok(cases.length > 5);
  for (const c of cases) {
    // A page on no tab, owned by Home: a link to a tab root other than Home switches.
    const page = await tabPage(t, '/@channel');
    const href = ORIGIN + (c.path === '' ? '/' : c.path);
    const prevented = tapLink(page, href);
    const switches = c.tab !== null && c.tab !== 'home';
    if (switches) assert.equal(prevented, true, `${c.path}: defaultPrevented`);
    assert.deepEqual(tabsPosted(page), switches ? [c.tab] : [], c.path);
    check(page, c.path);
  }
});

test('router.js › home view › tapping Subscriptions posts selectTab and mweb never sees the tap', async (t) => {
  const page = await tabPage(t, '/');
  const { prevented, pageListenerRan } = tapItem(page, 'pivot-subs');
  assert.equal(prevented, true);
  assert.equal(pageListenerRan, false);
  assert.deepEqual(tabsPosted(page), ['subscriptions']);
  assert.deepEqual(page.posted('route'), []);
  check(page, 'home → subs');
});

test('router.js › home view › tapping You (pivot-library) posts selectTab you', async (t) => {
  const page = await tabPage(t, '/');
  tapItem(page, 'pivot-library');
  assert.deepEqual(tabsPosted(page), ['you']);
  check(page, 'home → you');
});

test('router.js › home view › tapping Home (its own tab) and Shorts stay mweb\'s', async (t) => {
  const page = await tabPage(t, '/');
  for (const cls of ['pivot-w2w', 'pivot-shorts']) {
    const { prevented, pageListenerRan } = tapItem(page, cls);
    assert.equal(prevented, false, cls);
    assert.equal(pageListenerRan, true, cls);
  }
  assert.deepEqual(tabsPosted(page), []);
  const logs = page.posted('log').map((m) => m.message);
  assert.ok(logs.some((m) => m.includes('pivot-shorts')), 'an unknown pivot item is logged once');
  tapItem(page, 'pivot-shorts');
  assert.equal(page.posted('log').filter((m) => m.message.includes('pivot-shorts')).length, 1, 'only once');
  check(page, 'own tab');
});

test('router.js › subscriptions view › owns Subscriptions: its own tap stays, Home switches', async (t) => {
  const page = await tabPage(t, '/feed/subscriptions');
  assert.equal(tapItem(page, 'pivot-subs').prevented, false);
  assert.equal(tapItem(page, 'pivot-w2w').prevented, true);
  assert.deepEqual(tabsPosted(page), ['home']);
  check(page, 'subs view');
});

test('router.js › subscriptions view › keeps owning Subscriptions after SPA and full loads elsewhere', async (t) => {
  const page = await tabPage(t, '/feed/subscriptions');
  page.window.history.pushState({}, '', '/@channel');
  assert.equal(page.window.sessionStorage.getItem('ytadless.tab'), 'subscriptions');
  assert.equal(tapItem(page, 'pivot-subs').prevented, false, 'own tab: back to its root is mweb\'s');
  assert.equal(tapItem(page, 'pivot-w2w').prevented, true);
  assert.deepEqual(tabsPosted(page), ['home']);
  check(page, 'subs elsewhere');
});

test('router.js › home view › a pushState onto another tab\'s root posts selectTab and goes back', async (t) => {
  const page = await tabPage(t, '/');
  let backs = 0;
  page.window.History.prototype.back = function back() { backs += 1; };
  page.window.history.pushState({}, '', '/feed/subscriptions');
  assert.deepEqual(tabsPosted(page), ['subscriptions']);
  assert.equal(backs, 1);
  page.window.history.pushState({}, '', '/');
  page.window.history.pushState({}, '', '/results?search_query=x');
  assert.deepEqual(tabsPosted(page), ['subscriptions'], 'own tab and other pages are not switches');
  assert.equal(backs, 1);
  check(page, 'history backstop');
});

test('router.js › player view › pivot taps and tab links are never selectTab', async (t) => {
  const page = await tabPage(t, '/watch?v=dQw4w9WgXcQ', { role: 'player' });
  tapItem(page, 'pivot-subs');
  assert.deepEqual(tabsPosted(page), []);
  check(page, 'player');
});
