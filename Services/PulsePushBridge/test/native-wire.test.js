'use strict';

/**
 * Native wire golden tests.
 *
 * These tests do not let JavaScript grade its own homework. The fixtures in
 * `test/fixtures/` were produced by Apple Swift 6.4's Foundation — compiled
 * against the REAL `PulseActivityState` from `Packages/PulseActivity` — using
 * a plain `JSONEncoder()` / `JSONDecoder()`, which Apple's ActivityKit
 * documentation states are the only strategies the system ever applies to a
 * Live Activity push's `content-state`:
 *
 *   - `native-date-content-state.json` — the exact APNs body this bridge emits
 *     for one fixed registration. The Swift proof decoded its `content-state`
 *     into the real `PulseActivityState` with default strategies and recovered
 *     every intended instant, then re-encoded it byte-identically.
 *   - `native-date-golden.json` — the Swift-side evidence: what the default
 *     encoder writes for each golden instant, what the default decoder read
 *     back from the bridge's body, and the outer-APS UNIX clocks.
 *
 * Regenerating the fixtures requires a macOS Swift toolchain and is described
 * in `docs/NATIVE_WIRE.md`; the tests below pin the bridge's output to the
 * committed evidence so the suite itself never needs Swift.
 */

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const {
  buildApsDictionary,
  checkApsShape,
  checkPayloadBudget,
  materializeState,
  validateState,
} = require('../src/payload');
const { APPLE_REFERENCE_DATE_UNIX_SECONDS, unixSecondsToAppleReference } = require('../src/util');
const { registrationBody } = require('./helpers');

const FIXTURE_DIR = path.join(__dirname, 'fixtures');
const WIRE_BODY = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'native-date-content-state.json'), 'utf8'));
const GOLDEN = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, 'native-date-golden.json'), 'utf8'));

const T0 = 1_700_000_000;

/** Rebuilds, from live code, the body the committed fixture must equal. */
function buildWireBody() {
  const body = registrationBody({
    quoteSourceTimeUnix: T0,
    plans: {
      priceConditionReachedCount: 1,
      manualReviewCount: 2,
      remainingPlanCount: 3,
      asOf: { encoding: 'appleReferenceSeconds', value: unixSecondsToAppleReference(T0 - 60) },
      syncState: 'pending',
    },
  });
  const validated = validateState(body.template, 'template');
  assert.equal(validated.ok, true, JSON.stringify(validated));
  const state = materializeState(validated.value, {
    quoteSourceTimeUnix: T0,
    staleDateUnix: T0 + 300,
  });
  return buildApsDictionary(state, {
    event: 'update',
    nowUnix: T0 + 10,
    staleDateUnix: T0 + 300,
    relevanceScore: 80,
  });
}

test('the committed content-state fixture is exactly what the current code emits', () => {
  // If the wire shape ever changes, this fails until the fixtures are
  // regenerated AND re-verified by the Swift proof — never edited by hand.
  assert.deepEqual(buildWireBody(), WIRE_BODY);
});

test('Swift\'s default encoder agrees with the bridge offset on every golden instant', () => {
  assert.equal(GOLDEN.referenceDateUnixSeconds, APPLE_REFERENCE_DATE_UNIX_SECONDS);
  assert.equal(GOLDEN.referenceDateUnixSeconds, 978_307_200);
  for (const golden of GOLDEN.dates) {
    // The number the bridge computes for this instant...
    const bridgeValue = unixSecondsToAppleReference(golden.unixSeconds);
    // ...equals the Date's timeIntervalSinceReferenceDate on macOS...
    assert.equal(bridgeValue, golden.appleReferenceSeconds, golden.name);
    // ...and equals the exact JSON the default JSONEncoder emitted.
    assert.equal(JSON.parse(golden.swiftEncodedJSON).date, golden.appleReferenceSeconds, golden.name);
  }
  // The boundary cases prove direction: the 2001 epoch encodes as 0, and the
  // UNIX epoch encodes as a negative offset. A flipped sign would fail here.
  const byName = Object.fromEntries(GOLDEN.dates.map((d) => [d.name, d]));
  assert.equal(byName['reference-epoch'].appleReferenceSeconds, 0);
  assert.equal(byName['unix-epoch'].appleReferenceSeconds, -978_307_200);
});

test('the system-default decoder recovered every intended instant from the bridge body', () => {
  // These numbers were produced by Swift decoding `native-date-content-state.json`
  // into the real PulseActivityState with a plain JSONDecoder() — the decode
  // the system performs on a Live Activity push, which no app can reconfigure.
  const decoded = GOLDEN.decodedContentState;
  assert.equal(decoded.quoteSourceTimeUnix, T0);
  assert.equal(decoded.primaryQuoteSourceTimeUnix, T0);
  assert.equal(decoded.staleDateUnix, T0 + 300);
  assert.equal(decoded.plansAsOfUnix, T0 - 60);
  assert.equal(decoded.status, 'live');
  assert.equal(decoded.syncState, 'pending');
  assert.equal(decoded.sessionID, 'sh.2026-10-16.regular');
  assert.equal(decoded.currencyCode, 'CNY');
  assert.equal(decoded.price, 1680.5);
  // Re-encoding the decoded state with the default JSONEncoder reproduced the
  // bridge's wire date numbers exactly — the strongest form of agreement.
  assert.equal(GOLDEN.reencodedContentStateMatchesNode, true);
});

test('the bridge emits the exact date numbers Swift\'s default encoder writes', () => {
  const contentState = WIRE_BODY.aps['content-state'];
  const byName = Object.fromEntries(GOLDEN.dates.map((d) => [d.name, d]));
  assert.equal(contentState.quoteSourceTime, byName['quote-source'].appleReferenceSeconds);
  assert.equal(contentState.primary.quoteSourceTime, byName['quote-source'].appleReferenceSeconds);
  assert.equal(contentState.staleDate, byName['stale-date'].appleReferenceSeconds);
  assert.equal(contentState.plans.asOf, byName['plan-as-of'].appleReferenceSeconds);
});

test('the outer APNs clocks are UNIX seconds while the inner dates are 2001-reference', () => {
  const { aps } = WIRE_BODY;
  // Consumed by APNs itself: seconds since 1970, and Swift recorded the same.
  assert.equal(aps.timestamp, T0 + 10);
  assert.equal(aps['stale-date'], T0 + 300);
  assert.equal(GOLDEN.outerAps.timestamp, T0 + 10);
  assert.equal(GOLDEN.outerAps.staleDate, T0 + 300);
  // Consumed by the system decoder: seconds since 2001 — strictly smaller than
  // the outer clocks by exactly the reference offset, and never swapped.
  const cs = aps['content-state'];
  assert.equal(aps.timestamp - cs.quoteSourceTime, APPLE_REFERENCE_DATE_UNIX_SECONDS + 10);
  assert.equal(aps['stale-date'] - cs.staleDate, APPLE_REFERENCE_DATE_UNIX_SECONDS);
  // The UNIX mirrors exist for service-side diagnostics and agree with APNs.
  assert.equal(cs.quoteSourceTimeUnix, T0);
  assert.equal(cs.staleDateUnix, T0 + 300);
  assert.equal(cs.quoteSourceTimeUnix - cs.quoteSourceTime, APPLE_REFERENCE_DATE_UNIX_SECONDS);
});

test('the golden body passes the pre-send shape and budget checks', () => {
  assert.equal(checkApsShape(WIRE_BODY).ok, true);
  const budget = checkPayloadBudget(WIRE_BODY);
  assert.equal(budget.ok, true, JSON.stringify(budget));
});
