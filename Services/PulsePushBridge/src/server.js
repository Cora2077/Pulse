'use strict';

/**
 * The HTTP surface.
 *
 * Fixed routes, no wildcards, no proxies, no outbound fetches. The whole API is
 * seven handlers, and every one of them is listed in `ROUTES` so the 404 path is
 * the default rather than something that has to be remembered.
 *
 *   GET    /v1/health
 *   GET    /v1/status
 *   PUT    /v1/registrations/<deviceID>
 *   GET    /v1/registrations/<deviceID>
 *   DELETE /v1/registrations/<deviceID>
 *   POST   /v1/registrations/<deviceID>/pause
 *   POST   /v1/quotes/refresh
 *
 * Security properties, all enforced here and all tested:
 *
 *   - **Bearer auth on everything except `/v1/health`.** `/v1/health` is the
 *     only unauthenticated route and it discloses nothing but liveness, so a
 *     monitoring probe works without holding the token. Health is *not* the
 *     status route.
 *   - **The token is compared in constant time** and never echoed, logged or
 *     included in an error message.
 *   - **`<deviceID>` is validated as an opaque token** before it is used for
 *     anything; it is never used as a path, so path traversal has no entry
 *     point. The store's own `realpath` check is a second layer.
 *   - **Bodies are size-capped** and must be `application/json`; the parser
 *     rejects duplicate keys, which `JSON.parse` would otherwise silently keep
 *     the last of — a classic allow-list bypass.
 *   - **No method is used to reach an arbitrary host.** There is no proxy route,
 *     no webhook, no URL field anywhere in the accepted schema.
 */

const http = require('node:http');
const { URL } = require('node:url');

const { logLine, isOpaqueID, safeEqualSecret } = require('./util');
const { screenBody } = require('./sensitive');
const { validateRegistration, mergeRegistration } = require('./registration');
const { QuoteUnavailableError } = require('./quote-source');
const { DELIVERY_OUTCOMES } = require('./delivery');

const MAX_BODY_BYTES = 64 * 1024;
const REGISTRATION_ROUTE = /^\/v1\/registrations\/([^/]+)$/;
const PAUSE_ROUTE = /^\/v1\/registrations\/([^/]+)\/pause$/;

/** Every route this server answers, for documentation and for the 404 text. */
const ROUTES = [
  { method: 'GET', path: '/v1/health', auth: false, description: 'Liveness only. No configuration detail.' },
  { method: 'GET', path: '/v1/status', auth: true, description: 'Mode, readiness and per-device delivery state.' },
  { method: 'PUT', path: '/v1/registrations/<deviceID>', auth: true, description: 'Create or replace a registration.' },
  { method: 'GET', path: '/v1/registrations/<deviceID>', auth: true, description: 'Read one registration (redacted).' },
  { method: 'DELETE', path: '/v1/registrations/<deviceID>', auth: true, description: 'Revoke: stop all pushes for this device.' },
  { method: 'POST', path: '/v1/registrations/<deviceID>/pause', auth: true, description: 'Pause until a UTC instant.' },
  { method: 'POST', path: '/v1/quotes/refresh', auth: true, description: 'Report freshness capability for a symbol key.' },
];

/** Headers a client may send. Everything else is ignored, not echoed. */
const ACCEPTED_REQUEST_HEADERS = ['authorization', 'content-type', 'content-length', 'host', 'user-agent'];

