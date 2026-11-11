// player-ads.js — owner: Module A (PLAN.md §6.1 Layer 2). Phase 0 stub.
//
// The RULES table (uBO json-prune dialect) that strips ad fields from player responses, plus the ad-showing fallback.
(() => {
  'use strict';

  const SOURCE = 'player-ads.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module A implements this file.
    void CONFIG;
  });
})();
