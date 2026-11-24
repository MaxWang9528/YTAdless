#!/usr/bin/env node
// capture.mjs — anonymous m.youtube.com fixtures for the ad tests. Owner: Module A (PLAN.md §6.1, §8).
//
//   node tools/capture.mjs [videoId…] [--short <id>] [--search <query>]… [--no-home] [--date YYYY-MM-DD] [--out <dir>]
//
// With no video ids it tries CONFIG.CANDIDATE_VIDEOS and keeps the first CONFIG.WANT_AD_VIDEOS
// whose /player response carries ads (adPlacements / playerAds / adSlots); ids you name are
// always kept. Writes, named <date>-<endpoint>-<id>.<ext> (CLAUDE.md › Fixtures):
//   player/<date>-player-<id>.json            innertube /youtubei/v1/player (MWEB, with signatureTimestamp)
//   player/<date>-get_watch-<id>.json         innertube /youtubei/v1/get_watch (an array)
//   html/<date>-watch-<id>.html               the watch page (ytInitialPlayerResponse / ytInitialData)
//   html/<date>-shorts-<id>.html              the Shorts page (ytInitialReelWatchSequenceResponse)
//   feed/<date>-reel_watch_sequence-<id>.json the Shorts sequence
//   html/<date>-home-home.html, feed/<date>-browse-home.json     the home feed
//   html/<date>-results-<slug>.html, feed/<date>-search-<slug>.json  a search feed
//
// ANONYMOUS ONLY. It never reads or sends account cookies or credentials: each run starts a
// fresh signed-out session (only the visitor cookies YouTube sets on the first response).
// Responses are scrubbed before writing: the client IP (remoteHost, `ip=` and `/ip/…/` in
// googlevideo URLs, and every other occurrence of that address) and visitorData. The run fails
// if the address still appears anywhere afterwards.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CONFIG = Object.freeze({
  ORIGIN: 'https://m.youtube.com',
  // = js/test/harness.mjs IPHONE_SAFARI_UA (iPhone Safari; what the app's webviews send, D17).
  USER_AGENT: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
  ACCEPT_LANGUAGE: 'en-US,en;q=0.9',
  // Popular monetised uploads; signed-out /player responses for these carried ads on 2026-11-24.
  CANDIDATE_VIDEOS: ['0e3GPea1Tyg', 'dQw4w9WgXcQ', 'kJQP7kiw5Fk', 'JGwWNGJdvx8', 'RgKAFK5djSk', 'OPf0YbXqDm0', 'hT_nvWreIhg', 'CevxZvSJLk8'],
  WANT_AD_VIDEOS: 3,
  DEFAULT_SHORT: 'ZZ8NTvw8_lU',
  DEFAULT_SEARCH: 'iphone 17 case',
  PLAYER_AD_KEYS: ['adPlacements', 'playerAds', 'adSlots'],
  DELAY_MS: 600,   // between requests; be polite
});

const HERE = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const opts = { videos: [], short: CONFIG.DEFAULT_SHORT, searches: [], home: true, date: new Date().toISOString().slice(0, 10), out: path.join(HERE, '..', 'fixtures') };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--short') opts.short = argv[++i];
    else if (a === '--no-short') opts.short = null;
    else if (a === '--search') opts.searches.push(argv[++i]);
    else if (a === '--no-home') opts.home = false;
    else if (a === '--date') opts.date = argv[++i];
    else if (a === '--out') opts.out = path.resolve(argv[++i]);
    else if (a === '--help' || a === '-h') { console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 20).join('\n')); process.exit(0); }
    else if (/^[A-Za-z0-9_-]{11}$/.test(a)) opts.videos.push(a);
    else throw new Error(`unknown argument ${a}`);
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(opts.date)) throw new Error('--date must be YYYY-MM-DD');
  if (opts.searches.length === 0) opts.searches.push(CONFIG.DEFAULT_SEARCH);
  return opts;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A signed-out session: only cookies YouTube sets during this run. */
class Session {
  constructor() { this.cookies = new Map(); this.ip = new Set(); }

  absorb(response) {
    for (const c of response.headers.getSetCookie?.() ?? []) {
      const [pair] = c.split(';');
      const eq = pair.indexOf('=');
      if (eq > 0) this.cookies.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }
  }

