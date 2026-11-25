// router.js tab state (PLAN.md §6.2 "Tab state"): switching between the browse view's bottom-nav
// tabs and back brings the same page back at the same scroll position. Owner: Module B.
//
// The page here plays mweb's part: a tab switch is a pushState plus a POST to /youtubei/v1/browse
// with {browseId} (in either order), whose text the page then renders. jsdom has no layout, so
// scrolling is a stub (scrollY, scrollTo, the document's scrollHeight) and the clock is fake.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, fixture } from './harness.mjs';
import { initialScriptsPage } from './ad-fixtures.mjs';

const HOME = 'https://m.youtube.com/';
const BROWSE = 'https://m.youtube.com/youtubei/v1/browse?prettyPrint=false';
const HOME_FIXTURE = 'feed/2026-11-24-browse-home.json';
const HOME_TEXT = fixture(HOME_FIXTURE);
const homeText = () => HOME_TEXT;
const page2 = (id, n = 1) => JSON.stringify({ responseContext: {}, contents: { tab: id, n } });

/** Installs a fake network under every script's fetch wrapper. Call from beforeScripts. */
function fakeNetwork(win, bodies, seen) {
  const NodeResponse = win.Response;
  win.fetch = async (input, init = {}) => {
    const url = typeof input === 'string' ? new URL(input, win.location.href).href : input.url;
    const body = init.body ?? (input && typeof input.text === 'function' ? await input.clone().text() : null);
    const parsed = body ? JSON.parse(body) : {};
    seen.push(parsed.continuation ? 'continuation' : parsed.browseId);
    const text = parsed.continuation ? JSON.stringify({ onResponseReceivedActions: [], n: seen.length })
      : typeof bodies[parsed.browseId] === 'function' ? bodies[parsed.browseId]() : bodies[parsed.browseId];
    const res = new NodeResponse(text ?? '{}', { status: text === undefined ? 404 : 200, headers: { 'content-type': 'application/json' } });
    Object.defineProperty(res, 'url', { value: url, configurable: true });
    return res;
  };
}

async function setup(t, options = {}) {
  const seen = [];
  const bodies = options.bodies || {};
  const view = { y: 0, height: options.height ?? 20000, now: 1_700_000_000_000 };
  const inline = options.initialData ? `<script>var ytInitialData = ${options.initialData};</script>` : '';
  const page = await createPage({
    role: options.role || 'browse',
    url: options.url || HOME,
    scripts: options.scripts || ['router.js'],
    html: options.html || `<html><head><title>YouTube</title>${inline}</head><body><div id="app"></div></body></html>`,
    beforeScripts(win) {
      const clamp = (y) => Math.max(0, Math.min(Number(y) || 0, view.height - win.innerHeight));
      Object.defineProperty(win, 'scrollY', { get: () => view.y, configurable: true });
      Object.defineProperty(win, 'pageYOffset', { get: () => view.y, configurable: true });
      win.scrollTo = (x, y) => {
        view.y = clamp(typeof x === 'object' && x !== null ? x.top : y);
        win.dispatchEvent(new win.Event('scroll'));
      };
      Object.defineProperty(win.Element.prototype, 'scrollHeight', {
        configurable: true,
        get() { return this === this.ownerDocument.documentElement ? view.height : 0; },
      });
      win.Date.now = () => view.now;
      fakeNetwork(win, bodies, seen);
    },
  });
  t.after(() => page.close());

  const win = page.window;
  const browse = (body, { request = false } = {}) => {
    const init = { method: 'POST', body: JSON.stringify({ context: { client: {} }, ...body }) };
    const p = request ? win.fetch(new win.Request(BROWSE, init)) : win.fetch(BROWSE, init);
    return p.then((r) => r.text());
  };
  const api = {
    page, view, seen, win,
    /** The user scrolls to `y` (sampled after the throttle). */
    async scroll(y) {
      view.y = y;
      win.dispatchEvent(new win.Event('scroll'));
      await page.flush(150);
    },
    /** A bottom-nav tap: click, then mweb resets the scroll, pushes and fetches (or fetches first). */
    async tapTab(path, browseId, { order = 'push-first', request = false } = {}) {
      win.document.body.dispatchEvent(new win.MouseEvent('click', { bubbles: true, cancelable: true }));
      view.y = 0;                                // mweb starts the new tab at the top
      win.dispatchEvent(new win.Event('scroll'));
      let text;
      if (order === 'push-first') {
        win.history.pushState({}, '', path);
        text = await browse({ browseId }, { request });
      } else {
        text = await browse({ browseId }, { request });
        win.history.pushState({}, '', path);
      }
      return text;
    },
    browse,
    async settle(ms = 1200) { await page.flush(ms); },
    check(label) {
      for (const m of page.messages) assertMatchesVector(m, label);
      assertClean(page, label);
    },
    logs() { return page.posted('log').map((m) => m.message); },
  };
  return api;
}

