// Generic fixture assertions for every player/feed/html fixture (PLAN.md §6.1), the
// unknown-ad-key scan, and fixture hygiene. Owner: Module A.
//
// Local captures in js/fixtures/local/ (gitignored) are included when present, so the
// maintenance loop in CLAUDE.md is: drop a capture there, run `npm test` and `npm run report`.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { createPage, assertClean, PATHS } from './harness.mjs';
import {
  loadCases, runCase, remainingKnownAdKeys, unknownAdKeys, shortsAdEntries, readAllowlist, AD_KEY_PATTERN, knownAdKeys,
} from './ad-fixtures.mjs';

const cases = loadCases();

test('fixtures › committed set › ≥3 ad-carrying videos, a Short, home and search feeds', () => {
  const committed = cases.filter((c) => !c.local);
  const withAds = committed.filter((c) => c.endpoint === 'player' && /"(adPlacements|playerAds|adSlots)"/.test(c.text));
  assert.ok(withAds.length >= 3, `ad-carrying player fixtures: ${withAds.map((c) => c.name)}`);
  for (const endpoint of ['get_watch', 'reel_watch_sequence', 'shorts', 'browse', 'home', 'search', 'results', 'watch']) {
    assert.ok(committed.some((c) => c.endpoint === endpoint), `a committed ${endpoint} fixture`);
  }
});

for (const c of cases) {
  test(`fixtures › ${c.name} › no known ad keys, no Shorts ad entries, no unknown ad-like keys after pruning`, async (t) => {
    const { page, value } = await runCase(createPage, c);
    t.after(() => page.close());
    assert.deepEqual(remainingKnownAdKeys(value), [], 'known ad keys left');
    assert.equal(shortsAdEntries(value.ytInitialReelWatchSequenceResponse ?? value), 0, 'Shorts ad entries left');
    assert.deepEqual(unknownAdKeys(value), [], 'unknown ad-like keys: decide each (prune it in player-ads.js/feed-ads.js, or allowlist it with a reason)');
    assertClean(page, c.name);
  });
}

test('fixtures › ad-key allowlist › every entry has a reason and still matches the pattern', () => {
  const { keys } = readAllowlist();
  for (const [key, reason] of Object.entries(keys)) {
    assert.ok(typeof reason === 'string' && reason.length > 20, `${key}: give a reason`);
    assert.match(key, AD_KEY_PATTERN, `${key}: allowlisted but not ad-like`);
    assert.ok(!knownAdKeys().includes(key), `${key}: both known and allowlisted`);
  }
});

test('fixtures › AD_KEY_PATTERN › camelCase ad words hit; words that merely contain "ad" do not', () => {
  for (const key of ['adPlacements', 'playerAds', 'adSlots', 'adSlotRenderer', 'promotedSparklesWebRenderer', 'mealbarPromoRenderer',
    'compactPromotedVideoRenderer', 'sponsoredItem', 'ads', 'isAd', 'AdBreak_x']) {
    assert.match(key, AD_KEY_PATTERN, key);
  }
  for (const key of ['header', 'loadingHeader', 'metadata', 'badges', 'uploadDate', 'payload', 'reloadContinuationData',
    'dynamicReadaheadConfig', 'thread', 'shadow', 'adjust', 'address', 'promotion']) {
    assert.doesNotMatch(key, AD_KEY_PATTERN, key);
  }
});

// ── Hygiene: committed fixtures are anonymous captures, scrubbed (tools/capture.mjs) ─────

const NAME = /^\d{4}-\d{2}-\d{2}-[a-z_]+-[A-Za-z0-9_-]+\.(json|html)$/;

for (const dir of ['player', 'feed', 'html', 'dom']) {
  const full = path.join(PATHS.fixtures, dir);
  for (const file of fs.existsSync(full) ? fs.readdirSync(full).filter((f) => !f.startsWith('.')) : []) {
    test(`fixtures › hygiene › ${dir}/${file} › named by date, signed out, no client address or visitor id`, () => {
      assert.match(file, NAME);
      const text = fs.readFileSync(path.join(full, file), 'utf8');
      assert.doesNotMatch(text, /"LOGGED_IN":true/, 'captured signed out');
      assert.doesNotMatch(text, /"remoteHost":"(?!0\.0\.0\.0")/, 'remoteHost scrubbed');
      assert.doesNotMatch(text, /[?&]ip=(?!0\.0\.0\.0)\d/, 'ip= scrubbed');
      assert.doesNotMatch(text, /"visitorData":"(?!REDACTED")|visitorData\\x22:\\x22(?!REDACTED)/, 'visitorData scrubbed');
      assert.doesNotMatch(text, /"(XSRF_TOKEN|DATASYNC_ID)":"(?!REDACTED")/, 'session tokens scrubbed');
    });
  }
}
