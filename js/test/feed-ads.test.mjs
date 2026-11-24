// feed-ads.js: AD_RENDERER_KEYS over the captured feeds (PLAN.md §6.1 Layer 3). Owner: Module A.
//
// Signed-out feeds carried no promoted items on 2026-11-24, so each real fixture is served twice:
// as captured (must come through unchanged), and with ad items spliced into its content lists
// (they must all go, and everything else must come through unchanged).

import test from 'node:test';
import assert from 'node:assert/strict';
import { createPage, assertClean, assertMatchesVector } from './harness.mjs';
import { jsonCases, htmlCases, runCase, feedAdKeys, remainingKnownAdKeys, decodeInitial, ORIGIN } from './ad-fixtures.mjs';

const FEED_ENDPOINTS = new Set(['browse', 'search', 'next', 'guide', 'reel_watch_sequence', 'get_watch']);
const WRAPPERS = ['richItemRenderer', 'richSectionRenderer'];
const AD_KEYS = feedAdKeys();

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function isAd(item) {
  if (!isObj(item)) return false;
  if (Object.keys(item).some((k) => AD_KEYS.includes(k))) return true;
  return WRAPPERS.some((w) => isObj(item[w]?.content) && Object.keys(item[w].content).some((k) => AD_KEYS.includes(k)));
}

/** Array elements outside ad items: what must survive pruning. */
function contentItems(root) {
  let n = 0;
  const stack = [root];
  while (stack.length) {
    const node = stack.pop();
    if (node === null || typeof node !== 'object') continue;
    if (Array.isArray(node)) {
      for (const item of node) if (!isAd(item)) { n += typeof item === 'object' && item !== null ? 1 : 0; stack.push(item); }
    } else {
      for (const v of Object.values(node)) stack.push(v);
    }
  }
  return n;
}

/** Content lists: arrays whose elements are single-key renderer objects. */
function contentLists(root) {
  const lists = [];
  const stack = [root];
  while (stack.length) {
    const node = stack.pop();
    if (node === null || typeof node !== 'object') continue;
    if (Array.isArray(node)) {
      if (node.length && node.every((i) => isObj(i) && Object.keys(i).some((k) => /Renderer$|ViewModel$/.test(k)))) lists.push(node);
      stack.push(...node);
    } else {
      stack.push(...Object.values(node));
    }
  }
  return lists;
}

/** Splices one ad item per AD_RENDERER_KEY (alternating direct and richItemRenderer-wrapped). */
function spliceAds(root) {
  const lists = contentLists(root);
  if (lists.length === 0) return 0;
  AD_KEYS.forEach((key, i) => {
    const list = lists[i % lists.length];
    const item = i % 2 === 0 ? { [key]: { trackingParams: 'synthetic' } } : { [WRAPPERS[i % 4 === 1 ? 0 : 1]]: { content: { [key]: {} } } };
    list.splice(Math.min(list.length, 1 + (i % 3)), 0, item);
  });
  return AD_KEYS.length;
}

function assertNoFeedAds(value, where) {
  assert.deepEqual(remainingKnownAdKeys(value).filter((k) => AD_KEYS.includes(k)), [], `${where}: no feed ad keys left`);
}

const cases = jsonCases().filter((c) => FEED_ENDPOINTS.has(c.endpoint));

