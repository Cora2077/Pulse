'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { ConfigError, isLoopbackHost, loadConfig } = require('../src/config');
const {
  APPLE_REFERENCE_DATE_UNIX_SECONDS,
  appleReferenceSecondsToUnix,
  decodeBase64Strict,
  isInsideRoot,
  isOpaqueID,
  logLine,
  parseInstant,
  redactObject,
  safeEqualSecret,
  unixSecondsToAppleReference,
} = require('../src/util');
const { AtomicJsonStore, OWNER_MARKER_CONTENT, OWNER_MARKER_NAME, StoreError } = require('../src/store');
const { cleanupTempDirs, dryRunEnv, liveEnv, makeTempDir } = require('./helpers');

test.after(() => cleanupTempDirs());

// ---------------------------------------------------------------------------
// Config: the security defaults live here
// ---------------------------------------------------------------------------

test('defaults to dry-run with no environment at all', () => {
  const config = loadConfig({});
  assert.equal(config.mode, 'dry-run');
  assert.equal(config.isLive, false);
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.liveReady, false);
  assert.equal(config.authRequired, true);
  // No credentials at all -> unconfigured, and the reason is listed.
  assert.ok(config.missingLiveRequirements.includes('PULSE_PUSH_BEARER_TOKEN'));
  assert.ok(config.missingLiveRequirements.includes('PULSE_PUSH_APNS_KEY_PATH'));
});

test('live mode without credentials is unconfigured, not live', () => {
  const config = loadConfig({ PULSE_PUSH_MODE: 'live' });
  assert.equal(config.mode, 'live');
  assert.equal(config.liveReady, false);
  assert.ok(config.missingLiveRequirements.length > 0);
});

test('live mode requires a long bearer token', () => {
  const env = liveEnv();
  env.PULSE_PUSH_BEARER_TOKEN = 'short';
  const config = loadConfig(env);
  assert.equal(config.liveReady, false);
  assert.ok(config.missingLiveRequirements.includes('PULSE_PUSH_BEARER_TOKEN-too-short'));
});

test('live mode requires a readable key file', () => {
  const env = liveEnv();
  env.PULSE_PUSH_APNS_KEY_PATH = path.join(os.tmpdir(), 'definitely-not-here.p8');
  const config = loadConfig(env);
  assert.equal(config.liveReady, false);
  assert.ok(config.missingLiveRequirements.includes('PULSE_PUSH_APNS_KEY_PATH-not-readable'));
});

test('a complete live environment becomes ready', () => {
  const config = loadConfig(liveEnv());
  assert.equal(config.liveReady, true);
  assert.equal(config.apnsHost, 'api.sandbox.push.apple.com');
});

test('production environment selects the production host and nothing else', () => {
  const config = loadConfig(liveEnv({ PULSE_PUSH_APNS_ENV: 'production' }));
  assert.equal(config.apnsHost, 'api.push.apple.com');
});

test('an unknown APNs environment is refused rather than guessed', () => {
  assert.throws(() => loadConfig({ PULSE_PUSH_APNS_ENV: 'staging' }), ConfigError);
});

test('binding a non-loopback address is refused without the explicit opt-in', () => {
  assert.throws(
    () => loadConfig({ PULSE_PUSH_HOST: '0.0.0.0' }),
    (error) => error instanceof ConfigError && /non-loopback/.test(error.message),
  );
  const allowed = loadConfig({ PULSE_PUSH_HOST: '0.0.0.0', PULSE_PUSH_ALLOW_NON_LOOPBACK: '1' });
  assert.equal(allowed.host, '0.0.0.0');
  assert.equal(allowed.allowNonLoopback, true);
});

test('loopback detection covers the 127/8 range and rejects lookalikes', () => {
  for (const host of ['127.0.0.1', '127.1.2.3', 'localhost', '::1']) {
    assert.equal(isLoopbackHost(host), true, host);
  }
  for (const host of ['0.0.0.0', '10.0.0.1', '172.16.0.1', '192.168.1.1', '1270.0.1', 'example.com']) {
    assert.equal(isLoopbackHost(host), false, host);
  }
});

test('the state directory may not be a filesystem root', () => {
  assert.throws(() => loadConfig({ PULSE_PUSH_STATE_DIR: '/' }), ConfigError);
});

