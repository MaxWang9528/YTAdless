// ad-fixtures.mjs — fixture loading and ad-key scanning shared by the Module A tests and
// tools/report.mjs. Owner: Module A (PLAN.md §6.1 "Generic fixture assertions").
//
// A fixture case is {name, endpoint, url, kind: 'json'|'html', text, local}. Committed fixtures
// come from tools/capture.mjs and are named <date>-<endpoint>-<id>.<ext>; the endpoint decides
// which URL the response is served from. Local captures (js/fixtures/local/, gitignored; Debug ›
// Capture from the device, CLAUDE.md maintenance loop) are read too when present: any .json that
// is a hooks.js `originals` entry ({url, text}), an array of them, or a capture result with an
// `originals` array; plus files named like the committed ones.

import fs from 'node:fs';
import path from 'node:path';
import { PATHS, readJSON, readText } from './harness.mjs';

export const ORIGIN = 'https://m.youtube.com';

/** Capture endpoint → the URL the page fetched it from (capture 2026-11-24). */
export const ENDPOINT_URLS = Object.freeze({
  player: `${ORIGIN}/youtubei/v1/player?prettyPrint=false`,
  get_watch: `${ORIGIN}/youtubei/v1/get_watch?prettyPrint=false`,
  next: `${ORIGIN}/youtubei/v1/next?prettyPrint=false`,
  browse: `${ORIGIN}/youtubei/v1/browse?prettyPrint=false`,
  search: `${ORIGIN}/youtubei/v1/search?prettyPrint=false`,
  reel_watch_sequence: `${ORIGIN}/youtubei/v1/reel/reel_watch_sequence?prettyPrint=false`,
  reel_item_watch: `${ORIGIN}/youtubei/v1/reel/reel_item_watch?prettyPrint=false`,
  guide: `${ORIGIN}/youtubei/v1/guide?prettyPrint=false`,
  watch: (id) => `${ORIGIN}/watch?v=${id}`,
  shorts: (id) => `${ORIGIN}/shorts/${id}`,
  home: () => `${ORIGIN}/`,
  results: (id) => `${ORIGIN}/results?search_query=${encodeURIComponent(id.replace(/_/g, ' '))}`,
});

/** Player-response ad fields (uBO json-prune lines, F6). */
export const PLAYER_AD_KEYS = Object.freeze(['adPlacements', 'playerAds', 'adSlots']);

/** Feed ad renderers: the keys of feed-ads.js AD_RENDERER_KEYS, read from the shipped script. */
export function feedAdKeys() {
  const source = readText(PATHS.scripts, 'feed-ads.js');
  const table = source.match(/const AD_RENDERER_KEYS = Object\.freeze\(\{([\s\S]*?)\}\);/);
  if (!table) throw new Error('feed-ads.js: AD_RENDERER_KEYS table not found');
  return [...table[1].matchAll(/^\s*([A-Za-z]+):/gm)].map((m) => m[1]);
}

export function knownAdKeys() {
  return [...PLAYER_AD_KEYS, ...feedAdKeys()];
}

/**
 * Ad-like key names. PLAN.md §6.1 writes `/(^|[a-z])(ad|ads|promo|promoted|sponsor)[A-Z_]/i`,
 * but with the `i` flag `[a-z]`/`[A-Z_]` match any letter (so `header`, `metadata`, `badges`
 * all hit) and without `$` it misses `playerAds`. This is the camelCase-word form it means: the
 * word is the key's first word (lowercase) or a later word (capitalised), and ends the key or
 * precedes a capital or `_`. So `adSlots`, `playerAds`, `mealbarPromoRenderer` hit, while
 * `uploadDate`, `payload`, `readaheadConfig` don't.
 */
export const AD_KEY_PATTERN = /(?:^(?:ads?|promo(?:ted)?|sponsor(?:ed)?)|(?:Ads?|Promo(?:ted)?|Sponsor(?:ed)?))(?:[A-Z_]|$)/;

/** Every property name in `value` (deep) → number of occurrences. */
export function keyCounts(value) {
  const counts = new Map();
  const stack = [value];
  while (stack.length) {
    const node = stack.pop();
    if (node === null || typeof node !== 'object') continue;
    if (Array.isArray(node)) { for (const v of node) stack.push(v); continue; }
    for (const [k, v] of Object.entries(node)) {
      counts.set(k, (counts.get(k) || 0) + 1);
      stack.push(v);
    }
  }
  return counts;
}

export function readAllowlist() {
  const file = path.join(PATHS.fixtures, 'ad-key-allowlist.json');
  return readJSON(file);
}

