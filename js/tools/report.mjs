#!/usr/bin/env node
// report.mjs — filterHit counts per rule per fixture, plus what survives. Owner: Module A (PLAN.md §6.1).
//
//   npm run report [-- --committed] [-- <substring>…]
//
// Serves every fixture (committed, plus js/fixtures/local/ captures when present) through the
// shipped scripts in the harness, exactly as the tests do, and prints:
//   - a table: one row per fixture, one column per rule that hit anywhere (blank = 0)
//   - per fixture: known ad keys still present after pruning, and unknown ad-like keys
//     (not in js/fixtures/ad-key-allowlist.json): the sign of a renamed ad renderer
// A rule whose column went blank on a fresh capture is the rule YouTube broke.

import { createPage } from '../test/harness.mjs';
import { loadCases, runCase, remainingKnownAdKeys, unknownAdKeys, shortsAdEntries, readAllowlist } from '../test/ad-fixtures.mjs';

const CONFIG = Object.freeze({
  NAME_WIDTH: 52,
  COLUMN_MIN: 6,
});

const args = process.argv.slice(2);
const committedOnly = args.includes('--committed');
const filters = args.filter((a) => !a.startsWith('--'));

const cases = loadCases({ local: !committedOnly }).filter((c) => filters.length === 0 || filters.some((f) => c.name.includes(f)));
if (cases.length === 0) {
  console.log('no fixtures matched');
  process.exit(0);
}

const allowlist = readAllowlist();
const rows = [];
for (const c of cases) {
  const { page, value, hits } = await runCase(createPage, c);
  const errors = page.scriptErrors().map((e) => `${e.source}: ${e.message}`);
  rows.push({
    name: c.name,
    hits,
    remaining: remainingKnownAdKeys(value),
    unknown: unknownAdKeys(value, allowlist),
    shortsAds: shortsAdEntries(value.ytInitialReelWatchSequenceResponse ?? value),
    errors,
  });
  page.close();
}

const rules = [...new Set(rows.flatMap((r) => Object.keys(r.hits)))].sort();
const pad = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s.padEnd(n));
const widths = rules.map((r) => Math.max(CONFIG.COLUMN_MIN, r.length));

console.log(pad('fixture', CONFIG.NAME_WIDTH) + rules.map((r, i) => ' ' + r.padStart(widths[i])).join(''));
for (const row of rows) {
  console.log(pad(row.name, CONFIG.NAME_WIDTH) + rules.map((r, i) => ' ' + String(row.hits[r] || '').padStart(widths[i])).join(''));
}
console.log('');

let problems = 0;
for (const row of rows) {
  const notes = [];
  if (row.remaining.length) notes.push(`known ad keys left: ${row.remaining.join(', ')}`);
  if (row.shortsAds) notes.push(`Shorts ad entries left: ${row.shortsAds}`);
  if (row.unknown.length) notes.push(`unknown ad-like keys: ${row.unknown.join(', ')}`);
  if (row.errors.length) notes.push(`script errors: ${row.errors.join(' | ')}`);
  if (notes.length) {
    problems += 1;
    console.log(`${row.name}\n  ${notes.join('\n  ')}`);
  }
}
console.log(problems ? `\n${problems} fixture(s) need a look.` : `all ${rows.length} fixtures clean: no known ad keys left, no unknown ad-like keys.`);
