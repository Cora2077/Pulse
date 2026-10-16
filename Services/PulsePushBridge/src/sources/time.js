'use strict';

/**
 * Timestamps and text decoding shared by the adapters.
 *
 * Two rules are enforced for every source:
 *
 *   1. A wall-clock string is only ever interpreted in the exchange's own zone,
 *      and only when it round-trips exactly. A lenient parse would accept
 *      `2025-13-45`, and a `Date.now()` fallback would let the service present
 *      an old number as a live one, so neither exists here.
 *   2. There is no "now" parameter. An adapter that cannot read a source
 *      timestamp reports `source-invalid`; it never substitutes a clock.
 */

const { QuoteUnavailableError } = require('../quote-source');

/** Fixed offsets. The source strings carry their own zone; these are the zones. */
const ZONE_OFFSETS = {
  'Asia/Seoul': 9 * 3600,
  'Asia/Shanghai': 8 * 3600,
  'Asia/Hong_Kong': 8 * 3600,
};

/**
 * The US board is the one zone in this module whose offset is not a constant,
 * because `Market.us.timeZone` is `America/New_York`, which observes daylight
 * saving time. Tencent's US rows carry the exchange's local wall clock
 * (`2026/07/20 16:00:01`), so reading that clock needs the offset that was in
 * force *on that date*: a flat `-5 * 3600` would put every summer close an hour
 * in the future, which is the kind of quiet error this module exists to refuse.
 *
 * The offset is read from `Intl`, which ships the same IANA database Foundation
 * uses on the Swift side, so the two implementations agree for every date either
 * covers. Nothing here reads the process clock: the offset is a function of the
 * instant being converted, so a test on any machine gets the same answer.
 */
const NEW_YORK_PARTS = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York',
  hour12: false,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
});

function newYorkPartsAt(instantMs) {
  const parts = NEW_YORK_PARTS.formatToParts(new Date(instantMs));
  const read = (type) => {
    const piece = parts.find((candidate) => candidate.type === type);
    return piece ? Number(piece.value) : Number.NaN;
  };
  return {
    year: read('year'),
    month: read('month'),
    day: read('day'),
    hour: read('hour') % 24,
    minute: read('minute'),
    second: read('second'),
  };
}

/** The `America/New_York` offset, in seconds, in force at an instant. */
function newYorkOffsetAtInstant(instantMs) {
  const local = newYorkPartsAt(instantMs);
  if (!Number.isInteger(local.year) || !Number.isInteger(local.month) || !Number.isInteger(local.day)) return null;
  const asIfUtcMs = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute, local.second);
  return (asIfUtcMs - instantMs) / 1000;
}

/**
 * Converts an `America/New_York` wall-clock reading to UNIX seconds.
 *
 * Two passes, because the offset that applies to the guess is not necessarily
 * the one that applies to the answer: in the hour after a spring-forward the
 * first guess lands an hour off. The second pass is then verified by reading the
 * resolved instant back in the zone, so a wall clock that does not exist (the
 * hour a spring transition skips) resolves to the instant it would have had —
 * the same reading Foundation gives it — rather than to something arbitrary.
 *
 * @returns {number|null} integer UNIX seconds, or null when the fields are not a
 *   real calendar instant
 */
function unixFromNewYorkParts(year, month, day, hour, minute, second) {
  for (const value of [year, month, day, hour, minute, second]) {
    if (!Number.isInteger(value)) return null;
  }
  if (year < 1970 || year > 2200) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > daysInMonth(year, month)) return null;
  if (hour < 0 || hour > 23) return null;
  if (minute < 0 || minute > 59) return null;
  if (second < 0 || second > 60) return null;

  const asIfUtcMs = Date.UTC(year, month - 1, day, hour, minute, second);
  let offset = newYorkOffsetAtInstant(asIfUtcMs);
  if (offset === null) return null;
  let instantMs = asIfUtcMs - offset * 1000;
  const refined = newYorkOffsetAtInstant(instantMs);
  if (refined !== null && refined !== offset) {
    offset = refined;
    instantMs = asIfUtcMs - offset * 1000;
  }
  const seconds = Math.floor(instantMs / 1000);
  return Number.isSafeInteger(seconds) ? seconds : null;
}

const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

function isLeapYear(year) {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

function daysInMonth(year, month) {
  if (month === 2 && isLeapYear(year)) return 29;
  return DAYS_IN_MONTH[month - 1] ?? 0;
}

/**
 * A calendar instant validated field by field, then converted to UNIX seconds
 * with an explicit offset. `Date.UTC` is not used: it remaps years 0–99 into the
 * twentieth century, which is exactly the kind of silent reinterpretation this
 * module exists to prevent.
 *
 * @returns {number|null} integer UNIX seconds, or null when the fields are not a
 *   real calendar instant
 */
function unixFromParts(year, month, day, hour, minute, second, offsetSeconds) {
  for (const value of [year, month, day, hour, minute, second, offsetSeconds]) {
    if (!Number.isInteger(value)) return null;
  }
  if (year < 1970 || year > 2200) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > daysInMonth(year, month)) return null;
  if (hour < 0 || hour > 23) return null;
  if (minute < 0 || minute > 59) return null;
  if (second < 0 || second > 60) return null;

  const epochDays = daysFromCivil(year, month, day);
  const seconds = epochDays * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds;
  return Number.isSafeInteger(seconds) ? seconds : null;
}