/** Ad-like keys in `value` that are neither known ad keys nor allowlisted. */
export function unknownAdKeys(value, allowlist = readAllowlist()) {
  const allowed = new Set(Object.keys(allowlist.keys));
  const known = new Set(knownAdKeys());
  return [...keyCounts(value).keys()].filter((k) => AD_KEY_PATTERN.test(k) && !allowed.has(k) && !known.has(k)).sort();
}

export function remainingKnownAdKeys(value) {
  const counts = keyCounts(value);
  return knownAdKeys().filter((k) => counts.has(k));
}

/** Shorts entries flagged as ads (uBO `entries.[-].command.reelWatchEndpoint.adClientParams.isAd`). */
export function shortsAdEntries(value) {
  const entries = value && Array.isArray(value.entries) ? value.entries : [];
  return entries.filter((e) => e?.command?.reelWatchEndpoint?.adClientParams?.isAd).length;
}

// ── Loading ──────────────────────────────────────────────────────────────────────────────

const NAME = /^(\d{4}-\d{2}-\d{2})-([a-z_]+)-(.+)\.(json|html)$/;

function caseFromFile(file, local) {
  const base = path.basename(file);
  const m = base.match(NAME);
  if (!m) return null;
  const [, date, endpoint, id, ext] = m;
  const url = ENDPOINT_URLS[endpoint];
  if (!url) return null;
  return {
    name: (local ? 'local/' : '') + base,
    date,
    endpoint,
    id,
    kind: ext,
    url: typeof url === 'function' ? url(id) : url,
    text: fs.readFileSync(file, 'utf8'),
    local,
  };
}

function endpointOf(url) {
  try {
    const u = new URL(url, ORIGIN);
    const m = u.pathname.match(/^\/youtubei\/v1\/(.+)$/);
    if (m) return m[1].replace(/^reel\//, '').replace(/\//g, '_');
    if (u.pathname === '/watch') return 'watch';
    if (u.pathname.startsWith('/shorts/')) return 'shorts';
    return 'page';
  } catch (_) {
    return 'unknown';
  }
}

function casesFromCapture(file) {
  let data;
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return []; }
  return casesFromCaptureData(data, path.relative(path.join(PATHS.fixtures, 'local'), file));
}

/** Cases from a parsed Debug › Capture file (`<role>-originals.json`, or a whole capture result). */
export function casesFromCaptureData(data, label) {
  const entries = Array.isArray(data) ? data : Array.isArray(data?.originals) ? data.originals : data && typeof data.text === 'string' ? [data] : [];
  return entries
    .map((e) => (e && typeof e.text === 'string' && typeof e.url === 'string' ? { ...e, url: apiUrlOf(e) } : null))
    .map((e, i) => (e && e.url ? {
      name: `local/${label}#${i}`,
      endpoint: endpointOf(e.url),
      id: String(i),
      kind: 'json',
      url: e.url,
      text: e.text,
      local: true,
    } : null))
    .filter(Boolean);
}

/**
 * The API URL a hooks.js `originals` entry is replayed from. fetch/xhr entries already carry one.
 * `initial` entries (inline page data, recorded with the page URL and a `window.<name>` target)
 * map to the endpoint that serves the same object, so the same pruners apply: every video the
 * player opens is a full page load (D15), so its player response is always an `initial` entry.
 */
function apiUrlOf(entry) {
  if (/\/youtubei\/v1\//.test(entry.url)) return entry.url;
  if (entry.source !== 'initial' || typeof entry.target !== 'string') return null;
  const target = entry.target;
  if (target === 'window.ytInitialPlayerResponse' || target.startsWith('window.ytplayer')) return ENDPOINT_URLS.player;
  if (target === 'window.ytInitialReelWatchSequenceResponse') return ENDPOINT_URLS.reel_watch_sequence;
  if (target === 'window.ytInitialData') {
    let pathname = '/';
    try { pathname = new URL(entry.url, ORIGIN).pathname; } catch (_) { /* keep '/' */ }
    return pathname === '/watch' ? ENDPOINT_URLS.next : pathname === '/results' ? ENDPOINT_URLS.search : ENDPOINT_URLS.browse;
  }
  return null;
}

function walkFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(full));
    else out.push(full);
  }
  return out.sort();
}

/**
 * All fixture cases. `dirs` picks committed subdirectories; `local: false` skips local captures.
 * Set YTADLESS_FIXTURES=committed to ignore js/fixtures/local/ (CI-like runs).
 */
export function loadCases({ dirs = ['player', 'feed', 'html'], local = process.env.YTADLESS_FIXTURES !== 'committed' } = {}) {
  const cases = [];
  for (const dir of dirs) {
    for (const file of walkFiles(path.join(PATHS.fixtures, dir))) {
      const c = caseFromFile(file, false);
      if (c) cases.push(c);
    }
  }
  if (local) {
    for (const file of walkFiles(path.join(PATHS.fixtures, 'local'))) {
      const named = caseFromFile(file, true);
      if (named) cases.push(named);
      else if (file.endsWith('.json')) cases.push(...casesFromCapture(file));
    }
  }
  return cases;
}