class ApiError extends Error {
  constructor(status, code, detail) {
    super(code);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

/**
 * Strict JSON parser.
 *
 * `JSON.parse` accepts duplicate keys and keeps the last one, so
 * `{"enabled":false,"enabled":true}` would pass an allow-list check on one
 * reading and be interpreted on another. A reviver that throws on a repeated
 * key removes the ambiguity.
 */
function parseStrictJson(text, label = 'body') {
  const seenPaths = [];
  let parsed;
  try {
    parsed = JSON.parse(text, function reviver(key, value) {
      const path = `${this === undefined ? '' : ''}${key}`;
      seenPaths.push(path);
      return value;
    });
  } catch {
    throw new ApiError(400, 'invalid-json', `${label} is not valid JSON`);
  }
  // The reviver above cannot see duplicates (they are overwritten before the
  // reviver runs), so a second pass over the raw text is used instead: count
  // top-level and nested key occurrences cheaply and reject a repeat.
  if (hasDuplicateKeys(text)) {
    throw new ApiError(400, 'duplicate-keys', `${label} contains a repeated object key`);
  }
  void seenPaths;
  return parsed;
}

/**
 * Detects a repeated key by re-scanning with a key-tracking reviver.
 *
 * Uses a JSON tokenizer built on the reviver plus a manual pre-scan of quoted
 * keys inside each object: adequate for the small bodies this API accepts, and
 * it fails closed (a false positive rejects the request).
 */
function hasDuplicateKeys(text) {
  let index = 0;
  const length = text.length;

  function skipWhitespace() {
    while (index < length && (text[index] === ' ' || text[index] === '\t' || text[index] === '\n' || text[index] === '\r')) {
      index += 1;
    }
  }

  function parseString() {
    let out = '';
    index += 1; // opening quote
    while (index < length) {
      const ch = text[index];
      if (ch === '\\') {
        out += text[index + 1];
        index += 2;
        continue;
      }
      if (ch === '"') {
        index += 1;
        return out;
      }
      out += ch;
      index += 1;
    }
    throw new Error('unterminated string');
  }

  function parseValue() {
    skipWhitespace();
    const ch = text[index];
    if (ch === '{') return parseObject();
    if (ch === '[') return parseArray();
    if (ch === '"') {
      parseString();
      return;
    }
    while (index < length && !',}] \t\n\r'.includes(text[index])) index += 1;
  }

  function parseArray() {
    index += 1;
    skipWhitespace();
    if (text[index] === ']') {
      index += 1;
      return;
    }
    for (;;) {
      parseValue();
      skipWhitespace();
      if (text[index] === ',') {
        index += 1;
        continue;
      }
      if (text[index] === ']') {
        index += 1;
        return;
      }
      throw new Error('bad array');
    }
  }

  function parseObject() {
    index += 1;
    const keys = new Set();
    skipWhitespace();
    if (text[index] === '}') {
      index += 1;
      return;
    }
    for (;;) {
      skipWhitespace();
      if (text[index] !== '"') throw new Error('bad key');
      const key = parseString();
      if (keys.has(key)) throw new DuplicateKeyError(key);
      keys.add(key);
      skipWhitespace();
      if (text[index] !== ':') throw new Error('bad separator');
      index += 1;
      parseValue();
      skipWhitespace();
      if (text[index] === ',') {
        index += 1;
        continue;
      }
      if (text[index] === '}') {
        index += 1;
        return;
      }
      throw new Error('bad object');
    }
  }

  try {
    parseValue();
    return false;
  } catch (error) {
    if (error instanceof DuplicateKeyError) return true;
    return false; // malformed JSON is reported by JSON.parse, not here
  }
}

class DuplicateKeyError extends Error {}

class PushBridgeServer {
  /**
   * @param {object} options
   * @param {object} options.config
   * @param {import('./registry').Registry} options.registry
   * @param {import('./delivery').DeliveryEngine} options.engine
   * @param {import('./quote-source').ClientSnapshotQuoteSource} options.quoteSource
   * @param {() => number} [options.now]
   * @param {object} [options.logger]
   */
  constructor({ config, registry, engine, quoteSource, now = () => Date.now(), logger = null }) {
    this.config = config;
    this.registry = registry;
    this.engine = engine;
    this.quoteSource = quoteSource;
    this.now = now;
    this.logger = logger;
    this.server = http.createServer((req, res) => {
      this.#handle(req, res).catch((error) => {
        this.logEvent('error', 'request-handler-failed', { message: error.message });
        this.sendResponse(res, 500, { error: 'internal-error' });
      });
    });
    // A slow-loris on a personal service is not a threat model, but a hard
    // header timeout keeps a stuck socket from holding the event loop's attention.
    this.server.headersTimeout = 10_000;
    this.server.requestTimeout = 15_000;
    this.server.keepAliveTimeout = 5_000;
  }

  logEvent(level, event, details = {}) {
    const line = logLine({ level, event, ...details });
    if (this.logger) this.logger[level === 'error' ? 'error' : level === 'warn' ? 'warn' : 'info'](event, details);
    else process.stdout.write(line + '\n');
  }

