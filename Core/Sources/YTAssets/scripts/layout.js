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
//
// Collapsed bar (user request 2026-11-25): once the page is scrolled so the video would leave the
// top, the player container is pinned `fixed` at the top as a short bar (small 16:9 video at the
// left, title and play/pause at the right) and the page scrolls beneath it; scrolling back up
// restores the full-width video. CSS only plus one bar element inside the container: the video
// element is never moved, so it doesn't pause or reload (D2).
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
    // "A large nav bar with video categories in the middle of the screen" when scrolling (device,
    // 2026-11-25). mweb c3 CSS (ytmweb.c3_base, fetched 2026-11-25): `ytm-related-chip-cloud-renderer
    // {position:sticky;top:calc(56.25vw + 96px);height:0;opacity:0;…}`, mweb's JS adds
    // `.chips-visible{opacity:1;top:96px;transform:translateY(-48px)}` and
    // `.chips-fixed-positioning{position:fixed}` on scroll. Its offsets assume the fixed top bar and
    // fixed player the watch view removes, and with height 0 even an un-stuck copy paints over the
    // page, so it is hidden. `.related-chips-slot-wrapper.slot-open{transform:translateY(-48px)}`
    // (same CSS) shifts the list up while the chips show; neutralised so nothing jumps.
    WATCH_HIDE_CHIPS: ['ytm-related-chip-cloud-renderer'],
    WATCH_CHIPS_SLOT: '.related-chips-slot-wrapper',
    // Comments / description panels. mweb CSS (ytmweb c3_base, fetched 2026-11-25), portrait:
    // `ytm-engagement-panel{position:fixed;…;top:calc(56.25vw + 48px)}`, i.e. under its 48px top
    // bar and the video. The watch view has no top bar, so the panel sits at the video's bottom.
    // `.engagement-panel-section-list-background.at-top{overflow-y:auto}`: the list only scrolls
    // once mweb's drag code adds `at-top`, which with our geometry happened only after nudging the
    // drag handle (device, 2026-11-25: "can't scroll comments until I jiggle the pull-down bar").
    WATCH_PANEL: 'ytm-engagement-panel:not(.is-shorts-style):not(.force-fullscreen)',
    WATCH_PANEL_TOP: '56.25vw',
    WATCH_PANEL_SCROLLERS: ['.engagement-panel-section-list-background', '.engagement-panel-content-wrapper'],
    // Collapsed bar. Height in CSS px; the video in it is 16:9 at that height. Collapses once the
    // page has scrolled so less than COLLAPSED_HEIGHT of the video would be left on screen, and
    // expands again HYSTERESIS px earlier so a small scroll back doesn't flicker it.
    COLLAPSE_CLASS: 'ytadless-watch-collapsed',
    COLLAPSED_HEIGHT: 64,
    COLLAPSE_HYSTERESIS: 24,
    // The space mweb reserves for the video in the page (fixture dom/2026-11-24-watch-skeleton…);
    // its height is the expanded video's height. Fallback: `.player-size{padding-bottom:56.25%}`.
    VIDEO_PLACEHOLDER: '.player-placeholder-wrapper .player-size',
    VIDEO_ASPECT: 9 / 16,
    BAR_ID: 'ytadless-collapsed-bar',
    // Covers the player while collapsed (fixture: siblings of #player in #player-container-id).
    COLLAPSED_HIDE: ['#player-control-container', '#player-thumbnail-overlay', '#player-endscreen-container'],
    // `#movie_player` exposes playVideo/pauseVideo (YouTube iframe/player API); the <video> is the fallback.
    MOVIE_PLAYER: '#movie_player',
    // mweb sets document.title to "<video title> - YouTube" (watch capture 2026-11-24).
    TITLE_SUFFIX: / - YouTube$/,
    BAR_Z_INDEX: 2147483000,
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
      `${CONFIG.WATCH_HIDE_CHIPS.map(watch).join(',\n')} { display: none !important; }`,
      `${watch(CONFIG.WATCH_CHIPS_SLOT)} { transform: none !important; }`,
      `${watch(CONFIG.WATCH_PANEL)} { top: ${CONFIG.WATCH_PANEL_TOP} !important; }`,
      `${CONFIG.WATCH_PANEL_SCROLLERS.map(watch).join(',\n')} { overflow-y: auto !important;` +
        ' -webkit-overflow-scrolling: touch !important; overscroll-behavior: contain !important; }',
    ].join('\n');

    // Collapsed bar. Scoped to page mode (`:not(.<ROOT_CLASS>)`): video mode's full-viewport rules
    // must win, and these selectors would otherwise outrank its ID selectors.
    const H = CONFIG.COLLAPSED_HEIGHT;
    const W = Math.round(H / CONFIG.VIDEO_ASPECT);
    const collapsed = (selector) => `html.${CONFIG.WATCH_CLASS}.${CONFIG.COLLAPSE_CLASS}:not(.${CONFIG.ROOT_CLASS}) ${selector}`;
    const bar = `#${CONFIG.BAR_ID}`;
    const COLLAPSE_CSS = [
      `${collapsed(CONFIG.PLAYER_CONTAINER)} { position: fixed !important; top: 0 !important; left: 0 !important;` +
        ` right: 0 !important; width: 100% !important; height: ${H}px !important; margin: 0 !important;` +
        ` padding: 0 !important; transform: none !important; z-index: ${CONFIG.BAR_Z_INDEX} !important;` +
        ' background: #fff !important; box-shadow: 0 1px 0 rgba(0, 0, 0, 0.1) !important; }',
      `${collapsed(CONFIG.PLAYER)} { position: absolute !important; top: 0 !important; left: 0 !important;` +
        ` width: ${W}px !important; height: ${H}px !important; margin: 0 !important; padding: 0 !important; }`,
      `${CONFIG.FILL.map(collapsed).join(',\n')} { width: 100% !important; height: 100% !important; top: 0 !important; left: 0 !important; }`,
      `${collapsed(CONFIG.VIDEO)} { width: 100% !important; height: 100% !important; top: 0 !important;` +
        ' left: 0 !important; object-fit: contain !important; background: #000 !important; }',
      `${CONFIG.COLLAPSED_HIDE.map(collapsed).join(',\n')} { display: none !important; }`,
      `${bar} { display: none; }`,
      `${collapsed(bar)} { display: flex !important; position: absolute; top: 0; left: 0; right: 0; height: ${H}px;` +
        ` align-items: center; z-index: 1; color: #0f0f0f; font: 500 14px/18px Roboto, Arial, sans-serif; }`,
      `${bar} .ytadless-bar-expand { flex: none; width: ${W}px; height: ${H}px; }`,
      `${bar} .ytadless-bar-title { flex: 1; min-width: 0; height: ${H}px; padding: 0 8px 0 12px; display: flex; align-items: center; }`,
      `${bar} .ytadless-bar-title span { overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }`,
      `${bar} .ytadless-bar-play { flex: none; width: 48px; height: ${H}px; margin-right: 4px; border: 0; padding: 0;` +
        ' background: transparent; color: inherit; font-size: 22px; line-height: 1; }',
      // mweb dark theme (`<html dark>`) and the system appearance (Settings › Appearance).
      `html[dark] ${collapsed(CONFIG.PLAYER_CONTAINER)} { background: #0f0f0f !important; box-shadow: 0 1px 0 rgba(255, 255, 255, 0.1) !important; }`,
      `html[dark] ${collapsed(bar)} { color: #f1f1f1; }`,
      '@media (prefers-color-scheme: dark) {',
      `  ${collapsed(CONFIG.PLAYER_CONTAINER)} { background: #0f0f0f !important; box-shadow: 0 1px 0 rgba(255, 255, 255, 0.1) !important; }`,
      `  ${collapsed(bar)} { color: #f1f1f1; }`,
      '}',
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
      style.textContent = CSS + '\n' + WATCH_CSS + '\n' + COLLAPSE_CSS;
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
      updateCollapse();
    }

    // MARK: collapsed bar

    let isCollapsed = false;

    function videoHeight() {
      const placeholder = document.querySelector(CONFIG.VIDEO_PLACEHOLDER);
      const measured = placeholder ? placeholder.getBoundingClientRect().height : 0;
      return measured > 0 ? measured : (window.innerWidth || 0) * CONFIG.VIDEO_ASPECT;
    }

    // Collapse once less than COLLAPSED_HEIGHT of the video is left on screen; expand HYSTERESIS
    // earlier. Never in video mode (mini player / landscape) or on a page without a player.
    function shouldCollapse() {
      if (mode !== 'page' || !document.querySelector(CONFIG.PLAYER_CONTAINER)) return false;
      const height = videoHeight();
      if (!(height > CONFIG.COLLAPSED_HEIGHT)) return false;
      const at = height - CONFIG.COLLAPSED_HEIGHT;
      const y = window.scrollY || 0;
      return isCollapsed ? y > at - CONFIG.COLLAPSE_HYSTERESIS : y >= at;
    }

    function updateCollapse() {
      const html = root();
      if (!html) return;
      const next = shouldCollapse();
      if (next) ensureBar();
      if (next !== isCollapsed) {
        isCollapsed = next;
        ns.log('debug', SOURCE, next ? 'collapsed' : 'expanded');
      }
      if (next) {
        refreshBar();
        if (!html.classList.contains(CONFIG.COLLAPSE_CLASS)) html.classList.add(CONFIG.COLLAPSE_CLASS);
      } else if (html.classList.contains(CONFIG.COLLAPSE_CLASS)) {
        html.classList.remove(CONFIG.COLLAPSE_CLASS);
      }
    }

    const PLAY = '▶';   // ▶
    const PAUSE = '❚❚';  // ❚❚

    function video() { return document.querySelector(CONFIG.VIDEO); }

    function refreshBar() {
      const el = document.getElementById(CONFIG.BAR_ID);
      if (!el) return;
      const title = String(document.title || '').replace(CONFIG.TITLE_SUFFIX, '').trim();
      const span = el.querySelector('.ytadless-bar-title span');
      if (span && span.textContent !== title) span.textContent = title;
      const v = video();
      const button = el.querySelector('.ytadless-bar-play');
      const playing = !!v && !v.paused;
      if (button) {
        const label = playing ? PAUSE : PLAY;
        if (button.textContent !== label) button.textContent = label;
        button.setAttribute('aria-label', playing ? 'Pause' : 'Play');
      }
    }

    function expand() {
      try {
        window.scrollTo({ top: 0, behavior: 'smooth' });
      } catch (_) {
        window.scrollTo(0, 0);
      }
    }

    // A real tap: player-bridge.js sees play()/pause() inside the gesture and emits userIntent.
    function togglePlay() {
      const v = video();
      if (!v) return;
      const player = document.querySelector(CONFIG.MOVIE_PLAYER);
      if (v.paused) {
        if (player && typeof player.playVideo === 'function') player.playVideo();
        else Promise.resolve(v.play()).catch(() => {});
      } else if (player && typeof player.pauseVideo === 'function') {
        player.pauseVideo();
      } else {
        v.pause();
      }
      refreshBar();
    }

    function ensureBar() {
      const existing = document.getElementById(CONFIG.BAR_ID);
      if (existing) return existing;
      const container = document.querySelector(CONFIG.PLAYER_CONTAINER);
      if (!container) return null;
      const el = document.createElement('div');
      el.id = CONFIG.BAR_ID;
      const expandArea = document.createElement('div');
      expandArea.className = 'ytadless-bar-expand';
      const title = document.createElement('div');
      title.className = 'ytadless-bar-title';
      title.appendChild(document.createElement('span'));
      const button = document.createElement('button');
      button.className = 'ytadless-bar-play';
      button.type = 'button';
      el.append(expandArea, title, button);
      const onExpand = (e) => ns.guard(SOURCE, () => { e.preventDefault(); e.stopPropagation(); expand(); });
      expandArea.addEventListener('click', onExpand);
      title.addEventListener('click', onExpand);
      button.addEventListener('click', (e) => ns.guard(SOURCE, () => { e.preventDefault(); e.stopPropagation(); togglePlay(); }));
      container.appendChild(el);
      return el;
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

    window.addEventListener('scroll', () => ns.guard(SOURCE, () => { updateCollapse(); scheduleUnstick(); }), { passive: true });
    window.addEventListener('resize', () => ns.guard(SOURCE, updateCollapse), { passive: true });
    // Media events don't bubble; capture them at the document to keep the bar's button current.
    for (const type of ['play', 'playing', 'pause', 'ended']) {
      document.addEventListener(type, () => ns.guard(SOURCE, () => { if (isCollapsed) refreshBar(); }), true);
    }
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
