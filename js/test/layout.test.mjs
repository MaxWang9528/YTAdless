// layout.js (PLAN.md §6.3). Owner: Module C.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector, fixture, commandVectors } from './harness.mjs';

const WATCH = 'https://m.youtube.com/watch?v=dQw4w9WgXcQ';
const FIXTURE = '2026-11-24-watch-skeleton-dQw4w9WgXcQ.html';
const SKELETON = fixture('dom', FIXTURE);
const ROOT_CLASS = 'ytadless-layout-video';
const STYLE_ID = 'ytadless-layout-style';
const STORAGE_KEY = 'ytadless.layout';

// What the player JS adds after load (not in the server HTML): mweb 2026-11.
function hydrate(document) {
  const player = document.getElementById('player');
  player.innerHTML = '<div id="movie_player" class="html5-video-player"><div class="html5-video-container">'
    + '<video class="html5-main-video" style="width: 393px; height: 221px; left: 0px; top: 0px;"></video></div></div>';
  const app = document.querySelector('ytm-app');
  app.insertAdjacentHTML('afterbegin', '<ytm-mobile-topbar-renderer></ytm-mobile-topbar-renderer>');
  app.insertAdjacentHTML('beforeend', '<ytm-pivot-bar-renderer></ytm-pivot-bar-renderer>');
}

async function layoutPage(t, options = {}) {
  const page = await createPage({ role: 'player', url: WATCH, scripts: ['layout.js'], html: SKELETON, ...options });
  t.after(() => page.close());
  hydrate(page.document);
  return page;
}

const isVideo = (page) => page.document.documentElement.classList.contains(ROOT_CLASS);
const styles = (page) => page.document.querySelectorAll(`#${STYLE_ID}`);

function assertAllMatchVectors(page) {
  for (const message of page.messages) assertMatchesVector(message, message.type);
}

const WATCH_CLASS = 'ytadless-watch-view';
const isWatchView = (page) => page.document.documentElement.classList.contains(WATCH_CLASS);

test(`layout.js › ${FIXTURE} › starts in page layout with the app-like watch view on`, async (t) => {
  const page = await layoutPage(t);
  assert.equal(isVideo(page), false);
  assert.equal(isWatchView(page), true, 'top bar and bottom nav hidden from the start');
  assert.equal(styles(page).length, 1);
  assertClean(page, 'load');
});

test(`layout.js › ${FIXTURE} › the watch view hides the site's top bar and bottom nav and puts the player at the top`, async (t) => {
  const page = await layoutPage(t);
  const css = styles(page)[0].textContent;
  for (const selector of ['ytm-header', 'ytm-mobile-topbar-renderer', 'ytm-pivot-bar-renderer']) {
    assert.ok(page.document.querySelector(`html.${WATCH_CLASS} ${selector}`), `${selector} is targeted and present`);
    assert.match(css, new RegExp(`html\\.${WATCH_CLASS} ${selector}[^{]*\\{[^}]*display: none`));
  }
  assert.match(css, new RegExp(`html\\.${WATCH_CLASS} \\.player-container \\{ position: absolute !important; top: 0`));
  assert.match(css, new RegExp(`html\\.${WATCH_CLASS} ytm-app \\{ padding-top: 0`));
  // Kept in both page layouts.
  await page.cmd('layout', { mode: 'video' });
  await page.cmd('layout', { mode: 'page' });
  assert.equal(isWatchView(page), true);
  assertClean(page, 'watch view');
});

// mweb's own rules for the player (inline CSS of the 2026-11-24 watch capture); the skeleton
// fixture has its <style> elements removed.
const MWEB_PLAYER_CSS = '.player-container{position:absolute;top:48px;left:0;right:0;overflow:hidden;z-index:2}'
  + '.player-container.sticky-player{position:fixed;top:48px;left:0;right:0;overflow:hidden;z-index:2}'
  + 'ytm-app.sticky-player{display:block;padding-top:48px}';

test(`layout.js › ${FIXTURE} › the watch view un-pins the sticky player so it scrolls away with the page`, async (t) => {
  const page = await layoutPage(t);
  const { document, window } = page;
  const mweb = document.createElement('style');
  mweb.textContent = MWEB_PLAYER_CSS;
  document.head.insertBefore(mweb, document.head.firstChild);
  const css = (selector) => window.getComputedStyle(document.querySelector(selector));
  assert.ok(document.querySelector('#player-container-id').classList.contains('sticky-player'));

  // page: out of flow at the document top (over YouTube's placeholder), not fixed to the viewport.
  assert.equal(css('#player-container-id').position, 'absolute');
  assert.equal(css('#player-container-id').top, '0px');
  assert.equal(css('ytm-app').paddingTop, '0px');
  assert.ok(document.querySelector('ytm-app > .player-placeholder-wrapper > .player-size'),
    'the page still reserves the video space, so absolute leaves no gap and no overlap');

  // video (mini player, landscape): still pinned full-viewport, the watch class notwithstanding.
  await page.cmd('layout', { mode: 'video' });
  assert.equal(isWatchView(page), true);
  assert.equal(css('#player-container-id').position, 'fixed');
  assert.equal(css('#player-container-id').height, '100%');

  await page.cmd('layout', { mode: 'page' });
  assert.equal(css('#player-container-id').position, 'absolute');
  assert.equal(css('#player-container-id').top, '0px');
  assertClean(page, 'un-pinned');
});

