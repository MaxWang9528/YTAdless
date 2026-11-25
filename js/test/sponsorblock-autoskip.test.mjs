// sponsorblock.js (PLAN.md §5.4 `sponsorSegments`/`suggestedSegments` `autoSkip`; §6.5): each list
// is either skipped automatically (Undo toast) or offered with a Skip button. Owner: Module D.
// The media fakes don't fire timeupdate/seeked when currentTime is set, so tests dispatch them.

import test from 'node:test';
import assert from 'node:assert/strict';
import { assertClean, assertMatchesVector } from './harness.mjs';
import { playerPage } from './media-fakes.mjs';

const SCRIPTS = ['player-bridge.js', 'background.js', 'sponsorblock.js'];
const ID = 'dQw4w9WgXcQ';
const TOAST = '#ytadless-sponsorblock-toast';
const SEG = { start: 10, end: 30, category: 'sponsor' };
const GUESS = { start: 61, end: 95, category: 'sponsor' };

async function sbPage(t) {
  const env = await playerPage(t, { scripts: SCRIPTS });
  const video = await env.addVideo({ playing: true, duration: 213 });
  const at = (time) => {
    video.currentTime = time;
    video.dispatchEvent(new env.win.Event('timeupdate'));
  };
  const toast = () => env.page.document.querySelector(TOAST);
  const tap = () => toast().querySelector('button').dispatchEvent(new env.win.MouseEvent('click', { bubbles: true }));
  const intents = [];
  env.ns.on('userIntent', (i) => intents.push({ ...i }));
  return { ...env, video, at, toast, tap, intents };
}

function assertAll(page) {
  for (const m of page.messages) assertMatchesVector(m, `posted ${m.type}`);
  assertClean(page);
}
const logs = (page, re) => page.posted('log').filter((m) => m.source === 'sponsorblock.js' && re.test(m.message));

test('sponsorblock.js › sponsorSegments autoSkip false › Skip button, no skip until tapped', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(12);
  assert.equal(env.video.currentTime, 12, 'not skipped');
  assert.ok(env.toast(), 'prompt shown');
  assert.match(env.toast().textContent, /^Sponsor/);
  assert.match(env.toast().querySelector('button').textContent, /Skip/);
  assert.doesNotMatch(env.toast().textContent, /Possible/);
  env.at(14);
  assert.equal(env.video.currentTime, 14, 'still not skipped');
  env.tap();
  assert.equal(env.video.currentTime, 30, 'skipped by the tap');
  assert.deepEqual(env.intents, [{ action: 'seek', source: 'page' }], 'a real tap is user intent');
  assert.equal(logs(env.page, /^prompt: sponsor/).length, 1);
  assert.equal(logs(env.page, /^skipped by tap: sponsor/).length, 1);
  assertAll(env.page);
});

test('sponsorblock.js › sponsorSegments autoSkip false › seeking back before the start prompts again', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(12);
  env.at(40);
  assert.equal(env.toast(), null, 'prompt gone after the segment');
  env.at(5);
  env.at(11);
  assert.ok(env.toast(), 'prompted again');
  assert.equal(env.video.currentTime, 11);
  assertAll(env.page);
});

test('sponsorblock.js › sponsorSegments autoSkip missing or true › skipped automatically (unchanged default)', async (t) => {
  for (const args of [{}, { autoSkip: true }, { autoSkip: 'no' }]) {
    const env = await sbPage(t);
    await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], ...args });
    env.at(12);
    assert.equal(env.video.currentTime, 30, JSON.stringify(args));
    assert.match(env.toast().textContent, /Skipped sponsor/);
    assert.deepEqual(env.intents, [], 'automatic skips are not user intent (D12)');
  }
});

test('sponsorblock.js › suggestedSegments autoSkip true › skipped automatically with Undo', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('suggestedSegments', { videoId: ID, segments: [GUESS], autoSkip: true });
  env.at(62);
  assert.equal(env.video.currentTime, 95, 'skipped');
  assert.match(env.toast().textContent, /Skipped possible sponsor/);
  assert.match(env.toast().querySelector('button').textContent, /Undo/);
  assert.deepEqual(env.intents, [], 'automatic skip: no user intent');
  assert.equal(logs(env.page, /^skipped sponsor \(AI guess\) /).length, 1);
  env.tap();
  assert.equal(env.video.currentTime, 61, 'Undo seeks back');
  env.at(62);
  assert.equal(env.video.currentTime, 62, 'not skipped twice in one load');
  assertAll(env.page);
});

test('sponsorblock.js › suggestedSegments autoSkip missing or false › prompt only (unchanged default)', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('suggestedSegments', { videoId: ID, segments: [GUESS] });
  env.at(62);
  assert.equal(env.video.currentTime, 62);
  assert.match(env.toast().textContent, /Possible sponsor/);
  assertAll(env.page);
});

test('sponsorblock.js › switching sponsorSegments to autoSkip mid-segment › skipped, prompt replaced', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(12);
  assert.match(env.toast().textContent, /^Sponsor/);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: true });
  assert.equal(env.video.currentTime, 30, 'skipped on the re-send');
  assert.match(env.toast().textContent, /Skipped sponsor/);
  assertAll(env.page);
});

test('sponsorblock.js › both lists as buttons › each prompts with its own label', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  await env.page.cmd('suggestedSegments', { videoId: ID, segments: [GUESS], autoSkip: false });
  env.at(12);
  assert.match(env.toast().textContent, /^Sponsor/);
  env.at(62);
  assert.match(env.toast().textContent, /Possible sponsor/);
  assert.equal(env.video.currentTime, 62);
  assertAll(env.page);
});

test('sponsorblock.js › Skip button 3 s early › appears before the start; a tap skips to the end', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(6.5);
  assert.equal(env.toast(), null, '3.5 s before: nothing yet');
  env.at(7.2);
  assert.ok(env.toast(), '2.8 s before: Skip button shown');
  env.tap();
  assert.equal(env.video.currentTime, 30);
  assertAll(env.page);
});

test('sponsorblock.js › Skip button 3 s early › seeking back before the lead re-arms it', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(8);
  env.at(40);
  env.at(7.5);
  assert.equal(env.toast(), null, 'still inside the lead window: not re-armed');
  env.at(2);
  env.at(8);
  assert.ok(env.toast(), 're-armed after going back before the lead');
  assertAll(env.page);
});

test('sponsorblock.js › Skip button taps › do not reach the player', async (t) => {
  const env = await sbPage(t);
  await env.page.cmd('sponsorSegments', { videoId: ID, segments: [SEG], autoSkip: false });
  env.at(12);
  const seen = [];
  const player = env.page.document.querySelector('#movie_player');
  for (const type of ['touchstart', 'touchend', 'pointerdown', 'click']) {
    player.addEventListener(type, () => seen.push(type));
    env.page.document.addEventListener(type, () => seen.push('document ' + type));
  }
  const button = env.toast().querySelector('button');
  for (const type of ['touchstart', 'touchend', 'pointerdown']) button.dispatchEvent(new env.win.Event(type, { bubbles: true }));
  button.dispatchEvent(new env.win.MouseEvent('click', { bubbles: true }));
  assert.deepEqual(seen, []);
  assert.equal(env.video.currentTime, 30);
  assertAll(env.page);
});
