'use strict';

/**
 * Small, dependency-free helpers.
 *
 * Everything in this file is pure (or filesystem-only) and deliberately has no
 * knowledge of Apple, ActivityKit or the Pulse payload: that keeps the security
 * primitives reviewable on their own.
 */

const crypto = require('node:crypto');
const path = require('node:path');
const fs = require('node:fs');

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/**
 * Seconds since the UNIX epoch, floored. APNs requires integer seconds here;
 * a float is rejected by the push service.
 */
function unixSeconds(date) {
  return Math.floor(date.getTime() / 1000);
}

/**
 * Converts an NSDate "reference date" (2001-01-01T00:00:00Z) offset to UNIX
 * seconds.
 *
 * This is the single most dangerous conversion in the bridge. Swift's
 * `JSONEncoder` default `dateEncodingStrategy` is `.deferredToDate`, which
 * writes `Date` as *seconds since 2001*, while APNs `timestamp`/`stale-date`
 * are *seconds since 1970*. Mixing them silently shifts a quote 31 years into
 * the past; the offset is applied in exactly one place so there is one place to
 * review and one test that pins it.
 */
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978307200;

function appleReferenceSecondsToUnix(referenceSeconds) {
  return referenceSeconds + APPLE_REFERENCE_DATE_UNIX_SECONDS;
}

function unixSecondsToAppleReference(unix) {
  return unix - APPLE_REFERENCE_DATE_UNIX_SECONDS;
}

/** Parses an ISO-8601 timestamp into a `Date`, or `null` when unusable. */
function parseInstant(value) {
  if (typeof value !== 'string' || value.length === 0) return null;
  // `Date.parse` accepts loose input; require a real ISO-8601 instant so a
  // human-typed date ("next tuesday") can never become a schedule.
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.test(value)) {
    return null;
  }
  const ms = Date.parse(value);
  if (!Number.isFinite(ms)) return null;
  return new Date(ms);
}

// ---------------------------------------------------------------------------
// Opaque identifiers
// ---------------------------------------------------------------------------

const OPAQUE_ID_PATTERN = /^[A-Za-z0-9_-]{8,128}$/;

/**
 * Device IDs are opaque and client-generated. Restricting them to a URL-safe
 * charset is what makes the route layer incapable of path traversal: no `.`,
 * no `/`, no `%`, no empty segment.
 */
function isOpaqueID(value) {
  return typeof value === 'string' && OPAQUE_ID_PATTERN.test(value);
}

function randomID(bytes = 16) {
  return crypto.randomBytes(bytes).toString('base64url');
}

// ---------------------------------------------------------------------------
// Base64 / base64url decoding
// ---------------------------------------------------------------------------

/**
 * Decodes base64 or base64url into a `Buffer`.
 *
 * `Buffer.from(x, 'base64')` silently ignores invalid characters and truncates
 * at the first `=`, so it accepts garbage that APNs will reject later. Strict
 * mode re-encodes and compares to prove the input really was canonical base64.
 */
function decodeBase64Strict(value, { maxBytes = 8192 } = {}) {
  if (typeof value !== 'string') return { ok: false, reason: 'not-a-string' };
  const compact = value.replace(/\s+/g, '');
  if (compact.length === 0) return { ok: false, reason: 'empty' };
  if (!/^[A-Za-z0-9+/\-_]+={0,2}$/.test(compact)) return { ok: false, reason: 'invalid-characters' };
  const normalized = compact.replace(/-/g, '+').replace(/_/g, '/');
  const buffer = Buffer.from(normalized, 'base64');
  if (buffer.length === 0) return { ok: false, reason: 'empty' };
  if (buffer.length > maxBytes) return { ok: false, reason: 'too-large' };
  const reencoded = buffer.toString('base64').replace(/=+$/, '');
  if (reencoded !== normalized.replace(/=+$/, '')) return { ok: false, reason: 'not-canonical' };
  return { ok: true, buffer };
}

function encodeBase64(buffer) {
  return Buffer.from(buffer).toString('base64');
}

// ---------------------------------------------------------------------------
// Byte-safe string primitives
// ---------------------------------------------------------------------------

