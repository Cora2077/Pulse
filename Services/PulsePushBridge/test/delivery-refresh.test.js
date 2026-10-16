'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { DeliveryEngine } = require('../src/delivery');
const { Registry } = require('../src/registry');
const { validateRegistration } = require('../src/registration');
const { loadConfig } = require('../src/config');
const { FakeClock, FakeApnsTransport, registrationBody, windowAfter, liveEnv, cleanupTempDirs } = require('./helpers');
test.after(cleanupTempDirs);
const T0 = 1700000000;
const ID = 'refresh-test-device';
function setup(refresh) {
  const clock = new FakeClock(T0);
  const registry = new Registry({ now: () => clock.now() });
  const transport = new FakeApnsTransport();
  const config = loadConfig(liveEnv());
  const source = { id: 'public', supportedMarkets: () => ['SH'], isRefreshable: () => true, refresh };
  const engine = new DeliveryEngine({ registry, transport, config, quoteSource: source, now: () => clock.now() });
  const checked = validateRegistration(registrationBody({ quoteSourceTimeUnix: T0 - 10000,
    windows: [windowAfter(clock, 'w1', 0, 3600)] }), { hasUsableTokenAfterWrite: true, nowUnix: T0 });
  assert.equal(checked.ok, true, JSON.stringify(checked));
  registry.put(ID, checked.value);
  return { clock, registry, transport, engine };
}
const quote = () => ({ symbolKey: '600519.SH', price: 1200, change: -10, changePercent: -0.82,
  quoteSourceTimeUnix: T0, sourceDelay: 0, marketPhase: 'regular' });

test('a stale client template is refreshed independently before scheduling a start', async () => {
  const ctx = setup(async () => quote());
  const result = await ctx.engine.tick(ID);
  assert.equal(result.outcome, 'accepted');
  const state = ctx.transport.lastAttempt.body.aps['content-state'];
  assert.equal(state.primary.price, 1200);
  const aps = ctx.transport.lastAttempt.body.aps;
  assert.equal(aps['attributes-type'], 'PulseActivityAttributes');
  assert.deepEqual(aps.attributes, { symbolKey: '600519.SH', destination: { instrumentDetail: { symbolKey: '600519.SH' } } });
  assert.equal(typeof aps.alert.body, 'string');
  assert.equal(aps['input-push-token'], 1);
  assert.equal(state.primary.quoteSourceTime, T0 - 978307200);
  assert.equal(state.plans.syncState, 'pending');
});

test('an old closed-source quote cannot look fresh during an authorized open window', async () => {
  const ctx = setup(async () => ({ ...quote(), quoteSourceTimeUnix: T0 - 10000, marketPhase: 'closed' }));
  const result = await ctx.engine.tick(ID);
  assert.equal(result.reason, 'source-stale-during-authorized-window');
  assert.equal(ctx.transport.attempts.length, 0);
});

test('disabling while the source is in flight rejects the old refresh result', async () => {
  let release, entered;
  const started = new Promise(r => { entered = r; });
  const ctx = setup(async () => { entered(); return new Promise(r => { release = r; }); });
  const task = ctx.engine.tick(ID);
  await started;
  ctx.registry.mutate(ID, e => { e.enabled = false; });
  release(quote());
  assert.equal((await task).reason, 'registration-changed-during-refresh');
  assert.equal(ctx.transport.attempts.length, 0);
});

test('deleting while an APNs start is in flight cannot resurrect the registration', async () => {
  const ctx = setup(async () => quote());
  let release, entered;
  const started = new Promise(r => { entered = r; });
  ctx.transport.send = async () => { entered(); return new Promise(r => { release = r; }); };
  const task = ctx.engine.tick(ID);
  await started;
  ctx.registry.remove(ID);
  release({ outcome: 'accepted', status: 200, apnsId: 'fake' });
  assert.equal((await task).reason, 'registration-changed-during-send');
  assert.equal(ctx.registry.get(ID), null);
});

test('an end never targets a push-to-start token when the activity update token is missing', async () => {
  const ctx = setup(async () => quote());
  await ctx.engine.tick(ID);
  ctx.registry.mutate(ID, e => { e.updateToken = null; e.enabled = false; });
  const result = await ctx.engine.tick(ID);
  assert.equal(result.event, 'end');
  assert.equal(result.outcome, 'skipped');
  assert.equal(ctx.transport.attempts.length, 1);
  assert.equal(ctx.registry.get(ID).activeActivity, null);
});

test('an ambiguous start failure keeps the pre-send budget instead of bombarding after a restart', async () => {
  const ctx = setup(async () => quote());
  ctx.transport.enqueue({ outcome: 'retry', status: 503, retryable: true });
  await ctx.engine.tick(ID);
  assert.equal(ctx.registry.get(ID).bookkeeping.w1.startsUsed, 1);
  ctx.clock.setUnix(T0 + 120);
  const second = await ctx.engine.tick(ID);
  assert.equal(second.reason, 'skipped-budget-spent');
  assert.equal(ctx.transport.attempts.length, 1);
});
