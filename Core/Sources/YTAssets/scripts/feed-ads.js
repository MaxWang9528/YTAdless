// feed-ads.js — owner: Module A (PLAN.md §6.1 Layer 3).
//
// Removes promoted items from feed data before YouTube renders them: ytInitialData and the
// innertube browse/search/next/get_watch/guide/reel responses. One generic walk, driven by
// AD_RENDERER_KEYS: an array element is removed when its own key, or the key inside its
// richItemRenderer.content / richSectionRenderer.content, is in the table. Each removal reports
// filterHit('feed.<key>'). rules/cosmetic.txt hides the same items as a backstop.
(() => {
  'use strict';

  const SOURCE = 'feed-ads.js';

  // status 'known': PLAN.md §6.1 known keys (uBO/EasyList youtube.com rules). 'candidate': listed
  // in PLAN.md §6.1 to confirm against fixtures; none appeared in the anonymous 2026-11-24
  // captures (signed-out feeds carry no ads), so they stay until a signed-in capture says otherwise.
  const AD_RENDERER_KEYS = Object.freeze({
    adSlotRenderer: 'known',                      // uBO json-edit `[?.adSlotRenderer]`; get_watch fixture 2026-11-24
    promotedSparklesWebRenderer: 'known',         // EasyList `ytm-promoted-sparkles-web-renderer`
    promotedVideoRenderer: 'known',               // EasyList `ytm-promoted-video-renderer`
    compactPromotedVideoRenderer: 'known',        // uBO youtube.com json-prune lists
    searchPyvRenderer: 'known',                   // uBO youtube.com search ads
    promotedSparklesTextSearchRenderer: 'candidate',
    statementBannerRenderer: 'candidate',
    mealbarPromoRenderer: 'candidate',
    brandVideoShelfRenderer: 'candidate',
    brandVideoSingletonRenderer: 'candidate',
  });

  const CONFIG = Object.freeze({
    // Wrappers whose `content` holds the renderer that decides (home grid, shelves).
    WRAPPER_KEYS: ['richItemRenderer', 'richSectionRenderer'],
    // Where feed data arrives (PLAN.md §6.1). Substrings of the request URL or hooks.js targets.
    URLS: [
      'window.ytInitialData',
      'window.ytInitialReelWatchSequenceResponse',
      'JSON.parse',
      '/youtubei/v1/browse',
      '/youtubei/v1/search',
      '/youtubei/v1/next',
      '/youtubei/v1/get_watch',
      '/youtubei/v1/guide',
      '/youtubei/v1/reel/',
    ],
  });

  const ns = window.__ytadless;
  if (!ns) return;

  const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const isObject = (v) => v !== null && typeof v === 'object';

  /** The ad key that makes `item` an ad, or null. */
  function adKeyOf(item) {
    if (!isObject(item) || Array.isArray(item)) return null;
    for (const key of Object.keys(item)) {
      if (hasOwn(AD_RENDERER_KEYS, key)) return key;
    }
    for (const wrapper of CONFIG.WRAPPER_KEYS) {
      const content = isObject(item[wrapper]) ? item[wrapper].content : null;
      if (!isObject(content)) continue;
      for (const key of Object.keys(content)) {
        if (hasOwn(AD_RENDERER_KEYS, key)) return key;
      }
    }
    return null;
  }

  /** Removes ad elements from every array in `root`, in place. Returns {'feed.<key>': count}. */
  function strip(root) {
    const hits = {};
    const stack = [root];
    const seen = new Set();
    while (stack.length) {
      const node = stack.pop();
      if (!isObject(node) || seen.has(node)) continue;
      seen.add(node);
      if (Array.isArray(node)) {
        for (let i = node.length - 1; i >= 0; i -= 1) {
          const key = adKeyOf(node[i]);
          if (key) {
            node.splice(i, 1);
            hits['feed.' + key] = (hits['feed.' + key] || 0) + 1;
          } else if (isObject(node[i])) {
            stack.push(node[i]);
          }
        }
      } else {
        for (const key of Object.keys(node)) if (isObject(node[key])) stack.push(node[key]);
      }
    }
    return hits;
  }

  ns.guard(SOURCE, () => {
    const hooks = ns.hooks;
    if (!hooks || typeof hooks.addPruner !== 'function') {
      ns.log('warn', SOURCE, 'hooks.js is not installed; feed ads are not pruned');
      return;
    }
    hooks.addPruner({ name: 'feed', urls: CONFIG.URLS, fn: (value) => strip(value) });
  });
})();
