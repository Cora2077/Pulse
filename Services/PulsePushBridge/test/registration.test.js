'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  MAX_WINDOWS,
  MAX_WINDOW_SECONDS,
  mergeRegistration,
  validateRegistration,
  validateWindow,
  validateWindows,
} = require('../src/registration');
const { Registry } = require('../src/registry');
const { cleanupTempDirs, dryRunEnv, isoAfter, isoAt, liveEnv, registrationBody, windowAfter } = require('./helpers');
const { loadConfig } = require('../src/config');
const { FakeClock } = require('./helpers');

test.after(() => cleanupTempDirs());

const T0 = 1_700_000_000;
const clock = new FakeClock(T0);

function validated(body, overrides = {}) {
  return validateRegistration(body, { hasUsableTokenAfterWrite: true, nowUnix: T0, maxWindows: MAX_WINDOWS, ...overrides });
}

// ---------------------------------------------------------------------------
// Window rules
// ---------------------------------------------------------------------------

test('a window requires strict ordering and an explicit UTC instant', () => {
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T01:30:00Z', end: '2026-10-16T09:30:00Z' }, 'w').ok, true);
  // Backwards.
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T09:30:00Z', end: '2026-10-16T01:30:00Z' }, 'w').reason,
    'window-not-increasing');
  // Equal endpoints are not a window.
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T01:30:00Z', end: '2026-10-16T01:30:00Z' }, 'w').reason,
    'window-not-increasing');
  // No zone: an ambiguous local time is how a push lands at 03:00.
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16 01:30', end: '2026-10-16 09:30' }, 'w').reason,
    'bad-window-start');
  // No date at all.
  assert.equal(validateWindow({ id: 'w1', start: '01:30', end: '09:30' }, 'w').reason, 'bad-window-start');
});

test('a window longer than 8 hours is refused', () => {
  const eight = validateWindow({ id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T08:00:00Z' }, 'w');
  assert.equal(eight.ok, true);
  assert.equal(eight.value.endSeconds - eight.value.startSeconds, MAX_WINDOW_SECONDS);

  const nine = validateWindow({ id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T09:00:00Z' }, 'w');
  assert.equal(nine.ok, false);
  assert.equal(nine.reason, 'window-too-long');

  // Even a full day is refused; the OS would not honour it anyway.
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-17T00:00:00Z' }, 'w').reason,
    'window-too-long');
});

test('overlapping windows are refused rather than merged', () => {
  const result = validateWindows([
    { id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T04:00:00Z' },
    { id: 'w2', start: '2026-10-16T03:00:00Z', end: '2026-10-16T07:00:00Z' },
  ]);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'windows-overlap');
});

test('touching windows are allowed and duplicates are refused', () => {
  const touching = validateWindows([
    { id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T04:00:00Z' },
    { id: 'w2', start: '2026-10-16T04:00:00Z', end: '2026-10-16T08:00:00Z' },
  ]);
  assert.equal(touching.ok, true);

  const duplicate = validateWindows([
    { id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T04:00:00Z' },
    { id: 'w1', start: '2026-10-16T05:00:00Z', end: '2026-10-16T08:00:00Z' },
  ]);
  assert.equal(duplicate.ok, false);
  assert.equal(duplicate.reason, 'duplicate-window-id');
});

test('the number of windows is bounded', () => {
  const many = Array.from({ length: MAX_WINDOWS + 1 }, (_, i) => ({
    id: `w${i}`,
    start: new Date(Date.UTC(2026, 9, 16, i * 2)).toISOString(),
    end: new Date(Date.UTC(2026, 9, 16, i * 2 + 1)).toISOString(),
  }));
  assert.equal(validateWindows(many).reason, 'too-many-windows');
});

test('autoStart must be a boolean when present and defaults to true', () => {
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T01:00:00Z' }, 'w').value.autoStart,
    true);
  assert.equal(validateWindow({ id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T01:00:00Z', autoStart: 'yes' }, 'w').reason,
    'not-a-boolean');
});

test('an unknown window field is refused', () => {
  const result = validateWindow({
    id: 'w1', start: '2026-10-16T00:00:00Z', end: '2026-10-16T01:00:00Z', market: 'SH',
  }, 'w');
  assert.equal(result.reason, 'unknown-field');
  assert.equal(result.detail, 'w.market');
});

// ---------------------------------------------------------------------------
// Registration body
// ---------------------------------------------------------------------------

test('a full registration validates', () => {
  const body = registrationBody({
    quoteSourceTimeUnix: T0,
    windows: [windowAfter(clock, 'w1', 60, 3600)],
  });
  const result = validated(body);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(result.value.attributes.symbolKey, '600519.SH');
  assert.equal(result.value.windows.length, 1);
  assert.equal(result.value.pushToStartToken.bytes.length, 32);
  assert.equal(result.value.updateToken.bytes.length, 32);
});

test('a registration with no token at all is refused', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0, omitPushToStart: true, omitUpdate: true });
  // The server passes this only when neither the body nor the stored entry has
  // a token, so this is the genuinely unreachable-by-push case.
  const result = validated(body, { hasUsableTokenAfterWrite: false });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no-token-supplied');
});

test('a template-only edit is accepted when the stored entry still has a token', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 + 60, omitPushToStart: true, omitUpdate: true, revision: 2 });
  const result = validated(body, { hasUsableTokenAfterWrite: true });
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.equal(result.value.pushToStartToken, null);
});

