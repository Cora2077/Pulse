'use strict';

/**
 * The APNs transport.
 *
 * Shape of the contract, which is what makes the delivery engine honest:
 *
 *   `send()` resolves to `{ outcome: 'accepted' | 'rejected' | 'retry' | 'unconfigured', ... }`
 *   and never throws for an ordinary failure. A caller that gets anything other
 *   than `accepted` must not record a successful delivery.
 *
 * Hard security properties:
 *
 *   - The HTTP/2 connection goes to **one** host, chosen from config
 *     (`api.sandbox.push.apple.com` or `api.push.apple.com`). The request path
 *     is built from the *decoded token bytes*, hex-encoded, so no caller-supplied
 *     string can influence the URL. There is no code path that accepts a URL,
 *     which is what rules out SSRF by construction rather than by filtering.
 *   - `apns-topic`, `apns-push-type`, `apns-priority`, `apns-expiration` are set
 *     from constants plus the registration, never echoed from a request body.
 *   - The session is created lazily and shared; on a transport error the session
 *     is destroyed so the next attempt reconnects instead of reusing a poisoned
 *     socket.
 */

const http2 = require('node:http2');
const { logLine } = require('./util');

const SANDBOX_HOST = 'api.sandbox.push.apple.com';
const PRODUCTION_HOST = 'api.push.apple.com';
const ALLOWED_HOSTS = new Set([SANDBOX_HOST, PRODUCTION_HOST]);
const APNS_PORT = 443;

/** APNs reasons that mean "this token is dead; stop using it". */
const TOKEN_DEAD_REASONS = new Set([
  'BadDeviceToken',
  'DeviceTokenNotForTopic',
  'Unregistered',
  'ExpiredProviderToken', // the token we signed, handled separately
]);

/** Reasons that are our fault and will not improve by retrying immediately. */
const PERMANENT_REASONS = new Set([
  'BadCollapseId', 'BadExpirationDate', 'BadMessageId', 'BadPriority', 'BadTopic',
  'InvalidPushType', 'MissingTopic', 'TopicDisallowed', 'PayloadEmpty',
  'PayloadTooLarge', 'BadCertificateEnvironment', 'Forbidden', 'InvalidProviderToken',
  'MissingProviderToken', 'BadPath', 'MethodNotAllowed', 'Unregistered',
]);

class ApnsTransport {
  /**
   * @param {object} options
   * @param {string} options.host              Must be a known Apple host.
   * @param {() => (string|null)} options.tokenProvider Bearer token source.
   * @param {string} options.topic             App bundle id.
   * @param {object} [options.session]         Injected for tests.
   * @param {object} [options.logger]
   * @param {number} [options.timeoutMs]
   */
  constructor({ host, tokenProvider, topic, session = null, logger = null, timeoutMs = 10_000 }) {
    if (!ALLOWED_HOSTS.has(host)) {
      throw new Error(`APNs host must be one of ${[...ALLOWED_HOSTS].join(', ')}`);
    }
    this.host = host;
    this.authority = `https://${host}:${APNS_PORT}`;
    this.tokenProvider = tokenProvider;
    this.topic = topic;
    this.logger = logger;
    this.timeoutMs = timeoutMs;
    this.injectedSession = session;
    this.session = session;
  }

  ensureSession() {
    if (this.session && !this.session.closed && !this.session.destroyed) return this.session;
    if (this.injectedSession && !this.injectedSession.closed) {
      this.session = this.injectedSession;
      return this.session;
    }
    this.session = http2.connect(this.authority);
    this.session.on('error', () => {
      this.session = null;
    });
    return this.session;
  }

  /** Tears down the connection so the next send reconnects. */
  reset() {
    if (this.session && this.session !== this.injectedSession) {
      try {
        this.session.destroy();
      } catch {
        // Destroying a dead session is not an error worth surfacing.
      }
    }
    this.session = null;
  }

  /**
   * Sends one push.
   *
   * @param {Buffer} tokenBytes Raw device token; hex-encoded into the path.
   * @param {object} apsDictionary The exact JSON body.
   * @param {object} options
   * @param {'alert'|'liveactivity'} [options.pushType]
   * @param {number} [options.expirationUnix] 0 = do not store.
   * @param {number} [options.priority] 5 or 10.
   * @returns {Promise<object>} See module doc.
   */
  async send(tokenBytes, apsDictionary, options = {}) {
    const {
      pushType = 'liveactivity',
      expirationUnix = 0,
      priority = 10,
      collapseId = null,
      apnsID = null,
    } = options;

    if (!Buffer.isBuffer(tokenBytes) || tokenBytes.length === 0) {
      return { outcome: 'rejected', status: 0, reason: 'empty-device-token', permanent: true };
    }

    let token;
    try {
      token = this.tokenProvider();
    } catch (error) {
      // No provider token: this is `unconfigured`, not a delivery failure. The
      // caller must report it as such rather than as a transient error.
      return { outcome: 'unconfigured', reason: error.code ?? 'auth-unavailable' };
    }
    if (!token) return { outcome: 'unconfigured', reason: 'auth-unavailable' };

    const body = Buffer.from(JSON.stringify(apsDictionary), 'utf8');
    const headers = {
      ':method': 'POST',
      // Path is built only from the token's own bytes.
      ':path': `/3/device/${tokenBytes.toString('hex')}`,
      'apns-topic': this.topic,
      'apns-push-type': pushType,
      'apns-priority': String(priority),
      'apns-expiration': String(expirationUnix),
      authorization: `bearer ${token}`,
      'content-type': 'application/json',
      'content-length': String(body.length),
    };
    if (collapseId) headers['apns-collapse-id'] = collapseId;
    if (apnsID) headers['apns-id'] = apnsID;

    return this.#request(headers, body);
  }

