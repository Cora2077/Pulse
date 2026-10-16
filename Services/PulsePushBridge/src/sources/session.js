'use strict';

/**
 * The market phase a *source timestamp* implies.
 *
 * Every adapter used to answer `marketPhase: 'regular'` unconditionally. That is
 * a claim, not an observation: a quote stamped at 03:00 Seoul time or on a
 * Saturday would have been reported as "trading", and the freshness policy would
 * then have treated it as a live price for five minutes. `PulseMarketPhase` is
 * what the lock screen prints, so this module exists so the answer comes from
 * the source's own timestamp instead of from an assumption.
 *
 * Two rules shape it:
 *
 *   1. **The phase is a function of the source's timestamp only.** No adapter
 *      passes a clock here. A quote is labelled by when the *source* says it was
 *      struck, which is the same instant `quoteSourceTimeUnix` carries, so the
 *      phase can never disagree with the time it is attached to.
 *   2. **Nothing is claimed beyond the wall clock.** This module reads the
 *      exchange's session in its own zone. It does not know about holidays, half
 *      days or exchange-specific closures, so a timestamp inside a session on a
 *      holiday reads `regular` — the source would not have produced a fresh
 *      quote for one, and an out-of-session timestamp reads `closed` rather than
 *      being guessed at. Where a source reports its own status (Naver's
 *      `marketStatus`) that value is preferred; this module is the fallback.
 *
 * The US zone is DST-observing, so its offset is resolved per timestamp through
 * the same `Intl` path `time.js` uses; the three Asian zones are fixed offsets.
 */

const { newYorkOffsetAtInstant } = require('./time');

const SECOND = 1;
const MINUTE = 60;
const HOUR = 3_600;

/** `[openSecondsOfDay, closeSecondsOfDay)` for each continuous session. */
const SESSIONS = Object.freeze({
  // Korea Exchange: 09:00–15:30 KST, no midday break.
  KR: Object.freeze({
    zoneOffset: 9 * HOUR,
    segments: Object.freeze([Object.freeze([9 * HOUR, 15 * HOUR + 30 * MINUTE])]),
  }),
  // Mainland A-shares: 09:30–11:30 and 13:00–15:00 CST.
  SH: Object.freeze({
    zoneOffset: 8 * HOUR,
    segments: Object.freeze([
      Object.freeze([9 * HOUR + 30 * MINUTE, 11 * HOUR + 30 * MINUTE]),
      Object.freeze([13 * HOUR, 15 * HOUR]),
    ]),
  }),
  SZ: Object.freeze({
    zoneOffset: 8 * HOUR,
    segments: Object.freeze([
      Object.freeze([9 * HOUR + 30 * MINUTE, 11 * HOUR + 30 * MINUTE]),
      Object.freeze([13 * HOUR, 15 * HOUR]),
    ]),
  }),
  // Hong Kong: 09:30–12:00 and 13:00–16:00 HKT.
  HK: Object.freeze({
    zoneOffset: 8 * HOUR,
    segments: Object.freeze([
      Object.freeze([9 * HOUR + 30 * MINUTE, 12 * HOUR]),
      Object.freeze([13 * HOUR, 16 * HOUR]),
    ]),
  }),
  // NYSE/Nasdaq: 09:30–16:00 ET, with the extended legs the sources do quote.
  US: Object.freeze({
    zoneOffset: null, // DST-observing; resolved per timestamp
    segments: Object.freeze([Object.freeze([9 * HOUR + 30 * MINUTE, 16 * HOUR])]),
    preMarket: Object.freeze([4 * HOUR, 9 * HOUR + 30 * MINUTE]),
    postMarket: Object.freeze([16 * HOUR, 20 * HOUR]),
    // The overnight leg wraps midnight, so it is tested as two ranges.
    overnight: Object.freeze([
      Object.freeze([20 * HOUR, 24 * HOUR]),
      Object.freeze([0, 4 * HOUR]),
    ]),
  }),
});

/** 1970-01-01 was a Thursday. */
const EPOCH_WEEKDAY = 4;

/**
 * Local wall-clock reading of an instant in a zone.
 *
 * @param {number} unixSeconds
 * @param {number|null} zoneOffset seconds east of UTC; null resolves `America/New_York`
 * @returns {{ weekday: number, secondsOfDay: number }|null}
 */
function localWallClock(unixSeconds, zoneOffset) {
  if (!Number.isInteger(unixSeconds) || unixSeconds <= 0) return null;
  let offset = zoneOffset;
  if (offset === null || offset === undefined) {
    offset = newYorkOffsetAtInstant(unixSeconds * 1000);
    if (offset === null) return null;
  }
  const local = unixSeconds + offset;
  const day = Math.floor(local / 86_400);
  const secondsOfDay = local - day * 86_400;
  if (!Number.isSafeInteger(day)) return null;
  // A negative `secondsOfDay` cannot occur because `Math.floor` was used.
  return { weekday: ((day % 7) + EPOCH_WEEKDAY) % 7, secondsOfDay };
}

function within(secondsOfDay, range) {
  return secondsOfDay >= range[0] && secondsOfDay < range[1];
}

/**
 * The phase implied by a source timestamp, or `null` when the market has no
 * session table here (which the caller must treat as "the source did not say").
 *
 * @param {string} market one of the keys of `SESSIONS`
 * @param {number} unixSeconds the source's own timestamp
 * @returns {'preMarket'|'regular'|'lunchBreak'|'postMarket'|'overnight'|'closed'|null}
 */
function marketPhaseFor(market, unixSeconds) {
  const session = SESSIONS[market];
  if (!session) return null;
  const clock = localWallClock(unixSeconds, session.zoneOffset);
  if (clock === null) return null;

  // Saturday and Sunday: the sources do not quote a session, so this is the one
  // calendar fact that can be read from the timestamp alone.
  if (clock.weekday === 0 || clock.weekday === 6) return 'closed';

  const { secondsOfDay } = clock;
  for (const segment of session.segments) {
    if (within(secondsOfDay, segment)) return 'regular';
  }
  if (session.segments.length > 1) {
    // A gap between two sessions is the midday break, not a closure.
    const first = session.segments[0];
    const last = session.segments[session.segments.length - 1];
    if (secondsOfDay >= first[1] && secondsOfDay < last[0]) return 'lunchBreak';
  }
  if (session.preMarket && within(secondsOfDay, session.preMarket)) return 'preMarket';
  if (session.postMarket && within(secondsOfDay, session.postMarket)) return 'postMarket';
  if (session.overnight && session.overnight.some((range) => within(secondsOfDay, range))) {
    return 'overnight';
  }
  return 'closed';
}

/**
 * The phase to publish for a market whose session table this module does not
 * carry. `unknown` is the honest answer: it widens the freshness window instead
 * of narrowing it, so a source that cannot date its own session is never
 * presented as live.
 */
const UNKNOWN_PHASE = 'unknown';

module.exports = {
  SESSIONS,
  UNKNOWN_PHASE,
  localWallClock,
  marketPhaseFor,
};
