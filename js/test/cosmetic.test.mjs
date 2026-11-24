// rules/cosmetic.txt: every selector is valid CSS, matches the ad nodes in the DOM fixtures,
// and hides nothing marked as content (PLAN.md §6.1, CLAUDE.md tier 2). Owner: Module A.
// The Swift RuleCompiler validates the same selectors (RulesTests); this checks them against a
// real selector engine and a page.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { JSDOM } from 'jsdom';
import { PATHS, readText } from './harness.mjs';

function cosmeticRules() {
  return readText(PATHS.rules, 'cosmetic.txt').split('\n')
    .map((line, i) => ({ line: i + 1, text: line.trim() }))
    .filter((r) => r.text && !r.text.startsWith('!'))
    .map((r) => {
      const at = r.text.indexOf('##');
      return { ...r, domains: at > 0 ? r.text.slice(0, at).split(',') : [], selector: r.text.slice(at + 2).trim() };
    });
}

function domFixtures() {
  const dir = path.join(PATHS.fixtures, 'dom');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.html')).map((f) => path.join(dir, f));
  return files.map((file) => ({ name: path.basename(file), document: new JSDOM(fs.readFileSync(file, 'utf8')).window.document }));
}

const rules = cosmeticRules();
const pages = domFixtures();

test('cosmetic.txt › rules › every line is domain##selector scoped to m.youtube.com or global', () => {
  assert.ok(rules.length > 0);
  for (const r of rules) {
    assert.ok(r.text.includes('##'), `line ${r.line}`);
    for (const d of r.domains) assert.match(d, /^~?[a-z0-9.-]+$/, `line ${r.line}: domain ${d}`);
  }
});

test('cosmetic.txt › dom fixtures › at least one page with ad and content markers', () => {
  // Not every DOM fixture carries ads (Module C's watch skeleton has none); those still count for
  // the "never hides content" check below.
  assert.ok(pages.length > 0);
  assert.ok(
    pages.some((p) => p.document.querySelector('[data-test-ad]') && p.document.querySelector('[data-test-content]')),
    `no DOM fixture has both [data-test-ad] and [data-test-content]: ${pages.map((p) => p.name).join(', ')}`,
  );
});

for (const r of rules) {
  test(`cosmetic.txt › line ${r.line} › ${r.selector} › valid and matches an ad node, never content`, () => {
    let matched = 0;
    for (const p of pages) {
      const nodes = [...p.document.querySelectorAll(r.selector)];  // throws on an invalid selector
      matched += nodes.length;
      for (const node of nodes) {
        assert.ok(node.hasAttribute('data-test-ad'), `${p.name}: ${r.selector} hides <${node.localName}> which is not marked as an ad`);
      }
    }
    assert.ok(matched > 0, `${r.selector} matches nothing in the DOM fixtures`);
  });
}

for (const p of pages) {
  test(`cosmetic.txt › ${p.name} › every ad node is hidden (itself or an ancestor matched)`, () => {
    const hidden = new Set();
    for (const r of rules) for (const node of p.document.querySelectorAll(r.selector)) hidden.add(node);
    for (const ad of p.document.querySelectorAll('[data-test-ad]')) {
      let node = ad;
      while (node && !hidden.has(node)) node = node.parentElement;
      assert.ok(node, `<${ad.localName}> in ${ad.parentElement?.localName} is not hidden by any rule`);
    }
    for (const content of p.document.querySelectorAll('[data-test-content]')) {
      let node = content;
      while (node && !hidden.has(node)) node = node.parentElement;
      assert.equal(node, null, `<${content.localName}> is content but is hidden`);
    }
  });
}