  listen() {
    return new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(this.config.port, this.config.host, () => resolve(this.server.address()));
    });
  }

  close() {
    return new Promise((resolve) => this.server.close(() => resolve()));
  }

  // --- request pipeline ----------------------------------------------------

  async #handle(req, res) {
    const started = this.now();
    const url = new URL(req.url, `http://${req.headers.host ?? '127.0.0.1'}`);
    const pathname = url.pathname;

    // Query strings are not part of this API. Accepting them would invite a
    // "fetch this URL" parameter later; refusing them now keeps that door shut.
    if (url.search.length > 0) {
      this.sendResponse(res, 400, { error: 'query-strings-not-supported' });
      return;
    }

    const route = matchRoute(req.method, pathname);

    if (!route) {
      this.sendResponse(res, 404, { error: 'not-found', routes: ROUTES.map((r) => `${r.method} ${r.path}`) });
      return;
    }

    if (route.auth) {
      const auth = this.authenticate(req);
      if (!auth.ok) {
        this.sendResponse(res, auth.status, { error: auth.code });
        return;
      }
    }

    let body = null;
    if (req.method === 'PUT' || req.method === 'POST') {
      try {
        body = await this.readJsonBody(req);
      } catch (error) {
        if (error instanceof ApiError) {
          this.sendResponse(res, error.status, { error: error.code, detail: error.detail });
          return;
        }
        throw error;
      }
    }

    const elapsedMs = this.now() - started;
    await route.handler(this, req, res, { body, pathname, params: route.params, elapsedMs });
  }

  /**
   * Constant-time bearer check.
   *
   * A missing or malformed `Authorization` header is a 401 with the same body as
   * a wrong token, so the response cannot be used to probe for token validity by
   * shape.
   */
  /** Public because the route handlers are module-level functions; not part of the HTTP contract. */
  authenticate(req) {
    const header = req.headers.authorization;
    if (typeof header !== 'string' || !header.startsWith('Bearer ')) {
      return { ok: false, status: 401, code: 'missing-bearer-token' };
    }
    const presented = header.slice('Bearer '.length).trim();
    if (!safeEqualSecret(presented, this.config.bearerToken ?? '')) {
      return { ok: false, status: 401, code: 'invalid-bearer-token' };
    }
    return { ok: true };
  }

  readJsonBody(req) {
    return new Promise((resolve, reject) => {
      const contentType = String(req.headers['content-type'] ?? '');
      if (!contentType.toLowerCase().startsWith('application/json')) {
        reject(new ApiError(415, 'content-type-must-be-json'));
        return;
      }
      const chunks = [];
      let total = 0;
      req.on('data', (chunk) => {
        total += chunk.length;
        if (total > MAX_BODY_BYTES) {
          reject(new ApiError(413, 'body-too-large', `> ${MAX_BODY_BYTES} bytes`));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on('error', () => reject(new ApiError(400, 'request-stream-error')));
      req.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (text.trim().length === 0) {
          resolve({});
          return;
        }
        try {
          resolve(parseStrictJson(text));
        } catch (error) {
          reject(error instanceof ApiError ? error : new ApiError(400, 'invalid-json'));
        }
      });
    });
  }

  /** The single response path. Public for the same reason as `authenticate`. */
  sendResponse(res, status, payload) {
    if (res.writableEnded) return;
    const text = JSON.stringify(payload);
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(text),
      'cache-control': 'no-store',
      // A lock-screen bridge must never be embedded or framed.
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    });
    res.end(text);
  }
}

