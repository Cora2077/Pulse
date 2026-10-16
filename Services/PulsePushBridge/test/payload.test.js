'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  MAX_PAYLOAD_BYTES,
  POINTS_CURRENCY_CODE,
  buildApsDictionary,
  checkApsShape,
  checkPayloadBudget,
  classifyToken,
  materializeState,
  validateAttributes,
  validateDestination,
  validateState,
} = require('../src/payload');
const { findForbiddenKey, screenBody } = require('../src/sensitive');
const { unixSecondsToAppleReference } = require('../src/util');
const { cleanupTempDirs, fakeToken, registrationBody } = require('./helpers');

test.after(() => cleanupTempDirs());

const T0 = 1_700_000_000;

// ---------------------------------------------------------------------------
// Swift Codable correspondence
// ---------------------------------------------------------------------------

test('the Swift JSONEncoder shape validates, including 2001-reference dates', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  // Exactly what `JSONEncoder` with `.deferredToDate` produces: a bare number
  // of seconds since 2001, not milliseconds and not ISO-8601.
  assert.equal(typeof body.template.primary.quoteSourceTime.value, 'number');
  assert.equal(body.template.primary.quoteSourceTime.encoding, 'appleReferenceSeconds');

  const result = validateState(body.template, 'template');
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(result.value.status, 'live');
  assert.equal(result.value.plans.remainingPlanCount, 1);
  assert.equal(result.value.sessionID, 'sh.2026-10-16.regular');
  assert.equal(result.value.primary.marketPhase, 'regular');
});

test('the same instant in the three accepted encodings checks out identically', () => {
  const base = registrationBody({ quoteSourceTimeUnix: T0 }).template;
  const reference = validateState(base, 't');
  assert.equal(reference.ok, true);

  const unix = structuredClone(base);
  unix.primary.quoteSourceTime = { encoding: 'unixSeconds', value: T0 };
  unix.quoteSourceTime = { encoding: 'unixSeconds', value: T0 };
  unix.staleDate = { encoding: 'unixSeconds', value: T0 + 300 };
  const unixResult = validateState(unix, 't');
  assert.equal(unixResult.ok, true);

  const iso = structuredClone(base);
  iso.primary.quoteSourceTime = { encoding: 'iso8601', value: new Date(T0 * 1000).toISOString() };
  iso.quoteSourceTime = { encoding: 'iso8601', value: new Date(T0 * 1000).toISOString() };
  iso.staleDate = { encoding: 'iso8601', value: new Date((T0 + 300) * 1000).toISOString() };
  const isoResult = validateState(iso, 't');
  assert.equal(isoResult.ok, true);

  const { dateToUnixSeconds } = require('../src/payload');
  assert.equal(dateToUnixSeconds(reference.value.quoteSourceTime), T0);
  assert.equal(dateToUnixSeconds(unixResult.value.quoteSourceTime), T0);
  assert.equal(dateToUnixSeconds(isoResult.value.quoteSourceTime), T0);
});

test('an unlabelled date is refused rather than guessed', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.quoteSourceTime = 1700000000; // no encoding tag
  const result = validateState(body.template, 't');
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'date-must-be-an-object');
});

test('an unknown date encoding is refused', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.quoteSourceTime = { encoding: 'unixMilliseconds', value: T0 * 1000 };
  const result = validateState(body.template, 't');
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unknown-date-encoding');
});

test('an enum case the Swift decoder would throw on is refused, not coerced', () => {
  // `PulseMarketPhase` is a raw-value String enum, so a case the app does not
  // know makes the decoder throw. Accepting it here would register a
  // registration whose payload the device cannot decode.
  const body = registrationBody({ quoteSourceTimeUnix: T0, marketPhase: 'auction' });
  const result = validateState(body.template, 't');
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unknown-enum-case');
  assert.equal(result.detail, 't.primary.marketPhase');
});

