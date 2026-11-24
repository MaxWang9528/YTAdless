// player-ads.js: RULES over the captured player fixtures, synthetic cases for the rules the
// anonymous captures don't exercise, and the ad-showing fallback (PLAN.md §6.1 Layer 2).
// Owner: Module A.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector } from './harness.mjs';
import { jsonCases, htmlCases, runCase, PLAYER_AD_KEYS, ENDPOINT_URLS, decodeInitial } from './ad-fixtures.mjs';

const PLAYER_ENDPOINTS = new Set(['player', 'get_watch', 'reel_item_watch']);

function playerResponses(value) {
  if (Array.isArray(value)) return value.map((v) => v?.playerResponse).filter(Boolean);
  if (value?.playerResponse) return [value.playerResponse];
  return value?.videoDetails || value?.playabilityStatus ? [value] : [];
}

function assertNoPlayerAds(pr, where) {
  for (const key of PLAYER_AD_KEYS) assert.ok(!Object.hasOwn(pr, key), `${where}: ${key} removed`);
}

function hasPlayerAds(value) {
  return playerResponses(value).some((pr) => PLAYER_AD_KEYS.some((k) => Object.hasOwn(pr, k)));
}

const cases = jsonCases().filter((c) => PLAYER_ENDPOINTS.has(c.endpoint));
assert.ok(cases.filter((c) => !c.local && c.endpoint === 'player').length >= 3, 'at least 3 committed ad-carrying player fixtures');

for (const c of cases) {
  for (const api of ['fetch', 'xhr']) {
    test(`player-ads.js › ${c.name} › ${api}: ad fields removed, videoDetails and streamingData intact`, async (t) => {
      const original = JSON.parse(c.text);
      const { page, value, hits, emitted } = await runCase(createPage, c, { api });
      t.after(() => page.close());
      const before = playerResponses(original);
      const after = playerResponses(value);
      assert.equal(after.length, before.length, 'every player response survives');
      after.forEach((pr, i) => {
        assertNoPlayerAds(pr, `${c.name}[${i}]`);
        assert.deepEqual(pr.videoDetails, before[i].videoDetails, 'videoDetails unchanged');
        assert.deepEqual(pr.streamingData, before[i].streamingData, 'streamingData unchanged');
        assert.deepEqual(pr.playabilityStatus, before[i].playabilityStatus, 'playabilityStatus unchanged');
      });
      if (hasPlayerAds(original)) assert.ok(Object.keys(hits).some((r) => /adPlacements/.test(r)), `a player rule reported a hit: ${JSON.stringify(hits)}`);
      assert.deepEqual(emitted.map((e) => e.videoId), before.map((pr) => pr.videoDetails?.videoId ?? null), 'playerResponse emitted for each');
      assert.ok(emitted.every((e) => e.source === api));
      page.messages.forEach((m, i) => assertMatchesVector(m, `message ${i}`));
      assertClean(page, c.name);
    });
  }
}

for (const c of htmlCases().filter((h) => h.endpoint === 'watch')) {
  test(`player-ads.js › ${c.name} › inline ytInitialPlayerResponse: ad fields removed before the page reads it`, async (t) => {
    const original = decodeInitial(c.text, 'ytInitialPlayerResponse');
    const { page, value, hits, emitted } = await runCase(createPage, c);
    t.after(() => page.close());
    const pr = value.ytInitialPlayerResponse;
    assert.ok(pr, 'the page has a player response');
    assertNoPlayerAds(pr, c.name);
    assert.deepEqual(pr.videoDetails, original.videoDetails);
    assert.deepEqual(pr.streamingData, original.streamingData);
    if (PLAYER_AD_KEYS.some((k) => Object.hasOwn(original, k))) assert.ok(hits['player.adPlacements'] > 0);
    assert.deepEqual(emitted, [{ videoId: original.videoDetails.videoId, source: 'initial' }]);
    assertClean(page, c.name);
  });
}

// ── Synthetic cases (rules the 2026-11-24 anonymous captures don't exercise) ──────────────

async function serve(t, endpoint, body, role = 'player') {
  const c = { name: `synthetic-${endpoint}`, endpoint, kind: 'json', url: ENDPOINT_URLS[endpoint], text: JSON.stringify(body) };
  const result = await runCase(createPage, c, { role });
  t.after(() => result.page.close());
  return result;
}

const reelEntry = (videoId, ad = false) => ({
  command: { reelWatchEndpoint: { videoId, ...(ad ? { adClientParams: { isAd: true } } : {}) } },
});

test('player-ads.js › synthetic reel_watch_sequence › ad entries removed, the others kept in order', async (t) => {
  const c = jsonCases().find((x) => x.endpoint === 'reel_watch_sequence' && !x.local);
  const real = JSON.parse(c.text);
  const ids = real.entries.map((e) => e.command.reelWatchEndpoint.videoId);
  real.entries.splice(2, 0, reelEntry('adadadadad1', true));
  real.entries.push(reelEntry('adadadadad2', true));
  const { page, value, hits } = await serve(t, 'reel_watch_sequence', real);
  assert.deepEqual(value.entries.map((e) => e.command.reelWatchEndpoint.videoId), ids);
  assert.equal(hits['shorts.adEntries'], 2);
  assertClean(page);
});

