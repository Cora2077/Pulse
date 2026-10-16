'use strict';

/**
 * The only module in the bridge that performs network I/O.
 *
 * Several rules live here rather than in each adapter, because an adapter that
 * forgets one of them would be an SSRF or a hang, not a wrong number:
 *
 *   - **Host pinning.** A request is built from a fixed host constant and a code
 *     that already passed the adapter's own strict regex. There is no parameter
 *     for a caller-supplied URL, host, or path separator anywhere below.
 *   - **No redirects.** `redirect: 'error'` is requested. When a fetch
 *     implementation ignores that (or a test double reports a redirect anyway),
 *     the resulting status/location is re-checked here and a hop to any host but
 *     the pinned one is refused. A redirect is never followed to another host,
 *     even by a fetch implementation that would have followed it itself.
 *   - **Hard timeout.** Every request has one, so a stalled peer surfaces as a
 *     typed failure instead of a wedged refresh.
 *   - **Bounded bodies.** The body is read through a byte ceiling. An oversized
 *     response is a `source-invalid`, not something that is buffered first and
 *     measured afterwards.
 *
 * The fetch implementation and the clock are injected, so no test can reach the
 * network and no code path can mistake "the time now" for "the source's time".
 */

const { QuoteUnavailableError } = require('../quote-source');

const DEFAULT_TIMEOUT_MS = 5_000;
const DEFAULT_MAX_BYTES = 512 * 1024;

/** A scheme/host pair may only ever be this exact string. */
const ALLOWED_PROTOCOL = 'https:';

/** Reasons a caller may ask for; anything else is normalised to `source-error`. */
const REQUEST_FAILURE_REASONS = new Set(['source-unavailable', 'source-error', 'source-invalid']);

/**
 * Characters that must never appear in a symbol code that reaches a URL. `.` is
 * deliberately absent: the symbol suffixes (`600519.SH`) are stripped by the
 * adapter *before* this check, so a dot here is an escaped or split separator,
 * not part of a code.
 */
const URL_UNSAFE = /[\/\\%?#:\s]/;
const TRAVERSAL = /\.\./;

/**
 * Validates a code that is about to become one path segment.
 *
 * @param {unknown} code
 * @param {{ pattern: RegExp, maxLength?: number, label?: string }} options
 * @returns {string} the code, unchanged, when it is safe
 * @throws {QuoteUnavailableError} `source-invalid`
 */
function assertSafeCode(code, { pattern, maxLength = 32, label = 'symbol' }) {
  if (typeof code !== 'string' || code.length === 0 || code.length > maxLength) {
    throw new QuoteUnavailableError('source-invalid', `${label} is not a bounded string`);
  }
  if (URL_UNSAFE.test(code) || TRAVERSAL.test(code)) {
    throw new QuoteUnavailableError('source-invalid', `${label} contains URL-unsafe characters`);
  }
  if (!pattern.test(code)) {
    throw new QuoteUnavailableError('source-invalid', `${label} has an unexpected form`);
  }
  return code;
}

/** Normalises whatever a fetch implementation threw into a typed reason. */
function classifyThrow(error) {
  if (error instanceof QuoteUnavailableError) return error;
  const name = error && error.name;
  if (name === 'AbortError' || name === 'TimeoutError' || name === 'AbortSignal') {
    return new QuoteUnavailableError('source-unavailable', 'quote request timed out');
  }
  return new QuoteUnavailableError('source-error', `quote request failed: ${(error && error.message) || name || 'unknown error'}`);
}

/**
 * Maps a status to a typed failure. Every non-2xx is an error: a 404 is an
 * unknown instrument, a 429 or 5xx is the source being unavailable, and nothing
 * here retries — a tight retry loop against a rate-limited host is how a service
 * gets itself blocked.
 */
function failureForStatus(status, { notFoundReason = 'unsupported-market' } = {}) {
  if (status === 404 || status === 410 || status === 400 || status === 403) {
    return new QuoteUnavailableError(notFoundReason, `source answered HTTP ${status}`);
  }
  return new QuoteUnavailableError('source-unavailable', `source answered HTTP ${status}`);
}

/**
 * Enforces the pinned host on a response, and refuses anything that looks like a
 * redirect away from it. Returns the (possibly unreachable) `location` so an
 * adapter can assert what happened.
 */
function guardPinnedResponse(response, { host, label }) {
  const status = response.status;
  if (status >= 300 && status < 400) {
    const location = readLocation(response);
    throw new QuoteUnavailableError(
      'source-unavailable',
      `${label}: refused a redirect (HTTP ${status}${location ? ` to ${location}` : ''}); the host is pinned to ${host}`,
    );
  }
  const finalUrl = response.url;
  if (typeof finalUrl === 'string' && finalUrl.length > 0) {
    let origin;
    try {
      origin = new URL(finalUrl);
    } catch {
      throw new QuoteUnavailableError('source-unavailable', `${label}: response carries an unparseable URL`);
    }
    if (origin.protocol !== ALLOWED_PROTOCOL || origin.host !== host) {
      throw new QuoteUnavailableError(
        'source-unavailable',
        `${label}: response left the pinned host ${host} (${origin.host})`,
      );
    }
  }
}

/** Best-effort read of a `Location` header from any of the shapes a fetch may use. */
function readLocation(response) {
  const headers = response.headers;
  if (!headers) return '';
  try {
    if (typeof headers.get === 'function') return headers.get('location') ?? '';
    if (Array.isArray(headers)) {
      const entry = headers.find((pair) => Array.isArray(pair) && String(pair[0]).toLowerCase() === 'location');
      return entry ? String(entry[1]) : '';
    }
    return String(headers.location ?? headers.Location ?? '');
  } catch {
    return '';
  }
}

/**
 * Reads at most `maxBytes` from a body.
 *
 * Prefers `arrayBuffer()`, whose length is known before the bytes are handed
 * over, and falls back to a streamed reader that aborts the moment the ceiling
 * is crossed. A body that is missing or unreadable is `source-error`: the source
 * answered, so this is not a bad symbol.
 */
async function readBoundedBody(response, { maxBytes, label }) {
  if (!response.body || typeof response.body.getReader !== 'function') {
    if (typeof response.arrayBuffer !== 'function') {
      throw new QuoteUnavailableError('source-error', `${label}: response has no readable body`);
    }
    let bytes;
    try {
      bytes = Buffer.from(await response.arrayBuffer());
    } catch (error) {
      throw new QuoteUnavailableError('source-error', `${label}: unreadable body (${(error && error.message) || 'unknown'})`);
    }
    if (bytes.length > maxBytes) {
      throw new QuoteUnavailableError('source-invalid', `${label}: body exceeds ${maxBytes} bytes`);
    }
    return bytes;
  }

  const body = response.body;
  if (!body || typeof body.getReader !== 'function') {
    throw new QuoteUnavailableError('source-error', `${label}: response has no readable body`);
  }
  const reader = body.getReader();
  const chunks = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        throw new QuoteUnavailableError('source-invalid', `${label}: body exceeds ${maxBytes} bytes`);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    try {
      await reader.cancel();
    } catch {
      // The stream is already gone; nothing to release.
    }
  }
  return Buffer.concat(chunks, total);
}