test('an unknown status is refused', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0, status: 'syncing' });
  const result = validateState(body.template, 't');
  assert.equal(result.ok, false);
  assert.equal(result.detail, 't.status');
});

test('a zero or negative price is refused: it is what a failed feed returns', () => {
  for (const price of [0, -1, Number.NaN, Number.POSITIVE_INFINITY, '1680']) {
    const body = registrationBody({ quoteSourceTimeUnix: T0, price });
    const result = validateState(body.template, 't');
    assert.equal(result.ok, false, String(price));
    assert.equal(result.detail, 't.primary.price');
  }
});

test('changePercent stays nil-able and is never fabricated', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0, changePercent: null });
  const result = validateState(body.template, 't');
  assert.equal(result.ok, true);
  assert.equal(result.value.primary.changePercent, null);
});

test('POINTS is accepted as the explicit index-points unit, and only that', () => {
  // The iOS main target tracks KOSPI / sector indices: the quote is an index
  // level, and `POINTS` says so explicitly. It survives onto the wire so the
  // device renders a points label, not a currency one.
  const body = registrationBody({ quoteSourceTimeUnix: T0, currencyCode: 'POINTS', price: 3245.67 });
  const validated = validateState(body.template, 't');
  assert.equal(validated.ok, true, JSON.stringify(validated));
  assert.equal(validated.value.primary.currencyCode, POINTS_CURRENCY_CODE);

  const state = materializeState(validated.value, { quoteSourceTimeUnix: T0, staleDateUnix: T0 + 300 });
  assert.equal(state.primary.currencyCode, 'POINTS');

  // This is not a widening of the currency pattern: anything else that is not
  // a 3–4 letter ISO-style code is still refused, including near-misses.
  for (const bad of ['POINT', 'points', 'Points', 'POINTSX', 'PT', 'P1NTS', '점']) {
    const rejected = validateState(
      registrationBody({ quoteSourceTimeUnix: T0, currencyCode: bad }).template, 't');
    assert.equal(rejected.ok, false, bad);
    assert.equal(rejected.detail, 't.primary.currencyCode', bad);
  }

  // Real codes, including whole-unit ones, are unaffected.
  for (const good of ['CNY', 'KRW', 'JPY', 'USDT']) {
    assert.equal(
      validateState(registrationBody({ quoteSourceTimeUnix: T0, currencyCode: good }).template, 't').ok,
      true, good);
  }
});

test('the destination union validates all three cases and rejects a fourth', () => {
  assert.deepEqual(validateDestination({ instrumentDetail: { symbolKey: '600519.SH' } }),
    { ok: true, value: { kind: 'instrumentDetail', symbolKey: '600519.SH' } });
  assert.deepEqual(validateDestination({ plans: { planID: null } }),
    { ok: true, value: { kind: 'plans', planID: null } });
  assert.deepEqual(validateDestination({ plans: { planID: 'p1' } }),
    { ok: true, value: { kind: 'plans', planID: 'p1' } });
  assert.deepEqual(validateDestination({ planInbox: {} }), { ok: true, value: { kind: 'planInbox' } });
  // A write route is not expressible; the service must not invent one.
  assert.equal(validateDestination({ placeOrder: { symbolKey: '600519.SH' } }).ok, false);
  assert.equal(validateDestination({ instrumentDetail: { symbolKey: 'x' }, planInbox: {} }).ok, false);
});

test('attributes require symbolKey and a valid destination', () => {
  const good = validateAttributes({
    symbolKey: '600519.SH',
    destination: { plans: { planID: null } },
  });
  assert.equal(good.ok, true);
  assert.equal(validateAttributes({ symbolKey: '600519.SH' }).ok, false);
  assert.equal(validateAttributes({ symbolKey: 'bad symbol!', destination: { planInbox: {} } }).ok, false);
});

// ---------------------------------------------------------------------------
// Sensitive fields: the red line
// ---------------------------------------------------------------------------

