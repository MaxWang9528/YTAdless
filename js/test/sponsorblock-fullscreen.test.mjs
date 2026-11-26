// sponsorblock.js `hideMarkersInFullscreen` (PLAN.md §5.4; Settings › Hide segment marks in full
// screen). Owner: Module D.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector } from './harness.mjs';
import { playerPage } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js', 'sponsorblock.js'];
const ID = 'dQw4w9WgXcQ';  // media-fakes WATCH
const TOAST = '#ytadless-sponsorblock-toast';
const STYLE = '#ytadless-sponsorblock-style';
const HIDE = 'ytadless-sb-hide-markers-fs';
const SPONSOR = { start: 10, end: 30.5, category: 'sponsor' };

async function sbPage(t) {
  const env = await playerPage(t, { scripts: SCRIPTS });
  const video = await env.addVideo({ playing: true, duration: 213 });
  const at = (time) => {
    video.currentTime = time;
    video.dispatchEvent(new env.win.Event('timeupdate'));
  };
  return { ...env, video, at };
}

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}

test('sponsorblock.js › hideMarkersInFullscreen › either command toggles the class; the latest wins', async (t) => {
  const { page } = await sbPage(t);
  const html = page.document.documentElement;
  await page.cmd('sponsorSegments', { videoId: ID, segments: [SPONSOR] });
  assert.equal(html.classList.contains(HIDE), false, 'missing field = off');
  assert.equal(page.document.querySelector(STYLE), null, 'no stylesheet until needed');

  await page.cmd('sponsorSegments', { videoId: ID, segments: [SPONSOR], hideMarkersInFullscreen: true });
  assert.equal(html.classList.contains(HIDE), true, 'sponsorSegments turns it on');
  await page.cmd('suggestedSegments', { videoId: ID, segments: [] });
  assert.equal(html.classList.contains(HIDE), false, 'suggestedSegments without the field turns it off');
  await page.cmd('suggestedSegments', { videoId: ID, segments: [], hideMarkersInFullscreen: true });
  assert.equal(html.classList.contains(HIDE), true, 'suggestedSegments turns it on');
  await page.cmd('sponsorSegments', { videoId: 'otherVideo1', segments: [], hideMarkersInFullscreen: false });
  assert.equal(html.classList.contains(HIDE), false, 'a setting: applied even for another video id');
  await page.cmd('sponsorSegments', { videoId: ID, segments: [SPONSOR], hideMarkersInFullscreen: true });
  assert.equal(page.document.querySelectorAll(STYLE).length, 1, 'one stylesheet, added once');
  assertAll(page);
});

test('sponsorblock.js › hideMarkersInFullscreen › the rule hides only the marks, only in landscape video mode', async (t) => {
  const { page, at } = await sbPage(t);
  const html = page.document.documentElement;
  await page.cmd('sponsorSegments', { videoId: ID, segments: [SPONSOR], autoSkip: false, hideMarkersInFullscreen: true });
  at(12);  // inside the segment: the Skip toast is up
  assert.ok(page.document.querySelector(TOAST), 'Skip toast shown');
  assert.ok(page.document.querySelector('#ytadless-sponsorblock-markers'), 'marks drawn');

  const rule = page.document.querySelector(STYLE).sheet.cssRules[0];
  assert.match(rule.conditionText ?? rule.media.mediaText, /orientation:\s*landscape/, 'landscape only');
  const selector = rule.cssRules[0].selectorText;
  assert.match(rule.cssRules[0].style.cssText, /display:\s*none/);
  assert.equal(page.document.querySelector(selector), null, 'page mode (no layout.js video class): nothing hidden');
  html.classList.add('ytadless-layout-video');
  const hidden = [...page.document.querySelectorAll(selector)].map((el) => el.id);
  assert.deepEqual(hidden, ['ytadless-sponsorblock-markers'], 'only the marks, never the toast');
  html.classList.remove(HIDE);
  assert.equal(page.document.querySelector(selector), null, 'setting off: nothing hidden');
  assertAll(page);
});
