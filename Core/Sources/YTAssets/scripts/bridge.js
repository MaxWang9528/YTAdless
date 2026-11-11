// bridge.js — the in-page runtime `window.__ytadless` (PLAN.md §5.2). Owner: P0 (frozen).
//
// Runs first in every frame of both webviews, in the page content world (D5), right after the
// generated config prelude. Everything else talks to native and to each other through it:
//   post(type, payload)   JS → native message {v:1, type, frame, ...payload}; never throws
//   on(evt, fn) / emit(evt, ...args)   in-page event bus (event names: PLAN.md §5.2)
//   command(name, fn)     register the one handler for a native → JS command (§5.4)
//   cmd(name, argsJSON)   native entry point; returns a JSON-safe value or {error}; never throws
//   log(level, source, ...args) · guard(source, fn) · config · hooks (set once by hooks.js)
// This file can't use guard (it defines it), so every entry point has its own try/catch.
(() => {
  'use strict';

  const NS = '__ytadless';       // = ScriptConfig.namespace
  const HANDLER = 'ytadless';    // = ScriptConfig.messageHandlerName
  const PROTOCOL_VERSION = 1;    // = BridgeMessage.protocolVersion

  const CONFIG = Object.freeze({
    LOG_LEVELS: ['debug', 'info', 'warn', 'error'],
    MAX_MESSAGE_CHARS: 4000,     // log / scriptError message, truncated beyond this
    MAX_STACK_CHARS: 4000,
    MAX_ERRORS_PER_SOURCE: 50,   // scriptError reports per source per document, then silence
    DEFAULT_CONFIG: { role: 'browse', debug: false, build: 'unknown' },  // prelude missing
  });

  const existing = Object.getOwnPropertyDescriptor(window, NS);
  if (existing && !existing.configurable) return;  // already installed in this document

  // Originals, captured before any other script runs (hooks.js wraps JSON.parse and fetch).
  const jsonParse = JSON.parse;
  const jsonStringify = JSON.stringify;
  const apply = Reflect.apply;
  const freeze = Object.freeze;
  const defineProperty = Object.defineProperty;
  const create = Object.create;
  const isArray = Array.isArray;

  const handler = (() => {
    try {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER];
      return h && typeof h.postMessage === 'function' ? h : null;
    } catch (_) {
      return null;
    }
  })();
  const postMessage = handler ? handler.postMessage : null;

  const frame = (() => {
    try { return window.top === window ? 'main' : 'sub'; } catch (_) { return 'sub'; }
  })();

  const config = (() => {
    const fallback = CONFIG.DEFAULT_CONFIG;
    let c = null;
    try { c = existing && existing.value && existing.value.config; } catch (_) { c = null; }
    if (!c || typeof c !== 'object') return freeze({ ...fallback });
    return freeze({
      role: c.role === 'player' ? 'player' : 'browse',
      debug: c.debug === true,
      build: typeof c.build === 'string' ? c.build : fallback.build,
    });
  })();

  // A JSON round trip with the original JSON functions: drops functions and undefined, turns
  // NaN/Infinity into null, and fails (→ fallback) on cycles or BigInt. What WebKit's
  // postMessage and callAsyncJavaScript receive is therefore always plain JSON.
  const UNSERIALIZABLE = {};
  function toJSONSafe(value) {
    try {
      const text = jsonStringify(value);
      return text === undefined ? null : jsonParse(text);
    } catch (_) {
      return UNSERIALIZABLE;
    }
  }

  function truncate(text, max) {
    return text.length > max ? text.slice(0, max) + '…' : text;
  }

  function describe(value) {
    try {
      if (typeof value === 'string') return value;
      if (value === undefined) return 'undefined';
      if (value === null) return 'null';
      if (typeof value === 'object' && typeof value.message === 'string') {
        const name = typeof value.name === 'string' ? value.name : 'Error';
        return name + ': ' + value.message;
      }
      if (typeof value === 'object') {
        const text = jsonStringify(value);
        if (typeof text === 'string') return text;
      }
      return String(value);
    } catch (_) {
      return '[unprintable]';
    }
  }

  let dropped = 0;
  function post(type, payload) {
    if (!postMessage || typeof type !== 'string' || type === '') return false;
    try {
      let body = payload == null ? {} : toJSONSafe(payload);
      if (!body || typeof body !== 'object' || isArray(body)) body = {};
      body.v = PROTOCOL_VERSION;
      body.type = type;
      body.frame = frame;
      apply(postMessage, handler, [body]);
      return true;
    } catch (_) {
      dropped += 1;
      return false;
    }
  }

  const errorCounts = create(null);
  function reportError(source, error) {
    try {
      const src = typeof source === 'string' && source !== '' ? source : 'unknown';
      const count = (errorCounts[src] || 0) + 1;
      errorCounts[src] = count;
      if (count > CONFIG.MAX_ERRORS_PER_SOURCE) return;
      const payload = { source: src, message: truncate(describe(error), CONFIG.MAX_MESSAGE_CHARS) };
      const stack = error && typeof error === 'object' && typeof error.stack === 'string' ? error.stack : null;
      if (stack) payload.stack = truncate(stack, CONFIG.MAX_STACK_CHARS);
      post('scriptError', payload);
    } catch (_) {
      // Nothing left to report with.
    }
  }

  function isThenable(value) {
    return value !== null && (typeof value === 'object' || typeof value === 'function') && typeof value.then === 'function';
  }

  function guard(source, fn) {
    try {
      const result = fn();
      if (isThenable(result)) {
        try { result.then(undefined, (e) => reportError(source, e)); } catch (e) { reportError(source, e); }
      }
      return result;
    } catch (e) {
      reportError(source, e);
      return undefined;
    }
  }

  function log(level, source, ...args) {
    try {
      const lvl = CONFIG.LOG_LEVELS.includes(level) ? level : 'info';
      if (lvl === 'debug' && !config.debug) return;
      const message = truncate(args.map(describe).join(' '), CONFIG.MAX_MESSAGE_CHARS);
      post('log', { level: lvl, source: typeof source === 'string' ? source : String(source), message });
    } catch (_) {
      // Logging must never throw.
    }
  }

  // ── Event bus ──────────────────────────────────────────────────────────────────────────────
  const listeners = create(null);  // event name → array of functions

  function on(evt, fn) {
    if (typeof evt !== 'string' || typeof fn !== 'function') return () => {};
    try {
      (listeners[evt] || (listeners[evt] = [])).push(fn);
    } catch (e) {
      reportError('bridge.js', e);
    }
    return () => {
      try {
        const list = listeners[evt];
        const i = list ? list.indexOf(fn) : -1;
        if (i >= 0) list.splice(i, 1);
      } catch (_) { /* ignore */ }
    };
  }

  function emit(evt, ...args) {
    const list = typeof evt === 'string' ? listeners[evt] : undefined;
    if (!list || list.length === 0) return 0;
    const snapshot = list.slice();
    for (const fn of snapshot) {
      guard('on:' + evt, () => apply(fn, undefined, args));
    }
    return snapshot.length;
  }

  // ── Native → JS commands ───────────────────────────────────────────────────────────────────
  const commands = create(null);

  function command(name, fn) {
    if (typeof name !== 'string' || name === '' || typeof fn !== 'function') return false;
    if (commands[name]) {
      reportError('bridge.js', new Error('command "' + name + '" registered twice; keeping the first'));
      return false;
    }
    commands[name] = fn;
    return true;
  }

  function toResult(value) {
    if (value === undefined) return null;
    const safe = toJSONSafe(value);
    return safe === UNSERIALIZABLE ? { error: 'unserializable-result' } : safe;
  }

  function cmd(name, argsJSON) {
    try {
      const fn = typeof name === 'string' ? commands[name] : undefined;
      if (typeof fn !== 'function') return { error: 'unknown-command: ' + describe(name) };
      let args = {};
      if (typeof argsJSON === 'string' && argsJSON !== '') {
        try { args = jsonParse(argsJSON); } catch (_) { return { error: 'invalid-args' }; }
      } else if (argsJSON && typeof argsJSON === 'object') {
        args = argsJSON;
      }
      if (!args || typeof args !== 'object' || isArray(args)) args = {};
      const result = fn(args);
      if (isThenable(result)) {
        return Promise.resolve(result).then(toResult, (e) => {
          reportError('cmd:' + name, e);
          return { error: describe(e) };
        });
      }
      return toResult(result);
    } catch (e) {
      reportError('cmd:' + name, e);
      return { error: describe(e) };
    }
  }

  // ── Namespace ──────────────────────────────────────────────────────────────────────────────
  let hooks;
  const ns = {
    config,
    post,
    on,
    emit,
    command,
    cmd,
    log,
    guard,
  };
  defineProperty(ns, 'hooks', {
    enumerable: true,
    get() { return hooks; },
    set(value) {
      if (hooks !== undefined) {
        reportError('bridge.js', new Error('__ytadless.hooks is already set'));
        return;
      }
      if (value && typeof value === 'object') hooks = value;
    },
  });
  freeze(ns);

  try {
    defineProperty(window, NS, { value: ns, enumerable: false, writable: false, configurable: false });
  } catch (e) {
    reportError('bridge.js', e);
    return;
  }

  post('ready', { role: config.role, url: String(location.href) });
})();