test('a token with the wrong length is refused', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0, pushToStartTokenBytes: 17 });
  const result = validated(body);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unexpected-token-length');
});

test('a token that is not canonical base64 is refused', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.pushToStartToken.base64 = 'not base64 at all!!';
  const result = validated(body);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'bad-token-encoding');
});

test('the template and attributes must agree on the symbol', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.attributes.symbolKey = '000001.SZ';
  body.attributes.destination = { instrumentDetail: { symbolKey: '000001.SZ' } };
  const result = validated(body);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'template-attributes-symbol-mismatch');
});

test('a position or balance anywhere in the body is rejected', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.template.plans.balance = 1000;
  const result = validated(body);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'sensitive-field-rejected');
});

test('an unknown top-level field is rejected', () => {
  const body = registrationBody({ quoteSourceTimeUnix: T0 });
  body.accountID = 'acc-1';
  const result = validated(body);
  assert.equal(result.ok, false);
  // The sensitive scan fires first and names the real problem.
  assert.equal(result.reason, 'sensitive-field-rejected');
});

test('pauseUntil must be ISO-8601 and not more than 30 days out', () => {
  const ok = validated(registrationBody({ quoteSourceTimeUnix: T0, pauseUntil: isoAfter(clock, 3600) }));
  assert.equal(ok.ok, true);

  const bad = validated(registrationBody({ quoteSourceTimeUnix: T0, pauseUntil: 'next week' }));
  assert.equal(bad.reason, 'bad-pause-until');

  const far = validated(registrationBody({ quoteSourceTimeUnix: T0, pauseUntil: isoAfter(clock, 60 * 24 * 3600) }));
  assert.equal(far.reason, 'pause-too-far');
});

test('revision must be a non-negative integer', () => {
  assert.equal(validated(registrationBody({ quoteSourceTimeUnix: T0, revision: -1 })).reason, 'bad-revision');
  assert.equal(validated(registrationBody({ quoteSourceTimeUnix: T0, revision: 1.5 })).reason, 'bad-revision');
  assert.equal(validated(registrationBody({ quoteSourceTimeUnix: T0, revision: 0 })).ok, true);
});

test('an activityID must look like an ActivityKit identifier', () => {
  const ok = validated({ ...registrationBody({ quoteSourceTimeUnix: T0 }), activityID: 'ABC-123:def_456.ghi' });
  assert.equal(ok.ok, true);
  assert.equal(validated({ ...registrationBody({ quoteSourceTimeUnix: T0 }), activityID: '../../etc/passwd' }).ok, false);
  assert.equal(validated({ ...registrationBody({ quoteSourceTimeUnix: T0 }), activityID: '' }).ok, false);
});

test('replacing a registration without tokens keeps the stored ones', () => {
  const original = validated(registrationBody({ quoteSourceTimeUnix: T0, omitPushToStart: false, omitUpdate: false })).value;
  const stored = { pushToStartToken: original.pushToStartToken, updateToken: original.updateToken, activityID: 'a-1' };
  const update = validated(registrationBody({ quoteSourceTimeUnix: T0 + 60, omitPushToStart: true, omitUpdate: true, revision: 2 })).value;
  const merged = mergeRegistration(stored, update);
  assert.equal(merged.pushToStartToken.bytes.length, 32);
  assert.equal(merged.updateToken.bytes.length, 32);
  assert.equal(merged.revision, 2);
  assert.equal(merged.activityID, 'a-1');
});

test('replacing a registration with new tokens swaps them', () => {
  const original = validated(registrationBody({ quoteSourceTimeUnix: T0 })).value;
  const fresh = validated(registrationBody({ quoteSourceTimeUnix: T0, pushToStartTokenBytes: 44 })).value;
  const merged = mergeRegistration(original, fresh);
  assert.equal(merged.pushToStartToken.bytes.length, 44);
});