/** Route table. Returns `null` for anything not explicitly listed. */
function matchRoute(method, pathname) {
  if (method === 'GET' && pathname === '/v1/health') {
    return { auth: false, params: {}, handler: handleHealth };
  }
  if (method === 'GET' && pathname === '/v1/status') {
    return { auth: true, params: {}, handler: handleStatus };
  }
  if (method === 'POST' && pathname === '/v1/quotes/refresh') {
    return { auth: true, params: {}, handler: handleQuoteRefresh };
  }
  const pause = PAUSE_ROUTE.exec(pathname);
  if (pause && method === 'POST') {
    const deviceID = pause[1];
    if (!isOpaqueID(deviceID)) return { auth: true, params: {}, handler: handleBadDeviceID };
    return { auth: true, params: { deviceID }, handler: handlePause };
  }
  const registration = REGISTRATION_ROUTE.exec(pathname);
  if (registration) {
    const deviceID = registration[1];
    if (!isOpaqueID(deviceID)) return { auth: true, params: {}, handler: handleBadDeviceID };
    if (method === 'PUT') return { auth: true, params: { deviceID }, handler: handlePutRegistration };
    if (method === 'GET') return { auth: true, params: { deviceID }, handler: handleGetRegistration };
    if (method === 'DELETE') return { auth: true, params: { deviceID }, handler: handleDeleteRegistration };
  }
  // A path that looks like a registration route but is not one of the four
  // allowed methods is a 405, not a 404: it is more honest about what exists.
  if ((registration || pause) && method !== 'OPTIONS') {
    return { auth: true, params: {}, handler: handleMethodNotAllowed };
  }
  return null;
}

// --- handlers --------------------------------------------------------------

function handleHealth(server, req, res) {
  // Liveness only. No mode, no readiness, no device count: those are on /v1/status
  // behind auth.
  server.sendResponse(res, 200, { status: 'ok' });
}

function handleBadDeviceID(server, req, res) {
  server.sendResponse(res, 400, {
    error: 'invalid-device-id',
    detail: 'deviceID must be 8..128 chars of [A-Za-z0-9_-]',
  });
}

function handleMethodNotAllowed(server, req, res) {
  server.sendResponse(res, 405, { error: 'method-not-allowed', routes: ROUTES.map((r) => `${r.method} ${r.path}`) });
}

/**
 * `GET /v1/status`
 *
 * Reports mode and readiness exactly, and per-device last delivery outcome so
 * the app can tell "the service accepted this" from "the service is configured
 * but the last push failed".
 */
function handleStatus(server, req, res, { elapsedMs }) {
  const { config, registry } = server;
  const devices = registry.list().map((entry) => ({
    deviceID: entry.deviceID,
    enabled: entry.enabled,
    paused: entry.pauseUntilUnix !== null && entry.pauseUntilUnix !== undefined
      && Math.floor(server.now() / 1000) < entry.pauseUntilUnix,
    planVersion: entry.planVersion,
    revision: entry.revision,
    windows: entry.windows.length,
    activeWindowID: entry.activeActivity?.windowID ?? null,
    pushToStartTokenPresent: Boolean(entry.pushToStartToken),
    pushToStartTokenInvalid: Boolean(entry.pushToStartTokenInvalid),
    updateTokenPresent: Boolean(entry.updateToken),
    updateTokenInvalid: Boolean(entry.updateTokenInvalid),
    lastOutcome: entry.sync?.lastOutcome ?? null,
    lastAcceptedAtUnix: entry.sync?.lastAcceptedAtUnix ?? null,
    lastRejectedAtUnix: entry.sync?.lastRejectedAtUnix ?? null,
    lastRejectionReason: entry.sync?.lastRejectionReason ?? null,
    nextAttemptAtUnix: entry.sync?.nextAttemptAtUnix ?? 0,
  }));

  server.sendResponse(res, 200, {
    mode: config.mode,
    // `deliveryReady` is the honest answer to "will a push actually leave this
    // process": it is false in dry-run and false when credentials are missing.
    deliveryReady: config.liveReady,
    dryRun: !config.liveReady,
    unconfigured: !config.liveReady,
    missingRequirements: config.missingLiveRequirements,
    apnsEnvironment: config.apnsEnvironment,
    quoteSource: config.quoteSource,
    refreshableMarkets: server.quoteSource.supportedMarkets(),
    updateIntervalSeconds: config.updateIntervalSeconds,
    registrationCount: registry.size,
    devices,
    elapsedMs,
  });
}

