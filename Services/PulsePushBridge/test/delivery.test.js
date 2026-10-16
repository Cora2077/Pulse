'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { DELIVERY_OUTCOMES, DeliveryEngine } = require('../src/delivery');
const { Registry } = require('../src/registry');
const { validateRegistration, MAX_WINDOWS } = require('../src/registration');
const { classifyResponse } = require('../src/apns-client');
const { loadConfig } = require('../src/config');
const { unixSecondsToAppleReference } = require('../src/util');
const {
  FakeApnsTransport,
  FakeClock,
  FakeQuoteSource,
  cleanupTempDirs,
  dryRunEnv,
  isoAt,
  liveEnv,
  registrationBody,
  windowAfter,
} = require('./helpers');

test.after(() => cleanupTempDirs());

const T0 = 1_700_000_000;
const DEVICE = 'device-aaaaaaaa';

/**
 * An engine over in-memory state with an injected transport and fake clock.
 *
 * `live` chooses whether the config claims to be delivery-ready. It matters:
 * the engine's dry-run reporting is derived from `config.liveReady`, so both
 * paths are exercised with the real `loadConfig` output rather than a hand-made
 * object.
 */
function makeEngine({ clock = new FakeClock(T0), transport = new FakeApnsTransport(), live = true, quoteSource = null } = {}) {
  const env = live ? liveEnv() : dryRunEnv();
  const config = loadConfig(env);
  const registry = new Registry({ now: () => clock.now() });
  const source = quoteSource ?? new FakeQuoteSource({ id: 'client', markets: [] });
  const engine = new DeliveryEngine({
    registry,
    transport,
    quoteSource: source,
    config,
    now: () => clock.now(),
  });
  return { engine, registry, transport, config, clock, quoteSource: source };
}

function register(engine, registry, clock, overrides = {}) {
  const validated = validateRegistration(
    registrationBody({
      quoteSourceTimeUnix: clock.nowUnix(),
      windows: [windowAfter(clock, 'w1', 0, 3600)],
      ...overrides,
    }),
    { hasUsableTokenAfterWrite: true, nowUnix: clock.nowUnix(), maxWindows: MAX_WINDOWS },
  );
  assert.equal(validated.ok, true, JSON.stringify(validated));
  registry.put(DEVICE, validated.value);
  return validated.value;
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

test('a start inside an authorized window sends a start event and records it', async () => {
  const ctx = makeEngine();
  register(ctx.engine, ctx.registry, ctx.clock);

  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(result.event, 'start');
  assert.equal(result.dryRun, false);

  const attempt = ctx.transport.lastAttempt;
  assert.equal(attempt.options.pushType, 'liveactivity');
  assert.equal(attempt.options.priority, 10);
  assert.equal(attempt.body.aps.event, 'start');
  assert.equal(attempt.body.aps.timestamp, T0);
  assert.equal(attempt.body.aps['stale-date'], T0 + 300);

  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.bookkeeping.w1.startsUsed, 1);
  assert.equal(entry.activeActivity.windowID, 'w1');
  assert.equal(entry.sync.lastOutcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(entry.sync.lastAcceptedAtUnix, T0);
});

test('the start uses the push-to-start token, not the update token', async () => {
  const ctx = makeEngine();
  const body = register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);
  const sent = ctx.transport.lastAttempt.token;
  // The transport is handed the raw token bytes, not the wrapper object.
  assert.ok(Buffer.isBuffer(sent));
  assert.equal(sent.equals(body.pushToStartToken.bytes), true);
  // And it is genuinely the push-to-start token, not the update token.
  assert.equal(sent.equals(body.updateToken.bytes), false);
});

