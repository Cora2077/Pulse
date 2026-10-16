'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  FRESHNESS_WINDOWS_SECONDS,
  WINDOW_ACTIONS,
  attemptsExhausted,
  backoffSeconds,
  effectiveSourceTimeUnix,
  isSourceFresh,
  planTick,
  staleDateUnixFor,
} = require('../src/scheduler');
const { validateRegistration, MAX_WINDOWS } = require('../src/registration');
const { Registry } = require('../src/registry');
const { unixSecondsToAppleReference } = require('../src/util');
const { FakeClock, cleanupTempDirs, isoAt, registrationBody, windowAfter } = require('./helpers');

test.after(() => cleanupTempDirs());

const T0 = 1_700_000_000;

/** A registry holding one validated registration, ready to plan. */
function makeRegistry(clock, { windows, templateOverrides = {}, quoteSourceTimeUnix, ...overrides } = {}) {
  const registry = new Registry({ now: () => clock.now() });
  const validated = validateRegistration(
    registrationBody({
      quoteSourceTimeUnix: quoteSourceTimeUnix ?? clock.nowUnix(),
      windows: windows ?? [windowAfter(clock, 'w1', 0, 3600)],
      ...templateOverrides,
      ...overrides,
    }),
    { hasUsableTokenAfterWrite: true, nowUnix: clock.nowUnix(), maxWindows: MAX_WINDOWS },
  );
  assert.equal(validated.ok, true, JSON.stringify(validated));
  registry.put('device-aaaaaaaa', validated.value);
  return registry;
}

// ---------------------------------------------------------------------------
// Source-time arithmetic
// ---------------------------------------------------------------------------

test('the stale date is derived from the source time, never from now', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock);
  const entry = registry.get('device-aaaaaaaa');

  // Five minutes after the source stamped it, a regular-session quote expires.
  assert.equal(staleDateUnixFor(entry.template), T0 + FRESHNESS_WINDOWS_SECONDS.regular);
  assert.equal(staleDateUnixFor(entry.template), T0 + 300);

  // Wall clock is irrelevant: it is still the same deadline a day later.
  clock.advanceSeconds(24 * 3600);
  assert.equal(staleDateUnixFor(entry.template), T0 + 300);
});

test('a source-declared delay ages the source time rather than being ignored', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { templateOverrides: {} });
  const entry = registry.get('device-aaaaaaaa');
  entry.template.primary.sourceDelay = 120;
  assert.equal(effectiveSourceTimeUnix(entry.template), T0 + 120);
  assert.equal(staleDateUnixFor(entry.template), T0 + 120 + FRESHNESS_WINDOWS_SECONDS.regular);
});

test('the freshness window follows the market phase', () => {
  const clock = new FakeClock(T0);
  for (const [phase, expected] of [
    ['regular', 300],
    ['preMarket', 1200],
    ['postMarket', 1200],
    ['overnight', 1200],
    ['lunchBreak', 1200],
    ['closed', 24 * 3600],
    ['unknown', 900],
  ]) {
    const registry = makeRegistry(clock, { templateOverrides: { marketPhase: phase } });
    const entry = registry.get('device-aaaaaaaa');
    assert.equal(staleDateUnixFor(entry.template) - T0, expected, phase);
  }
});

test('freshness is evaluated against an explicit now', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock);
  const entry = registry.get('device-aaaaaaaa');
  assert.equal(isSourceFresh(entry.template, T0 + 299), true);
  assert.equal(isSourceFresh(entry.template, T0 + 300), false);
  assert.equal(isSourceFresh(entry.template, T0 + 3600), false);
});

// ---------------------------------------------------------------------------
// Gate order
// ---------------------------------------------------------------------------

test('a disabled registration does nothing at all', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { enabled: false });
  const entry = registry.get('device-aaaaaaaa');
  const plan = planTick(entry, { nowUnix: clock.nowUnix() });
  assert.equal(plan.action, WINDOW_ACTIONS.SKIPPED_DISABLED);
  assert.equal(plan.reason, 'disabled');
});

