// hooks.js — owner: Module A (PLAN.md §6.1 Layer 2, §5.2 `hooks`).
//
// Installs every JSON interception point once and dispatches what passes through them to the
// registered pruners. player-ads.js, feed-ads.js (and background.js, for youThereRenderer)
// register with `__ytadless.hooks.addPruner(...)`; none of them touch fetch/XHR/JSON themselves.
//
//   interception point                         target string that pruner `urls` match against
//   JSON.parse (innertube-shaped results only)  'JSON.parse'
//   fetch  /youtubei/v1/…  (Response rewrapped) the request URL
//   XMLHttpRequest responseText / response      the request URL
//   window.ytInitialPlayerResponse / …Data …    'window.<name>'   (accessor traps, so an inline
//   window.ytplayer.{bootstrapPlayerResponse,config}  'window.ytplayer.<key>'   `var x = {…}` hits our setter)
//
// addPruner({name, urls?, paths?, fn?, text?}) → bool
//   name   the filterHit rule name (posted with the number of removals, only when > 0)
//   urls   strings (substring) or RegExps tested against the target; omitted = every target
//   paths  uBO `json-prune` paths (dialect below); each match is deleted
//   fn     (value, {source, target, url}) → number | {ruleName: number}; edits value in place
//   text   [[search, replace], …] on the raw response text before parsing (fetch/XHR only):
//          uBO's other strategy, `"adPlacements"` → `"no_ads"`
// Path dialect (uBO json-prune / json-edit subset): `a.b`, `*` (any key or index), `[]` (every
// array element), `..key` (key at any depth), `[-]` (remove the containing array element when
// the rest of the path exists), `[?.sub.path]` (children where sub.path exists).
//
// originals: an Array (newest last) of pre-prune responses for Debug › Capture and fixtures:
//   {source: 'fetch'|'xhr'|'initial', url, target, time, text}; bounded by CONFIG.ORIGINALS_*.
// After pruning, every player response found is emitted as `playerResponse` (pr, {source, url}).
(() => {
  'use strict';

  const SOURCE = 'hooks.js';
  // Everything YouTube can change goes here, each entry citing where it came from (CLAUDE.md).
  const CONFIG = Object.freeze({
    // fetch/XHR URLs whose JSON bodies are read and pruned. m.youtube.com's innertube API; mweb
    // watch navigations go through /youtubei/v1/get_watch (F6; capture 2026-11-24).
    INTERCEPT_URLS: [/\/youtubei\/v1\//],
    // Globals that inline scripts in the watch/shorts/home HTML assign (capture 2026-11-24):
    // `var ytInitialPlayerResponse = null;` then `= {…}`; `var ytInitialData = '\x7b…'` (a string)
    // then `window['ytInitialData'] = JSON.parse(window['ytInitialData'])`; the Shorts sequence
    // the same way. Strings are stored untouched; objects are pruned on assignment.
    TRAPS: ['ytInitialPlayerResponse', 'ytInitialData', 'ytInitialReelWatchSequenceResponse'],
    // window.ytplayer keys that carry a player response, and where it sits inside each value
    // (watch HTML 2026-11-24: `ytplayer.bootstrapPlayerResponse = window['ytInitialPlayerResponse']`,
    // `ytplayer.config = {args: {raw_player_response: …}}`).
    YTPLAYER_KEYS: { bootstrapPlayerResponse: [], config: ['args', 'raw_player_response'] },
    // Where player responses sit in a pruned value, for the `playerResponse` event: the value itself
    // (/player, initial), get_watch's `[].playerResponse`, reel_item_watch's `playerResponse`,
    // resolve_url's prefetch (uBO json-prune-fetch-response lines, F6).
    PLAYER_RESPONSE_PATHS: ['', 'playerResponse', '[].playerResponse', 'endpoint.watchEndpoint.unserializedPrefetchData.playerResponse'],
    PLAYER_RESPONSE_KEYS: ['videoDetails', 'playabilityStatus'],  // has either → a player response
    // JSON.parse results are only pruned when they look like innertube data: cheap, and keeps the
    // hook off YouTube's many small parses. (A top-level key, or the first element's for arrays.)
    JSON_PARSE_MARKERS: ['responseContext', 'playerResponse', 'videoDetails'],
    NO_BODY_STATUS: [101, 204, 205, 304],
    ORIGINALS_MAX_ENTRIES: 24,
    ORIGINALS_MAX_CHARS: 8_000_000,   // total text kept; oldest entries are dropped first
  });

  const ns = window.__ytadless;
  if (!ns) return;

  ns.guard(SOURCE, () => {
    if (ns.hooks !== undefined) return;  // a second copy in the same document does nothing

    // ── Originals (captured before anyone else wraps them) ─────────────────────────────────
    const origParse = JSON.parse;
    const origStringify = JSON.stringify;
    const origFetch = typeof window.fetch === 'function' ? window.fetch : null;
    const OrigResponse = typeof window.Response === 'function' ? window.Response : null;
    const XHR = typeof window.XMLHttpRequest === 'function' ? window.XMLHttpRequest : null;
    const apply = Reflect.apply;
    const hasOwn = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
    const isObject = (v) => v !== null && typeof v === 'object';
    const reportError = (e) => ns.guard(SOURCE, () => { throw e; });

    // ── Path engine ────────────────────────────────────────────────────────────────────────
    const compiledPaths = new Map();

    function parsePath(text) {
      if (compiledPaths.has(text)) return compiledPaths.get(text);
      const steps = [];
      let i = 0;
      const name = () => {
        const start = i;
        while (i < text.length && text[i] !== '.' && text[i] !== '[') i += 1;
        return text.slice(start, i);
      };
      while (i < text.length) {
        if (text.startsWith('..', i)) {
          i += 2;
          const key = name();
          if (!key) throw new Error('bad path "' + text + '": .. needs a key');
          steps.push({ t: 'desc', key });
        } else if (text[i] === '.') {
          i += 1;
        } else if (text.startsWith('[]', i)) {
          i += 2;
          steps.push({ t: 'each' });
        } else if (text.startsWith('[-]', i)) {
          i += 3;
          steps.push({ t: 'removeElement' });
        } else if (text.startsWith('[?', i)) {
          let depth = 0;
          let j = i;
          for (; j < text.length; j += 1) {
            if (text[j] === '[') depth += 1;
            else if (text[j] === ']' && --depth === 0) break;
          }
          if (j >= text.length) throw new Error('bad path "' + text + '": unterminated [?');
          const sub = text.slice(i + 2, j).replace(/^\./, '');
          // `*[?.k]` and `[?.k]` both mean "the children that have k" (uBO json-edit).
          if (steps.length && steps[steps.length - 1].t === 'any') steps.pop();
          steps.push({ t: 'filter', sub: parsePath(sub) });
          i = j + 1;
        } else if (text[i] === '*') {
          i += 1;
          steps.push({ t: 'any' });
        } else {
          const key = name();
          if (!key) throw new Error('bad path "' + text + '" at ' + i);
          steps.push({ t: 'key', key });
        }
      }
      compiledPaths.set(text, steps);
      return steps;
    }

    function children(node) {
      if (Array.isArray(node)) return node.map((v, k) => [k, v]);
      if (isObject(node)) return Object.keys(node).map((k) => [k, node[k]]);
      return [];
    }

    // Calls visit(parent, key, value) for every location the steps reach from `node`; returns
    // true from visit to stop early. `ref` is the location of `node` itself.
    function walk(node, steps, i, ref, visit) {
      if (i === steps.length) return visit(ref.parent, ref.key, node) === true;
      const step = steps[i];
      switch (step.t) {
        case 'key':
          if (isObject(node) && !Array.isArray(node) && hasOwn(node, step.key)) {
            return walk(node[step.key], steps, i + 1, { parent: node, key: step.key }, visit);
          }
          return false;
        case 'any':
          for (const [k, v] of children(node)) if (walk(v, steps, i + 1, { parent: node, key: k }, visit)) return true;
          return false;
        case 'each':
          if (!Array.isArray(node)) return false;
          for (let k = 0; k < node.length; k += 1) if (walk(node[k], steps, i + 1, { parent: node, key: k }, visit)) return true;
          return false;
        case 'filter':
          for (const [k, v] of children(node)) {
            if (exists(v, step.sub) && walk(v, steps, i + 1, { parent: node, key: k }, visit)) return true;
          }
          return false;
        case 'removeElement':
          if (!Array.isArray(node)) return false;
          for (let k = 0; k < node.length; k += 1) {
            if (exists(node[k], steps.slice(i + 1)) && visit(node, k, node[k]) === true) return true;
          }
          return false;
        case 'desc': {
          // Iterative, so a deep innertube tree can't overflow the stack.
          const stack = [node];
          const seen = new Set();
          while (stack.length) {
            const current = stack.pop();
            if (!isObject(current) || seen.has(current)) continue;
            seen.add(current);
            if (!Array.isArray(current) && hasOwn(current, step.key)) {
              if (walk(current[step.key], steps, i + 1, { parent: current, key: step.key }, visit)) return true;
            }
            const kids = children(current);
            for (let k = kids.length - 1; k >= 0; k -= 1) if (isObject(kids[k][1])) stack.push(kids[k][1]);
          }
          return false;
        }
        default:
          return false;
      }
    }

    function exists(node, steps) {
      return walk(node, steps, 0, { parent: null, key: null }, () => true);
    }

    /** Values found at `path` (an empty path is the value itself). */
    function find(value, path) {
      const out = [];
      walk(value, path ? parsePath(path) : [], 0, { parent: null, key: null }, (p, k, v) => { out.push(v); });
      return out;
    }

    /** Deletes every match of `path`; returns how many entries were removed. */
    function prune(value, path) {
      const steps = parsePath(path);
      const hits = new Map();  // parent → Set of keys
      walk(value, steps, 0, { parent: null, key: null }, (parent, key) => {
        if (parent === null) return;
        if (!hits.has(parent)) hits.set(parent, new Set());
        hits.get(parent).add(key);
      });
      let count = 0;
      for (const [parent, keys] of hits) {
        if (Array.isArray(parent)) {
          const indexes = [...keys].sort((a, b) => b - a);
          for (const index of indexes) { parent.splice(index, 1); count += 1; }
        } else {
          for (const key of keys) { if (delete parent[key]) count += 1; }
        }
      }
      return count;
    }

    // ── Pruner registry ────────────────────────────────────────────────────────────────────
    const pruners = [];

    function matchesTarget(pruner, target) {
      if (!pruner.urls) return true;
      return pruner.urls.some((u) => (u instanceof RegExp ? u.test(target) : target.includes(u)));
    }

    function addPruner(spec) {
      return ns.guard(SOURCE, () => {
        if (!spec || typeof spec.name !== 'string' || spec.name === '') throw new Error('addPruner: needs a name');
        const urls = spec.urls == null ? null : [].concat(spec.urls);
        const paths = spec.paths == null ? [] : [].concat(spec.paths);
        for (const p of paths) parsePath(p);  // fail at registration, not per response
        const text = spec.text == null ? [] : [].concat(spec.text);
        if (spec.fn != null && typeof spec.fn !== 'function') throw new Error('addPruner(' + spec.name + '): fn is not a function');
        if (!paths.length && !spec.fn && !text.length) throw new Error('addPruner(' + spec.name + '): needs paths, fn or text');
        pruners.push(Object.freeze({ name: spec.name, urls, paths, fn: spec.fn || null, text }));
        return true;
      }) === true;
    }

    function tally(hits, name, n) {
      const count = Number(n);
      if (Number.isFinite(count) && count > 0) hits[name] = (hits[name] || 0) + Math.round(count);
    }

    function postHits(hits) {
      for (const name of Object.keys(hits)) ns.post('filterHit', { rule: name, count: hits[name] });
    }

    /** Runs the matching pruners over a parsed value, in place. Returns the hit counts. */
    function runPruners(value, ctx) {
      const hits = {};
      if (!isObject(value)) return hits;
      for (const pruner of pruners) {
        if (!matchesTarget(pruner, ctx.target)) continue;
        ns.guard(SOURCE + ':' + pruner.name, () => {
          for (const path of pruner.paths) tally(hits, pruner.name, prune(value, path));
          if (pruner.fn) {
            const result = pruner.fn(value, ctx);
            if (isObject(result)) for (const k of Object.keys(result)) tally(hits, k, result[k]);
            else tally(hits, pruner.name, result === true ? 1 : result);
          }
        });
      }
      postHits(hits);
      return hits;
    }

    function runTextRules(text, target) {
      const hits = {};
      let out = text;
      for (const pruner of pruners) {
        if (!pruner.text.length || !matchesTarget(pruner, target)) continue;
        for (const [search, replace] of pruner.text) {
          const parts = out.split(search);
          if (parts.length > 1) {
            tally(hits, pruner.name, parts.length - 1);
            out = parts.join(replace);
          }
        }
      }
      return { text: out, hits };
    }

    // ── Originals ring buffer ──────────────────────────────────────────────────────────────
    const originals = [];
    let originalsChars = 0;

    function keepOriginal(entry) {
      if (typeof entry.text !== 'string') return;
      originals.push(Object.freeze(entry));
      originalsChars += entry.text.length;
      while (originals.length > CONFIG.ORIGINALS_MAX_ENTRIES || (originalsChars > CONFIG.ORIGINALS_MAX_CHARS && originals.length > 1)) {
        originalsChars -= originals.shift().text.length;
      }
    }

    // ── Player responses ───────────────────────────────────────────────────────────────────
    const emitted = new WeakSet();

    function isPlayerResponse(v) {
      return isObject(v) && !Array.isArray(v) && CONFIG.PLAYER_RESPONSE_KEYS.some((k) => hasOwn(v, k));
    }

    function emitPlayerResponses(value, source, url) {
      for (const path of CONFIG.PLAYER_RESPONSE_PATHS) {
        for (const pr of find(value, path)) {
          if (!isPlayerResponse(pr) || emitted.has(pr)) continue;
          emitted.add(pr);
          ns.emit('playerResponse', pr, { source, url });
        }
      }
    }

    // ── Processing a response body (fetch / XHR) ──────────────────────────────────────────
    function shouldIntercept(url) {
      return typeof url === 'string' && CONFIG.INTERCEPT_URLS.some((re) => re.test(url)) && pruners.length > 0;
    }

    /** Raw text → {text, changed}. Keeps the original, prunes, emits player responses. */
    function processText(raw, url, source) {
      keepOriginal({ source, url, target: url, time: Date.now(), text: raw });
      const replaced = runTextRules(raw, url);
      postHits(replaced.hits);
      let value;
      try {
        value = apply(origParse, JSON, [replaced.text]);
      } catch (_) {
        return { text: replaced.text, value: undefined, changed: replaced.text !== raw };
      }
      const hits = runPruners(value, { source, target: url, url });
      const pruned = Object.keys(hits).length > 0;
      emitPlayerResponses(value, source, url);
      const text = pruned ? apply(origStringify, JSON, [value]) : replaced.text;
      return { text, value, changed: text !== raw };
    }

    // ── JSON.parse ─────────────────────────────────────────────────────────────────────────
    function looksLikeInnertube(v) {
      const probe = Array.isArray(v) ? v[0] : v;
      return isObject(probe) && CONFIG.JSON_PARSE_MARKERS.some((k) => hasOwn(probe, k));
    }

    const parseProxy = new Proxy(origParse, {
      apply(target, thisArg, args) {
        const result = apply(target, thisArg, args);
        if (isObject(result) && pruners.length > 0) {
          ns.guard(SOURCE, () => {
            if (looksLikeInnertube(result)) runPruners(result, { source: 'JSON.parse', target: 'JSON.parse', url: String(location.href) });
          });
        }
        return result;
      },
    });
    JSON.parse = parseProxy;

    // ── fetch ──────────────────────────────────────────────────────────────────────────────
    function requestURL(input) {
      try {
        if (typeof input === 'string') return new URL(input, location.href).href;
        if (input && typeof input.url === 'string') return input.url;
        if (input && typeof input.href === 'string') return input.href;
        return String(input);
      } catch (_) {
        return String(input);
      }
    }

    async function rewriteResponse(response, url) {
      if (!response || CONFIG.NO_BODY_STATUS.includes(response.status) || response.bodyUsed) return response;
      const raw = await response.clone().text();
      const result = processText(raw, url, 'fetch');
      if (!result.changed || !OrigResponse) return response;
      let headers = response.headers;
      try {
        headers = new window.Headers(response.headers);
        headers.delete('content-length');  // the body changed size
      } catch (_) { /* keep the originals */ }
      const rewrapped = new OrigResponse(result.text, { status: response.status, statusText: response.statusText, headers });
      for (const key of ['url', 'redirected', 'type']) {
        try { Object.defineProperty(rewrapped, key, { value: response[key], configurable: true }); } catch (_) { /* keep */ }
      }
      return rewrapped;
    }

    if (origFetch) {
      window.fetch = new Proxy(origFetch, {
        apply(target, thisArg, args) {
          const pending = apply(target, thisArg, args);
          let url = '';
          try { url = requestURL(args[0]); } catch (_) { return pending; }
          if (!shouldIntercept(url)) return pending;
          return pending.then((response) => rewriteResponse(response, url).then(
            (r) => r,
            (e) => { reportError(e); return response; },
          ));
        },
      });
    }

    // ── XMLHttpRequest ─────────────────────────────────────────────────────────────────────
    if (XHR && XHR.prototype) {
      const proto = XHR.prototype;
      const origOpen = proto.open;
      const textDesc = Object.getOwnPropertyDescriptor(proto, 'responseText');
      const responseDesc = Object.getOwnPropertyDescriptor(proto, 'response');
      const readyStateDesc = Object.getOwnPropertyDescriptor(proto, 'readyState');
      const typeDesc = Object.getOwnPropertyDescriptor(proto, 'responseType');
      const xhrURL = new WeakMap();
      const xhrCache = new WeakMap();  // xhr → {raw, text} for text, or the pruned object for json

      const DONE = 4;
      const readyState = (xhr) => (readyStateDesc && readyStateDesc.get ? apply(readyStateDesc.get, xhr, []) : xhr.readyState);

      function prunedText(xhr, raw) {
        const url = xhrURL.get(xhr);
        if (typeof raw !== 'string' || raw === '' || readyState(xhr) !== DONE || !shouldIntercept(url)) return raw;
        const cached = xhrCache.get(xhr);
        if (cached && cached.raw === raw) return cached.text;
        const result = ns.guard(SOURCE, () => processText(raw, url, 'xhr'));
        const text = result ? result.text : raw;
        xhrCache.set(xhr, { raw, text });
        return text;
      }

      if (typeof origOpen === 'function') {
        proto.open = new Proxy(origOpen, {
          apply(target, thisArg, args) {
            try { xhrURL.set(thisArg, new URL(String(args[1]), location.href).href); } catch (_) { /* leave unset */ }
            return apply(target, thisArg, args);
          },
        });
      }

      if (textDesc && textDesc.get) {
        Object.defineProperty(proto, 'responseText', {
          configurable: true,
          enumerable: textDesc.enumerable,
          get() {
            const raw = apply(textDesc.get, this, []);
            return prunedText(this, raw);
          },
        });
      }

      if (responseDesc && responseDesc.get) {
        Object.defineProperty(proto, 'response', {
          configurable: true,
          enumerable: responseDesc.enumerable,
          get() {
            const raw = apply(responseDesc.get, this, []);
            if (typeof raw === 'string') return prunedText(this, raw);
            const type = typeDesc && typeDesc.get ? apply(typeDesc.get, this, []) : '';
            if (type === 'json' && isObject(raw) && readyState(this) === DONE) {
              const url = xhrURL.get(this);
              if (shouldIntercept(url) && xhrCache.get(this) !== raw) {
                xhrCache.set(this, raw);
                ns.guard(SOURCE, () => {
                  keepOriginal({ source: 'xhr', url, target: url, time: Date.now(), text: apply(origStringify, JSON, [raw]) });
                  runPruners(raw, { source: 'xhr', target: url, url });
                  emitPlayerResponses(raw, 'xhr', url);
                });
              }
            }
            return raw;
          },
        });
      }
    }

    // ── Accessor traps on the ytInitial* globals and window.ytplayer ───────────────────────
    const processedInitial = new WeakSet();

    function processInitial(value, target) {
      if (!isObject(value) || processedInitial.has(value)) return;
      processedInitial.add(value);
      if (pruners.length > 0) {
        keepOriginal({ source: 'initial', url: String(location.href), target, time: Date.now(), text: apply(origStringify, JSON, [value]) });
        runPruners(value, { source: 'initial', target, url: String(location.href) });
      }
      emitPlayerResponses(value, 'initial', String(location.href));
    }

    function trap(owner, key, target, onSet) {
      const existing = Object.getOwnPropertyDescriptor(owner, key);
      if (existing && (!existing.configurable || existing.get || existing.set)) return;
      let stored = existing ? existing.value : undefined;
      Object.defineProperty(owner, key, {
        configurable: true,
        enumerable: true,
        get() { return stored; },
        set(value) {
          stored = value;
          ns.guard(SOURCE, () => onSet(value, target));
        },
      });
      if (stored !== undefined) ns.guard(SOURCE, () => onSet(stored, target));
    }

    for (const name of CONFIG.TRAPS) trap(window, name, 'window.' + name, processInitial);

    trap(window, 'ytplayer', 'window.ytplayer', (value) => {
      if (!isObject(value)) return;
      for (const key of Object.keys(CONFIG.YTPLAYER_KEYS)) {
        const inner = CONFIG.YTPLAYER_KEYS[key];
        trap(value, key, 'window.ytplayer.' + key, (v, target) => {
          let pr = v;
          for (const k of inner) pr = isObject(pr) ? pr[k] : undefined;
          processInitial(pr, target);
        });
      }
    });

    ns.hooks = Object.freeze({
      addPruner,
      originals,
      // For tests and Debug tooling; not part of the §5.2 contract.
      prune,
      find,
      parsePath,
    });
  });
})();
