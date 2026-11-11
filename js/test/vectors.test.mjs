// TestVectors as seen from JS: prelude, bridge shapes, commands, routing (PLAN.md §5.8). Owner: P0.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  prelude, preludeVectors, bridgeVector, bridgeVectorTypes, assertMatchesVector,
  commandVectors, routingVectors, readManifest,
} from './harness.mjs';

test('vectors › prelude.json › harness prelude() is byte-identical to the Swift generator', () => {
  const { cases } = preludeVectors();
  assert.ok(cases.length >= 3);
  for (const c of cases) assert.equal(prelude(c), c.source, `${c.role} ${c.debug} ${JSON.stringify(c.build)}`);
});

test('vectors › prelude.json › the prelude defines a configurable placeholder that bridge.js replaces', () => {
  const sandbox = {};
  sandbox.window = sandbox;
  const { cases } = preludeVectors();
  new Function('window', cases[2].source)(sandbox);
  const descriptor = Object.getOwnPropertyDescriptor(sandbox, '__ytadless');
  assert.equal(descriptor.configurable, true);
  assert.equal(descriptor.enumerable, false);
  assert.deepEqual(descriptor.value.config, { build: cases[2].build, debug: cases[2].debug, role: cases[2].role });
});

for (const type of bridgeVectorTypes()) {
  test(`vectors › bridge/${type}.json › body and minimal satisfy their own shape`, () => {
    const vector = bridgeVector(type);
    assert.equal(vector.type, type);
    assert.equal(vector.body.type, type);
    for (const key of vector.optional) assert.ok(Object.hasOwn(vector.body, key), `optional ${key} appears in body`);
    for (const key of Object.keys(vector.enums)) assert.ok(Object.hasOwn(vector.body, key), `enum ${key} appears in body`);
    assertMatchesVector(vector.body, 'body');
    if (vector.minimal) {
      assertMatchesVector(vector.minimal, 'minimal');
      const missing = Object.keys(vector.body).filter((k) => !Object.hasOwn(vector.minimal, k) || vector.minimal[k] === null);
      assert.deepEqual(missing.sort(), [...vector.optional].sort(), 'minimal leaves out exactly the optional fields');
    } else {
      assert.deepEqual(vector.optional, [], 'a vector with optional fields has a minimal sample');
    }
  });
}

test('vectors › assertMatchesVector › rejects unknown fields, wrong types, bad enums, non-finite numbers', () => {
  const base = bridgeVector('playback').body;
  assert.throws(() => assertMatchesVector({ ...base, extra: 1 }), /unexpected field "extra"/);
  assert.throws(() => assertMatchesVector({ ...base, position: '1' }), /"position" is a number/);
  assert.throws(() => assertMatchesVector({ ...base, status: 'stopped' }), /"status"="stopped"/);
  assert.throws(() => assertMatchesVector({ ...base, position: Infinity }), /"position" is finite/);
  assert.throws(() => assertMatchesVector({ ...base, rate: null }), /"rate" is null but not optional/);
  const { status, ...noStatus } = base;
  assert.ok(status);
  assert.throws(() => assertMatchesVector(noStatus), /missing required field "status"/);
  assert.throws(() => assertMatchesVector({ ...bridgeVector('filterHit').body, count: 1.5 }), /"count" is an integer/);
});

test('vectors › commands.json › unique names, handlers are manifest scripts', () => {
  const { commands } = commandVectors();
  const files = new Set(readManifest().scripts.map((s) => s.file));
  assert.equal(new Set(commands.map((c) => c.name)).size, commands.length);
  for (const c of commands) {
    assert.ok(files.has(c.handler), `${c.name}: handler ${c.handler} is in the manifest`);
    assert.equal(typeof c.args, 'object');
  }
});

test('vectors › routing.json › well-formed for router.js', () => {
  const { version, decide, normalize } = routingVectors();
  assert.equal(version, 1);
  assert.ok(decide.length >= 25);
  assert.ok(normalize.length > 0);
  const decisions = new Set(['allow', 'openInPlayer', 'openInBrowse', 'openExternally', 'cancel']);
  for (const c of decide) {
    assert.ok(['browse', 'player'].includes(c.role), c.name);
    assert.ok(['click', 'history', 'windowOpen', 'location', 'initial'].includes(c.trigger), c.name);
    assert.doesNotThrow(() => new URL(c.url), c.name);
    assert.ok(decisions.has(c.expect.decision), c.name);
    if (c.expect.decision === 'openInPlayer') assert.match(c.expect.request.id, /^[A-Za-z0-9_-]{11}$/, c.name);
  }
});
