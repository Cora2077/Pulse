'use strict';

/**
 * Validation of the Live Activity payload, mirroring the Swift types in
 * `Packages/PulseActivity/Sources/PulseActivity/`.
 *
 * The correspondence is exact and is asserted in tests against literal JSON
 * produced the way `JSONEncoder` would produce it:
 *
 *   PulseActivityAttributes  <->  registration.attributes
 *   PulseActivityState       <->  template.state          (APNs `content-state`)
 *   PulseActivityContent     <->  {state, staleDate}      (APNs `aps`)
 *
 * Two encoding facts drive the whole file:
 *
 *   * Swift's default `JSONEncoder` writes `Date` as **seconds since
 *     2001-01-01**, and Apple's ActivityKit documentation states the system
 *     **always** decodes a push's `content-state` with its default strategies —
 *     the app cannot install a custom decoder for it. Every `Date` inside the
 *     pushed `content-state` is therefore emitted as 2001-reference seconds
 *     under the Swift property names (`quoteSourceTime`, `staleDate`,
 *     `primary.quoteSourceTime`, `plans.asOf`), while the outer APNs
 *     `timestamp` and `stale-date` remain **seconds since 1970**. On input,
 *     dates are tagged explicitly by the client and converted once to UNIX
 *     seconds for internal arithmetic; the 2001-reference conversion happens
 *     exactly once, at the APNs boundary in `materializeState`. The full
 *     contract and its native proof live in `docs/NATIVE_WIRE.md`.
 *   * Enums are `String`-raw-valued and are therefore enum-erased on an unknown
 *     case: a newer client can send `marketPhase: "auction"` and the decoder
 *     throws. This module preserves that behaviour instead of coercing to
 *     `unknown`, because a payload the device cannot decode is a payload the
 *     service must not push.
 */

const { unixSeconds, isWellFormedUTF8, utf8Length, unixSecondsToAppleReference } = require('./util');

/** Mirrors `PulseMarketPhase`. */
const MARKET_PHASES = new Set([
  'preMarket', 'regular', 'lunchBreak', 'postMarket', 'overnight', 'closed', 'unknown',
]);

/** Mirrors `PulseActivityStatus`. */
const ACTIVITY_STATUSES = new Set([
  'live', 'stale', 'marketClosed', 'pausedToday', 'disabled', 'permissionRequired',
  'remoteUnavailable', 'noCandidate',
]);

/** Mirrors `PulsePlanSyncState` (reserved; not yet on the wire). */
const PLAN_SYNC_STATES = new Set(['local', 'synced', 'pending', 'unavailable']);

/**
 * The statuses a *push* may legitimately carry.
 *
 * `disabled`, `pausedToday`, `permissionRequired`, `noCandidate` are local
 * decisions: the device reached them by looking at its own state. A service
 * that pushes one of them is asserting something it cannot know, so the
 * delivery engine refuses and the registration is untouched.
 */
const PUSHABLE_STATUSES = new Set(['live', 'stale', 'marketClosed']);

/** APNs hard limit for the whole `aps` dictionary. */
const MAX_PAYLOAD_BYTES = 4096;

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

const ACTIVITY_ID_PATTERN = /^[A-Za-z0-9:._-]{1,128}$/;
const SYMBOL_KEY_PATTERN = /^[A-Za-z0-9._/:-]{1,32}$/;
const CURRENCY_PATTERN = /^[A-Z]{3,4}$/;

/**
 * The explicit index-points unit sentinel for `currencyCode`.
 *
 * An index level is not a money amount, and the iOS main target tracks
 * KOSPI / sector indices whose quote is a number of points. `POINTS` is the
 * one accepted non-ISO code: it is matched literally, so this is **not** a
 * widening of `CURRENCY_PATTERN` — any other string that is not 3–4 uppercase
 * letters is still refused, and a points-quoted instrument is never required
 * to borrow its market's whole-unit formatting (a KOSPI index keeps its
 * decimals even though KRW equities are quoted in whole won).
 */
const POINTS_CURRENCY_CODE = 'POINTS';