test(`layout.js › ${FIXTURE} › video adds the class and one stylesheet; page removes the class`, async (t) => {
  const page = await layoutPage(t);
  assert.deepEqual(await page.cmd('layout', { mode: 'video' }), { ok: true, mode: 'video' });
  assert.equal(isVideo(page), true);
  assert.equal(styles(page).length, 1);
  assert.equal(styles(page)[0].parentNode, page.document.head);

  assert.deepEqual(await page.cmd('layout', { mode: 'video' }), { ok: true, mode: 'video' });
  assert.equal(styles(page).length, 1, 'stylesheet is injected once');

  assert.deepEqual(await page.cmd('layout', { mode: 'page' }), { ok: true, mode: 'page' });
  assert.equal(isVideo(page), false);
  await page.cmd('layout', { mode: 'video' });
  assert.equal(styles(page).length, 1);
  assertClean(page, 'after commands');
  assertAllMatchVectors(page);
});

test(`layout.js › ${FIXTURE} › video hides the app and chrome and pins the player`, async (t) => {
  const page = await layoutPage(t);
  const { document, window } = page;
  const css = (selector) => window.getComputedStyle(document.querySelector(selector));
  assert.notEqual(css('ytm-app').visibility, 'hidden');
  assert.equal(css('#player-container-id').position, 'absolute');

  await page.cmd('layout', { mode: 'video' });
  assert.equal(css('ytm-app').visibility, 'hidden');
  assert.equal(css('ytm-app').pointerEvents, 'none');
  for (const selector of ['ytm-mobile-topbar-renderer', 'ytm-pivot-bar-renderer', 'ytm-header']) {
    assert.equal(css(selector).display, 'none', selector);
  }
  const container = css('#player-container-id');
  assert.equal(container.position, 'fixed');
  assert.equal(container.top, '0px');
  assert.equal(container.height, '100%');
  assert.equal(container.visibility, 'visible');
  assert.equal(css('#player').height, '100%');
  assert.equal(css('#player').paddingTop, '0px');
  // !important beats the player's inline size.
  assert.equal(css('video').width, '100%');
  assert.equal(css('video').objectFit, 'contain');

  await page.cmd('layout', { mode: 'page' });
  assert.equal(css('#player-container-id').position, 'absolute');
  assert.notEqual(css('ytm-app').visibility, 'hidden');
});

test(`layout.js › ${FIXTURE} › every stylesheet selector is valid and matches the fixture`, async (t) => {
  const page = await layoutPage(t);
  await page.cmd('layout', { mode: 'video' });
  const sheet = styles(page)[0].sheet;
  assert.ok(sheet.cssRules.length >= 6);
  for (const rule of sheet.cssRules) {
    for (const selector of rule.selectorText.split(',').map((s) => s.trim())) {
      // Added at runtime to rows mweb makes sticky (tested below); the fixture has none.
      if (selector.includes('ytadless-unstuck')) continue;
      let matches;
      assert.doesNotThrow(() => { matches = page.document.querySelectorAll(selector); }, selector);
      assert.ok(matches.length > 0, `${selector} matches the hydrated fixture`);
    }
  }
});

test(`layout.js › ${FIXTURE} › rejects an unknown mode without a scriptError and keeps the current one`, async (t) => {
  const page = await layoutPage(t);
  await page.cmd('layout', { mode: 'video' });
  assert.deepEqual(await page.cmd('layout', { mode: 'tiny' }), { error: 'invalid-mode: tiny' });
  assert.deepEqual(await page.cmd('layout', {}), { error: 'invalid-mode: undefined' });
  assert.equal(isVideo(page), true);
  assertClean(page, 'bad args');
});

test(`layout.js › ${FIXTURE} › the commands.json vector works as sent by native`, async (t) => {
  const page = await layoutPage(t);
  const vector = commandVectors().commands.find((c) => c.name === 'layout');
  assert.equal(vector.handler, 'layout.js');
  assert.deepEqual(await page.cmd(vector.name, vector.args), { ok: true, mode: vector.args.mode });
});

