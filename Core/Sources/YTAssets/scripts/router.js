// router.js — owner: Module B (PLAN.md §6.2). Phase 0 stub.
//
// Click capture and history hooks: posts `route` and `pageChanged`, emits `navigation` (classifier checked against TestVectors/routing.json).
(() => {
  'use strict';

  const SOURCE = 'router.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module B implements this file.
    void CONFIG;
  });
})();