test('position, balance, cost and notes are rejected at any depth', () => {
  const cases = [
    { balance: 1000 },
    { Position: 5 },
    { nested: { costBasis: 12.5 } },
    { template: { primary: { quantity: 100 } } },
    { list: [{ pnl: 3 }] },
    { 'cost basis': 1 },
    { accountID: 'x' },
    { fillPrice: 1 },
    { journal: 'notes' },
    { apnsToken: 'x' },
  ];
  for (const body of cases) {
    const found = findForbiddenKey(body);
    assert.notEqual(found, null, JSON.stringify(body));
  }
});

test('the allowed payload fields are not caught by the denylist', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  assert.equal(findForbiddenKey(body), null);
  assert.equal(findForbiddenKey({ changePercent: 0.5, remainingPlanCount: 2, sourceDelay: 60 }), null);
});

test('an unknown field is rejected, not silently stripped', () => {
  const allowed = ['attributes', 'template'];
  const result = screenBody({ attributes: {}, template: {}, extra: 1 }, allowed, 'registration');
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unknown-field');
  assert.equal(result.detail, 'registration.extra');
});

test('a sensitive field reports the sensitive reason, not the unknown-field reason', () => {
  const result = screenBody({ balance: 1 }, ['attributes'], 'registration');
  assert.equal(result.reason, 'sensitive-field-rejected');
  assert.equal(result.detail, '$.balance');
});

test('a non-object body is refused', () => {
  assert.equal(screenBody([], ['a'], 'x').reason, 'not-an-object');
  assert.equal(screenBody('a string', ['a'], 'x').reason, 'not-an-object');
});

// ---------------------------------------------------------------------------
// APNs payload
// ---------------------------------------------------------------------------

test('the aps dictionary keeps the outer APNs clocks in UNIX seconds', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  const template = validateState(body.template, 't').value;
  const state = materializeState(template, {
    quoteSourceTimeUnix: T0,
    staleDateUnix: T0 + 300,
  });
  const aps = buildApsDictionary(state, { event: 'update', nowUnix: T0 + 10, staleDateUnix: T0 + 300 });

  // The outer APNs fields are consumed by the push service itself, not by the
  // activity's Codable state: they stay seconds since 1970.
  assert.equal(aps.aps.timestamp, T0 + 10);
  assert.equal(aps.aps['stale-date'], T0 + 300);
  assert.equal(aps.aps.event, 'update');
  assert.ok(aps.aps.timestamp > 1_000_000_000, 'timestamp must be UNIX, not 2001-reference');
  assert.ok(aps.aps['stale-date'] > 1_000_000_000, 'stale-date must be UNIX, not 2001-reference');

  // The content-state dates are the opposite clock: the system decodes them
  // with JSONDecoder's default strategy, so they are seconds since 2001 under
  // the Swift property names. UNIX seconds here would decode as 2057.
  const contentState = aps.aps['content-state'];
  assert.equal(contentState.quoteSourceTime, T0 - 978307200);
  assert.equal(contentState.staleDate, T0 + 300 - 978307200);
  assert.equal(contentState.primary.quoteSourceTime, T0 - 978307200);
  // The UNIX mirrors stay for service-side diagnostics under unambiguous names.
  assert.equal(contentState.quoteSourceTimeUnix, T0);
  assert.equal(contentState.staleDateUnix, T0 + 300);
  assert.equal(contentState.primary.quoteSourceTimeUnix, T0);
  // The offset is exactly the 2001 reference date, applied once, as a change of
  // unit — never a change of the source instant.
  assert.equal(contentState.quoteSourceTimeUnix - contentState.quoteSourceTime, 978307200);
  assert.equal(unixSecondsToAppleReference(T0), contentState.quoteSourceTime);
});

