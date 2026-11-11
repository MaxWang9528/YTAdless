// media-session.js — owner: Module D (PLAN.md §6.4 Now Playing). Phase 0 stub.
//
// Owns navigator.mediaSession: metadata, position state and action handlers (D11, pending approval).
(() => {
  'use strict';

  const SOURCE = 'media-session.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module D implements this file.
    void CONFIG;
  });
})();