  headers(extra = {}) {
    const h = { 'user-agent': CONFIG.USER_AGENT, 'accept-language': CONFIG.ACCEPT_LANGUAGE, ...extra };
    if (this.cookies.size) h.cookie = [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; ');
    return h;
  }

  async get(url) {
    await sleep(CONFIG.DELAY_MS);
    const res = await fetch(url, { headers: this.headers(), redirect: 'follow' });
    this.absorb(res);
    if (/consent\.(youtube|google)\.com/.test(res.url)) throw new Error(`redirected to a consent page (${res.url}); run from a region without one`);
    if (!res.ok) throw new Error(`GET ${url} → ${res.status}`);
    return res.text();
  }

  async innertube(endpoint, body) {
    await sleep(CONFIG.DELAY_MS);
    const res = await fetch(`${CONFIG.ORIGIN}/youtubei/v1/${endpoint}?prettyPrint=false`, {
      method: 'POST',
      headers: this.headers({
        'content-type': 'application/json',
        origin: CONFIG.ORIGIN,
        'x-youtube-client-name': '2',
        'x-youtube-client-version': this.clientVersion,
        ...(this.visitorData ? { 'x-goog-visitor-id': this.visitorData } : {}),
      }),
      body: JSON.stringify({ context: this.context(), ...body }),
    });
    this.absorb(res);
    const text = await res.text();
    if (!res.ok) throw new Error(`POST ${endpoint} → ${res.status}: ${text.slice(0, 200)}`);
    return text;
  }

  context() {
    return { client: { clientName: 'MWEB', clientVersion: this.clientVersion, hl: 'en', gl: 'US', visitorData: this.visitorData, userAgent: CONFIG.USER_AGENT } };
  }

  /** Reads the innertube client config and the player's signatureTimestamp from a page. */
  async bootstrap(html) {
    this.clientVersion = html.match(/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/)?.[1];
    this.visitorData = html.match(/"VISITOR_DATA":"([^"]+)"/)?.[1];
    if (!this.clientVersion) throw new Error('no INNERTUBE_CLIENT_VERSION in the page');
    const jsUrl = html.match(/"jsUrl":"([^"]+)"/)?.[1];
    if (jsUrl && !this.sts) {
      const js = await this.get(new URL(jsUrl, CONFIG.ORIGIN).href);
      this.sts = Number(js.match(/signatureTimestamp:?\s*(\d+)/)?.[1] ?? js.match(/\bsts:\s*(\d+)/)?.[1]) || undefined;
    }
    // Without a signatureTimestamp /player answers "The page needs to be reloaded" and no ads.
    if (!this.sts) throw new Error('could not read signatureTimestamp from the player script');
  }

  playerRequest(videoId) {
    return { videoId, contentCheckOk: true, racyCheckOk: true, playbackContext: { contentPlaybackContext: { signatureTimestamp: this.sts, html5Preference: 'HTML5_PREF_WANTS' } } };
  }
}

// ── Scrubbing ──────────────────────────────────────────────────────────────────────────────

const IPV4 = String.raw`(?:\d{1,3}\.){3}\d{1,3}`;
const IPV6 = String.raw`[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7}`;

function learnIPs(text, session) {
  for (const re of [/"remoteHost":"([^"]+)"/g, new RegExp(String.raw`[?&]ip=(${IPV4}|${IPV6})`, 'g'), new RegExp(String.raw`/ip/(${IPV4}|${IPV6})/`, 'g')]) {
    for (const m of text.matchAll(re)) session.ip.add(decodeURIComponent(m[1]));
  }
  // The URL-encoded form too (googlevideo URLs inside JSON strings).
  for (const ip of [...session.ip]) session.ip.add(encodeURIComponent(ip));
}