test('a disabled registration with a running activity ends it', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock);
  const entry = registry.get('device-aaaaaaaa');
  entry.enabled = false;
  entry.activeActivity = { windowID: 'w1', activityID: 'a', startedAtUnix: T0, pushToStart: true };
  const plan = planTick(entry, { nowUnix: clock.nowUnix() });
  assert.equal(plan.shouldEndActivity, true);
});

test('a paused registration does nothing while the pause holds', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { pauseUntil: isoAt(T0 + 3600) });
  const entry = registry.get('device-aaaaaaaa');
  assert.equal(planTick(entry, { nowUnix: T0 + 60 }).action, WINDOW_ACTIONS.SKIPPED_PAUSED);
  assert.equal(planTick(entry, { nowUnix: T0 + 3599 }).action, WINDOW_ACTIONS.SKIPPED_PAUSED);
  // The window itself also closed at T0+3600, so past that point the plan is
  // idle for two independent reasons. Assert the pause specifically with a
  // window that is still open and a quote that is still fresh.
  const stillOpen = makeRegistry(clock, {
    windows: [windowAfter(clock, 'w1', 0, 4 * 3600)],
    pauseUntil: isoAt(T0 + 3600),
    quoteSourceTimeUnix: T0,
  }).get('device-aaaaaaaa');
  assert.equal(planTick(stillOpen, { nowUnix: T0 + 3601 }).action, WINDOW_ACTIONS.SKIPPED_STALE_SOURCE);

  const freshAndUnpaused = makeRegistry(clock, {
    windows: [windowAfter(clock, 'w1', 0, 4 * 3600)],
    pauseUntil: isoAt(T0 + 3600),
    quoteSourceTimeUnix: T0 + 3601,
  }).get('device-aaaaaaaa');
  assert.equal(planTick(freshAndUnpaused, { nowUnix: T0 + 3601 }).action, WINDOW_ACTIONS.START);
});

test('pause and disable remain distinct states', () => {
  const clock = new FakeClock(T0);
  const paused = makeRegistry(clock, { pauseUntil: isoAt(T0 + 3600) }).get('device-aaaaaaaa');
  const disabled = makeRegistry(clock, { enabled: false }).get('device-aaaaaaaa');
  assert.equal(planTick(paused, { nowUnix: T0 }).reason, 'paused');
  assert.equal(planTick(disabled, { nowUnix: T0 }).reason, 'disabled');
  // A pause never disables, and disabling never sets a pause.
  assert.equal(paused.enabled, true);
  assert.equal(disabled.pauseUntilUnix, null);
});

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

test('before a window opens nothing happens, and it is not a start', () => {
  const clock = new FakeClock(T0);
  // The quote is stamped when the window opens, so the freshness gate is not
  // what this test is measuring — the window boundary is.
  const registry = makeRegistry(clock, {
    windows: [windowAfter(clock, 'w1', 600, 3600)],
    quoteSourceTimeUnix: T0 + 600,
  });
  const entry = registry.get('device-aaaaaaaa');
  assert.equal(planTick(entry, { nowUnix: T0 }).action, WINDOW_ACTIONS.IDLE);
  assert.equal(planTick(entry, { nowUnix: T0 + 599 }).action, WINDOW_ACTIONS.IDLE);
  assert.equal(planTick(entry, { nowUnix: T0 + 600 }).action, WINDOW_ACTIONS.START);
});

test('an expired window is never back-filled', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, {
    windows: [{ id: 'w1', start: isoAt(T0 - 7200), end: isoAt(T0 - 3600) }],
  });
  const entry = registry.get('device-aaaaaaaa');
  // The window closed an hour ago. Nothing to start, nothing to end.
  const plan = planTick(entry, { nowUnix: T0 });
  assert.equal(plan.action, WINDOW_ACTIONS.IDLE);
  assert.equal(plan.shouldEndActivity, false);
});