test('an unknown quote source is refused', () => {
  assert.throws(() => loadConfig({ PULSE_PUSH_QUOTE_SOURCE: 'bloomberg' }), ConfigError);
});

test('describe() never includes the bearer token or the key path', () => {
  const env = liveEnv();
  const config = loadConfig(env);
  const described = JSON.stringify(config);
  const { describeConfig } = require('../src/config');
  const text = JSON.stringify(describeConfig(config));
  // `config` itself holds the secret because it is the runtime object; the
  // *description* is what must be safe to print.
  assert.ok(config.bearerToken.length > 0);
  assert.equal(text.includes(env.PULSE_PUSH_BEARER_TOKEN), false);
  assert.equal(text.includes(env.PULSE_PUSH_APNS_KEY_PATH), false);
  assert.ok(text.includes('AuthKey_TESTONLY.p8'));
  assert.ok(described.length > 0); // documented: the object itself is not printed
});

// ---------------------------------------------------------------------------
// util: the date conversion that would otherwise be silent
// ---------------------------------------------------------------------------

test('apple reference seconds convert to UNIX seconds with the 2001 offset', () => {
  // 2001-01-01T00:00:00Z is exactly the offset.
  assert.equal(appleReferenceSecondsToUnix(0), APPLE_REFERENCE_DATE_UNIX_SECONDS);
  assert.equal(APPLE_REFERENCE_DATE_UNIX_SECONDS, 978307200);
  // Round-trip.
  const unix = 1_700_000_000;
  assert.equal(appleReferenceSecondsToUnix(unixSecondsToAppleReference(unix)), unix);
  // The mistake this prevents: treating Swift's value as UNIX seconds would put
  // the quote in 1970.
  assert.ok(appleReferenceSecondsToUnix(unixSecondsToAppleReference(unix)) - unixSecondsToAppleReference(unix) > 30 * 365 * 24 * 3600);
});

test('strict base64 rejects non-canonical and oversized input', () => {
  const good = Buffer.from('hello world').toString('base64');
  assert.equal(decodeBase64Strict(good).ok, true);
  assert.equal(decodeBase64Strict('not base64!!').ok, false);
  assert.equal(decodeBase64Strict('').ok, false);
  assert.equal(decodeBase64Strict(good, { maxBytes: 2 }).ok, false);
  // Buffer.from would silently accept this; strict mode must not.
  assert.equal(decodeBase64Strict('AAAA=====').ok, false);
});

test('opaque ids admit no path traversal characters', () => {
  assert.equal(isOpaqueID('abcdefgh'), true);
  assert.equal(isOpaqueID('A-b_c12345678'), true);
  for (const bad of ['../../../etc/passwd', 'a/b', 'short', '..', 'a.b', '', 'x'.repeat(129), 'has space']) {
    assert.equal(isOpaqueID(bad), false, bad);
  }
});

test('instant parsing requires a real ISO-8601 stamp', () => {
  assert.ok(parseInstant('2026-10-16T09:30:00Z'));
  assert.ok(parseInstant('2026-10-16T09:30:00.500+08:00'));
  for (const bad of ['tomorrow', '2026-10-16', '2026-10-16 09:30:00', '', null, 42]) {
    assert.equal(parseInstant(bad), null, String(bad));
  }
});

test('secret comparison is constant-time-shaped and length-agnostic', () => {
  assert.equal(safeEqualSecret('abc', 'abc'), true);
  assert.equal(safeEqualSecret('abc', 'abd'), false);
  assert.equal(safeEqualSecret('abc', 'abcdef'), false);
  assert.equal(safeEqualSecret('abc', ''), false);
  assert.equal(safeEqualSecret(null, 'abc'), false);
});

test('log lines redact secret-looking keys and long tokens', () => {
  const line = logLine({
    level: 'info',
    event: 'test',
    bearerToken: 'super-secret-value',
    nested: { apnsToken: 'also-secret', status: 200, address: '127.0.0.1:1' },
    opaque: 'A'.repeat(40),
  });
  assert.equal(line.includes('super-secret-value'), false);
  assert.equal(line.includes('also-secret'), false);
  assert.equal(line.includes('A'.repeat(40)), false);
  assert.ok(line.includes('127.0.0.1:1'));
  assert.ok(line.includes('200'));
  assert.equal(line.includes('\n'), false);
});

