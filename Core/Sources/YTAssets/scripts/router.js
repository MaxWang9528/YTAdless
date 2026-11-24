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
  });
})();