// ---------------------------------------------------------------------------
// Registry: durability of the push budget
// ---------------------------------------------------------------------------

test('the registry round-trips through a durable store', () => {
  const dir = require('./helpers').makeTempDir('pulse-registry');
  const { AtomicJsonStore } = require('../src/store');
  const { emptyRegistry, validateRegistry } = require('../src/registry');

  const store = new AtomicJsonStore({
    directory: dir,
    filename: 'registry.json',
    emptyValue: emptyRegistry,
    validate: validateRegistry,
  });

  const first = new Registry({ store, now: () => T0 * 1000 });
  const body = validated(registrationBody({ quoteSourceTimeUnix: T0, windows: [windowAfter(clock, 'w1', 0, 3600)] })).value;
  first.put('device-aaaaaaaa', body);
  first.mutate('device-aaaaaaaa', (entry) => {
    entry.activeActivity = { windowID: 'w1', activityID: 'a-1', startedAtUnix: T0, pushToStart: true };
    first.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });
  });

  // A fresh process, same directory.
  const second = new Registry({ store, now: () => T0 * 1000 });
  const entry = second.get('device-aaaaaaaa');
  assert.ok(entry);
  assert.equal(entry.windows.length, 1);
  assert.equal(entry.bookkeeping.w1.startsUsed, 1);
  assert.equal(entry.activeActivity.windowID, 'w1');
  // This is the restart-bombardment guard, asserted directly.
  const { planTick, WINDOW_ACTIONS } = require('../src/scheduler');
  const plan = planTick(entry, { nowUnix: T0 + 60 });
  assert.equal(plan.action, WINDOW_ACTIONS.UPDATE);
});

test('registry bookkeeping is pruned once a window is long past', () => {
  const registry = new Registry({ now: () => T0 * 1000 });
  // `w0` closed 30 days ago; `w1` is open now.
  const body = validated(registrationBody({
    quoteSourceTimeUnix: T0,
    windows: [
      { id: 'w0', start: isoAt(T0 - 30 * 24 * 3600), end: isoAt(T0 - 30 * 24 * 3600 + 3600) },
      windowAfter(clock, 'w1', 0, 3600),
    ],
  })).value;
  registry.put('device-bbbbbbbb', body);
  registry.mutate('device-bbbbbbbb', (entry) => {
    registry.setWindowState(entry, 'w0', { startsUsed: 1, endedAtUnix: T0 - 30 * 24 * 3600 + 3600 });
    registry.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });
  });

  const entry = registry.get('device-bbbbbbbb');
  // Retention is measured from the window's own end, not from "now": a month-old
  // window is dropped immediately, while the window running now keeps its budget.
  registry.prune(entry, { nowSeconds: T0 + 60 });
  assert.equal(entry.bookkeeping.w0, undefined, 'the month-old window is dropped');
  assert.ok(entry.bookkeeping.w1, 'the open window keeps its start budget');

  // A day after `w1` ends, it is dropped too.
  registry.prune(entry, { nowSeconds: T0 + 3600 + 24 * 3600 + 1 });
  assert.equal(entry.bookkeeping.w1, undefined);
});

test('bookkeeping for a window the client removed is still pruned eventually', () => {
  const registry = new Registry({ now: () => T0 * 1000 });
  const body = validated(registrationBody({ quoteSourceTimeUnix: T0, windows: [windowAfter(clock, 'w1', 0, 3600)] })).value;
  registry.put('device-cccccccc', body);
  const entry = registry.get('device-cccccccc');
  // A window ID that is not in the schedule at all, last acted on 30 days ago.
  registry.setWindowState(entry, 'vanished', { startsUsed: 1, lastStartAtUnix: T0 - 30 * 24 * 3600 });
  registry.prune(entry, { nowSeconds: T0 });
  assert.equal(entry.bookkeeping.vanished, undefined);
});

test('a registry file with a wrong version reads as empty', () => {
  const dir = require('./helpers').makeTempDir('pulse-registry-version');
  const { AtomicJsonStore } = require('../src/store');
  const { emptyRegistry, validateRegistry } = require('../src/registry');
  const store = new AtomicJsonStore({
    directory: dir,
    filename: 'registry.json',
    emptyValue: emptyRegistry,
    validate: validateRegistry,
  });
  store.write({ version: 99, registrations: {} });
  const registry = new Registry({ store, now: () => T0 * 1000 });
  assert.equal(registry.size, 0);
});

test('a device id that is not opaque is refused by the registry layer too', () => {
  const { isOpaqueID } = require('../src/util');
  assert.equal(isOpaqueID('../escape'), false);
});

void dryRunEnv;
void liveEnv;
void loadConfig;