/** Howard Hinnant's `days_from_civil`; exact for the proleptic Gregorian calendar. */
function daysFromCivil(year, month, day) {
  const y = month <= 2 ? year - 1 : year;
  const era = Math.floor(y / 400);
  const yoe = y - era * 400;
  const doy = Math.floor((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146_097 + doe - 719_468;
}

/**
 * Parses `yyyy-MM-dd HH:mm:ss` (a trailing sub-second part is not accepted; only
 * the first two space-separated tokens are considered, mirroring the Swift
 * `parseTimestamp`) in a fixed-offset zone.
 *
 * @returns {number|null}
 */
function parseDateSpaceTime(raw, offsetSeconds) {
  if (typeof raw !== 'string') return null;
  const tokens = raw.trim().split(/\s+/).filter((token) => token.length > 0);
  if (tokens.length < 2) return null;
  const [datePart, timePart] = tokens;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(datePart) || !/^\d{2}:\d{2}:\d{2}$/.test(timePart)) return null;
  const [year, month, day] = datePart.split('-').map(Number);
  const [hour, minute, second] = timePart.split(':').map(Number);
  return unixFromParts(year, month, day, hour, minute, second, offsetSeconds);
}

/** Parses `yyyyMMddHHmmss` in a fixed-offset zone. @returns {number|null} */
function parseCompactDateTime(raw, offsetSeconds) {
  if (typeof raw !== 'string' || !/^\d{14}$/.test(raw)) return null;
  return unixFromParts(
    Number(raw.slice(0, 4)),
    Number(raw.slice(4, 6)),
    Number(raw.slice(6, 8)),
    Number(raw.slice(8, 10)),
    Number(raw.slice(10, 12)),
    Number(raw.slice(12, 14)),
    offsetSeconds,
  );
}

/** Parses `yyyy/MM/dd HH:mm:ss` in a fixed-offset zone. @returns {number|null} */
function parseSlashDateTime(raw, offsetSeconds) {
  if (typeof raw !== 'string') return null;
  const tokens = raw.trim().split(/\s+/).filter((token) => token.length > 0);
  if (tokens.length < 2) return null;
  const [datePart, timePart] = tokens;
  if (!/^\d{4}\/\d{2}\/\d{2}$/.test(datePart) || !/^\d{2}:\d{2}:\d{2}$/.test(timePart)) return null;
  const [year, month, day] = datePart.split('/').map(Number);
  const [hour, minute, second] = timePart.split(':').map(Number);
  return unixFromParts(year, month, day, hour, minute, second, offsetSeconds);
}

/**
 * Parses a wall-clock string in `America/New_York`, in either spelling Tencent
 * uses for a US row: `yyyy/MM/dd HH:mm:ss` or `yyyy-MM-dd HH:mm:ss`.
 *
 * Mirrors `TencentProvider.parseTimestamp`, whose third format
 * (`yyyyMMddHHmmss`) is handled by `parseCompactDateTime` and is not accepted
 * here: only the two date-space-time spellings reach the US board.
 *
 * @returns {number|null}
 */
function parseNewYorkDateTime(raw) {
  if (typeof raw !== 'string') return null;
  const tokens = raw.trim().split(/\s+/).filter((token) => token.length > 0);
  if (tokens.length < 2) return null;
  const [datePart, timePart] = tokens;
  let fields;
  if (/^\d{4}-\d{2}-\d{2}$/.test(datePart)) fields = datePart.split('-').map(Number);
  else if (/^\d{4}\/\d{2}\/\d{2}$/.test(datePart)) fields = datePart.split('/').map(Number);
  else return null;
  if (!/^\d{2}:\d{2}:\d{2}$/.test(timePart)) return null;
  const [hour, minute, second] = timePart.split(':').map(Number);
  return unixFromNewYorkParts(fields[0], fields[1], fields[2], hour, minute, second);
}

/**
 * Naver's `localTradedAt`, e.g. `2026-08-20T12:12:37.828638+09:00`, sometimes
 * without the fraction. The offset is part of the string and is read as given —
 * it is never re-interpreted through the market's declared zone, and the
 * `Z`-suffixed form is accepted as UTC.
 *
 * @returns {number|null}
 */
function parseIsoWithOffset(raw) {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (text.length === 0) return null;

  // Drop a fractional-seconds run of any length: the source varies its width,
  // which is more than a fixed format can accept.
  const withoutFraction = text.replace(/\.\d+/, '');
  const match = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(Z|[+-]\d{2}:\d{2})?$/.exec(withoutFraction);
  if (!match) return null;

  const [, year, month, day, hour, minute, second, zone] = match;
  let offsetSeconds = 0;
  if (zone && zone !== 'Z') {
    const sign = zone[0] === '-' ? -1 : 1;
    offsetSeconds = sign * (Number(zone.slice(1, 3)) * 3600 + Number(zone.slice(4, 6)) * 60);
  }
  return unixFromParts(
    Number(year), Number(month), Number(day),
    Number(hour), Number(minute), Number(second),
    offsetSeconds,
  );
}

/**
 * Section 2.1 of `Hong Kong Supplementary Character Set`-era GBK and the
 * GB18030 ranges that follow it. Only ranges are consulted: the full mapping
 * table would be a megabyte of data for names this service merely passes
 * through, so anything outside the ranges is reported as undecodable rather than
 * guessed at. A wrong price is impossible here — only names travel this path —
 * but a mojibake name is still a lie, so it is refused.
 */
const GBK_RANGES = [
  [0x81, 0xfe, 0x40, 0x7e],
  [0x81, 0xfe, 0x80, 0xfe],
];

/** True when `bytes` is entirely representable in GBK/GB18030 two-byte form. */
function isGbkRepresentable(bytes) {
  let index = 0;
  while (index < bytes.length) {
    const byte = bytes[index];
    if (byte <= 0x7f) {
      index += 1;
      continue;
    }
    if (index + 1 >= bytes.length) return false;
    const trail = bytes[index + 1];
    const inRange = GBK_RANGES.some(([leadLow, leadHigh, trailLow, trailHigh]) => (
      byte >= leadLow && byte <= leadHigh && trail >= trailLow && trail <= trailHigh
    ));
    if (!inRange) return false;
    index += 2;
  }
  return true;
}

let gb18030Decoder = null;
let gb18030Probed = false;

/**
 * A GB18030 decoder, or null when this Node build has no such ICU converter
 * (a small-icu build, or a future Node that drops legacy converters).
 *
 * This is the one place a non-pure-Node facility is used, via the standard
 * `TextDecoder` API. It is a *decode*, not a dependency: no network call, no
 * account, and a process-wide capability probe. Callers must treat null as
 * "cannot decode non-ASCII" and say so, never as "decode as Latin-1".
 */
function gb18030() {
  if (gb18030Probed) return gb18030Decoder;
  gb18030Probed = true;
  try {
    const decoder = new TextDecoder('gb18030', { fatal: false });
    // Probe one known sequence (银行) so a decoder that silently reports the
    // wrong encoding is not trusted.
    gb18030Decoder = decoder.decode(Uint8Array.from([0xd2, 0xf8, 0xd0, 0xd0])) === '银行' ? decoder : null;
  } catch {
    gb18030Decoder = null;
  }
  return gb18030Decoder;
}

/** Whether this process can decode GB18030 text at all. Exported for the tests. */
function canDecodeGB18030() {
  return gb18030() !== null;
}

/**
 * Decodes a source body.
 *
 * Order is the caller's: Tencent answers GBK first with UTF-8 as the fallback,
 * THS the other way round. A body that is valid UTF-8 is always taken as UTF-8 —
 * multibyte UTF-8 can never be valid GBK, so the two cannot be confused.
 *
 * @param {Buffer} bytes
 * @param {{ prefer?: 'utf8'|'gb18030' }} [options]
 * @returns {{ text: string|null, encoding: 'utf-8'|'gb18030'|null, undecodable: boolean }}
 */
function decodeBody(bytes, { prefer = 'utf8' } = {}) {
  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes ?? []);
  const utf8 = tryUtf8(buffer);
  const gbk = tryGb18030(buffer);

  if (prefer === 'gb18030') {
    if (gbk !== null) return { text: gbk, encoding: 'gb18030', undecodable: false };
    if (utf8 !== null) return { text: utf8, encoding: 'utf-8', undecodable: false };
  } else {
    if (utf8 !== null) return { text: utf8, encoding: 'utf-8', undecodable: false };
    if (gbk !== null) return { text: gbk, encoding: 'gb18030', undecodable: false };
  }
  return { text: null, encoding: null, undecodable: true };
}

