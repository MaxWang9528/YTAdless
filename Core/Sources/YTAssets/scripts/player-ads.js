// player-ads.js — owner: Module A (PLAN.md §6.1 Layer 2).
//
// The RULES table that strips ad fields from player responses, registered with hooks.js, plus
// the last-resort `ad-showing` fallback. RULES use uBO's json-prune path dialect (D8), so an
// upstream fix ports line by line: copy the paths, and put the uBO URL pattern in `urls`.
// `urls` entries are substrings of the request URL, or 'window.<global>' for the inline-script
// traps, or 'JSON.parse' (see hooks.js). Every rule reports `filterHit` with its `name`.
(() => {
  'use strict';

  const SOURCE = 'player-ads.js';

  // Sources: uBlockOrigin/uAssets master, filters/filters.txt (F) and filters/quick-fixes.txt (Q),
  // lines quoted verbatim as fetched 2026-11-24 (the leading host list "m.youtube.com,music.youtube.com,
  // …" is shortened to "m.youtube.com,…"); checked against the 2026-11-24 anonymous fixtures.
  const RULES = Object.freeze([
    {
      // F: m.youtube.com,…##+js(set, ytInitialPlayerResponse.playerAds, undefined)
      // F: m.youtube.com,…##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
      // F: m.youtube.com,…##+js(set, ytInitialPlayerResponse.adSlots, undefined)
      // F: m.youtube.com,…##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots important)
      // Q: www.youtube.com##+js(json-prune-fetch-response, adPlacements adSlots playerResponse.adPlacements playerResponse.adSlots [].playerResponse.adPlacements [].playerResponse.adSlots, , propsToMatch, /\/player(\?|$)/)
      //    (www-only upstream; applied to mweb's /player too, with playerAds as in F)
      name: 'player.adPlacements',
      urls: ['window.ytInitialPlayerResponse', 'window.ytplayer', 'JSON.parse', /\/youtubei\/v1\/player(?:\?|$)/],
      paths: ['adPlacements', 'playerAds', 'adSlots'],
    },
    {
      // F: the json-prune line above (its playerResponse.* paths, on JSON.parse), and
      // F: m.youtube.com,…##+js(set, playerResponse.adPlacements, undefined)
      // Also reel_item_watch (Shorts player), which wraps the player response the same way.
      name: 'playerResponse.adPlacements',
      urls: ['JSON.parse', '/youtubei/v1/reel/reel_item_watch'],
      paths: ['playerResponse.adPlacements', 'playerResponse.playerAds', 'playerResponse.adSlots'],
    },
    {
      // Upstream handles get_watch by text replacement (see TEXT_RULES):
      // F/Q: ||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/"adPlacements"/"no_ads"/
      // F/Q: ||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/"adSlots"/"no_ads"/
      // Here the same fields are pruned with the [].playerResponse paths of the Q /player line
      // above (a commented-out Q www line lists them for /get_watch too).
      // mweb watch navigations return an array (F6; fixture 2026-11-24-get_watch-*.json).
      name: 'get_watch.adPlacements',
      urls: ['/youtubei/v1/get_watch'],
      paths: ['[].playerResponse.adPlacements', '[].playerResponse.playerAds', '[].playerResponse.adSlots'],
    },
    {
      // Q: m.youtube.com,www.youtube.com,www.youtube-nocookie.com##+js(json-prune-fetch-response, endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.playerAds endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adPlacements endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adSlots, , propsToMatch, /resolve_url?)
      name: 'prefetch.adPlacements',
      urls: ['/youtubei/v1/navigation/resolve_url', 'JSON.parse'],
      paths: [
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adPlacements',
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.playerAds',
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adSlots',
      ],
    },
    {
      // F: m.youtube.com##+js(json-edit-fetch-response, ..itemSectionRenderer.contents.*[?.adSlotRenderer], propsToMatch, /get_watch)
      // The in-feed ad under the player. /next is ours: the same watch-next data, without the player.
      name: 'get_watch.adSlotRenderer',
      urls: ['/youtubei/v1/get_watch', '/youtubei/v1/next'],
      paths: ['..itemSectionRenderer.contents.*[?.adSlotRenderer]'],
    },
    {
      // F: m.youtube.com,…##+js(json-prune-fetch-response, reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd entries.[-].command.reelWatchEndpoint.adClientParams.isAd, , propsToMatch, url:/reel_watch_sequence?)
      // F: m.youtube.com,…##+js(json-prune, entries.[-].command.reelWatchEndpoint.adClientParams.isAd)
      // Ad entries in the Shorts sequence; the first page also arrives inline in the Shorts HTML.
      name: 'shorts.adEntries',
      urls: ['/youtubei/v1/reel/reel_watch_sequence', 'window.ytInitialReelWatchSequenceResponse', 'JSON.parse'],
      paths: [
        'reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd',
        'entries.[-].command.reelWatchEndpoint.adClientParams.isAd',
      ],
    },
  ]);

  // uBO's other strategy: rename the keys in the raw text so the player never sees them.
  // F/Q: ||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/"adPlacements"/"no_ads"/  (and "adSlots")
  // F/Q: www.youtube.com##+js(trusted-rpfr, '"adPlacements"', '"no_ads"', player?)       (and "adSlots")
  // Off: the pruning above covers the same fields. Turn it on if YouTube starts detecting pruned
  // responses (hooks.js `text` support is tested).
  const TEXT_RULES = Object.freeze([
    { name: 'player.no_ads', enabled: false, urls: [/\/youtubei\/v1\/player(?:\?|$)/, '/youtubei/v1/get_watch'], text: [['"adPlacements"', '"no_ads"'], ['"adSlots"', '"no_ads"']] },
  ]);

  // Last resort (PLAN.md §6.1): if an ad still renders, mute, jump to its end, press Skip.
  // Firing at all means pruning failed, so it reports filterHit('ad-skip-fallback').
  // Selectors: m.youtube.com player DOM (#movie_player gets `ad-showing` while an ad plays;
  // EasyList/uBO and community skip scripts, 2026-11-24).
  const FALLBACK = Object.freeze({
    PLAYER_ID: 'movie_player',
    AD_CLASS: 'ad-showing',
    SKIP_SELECTORS: ['.ytp-ad-skip-button', '.ytp-ad-skip-button-modern', '.ytp-skip-ad-button', '.ytp-ad-skip-button-container button'],
    RULE: 'ad-skip-fallback',
    CONTENT_TOLERANCE_S: 2,  // |duration − videoDetails.lengthSeconds| below this = the real video
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const hooks = ns.hooks;
    if (hooks && typeof hooks.addPruner === 'function') {
      for (const rule of RULES) hooks.addPruner(rule);
      for (const rule of TEXT_RULES) if (rule.enabled) hooks.addPruner({ name: rule.name, urls: rule.urls, text: rule.text });
    } else {
      ns.log('warn', SOURCE, 'hooks.js is not installed; player ads are not pruned');
    }

    // The fallback only matters where video plays: the player view's main frame (D14).
    if (ns.config.role !== 'player' || window.top !== window) return;
    if (typeof MutationObserver !== 'function') return;

    let active = null;  // {video, wasMuted} while an ad is showing
    // The ad and the content share one <video>. If `ad-showing` is still set once the content's
    // metadata has loaded, seeking to the end would skip the real video, so a media element whose
    // duration matches the content's length is never muted or seeked.
    const contentLengths = new Set();
    ns.on('playerResponse', (pr) => {
      const length = Number(pr && pr.videoDetails && pr.videoDetails.lengthSeconds);
      if (Number.isFinite(length) && length > 0) contentLengths.add(length);
    });
    const isContent = (video) => [...contentLengths].some((length) => Math.abs(video.duration - length) <= FALLBACK.CONTENT_TOLERANCE_S);

    function skip(player) {
      const video = player.querySelector('video');
      if (!active) {
        active = { video, wasMuted: video ? video.muted : false };
        ns.post('filterHit', { rule: FALLBACK.RULE, count: 1 });
        ns.log('warn', SOURCE, 'ad rendered despite pruning; skipping it');
      }
      if (video && !isContent(video)) {
        video.muted = true;
        if (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
          video.currentTime = video.duration;
        }
      }
      for (const selector of FALLBACK.SKIP_SELECTORS) {
        const button = player.querySelector(selector);
        if (button && typeof button.click === 'function') button.click();
      }
    }

    function check() {
      const player = document.getElementById(FALLBACK.PLAYER_ID);
      const showing = !!player && player.classList.contains(FALLBACK.AD_CLASS);
      if (showing) {
        skip(player);
      } else if (active) {
        if (active.video && !active.wasMuted) active.video.muted = false;
        active = null;
      }
    }

    const observer = new MutationObserver(() => ns.guard(SOURCE, check));
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
  });
})();