const HOME_ID = 'FEwhat_to_watch';
const SUBS_ID = 'FEsubscriptions';
const SUBS = '/feed/subscriptions';

for (const order of ['push-first', 'fetch-first']) {
  test(`router.js › ${HOME_FIXTURE} › Home → Subscriptions → Home serves the same Home page and restores its scroll (${order})`, async (t) => {
    let homeServed = 0;
    const s = await setup(t, { bodies: { [HOME_ID]: () => { homeServed += 1; return homeText(); }, [SUBS_ID]: page2(SUBS_ID) } });
    // The first Home page came from the network (no ytInitialData here).
    assert.equal(await s.browse({ browseId: HOME_ID }), homeText());
    await s.scroll(2400);

    assert.equal(await s.tapTab(SUBS, SUBS_ID, { order }), page2(SUBS_ID));
    await s.scroll(300);
    const back = await s.tapTab('/', HOME_ID, { order });
    assert.equal(back, homeText(), 'the same Home page comes back');
    assert.deepEqual(s.seen, [HOME_ID, SUBS_ID], 'no second Home request reached the network');
    assert.equal(homeServed, 1);
    await s.settle();
    assert.equal(s.view.y, 2400, 'Home is back where the user left it');
    assert.ok(s.logs().some((l) => l.startsWith('tab-state: FEwhat_to_watch from cache')), 'the hit is logged');
    assert.ok(s.logs().some((l) => l === 'tab-state: restored FEwhat_to_watch to 2400'));

    // And back to Subscriptions: its page and position come back too.
    assert.equal(await s.tapTab(SUBS, SUBS_ID, { order }), page2(SUBS_ID));
    assert.deepEqual(s.seen, [HOME_ID, SUBS_ID]);
    await s.settle();
    assert.equal(s.view.y, 300);
    s.check(order);
  });
}

test('router.js › home ytInitialData › the Home page the document loaded with is served when going back to Home', async (t) => {
  const initial = page2(HOME_ID, 7);
  const s = await setup(t, { initialData: initial, bodies: { [HOME_ID]: page2(HOME_ID, 99), [SUBS_ID]: page2(SUBS_ID) } });
  await s.scroll(900);
  await s.tapTab(SUBS, SUBS_ID);
  const back = await s.tapTab('/', HOME_ID);
  assert.deepEqual(JSON.parse(back), JSON.parse(initial));
  assert.deepEqual(s.seen, [SUBS_ID]);
  await s.settle();
  assert.equal(s.view.y, 900);
  s.check('initial');
});

test('router.js › synthetic feed › pull-to-refresh or a tap on the active tab goes to the network and replaces the cached page', async (t) => {
  let n = 0;
  const s = await setup(t, { bodies: { [HOME_ID]: () => page2(HOME_ID, ++n), [SUBS_ID]: page2(SUBS_ID) } });
  assert.equal(JSON.parse(await s.browse({ browseId: HOME_ID })).contents.n, 1);
  await s.scroll(1500);
  // Same tab, no navigation: a refresh.
  assert.equal(JSON.parse(await s.browse({ browseId: HOME_ID })).contents.n, 2);
  assert.deepEqual(s.seen, [HOME_ID, HOME_ID]);
  await s.scroll(0);
  await s.tapTab(SUBS, SUBS_ID);
  const back = await s.tapTab('/', HOME_ID);
  assert.equal(JSON.parse(back).contents.n, 2, 'the refreshed page is the one kept');
  await s.settle();
  assert.equal(s.view.y, 0, 'a refreshed tab starts at the top');
  s.check('refresh');
});

test('router.js › synthetic feed › a cached page older than the TTL is fetched again', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) } });
  await s.browse({ browseId: HOME_ID });
  await s.scroll(800);
  await s.tapTab(SUBS, SUBS_ID);
  s.view.now += 16 * 60 * 1000;
  await s.tapTab('/', HOME_ID);
  assert.deepEqual(s.seen, [HOME_ID, SUBS_ID, HOME_ID]);
  await s.settle();
  assert.equal(s.view.y, 0, 'no restore onto a fresh feed');
  s.check('ttl');
});

test('router.js › synthetic feed › continuation pages always go to the network and change nothing', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) } });
  await s.browse({ browseId: HOME_ID });
  await s.browse({ continuation: 'tok' });
  await s.browse({ continuation: 'tok' });
  await s.scroll(600);
  await s.tapTab(SUBS, SUBS_ID);
  await s.browse({ continuation: 'tok2' });
  await s.tapTab('/', HOME_ID);
  assert.deepEqual(s.seen, [HOME_ID, 'continuation', 'continuation', SUBS_ID, 'continuation']);
  await s.settle();
  assert.equal(s.view.y, 600);
  s.check('continuation');
});