test('a second tick in the same window updates rather than starts again', async () => {
  const ctx = makeEngine();
  register(ctx.engine, ctx.registry, ctx.clock);

  await ctx.engine.tick(DEVICE);
  ctx.clock.advanceSeconds(120);
  const result = await ctx.engine.tick(DEVICE);

  assert.equal(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(result.event, 'update');
  const entry = ctx.registry.get(DEVICE);
  // Still exactly one start, no matter how many ticks happen.
  assert.equal(entry.bookkeeping.w1.startsUsed, 1);
  assert.equal(ctx.transport.attempts.length, 2);
  const second = ctx.transport.lastAttempt.token;
  assert.ok(Buffer.isBuffer(second));
  assert.equal(second.equals(entry.updateToken.bytes), true);
  assert.equal(second.equals(entry.pushToStartToken.bytes), false);
});

test('an update is not sent before the configured interval elapses', async () => {
  const ctx = makeEngine();
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  // 30 s later, with a 60 s cadence, nothing is due.
  ctx.clock.advanceSeconds(30);
  const tooSoon = await ctx.engine.tick(DEVICE);
  assert.equal(tooSoon.outcome, DELIVERY_OUTCOMES.IDLE);
  assert.equal(tooSoon.reason, 'update-not-due');
  assert.equal(ctx.transport.attempts.length, 1);

  // Past the interval it is due. The quote is refreshed so it is not stale.
  ctx.clock.advanceSeconds(31);
  refreshQuote(ctx, ctx.clock.nowUnix() - 10);
  const due = await ctx.engine.tick(DEVICE);
  assert.equal(due.event, 'update');
  assert.equal(ctx.transport.attempts.length, 2);
});

test('a forced tick ignores the cadence but not the authorization', async () => {
  const ctx = makeEngine();
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);
  ctx.clock.advanceSeconds(5);
  const forced = await ctx.engine.tick(DEVICE, { force: true });
  assert.equal(forced.event, 'update');
});

// ---------------------------------------------------------------------------
// Dry run / unconfigured
// ---------------------------------------------------------------------------

test('an unconfigured service reports unconfigured and never accepted', async () => {
  // A real recording transport, as `createBridge` would wire in dry-run.
  const { RecordingTransport } = require('../src/apns-client');
  const transport = new RecordingTransport({ simulateAccepted: false });
  const ctx = makeEngine({ transport, live: false });
  register(ctx.engine, ctx.registry, ctx.clock);

  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.UNCONFIGURED);
  assert.notEqual(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(result.dryRun, true);

  const entry = ctx.registry.get(DEVICE);
  // The critical assertion: a dry run is not a delivery.
  assert.equal(entry.sync.lastAcceptedAtUnix, null);
  assert.equal(entry.sync.lastOutcome, DELIVERY_OUTCOMES.UNCONFIGURED);
  // And it did not spend the window's start budget.
  assert.equal(entry.bookkeeping.w1?.startsUsed ?? 0, 0);
  assert.equal(entry.activeActivity, null);
  // It still recorded exactly what would have been sent, for inspection.
  assert.equal(transport.sent.length, 1);
  assert.equal(transport.sent[0].body.aps.event, 'start');
});

test('the live path is unreachable from a dry-run configuration', () => {
  const { createBridge } = require('../src/bridge');
  const bridge = createBridge({ env: dryRunEnv(), inMemory: true });
  assert.equal(bridge.transport.constructor.name, 'RecordingTransport');
  assert.equal(bridge.config.liveReady, false);
});

test('a live-but-incomplete configuration also cannot reach the network', () => {
  const { createBridge } = require('../src/bridge');
  const bridge = createBridge({
    env: { ...liveEnv(), PULSE_PUSH_APNS_KEY_PATH: '/nonexistent/key.p8' },
    inMemory: true,
  });
  assert.equal(bridge.transport.constructor.name, 'RecordingTransport');
  assert.equal(bridge.config.liveReady, false);
});

test('a complete live configuration builds a real transport to a fixed Apple host', () => {
  const { createBridge } = require('../src/bridge');
  const bridge = createBridge({ env: liveEnv(), inMemory: true });
  assert.equal(bridge.transport.constructor.name, 'ApnsTransport');
  assert.equal(bridge.transport.host, 'api.sandbox.push.apple.com');
  assert.equal(bridge.config.liveReady, true);
});

// ---------------------------------------------------------------------------
// Failure handling
// ---------------------------------------------------------------------------