test('the aps shape check catches a missing or non-integer field', () => {
  const contentState = minimalWireContentState();
  const ok = { aps: { timestamp: 1, event: 'update', 'content-state': contentState } };
  assert.equal(checkApsShape(ok).ok, true);
  assert.equal(checkApsShape({}).reason, 'missing-aps');
  assert.equal(checkApsShape({ aps: { event: 'update', 'content-state': contentState } }).reason, 'missing-aps-key');
  assert.equal(checkApsShape({ aps: { timestamp: 1.5, event: 'update', 'content-state': contentState } }).reason,
    'aps-timestamp-not-integer-seconds');
  assert.equal(checkApsShape({ aps: { timestamp: 1, event: 'syncing', 'content-state': contentState } }).reason,
    'bad-aps-event');
  assert.equal(checkApsShape({ aps: { timestamp: 1, event: 'update', 'content-state': [] } }).reason,
    'aps-content-state-not-an-object');
  assert.equal(
    checkApsShape({ aps: { timestamp: 1, event: 'update', 'content-state': contentState, 'stale-date': 1.5 } }).reason,
    'aps-stale-date-not-integer-seconds');
});

test('the aps shape check refuses content-state the default decoder cannot read', () => {
  const wrap = (cs) => ({ aps: { timestamp: 1, event: 'update', 'content-state': cs } });

  // A content-state with no native date keys is what the pre-fix service
  // emitted: the system decoder throws on it, so the bridge must refuse it.
  const bare = checkApsShape(wrap({}));
  assert.equal(bare.reason, 'aps-content-state-date-not-a-number');
  assert.equal(bare.detail, 'content-state.quoteSourceTime');

  for (const [label, mutate] of [
    ['root quoteSourceTime as a string', (cs) => { cs.quoteSourceTime = '1700000000'; }],
    ['root staleDate null', (cs) => { cs.staleDate = null; }],
    ['primary quoteSourceTime missing', (cs) => { delete cs.primary.quoteSourceTime; }],
    ['plans.asOf as a tagged object', (cs) => { cs.plans = { asOf: { encoding: 'unixSeconds', value: 1 } }; }],
  ]) {
    const cs = structuredClone(minimalWireContentState());
    mutate(cs);
    const result = checkApsShape(wrap(cs));
    assert.equal(result.ok, false, label);
    assert.equal(result.reason, 'aps-content-state-date-not-a-number', label);
  }
});

/** The smallest content-state that satisfies the native-decodability check. */
function minimalWireContentState() {
  return {
    quoteSourceTime: 721692800,
    staleDate: 721693100,
    primary: { quoteSourceTime: 721692800 },
  };
}

test('materializeState cannot invent a price: it copies the template', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0, price: 42.5, change: -1.5 });
  const template = validateState(body.template, 't').value;
  const state = materializeState(template, { quoteSourceTimeUnix: T0 - 60, staleDateUnix: T0 - 60 + 300 });
  assert.equal(state.primary.price, 42.5);
  assert.equal(state.primary.change, -1.5);
  assert.equal(state.primary.displayName, '贵州茅台');
  assert.equal(state.primary.quoteSourceTimeUnix, T0 - 60);
  assert.equal(state.primary.quoteSourceTime, unixSecondsToAppleReference(T0 - 60));
  // The plans digest is re-emitted in wire form: the three counts, untouched.
  assert.deepEqual(state.plans, {
    priceConditionReachedCount: 0,
    manualReviewCount: 0,
    remainingPlanCount: 1,
  });
});

test('materializeState refuses a non-integer clock instead of emitting null', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  const template = validateState(body.template, 't').value;
  // Regression: the engine used to pass `null` here for a client snapshot
  // source, which serialized an undecodable date into `content-state`.
  assert.throws(
    () => materializeState(template, { quoteSourceTimeUnix: null, staleDateUnix: T0 + 300 }),
    /quoteSourceTimeUnix/,
  );
  assert.throws(
    () => materializeState(template, { quoteSourceTimeUnix: T0, staleDateUnix: null }),
    /staleDateUnix/,
  );
});

