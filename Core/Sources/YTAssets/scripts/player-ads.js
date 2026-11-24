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

  // Sources: uBlockOrigin/uAssets filters/filters.txt and filters/quick-fixes.txt, the
  // m.youtube.com / youtube.com entries summarised in PLAN.md F6; checked against the
  // 2026-11-24 anonymous fixtures (js/fixtures/player/).
  const RULES = Object.freeze([
    {
      // uBO: youtube.com##+js(set, ytInitialPlayerResponse.{adPlacements,playerAds,adSlots}, undefined)
      //      youtube.com##+js(json-prune, … adPlacements playerAds adSlots …)
      //      youtube.com##+js(json-prune-fetch-response, adPlacements playerAds adSlots, , propsToMatch, /player?)
      name: 'player.adPlacements',
      urls: ['window.ytInitialPlayerResponse', 'window.ytplayer', 'JSON.parse', /\/youtubei\/v1\/player(?:\?|$)/],
      paths: ['adPlacements', 'playerAds', 'adSlots'],
    },
    {
      // uBO: youtube.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots …)
      // Also reel_item_watch (Shorts player), which wraps the player response the same way.
      name: 'playerResponse.adPlacements',
      urls: ['JSON.parse', '/youtubei/v1/reel/reel_item_watch'],
      paths: ['playerResponse.adPlacements', 'playerResponse.playerAds', 'playerResponse.adSlots'],
    },
    {
      // uBO: m.youtube.com##+js(json-prune-fetch-response, [].playerResponse.adPlacements
      //      [].playerResponse.playerAds [].playerResponse.adSlots, , propsToMatch, /get_watch?)
      // mweb watch navigations return an array (F6; fixture 2026-11-24-get_watch-*.json).
      name: 'get_watch.adPlacements',
      urls: ['/youtubei/v1/get_watch'],
      paths: ['[].playerResponse.adPlacements', '[].playerResponse.playerAds', '[].playerResponse.adSlots'],
    },
    {
      // uBO: youtube.com##+js(json-prune-fetch-response,
      //      endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.{adPlacements,playerAds,adSlots}, , propsToMatch, resolve_url)
      name: 'prefetch.adPlacements',
      urls: ['/youtubei/v1/navigation/resolve_url', 'JSON.parse'],
      paths: [
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adPlacements',
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.playerAds',
        'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse.adSlots',
      ],
    },
    {
      // uBO: m.youtube.com##+js(json-edit-fetch-response, ..itemSectionRenderer.contents.*[?.adSlotRenderer], , propsToMatch, /get_watch?)
      // The in-feed ad under the player (fixture 2026-11-24-get_watch-*.json carries one).
      name: 'get_watch.adSlotRenderer',
      urls: ['/youtubei/v1/get_watch', '/youtubei/v1/next'],
      paths: ['..itemSectionRenderer.contents.*[?.adSlotRenderer]'],
    },
    {
      // uBO: m.youtube.com##+js(json-prune-fetch-response, entries.[-].command.reelWatchEndpoint.adClientParams.isAd, , propsToMatch, /reel_watch_sequence?)
      // Ad entries in the Shorts sequence; the first page also arrives inline in the Shorts HTML.
      name: 'shorts.adEntries',
      urls: ['/youtubei/v1/reel/reel_watch_sequence', 'window.ytInitialReelWatchSequenceResponse'],
      paths: ['entries.[-].command.reelWatchEndpoint.adClientParams.isAd'],
    },
  ]);

  // uBO's other strategy (trusted-replace-xhr-response '"adPlacements"' '"no_ads"'): rename the
  // keys in the raw text so the player never sees them. Off: pruning covers the same fields.
  // Turn it on if YouTube starts detecting pruned responses (hooks.js `text` support is tested).
  const TEXT_RULES = Object.freeze([
    { name: 'player.no_ads', enabled: false, urls: [/\/youtubei\/v1\/player(?:\?|$)/, '/youtubei/v1/get_watch'], text: [['"adPlacements"', '"no_ads"'], ['"adSlots"', '"no_ads2"']] },
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

    function skip(player) {
      const video = player.querySelector('video');
      if (!active) {
        active = { video, wasMuted: video ? video.muted : false };
        ns.post('filterHit', { rule: FALLBACK.RULE, count: 1 });
        ns.log('warn', SOURCE, 'ad rendered despite pruning; skipping it');
      }
      if (video) {
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
