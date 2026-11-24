// debug.js — owner: Module B (PLAN.md §6.2 Debug tooling, §5.4 `capture`, D19).
//
// The app is its own debugger (no Web Inspector on Windows). This file:
//   forwards  console.warn / console.error, uncaught page errors and unhandled rejections to the
//             Debug log as `log` messages (source 'debug.js'), capped and de-duplicated per document
//   handles   `capture` → {url, title, html, originals[], counters, log[]}: the DOM, Module A's
//             pre-prune responses (`__ytadless.hooks.originals`), and what this file forwarded
// filterHit counters aren't visible from here (bridge.js posts them directly), so `counters`
// holds this file's own counts; native adds its filterHit totals to the capture folder.
(() => {
  'use strict';

  const SOURCE = 'debug.js';
  const CONFIG = Object.freeze({
    CONSOLE_METHODS: ['warn', 'error'],  // console.<m> → log level <m> (PLAN.md §5.3 `log`)
    MAX_FORWARDED: 300,                  // log lines forwarded per document, then one "suppressed" line
    MAX_REPEATS: 3,                      // identical lines forwarded per document
    MAX_DISTINCT_TRACKED: 2000,          // repeat counts are forgotten past this many distinct lines
    MAX_ARG_CHARS: 600,                  // per console argument
    MAX_KEYS_SHOWN: 8,                   // an object argument prints as {key1,key2,…}, never stringified whole
    LOG_BUFFER_SIZE: 200,                // lines kept for `capture`
    MAX_ORIGINALS: 200,                  // entries of hooks.originals copied into a capture
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    const reflectApply = Reflect.apply;
    const objectToString = Object.prototype.toString;
    const counters = {
      consoleWarn: 0, consoleError: 0, pageError: 0, unhandledRejection: 0, forwarded: 0, suppressed: 0,
    };
    const seen = new Map();   // line → times seen
    const buffer = [];        // [{time, level, message}] for capture

    function clip(text) {
      return text.length > CONFIG.MAX_ARG_CHARS ? text.slice(0, CONFIG.MAX_ARG_CHARS) + '…' : text;
    }

    // Cheap on purpose: YouTube logs large objects, and this runs on every console call.
    function describe(value) {
      try {
        if (typeof value === 'string') return clip(value);
        if (value === null || value === undefined) return String(value);
        if (typeof value !== 'object' && typeof value !== 'function') return String(value);
        if (typeof value === 'function') return '[function ' + (value.name || 'anonymous') + ']';
        if (typeof value.message === 'string' && typeof value.name === 'string') return clip(value.name + ': ' + value.message);
        if (Array.isArray(value)) return '[Array(' + value.length + ')]';
        const tag = objectToString.call(value).slice(8, -1);
        if (tag !== 'Object') return '[' + tag + ']';
        const keys = Object.keys(value);
        const shown = keys.slice(0, CONFIG.MAX_KEYS_SHOWN).join(',');
        return '{' + shown + (keys.length > CONFIG.MAX_KEYS_SHOWN ? ',…' : '') + '}';
      } catch (_) {
        return '[unprintable]';
      }
    }

    function forward(level, message) {
      if (seen.size >= CONFIG.MAX_DISTINCT_TRACKED && !seen.has(message)) seen.clear();
      const repeats = (seen.get(message) || 0) + 1;
      seen.set(message, repeats);
      buffer.push({ time: Date.now(), level, message });
      if (buffer.length > CONFIG.LOG_BUFFER_SIZE) buffer.shift();
      if (repeats > CONFIG.MAX_REPEATS) return;
      if (counters.forwarded >= CONFIG.MAX_FORWARDED) {
        counters.suppressed += 1;
        if (counters.suppressed === 1) {
          ns.log('warn', SOURCE, 'more than ' + CONFIG.MAX_FORWARDED + ' log lines in this document; the rest are only in captures');
        }
        return;
      }
      counters.forwarded += 1;
      ns.log(level, SOURCE, message);
    }

    // ── console ─────────────────────────────────────────────────────────────────────────────
    for (const method of CONFIG.CONSOLE_METHODS) {
      const original = console[method];
      if (typeof original !== 'function') continue;
      const counter = method === 'warn' ? 'consoleWarn' : 'consoleError';
      console[method] = {
        [method](...args) {
          ns.guard(SOURCE, () => {
            counters[counter] += 1;
            forward(method, 'console.' + method + ': ' + args.map(describe).join(' '));
          });
          return reflectApply(original, this, args);
        },
      }[method];
    }

    // ── uncaught errors ─────────────────────────────────────────────────────────────────────
    // Only ErrorEvents: failed resource loads (blocked ad requests) also fire `error` on window.
    window.addEventListener('error', (event) => ns.guard(SOURCE, () => {
      if (!(event instanceof ErrorEvent)) return;
      counters.pageError += 1;
      const where = event.filename ? ' @ ' + event.filename + ':' + event.lineno + ':' + event.colno : '';
      const what = event.error !== undefined && event.error !== null ? describe(event.error) : String(event.message);
      forward('error', 'uncaught: ' + what + where);
    }), true);

    window.addEventListener('unhandledrejection', (event) => ns.guard(SOURCE, () => {
      counters.unhandledRejection += 1;
      forward('warn', 'unhandledrejection: ' + describe(event.reason));
    }), true);

    // ── capture ─────────────────────────────────────────────────────────────────────────────
    function serializeDocument() {
      const doctype = document.doctype ? '<!DOCTYPE ' + document.doctype.name + '>\n' : '';
      return doctype + (document.documentElement ? document.documentElement.outerHTML : '');
    }

    // `hooks.originals` is Module A's ring buffer; accept an array, something iterable or with a
    // `snapshot()`/`toArray()`, or nothing.
    function originals() {
      const hooks = ns.hooks;
      const source = hooks && hooks.originals;
      if (!source) return [];
      let list = null;
      if (Array.isArray(source)) list = source;
      else if (typeof source.snapshot === 'function') list = source.snapshot();
      else if (typeof source.toArray === 'function') list = source.toArray();
      else if (typeof source[Symbol.iterator] === 'function') list = Array.from(source);
      if (!Array.isArray(list)) return [];
      return list.slice(-CONFIG.MAX_ORIGINALS);
    }

    ns.command('capture', () => ({
      url: String(location.href),
      title: typeof document.title === 'string' ? document.title : '',
      html: serializeDocument(),
      originals: ns.guard(SOURCE, originals) || [],
      counters: { ...counters },
      log: buffer.slice(),
    }));
  });
})();
