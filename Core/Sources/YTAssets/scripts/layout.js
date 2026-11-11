// layout.js — owner: Module C (PLAN.md §6.3). Phase 0 stub.
//
// Handles the `layout` command: in `video` mode hides the page chrome and pins the player to the viewport. Injected at document end.
(() => {
  'use strict';

  const SOURCE = 'layout.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module C implements this file.
    void CONFIG;
  });
})();
