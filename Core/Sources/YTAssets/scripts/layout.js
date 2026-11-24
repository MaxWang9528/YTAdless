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
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const root = () => document.documentElement;
    const scoped = (selector) => `html.${CONFIG.ROOT_CLASS} ${selector}`;
    const list = (selectors) => selectors.map(scoped).join(',\n');

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
      style.textContent = CSS;
      (document.head || root()).appendChild(style);
    }

    function apply() {
      const html = root();
      if (!html) return;
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

    ns.on('navigation', () => apply());

    // YouTube sets attributes on <html> (dark theme, …); put our class back if one write drops it.
    if (root() && typeof MutationObserver === 'function') {
      new MutationObserver(() => ns.guard(SOURCE, apply))
        .observe(root(), { attributes: true, attributeFilter: ['class'] });
    }

    const saved = load();
    if (saved) {
      mode = saved;
      apply();
    }
  });
})();
