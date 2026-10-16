'use strict';

/**
 * Registration shape and the authorized session windows.
 *
 * A registration is the *whole* authorization: after it is stored, the service
 * may push within these windows and nothing else. So the rules are strict:
 *
 *   - UTC only. A window with no zone is not "local time"; it is ambiguous, and
 *     an ambiguous window is a push at 03:00 the user did not ask for.
 *   - At most 8 hours per window, which matches the system's own Live Activity
 *     lifetime; a 24-hour window would be a promise the OS will not keep.
 *   - A bounded number of windows, and no overlap, so the scheduler's
 *     "one automatic start per window" cannot be gamed by nesting windows.
 *   - `pauseUntil` suppresses everything until it passes; it never extends a
 *     window and never re-arms a spent start budget.
 */

const { isWellFormedUTF8, parseInstant, utf8Length } = require('./util');
const { screenBody } = require('./sensitive');
const {
  ACTIVITY_ID_PATTERN,
  classifyToken,
  validateAttributes,
  validateState,
} = require('./payload');

const MAX_WINDOW_SECONDS = 8 * 60 * 60;
const MAX_WINDOWS = 8;
const MAX_PAUSE_SECONDS = 30 * 24 * 60 * 60;

/**
 * Window IDs are client-chosen labels for one authorization window.
 *
 * They are shorter than device IDs (2 chars is plenty for `w1`) and are only
 * ever used as an in-memory map key and in the registry's JSON — never as a
 * path component — but the charset is still restricted so a window ID can never
 * look like a path or a URL.
 */
const WINDOW_ID_PATTERN = /^[A-Za-z0-9_-]{2,64}$/;

/** Allowed top-level keys of a registration body. */
const REGISTRATION_KEYS = [
  'attributes',
  'template',
  'pushToStartToken',
  'updateToken',
  'activityID',
  'enabled',
  'pauseUntil',
  'windows',
  'revision',
];

const WINDOW_KEYS = ['id', 'start', 'end', 'autoStart'];