function isWellFormedUTF8(value) {
  return typeof value === 'string' && !value.includes('\uFFFD') && Buffer.from(value, 'utf8').toString('utf8') === value;
}

/** UTF-8 byte length, which is what the 4 KB APNs budget is measured in. */
function utf8Length(value) {
  return Buffer.byteLength(value, 'utf8');
}

// ---------------------------------------------------------------------------
// Timing-safe comparison
// ---------------------------------------------------------------------------

/**
 * Compares two secrets without leaking length or content through timing.
 *
 * Both sides are hashed first so differing lengths cannot short-circuit, then
 * compared with `crypto.timingSafeEqual`.
 */
function safeEqualSecret(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const ha = crypto.createHash('sha256').update(a, 'utf8').digest();
  const hb = crypto.createHash('sha256').update(b, 'utf8').digest();
  return crypto.timingSafeEqual(ha, hb);
}

// ---------------------------------------------------------------------------
// Filesystem safety
// ---------------------------------------------------------------------------

/**
 * Proves that `target` is inside `root` after resolving symlinks on both.
 *
 * The store refuses to write anywhere it did not create, so this check does not
 * merely compare prefixes on unresolved strings: `realpath` on the root catches
 * a `latest.json` that is a symlink out of the tree, and the parent-directory
 * variant catches the same trick played on the directory itself.
 */
function isInsideRoot(root, target) {
  const realRoot = fs.realpathSync(root);
  let realTarget;
  try {
    realTarget = fs.realpathSync(target);
  } catch {
    // The target does not exist yet: resolve its parent instead and append the
    // basename so a not-yet-created file is still checked.
    const parent = path.dirname(target);
    const realParent = fs.realpathSync(parent);
    realTarget = path.join(realParent, path.basename(target));
  }
  const relative = path.relative(realRoot, realTarget);
  if (relative === '') return false; // the root itself is not a valid target
  return !relative.startsWith('..') && !path.isAbsolute(relative);
}

/** Refuses a symlink at `target` even when it points back inside the root. */
function isSymlink(target) {
  try {
    return fs.lstatSync(target).isSymbolicLink();
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Redaction
// ---------------------------------------------------------------------------

/**
 * The answer to "why is there no token in my log?".
 *
 * Log records are built from an allow-list of scalar fields (`elapsedMs`,
 * `status`, `attempt`), so no code path ever *needs* to scrub a token. This
 * helper exists for the few places that must print a free-form reason from an
 * external system and acts as a second line of defence.
 */
const REDACTED = '[redacted]';

const SECRET_KEY_PATTERN = /(token|secret|authorization|bearer|password|p8|privatekey|private_key|jwt|apns-key|apns_key|keyid|key_id)/i;

function redactValue(value) {
  if (typeof value === 'string') {
    if (value.length === 0) return value;
    // A long base64/hex-looking run is more likely a token than a status word.
    if (/^[A-Za-z0-9+/\-_=]{20,}$/.test(value)) return REDACTED;
    return value;
  }
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === 'object') return redactObject(value);
  return value;
}

function redactObject(object) {
  const out = {};
  for (const [key, value] of Object.entries(object)) {
    out[key] = SECRET_KEY_PATTERN.test(key) ? REDACTED : redactValue(value);
  }
  return out;
}

/**
 * The only serializer used for log lines.
 *
 * Returns a single-line JSON string with a hard length cap so a hostile token
 * cannot force a multi-megabyte log entry.
 */
function logLine(fields) {
  let text;
  try {
    text = JSON.stringify(redactObject(fields));
  } catch {
    text = '{"level":"error","event":"log-serialization-failed"}';
  }
  return text.length > 2048 ? text.slice(0, 2048) + '…' : text;
}

module.exports = {
  APPLE_REFERENCE_DATE_UNIX_SECONDS,
  REDACTED,
  appleReferenceSecondsToUnix,
  decodeBase64Strict,
  encodeBase64,
  isInsideRoot,
  isOpaqueID,
  isSymlink,
  isWellFormedUTF8,
  logLine,
  parseInstant,
  randomID,
  redactObject,
  safeEqualSecret,
  unixSeconds,
  unixSecondsToAppleReference,
  utf8Length,
};