/**
 * An HTTP client bound to one fixed host.
 *
 * @param {object} options
 * @param {string} options.host pinned host: the only host a request may reach
 * @param {Function} [options.fetchImpl] injected for tests; defaults to global fetch
 * @param {() => number} [options.now] injected clock, milliseconds
 * @param {number} [options.timeoutMs]
 * @param {number} [options.maxBytes] body ceiling
 * @param {string} [options.label] used in error details only
 */
function createHttpClient({
  host,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maxBytes = DEFAULT_MAX_BYTES,
  label = host,
} = {}) {
  if (typeof host !== 'string' || host.length === 0) {
    throw new TypeError('createHttpClient requires a pinned host');
  }
  if (typeof fetchImpl !== 'function') {
    throw new TypeError('createHttpClient requires a fetch implementation');
  }
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new TypeError('createHttpClient requires a positive timeoutMs');
  }
  if (!Number.isInteger(maxBytes) || maxBytes <= 0) {
    throw new TypeError('createHttpClient requires a positive integer maxBytes');
  }

  /**
   * One GET against the pinned host.
   *
   * @param {string} pathAndQuery already-built path, never caller-supplied
   * @param {{ headers?: Record<string,string>, notFoundReason?: string }} [request]
   */
  async function request(pathAndQuery, { headers = {}, notFoundReason = 'unsupported-market' } = {}) {
    if (typeof pathAndQuery !== 'string' || !pathAndQuery.startsWith('/') || pathAndQuery.length > 512) {
      throw new QuoteUnavailableError('source-invalid', `${label}: refusing to build a request from that path`);
    }
    if (URL_UNSAFE.test(pathAndQuery.replace(/[/?=&,]/g, ''))) {
      throw new QuoteUnavailableError('source-invalid', `${label}: path contains URL-unsafe characters`);
    }
    const url = `${ALLOWED_PROTOCOL}//${host}${pathAndQuery}`;

    // The clock is read once, so a request cannot be timed out by a clock the
    // adapter moves; it is never used as a quote timestamp.
    const startedAtMs = now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    // Node keeps the event loop alive for a pending timer; a refresh must not.
    if (typeof timer.unref === 'function') timer.unref();

    let response;
    try {
      response = await fetchImpl(url, {
        method: 'GET',
        headers,
        redirect: 'error',
        signal: controller.signal,
      });
    } catch (error) {
      clearTimeout(timer);
      throw classifyThrow(error);
    }
    try {
      if (!response || typeof response.status !== 'number') {
        throw new QuoteUnavailableError('source-error', `${label}: response has no HTTP status`);
      }
      guardPinnedResponse(response, { host, label });
      if (response.status < 200 || response.status >= 300) {
        throw failureForStatus(response.status, { notFoundReason });
      }
      const bytes = await readBoundedBody(response, { maxBytes, label });
      return { bytes, url, status: response.status, elapsedMs: Math.max(0, now() - startedAtMs) };
    } finally { clearTimeout(timer); }
  }

  return Object.freeze({ host, label, maxBytes, request, timeoutMs });
}

module.exports = {
  ALLOWED_PROTOCOL,
  DEFAULT_MAX_BYTES,
  DEFAULT_TIMEOUT_MS,
  REQUEST_FAILURE_REASONS,
  assertSafeCode,
  createHttpClient,
  failureForStatus,
  guardPinnedResponse,
  readBoundedBody,
  readLocation,
};