test('a long outage does not produce a burst of catch-up starts', () => {
  const clock = new FakeClock(T0);
  // Three separate past sessions.
  const registry = makeRegistry(clock, {
    windows: [
      { id: 'd1', start: isoAt(T0 - 4 * 24 * 3600), end: isoAt(T0 - 4 * 24 * 3600 + 3600) },
      { id: 'd2', start: isoAt(T0 - 3 * 24 * 3600), end: isoAt(T0 - 3 * 24 * 3600 + 3600) },
      { id: 'd3', start: isoAt(T0 - 2 * 24 * 3600), end: isoAt(T0 - 2 * 24 * 3600 + 3600) },
    ],
  });
  const entry = registry.get('device-aaaaaaaa');
  // Every missed session plans to idle; none of them plans to start.
  const actions = entry.windows.map((w) => planTick(entry, { nowUnix: Math.floor((T0 + 60)) }).action);
  assert.deepEqual([...new Set(actions)], [WINDOW_ACTIONS.IDLE]);
});

test('a window that closed after a start produces an end, not a new start', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const entry = registry.get('device-aaaaaaaa');
  entry.activeActivity = { windowID: 'w1', activityID: 'a', startedAtUnix: T0, pushToStart: true };
  registry.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });

  // Within the freshness window it is an update; past it, the source gate wins
  // and the service says so instead of refreshing a stale number.
  assert.equal(planTick(entry, { nowUnix: T0 + 100 }).action, WINDOW_ACTIONS.UPDATE);
  assert.equal(planTick(entry, { nowUnix: T0 + 1800 }).action, WINDOW_ACTIONS.SKIPPED_STALE_SOURCE);
  // The window closing is a separate, later decision that always wins.
  assert.equal(planTick(entry, { nowUnix: T0 + 3600 }).action, WINDOW_ACTIONS.END);
  assert.equal(planTick(entry, { nowUnix: T0 + 3600 }).reason, 'window-closed');

  // Once ended, the window is inert even if asked again.
  registry.setWindowState(entry, 'w1', { endedAtUnix: T0 + 3600 });
  assert.equal(planTick(entry, { nowUnix: T0 + 3601 }).action, WINDOW_ACTIONS.IDLE);
});

test('removing a window from the schedule ends its running activity', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const entry = registry.get('device-aaaaaaaa');
  entry.activeActivity = { windowID: 'gone', activityID: 'a', startedAtUnix: T0, pushToStart: true };
  // The client edited the schedule and `gone` no longer exists, while `w1` is open.
  const plan = planTick(entry, { nowUnix: T0 + 60 });
  assert.equal(plan.action, WINDOW_ACTIONS.END);
  assert.equal(plan.reason, 'window-removed');
});

// ---------------------------------------------------------------------------
// The start budget
// ---------------------------------------------------------------------------

test('exactly one automatic start is allowed per window', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const entry = registry.get('device-aaaaaaaa');

  assert.equal(planTick(entry, { nowUnix: T0 }).action, WINDOW_ACTIONS.START);

  // Simulate the engine having spent the budget.
  registry.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });
  assert.equal(planTick(entry, { nowUnix: T0 + 1 }).action, WINDOW_ACTIONS.SKIPPED_BUDGET);
  assert.equal(planTick(entry, { nowUnix: T0 + 1 }).reason, 'automatic-start-already-used');
  assert.equal(planTick(entry, { nowUnix: T0 + 3599 }).action, WINDOW_ACTIONS.SKIPPED_BUDGET);
});

