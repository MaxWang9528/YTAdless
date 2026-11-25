// router.js — owner: Module B (PLAN.md §6.2).
//
// Keeps each webview on its side of the split: the browse view never opens a video, and the
// player view never shows a non-video YouTube page. Three entry points, all in the main frame:
//   click capture   a tap on <a href> that should leave this view: preventDefault +
//                   stopImmediatePropagation, then post route{trigger:'click'}
//   history hook    pushState/replaceState/popstate: post pageChanged and emit `navigation` on every
//                   URL change; a pushState that should have left this view (a tap that slipped
//                   past click capture) posts route{trigger:'history'}, and native goes back
//   window.open     a URL that should leave this view posts route{trigger:'windowOpen'}, returns null
// Browse only, tab state (PLAN.md §6.2 "Tab state"): mweb's bottom-nav tabs (Home, Subscriptions,
// You) are SPA pushes that each fetch a fresh /youtubei/v1/browse page, so going back to a tab
// shows a new feed at the top. A fetch wrapper (outside hooks.js's, so it sees pruned responses)
// keeps each tab's first browse page in memory and serves it again when the user switches back
// to that tab within TAB_STATE.CACHE_TTL_MS; the tab's scroll position is then restored. A browse
// fetch for the tab already on screen (pull-to-refresh, tapping the active tab) always goes to the
// network and replaces the cached page.
// Native makes the real decision with Router.decide (YTCore). This file only needs to know
// whether a URL leaves the view, and `leaves()` mirrors Router.classify/decide: both are checked
// against TestVectors/routing.json. A rule added here needs the same rule in Router.swift.
(() => {
  'use strict';

  const SOURCE = 'router.js';
  const CONFIG = Object.freeze({
    // = Router.youtubeHosts / shortLinkHost (PLAN.md §6.2)
    YOUTUBE_HOSTS: ['youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be'],
    SHORT_LINK_HOST: 'youtu.be',
    // = Router.signInHosts. Provisional until spike S-B1 (Google sign-in) settles the list.
    SIGN_IN_HOSTS: ['accounts.google.com', 'accounts.youtube.com', 'consent.youtube.com'],
    // = Router.inPlaceSchemes. YouTube uses javascript: hrefs on buttons; never intercept them.
    IN_PLACE_PROTOCOLS: ['about:', 'javascript:', 'blob:', 'data:'],
    WEB_PROTOCOLS: ['http:', 'https:'],
    REDIRECT_PATH: '/redirect',                     // youtube.com/redirect?q=<external URL>
    VIDEO_ID: /^[A-Za-z0-9_-]{11}$/,                // = Router.isVideoID
    VIDEO_PATH: /^\/(?:shorts|live)\/[A-Za-z0-9_-]{11}\/?$/,   // /shorts/ID, /live/ID
    WATCH_PATH: '/watch',
    ANCHOR_TAG: 'a',
  });

  // Browse-view tab state. Everything mweb can change about it lives here.
  const TAB_STATE = Object.freeze({
    // Tab path → browseId the page asks /youtubei/v1/browse for. FEwhat_to_watch: home fixture
    // (feed/2026-11-24-browse-home.json, html/2026-11-24-home-home.html). The others are mweb's
    // pivot-bar browseEndpoints (not in an anonymous fixture; check on device via the Debug log).
    TABS: {
      '/': 'FEwhat_to_watch',
      '/feed/subscriptions': 'FEsubscriptions',
      '/feed/library': 'FElibrary',
      '/feed/you': 'FEyou',
      '/feed/history': 'FEhistory',
    },
    BROWSE_URL: /\/youtubei\/v1\/browse(?:[?#]|$)/,   // innertube browse (hooks.js INTERCEPT_URLS)
    CACHE_TTL_MS: 15 * 60 * 1000,      // older pages are fetched fresh again
    CACHE_MAX_ENTRIES: 6,
    CACHE_MAX_CHARS: 8_000_000,        // a home page is ~0.3 MB (feed/2026-11-24-browse-home.json)
    CONTENT_MARKER: '"contents"',      // a renderable browse page has top-level `contents`
    RESPONSE_HEADERS: { 'content-type': 'application/json; charset=UTF-8' },
    SCROLL_SAMPLE_MS: 100,             // scroll position sampling (trailing throttle)
    TAP_SNAPSHOT_MS: 1500,             // a tap's scroll snapshot wins over later samples this long
    NAV_SETTLE_MS: 2500,               // after a push to a tab with no browse fetch, it is on screen
    RESTORE_MIN_Y: 8,                  // positions this close to the top are not restored
    RESTORE_INTERVAL_MS: 100,
    RESTORE_TIMEOUT_MS: 5000,          // continuation pages load while we scroll toward the target
    RESTORE_RECHECK_MS: 400,           // re-apply once if the page jumps back to the top after
    RESTORE_TOLERANCE_PX: 4,
    CANCEL_EVENTS: ['touchstart', 'wheel'],   // the user takes over
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const role = ns.config.role;
    const reflectApply = Reflect.apply;

    // ── Classifier (mirrors Router.swift) ───────────────────────────────────────────────────

    function isVideoLink(path, params) {
      if (path === CONFIG.WATCH_PATH) {
        const v = params.get('v');
        return typeof v === 'string' && CONFIG.VIDEO_ID.test(v);
      }
      return CONFIG.VIDEO_PATH.test(path);
    }

    /** True when `url` (a URL object) should not load in this view. */
    function leaves(url) {
      const protocol = url.protocol.toLowerCase();
      if (CONFIG.IN_PLACE_PROTOCOLS.includes(protocol)) return false;
      if (!CONFIG.WEB_PROTOCOLS.includes(protocol)) return true;         // mailto:, tel:, app links
      const host = url.hostname.toLowerCase();
      if (host === '') return false;
      if (CONFIG.SIGN_IN_HOSTS.includes(host)) return false;
      if (!CONFIG.YOUTUBE_HOSTS.includes(host)) return true;            // another site
      let path = url.pathname;
      let params = url.searchParams;
      if (host === CONFIG.SHORT_LINK_HOST) {
        const id = path.split('/').filter((s) => s !== '')[0];
        if (id !== undefined) {
          params = new URLSearchParams(url.search);
          params.set('v', id);   // youtu.be/ID?q → /watch?v=ID&q: the path id wins
          path = CONFIG.WATCH_PATH;
        }
      }
      if (path === CONFIG.REDIRECT_PATH) return true;                   // always external
      const video = isVideoLink(path, params);
      return role === 'browse' ? video : !video;
    }

    function resolve(href) {
      try {
        return new URL(href, document.baseURI);
      } catch (_) {
        return null;  // an invalid href navigates nowhere; leave it to the page
      }
    }

    // ── Click capture ───────────────────────────────────────────────────────────────────────

    function findAnchor(event) {
      const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
      for (const node of path) {
        if (node instanceof HTMLAnchorElement && node.localName === CONFIG.ANCHOR_TAG) {
          return node.hasAttribute('href') ? node : null;
        }
      }
      const target = event.target;
      const anchor = target instanceof Element ? target.closest('a[href]') : null;
      return anchor instanceof HTMLAnchorElement ? anchor : null;  // SVG <a> has no string href
    }

    function onClick(event) {
      if (event.button > 0) return;
      const anchor = findAnchor(event);
      if (!anchor || anchor.hasAttribute('download')) return;
      const url = resolve(anchor.getAttribute('href'));
      if (!url || !leaves(url)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      ns.post('route', { url: url.href, trigger: 'click' });
    }

    // On window, at document start: ahead of every listener YouTube adds later.
    window.addEventListener('click', (event) => ns.guard(SOURCE, () => onClick(event)), true);

    // ── History ─────────────────────────────────────────────────────────────────────────────

    let lastURL = String(location.href);

    function afterURLChange(kind) {
      const href = String(location.href);
      if (href === lastURL) return;
      lastURL = href;
      const title = typeof document.title === 'string' ? document.title.trim() : '';
      ns.post('pageChanged', title !== '' ? { url: href, title } : { url: href });
      ns.emit('navigation', { url: href });
      if (kind !== 'push') return;  // after replaceState or popstate there is no entry to go back from
      const url = resolve(href);
      if (url && leaves(url)) ns.post('route', { url: href, trigger: 'history' });
    }

    function wrapHistory(name, kind) {
      const descriptor = Object.getOwnPropertyDescriptor(History.prototype, name);
      const original = descriptor && descriptor.value;
      if (typeof original !== 'function') return;
      const wrapped = {
        [name](...args) {
          const result = reflectApply(original, this, args);  // its exceptions are the page's
          ns.guard(SOURCE, () => afterURLChange(kind));
          return result;
        },
      }[name];
      Object.defineProperty(History.prototype, name, { ...descriptor, value: wrapped });
    }

    wrapHistory('pushState', 'push');
    wrapHistory('replaceState', 'replace');
    window.addEventListener('popstate', () => ns.guard(SOURCE, () => afterURLChange('pop')), true);

    // ── window.open ─────────────────────────────────────────────────────────────────────────

    const origOpen = window.open;
    if (typeof origOpen === 'function') {
      window.open = function open(...args) {
        const routed = ns.guard(SOURCE, () => {
          const target = args[0];
          if (target === undefined || target === null || String(target) === '') return false;
          const url = resolve(String(target));
          if (!url || !leaves(url)) return false;
          ns.post('route', { url: url.href, trigger: 'windowOpen' });
          return true;
        });
        return routed === true ? null : reflectApply(origOpen, this, args);
      };
    }

    // ── Tab state (browse only) ─────────────────────────────────────────────────────────────
    //
    // `shownId` is the browseId of the page on screen. It is set when a browse page is
    // delivered, and when a push leaves the tabs or settles on one. A first-page browse fetch for
    // any other id is a switch, served from the cache when it can be; one for `shownId` is a
    // refresh. This holds whether mweb pushes the URL before or after it fetches.
    if (role === 'browse') installTabState();

    function installTabState() {
      const origFetch = typeof window.fetch === 'function' ? window.fetch : null;
      const PageResponse = typeof window.Response === 'function' ? window.Response : null;
      const PageRequest = typeof window.Request === 'function' ? window.Request : null;
      if (!origFetch || !PageResponse) return;

      const OTHER = '';                 // a page that is not a browse tab (search, channel, …)
      const now = () => Date.now();
      const tabIds = Object.values(TAB_STATE.TABS);
      const tabId = (href) => {
        const url = resolve(href);
        if (!url || url.origin !== location.origin) return null;
        const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname;
        return Object.prototype.hasOwnProperty.call(TAB_STATE.TABS, path) ? TAB_STATE.TABS[path] : null;
      };

      const cache = new Map();          // key → {id, text, time}; Map order = oldest first
      const positions = new Map();      // browseId → {y, time}
      let shownId = tabId(location.href) ?? OTHER;
      let recordId = shownId || null;   // whose scroll the samples belong to; null while switching
      let tap = null;                   // {id, y, time}: the scroll at the last tap
      let restore = null;               // the running restore, if any
      let settleTimer = 0;
      let sawBrowseFetch = false;
      let checkedTransport = false;

      // ── Scroll ──

      const scrollY = () => {
        const y = Number(window.scrollY ?? window.pageYOffset ?? 0);
        return Number.isFinite(y) ? y : 0;
      };
      const maxScroll = () => {
        const el = document.scrollingElement || document.documentElement;
        const height = el ? Number(el.scrollHeight) : 0;
        const view = Number(window.innerHeight) || 0;
        return Number.isFinite(height) ? Math.max(0, height - view) : 0;
      };

      let sampleTimer = 0;
      function sample() {
        sampleTimer = 0;
        if (recordId === null || (restore && restore.id === recordId)) return;  // not the user's scroll
        positions.set(recordId, { y: scrollY(), time: now() });
      }
      window.addEventListener('scroll', () => ns.guard(SOURCE, () => {
        if (sampleTimer === 0) sampleTimer = window.setTimeout(() => ns.guard(SOURCE, sample), TAB_STATE.SCROLL_SAMPLE_MS);
      }), { capture: true, passive: true });

      // A tap may start a switch: keep the scroll from before mweb resets it.
      window.addEventListener('click', () => ns.guard(SOURCE, () => {
        if (recordId !== null) tap = { id: recordId, y: scrollY(), time: now() };
      }), true);

      for (const type of TAB_STATE.CANCEL_EVENTS) {
        window.addEventListener(type, () => ns.guard(SOURCE, () => stopRestore('user')), { capture: true, passive: true });
      }

      /** The page on screen is leaving: keep its position and stop sampling for it. */
      function freeze() {
        if (recordId === null) return;
        if (tap && tap.id === recordId && now() - tap.time <= TAB_STATE.TAP_SNAPSHOT_MS) {
          positions.set(recordId, { y: tap.y, time: tap.time });
        } else if (!positions.has(recordId)) {
          positions.set(recordId, { y: scrollY(), time: now() });
        }
        tap = null;
        recordId = null;
      }

      function show(id) {
        shownId = id;
        recordId = id || null;
        if (settleTimer) { window.clearTimeout(settleTimer); settleTimer = 0; }
      }

      // ── Restore ──

      function stopRestore(reason) {
        if (!restore) return;
        const r = restore;
        restore = null;
        window.clearTimeout(r.timer);
        if (reason !== 'done') {
          ns.log('info', SOURCE, 'tab-state: restoring ' + r.id + ' stopped (' + reason + ') at ' + Math.round(scrollY()) + ' of ' + Math.round(r.y));
        }
      }

      function startRestore(id) {
        stopRestore('replaced');
        const saved = positions.get(id);
        if (!saved || saved.y < TAB_STATE.RESTORE_MIN_Y || now() - saved.time > TAB_STATE.CACHE_TTL_MS) return;
        restore = { id, y: saved.y, start: now(), timer: 0, rechecked: false };
        restore.timer = window.setTimeout(() => ns.guard(SOURCE, stepRestore), TAB_STATE.RESTORE_INTERVAL_MS);
      }

      function stepRestore() {
        const r = restore;
        if (!r) return;
        const later = (ms) => { r.timer = window.setTimeout(() => ns.guard(SOURCE, stepRestore), ms); };
        if (shownId !== r.id) { stopRestore('left the tab'); return; }
        const onTab = tabId(location.href) === r.id;  // mweb may push after it renders
        const y = scrollY();
        const tol = TAB_STATE.RESTORE_TOLERANCE_PX;
        if (onTab && Math.abs(y - r.y) <= tol) {
          if (!r.rechecked) {           // mweb may still jump to the top once it settles
            r.rechecked = true;
            later(TAB_STATE.RESTORE_RECHECK_MS);
            return;
          }
          stopRestore('done');
          positions.set(r.id, { y: r.y, time: now() });
          ns.log('info', SOURCE, 'tab-state: restored ' + r.id + ' to ' + Math.round(r.y));
          return;
        }
        if (now() - r.start > TAB_STATE.RESTORE_TIMEOUT_MS) { stopRestore('timeout'); return; }
        if (onTab) {
          // Short of the target, go as far as the page goes: at the bottom mweb loads its next
          // continuation page, so the feed grows toward the target.
          const target = Math.min(r.y, maxScroll());
          if (Math.abs(y - target) > tol) window.scrollTo(0, target);
        }
        later(TAB_STATE.RESTORE_INTERVAL_MS);
      }

      // ── Cache ──

      function evict() {
        const t = now();
        for (const [key, entry] of cache) if (t - entry.time > TAB_STATE.CACHE_TTL_MS) cache.delete(key);
        let chars = 0;
        for (const entry of cache.values()) chars += entry.text.length;
        for (const [key, entry] of cache) {
          if (cache.size <= TAB_STATE.CACHE_MAX_ENTRIES && chars <= TAB_STATE.CACHE_MAX_CHARS) break;
          chars -= entry.text.length;
          cache.delete(key);
        }
      }

      function store(key, id, text, from) {
        if (typeof text !== 'string' || text.length > TAB_STATE.CACHE_MAX_CHARS) return;
        const head = text.trimStart();
        if (!head.startsWith('{') || !head.includes(TAB_STATE.CONTENT_MARKER)) return;
        cache.delete(key);
        cache.set(key, { id, text, time: now() });
        evict();
        ns.log('info', SOURCE, 'tab-state: kept ' + id + ' (' + from + ', ' + Math.round(text.length / 1024) + ' KB)');
      }

      function cached(key) {
        const entry = cache.get(key);
        if (!entry) return null;
        if (now() - entry.time > TAB_STATE.CACHE_TTL_MS) { cache.delete(key); return null; }
        return entry;
      }

      const cacheKey = (id, params) => id + '\n' + (typeof params === 'string' ? params : '');

      // The tab this document loaded with: its ytInitialData is that tab's browse page.
      document.addEventListener('DOMContentLoaded', () => ns.guard(SOURCE, () => {
        const id = tabId(location.href);
        const data = window.ytInitialData;
        if (!id || data === null || typeof data !== 'object' || data.contents === undefined) return;
        store(cacheKey(id, undefined), id, JSON.stringify(data), 'ytInitialData');
      }), { once: true });

      // ── Navigation (this file's own `navigation` event) ──

      ns.on('navigation', ({ url }) => {
        const id = tabId(url);
        if (id !== null && id === shownId && recordId !== null) return;  // fetched first, then pushed
        freeze();
        stopRestore('navigation');
        if (settleTimer) { window.clearTimeout(settleTimer); settleTimer = 0; }
        if (id === null) {
          shownId = OTHER;
        } else {
          // No browse page for this tab arrives (mweb answered it itself): it is on screen anyway.
          settleTimer = window.setTimeout(() => ns.guard(SOURCE, () => {
            settleTimer = 0;
            if (recordId === null && tabId(location.href) === id) show(id);
          }), TAB_STATE.NAV_SETTLE_MS);
        }
        checkTransport();
      });

      /** Once: if browse pages come over XHR, this cache never sees them; say so in the Debug log. */
      function checkTransport() {
        if (checkedTransport || sawBrowseFetch || !ns.hooks || !Array.isArray(ns.hooks.originals)) return;
        const xhr = ns.hooks.originals.find((o) => o && o.source === 'xhr' && TAB_STATE.BROWSE_URL.test(String(o.url)));
        if (!xhr) return;
        checkedTransport = true;
        ns.log('warn', SOURCE, 'tab-state: browse pages arrive over XHR; the tab cache (fetch only) is inactive');
      }

      // ── fetch ──

      function browseURL(input) {
        try {
          const raw = typeof input === 'string' ? input : input && typeof input.url === 'string' ? input.url : String(input);
          const url = new URL(raw, location.href);
          return TAB_STATE.BROWSE_URL.test(url.pathname) ? url.href : null;
        } catch (_) {
          return null;
        }
      }

      /** The request body: a string, a promise of one (a Request), or null (leave it alone). */
      function bodyOf(args) {
        const input = args[0];
        const init = args[1];
        try {
          if (init && init.body !== undefined && init.body !== null) return typeof init.body === 'string' ? init.body : null;
          if (PageRequest && input instanceof PageRequest && !input.bodyUsed) return input.clone().text();
        } catch (_) { /* unreadable: pass through */ }
        return null;
      }

      /** What to do with a browse request: null = pass through untouched. */
      function plan(text) {
        if (typeof text !== 'string') return null;
        let body;
        try { body = JSON.parse(text); } catch (_) { return null; }
        if (body === null || typeof body !== 'object') return null;
        if (body.continuation !== undefined || typeof body.browseId !== 'string' || body.browseId === '') return null;
        const id = body.browseId;
        const key = tabIds.includes(id) ? cacheKey(id, body.params) : null;
        if (id === shownId && recordId !== null) {
          // Pull-to-refresh or a tap on the active tab: a fresh page, from the top.
          positions.delete(id);
          stopRestore('refresh');
          return { id, key, entry: null };
        }
        freeze();
        stopRestore('switch');
        const entry = key ? cached(key) : null;
        ns.log('info', SOURCE, 'tab-state: switch to ' + id + (body.params ? ' (params)' : '') + ': ' + (!key ? 'not a tab' : entry ? 'hit' : 'miss'));
        return { id, key, entry };
      }

      function serve(p, url) {
        const response = new PageResponse(p.entry.text, { status: 200, statusText: 'OK', headers: TAB_STATE.RESPONSE_HEADERS });
        try { Object.defineProperty(response, 'url', { value: url, configurable: true }); } catch (_) { /* keep */ }
        show(p.id);
        ns.log('info', SOURCE, 'tab-state: ' + p.id + ' from cache (' + Math.round((now() - p.entry.time) / 1000) + ' s old)');
        startRestore(p.id);
        return response;
      }

      function delivered(p, response) {
        if (!response || response.status !== 200) return;
        show(p.id);
        if (!p.key || response.bodyUsed) return;
        response.clone().text().then((text) => ns.guard(SOURCE, () => store(p.key, p.id, text, 'fetch')), () => {});
      }

      function handle(target, thisArg, args, url, p) {
        if (p && p.entry) {
          const response = ns.guard(SOURCE, () => serve(p, url));
          if (response) return Promise.resolve(response);
        }
        const pending = reflectApply(target, thisArg, args);  // its errors are the page's
        if (!p) return pending;
        return pending.then((response) => {
          ns.guard(SOURCE, () => delivered(p, response));
          return response;
        });
      }

      // Outside hooks.js's wrapper (router.js loads after it), so pages are stored already pruned
      // and a cached page skips the pruners.
      window.fetch = new Proxy(origFetch, {
        apply(target, thisArg, args) {
          const url = browseURL(args[0]);
          if (url === null) return reflectApply(target, thisArg, args);
          if (!sawBrowseFetch) {
            sawBrowseFetch = true;
            ns.log('info', SOURCE, 'tab-state: browse pages arrive over fetch');
          }
          const body = bodyOf(args);
          const decide = (text) => ns.guard(SOURCE, () => plan(text)) || null;
          if (body !== null && typeof body.then === 'function') {
            return body.then(
              (text) => handle(target, thisArg, args, url, decide(text)),
              () => reflectApply(target, thisArg, args),
            );
          }
          return handle(target, thisArg, args, url, decide(body));
        },
      });
    }
  });
})();