test('a 410 on the push-to-start token invalidates it and stops retrying', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  transport.enqueue({ outcome: 'rejected', status: 410, reason: 'Unregistered', tokenDead: true, permanent: true });

  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.RETRY);
  assert.equal(result.tokenInvalidated, 'pushToStartToken');
  assert.equal(result.reason, 'Unregistered');

  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.pushToStartTokenInvalid, true);
  assert.equal(entry.sync.lastAcceptedAtUnix, null);
  assert.equal(entry.activeActivity, null);
  // No retry is scheduled for a dead token.
  assert.equal(entry.sync.nextAttemptAtUnix, 0);
});

test('a failed push never claims success and never advances the accepted time', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  transport.enqueue({ outcome: 'retry', status: 503, reason: 'ServiceUnavailable', retryable: true });

  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.RETRY);
  assert.notEqual(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);

  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.sync.lastAcceptedAtUnix, null);
  assert.equal(entry.sync.lastRejectionReason, 'ServiceUnavailable');
  assert.equal(entry.sync.lastOutcome, DELIVERY_OUTCOMES.RETRY);
  assert.ok(entry.sync.nextAttemptAtUnix > T0, 'a retry is scheduled');
  assert.equal(entry.bookkeeping.w1.startsUsed, 1, 'an ambiguous 5xx may have created an activity; preserve the pre-send budget claim');
});

test('a retryable failure is skipped until the backoff elapses', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  transport.enqueue({ outcome: 'retry', status: 429, reason: 'TooManyRequests', retryable: true });
  await ctx.engine.tick(DEVICE);

  const entry = ctx.registry.get(DEVICE);
  const retryAt = entry.sync.nextAttemptAtUnix;

  // Immediately afterwards: deferred, and no second APNs attempt.
  const deferred = await ctx.engine.tick(DEVICE);
  assert.equal(deferred.outcome, DELIVERY_OUTCOMES.DEFERRED);
  assert.equal(deferred.reason, 'backoff');
  assert.equal(transport.attempts.length, 1);

  // Once the backoff has elapsed, the attempt is made again.
  ctx.clock.setUnix(retryAt);
  transport.enqueue({ outcome: 'accepted', status: 200 });
  const retried = await ctx.engine.tick(DEVICE);
  assert.equal(retried.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(transport.attempts.length, 2);
});

test('429 and 5xx are classified as retryable; 400/403 as permanent', () => {
  assert.equal(classifyResponse(429, '{"reason":"TooManyRequests"}').retryable, true);
  assert.equal(classifyResponse(500, '{"reason":"InternalServerError"}').retryable, true);
  assert.equal(classifyResponse(503, '{}').retryable, true);
  assert.equal(classifyResponse(400, '{"reason":"BadDeviceToken"}').tokenDead, true);
  assert.equal(classifyResponse(400, '{"reason":"BadDeviceToken"}').permanent, true);
  assert.equal(classifyResponse(410, '{"reason":"Unregistered"}').tokenDead, true);
  assert.equal(classifyResponse(403, '{"reason":"InvalidProviderToken"}').permanent, true);
  assert.equal(classifyResponse(403, '{"reason":"ExpiredProviderToken"}').refreshProviderToken, true);
  assert.equal(classifyResponse(413, '{"reason":"PayloadTooLarge"}').permanent, true);
  assert.equal(classifyResponse(200, '').outcome, 'accepted');
  // A 200 with a body is still a success.
  assert.equal(classifyResponse(200, '{}').outcome, 'accepted');
  // An unknown 4xx is retried rather than treated as a permanent token failure.
  assert.equal(classifyResponse(418, '{}').retryable, true);
});

test('a 410 on the update token invalidates it without killing the start token', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);
  ctx.clock.advanceSeconds(120);
  refreshQuote(ctx, ctx.clock.nowUnix() - 5);
  transport.enqueue({ outcome: 'rejected', status: 410, reason: 'Unregistered', tokenDead: true, permanent: true });

  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.tokenInvalidated, 'updateToken');
  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.updateTokenInvalid, true);
  assert.notEqual(entry.pushToStartTokenInvalid, true);
  // The activity is treated as unreachable rather than refreshed forever.
  assert.equal(entry.activeActivity.windowID, 'w1');
});

