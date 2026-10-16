'use strict';

/**
 * Configuration, parsed once from the environment.
 *
 * The security posture is enforced *here* rather than at the call sites, so
 * there is exactly one place to audit:
 *
 *   - the process is dry-run unless `PULSE_PUSH_MODE=live` is set explicitly;
 *   - live mode refuses to start without a long random bearer token AND a
 *     readable APNs key, so "live" can never mean "silently does nothing";
 *   - the listener is 127.0.0.1 unless the operator opts into a non-loopback
 *     bind *and* says so in a second variable, and it still needs a token;
 *   - there is no TLS in-process: the documented deployment puts the service
 *     behind an operator-managed reverse proxy.
 *
 * Nothing in this file reads a secret into a log line. `describe()` returns a
 * redacted view that is safe to print at startup.
 */

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const MIN_BEARER_TOKEN_LENGTH = 32;

/** Registered, allow-listed public data-source identifiers. */
const QUOTE_SOURCES = new Set(['client', 'none', 'public']);

/**
 * Markets this build can serve a *refreshable* quote for.
 *
 * Empty on purpose, and it must stay that way. This constant is the global claim
 * "the client can refresh a market without uploading its own snapshot", and the
 * client cannot: `ClientSnapshotQuoteSource.supportedMarkets()` derives from
 * this set, so populating it would make a phone that never uploads a fresh quote
 * look refreshable.
 *
 * The `public` source does have real coverage, but only when the operator opts
 * in with `PULSE_PUSH_QUOTE_SOURCE=public`. That coverage is reported by the
 * source *instance* (`PublicQuoteSource.supportedMarkets()`, derived from the
 * adapters in `src/sources/`) and by `PUBLIC_QUOTE_MARKETS` — never by this set.
 * Adding a provider means adding an adapter with tests — see docs/QUOTE_SOURCES.md.
 */
const REFRESHABLE_MARKETS = new Set();

/**
 * Markets the explicitly-selected `public` quote source can serve.
 *
 * Static because the set of wired adapters is static; kept in step with
 * `src/sources/index.js`, which derives its runtime answer from the adapters. A
 * market is listed here only when an adapter exists that can build a request for
 * a symbol of that market *and* parse a timestamp for it — never because the
 * market is merely interesting.
 */
const PUBLIC_QUOTE_MARKETS = Object.freeze(['KR', 'SH', 'SZ', 'HK', 'US']);

const DEFAULTS = {
  host: '127.0.0.1',
  port: 8787,
  storageSubdir: 'pulse-push-bridge',
  updateIntervalSeconds: 60,
  maxWindowsPerRegistration: 8,
  registrationTTLSeconds: 90 * 24 * 60 * 60,
  apnsEnvironment: 'sandbox',
  quoteSource: 'client',
};
class ConfigError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'ConfigError';
    this.details = details;
  }
}

function readString(env, key) {
  const raw = env[key];
  if (raw === undefined || raw === null) return undefined;
  const trimmed = String(raw).trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function readInteger(env, key, fallback, { min, max }) {
  const raw = readString(env, key);
  if (raw === undefined) return fallback;
  if (!/^-?\d+$/.test(raw)) {
    throw new ConfigError(`${key} must be an integer`, { key });
  }
  const value = Number.parseInt(raw, 10);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new ConfigError(`${key} is out of range`, { key, min, max });
  }
  return value;
}

function readBoolean(env, key, fallback) {
  const raw = readString(env, key);
  if (raw === undefined) return fallback;
  if (raw === '1' || raw.toLowerCase() === 'true') return true;
  if (raw === '0' || raw.toLowerCase() === 'false') return false;
  throw new ConfigError(`${key} must be 1/0 or true/false`, { key });
}

/**
 * Resolves the state directory.
 *
 * The service writes only under a directory that carries its own name, so an
 * accidental `PULSE_PUSH_STATE_DIR=/` cannot make it the owner of somebody
 * else's tree. The directory must be absent or an empty/own directory; the
 * store re-checks ownership on every write.
 */
function resolveStateDir(env) {
  const explicit = readString(env, 'PULSE_PUSH_STATE_DIR');
  const base = explicit
    ? path.resolve(explicit)
    : path.join(os.homedir(), '.local', 'state', DEFAULTS.storageSubdir);
  if (base === path.parse(base).root) {
    throw new ConfigError('PULSE_PUSH_STATE_DIR must not be a filesystem root', { key: 'PULSE_PUSH_STATE_DIR' });
  }
  return base;
}