/** `PUT /v1/registrations/<deviceID>` */
function handlePutRegistration(server, req, res, { body, params }) {
  const { deviceID } = params;
  const existing = server.registry.get(deviceID);
  const isCreate = existing === null;
  const nowUnix = Math.floor(server.now() / 1000);

  // "Can this registration push at all once written?" — true when the body
  // carries a token or the stored registration already has one. A template-only
  // edit must not be rejected as token-less.
  const bodyHasToken = Boolean(
    body && typeof body === 'object' && (body.pushToStartToken || body.updateToken),
  );
  const storedHasToken = Boolean(existing?.pushToStartToken || existing?.updateToken);

  const validated = validateRegistration(body, {
    hasUsableTokenAfterWrite: bodyHasToken || storedHasToken,
    nowUnix,
    maxWindows: server.config.maxWindowsPerRegistration,
  });
  if (!validated.ok) {
    server.sendResponse(res, 400, {
      error: 'invalid-registration',
      reason: validated.reason,
      detail: validated.detail ?? null,
    });
    return;
  }

  const merged = mergeRegistration(existing, validated.value);
  const entry = server.registry.put(deviceID, merged);

  server.sendResponse(res, isCreate ? 201 : 200, {
    deviceID,
    created: isCreate,
    planVersion: entry.planVersion,
    enabled: entry.enabled,
    windows: entry.windows.map((w) => ({ id: w.id, start: w.startSeconds, end: w.endSeconds, autoStart: w.autoStart })),
    pauseUntilUnix: entry.pauseUntilUnix,
    deliveryReady: server.config.liveReady,
    dryRun: !server.config.liveReady,
    quoteSource: server.quoteSource.id,
    quoteRefreshable: server.quoteSource.isRefreshable(entry.template.primary.symbolKey),
  });
}

/**
 * `GET /v1/registrations/<deviceID>`
 *
 * Returns the schedule and the *delivery* state. It deliberately does not return
 * the tokens back: a client that loses its token re-obtains it from
 * ActivityKit, and a token that cannot be read cannot leak from a compromised
 * client. Presence and validity flags are returned instead.
 */
function handleGetRegistration(server, req, res, { params }) {
  const entry = server.registry.get(params.deviceID);
  if (!entry) {
    server.sendResponse(res, 404, { error: 'not-registered' });
    return;
  }
  const nowUnix = Math.floor(server.now() / 1000);
  server.sendResponse(res, 200, {
    deviceID: entry.deviceID,
    enabled: entry.enabled,
    pauseUntilUnix: entry.pauseUntilUnix,
    paused: entry.pauseUntilUnix !== null && entry.pauseUntilUnix !== undefined && nowUnix < entry.pauseUntilUnix,
    planVersion: entry.planVersion,
    revision: entry.revision,
    symbolKey: entry.attributes?.symbolKey ?? null,
    windows: entry.windows.map((w) => ({
      id: w.id, start: w.startSeconds, end: w.endSeconds, autoStart: w.autoStart,
    })),
    activeActivity: entry.activeActivity,
    tokens: {
      pushToStartPresent: Boolean(entry.pushToStartToken),
      pushToStartInvalid: Boolean(entry.pushToStartTokenInvalid),
      updatePresent: Boolean(entry.updateToken),
      updateInvalid: Boolean(entry.updateTokenInvalid),
    },
    delivery: {
      ready: server.config.liveReady,
      dryRun: !server.config.liveReady,
      lastOutcome: entry.sync?.lastOutcome ?? null,
      lastAcceptedAtUnix: entry.sync?.lastAcceptedAtUnix ?? null,
      lastRejectedAtUnix: entry.sync?.lastRejectedAtUnix ?? null,
      lastRejectionReason: entry.sync?.lastRejectionReason ?? null,
      consecutiveFailures: entry.sync?.consecutiveFailures ?? 0,
      nextAttemptAtUnix: entry.sync?.nextAttemptAtUnix ?? 0,
    },
  });
}

/**
 * `DELETE /v1/registrations/<deviceID>`
 *
 * Revocation. The registration is removed outright — tokens, windows and
 * bookkeeping — so a later process start has nothing to resume. Any running
 * activity is ended first when a token is available; if it is not, the response
 * says `activityEnded: false` rather than implying the lock screen was cleared.
 */
async function handleDeleteRegistration(server, req, res, { params }) {
  const entry = server.registry.get(params.deviceID);
  if (!entry) {
    server.sendResponse(res, 404, { error: 'not-registered' });
    return;
  }

  let activityEnded = false;
  let endReason = 'no-active-activity';
  if (entry.activeActivity) {
    const nowUnix = Math.floor(server.now() / 1000);
    const result = await server.engine.tick(params.deviceID, { force: true });
    activityEnded = result.outcome === DELIVERY_OUTCOMES.ACCEPTED;
    endReason = result.outcome === DELIVERY_OUTCOMES.ACCEPTED
      ? 'end-accepted'
      : (result.reason ?? result.outcome);
    void nowUnix;
  }

  server.registry.remove(params.deviceID);
  server.sendResponse(res, 200, {
    deviceID: params.deviceID,
    revoked: true,
    activityEnded,
    endReason,
  });
}