export const jsonCases = (opts) => loadCases(opts).filter((c) => c.kind === 'json');
export const htmlCases = (opts) => loadCases(opts).filter((c) => c.kind === 'html');

// ── HTML pages ───────────────────────────────────────────────────────────────────────────

const INITIAL_GLOBALS = /\b(ytInitialPlayerResponse|ytInitialData|ytInitialReelWatchSequenceResponse|ytplayer)\b/;
// Scripts that read YouTube's own runtime (ytcfg, yt.player…) throw in jsdom; these are the
// assignments the hooks trap, which only need the globals above.
const ASSIGNS_INITIAL = /(?:^|[;\s])(?:var\s+ytInitial\w+\s*=|window\[['"]ytInitial\w+['"]\]\s*=|window\.ytplayer\s*=)/;

/**
 * A watch/shorts/home page reduced to the inline scripts that assign the ytInitial* globals,
 * as a document the harness can load. Data blocks stay in the same order as in the page.
 */
export function initialScriptsPage(html) {
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)]
    .filter(([, attrs, body]) => !/\bsrc=/.test(attrs) && !/type="application\/(?:ld\+)?json"/.test(attrs) && INITIAL_GLOBALS.test(body) && ASSIGNS_INITIAL.test(body))
    .map(([, , body]) => `<script>${body}</script>`);
  return `<html><head></head><body><div id="player"></div>${scripts.join('\n')}</body></html>`;
}

/** Inline scripts assign hex-escaped strings and then parse them; the same data, decoded. */
export function decodeInitial(html, name) {
  const quoted = html.match(new RegExp(`var ${name} = '((?:[^'\\\\]|\\\\.)*)';`));
  if (quoted) {
    // A single-quoted JS string literal → a JSON string literal → the JSON text it holds.
    const asJSON = quoted[1].replace(/\\x([0-9a-fA-F]{2})/g, '\\u00$1').replace(/\\'/g, "'").replace(/"/g, '\\"');
    return JSON.parse(JSON.parse(`"${asJSON}"`));
  }
  const obj = html.match(new RegExp(`var ${name} = (\\{[\\s\\S]*?\\});(?:var |</script>)`));
  return obj ? JSON.parse(obj[1]) : null;
}

// ── Running a case through the shipped scripts ──────────────────────────────────────────

/**
 * Serves `c` to a harness page with every script of `role` loaded, the way the page would get it:
 * JSON fixtures through fetch (or XHR with `api: 'xhr'`), HTML pages through their inline scripts.
 * Resolves to {page, value (what the page ends up with), hits ({rule: count}), emitted}.
 */
export async function runCase(createPage, c, { role = 'player', api = 'fetch' } = {}) {
  const emitted = [];
  const watch = (win) => {
    // Record playerResponse events from the moment hooks.js installs (before the HTML runs).
    const ns = win.__ytadless;
    if (ns) ns.on('playerResponse', (pr, info) => emitted.push({ videoId: pr?.videoDetails?.videoId ?? null, source: info?.source }));
  };
  let page;
  let value;
  if (c.kind === 'html') {
    page = await createPage({ role, url: c.url, until: 'start' });
    watch(page.window);
    page.finishLoading({ html: initialScriptsPage(c.text) });
    const win = page.window;
    value = {
      ytInitialPlayerResponse: win.ytInitialPlayerResponse ?? null,
      ytInitialData: win.ytInitialData ?? null,
      ytInitialReelWatchSequenceResponse: win.ytInitialReelWatchSequenceResponse ?? null,
    };
    value = JSON.parse(JSON.stringify(value));
  } else {
    page = await createPage({ role, url: `${ORIGIN}/`, until: 'start', routes: [{ match: (u) => u === c.url, body: c.text, headers: { 'content-type': 'application/json' } }] });
    watch(page.window);
    page.finishLoading();
    const win = page.window;
    const text = api === 'xhr'
      ? await new Promise((resolve, reject) => {
        const xhr = new win.XMLHttpRequest();
        xhr.open('POST', c.url);
        xhr.onload = () => resolve(xhr.responseText);
        xhr.onerror = () => reject(new Error('xhr failed'));
        xhr.send('{}');
      })
      : await (await win.fetch(c.url, { method: 'POST', body: '{}' })).text();
    value = JSON.parse(text);
  }
  const hits = {};
  for (const m of page.posted('filterHit')) hits[m.rule] = (hits[m.rule] || 0) + m.count;
  return { page, value, hits, emitted };
}
