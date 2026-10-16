'use strict';

/**
 * Test doubles and fixtures.
 *
 * Everything is in memory: a fake clock, a recording APNs transport, a fake
 * quote source, and a throwaway P-256 key. **No test touches the network, the
 * real APNs hosts, a real credential or the user's home directory.**
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { unixSecondsToAppleReference } = require('../src/util');

// ---------------------------------------------------------------------------
// Fake clock
// ---------------------------------------------------------------------------

/** A clock the test moves by hand. Nothing in the service reads `Date.now()`. */
class FakeClock {
  constructor(startUnixSeconds = 1_700_000_000) {
    this.currentMs = startUnixSeconds * 1000;
  }

  now() {
    return this.currentMs;
  }

  nowUnix() {
    return Math.floor(this.currentMs / 1000);
  }

  advanceSeconds(seconds) {
    this.currentMs += seconds * 1000;
    return this;
  }

  setUnix(seconds) {
    this.currentMs = seconds * 1000;
    return this;
  }
}

// ---------------------------------------------------------------------------
// APNs transport double
// ---------------------------------------------------------------------------

/**
 * A transport whose `send` resolves to whatever the test queued, and which
 * records every attempt. Used for 200/410/429/5xx/timeout behaviour without a
 * socket.
 */
class FakeApnsTransport {
  constructor({ defaultResult = { outcome: 'accepted', status: 200, apnsId: 'fake-apns-id' } } = {}) {
    this.host = 'fake';
    this.defaultResult = defaultResult;
    this.queue = [];
    this.attempts = [];
  }

  /** Queues one result for the next send. */
  enqueue(result) {
    this.queue.push(result);
    return this;
  }

  async send(tokenBytes, apsDictionary, options = {}) {
    const result = this.queue.length > 0 ? this.queue.shift() : this.defaultResult;
    this.attempts.push({
      token: tokenBytes,
      tokenHex: Buffer.isBuffer(tokenBytes) ? tokenBytes.toString('hex') : null,
      body: apsDictionary,
      options,
      result,
      atUnix: null,
    });
    return result;
  }

  reset() {}

  get lastAttempt() {
    return this.attempts[this.attempts.length - 1] ?? null;
  }
}

// ---------------------------------------------------------------------------
// Quote source double
// ---------------------------------------------------------------------------

/** A source that can serve a subset of markets, or refuses everything. */
class FakeQuoteSource {
  constructor({ id = 'fake', markets = [], quotes = {}, failWith = null } = {}) {
    this.id = id;
    this.markets = new Set(markets);
    this.quotes = quotes;
    this.failWith = failWith;
    this.calls = [];
  }

  supportedMarkets() {
    return [...this.markets];
  }

  isRefreshable(symbolKey) {
    const market = symbolKey.includes('/') ? 'CRYPTO' : symbolKey.split('.').pop().toUpperCase();
    return this.markets.has(market);
  }