test('router.js › synthetic feed › a browse Request object is read and served from the cache', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) } });
  await s.browse({ browseId: HOME_ID }, { request: true });
  await s.tapTab(SUBS, SUBS_ID, { request: true });
  assert.equal(await s.tapTab('/', HOME_ID, { request: true }), page2(HOME_ID));
  assert.deepEqual(s.seen, [HOME_ID, SUBS_ID]);
  s.check('request');
});

test('router.js › synthetic feed › a channel page in between is not cached, and Home still comes back', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), UCchannel: page2('UCchannel') } });
  await s.browse({ browseId: HOME_ID });
  await s.scroll(1000);
  await s.tapTab('/@channel', 'UCchannel');
  await s.browse({ browseId: 'UCchannel' });   // pull-to-refresh on the channel
  assert.deepEqual(s.seen, [HOME_ID, 'UCchannel', 'UCchannel'], 'non-tab pages are never cached');
  s.win.history.back();             // Back to Home (popstate); mweb asks for the Home page again
  await s.page.flush(10);
  assert.equal(s.win.location.href, HOME);
  await s.browse({ browseId: HOME_ID });
  assert.deepEqual(s.seen, [HOME_ID, 'UCchannel', 'UCchannel']);
  await s.settle();
  assert.equal(s.view.y, 1000);
  s.check('channel');
});

test('router.js › synthetic feed › restoring follows the feed as continuation pages grow it', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) } });
  await s.browse({ browseId: HOME_ID });
  await s.scroll(5000);
  await s.tapTab(SUBS, SUBS_ID);
  s.view.height = 2000;                 // the cached first page alone is short
  await s.tapTab('/', HOME_ID);
  await s.page.flush(250);
  assert.equal(s.view.y, 2000 - s.win.innerHeight, 'scrolled to the bottom to load more');
  s.view.height = 8000;                 // mweb appended continuation pages
  await s.settle();
  assert.equal(s.view.y, 5000);
  s.check('progressive');
});

test('router.js › synthetic feed › a touch stops the restore', async (t) => {
  const s = await setup(t, { bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) } });
  await s.browse({ browseId: HOME_ID });
  await s.scroll(5000);
  await s.tapTab(SUBS, SUBS_ID);
  s.view.height = 2000;
  await s.tapTab('/', HOME_ID);
  await s.page.flush(250);
  s.win.dispatchEvent(new s.win.Event('touchstart'));
  s.view.height = 8000;
  await s.settle();
  assert.equal(s.view.y, 2000 - s.win.innerHeight, 'left where the user took over');
  assert.ok(s.logs().some((l) => l.startsWith('tab-state: restoring FEwhat_to_watch stopped (user)')));
  s.check('touch');
});

test('router.js › synthetic feed › the player view never caches browse pages', async (t) => {
  const s = await setup(t, {
    role: 'player',
    url: 'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
    bodies: { [HOME_ID]: page2(HOME_ID), [SUBS_ID]: page2(SUBS_ID) },
  });
  await s.browse({ browseId: HOME_ID });
  await s.browse({ browseId: SUBS_ID });
  await s.browse({ browseId: HOME_ID });
  assert.deepEqual(s.seen, [HOME_ID, SUBS_ID, HOME_ID]);
  assert.deepEqual(s.page.posted('log'), []);
  s.check('player');
});

test('router.js › all browse scripts › tab caching works behind hooks.js and serves the pruned page', async (t) => {
  const s = await setup(t, {
    scripts: 'all',
    bodies: { [HOME_ID]: homeText(), [SUBS_ID]: page2(SUBS_ID) },
  });
  const first = await s.browse({ browseId: HOME_ID });
  await s.tapTab(SUBS, SUBS_ID);
  const back = await s.tapTab('/', HOME_ID);
  assert.equal(back, first, 'the cached page is the pruned page the feed got the first time');
  assert.deepEqual(s.seen, [HOME_ID, SUBS_ID]);
  s.check('all scripts');
});

test('router.js › html/2026-11-24-home-home.html › the launch Home page (inline ytInitialData, through hooks.js) is served when going back to Home', async (t) => {
  const s = await setup(t, {
    scripts: 'all',
    // Only the inline scripts that assign ytInitial* (as ad-fixtures does): the rest need a real browser.
    html: initialScriptsPage(fixture('html/2026-11-24-home-home.html')),
    bodies: { [SUBS_ID]: page2(SUBS_ID) },
  });
  await s.scroll(1800);
  await s.tapTab(SUBS, SUBS_ID);
  const back = JSON.parse(await s.tapTab('/', HOME_ID));
  assert.deepEqual(s.seen, [SUBS_ID], 'no Home request reached the network');
  assert.ok(back.contents && typeof back.contents === 'object', 'a renderable browse page');
  assert.deepEqual(Object.keys(back).sort(), Object.keys(JSON.parse(HOME_TEXT)).sort());
  assert.ok(s.logs().some((l) => /^tab-state: kept FEwhat_to_watch \(ytInitialData, \d+ KB\)$/.test(l)));
  await s.settle();
  assert.equal(s.view.y, 1800);
  s.check('launch home');
});