for (const c of cases) {
  test(`feed-ads.js › ${c.name} › as captured: non-ad content intact`, async (t) => {
    const original = JSON.parse(c.text);
    const { page, value } = await runCase(createPage, c, { role: 'browse' });
    t.after(() => page.close());
    assertNoFeedAds(value, c.name);
    // get_watch also carries a player response, whose ad fields player-ads.js removes.
    const feedPart = (v) => (Array.isArray(v) ? v.filter((p) => !p.playerResponse) : v);
    assert.equal(contentItems(feedPart(value)), contentItems(feedPart(original)), 'non-ad item count unchanged');
    page.messages.forEach((m, i) => assertMatchesVector(m, `message ${i}`));
    assertClean(page, c.name);
  });

  // Shorts sequences hold entries, not renderer lists; player-ads.js handles their ad entries.
  if (c.local || c.endpoint === 'reel_watch_sequence') continue;
  test(`feed-ads.js › ${c.name} › spliced ads: every ad removed, everything else unchanged`, async (t) => {
    const original = JSON.parse(c.text);
    const spliced = JSON.parse(c.text);
    const added = spliceAds(spliced);
    assert.ok(added > 0, 'the fixture has content lists to splice into');
    const { page, value, hits } = await runCase(createPage, { ...c, text: JSON.stringify(spliced) }, { role: 'browse' });
    t.after(() => page.close());
    assertNoFeedAds(value, c.name);
    // Player rules may have pruned their own fields from get_watch; compare the feed part.
    const comparable = (v) => (Array.isArray(v) ? v.map((p) => p.watchNextResponse ?? p) : v);
    if (c.endpoint === 'get_watch') {
      assert.deepEqual(comparable(value).filter((p) => !p.playerResponse), comparable(original).filter((p) => !p.playerResponse));
    } else {
      assert.deepEqual(value, original, 'only the spliced items were removed');
    }
    const total = Object.entries(hits).filter(([r]) => r.startsWith('feed.') || r === 'get_watch.adSlotRenderer').reduce((s, [, n]) => s + n, 0);
    assert.equal(total, added, `one hit per spliced ad: ${JSON.stringify(hits)}`);
    assertClean(page, c.name);
  });
}

for (const c of htmlCases()) {
  test(`feed-ads.js › ${c.name} › inline ytInitialData: non-ad content intact`, async (t) => {
    const original = decodeInitial(c.text, 'ytInitialData');
    const { page, value } = await runCase(createPage, c, { role: 'browse' });
    t.after(() => page.close());
    if (!original) { assert.equal(value.ytInitialData, null); return; }
    assertNoFeedAds(value.ytInitialData, c.name);
    assert.equal(contentItems(value.ytInitialData), contentItems(original));
    assertClean(page, c.name);
  });
}

test('feed-ads.js › home ytInitialData with spliced ads › removed before the page reads it', async (t) => {
  const home = htmlCases().find((c) => c.endpoint === 'home' && !c.local);
  const data = decodeInitial(home.text, 'ytInitialData');
  const original = structuredClone(data);
  const added = spliceAds(data);
  assert.ok(added > 0);
  const page = await createPage({ role: 'browse', url: `${ORIGIN}/`, html: `<html><body><script>var ytInitialData = ${JSON.stringify(data)};</script></body></html>` });
  t.after(() => page.close());
  assert.deepEqual(JSON.parse(JSON.stringify(page.window.ytInitialData)), original);
  assert.equal(page.posted('filterHit').reduce((s, m) => s + m.count, 0), added);
  assertClean(page);
});

for (const key of AD_KEYS) {
  test(`feed-ads.js › AD_RENDERER_KEYS › ${key}: removed directly and inside richItemRenderer/richSectionRenderer`, async (t) => {
    const body = { responseContext: {}, contents: { list: [
      { videoWithContextRenderer: { videoId: 'a' } },
      { [key]: {} },
      { richItemRenderer: { content: { [key]: {} } } },
      { richSectionRenderer: { content: { [key]: {} } } },
      { richItemRenderer: { content: { videoWithContextRenderer: { videoId: 'b' } } } },
    ] } };
    const c = { name: 'synthetic', endpoint: 'browse', kind: 'json', url: `${ORIGIN}/youtubei/v1/browse?prettyPrint=false`, text: JSON.stringify(body) };
    const { page, value, hits } = await runCase(createPage, c, { role: 'browse' });
    t.after(() => page.close());
    assert.deepEqual(value.contents.list, [
      { videoWithContextRenderer: { videoId: 'a' } },
      { richItemRenderer: { content: { videoWithContextRenderer: { videoId: 'b' } } } },
    ]);
    assert.equal(hits[`feed.${key}`], 3);
    assertClean(page);
  });
}

test('feed-ads.js › non-feed URLs › a browse-shaped body elsewhere is untouched', async (t) => {
  const body = JSON.stringify({ contents: [{ adSlotRenderer: {} }] });
  const c = { name: 'synthetic', endpoint: 'x', kind: 'json', url: `${ORIGIN}/youtubei/v1/account/account_menu`, text: body };
  const { page, value } = await runCase(createPage, c, { role: 'browse' });
  t.after(() => page.close());
  assert.deepEqual(value, JSON.parse(body));
  assertClean(page);
});
