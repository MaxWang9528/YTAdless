// debug.js — owner: Module B (PLAN.md §6.2 Debug tooling, §5.4 `capture`). Phase 0 stub.
//
// Forwards console.warn/error to the Debug log and implements the `capture` command (D19).
(() => {
  'use strict';

  const SOURCE = 'debug.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module B implements this file.
    void CONFIG;
  });
})();
