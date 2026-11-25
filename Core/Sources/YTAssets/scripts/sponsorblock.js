// sponsorblock.js — owner: Module D (PLAN.md §5.4 `sponsorSegments`).
//
// Contract stub: accepts `sponsorSegments {videoId, segments}` from native. Skipping comes next.
(() => {
  'use strict';

  const SOURCE = 'sponsorblock.js';
  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    ns.command('sponsorSegments', (args) => {
      const segments = Array.isArray(args.segments) ? args.segments : [];
      return { ok: true, count: segments.length };
    });
  });
})();