function loadConfig(env = process.env) {
  const mode = readString(env, 'PULSE_PUSH_MODE') ?? 'dry-run';
  if (mode !== 'dry-run' && mode !== 'live') {
    throw new ConfigError('PULSE_PUSH_MODE must be "dry-run" or "live"', { key: 'PULSE_PUSH_MODE' });
  }

  const host = readString(env, 'PULSE_PUSH_HOST') ?? DEFAULTS.host;
  const allowNonLoopback = readBoolean(env, 'PULSE_PUSH_ALLOW_NON_LOOPBACK', false);
  if (!allowNonLoopback && !isLoopbackHost(host)) {
    throw new ConfigError(
      'Refusing to bind a non-loopback address without PULSE_PUSH_ALLOW_NON_LOOPBACK=1',
      { key: 'PULSE_PUSH_HOST', host },
    );
  }

  // Port 0 is allowed and means "an ephemeral port", which is what tests use;
  // the bound port is reported on startup so it is never a mystery.
  const port = readInteger(env, 'PULSE_PUSH_PORT', DEFAULTS.port, { min: 0, max: 65535 });
  const stateDir = resolveStateDir(env);

  const quoteSource = readString(env, 'PULSE_PUSH_QUOTE_SOURCE') ?? DEFAULTS.quoteSource;
  if (!QUOTE_SOURCES.has(quoteSource)) {
    throw new ConfigError('PULSE_PUSH_QUOTE_SOURCE is not a registered source', {
      key: 'PULSE_PUSH_QUOTE_SOURCE',
      known: [...QUOTE_SOURCES],
    });
  }

  const apnsEnvironment = readString(env, 'PULSE_PUSH_APNS_ENV') ?? DEFAULTS.apnsEnvironment;
  if (apnsEnvironment !== 'sandbox' && apnsEnvironment !== 'production') {
    throw new ConfigError('PULSE_PUSH_APNS_ENV must be "sandbox" or "production"', {
      key: 'PULSE_PUSH_APNS_ENV',
    });
  }

  const bearerToken = readString(env, 'PULSE_PUSH_BEARER_TOKEN');
  const apnsKeyPath = readString(env, 'PULSE_PUSH_APNS_KEY_PATH');
  const apnsKeyId = readString(env, 'PULSE_PUSH_APNS_KEY_ID');
  const apnsTeamId = readString(env, 'PULSE_PUSH_APNS_TEAM_ID');
  const apnsTopic = readString(env, 'PULSE_PUSH_APNS_TOPIC');

  const config = {
    mode,
    isLive: mode === 'live',
    host,
    port,
    allowNonLoopback,
    stateDir,
    updateIntervalSeconds: readInteger(env, 'PULSE_PUSH_UPDATE_INTERVAL_SECONDS', DEFAULTS.updateIntervalSeconds, {
      min: 15,
      max: 3600,
    }),
    maxWindowsPerRegistration: readInteger(
      env,
      'PULSE_PUSH_MAX_WINDOWS_PER_REGISTRATION',
      DEFAULTS.maxWindowsPerRegistration,
      { min: 1, max: 64 },
    ),
    registrationTTLSeconds: DEFAULTS.registrationTTLSeconds,
    apnsEnvironment,
    quoteSource,
    bearerToken,
    apnsKeyPath,
    apnsKeyId,
    apnsTeamId,
    apnsTopic,
  };

  config.apnsHost = apnsEnvironment === 'production'
    ? 'api.push.apple.com'
    : 'api.sandbox.push.apple.com';

  // --- live-mode readiness -------------------------------------------------
  // Computed, never thrown here: a missing credential is an ordinary runtime
  // state that the API reports as `unconfigured`, not a crash.
  const missing = [];
  if (!bearerToken) {
    missing.push('PULSE_PUSH_BEARER_TOKEN');
  } else if (bearerToken.length < MIN_BEARER_TOKEN_LENGTH) {
    missing.push('PULSE_PUSH_BEARER_TOKEN-too-short');
  }
  if (!apnsKeyPath) {
    missing.push('PULSE_PUSH_APNS_KEY_PATH');
  } else if (!fs.existsSync(apnsKeyPath)) {
    missing.push('PULSE_PUSH_APNS_KEY_PATH-not-readable');
  }
  for (const [label, value] of [
    ['PULSE_PUSH_APNS_KEY_ID', apnsKeyId],
    ['PULSE_PUSH_APNS_TEAM_ID', apnsTeamId],
    ['PULSE_PUSH_APNS_TOPIC', apnsTopic],
  ]) {
    if (!value) missing.push(label);
  }

  config.missingLiveRequirements = missing;
  config.liveReady = mode === 'live' && missing.length === 0;
  config.authRequired = true; // always, in both modes

  return Object.freeze(config);
}

/** Loopback test that also accepts `localhost`, which Node resolves locally. */
function isLoopbackHost(host) {
  if (host === 'localhost') return true;
  if (host === '::1' || host === '[::1]') return true;
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!ipv4) return false;
  const octets = ipv4.slice(1).map(Number);
  if (octets.some((o) => o > 255)) return false;
  return octets[0] === 127;
}

/**
 * Startup line. Contains no token, no key material and no key path beyond its
 * basename, which is what an operator needs to confirm the right file is used.
 */
function describeConfig(config) {
  return {
    mode: config.mode,
    listen: `${config.host}:${config.port}`,
    nonLoopback: config.allowNonLoopback && !isLoopbackHost(config.host),
    stateDir: config.stateDir,
    apnsEnvironment: config.apnsEnvironment,
    apnsHost: config.apnsHost,
    apnsKeyFile: config.apnsKeyPath ? path.basename(config.apnsKeyPath) : null,
    hasBearerToken: Boolean(config.bearerToken),
    hasApnsKeyId: Boolean(config.apnsKeyId),
    hasApnsTeamId: Boolean(config.apnsTeamId),
    hasApnsTopic: Boolean(config.apnsTopic),
    quoteSource: config.quoteSource,
    liveReady: config.liveReady,
    missingLiveRequirements: config.missingLiveRequirements,
  };
}

module.exports = {
  ConfigError,
  DEFAULTS,
  MIN_BEARER_TOKEN_LENGTH,
  PUBLIC_QUOTE_MARKETS,
  QUOTE_SOURCES,
  REFRESHABLE_MARKETS,
  describeConfig,
  isLoopbackHost,
  loadConfig,
};
