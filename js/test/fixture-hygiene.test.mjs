// Committed fixtures carry no secrets or account data (CLAUDE.md "Fixtures"). js/fixtures/local/
// is gitignored and skipped. Owner: integration (shared, add-only directory).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { PATHS } from './harness.mjs';

function committedFixtures(dir = PATHS.fixtures) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { if (entry.name !== 'local') out.push(...committedFixtures(full)); }
    else out.push(full);
  }
  return out;
}

const CHECKS = [
  ['a Google API key (GitHub secret scanning flags these)', /AIza[0-9A-Za-z_-]{35}/],
  ['a signed-in capture', /"LOGGED_IN"\s*:\s*true|LOGGED_IN\\x22:\s*true/],
  ['an unredacted XSRF token', /"XSRF_TOKEN"\s*:\s*"(?!REDACTED")/],
  ['an account cookie name', /\b(?:SAPISID|__Secure-[13]PSID|LOGIN_INFO)=/],
];

for (const file of committedFixtures()) {
  const name = path.relative(PATHS.fixtures, file);
  test(`fixtures › ${name} › no secrets or account data`, () => {
    const text = fs.readFileSync(file, 'utf8');
    for (const [what, pattern] of CHECKS) assert.doesNotMatch(text, pattern, `${name} contains ${what}`);
  });
}