  async refresh(symbolKey) {
    this.calls.push(symbolKey);
    if (this.failWith) throw this.failWith;
    const quote = this.quotes[symbolKey];
    if (!quote) {
      const { QuoteUnavailableError } = require('../src/quote-source');
      throw new QuoteUnavailableError('source-unavailable', `no fixture for ${symbolKey}`);
    }
    return quote;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/** A toolchain-independent opaque token of the given byte length. */
function fakeToken(byteLength = 32, seed = 0) {
  const buffer = Buffer.alloc(byteLength);
  for (let i = 0; i < byteLength; i += 1) buffer[i] = (i * 31 + seed * 17 + 7) & 0xff;
  return buffer;
}

/**
 * A registration body shaped exactly like the Swift encoder's output.
 *
 * The dates use `appleReferenceSeconds` because that is what Swift's default
 * `JSONEncoder` writes — the tests that matter most here assert the service
 * converts them correctly rather than treating them as UNIX seconds.
 */
function registrationBody({
  symbolKey = '600519.SH',
  quoteSourceTimeUnix,
  marketPhase = 'regular',
  staleDateUnix = null,
  price = 1680.5,
  change = 12.3,
  changePercent = 0.74,
  currencyCode = 'CNY',
  status = 'live',
  windows = [],
  enabled = true,
  pauseUntil = null,
  revision = 1,
  pushToStartTokenBytes = 32,
  updateTokenBytes = 32,
  omitPushToStart = false,
  omitUpdate = false,
  plans = { priceConditionReachedCount: 0, manualReviewCount: 0, remainingPlanCount: 1 },
} = {}) {
  const body = {
    attributes: {
      symbolKey,
      destination: { instrumentDetail: { symbolKey } },
    },
    template: {
      primary: {
        symbolKey,
        displayName: '贵州茅台',
        identityText: symbolKey,
        currencyCode,
        price,
        change,
        changePercent,
        quoteSourceTime: {
          encoding: 'appleReferenceSeconds',
          value: unixSecondsToAppleReference(quoteSourceTimeUnix),
        },
        sourceDelay: null,
        marketPhase,
      },
      plans,
      status,
      staleDate: {
        encoding: 'appleReferenceSeconds',
        value: unixSecondsToAppleReference(staleDateUnix ?? quoteSourceTimeUnix + 300),
      },
      quoteSourceTime: {
        encoding: 'appleReferenceSeconds',
        value: unixSecondsToAppleReference(quoteSourceTimeUnix),
      },
      sessionID: 'sh.2026-10-16.regular',
    },
    enabled,
    revision,
    windows,
  };
  if (pauseUntil) body.pauseUntil = pauseUntil;
  if (!omitPushToStart) {
    body.pushToStartToken = { kind: 'pushToStart', base64: fakeToken(pushToStartTokenBytes).toString('base64') };
  }
  if (!omitUpdate) {
    body.updateToken = { kind: 'update', base64: fakeToken(updateTokenBytes, 1).toString('base64') };
  }
  return body;
}

/** An ISO-8601 instant `offsetSeconds` after the clock's current time. */
function isoAfter(clock, offsetSeconds) {
  return new Date((clock.nowUnix() + offsetSeconds) * 1000).toISOString();
}

/** An ISO-8601 instant at an absolute UNIX second. */
function isoAt(unixSeconds) {
  return new Date(unixSeconds * 1000).toISOString();
}

/** A window object covering `[startOffset, endOffset)` relative to the clock. */
function windowAfter(clock, id, startOffsetSeconds, durationSeconds, autoStart = true) {
  return {
    id,
    start: isoAfter(clock, startOffsetSeconds),
    end: isoAfter(clock, startOffsetSeconds + durationSeconds),
    autoStart,
  };
}

// ---------------------------------------------------------------------------
// Config helpers
// ---------------------------------------------------------------------------

/**
 * A minimal environment for a dry-run service.
 *
 * `PULSE_PUSH_STATE_DIR` always points at a fresh temp directory so no test can
 * touch a real install.
 */
function dryRunEnv(overrides = {}) {
  return {
    PULSE_PUSH_MODE: 'dry-run',
    PULSE_PUSH_PORT: '0',
    PULSE_PUSH_STATE_DIR: makeTempDir('pulse-push-test'),
    ...overrides,
  };
}

/** A complete live-mode environment with a generated throwaway key. */
function liveEnv(overrides = {}) {
  const key = generateTempKeyFile();
  return {
    PULSE_PUSH_MODE: 'live',
    PULSE_PUSH_PORT: '0',
    PULSE_PUSH_STATE_DIR: makeTempDir('pulse-push-test-live'),
    PULSE_PUSH_BEARER_TOKEN: 'test-bearer-token-0123456789abcdefghijklmnop',
    PULSE_PUSH_APNS_KEY_PATH: key.path,
    PULSE_PUSH_APNS_KEY_ID: 'ABCD123456',
    PULSE_PUSH_APNS_TEAM_ID: 'TEAM123456',
    PULSE_PUSH_APNS_TOPIC: 'app.pulse.ios.push-type.liveactivity',
    ...overrides,
    __keyPath: key.path,
  };
}

const tempDirs = [];
const tempKeys = [];

function makeTempDir(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `${prefix}-`));
  tempDirs.push(dir);
  return path.join(dir, 'state');
}

/**
 * Writes a throwaway EC P-256 PKCS#8 key to a temp file.
 *
 * Generated per call and deleted afterwards; the bytes are never written into
 * the repository and never used against a real Apple service.
 */
function generateTempKeyFile() {
  const { privateKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pulse-push-test-key-'));
  const keyPath = path.join(dir, 'AuthKey_TESTONLY.p8');
  fs.writeFileSync(keyPath, pem, { mode: 0o600 });
  tempDirs.push(dir);
  tempKeys.push(keyPath);
  return { path: keyPath, pem, privateKey };
}

function cleanupTempDirs() {
  for (const dir of tempDirs.splice(0)) {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      // Best effort; a leaked temp dir is not a test failure.
    }
  }
  tempKeys.length = 0;
}

module.exports = {
  FakeApnsTransport,
  FakeClock,
  FakeQuoteSource,
  cleanupTempDirs,
  dryRunEnv,
  fakeToken,
  generateTempKeyFile,
  isoAfter,
  isoAt,
  liveEnv,
  makeTempDir,
  registrationBody,
  windowAfter,
};
