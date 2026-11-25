// layout.js — owner: Module C (PLAN.md §6.3).
//
// Handles the `layout` command ({mode: 'page' | 'video'}, §5.4). `video` (docked, mini and
// landscape full screen) adds a class on <html> plus one stylesheet that hides the page chrome
// and pins the player container to the viewport, so the webview shows only the video. `page`
// (expanded, portrait) removes the class and YouTube's normal watch page is back.
//
// Opening a video is a full load (D15), and this script only runs at document end, so the mode
// is kept in sessionStorage and re-applied on load; native re-sends it after each load too.
// Re-applied on `navigation` (router.js) and when YouTube rewrites <html class>.
//
// Always on in the player view (an app-like watch view, user decisions 2026-11-24): the site's top
// bar and bottom nav are hidden, and the video sits at the top of the page and scrolls away with
// it like normal page content (mweb pins it `fixed`). The native header above the webview takes
// the top bar's place.
(() => {
  'use strict';

  const SOURCE = 'layout.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({
    MODES: ['page', 'video'],
    ROOT_CLASS: 'ytadless-layout-video',
    STYLE_ID: 'ytadless-layout-style',
    STORAGE_KEY: 'ytadless.layout',
    // `body > div#player-container-id.player-container.sticky-player` holds the player, outside
    // `ytm-app` (fixture dom/2026-11-24-watch-skeleton-dQw4w9WgXcQ.html).
    PLAYER_CONTAINER: '#player-container-id',
    // `#player.player-api.player-size`: sized 16:9 by `.player-size` padding (same fixture + its CSS).
    PLAYER: '#player-container-id #player',
    // `ytm-app#app` holds the header and the whole page below the player (same fixture). Hidden
    // with visibility, not display, so YouTube's size measurements of its placeholders still work.
    APP: 'ytm-app',
    // Top bar and bottom nav (mweb CSS in the 2026-11-24 watch capture). Inside ytm-app, but
    // hidden outright in case YouTube's CSS sets `visibility: visible` on them.
    HIDE: ['ytm-mobile-topbar-renderer', 'ytm-pivot-bar-renderer', 'ytm-header'],
    // Created by the player JS, not in the server HTML; sized with inline styles from the
    // container width (mweb 2026-11, `.html5-video-player{position:absolute;…}` in the capture).
    FILL: ['#movie_player', '.html5-video-player', '.html5-video-container'],
    VIDEO: '#player-container-id video',
    Z_INDEX: 2147483647,
    // Watch view (always on). YouTube's own `header-in-player` variant does the same offsets
    // (mweb inline CSS, watch page 2026-11-24): `.player-container.sticky-player.header-in-player{top:0}`,
    // `ytm-app.sticky-player.header-in-player{padding-top:0}`; the defaults are `top:48px` and
    // `ytm-app{padding-top:48px}`, `[has-pivot-bar=true] ytm-app{padding-bottom:48px}`.
    // Un-pinned: `.player-container.sticky-player{position:fixed;top:48px;…;z-index:2}` becomes
    // mweb's own non-sticky default `.player-container{position:absolute;top:48px;…}` (same CSS)
    // with top 0, so the video scrolls away with the page. Absolute, not static/relative: the page
    // already reserves the video's space with `ytm-app > .player-placeholder-wrapper > .player-size`
    // (fixture dom/2026-11-24-watch-skeleton-dQw4w9WgXcQ.html), so in-flow would add a second gap.
    WATCH_PLAYER_POSITION: 'absolute',
    WATCH_CLASS: 'ytadless-watch-view',
    WATCH_HIDE: ['ytm-header', 'ytm-mobile-topbar-renderer', 'ytm-pivot-bar-renderer'],
    WATCH_PLAYER: '.player-container',
    WATCH_APP: 'ytm-app',
    // mweb lays some rows out under its fixed player with `position: sticky; top: <header + video>`
    // (device, 2026-11-24: "a bar in the middle of the screen" once the video scrolls away; the
    // rules are in the external c3 CSS, not in our captures, so no selector is known). Any element
    // in ytm-app that is sticky with a top offset is un-stuck with this class; each one is logged
    // once so its selector can be pinned here later. Fixed elements are only logged.
    UNSTICK_CLASS: 'ytadless-unstuck',
    UNSTICK_MIN_TOP: 1,
    UNSTICK_SCAN_MS: 400,
    UNSTICK_MAX_NODES: 6000,
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const root = () => document.documentElement;
    const scoped = (selector) => `html.${CONFIG.ROOT_CLASS} ${selector}`;
    const list = (selectors) => selectors.map(scoped).join(',\n');

    // `video` mode's `html.<ROOT_CLASS> #player-container-id` (an ID) outranks the watch view's
    // `html.<WATCH_CLASS> .player-container`, so the mini player stays fixed full-viewport.
    const CSS = [
      `html.${CONFIG.ROOT_CLASS}, ${scoped('body')} { overflow: hidden !important; background: #000 !important; }`,
      `${scoped(CONFIG.APP)} { visibility: hidden !important; pointer-events: none !important; }`,
      `${list(CONFIG.HIDE)} { display: none !important; }`,
      `${scoped(CONFIG.PLAYER_CONTAINER)} { position: fixed !important; top: 0 !important; left: 0 !important;` +
        ' right: 0 !important; bottom: 0 !important; width: 100% !important; height: 100% !important;' +
        ' margin: 0 !important; padding: 0 !important; transform: none !important; visibility: visible !important;' +
        ` background: #000 !important; z-index: ${CONFIG.Z_INDEX} !important; }`,
      `${scoped(CONFIG.PLAYER)} { position: absolute !important; top: 0 !important; left: 0 !important;` +
        ' width: 100% !important; height: 100% !important; margin: 0 !important; padding: 0 !important; }',
      `${list(CONFIG.FILL)} { width: 100% !important; height: 100% !important; top: 0 !important; left: 0 !important; }`,
      `${scoped(CONFIG.VIDEO)} { width: 100% !important; height: 100% !important; top: 0 !important;` +
        ' left: 0 !important; object-fit: contain !important; }',
    ].join('\n');

    const watch = (selector) => `html.${CONFIG.WATCH_CLASS} ${selector}`;
    const WATCH_CSS = [
      `${CONFIG.WATCH_HIDE.map(watch).join(',\n')} { display: none !important; }`,
      `${watch(CONFIG.WATCH_PLAYER)} { position: ${CONFIG.WATCH_PLAYER_POSITION} !important; top: 0 !important; }`,
      `${watch(CONFIG.WATCH_APP)} { padding-top: 0 !important; padding-bottom: 0 !important; }`,
      `${watch('.' + CONFIG.UNSTICK_CLASS)} { position: static !important; top: auto !important; }`,
    ].join('\n');

    let mode = 'page';

    function load() {
      try {
        const saved = window.sessionStorage.getItem(CONFIG.STORAGE_KEY);
        return CONFIG.MODES.includes(saved) ? saved : null;
      } catch (_) {
        return null;  // storage blocked: native re-sends the mode anyway
      }
    }

    function save(value) {
      try { window.sessionStorage.setItem(CONFIG.STORAGE_KEY, value); } catch (_) { /* see load() */ }
    }

    function ensureStyle() {
      if (document.getElementById(CONFIG.STYLE_ID)) return;
      const style = document.createElement('style');
      style.id = CONFIG.STYLE_ID;
      style.textContent = CSS + '\n' + WATCH_CSS;
      (document.head || root()).appendChild(style);
    }

    function apply() {
      const html = root();
      if (!html) return;
      ensureStyle();
      if (!html.classList.contains(CONFIG.WATCH_CLASS)) html.classList.add(CONFIG.WATCH_CLASS);
      if (mode === 'video') {
        ensureStyle();
        if (!html.classList.contains(CONFIG.ROOT_CLASS)) html.classList.add(CONFIG.ROOT_CLASS);
      } else if (html.classList.contains(CONFIG.ROOT_CLASS)) {
        html.classList.remove(CONFIG.ROOT_CLASS);
      }
    }

    function setMode(next) {
      const changed = next !== mode;
      mode = next;
      save(next);
      apply();
      if (changed) ns.log('debug', SOURCE, 'layout', next);
    }

    ns.command('layout', (args) => {
      const next = args.mode;
      if (!CONFIG.MODES.includes(next)) return { error: `invalid-mode: ${String(next)}` };
      setMode(next);
      return { ok: true, mode };
    });

    // MARK: un-stick rows that were laid out under the fixed player

    const reported = new Set();
    const describe = (el) => el.localName + (el.id ? `#${el.id}` : '')
      + [...el.classList].filter((c) => c !== CONFIG.UNSTICK_CLASS).slice(0, 3).map((c) => `.${c}`).join('');

    function unstick() {
      if (mode !== 'page' || typeof window.getComputedStyle !== 'function') return;
      const app = document.querySelector(CONFIG.WATCH_APP);
      if (!app) return;
      const nodes = app.getElementsByTagName('*');
      const count = Math.min(nodes.length, CONFIG.UNSTICK_MAX_NODES);
      for (let i = 0; i < count; i++) {
        const el = nodes[i];
        if (el.classList.contains(CONFIG.UNSTICK_CLASS)) continue;
        const style = window.getComputedStyle(el);
        const position = style.position;
        if (position !== 'sticky' && position !== '-webkit-sticky' && position !== 'fixed') continue;
        if (style.display === 'none') continue;
        const top = parseFloat(style.top);
        const name = describe(el);
        if (position === 'fixed') {
          if (!reported.has('fixed ' + name)) { reported.add('fixed ' + name); ns.log('debug', SOURCE, 'fixed in watch view', name, `top=${style.top}`); }
          continue;
        }
        if (!(top >= CONFIG.UNSTICK_MIN_TOP)) continue;
        el.classList.add(CONFIG.UNSTICK_CLASS);
        if (!reported.has(name)) { reported.add(name); ns.log('info', SOURCE, 'unstuck', name, `top=${style.top}`); }
      }
    }

    let scanTimer = null;
    function scheduleUnstick() {
      if (scanTimer !== null) return;
      scanTimer = setTimeout(() => ns.guard(SOURCE, () => { scanTimer = null; unstick(); }), CONFIG.UNSTICK_SCAN_MS);
    }

    window.addEventListener('scroll', () => ns.guard(SOURCE, scheduleUnstick), { passive: true });
    if (typeof MutationObserver === 'function') {
      const observeApp = () => {
        const app = document.querySelector(CONFIG.WATCH_APP);
        if (!app) return false;
        new MutationObserver(() => ns.guard(SOURCE, scheduleUnstick)).observe(app, { childList: true, subtree: true });
        return true;
      };
      if (!observeApp()) document.addEventListener('DOMContentLoaded', () => ns.guard(SOURCE, observeApp), { once: true });
    }

    ns.on('navigation', () => { apply(); scheduleUnstick(); });

    // YouTube sets attributes on <html> (dark theme, …); put our class back if one write drops it.
    if (root() && typeof MutationObserver === 'function') {
      new MutationObserver(() => ns.guard(SOURCE, apply))
        .observe(root(), { attributes: true, attributeFilter: ['class'] });
    }

    const saved = load();
    if (saved) mode = saved;
    apply();
    scheduleUnstick();
  });
})();