function fail(reason, detail) {
  return { ok: false, reason, detail };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Validates one UTC window.
 *
 * `start < end` is required rather than "empty window means all day": an empty
 * window that silently becomes all-day is how a service starts pushing at
 * midnight.
 */
function validateWindow(raw, label, { maxWindowSeconds = MAX_WINDOW_SECONDS } = {}) {
  if (!isPlainObject(raw)) return fail('not-an-object', label);
  for (const key of Object.keys(raw)) {
    if (!WINDOW_KEYS.includes(key)) return fail('unknown-field', `${label}.${key}`);
  }
  if (typeof raw.id !== 'string' || !WINDOW_ID_PATTERN.test(raw.id)) return fail('bad-window-id', `${label}.id`);

  const start = parseInstant(raw.start);
  if (!start) return fail('bad-window-start', `${label}.start`);
  const end = parseInstant(raw.end);
  if (!end) return fail('bad-window-end', `${label}.end`);

  const startSeconds = Math.floor(start.getTime() / 1000);
  const endSeconds = Math.floor(end.getTime() / 1000);
  if (endSeconds <= startSeconds) return fail('window-not-increasing', label);
  if (endSeconds - startSeconds > maxWindowSeconds) {
    return fail('window-too-long', `${label} spans ${endSeconds - startSeconds}s`);
  }

  let autoStart = true;
  if (raw.autoStart !== undefined) {
    if (typeof raw.autoStart !== 'boolean') return fail('not-a-boolean', `${label}.autoStart`);
    autoStart = raw.autoStart;
  }

  return { ok: true, value: { id: raw.id, startSeconds, endSeconds, autoStart } };
}

/**
 * Validates the full window list.
 *
 * Overlaps are rejected instead of merged: merging would silently change how
 * many automatic starts the user authorized.
 */
function validateWindows(raw, { maxWindows = MAX_WINDOWS } = {}) {
  if (raw === undefined) return { ok: true, value: [] };
  if (!Array.isArray(raw)) return fail('not-an-array', 'windows');
  if (raw.length > maxWindows) return fail('too-many-windows', `> ${maxWindows}`);

  const windows = [];
  for (let i = 0; i < raw.length; i += 1) {
    const checked = validateWindow(raw[i], `windows[${i}]`);
    if (!checked.ok) return checked;
    windows.push(checked.value);
  }

  const ordered = [...windows].sort((a, b) => a.startSeconds - b.startSeconds);
  for (let i = 1; i < ordered.length; i += 1) {
    if (ordered[i].startSeconds < ordered[i - 1].endSeconds) {
      return fail('windows-overlap', `${ordered[i - 1].id} / ${ordered[i].id}`);
    }
  }

  const ids = new Set(windows.map((w) => w.id));
  if (ids.size !== windows.length) return fail('duplicate-window-id');

  return { ok: true, value: windows };
}

/** Validates the token object. Bytes are decoded later; length is checked here. */
function validateTokenObject(raw, { required, label }) {
  if (raw === undefined || raw === null) {
    return required ? fail('missing-token', label) : { ok: true, value: null };
  }
  if (!isPlainObject(raw)) return fail('not-an-object', label);
  for (const key of Object.keys(raw)) {
    if (!['kind', 'base64'].includes(key)) return fail('unknown-field', `${label}.${key}`);
  }
  const kind = raw.kind === undefined ? label : raw.kind;
  if (kind !== 'pushToStart' && kind !== 'update') return fail('bad-token-kind', `${label}.kind`);
  if (typeof raw.base64 !== 'string') return fail('not-a-string', `${label}.base64`);

  const { decodeBase64Strict } = require('./util');
  const decoded = decodeBase64Strict(raw.base64, { maxBytes: 512 });
  if (!decoded.ok) return fail('bad-token-encoding', `${label}.base64 (${decoded.reason})`);

  const lengthCheck = classifyToken(kind, decoded.buffer.length);
  if (!lengthCheck.ok) return fail(lengthCheck.reason, `${label}.base64`);

  return { ok: true, value: { kind, bytes: decoded.buffer } };
}

/**
 * Validates a registration body in full.
 *
 * @param {unknown} raw Parsed JSON body.
 * @param {object} options
 * @param {boolean} options.hasUsableTokenAfterWrite `false` only when neither
 *   this body nor the stored registration supplies a token. The server computes
 *   it, because "is this body acceptable" and "can this registration ever push"
 *   are different questions.
 * @param {number} options.nowUnix Current time, for pauseUntil bounds.
 * @param {number} options.maxWindows
 */
function validateRegistration(raw, { hasUsableTokenAfterWrite = true, nowUnix, maxWindows = MAX_WINDOWS }) {
  const screened = screenBody(raw, REGISTRATION_KEYS, 'registration');
  if (!screened.ok) return screened;

  const body = raw;

  const attributes = validateAttributes(body.attributes, 'attributes');
  if (!attributes.ok) return attributes;

  // The template carries the display payload. It is validated as a complete
  // PulseActivityState so a client cannot register a half-state that only
  // fails later, mid-window, when a push is due.
  const template = validateState(body.template, 'template');
  if (!template.ok) return template;

  if (template.value.primary.symbolKey !== attributes.value.symbolKey) {
    return fail('template-attributes-symbol-mismatch',
      `${template.value.primary.symbolKey} != ${attributes.value.symbolKey}`);
  }

  const pushToStartToken = validateTokenObject(body.pushToStartToken, { required: false, label: 'pushToStart' });
  if (!pushToStartToken.ok) return pushToStartToken;

  const updateToken = validateTokenObject(body.updateToken, { required: false, label: 'update' });
  if (!updateToken.ok) return updateToken;

  let activityID = null;
  if (body.activityID !== undefined && body.activityID !== null) {
    if (typeof body.activityID !== 'string' || !ACTIVITY_ID_PATTERN.test(body.activityID)) {
      return fail('bad-activity-id', 'activityID');
    }
    activityID = body.activityID;
  }

  let enabled = true;
  if (body.enabled !== undefined) {
    if (typeof body.enabled !== 'boolean') return fail('not-a-boolean', 'enabled');
    enabled = body.enabled;
  }

  let pauseUntilUnix = null;
  if (body.pauseUntil !== undefined && body.pauseUntil !== null) {
    const pause = parseInstant(body.pauseUntil);
    if (!pause) return fail('bad-pause-until', 'pauseUntil');
    const pauseSeconds = Math.floor(pause.getTime() / 1000);
    if (pauseSeconds > nowUnix + MAX_PAUSE_SECONDS) {
      return fail('pause-too-far', `> ${MAX_PAUSE_SECONDS}s ahead`);
    }
    pauseUntilUnix = pauseSeconds;
  }

  const windows = validateWindows(body.windows, { maxWindows });
  if (!windows.ok) return windows;

  let revision = null;
  if (body.revision !== undefined && body.revision !== null) {
    if (!Number.isInteger(body.revision) || body.revision < 0) return fail('bad-revision', 'revision');
    revision = body.revision;
  }

  if (!hasUsableTokenAfterWrite) {
    // A registration with no token can never do anything; storing it would make
    // the service look configured while it is not.
    //
    // This is not "the request was a PUT": a replacement that omits tokens
    // because it only edits the template inherits the stored ones through
    // `mergeRegistration`, and the server says so by passing
    // `hasUsableTokenAfterWrite: true`.
    return fail('no-token-supplied');
  }

  return {
    ok: true,
    value: {
      attributes: attributes.value,
      template: template.value,
      pushToStartToken: pushToStartToken.value,
      updateToken: updateToken.value,
      activityID,
      enabled,
      pauseUntilUnix,
      windows: windows.value,
      revision,
    },
  };
}

/**
 * Merges a PUT body over an existing registration.
 *
 * Absent token fields mean "keep what you have", present ones replace. This is
 * what lets the app re-send a template edit without having to re-read a token it
 * deliberately does not persist.
 */
function mergeRegistration(existing, incoming) {
  return {
    attributes: incoming.attributes,
    template: incoming.template,
    pushToStartToken: incoming.pushToStartToken ?? existing?.pushToStartToken ?? null,
    updateToken: incoming.updateToken ?? existing?.updateToken ?? null,
    activityID: incoming.activityID ?? existing?.activityID ?? null,
    enabled: incoming.enabled,
    pauseUntilUnix: incoming.pauseUntilUnix,
    windows: incoming.windows,
    revision: incoming.revision,
  };
}

module.exports = {
  MAX_PAUSE_SECONDS,
  MAX_WINDOWS,
  MAX_WINDOW_SECONDS,
  REGISTRATION_KEYS,
  WINDOW_KEYS,
  mergeRegistration,
  validateRegistration,
  validateWindow,
  validateWindows,
  utf8Length,
  isWellFormedUTF8,
};