function fail(reason, detail) {
  return { ok: false, reason, detail };
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function checkString(value, label, { min = 0, max = 256, pattern = null, allowNull = false } = {}) {
  if (value === null && allowNull) return { ok: true, value: null };
  if (typeof value !== 'string') return fail('not-a-string', label);
  if (!isWellFormedUTF8(value)) return fail('invalid-utf8', label);
  const length = utf8Length(value);
  if (length < min) return fail('too-short', label);
  if (length > max) return fail('too-long', label);
  if (pattern && !pattern.test(value)) return fail('bad-format', label);
  return { ok: true, value };
}

function checkNumber(value, label, { min = null, max = null, allowNull = false } = {}) {
  if (value === null && allowNull) return { ok: true, value: null };
  if (typeof value !== 'number' || !Number.isFinite(value)) return fail('not-a-finite-number', label);
  if (min !== null && value < min) return fail('below-minimum', label);
  if (max !== null && value > max) return fail('above-maximum', label);
  return { ok: true, value };
}

function checkInteger(value, label, { min = null, max = null, allowNull = false } = {}) {
  if (value === null && allowNull) return { ok: true, value: null };
  if (!Number.isInteger(value)) return fail('not-an-integer', label);
  if (min !== null && value < min) return fail('below-minimum', label);
  if (max !== null && value > max) return fail('above-maximum', label);
  return { ok: true, value };
}

/**
 * Reads a Swift-encoded date.
 *
 * The client must say which clock it used. Guessing is how a quote ends up 31
 * years old, and a stale-date that is wrong in the *future* direction turns a
 * frozen quote into a confident-looking live one — the exact failure this
 * module exists to prevent.
 */
function checkDate(value, label, { allowNull = false } = {}) {
  if (value === null && allowNull) return { ok: true, value: null };
  if (!isPlainObject(value)) return fail('date-must-be-an-object', label);

  const { encoding, value: raw } = value;
  if (encoding === 'appleReferenceSeconds') {
    const checked = checkNumber(raw, `${label}.value`, { min: -1e12, max: 1e12 });
    if (!checked.ok) return checked;
    return { ok: true, value: { encoding, seconds: checked.value } };
  }
  if (encoding === 'unixSeconds') {
    const checked = checkNumber(raw, `${label}.value`, { min: -1e12, max: 1e12 });
    if (!checked.ok) return checked;
    return { ok: true, value: { encoding, seconds: checked.value } };
  }
  if (encoding === 'iso8601') {
    const checked = checkString(raw, `${label}.value`, { min: 20, max: 40 });
    if (!checked.ok) return checked;
    const ms = Date.parse(checked.value);
    if (!Number.isFinite(ms)) return fail('bad-format', `${label}.value`);
    return { ok: true, value: { encoding, seconds: ms / 1000 } };
  }
  return fail('unknown-date-encoding', `${label}.encoding`);
}

/** Normalizes a checked date into UNIX seconds. */
function dateToUnixSeconds(checkedDate) {
  if (checkedDate.encoding === 'unixSeconds') return Math.floor(checkedDate.seconds);
  if (checkedDate.encoding === 'iso8601') return Math.floor(checkedDate.seconds);
  // appleReferenceSeconds
  return Math.floor(checkedDate.seconds + 978307200);
}

// ---------------------------------------------------------------------------
// PulseActivityInstrument
// ---------------------------------------------------------------------------

function validateInstrument(value, label = 'primary') {
  if (!isPlainObject(value)) return fail('not-an-object', label);
  const out = {};

  const symbolKey = checkString(value.symbolKey, `${label}.symbolKey`, { min: 1, max: 32, pattern: SYMBOL_KEY_PATTERN });
  if (!symbolKey.ok) return symbolKey;
  out.symbolKey = symbolKey.value;

  const displayName = checkString(value.displayName, `${label}.displayName`, { min: 1, max: 64 });
  if (!displayName.ok) return displayName;
  out.displayName = displayName.value;

  const identityText = checkString(value.identityText, `${label}.identityText`, { min: 1, max: 64 });
  if (!identityText.ok) return identityText;
  out.identityText = identityText.value;

  // `POINTS` is matched literally before the general pattern, so the only
  // non-ISO code that passes is exactly that sentinel.
  const currencyCode = value.currencyCode === POINTS_CURRENCY_CODE
    ? { ok: true, value: POINTS_CURRENCY_CODE }
    : checkString(value.currencyCode, `${label}.currencyCode`, { min: 3, max: 4, pattern: CURRENCY_PATTERN });
  if (!currencyCode.ok) return currencyCode;
  out.currencyCode = currencyCode.value;
  if (value.unit !== undefined) {
    if (value.unit !== 'currency' && value.unit !== 'points') return fail('unknown-enum-case', `${label}.unit`);
    out.unit = value.unit;
  } else if (value.currencyCode === POINTS_CURRENCY_CODE) {
    out.unit = 'points'; // legacy sentinel; new clients keep real currency + unit
  }

  // Price must be finite and > 0. `0` is what a failed feed returns; letting it
  // through would put "0.00" on a lock screen as if the instrument were worth
  // nothing.
  const price = checkNumber(value.price, `${label}.price`, { min: Number.EPSILON, max: 1e12 });
  if (!price.ok) return price;
  out.price = price.value;

  const change = checkNumber(value.change, `${label}.change`, { min: -1e12, max: 1e12 });
  if (!change.ok) return change;
  out.change = change.value;

  const changePercent = checkNumber(value.changePercent, `${label}.changePercent`, {
    min: -1e5, max: 1e5, allowNull: true,
  });
  if (!changePercent.ok) return changePercent;
  out.changePercent = changePercent.value;

  const quoteSourceTime = checkDate(value.quoteSourceTime, `${label}.quoteSourceTime`);
  if (!quoteSourceTime.ok) return quoteSourceTime;
  out.quoteSourceTime = quoteSourceTime.value;

  const sourceDelay = checkNumber(value.sourceDelay, `${label}.sourceDelay`, {
    min: 0, max: 7 * 24 * 3600, allowNull: true,
  });
  if (!sourceDelay.ok) return sourceDelay;
  out.sourceDelay = sourceDelay.value;

  const marketPhase = value.marketPhase === undefined ? 'unknown' : value.marketPhase;
  if (!MARKET_PHASES.has(marketPhase)) return fail('unknown-enum-case', `${label}.marketPhase`);
  out.marketPhase = marketPhase;

  return { ok: true, value: out };
}

// ---------------------------------------------------------------------------
// PulseActivityPlanDigest — counts only, never money
// ---------------------------------------------------------------------------

function validatePlanDigest(value, label = 'plans') {
  if (!isPlainObject(value)) return fail('not-an-object', label);
  const out = {};
  for (const key of ['priceConditionReachedCount', 'manualReviewCount', 'remainingPlanCount']) {
    const checked = checkInteger(value[key], `${label}.${key}`, { min: 0, max: 10_000 });
    if (!checked.ok) return checked;
    out[key] = checked.value;
  }

  // `asOf` and `syncState` are the plan-side clock and its confirmation state.
  // They are *tolerated* for backward compatibility with clients that already
  // send them: an older service ignored them, and rejecting them here would
  // break a client that is otherwise correct. They are validated when present
  // (so a malformed one is still refused) and carried through untouched.
  //
  // `asOf` is a date and goes through the same encoding-tagged path as every
  // other date, so a client may send it as Apple-reference or UNIX seconds and
  // the ambiguity is resolved explicitly rather than guessed. It is *not* used
  // for freshness: the quote clock governs that, and plan freshness is a
  // separate concern the service does not assert on.
  if (value.asOf !== undefined && value.asOf !== null) {
    const asOf = checkDate(value.asOf, `${label}.asOf`);
    if (!asOf.ok) return asOf;
    out.asOf = asOf.value;
    out.asOfUnix = dateToUnixSeconds(asOf.value);
    out.asOfEncoding = asOf.value.encoding;
  }

  if (value.syncState !== undefined && value.syncState !== null) {
    if (!PLAN_SYNC_STATES.has(value.syncState)) return fail('unknown-enum-case', `${label}.syncState`);
    out.syncState = value.syncState;
  }
  if (value.revision !== undefined && value.revision !== null) {
    const revision = checkString(value.revision, `${label}.revision`, { min: 1, max: 128 });
    if (!revision.ok) return revision;
    out.revision = revision.value;
  }

  return { ok: true, value: out };
}

// ---------------------------------------------------------------------------
// PulseActivityState
// ---------------------------------------------------------------------------

function validateState(value, label = 'state') {
  if (!isPlainObject(value)) return fail('not-an-object', label);

  const primary = validateInstrument(value.primary, `${label}.primary`);
  if (!primary.ok) return primary;

  const plans = validatePlanDigest(value.plans ?? {
    priceConditionReachedCount: 0, manualReviewCount: 0, remainingPlanCount: 0,
  }, `${label}.plans`);
  if (!plans.ok) return plans;

  if (!ACTIVITY_STATUSES.has(value.status)) return fail('unknown-enum-case', `${label}.status`);

  const staleDate = checkDate(value.staleDate, `${label}.staleDate`);
  if (!staleDate.ok) return staleDate;

  const quoteSourceTime = checkDate(value.quoteSourceTime, `${label}.quoteSourceTime`);
  if (!quoteSourceTime.ok) return quoteSourceTime;

  let sessionID = null;
  if (value.sessionID !== undefined && value.sessionID !== null) {
    const checked = checkString(value.sessionID, `${label}.sessionID`, { min: 1, max: 64 });
    if (!checked.ok) return checked;
    sessionID = checked.value;
  }

  return {
    ok: true,
    value: normalizeStateDates({
      primary: primary.value,
      plans: plans.value,
      status: value.status,
      staleDate: staleDate.value,
      quoteSourceTime: quoteSourceTime.value,
      sessionID,
    }),
  };
}

/**
 * Normalizes every date in a validated state to **UNIX seconds** under a fixed
 * key name.
 *
 * Why this exists: the wire form of a date is `{encoding, value}` and the
 * validated form was `{encoding, seconds}`. Two different shapes for the same
 * thing is how the scheduler ended up reading `.seconds` off an object that had
 * `.value`, producing `NaN` and silently disabling every freshness check. After
 * this function there is exactly one shape, the unit is always seconds since
 * 1970, and `dateToUnixSeconds` is the only converter.
 *
 * The original encoding is retained as `sourceEncoding` for diagnostics; it is
 * never used for arithmetic.
 */
function normalizeStateDates(state) {
  const rootSource = state.quoteSourceTime;
  const primarySource = state.primary.quoteSourceTime;
  const rootStale = state.staleDate;
  return {
    ...state,
    quoteSourceTimeUnix: dateToUnixSeconds(rootSource),
    quoteSourceTimeEncoding: rootSource.encoding,
    staleDateUnix: dateToUnixSeconds(rootStale),
    staleDateEncoding: rootStale.encoding,
    primary: {
      ...state.primary,
      quoteSourceTimeUnix: dateToUnixSeconds(primarySource),
      quoteSourceTimeEncoding: primarySource.encoding,
    },
  };
}

/**
 * The single normalization entry point for a validated state.
 *
 * `validateState` returns the raw checked shape; every consumer must pass it
 * through here so the UNIX-seconds keys exist. The delivery engine and the
 * scheduler both assert on `Number.isInteger(...Unix)` rather than trusting
 * that this was called.
 */
function normalizeValidatedState(validated) {
  return normalizeStateDates(validated);
}

// ---------------------------------------------------------------------------
// PulseActivityAttributes
// ---------------------------------------------------------------------------

function validateDestination(value, label = 'attributes.destination') {
  if (!isPlainObject(value)) return fail('not-an-object', label);
  const keys = Object.keys(value);
  if (keys.length !== 1) return fail('bad-union-shape', label);
  const tag = keys[0];
  if (tag === 'instrumentDetail') {
    const inner = value.instrumentDetail;
    if (!isPlainObject(inner)) return fail('not-an-object', `${label}.instrumentDetail`);
    const symbolKey = checkString(inner.symbolKey, `${label}.instrumentDetail.symbolKey`, {
      min: 1, max: 32, pattern: SYMBOL_KEY_PATTERN,
    });
    if (!symbolKey.ok) return symbolKey;
    return { ok: true, value: { kind: 'instrumentDetail', symbolKey: symbolKey.value } };
  }
  if (tag === 'plans') {
    const inner = value.plans;
    if (!isPlainObject(inner) || !('planID' in inner)) return fail('not-an-object', `${label}.plans`);
    const planID = checkString(inner.planID, `${label}.plans.planID`, { min: 1, max: 64, allowNull: true });
    if (!planID.ok) return planID;
    return { ok: true, value: { kind: 'plans', planID: planID.value ?? null } };
  }
  if (tag === 'planInbox') {
    const inner = value.planInbox;
    if (!isPlainObject(inner) || Object.keys(inner).length !== 0) {
      return fail('bad-union-shape', `${label}.planInbox`);
    }
    return { ok: true, value: { kind: 'planInbox' } };
  }
  return fail('unknown-enum-case', label);
}

function validateAttributes(value, label = 'attributes') {
  if (!isPlainObject(value)) return fail('not-an-object', label);
  const symbolKey = checkString(value.symbolKey, `${label}.symbolKey`, { min: 1, max: 32, pattern: SYMBOL_KEY_PATTERN });
  if (!symbolKey.ok) return symbolKey;
  const destination = validateDestination(value.destination, `${label}.destination`);
  if (!destination.ok) return destination;
  return { ok: true, value: { symbolKey: symbolKey.value, destination: destination.value } };
}

// ---------------------------------------------------------------------------
// Token classification
// ---------------------------------------------------------------------------

/**
 * Token lengths Apple has used, in bytes.
 *
 * Non-nominal lengths are rejected: the ActivityKit `Data` is opaque, but a
 * 3-byte or 4 KB "token" is a client bug, and storing it would only produce an
 * opaque APNs rejection later.
 */
const PUSH_TO_START_TOKEN_BYTES = new Set([32, 44]);
const UPDATE_TOKEN_BYTES = new Set([32]);

function classifyToken(kind, byteLength) {
  if (kind === 'pushToStart') {
    return PUSH_TO_START_TOKEN_BYTES.has(byteLength)
      ? { ok: true }
      : fail('unexpected-token-length', `expected 32 or 44 bytes, got ${byteLength}`);
  }
  return UPDATE_TOKEN_BYTES.has(byteLength)
    ? { ok: true }
    : fail('unexpected-token-length', `expected 32 bytes, got ${byteLength}`);
}

// ---------------------------------------------------------------------------
// APNs payload assembly and size check
// ---------------------------------------------------------------------------

/**
 * Materializes the wire form of a `PulseActivityState` from a validated
 * template.
 *
 * The returned object **is** the APNs `content-state`, and the system decodes
 * it with `JSONDecoder`'s default strategies — a strategy the app cannot
 * override (Apple, "Starting and updating Live Activities with ActivityKit
 * push notifications"). Its `Date` fields are therefore written the way
 * Swift's default `JSONEncoder` writes them: seconds since 2001-01-01, under
 * the Swift property names. The UNIX-second mirrors (`quoteSourceTimeUnix`,
 * `staleDateUnix`) are kept alongside for service-side diagnostics; the native
 * decoder ignores unknown keys, and the two families can never be confused
 * because only one of them is named like a Swift `Date`.
 *
 * Only the quote clock is moved; every other field is passed through verbatim,
 * which is what makes the "no fabricated content" claim checkable in tests: the
 * service cannot invent a price because it never constructs one.
 */
function materializeState(template, { quoteSourceTimeUnix, staleDateUnix }) {
  // Both clocks must be real UNIX-second integers. A `null` or `NaN` here would
  // be serialized into `content-state` and reach the device as an undecodable
  // date, so this fails loudly instead of emitting a broken payload. Callers
  // always pass values derived from a normalized template.
  if (!Number.isInteger(quoteSourceTimeUnix)) {
    throw new TypeError('materializeState requires an integer quoteSourceTimeUnix in UNIX seconds');
  }
  if (!Number.isInteger(staleDateUnix)) {
    throw new TypeError('materializeState requires an integer staleDateUnix in UNIX seconds');
  }
  // The source instant is converted, never moved: subtracting the 2001
  // reference offset is a change of unit, not of time.
  const quoteSourceTimeRef = unixSecondsToAppleReference(quoteSourceTimeUnix);
  return {
    primary: {
      symbolKey: template.primary.symbolKey,
      displayName: template.primary.displayName,
      identityText: template.primary.identityText,
      currencyCode: template.primary.currencyCode,
      ...(template.primary.unit === undefined ? {} : { unit: template.primary.unit }),
      price: template.primary.price,
      change: template.primary.change,
      changePercent: template.primary.changePercent,
      quoteSourceTime: quoteSourceTimeRef,
      quoteSourceTimeUnix,
      sourceDelay: template.primary.sourceDelay,
      marketPhase: template.primary.marketPhase,
    },
    plans: wirePlanDigest(template.plans),
    status: template.status,
    staleDate: unixSecondsToAppleReference(staleDateUnix),
    staleDateUnix,
    quoteSourceTime: quoteSourceTimeRef,
    quoteSourceTimeUnix,
    sessionID: template.sessionID,
  };
}

/**
 * The wire form of `PulseActivityPlanDigest`.
 *
 * The stored template carries the plan clock in service form (a tagged input
 * date plus `asOfUnix`/`asOfEncoding` mirrors); none of that is decodable as a
 * Swift `Date`, so the wire form re-emits `asOf` as a bare number of
 * 2001-reference seconds. Counts are copied untouched, `syncState` passes
 * through when present, and a digest without plan-clock metadata stays exactly
 * the three counts — the shape a pre-metadata client already decodes.
 */
function wirePlanDigest(plans) {
  const out = {
    priceConditionReachedCount: plans.priceConditionReachedCount,
    manualReviewCount: plans.manualReviewCount,
    remainingPlanCount: plans.remainingPlanCount,
  };
  if (Number.isInteger(plans.asOfUnix)) {
    out.asOf = unixSecondsToAppleReference(plans.asOfUnix);
  }
  if (plans.syncState !== undefined && plans.syncState !== null) {
    out.syncState = plans.syncState;
  }
  if (plans.revision !== undefined && plans.revision !== null) out.revision = plans.revision;
  return out;
}

/**
 * Builds the APNs `aps` dictionary.
 *
 * Shape (Live Activity update):
 *
 *   { "aps": { "timestamp": <unix s>, "event": "update",
 *              "content-state": <PulseActivityState>,
 *              "stale-date": <unix s>, "relevance-score": <n> } }
 *
 * `timestamp` and `stale-date` are UNIX seconds — they are consumed by APNs
 * itself, not by the activity's `Codable` state. The `Date` fields *inside*
 * `content-state` are written by `materializeState` as seconds since
 * 2001-01-01 under the Swift property names, because the system decodes
 * `content-state` with `JSONDecoder`'s default strategies and there is no
 * way — not even app-side — to make it use `.secondsSince1970` for a push.
 * See `docs/NATIVE_WIRE.md`.
 */
function buildApsDictionary(state, { event, nowUnix, staleDateUnix, relevanceScore = 0 }) {
  const aps = {
    timestamp: nowUnix,
    event,
    'content-state': state,
  };
  if (staleDateUnix !== null && staleDateUnix !== undefined) {
    aps['stale-date'] = staleDateUnix;
  }
  if (typeof relevanceScore === 'number' && Number.isFinite(relevanceScore)) {
    aps['relevance-score'] = Math.max(0, Math.min(100, relevanceScore));
  }
  return { aps };
}

/** The four mandatory Live Activity keys, checked before a byte is sent. */
function checkApsShape(apsDictionary) {
  const aps = apsDictionary && apsDictionary.aps;
  if (!isPlainObject(aps)) return fail('missing-aps');
  for (const key of ['timestamp', 'event', 'content-state']) {
    if (!(key in aps)) return fail('missing-aps-key', key);
  }
  if (!Number.isInteger(aps.timestamp)) return fail('aps-timestamp-not-integer-seconds');
  if (!['start', 'update', 'end'].includes(aps.event)) return fail('bad-aps-event', aps.event);
  if (!isPlainObject(aps['content-state'])) return fail('aps-content-state-not-an-object');
  if ('stale-date' in aps && !Number.isInteger(aps['stale-date'])) {
    return fail('aps-stale-date-not-integer-seconds');
  }
  // The system decodes `content-state` with `JSONDecoder`'s default strategies,
  // so each Swift `Date` property must be present as a plain finite number
  // (2001-reference seconds). A missing or mistyped one makes the whole update
  // undecodable on the device — exactly the failure this check catches before
  // a byte is sent.
  const contentState = aps['content-state'];
  const dateFields = [
    ['content-state.quoteSourceTime', contentState.quoteSourceTime],
    ['content-state.staleDate', contentState.staleDate],
    ['content-state.primary.quoteSourceTime',
      isPlainObject(contentState.primary) ? contentState.primary.quoteSourceTime : undefined],
  ];
  if (isPlainObject(contentState.plans) && contentState.plans.asOf !== undefined && contentState.plans.asOf !== null) {
    dateFields.push(['content-state.plans.asOf', contentState.plans.asOf]);
  }
  for (const [label, value] of dateFields) {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      return fail('aps-content-state-date-not-a-number', label);
    }
  }
  return { ok: true };
}

/** Enforces the 4 KB APNs budget on the serialized dictionary. */
function checkPayloadBudget(apsDictionary, maxBytes = MAX_PAYLOAD_BYTES) {
  const serialized = JSON.stringify(apsDictionary);
  const bytes = utf8Length(serialized);
  if (bytes > maxBytes) return fail('payload-too-large', `${bytes} > ${maxBytes}`);
  return { ok: true, bytes };
}

module.exports = {
  ACTIVITY_ID_PATTERN,
  ACTIVITY_STATUSES,
  MARKET_PHASES,
  MAX_PAYLOAD_BYTES,
  PLAN_SYNC_STATES,
  POINTS_CURRENCY_CODE,
  PUSHABLE_STATUSES,
  buildApsDictionary,
  checkApsShape,
  checkPayloadBudget,
  classifyToken,
  dateToUnixSeconds,
  materializeState,
  unixSeconds,
  validateAttributes,
  validateDestination,
  validateInstrument,
  validatePlanDigest,
  validateState,
};