  #request(headers, body) {
    return new Promise((resolve) => {
      let settled = false;
      const finish = (result) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };

      let stream;
      try {
        stream = this.ensureSession().request(headers);
      } catch (error) {
        this.reset();
        finish({ outcome: 'retry', reason: `connect-${error.code ?? 'failed'}`, retryable: true });
        return;
      }

      const timer = setTimeout(() => {
        try {
          stream.close(http2.constants.NGHTTP2_CANCEL);
        } catch {
          // Already closed.
        }
        this.reset();
        finish({ outcome: 'retry', reason: 'timeout', retryable: true });
      }, this.timeoutMs);

      let status = 0;
      let responseBody = '';
      let apnsId = null;

      stream.on('response', (responseHeaders) => {
        status = Number(responseHeaders[':status']) || 0;
        apnsId = responseHeaders['apns-id'] ?? null;
      });
      stream.setEncoding('utf8');
      stream.on('data', (chunk) => {
        // A response body from APNs is a small JSON error document. Cap it so a
        // misbehaving endpoint cannot balloon memory.
        if (responseBody.length < 4096) responseBody += chunk;
      });
      stream.on('error', (error) => {
        clearTimeout(timer);
        this.reset();
        finish({ outcome: 'retry', reason: `stream-${error.code ?? 'error'}`, retryable: true });
      });
      stream.on('close', () => {
        clearTimeout(timer);
        if (settled) return;
        if (status === 0) {
          this.reset();
          finish({ outcome: 'retry', reason: 'no-response', retryable: true });
          return;
        }
        finish(classifyResponse(status, responseBody, apnsId));
      });

      stream.end(body);
    });
  }
}

/**
 * Turns an APNs HTTP response into the transport outcome vocabulary.
 *
 * `410 Unregistered` and `BadDeviceToken` are terminal for that token: the
 * delivery engine drops the token rather than retrying forever. 429 and 5xx are
 * retryable. A 200 with an empty body is the only success.
 */
function classifyResponse(status, responseBody, apnsId = null) {
  let reason = null;
  if (responseBody) {
    try {
      const parsed = JSON.parse(responseBody);
      if (parsed && typeof parsed.reason === 'string') reason = parsed.reason;
    } catch {
      reason = null;
    }
  }

  if (status === 200) return { outcome: 'accepted', status, apnsId };

  if (status === 410) {
    return { outcome: 'rejected', status, reason: reason ?? 'Unregistered', tokenDead: true, permanent: true, apnsId };
  }
  if (status === 400 && reason && TOKEN_DEAD_REASONS.has(reason)) {
    return { outcome: 'rejected', status, reason, tokenDead: true, permanent: true, apnsId };
  }
  if (status === 403 && reason === 'ExpiredProviderToken') {
    return { outcome: 'retry', status, reason, retryable: true, refreshProviderToken: true, apnsId };
  }
  if (status === 429) {
    return { outcome: 'retry', status, reason: reason ?? 'TooManyRequests', retryable: true, apnsId };
  }
  if (status >= 500) {
    return { outcome: 'retry', status, reason: reason ?? `HTTP-${status}`, retryable: true, apnsId };
  }
  if (status === 404 && reason === 'BadPath') {
    return { outcome: 'rejected', status, reason, permanent: true, apnsId };
  }
  if (PERMANENT_REASONS.has(reason)) {
    return { outcome: 'rejected', status, reason, permanent: true, apnsId };
  }
  if (status >= 400) {
    // Unknown 4xx: treated as retryable once and then given up on by the
    // engine's attempt cap, because guessing "permanent" could drop a live
    // token for a reason Apple will later fix.
    return { outcome: 'retry', status, reason: reason ?? `HTTP-${status}`, retryable: true, apnsId };
  }
  return { outcome: 'retry', status, reason: `HTTP-${status}`, retryable: true, apnsId };
}

/**
 * A transport that never opens a socket.
 *
 * Used in `dry-run` mode and in tests. It records what *would* have been sent so
 * an operator can inspect the exact body, and it reports `accepted` only under
 * the explicit `simulateAccepted` flag — because a dry run must not be able to
 * make the service believe a push landed.
 */
class RecordingTransport {
  constructor({ simulateAccepted = false, onSend = null } = {}) {
    this.simulateAccepted = simulateAccepted;
    this.onSend = onSend;
    this.sent = [];
    this.host = 'recording';
  }

  async send(tokenBytes, apsDictionary, options = {}) {
    const record = {
      tokenLength: Buffer.isBuffer(tokenBytes) ? tokenBytes.length : 0,
      body: apsDictionary,
      options,
    };
    this.sent.push(record);
    if (this.onSend) this.onSend(record);
    return this.simulateAccepted
      ? { outcome: 'accepted', status: 200, apnsId: 'dry-run', dryRun: true }
      : { outcome: 'unconfigured', reason: 'dry-run-recording-only', dryRun: true };
  }

  reset() {}
}

module.exports = {
  ALLOWED_HOSTS,
  APNS_PORT,
  ApnsTransport,
  PERMANENT_REASONS,
  PRODUCTION_HOST,
  RecordingTransport,
  SANDBOX_HOST,
  TOKEN_DEAD_REASONS,
  classifyResponse,
  logLine,
};
