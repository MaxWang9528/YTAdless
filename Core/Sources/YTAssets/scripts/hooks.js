// hooks.js — owner: Module A (PLAN.md §6.1 Layer 2). Phase 0 stub.
//
// Installs the JSON.parse / fetch / XHR / ytInitial* interception points once and sets __ytadless.hooks = {addPruner, originals}; emits `playerResponse`.
(() => {
  'use strict';

  const SOURCE = 'hooks.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({});

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    // Module A implements this file.
    void CONFIG;
  });
})();