function tryUtf8(buffer) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch {
    return null;
  }
}

function tryGb18030(buffer) {
  const decoder = gb18030();
  if (decoder === null) return null;
  // A body whose bytes are outside the GBK ranges is not GBK: ICU would replace
  // them with U+FFFD, which is a fabricated name rather than a decoded one.
  if (!isGbkRepresentable(buffer)) return null;
  const text = decoder.decode(buffer);
  return text.includes('\uFFFD') ? null : text;
}

/** Throws `source-invalid` when no usable timestamp could be read. */
function requireSourceTime(unixSeconds, { label = 'quote', field = 'timestamp' } = {}) {
  if (!Number.isInteger(unixSeconds) || unixSeconds <= 0) {
    throw new QuoteUnavailableError('source-invalid', `${label}: ${field} is missing or unparseable`);
  }
  return unixSeconds;
}

module.exports = {
  ZONE_OFFSETS,
  canDecodeGB18030,
  daysFromCivil,
  decodeBody,
  isGbkRepresentable,
  newYorkOffsetAtInstant,
  parseCompactDateTime,
  parseDateSpaceTime,
  parseIsoWithOffset,
  parseNewYorkDateTime,
  parseSlashDateTime,
  requireSourceTime,
  unixFromNewYorkParts,
  unixFromParts,
};