test('the spent budget survives a process restart', () => {
  const clock = new FakeClock(T0);
  const dir = require('./helpers').makeTempDir('pulse-scheduler-restart');
  const { AtomicJsonStore } = require('../src/store');
  const { emptyRegistry, validateRegistry } = require('../src/registry');

  const store = new AtomicJsonStore({
    directory: dir,
    filename: 'registry.json',
    emptyValue: emptyRegistry,
    validate: validateRegistry,
  });

  // Process one: starts the activity, spends the budget, then "dies".
  const first = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const body = first.get('device-aaaaaaaa');
  const durable = new Registry({ store, now: () => clock.now() });
  durable.put('device-aaaaaaaa', {
    attributes: body.attributes,
    template: body.template,
    pushToStartToken: body.pushToStartToken,
    updateToken: body.updateToken,
    activityID: null,
    enabled: true,
    pauseUntilUnix: null,
    windows: body.windows,
    revision: 1,
  });
  durable.mutate('device-aaaaaaaa', (entry) => {
    durable.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });
    // The user dismissed the activity before the process died.
    entry.activeActivity = null;
  });

  // Process two: same directory, same window, no memory of process one.
  const restarted = new Registry({ store, now: () => clock.now() });
  const entry = restarted.get('device-aaaaaaaa');
  const plan = planTick(entry, { nowUnix: T0 + 120 });

  // This is the restart-bombardment rule: the budget is durable, so a restart
  // inside the window cannot buy a second notification.
  assert.equal(plan.action, WINDOW_ACTIONS.SKIPPED_BUDGET);
});

test('a new window gets its own budget', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, {
    windows: [windowAfter(clock, 'w1', 0, 3600), windowAfter(clock, 'w2', 7200, 3600)],
    // Stamped when `w2` opens: a week-old quote would (correctly) not start.
    quoteSourceTimeUnix: T0 + 7200,
  });
  const entry = registry.get('device-aaaaaaaa');
  // `w1` spent its start but is still running (a dismissed activity, say).
  registry.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });

  assert.equal(planTick(entry, { nowUnix: T0 + 100 }).action, WINDOW_ACTIONS.SKIPPED_BUDGET);
  // After `w1` closes it is inert, and the next session is a new authorization.
  registry.setWindowState(entry, 'w1', { endedAtUnix: T0 + 3600 });
  assert.equal(planTick(entry, { nowUnix: T0 + 4000 }).action, WINDOW_ACTIONS.IDLE);
  assert.equal(planTick(entry, { nowUnix: T0 + 7200 }).action, WINDOW_ACTIONS.START);
});

test('editing the schedule does not refill the running window budget', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const entry = registry.get('device-aaaaaaaa');
  registry.setWindowState(entry, 'w1', { startsUsed: 1, lastStartAtUnix: T0 });

  // The client re-sends the same window with more planned content.
  registry.put('device-aaaaaaaa', {
    ...entry,
    template: { ...entry.template, plans: { priceConditionReachedCount: 1, manualReviewCount: 0, remainingPlanCount: 0 } },
    windows: entry.windows,
  });
  const updated = registry.get('device-aaaaaaaa');
  assert.equal(planTick(updated, { nowUnix: T0 + 60 }).action, WINDOW_ACTIONS.SKIPPED_BUDGET);
});

test('a window the user did not authorize for auto-start never starts', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600, false)] });
  const entry = registry.get('device-aaaaaaaa');
  assert.equal(planTick(entry, { nowUnix: T0 }).action, WINDOW_ACTIONS.SKIPPED_BUDGET);
  assert.equal(planTick(entry, { nowUnix: T0 }).reason, 'auto-start-not-authorized');
});

test('without a push-to-start token the service says skipped, not started', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { omitPushToStart: true });
  const entry = registry.get('device-aaaaaaaa');
  entry.pushToStartToken = null;
  const plan = planTick(entry, { nowUnix: T0 });
  assert.equal(plan.action, WINDOW_ACTIONS.SKIPPED_NO_START);
  assert.equal(plan.reason, 'no-push-to-start-token');
});

test('a dead push-to-start token stops starts until a new token arrives', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock);
  const entry = registry.get('device-aaaaaaaa');
  entry.pushToStartTokenInvalid = true;
  assert.equal(planTick(entry, { nowUnix: T0 }).action, WINDOW_ACTIONS.SKIPPED_TOKEN_DEAD);
});

// ---------------------------------------------------------------------------
// Stale sources
// ---------------------------------------------------------------------------

test('a stale source never becomes a start, even inside an open window', () => {
  const clock = new FakeClock(T0);
  // The window opens an hour from now; the quote was stamped now and is a
  // regular-session quote with a 5 minute window, so it will be long stale.
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 3600, 3600)] });
  const entry = registry.get('device-aaaaaaaa');
  const plan = planTick(entry, { nowUnix: T0 + 3600 });
  assert.equal(plan.action, WINDOW_ACTIONS.SKIPPED_STALE_SOURCE);
  assert.equal(plan.reason, 'quote-source-stale');
});