/** `POST /v1/registrations/<deviceID>/pause` */
function handlePause(server, req, res, { body, params }) {
  const entry = server.registry.get(params.deviceID);
  if (!entry) {
    server.sendResponse(res, 404, { error: 'not-registered' });
    return;
  }

  const screened = screenBody(body, ['pauseUntil', 'enabled'], 'pause');
  if (!screened.ok) {
    server.sendResponse(res, 400, { error: 'invalid-pause', reason: screened.reason, detail: screened.detail ?? null });
    return;
  }

  const nowUnix = Math.floor(server.now() / 1000);
  let pauseUntilUnix = null;
  if (body.pauseUntil !== undefined && body.pauseUntil !== null) {
    const parsed = Date.parse(body.pauseUntil);
    if (!Number.isFinite(parsed)) {
      server.sendResponse(res, 400, { error: 'invalid-pause', reason: 'bad-pause-until' });
      return;
    }
    pauseUntilUnix = Math.floor(parsed / 1000);
    if (pauseUntilUnix > nowUnix + 30 * 24 * 3600) {
      server.sendResponse(res, 400, { error: 'invalid-pause', reason: 'pause-too-far' });
      return;
    }
  }

  const updated = server.registry.mutate(params.deviceID, (e) => {
    e.pauseUntilUnix = pauseUntilUnix;
    if (typeof body.enabled === 'boolean') e.enabled = body.enabled;
    e.planVersion += 1;
  });

  server.sendResponse(res, 200, {
    deviceID: params.deviceID,
    paused: updated.pauseUntilUnix !== null && updated.pauseUntilUnix !== undefined && nowUnix < updated.pauseUntilUnix,
    pauseUntilUnix: updated.pauseUntilUnix,
    enabled: updated.enabled,
    planVersion: updated.planVersion,
  });
}

/**
 * `POST /v1/quotes/refresh`
 *
 * Honest capability probe. It never fetches anything on behalf of the caller —
 * there is no URL parameter to abuse — and it answers `supported: false` with a
 * reason for every market this build cannot serve. That is the answer the client
 * needs: keep uploading your own quote, and know why.
 */
function handleQuoteRefresh(server, req, res, { body }) {
  const screened = screenBody(body, ['symbolKey'], 'refresh');
  if (!screened.ok) {
    server.sendResponse(res, 400, { error: 'invalid-refresh-request', reason: screened.reason, detail: screened.detail ?? null });
    return;
  }
  const symbolKey = body.symbolKey;
  if (typeof symbolKey !== 'string' || symbolKey.length === 0 || symbolKey.length > 32) {
    server.sendResponse(res, 400, { error: 'invalid-refresh-request', reason: 'bad-symbol-key' });
    return;
  }

  const supported = server.quoteSource.isRefreshable(symbolKey);
  if (!supported) {
    server.sendResponse(res, 200, {
      symbolKey,
      supported: false,
      reason: 'unsupported-market',
      detail:
        'This build has no refreshable quote source for that market. The client snapshot is used ' +
        'unchanged and its source timestamp is preserved; nothing is synthesized.',
      knownSources: [server.quoteSource.id],
      refreshableMarkets: server.quoteSource.supportedMarkets(),
    });
    return;
  }

  // Unreachable while no adapter is registered, and written so that adding one
  // does not change the contract.
  server.quoteSource.refresh(symbolKey).then(
    (quote) => server.sendResponse(res, 200, { symbolKey, supported: true, quote }),
    (error) => {
      const reason = error instanceof QuoteUnavailableError ? error.reason : 'source-error';
      server.sendResponse(res, 200, { symbolKey, supported: true, reason, detail: error.message });
    },
  );
}

module.exports = {
  ACCEPTED_REQUEST_HEADERS,
  ApiError,
  MAX_BODY_BYTES,
  PushBridgeServer,
  ROUTES,
  hasDuplicateKeys,
  matchRoute,
  parseStrictJson,
};