test('a client snapshot template keeps its own source time on every push', () => {
  // The source time travels from the template, not from the clock: this is the
  // "never stamp an old quote with now" rule at the payload layer.
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  const template = validateState(body.template, 't').value;
  assert.equal(template.quoteSourceTimeUnix, T0);
  assert.equal(template.primary.quoteSourceTimeUnix, T0);

  const state = materializeState(template, {
    quoteSourceTimeUnix: template.quoteSourceTimeUnix,
    staleDateUnix: T0 + 300,
  });
  const aps = buildApsDictionary(state, { event: 'update', nowUnix: T0 + 600, staleDateUnix: T0 + 300 });
  // `timestamp` is now; the quote's own clock is untouched and older, on both
  // the UNIX mirror and the native 2001-reference field.
  assert.equal(aps.aps['content-state'].quoteSourceTimeUnix, T0);
  assert.equal(aps.aps['content-state'].quoteSourceTime, unixSecondsToAppleReference(T0));
  assert.equal(aps.aps.timestamp, T0 + 600);
});

test('plan asOf and syncState are tolerated and carried through', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.plans.syncState = 'pending';
  body.template.plans.asOf = { encoding: 'appleReferenceSeconds', value: unixSecondsToAppleReference(T0) };

  const validated = validateState(body.template, 't');
  assert.equal(validated.ok, true, JSON.stringify(validated));
  assert.equal(validated.value.plans.syncState, 'pending');
  assert.equal(validated.value.plans.asOfUnix, T0);
  assert.equal(validated.value.plans.asOfEncoding, 'appleReferenceSeconds');

  // They must survive into the pushed state, or the device loses the field —
  // and `asOf` must arrive as a bare 2001-reference number, the only form the
  // system decoder accepts as a `Date`. The tagged input object and the UNIX
  // mirrors are service-internal and do not cross the wire.
  const state = materializeState(validated.value, { quoteSourceTimeUnix: T0, staleDateUnix: T0 + 300 });
  assert.equal(state.plans.syncState, 'pending');
  assert.equal(state.plans.asOf, unixSecondsToAppleReference(T0));
  assert.equal('asOfUnix' in state.plans, false);
  assert.equal('asOfEncoding' in state.plans, false);
});

test('an unknown plan syncState is refused rather than coerced', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.plans.syncState = 'bogus';
  const validated = validateState(body.template, 't');
  assert.equal(validated.ok, false);
  assert.equal(validated.reason, 'unknown-enum-case');
});

test('the 4 KB budget is enforced, not assumed', () => {
  const small = { aps: { timestamp: 1, event: 'update', 'content-state': { a: 1 } } };
  assert.equal(checkPayloadBudget(small).ok, true);

  const big = { aps: { timestamp: 1, event: 'update', 'content-state': { blob: 'x'.repeat(MAX_PAYLOAD_BYTES) } } };
  const result = checkPayloadBudget(big);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'payload-too-large');
});

test('a realistic payload fits well inside 4 KB', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  const template = validateState(body.template, 't').value;
  const state = materializeState(template, { quoteSourceTimeUnix: T0, staleDateUnix: T0 + 300 });
  const aps = buildApsDictionary(state, { event: 'update', nowUnix: T0, staleDateUnix: T0 + 300 });
  const bytes = checkPayloadBudget(aps);
  assert.equal(bytes.ok, true, JSON.stringify(bytes));
  assert.ok(bytes.bytes < 1024, `payload was ${bytes.bytes} bytes`);
});

test('token lengths are classified by kind', () => {
  assert.equal(classifyToken('pushToStart', 32).ok, true);
  assert.equal(classifyToken('pushToStart', 44).ok, true);
  assert.equal(classifyToken('update', 32).ok, true);
  assert.equal(classifyToken('update', 44).ok, false);
  assert.equal(classifyToken('pushToStart', 3).ok, false);
  assert.equal(classifyToken('update', 0).ok, false);
});

test('fake tokens are the length they claim', () => {
  assert.equal(fakeToken(32).length, 32);
  assert.equal(fakeToken(44).length, 44);
});