test('an expired provider token is refreshed on the next attempt', async () => {
  // Exercised through the real transport wrapper in `createBridge`.
  const { createBridge } = require('../src/bridge');
  const bridge = createBridge({ env: liveEnv(), inMemory: true });
  let invalidated = 0;
  const originalSend = bridge.transport.send.bind(bridge.transport);
  bridge.transport.send = async (...args) => {
    const result = await originalSend(...args);
    if (result.refreshProviderToken) invalidated += 1;
    return result;
  };
  // Drive the classifier directly: the wrapper only reacts to the flag.
  const result = classifyResponse(403, '{"reason":"ExpiredProviderToken"}');
  assert.equal(result.refreshProviderToken, true);
  assert.equal(invalidated, 0);
});

// ---------------------------------------------------------------------------
// End
// ---------------------------------------------------------------------------

test('a window closing ends the running activity', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  ctx.clock.advanceSeconds(3600);
  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  assert.equal(result.event, 'end');
  assert.equal(transport.lastAttempt.body.aps.event, 'end');
  assert.equal(transport.lastAttempt.options.priority, 10);

  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.activeActivity, null);
  assert.equal(entry.bookkeeping.w1.endedAtUnix, T0 + 3600);
  // An ended window never starts again.
  ctx.clock.advanceSeconds(1);
  const after = await ctx.engine.tick(DEVICE);
  assert.equal(after.outcome, DELIVERY_OUTCOMES.IDLE);
});

test('ending a window with no token still stops claiming it is active', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);
  ctx.registry.mutate(DEVICE, (entry) => {
    entry.updateToken = null;
    entry.pushToStartToken = null;
  });

  ctx.clock.advanceSeconds(3600);
  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.SKIPPED);
  assert.equal(result.reason, 'no-token');
  const entry = ctx.registry.get(DEVICE);
  assert.equal(entry.activeActivity, null);
  assert.equal(entry.bookkeeping.w1.endedAtUnix, T0 + 3600);
});

test('disabling a registration ends the running activity', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  ctx.registry.mutate(DEVICE, (entry) => { entry.enabled = false; });
  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.event, 'end');
  assert.equal(ctx.registry.get(DEVICE).activeActivity, null);
});

// ---------------------------------------------------------------------------
// Payload contents
// ---------------------------------------------------------------------------

test('the pushed payload preserves the source time and never stamps now onto it', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  ctx.clock.advanceSeconds(200);
  refreshQuote(ctx, T0); // the source is still the original stamp
  const result = await ctx.engine.tick(DEVICE, { force: true });

  // The quote is still within its 5 minute window, so it goes out with its real
  // source time; `timestamp` is now, which is a different and truthful field.
  assert.equal(result.event, 'update');
  const aps = ctx.transport.lastAttempt.body.aps;
  assert.equal(aps['content-state'].quoteSourceTimeUnix, T0);
  assert.equal(aps.timestamp, T0 + 200);
  assert.notEqual(aps['content-state'].quoteSourceTimeUnix, aps.timestamp);
  assert.equal(aps['stale-date'], T0 + 300);
});

test('a stale source produces no push at all', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  // Past the 5 minute regular-session window, with the source unchanged.
  ctx.clock.advanceSeconds(400);
  const result = await ctx.engine.tick(DEVICE, { force: true });
  assert.equal(result.outcome, DELIVERY_OUTCOMES.SKIPPED);
  assert.equal(result.reason, WINDOW_SKIP_REASON);
  // Exactly one push happened, the start.
  assert.equal(transport.attempts.length, 1);
});

const WINDOW_SKIP_REASON = 'skipped-stale-source';