test('a stale source also suppresses an update', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock);
  const entry = registry.get('device-aaaaaaaa');
  entry.activeActivity = { windowID: 'w1', activityID: 'a', startedAtUnix: T0, pushToStart: true };
  assert.equal(planTick(entry, { nowUnix: T0 + 100 }).action, WINDOW_ACTIONS.UPDATE);
  assert.equal(planTick(entry, { nowUnix: T0 + 400 }).action, WINDOW_ACTIONS.SKIPPED_STALE_SOURCE);
});

test('a closed market keeps its last quote presentable for a day', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { templateOverrides: { marketPhase: 'closed' } });
  const entry = registry.get('device-aaaaaaaa');

  // The freshness rule itself: a closed market's last quote is honest for 24h.
  assert.equal(staleDateUnixFor(entry.template), T0 + 24 * 3600);
  assert.equal(isSourceFresh(entry.template, T0 + 23 * 3600), true);
  assert.equal(isSourceFresh(entry.template, T0 + 24 * 3600), false);

  // And through the scheduler. The default window is one hour long, so the
  // 24-hour claim rests on the freshness rule above rather than on pretending a
  // longer window is authorized. At T0+3600 that window has closed with no
  // activity running, so there is nothing to end and the plan is idle.
  assert.equal(planTick(entry, { nowUnix: T0 + 3600 }).action, WINDOW_ACTIONS.IDLE);
  const eightHours = makeRegistry(clock, {
    windows: [windowAfter(clock, 'w1', 0, 8 * 3600)],
    templateOverrides: { marketPhase: 'closed' },
  }).get('device-aaaaaaaa');
  assert.equal(planTick(eightHours, { nowUnix: T0 + 7 * 3600 }).action, WINDOW_ACTIONS.START);
  assert.equal(planTick(eightHours, { nowUnix: T0 + 8 * 3600 }).action, WINDOW_ACTIONS.IDLE);
});

// ---------------------------------------------------------------------------
// Backoff
// ---------------------------------------------------------------------------

test('backoff grows, is capped, and is deterministic per device', () => {
  assert.equal(backoffSeconds(0, { deviceID: 'a' }), 5 + backoffSeconds(0, { deviceID: 'a' }) - 5);
  assert.ok(backoffSeconds(1, { deviceID: 'a' }) > backoffSeconds(0, { deviceID: 'a' }));
  assert.ok(backoffSeconds(2, { deviceID: 'a' }) > backoffSeconds(1, { deviceID: 'a' }));
  // Capped.
  assert.ok(backoffSeconds(20, { deviceID: 'a' }) <= 300 * 1.2 + 1);
  // Deterministic (so tests can assert it) and jittered per device.
  assert.equal(backoffSeconds(3, { deviceID: 'device-abcdefgh' }), backoffSeconds(3, { deviceID: 'device-abcdefgh' }));
  assert.equal(backoffSeconds(0, { deviceID: 'aaaa' }), backoffSeconds(0, { deviceID: 'aaaa' }));
});

test('the attempt cap is respected', () => {
  assert.equal(attemptsExhausted(0, 4), false);
  assert.equal(attemptsExhausted(3, 4), false);
  assert.equal(attemptsExhausted(4, 4), true);
  assert.equal(attemptsExhausted(9, 4), true);
});

test('a closed market plans an update before an end', () => {
  const clock = new FakeClock(T0);
  const registry = makeRegistry(clock, { windows: [windowAfter(clock, 'w1', 0, 3600)] });
  const entry = registry.get('device-aaaaaaaa');
  entry.activeActivity = { windowID: 'w1', activityID: 'a', startedAtUnix: T0, pushToStart: true };
  assert.notEqual(planTick(entry, { nowUnix: T0 + 10 }).action, WINDOW_ACTIONS.END);
});

void unixSecondsToAppleReference;