test('player-ads.js › synthetic get_watch › an adSlotRenderer in itemSectionRenderer.contents is removed', async (t) => {
  const c = jsonCases().find((x) => x.endpoint === 'get_watch' && !x.local);
  const real = JSON.parse(c.text);
  const response = real.find((part) => part.watchNextResponse).watchNextResponse;
  const section = { itemSectionRenderer: { contents: [{ adSlotRenderer: { adSlotMetadata: {} } }, { videoWithContextRenderer: { videoId: 'keep' } }] } };
  (response.contents ??= {}).syntheticList = [section];
  const { page, value, hits } = await serve(t, 'get_watch', real);
  const after = value.find((part) => part.watchNextResponse).watchNextResponse.contents.syntheticList[0].itemSectionRenderer.contents;
  assert.deepEqual(after, [{ videoWithContextRenderer: { videoId: 'keep' } }]);
  assert.equal(hits['get_watch.adSlotRenderer'], 1);
  assertClean(page);
});

test('player-ads.js › synthetic resolve_url › the prefetched player response loses its ad fields', async (t) => {
  const pr = JSON.parse(jsonCases().find((x) => x.endpoint === 'player' && !x.local).text);
  pr.adPlacements = [{ adPlacementRenderer: {} }];
  const body = { endpoint: { watchEndpoint: { videoId: pr.videoDetails.videoId, unserializedPrefetchData: { playerResponse: pr } } } };
  const c = { name: 'synthetic-resolve_url', kind: 'json', url: 'https://m.youtube.com/youtubei/v1/navigation/resolve_url?prettyPrint=false', text: JSON.stringify(body) };
  const { page, value, hits, emitted } = await runCase(createPage, c);
  t.after(() => page.close());
  assertNoPlayerAds(value.endpoint.watchEndpoint.unserializedPrefetchData.playerResponse, 'prefetch');
  assert.ok(hits['prefetch.adPlacements'] >= 1);
  assert.deepEqual(emitted.map((e) => e.videoId), [pr.videoDetails.videoId]);
  assertClean(page);
});

test('player-ads.js › JSON.parse › playerResponse.* inside a parsed innertube blob is pruned', async (t) => {
  const page = await createPage({ role: 'player' });
  t.after(() => page.close());
  const parsed = page.window.JSON.parse('{"responseContext":{},"playerResponse":{"videoDetails":{"videoId":"x"},"adPlacements":[],"playerAds":[],"adSlots":[]}}');
  assert.deepEqual(Object.keys(parsed.playerResponse), ['videoDetails']);
  assertClean(page);
});

// ── ad-showing fallback ──────────────────────────────────────────────────────────────────

function playerHTML() {
  return '<html><body><div id="movie_player" class="html5-video-player"><video></video>' +
    '<div class="ytp-ad-module"></div></div></body></html>';
}

function mockVideo(video) {
  let time = 3;
  Object.defineProperty(video, 'duration', { configurable: true, get: () => 15 });
  Object.defineProperty(video, 'currentTime', { configurable: true, get: () => time, set: (v) => { time = v; } });
  return () => time;
}

test('player-ads.js › fallback › an ad-showing player is muted, skipped to the end, and reported once', async (t) => {
  const page = await createPage({ role: 'player', html: playerHTML() });
  t.after(() => page.close());
  const doc = page.document;
  const player = doc.getElementById('movie_player');
  const video = player.querySelector('video');
  const time = mockVideo(video);
  let clicks = 0;
  player.querySelector('.ytp-ad-module').innerHTML = '<button class="ytp-skip-ad-button">Skip</button>';
  player.querySelector('.ytp-skip-ad-button').addEventListener('click', () => { clicks += 1; });

  player.classList.add('ad-showing');
  await page.flush();
  assert.equal(video.muted, true);
  assert.equal(time(), 15);
  assert.equal(clicks, 1);
  player.classList.add('ad-interrupting');  // more class churn during the same ad
  await page.flush();
  assert.deepEqual(page.posted('filterHit').map((m) => [m.rule, m.count]), [['ad-skip-fallback', 1]]);

  player.classList.remove('ad-showing');
  await page.flush();
  assert.equal(video.muted, false, 'unmuted after the ad');
  page.messages.forEach((m, i) => assertMatchesVector(m, `message ${i}`));
  assertClean(page);
});

test('player-ads.js › fallback › a user-muted video stays muted after the ad', async (t) => {
  const page = await createPage({ role: 'player', html: playerHTML() });
  t.after(() => page.close());
  const player = page.document.getElementById('movie_player');
  const video = player.querySelector('video');
  mockVideo(video);
  video.muted = true;
  player.classList.add('ad-showing');
  await page.flush();
  player.classList.remove('ad-showing');
  await page.flush();
  assert.equal(video.muted, true);
  assertClean(page);
});

test('player-ads.js › fallback › a stale ad-showing class never seeks the real video (duration = lengthSeconds)', async (t) => {
  const page = await createPage({ role: 'player', html: playerHTML() });
  t.after(() => page.close());
  page.window.__ytadless.emit('playerResponse', { videoDetails: { videoId: 'dQw4w9WgXcQ', lengthSeconds: '15' } }, { source: 'fetch', url: 'x' });
  const player = page.document.getElementById('movie_player');
  const video = player.querySelector('video');
  const time = mockVideo(video);  // duration 15 = the content
  player.classList.add('ad-showing');
  await page.flush();
  assert.equal(time(), 3, 'not seeked');
  assert.equal(video.muted, false, 'not muted');
  assert.deepEqual(page.posted('filterHit').map((m) => m.rule), ['ad-skip-fallback'], 'still reported');
  assertClean(page);
});

test('player-ads.js › fallback › not installed in the browse view', async (t) => {
  const page = await createPage({ role: 'browse', html: playerHTML() });
  t.after(() => page.close());
  page.document.getElementById('movie_player').classList.add('ad-showing');
  await page.flush();
  assert.equal(page.posted('filterHit').length, 0);
  assertClean(page);
});