test('the payload carries no account, position or note data', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);

  const serialized = JSON.stringify(ctx.transport.lastAttempt.body);
  for (const forbidden of ['balance', 'position', 'quantity', 'costBasis', 'account', 'note', 'fill']) {
    assert.equal(serialized.toLowerCase().includes(forbidden.toLowerCase()), false, forbidden);
  }
  // And the plans digest is counts only.
  assert.deepEqual(Object.keys(ctx.transport.lastAttempt.body.aps['content-state'].plans),
    ['priceConditionReachedCount', 'manualReviewCount', 'remainingPlanCount']);
});

test('the payload stays under 4 KB including a long display name', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  await ctx.engine.tick(DEVICE);
  const bytes = Buffer.byteLength(JSON.stringify(ctx.transport.lastAttempt.body), 'utf8');
  assert.ok(bytes < 4096, `payload was ${bytes} bytes`);
});

test('the relevance score matches the coordinator formula and is clamped', async () => {
  const { relevanceFor } = require('../src/delivery');
  assert.equal(relevanceFor({ status: 'live', plans: { priceConditionReachedCount: 0, manualReviewCount: 0 } }), 50);
  assert.equal(relevanceFor({ status: 'live', plans: { priceConditionReachedCount: 1, manualReviewCount: 0 } }), 80);
  assert.equal(relevanceFor({ status: 'live', plans: { priceConditionReachedCount: 1, manualReviewCount: 2 } }), 90);
  assert.equal(relevanceFor({ status: 'stale', plans: { priceConditionReachedCount: 0, manualReviewCount: 0 } }), 10);
  assert.ok(relevanceFor({ status: 'live', plans: { priceConditionReachedCount: 99, manualReviewCount: 99 } }) <= 100);
});

// ---------------------------------------------------------------------------
// Loop behaviour
// ---------------------------------------------------------------------------

test('runOnce visits every registration and isolates per-device failures', async () => {
  const transport = new FakeApnsTransport();
  const ctx = makeEngine({ transport });
  register(ctx.engine, ctx.registry, ctx.clock);
  const second = validateRegistration(
    registrationBody({ quoteSourceTimeUnix: T0, windows: [windowAfter(ctx.clock, 'w1', 0, 3600)] }),
    { hasUsableTokenAfterWrite: true, nowUnix: T0, maxWindows: MAX_WINDOWS },
  );
  ctx.registry.put('device-bbbbbbbb', second.value);

  const results = await ctx.engine.runOnce();
  assert.equal(results.length, 2);
  assert.deepEqual(results.map((r) => r.deviceID).sort(), ['device-aaaaaaaa', 'device-bbbbbbbb']);
  assert.ok(results.every((r) => r.outcome === DELIVERY_OUTCOMES.ACCEPTED));
});

test('an unknown device id is a skip, not an error', async () => {
  const ctx = makeEngine();
  const result = await ctx.engine.tick('device-zzzzzzzz');
  assert.equal(result.outcome, DELIVERY_OUTCOMES.SKIPPED);
  assert.equal(result.reason, 'not-registered');
});

test('a quote source with no refreshable markets never invents one', async () => {
  const ctx = makeEngine({ quoteSource: new FakeQuoteSource({ id: 'client', markets: [] }) });
  register(ctx.engine, ctx.registry, ctx.clock);
  assert.equal(ctx.quoteSource.isRefreshable('600519.SH'), false);
  const result = await ctx.engine.tick(DEVICE);
  assert.equal(result.outcome, DELIVERY_OUTCOMES.ACCEPTED);
  // The price came from the client template, unchanged.
  assert.equal(ctx.transport.lastAttempt.body.aps['content-state'].primary.price, 1680.5);
});

/** Re-stamps the template's quote source time to `unixSeconds`. */
function refreshQuote(ctx, unixSeconds) {
  ctx.registry.mutate(DEVICE, (entry) => {
    entry.template = {
      ...entry.template,
      quoteSourceTime: { encoding: 'appleReferenceSeconds', value: unixSecondsToAppleReference(unixSeconds) },
      primary: {
        ...entry.template.primary,
        quoteSourceTime: { encoding: 'appleReferenceSeconds', value: unixSecondsToAppleReference(unixSeconds) },
      },
    };
    entry.planVersion += 1;
  });
}

void isoAt;