function scrub(text, session) {
  learnIPs(text, session);
  let out = text
    .replace(/"remoteHost":"[^"]*"/g, '"remoteHost":"0.0.0.0"')
    .replace(new RegExp(String.raw`([?&]ip=)(${IPV4}|${IPV6})`, 'g'), '$10.0.0.0')
    .replace(new RegExp(String.raw`(/ip/)(${IPV4}|${IPV6})/`, 'g'), '$10.0.0.0/')
    .replace(/("visitorData"\s*:\s*")[^"]*"/g, '$1REDACTED"')
    .replace(/("(?:VISITOR_DATA|XSRF_TOKEN|DATASYNC_ID)"\s*:\s*")[^"]*"/g, '$1REDACTED"')
    // Inside the hex-escaped ytInitialData strings of the HTML pages: visitorData\x22:\x22…\x22
    .replace(/((?:visitorData|VISITOR_DATA)\\x22:\\x22)[^\\"']*/g, '$1REDACTED')
    .replace(/(remoteHost\\x22:\\x22)[^\\"']*/g, '$10.0.0.0');
  for (const ip of session.ip) out = out.split(ip).join('0.0.0.0');
  if (session.visitorData) out = out.split(session.visitorData).join('REDACTED');
  return out;
}

function assertScrubbed(file, text, session) {
  for (const ip of session.ip) {
    if (ip !== '0.0.0.0' && text.includes(ip)) throw new Error(`${file}: still contains the client address`);
  }
  if (/"remoteHost":"(?!0\.0\.0\.0")|remoteHost\\x22:\\x22(?!0\.0\.0\.0)/.test(text)) throw new Error(`${file}: remoteHost not scrubbed`);
  if (/"visitorData":"(?!REDACTED")|visitorData\\x22:\\x22(?!REDACTED)/i.test(text)) throw new Error(`${file}: visitorData not scrubbed`);
}

// ── Main ───────────────────────────────────────────────────────────────────────────────────

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, '');

function playerAdKeys(json) {
  const pr = Array.isArray(json) ? json[0]?.playerResponse : json;
  return CONFIG.PLAYER_AD_KEYS.filter((k) => pr && Object.hasOwn(pr, k));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const session = new Session();
  const pending = [];  // [relativePath, text]
  const save = (dir, endpoint, id, ext, text) => pending.push([path.join(dir, `${opts.date}-${endpoint}-${id}.${ext}`), text]);
  const pretty = (text) => text;  // kept byte-for-byte as received

  const homeHTML = await session.get(`${CONFIG.ORIGIN}/`);
  await session.bootstrap(homeHTML);
  console.log(`session: MWEB ${session.clientVersion}, signatureTimestamp ${session.sts}`);

  if (opts.home) {
    save('html', 'home', 'home', 'html', homeHTML);
    save('feed', 'browse', 'home', 'json', pretty(await session.innertube('browse', { browseId: 'FEwhat_to_watch' })));
  }
  for (const query of opts.searches) {
    const id = slug(query);
    save('html', 'results', id, 'html', await session.get(`${CONFIG.ORIGIN}/results?search_query=${encodeURIComponent(query)}`));
    save('feed', 'search', id, 'json', pretty(await session.innertube('search', { query })));
  }

  const explicit = opts.videos.length > 0;
  const candidates = explicit ? opts.videos : CONFIG.CANDIDATE_VIDEOS;
  let kept = 0;
  let htmlSaved = false;
  for (const id of candidates) {
    if (!explicit && kept >= CONFIG.WANT_AD_VIDEOS) break;
    const player = await session.innertube('player', { ...session.playerRequest(id) });
    const ads = playerAdKeys(JSON.parse(player));
    const status = JSON.parse(player).playabilityStatus?.status;
    console.log(`video ${id}: playability ${status}; ad keys: ${ads.join(', ') || 'none'}`);
    if (!explicit && ads.length === 0) continue;
    kept += 1;
    save('player', 'player', id, 'json', pretty(player));
    const watch = await session.innertube('get_watch', { playerRequest: session.playerRequest(id), watchNextRequest: { videoId: id } });
    console.log(`  get_watch ${id}: ad keys ${playerAdKeys(JSON.parse(watch)).join(', ') || 'none'}; adSlotRenderer ${watch.includes('"adSlotRenderer"') ? 'yes' : 'no'}`);
    save('player', 'get_watch', id, 'json', pretty(watch));
    if (!htmlSaved) {
      save('html', 'watch', id, 'html', await session.get(`${CONFIG.ORIGIN}/watch?v=${id}`));
      htmlSaved = true;
    }
  }
  if (!explicit && kept < CONFIG.WANT_AD_VIDEOS) console.warn(`warning: only ${kept} candidate videos carried ads`);

  if (opts.short) {
    const html = await session.get(`${CONFIG.ORIGIN}/shorts/${opts.short}`);
    save('html', 'shorts', opts.short, 'html', html);
    const params = html.match(/"sequenceParams":"([^"]+)"/)?.[1];
    if (params) {
      const seq = await session.innertube('reel/reel_watch_sequence', { sequenceParams: decodeURIComponent(params) });
      const ads = (JSON.parse(seq).entries || []).filter((e) => e?.command?.reelWatchEndpoint?.adClientParams?.isAd).length;
      console.log(`short ${opts.short}: ${JSON.parse(seq).entries?.length ?? 0} sequence entries, ${ads} ads`);
      save('feed', 'reel_watch_sequence', opts.short, 'json', pretty(seq));
    } else {
      console.warn(`warning: no sequenceParams in /shorts/${opts.short}`);
    }
  }

  // Scrub everything first (so every address seen anywhere is known), then check and write.
  const scrubbed = pending.map(([rel, text]) => [rel, scrub(text, session)]);
  const final = scrubbed.map(([rel, text]) => [rel, scrub(text, session)]);
  for (const [rel, text] of final) {
    assertScrubbed(rel, text, session);
    const file = path.join(opts.out, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text.endsWith('\n') ? text : text + '\n');
    console.log(`wrote ${path.relative(process.cwd(), file)} (${Math.round(text.length / 1024)} KB)`);
  }
}

main().catch((e) => {
  console.error(`capture failed: ${e.message}`);
  process.exit(1);
});