test(`layout.js › ${FIXTURE} › the mode survives a full load through sessionStorage`, async (t) => {
  const first = await layoutPage(t);
  await first.cmd('layout', { mode: 'video' });
  assert.equal(first.window.sessionStorage.getItem(STORAGE_KEY), 'video');

  // A new document in the same tab: storage carries over, the script re-applies at document end.
  const second = await layoutPage(t, {
    beforeScripts: (win) => win.sessionStorage.setItem(STORAGE_KEY, 'video'),
  });
  assert.equal(isVideo(second), true);
  assert.equal(styles(second).length, 1);

  const third = await layoutPage(t, {
    beforeScripts: (win) => win.sessionStorage.setItem(STORAGE_KEY, 'page'),
  });
  assert.equal(isVideo(third), false);
  assertClean(second, 'restored');
  assertClean(third, 'restored page');
});

test(`layout.js › ${FIXTURE} › ignores junk in sessionStorage and survives blocked storage`, async (t) => {
  const junk = await layoutPage(t, { beforeScripts: (win) => win.sessionStorage.setItem(STORAGE_KEY, '<b>') });
  assert.equal(isVideo(junk), false);
  assertClean(junk, 'junk');

  const blocked = await layoutPage(t, {
    beforeScripts: (win) => {
      Object.defineProperty(win, 'sessionStorage', { configurable: true, get() { throw new win.DOMException('denied', 'SecurityError'); } });
    },
  });
  assert.deepEqual(await blocked.cmd('layout', { mode: 'video' }), { ok: true, mode: 'video' });
  assert.equal(isVideo(blocked), true);
  assertClean(blocked, 'blocked storage');
});

test(`layout.js › ${FIXTURE} › re-applies after YouTube rewrites <html class> and on navigation`, async (t) => {
  const page = await layoutPage(t);
  await page.cmd('layout', { mode: 'video' });
  page.document.documentElement.className = 'something-else';
  await page.flush();  // MutationObserver
  assert.equal(isVideo(page), true);
  assert.ok(page.document.documentElement.classList.contains('something-else'));

  // Drop the stylesheet, then fire the event router.js emits on an SPA URL change.
  page.document.getElementById(STYLE_ID).remove();
  page.window.__ytadless.emit('navigation', { url: WATCH });
  assert.equal(styles(page).length, 1, 'stylesheet restored on navigation');
  assertClean(page, 'reapply');
});

test('layout.js › bare page › loads and handles the command with no player DOM', async (t) => {
  const page = await createPage({ role: 'player', url: WATCH, scripts: ['layout.js'] });
  t.after(() => page.close());
  assert.deepEqual(await page.cmd('layout', { mode: 'video' }), { ok: true, mode: 'video' });
  assert.equal(isVideo(page), true);
  assertClean(page, 'bare');
});

test('layout.js › all scripts › works alongside every other player script', async (t) => {
  const page = await createPage({ role: 'player', url: WATCH, html: SKELETON });
  t.after(() => page.close());
  assert.deepEqual(await page.cmd('layout', { mode: 'video' }), { ok: true, mode: 'video' });
  assert.equal(isVideo(page), true);
  assertClean(page, 'all scripts');
  assertAllMatchVectors(page);
});

test(`layout.js › ${FIXTURE} › un-sticks rows mweb laid out under its fixed player, leaves the rest`, async (t) => {
  const page = await layoutPage(t);
  const { document, window } = page;
  const app = document.querySelector('ytm-app');
  // mweb-style: a chip row stuck just below the (formerly fixed) 16:9 video.
  const style = document.createElement('style');
  style.textContent = '.test-stuck-row { position: sticky; top: 221px; } .test-top-row { position: sticky; top: 0px; }'
    + ' .test-fixed { position: fixed; top: 300px; }';
  document.head.appendChild(style);
  app.insertAdjacentHTML('beforeend', '<div class="test-stuck-row"></div><div class="test-top-row"></div><div class="test-fixed"></div>');
  window.dispatchEvent(new window.Event('scroll'));
  await new Promise((resolve) => setTimeout(resolve, 500));
  const css = (selector) => window.getComputedStyle(document.querySelector(selector));
  assert.equal(css('.test-stuck-row').position, 'static', 'the stuck row scrolls with the page');
  assert.equal(css('.test-top-row').position, 'sticky', 'a row stuck at top 0 is left alone');
  assert.equal(css('.test-fixed').position, 'fixed', 'fixed elements (panels, dialogs) are only logged');
  assert.ok(page.messages.some((m) => m.type === 'log' && String(m.message ?? JSON.stringify(m)).includes('unstuck')), 'logged once');

  // Video mode (mini player, landscape) doesn't scan.
  await page.cmd('layout', { mode: 'video' });
  app.insertAdjacentHTML('beforeend', '<div class="test-stuck-row" id="later"></div>');
  window.dispatchEvent(new window.Event('scroll'));
  await new Promise((resolve) => setTimeout(resolve, 500));
  assert.equal(document.getElementById('later').classList.contains('ytadless-unstuck'), false);
  assertClean(page, 'unstick');
});