test('log lines are length-capped', () => {
  const line = logLine({ level: 'info', event: 'x', note: 'a'.repeat(10000) });
  assert.ok(line.length <= 2049);
});

test('redactObject leaves non-secret values alone', () => {
  const out = redactObject({ status: 200, attempt: 3, reason: 'TooManyRequests' });
  assert.deepEqual(out, { status: 200, attempt: 3, reason: 'TooManyRequests' });
});

// ---------------------------------------------------------------------------
// Store: permissions, atomicity, path safety
// ---------------------------------------------------------------------------

function makeStore(dir, overrides = {}) {
  return new AtomicJsonStore({
    directory: dir,
    filename: 'registry.json',
    emptyValue: () => ({ empty: true }),
    validate: (raw) => {
      if (!raw || typeof raw !== 'object') throw new Error('bad');
      return raw;
    },
    ...overrides,
  });
}

test('the store creates its directory with an owner marker and 0600 files', () => {
  const dir = makeTempDir('pulse-store-test');
  const store = makeStore(dir);
  store.write({ hello: 'world' });
  const stat = fs.statSync(store.path);
  assert.equal(stat.mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(path.join(dir, OWNER_MARKER_NAME), 'utf8'), OWNER_MARKER_CONTENT);
  assert.deepEqual(store.read(), { hello: 'world' });
});

test('the store refuses a directory it did not create', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pulse-store-foreign-'));
  fs.writeFileSync(path.join(dir, 'registry.json'), '{"hello":"world"}');
  assert.throws(() => makeStore(dir), (error) => error instanceof StoreError && error.code === 'root-not-owned');
});

test('the store refuses a symlinked state directory', () => {
  const real = makeTempDir('pulse-store-real');
  makeStore(real).write({ ok: true });
  const link = path.join(os.tmpdir(), `pulse-store-link-${Date.now()}`);
  fs.symlinkSync(real, link);
  assert.throws(() => makeStore(link), (error) => error instanceof StoreError && error.code === 'root-symlink');
  fs.unlinkSync(link);
});

test('the store refuses to write through a symlinked target file', () => {
  const dir = makeTempDir('pulse-store-symlink-target');
  const store = makeStore(dir);
  store.write({ first: true });
  const victim = path.join(os.tmpdir(), `pulse-store-victim-${Date.now()}.json`);
  fs.writeFileSync(victim, '{"untouched":true}');
  fs.rmSync(store.path);
  fs.symlinkSync(victim, store.path);
  assert.throws(() => store.write({ second: true }), (error) => error instanceof StoreError && error.code === 'target-symlink');
  assert.equal(fs.readFileSync(victim, 'utf8'), '{"untouched":true}');
  fs.unlinkSync(victim);
});

test('a corrupt or unvalidated document reads as empty rather than partially', () => {
  const dir = makeTempDir('pulse-store-corrupt');
  const store = makeStore(dir);
  store.write({ fine: true });
  fs.writeFileSync(store.path, '{ this is not json');
  assert.deepEqual(store.read(), { empty: true });
  fs.writeFileSync(store.path, '{"not":"valid"}');
  const strict = makeStore(dir, {
    validate: () => { throw new Error('rejected'); },
  });
  assert.deepEqual(strict.read(), { empty: true });
});

test('isInsideRoot rejects escapes and accepts real children', () => {
  const root = makeTempDir('pulse-root-check');
  const store = makeStore(root);
  const child = path.join(root, 'child.json');
  fs.writeFileSync(child, '{}');
  assert.equal(isInsideRoot(root, child), true);
  assert.equal(isInsideRoot(root, root), false);
  const outside = path.join(os.tmpdir(), 'definitely-outside.json');
  fs.writeFileSync(outside, '{}');
  assert.equal(isInsideRoot(root, outside), false);
  fs.unlinkSync(outside);
  void store;
});

test('an atomic write leaves no temp file behind', () => {
  const dir = makeTempDir('pulse-store-atomic');
  const store = makeStore(dir);
  store.write({ a: 1 });
  store.write({ a: 2 });
  const leftovers = fs.readdirSync(dir).filter((name) => name.includes('.tmp'));
  assert.deepEqual(leftovers, []);
  assert.deepEqual(store.read(), { a: 2 });
});

void dryRunEnv;
