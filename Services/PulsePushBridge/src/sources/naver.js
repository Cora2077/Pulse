'use strict';

/**
 * Naver Finance (`polling.finance.naver.com`) — Korea, delay 0.
 *
 * Mirrors `NaverProvider` in Core: the code Naver knows a stock by is its bare
 * six-digit code, never a board, and indices answer on a *different path* from
 * stocks, so the two are never mixed in one request.
 *
 * The timestamp is Naver's own `localTradedAt`, an ISO-8601 string that carries
 * its `+09:00` offset. That offset is parsed as written; the market's declared
 * zone is metadata about the venue, not a licence to re-interpret the instant. A
 * row without a usable stamp is `source-invalid` — never "now".
 */

const { QuoteUnavailableError } = require('../quote-source');
const { assertSafeCode, createHttpClient } = require('./http');
const { ZONE_OFFSETS, parseIsoWithOffset, requireSourceTime } = require('./time');
const { UNKNOWN_PHASE, marketPhaseFor } = require('./session');

const HOST = 'polling.finance.naver.com';
const MARKET = 'KR';
const CURRENCY = 'KRW';
const MAX_BYTES = 256 * 1024;
const TIMEOUT_MS = 5_000;

/** Naver refuses requests without a finance referer. */
const HEADERS = Object.freeze({
  Referer: 'https://finance.naver.com/',
  'User-Agent': 'Mozilla/5.0',
});

/** `005930.KS`, `000660.KQ`, and the composite. */
const KOREA_SYMBOL = /^(\d{6})\.(KS|KQ)$/;
const KOSPI_SYMBOL = /^KOSPI\.KS$/;

/** The only index Naver's index path is asked for. */
const INDEX_WIRE_NAMES = Object.freeze({ 'KOSPI.KS': 'KOSPI' });

/** The stock and index paths are distinct; a request never mixes them. */
const STOCK_PATH = 'stock';
const INDEX_PATH = 'index';

/**
 * Maps a `SymbolID.description` form to Naver's path segment, or null when Naver
 * is not the source for it.
 *
 * @returns {{ wire: string, kind: 'stock'|'index' }|null}
 */
function naverCodeFor(symbolKey) {
  if (typeof symbolKey !== 'string') return null;
  if (KOSPI_SYMBOL.test(symbolKey)) return { wire: INDEX_WIRE_NAMES[symbolKey], kind: 'index' };
  const match = KOREA_SYMBOL.exec(symbolKey);
  if (!match) return null;
  const code = match[1];
  // Six ASCII digits, already guaranteed by the regex; the safety pass below is
  // what keeps a future regex edit from reaching the URL builder.
  const wire = assertSafeCode(code, { pattern: /^\d{6}$/, maxLength: 6, label: 'naver code' });
  return { wire, kind: 'stock' };
}

function requestPath({ wire, kind }) {
  const segment = kind === 'index' ? INDEX_PATH : STOCK_PATH;
  return `/api/realtime/domestic/${segment}/${wire}`;
}

/**
 * Naver mixes JSON numbers and their string spellings across payloads — the same
 * field is `268500` on one endpoint and `"268,500"` on another.
 *
 * @returns {number|null}
 */
function readNumber(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') {
    const text = value.replace(/,/g, '').trim();
    if (text.length === 0) return null;
    const parsed = Number(text);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** `…Raw` is preferred, exactly as the Swift row accessors do. */
function readRawFirst(row, rawField, formattedField) {
  const raw = readNumber(row[rawField]);
  if (raw !== null) return raw;
  return readNumber(row[formattedField]);
}

/**
 * One row into a quote.
 *
 * @returns {object} a quote satisfying `assertQuoteShape`
 * @throws {QuoteUnavailableError}
 */
function parseRow(row, { symbolKey }) {
  if (!row || typeof row !== 'object') {
    throw new QuoteUnavailableError('source-invalid', 'naver: row is not an object');
  }
  const price = readRawFirst(row, 'closePriceRaw', 'closePrice');
  if (price === null || !Number.isFinite(price) || price <= 0) {
    throw new QuoteUnavailableError('source-invalid', `naver: unusable price for ${symbolKey}`);
  }
  const change = readRawFirst(row, 'compareToPreviousClosePriceRaw', 'compareToPreviousClosePrice') ?? 0;
  // Naver reports the move, and signs it: a decline arrives negative rather than
  // as a direction flag.
  const previousClose = price - change;
  const changePercent = previousClose > 0 ? (change / previousClose) * 100 : null;

  const name = typeof row.stockName === 'string' ? row.stockName.trim() : '';
  const quoteSourceTimeUnix = requireSourceTime(parseIsoWithOffset(row.localTradedAt), {
    label: 'naver',
    field: 'localTradedAt',
  });

  return {
    symbolKey,
    name: name.length > 0 ? name : null,
    price,
    previousClose: previousClose > 0 ? previousClose : null,
    change,
    changePercent,
    currencyCode: CURRENCY,
    quoteSourceTimeUnix,
    sourceDelay: 0,
    marketPhase: phaseForRow(row, quoteSourceTimeUnix),
    timeZoneOffsetSeconds: ZONE_OFFSETS['Asia/Seoul'],
  };
}

/**
 * The phase to publish for one row.
 *
 * Naver's own `marketStatus` is preferred, but only for the one value this build
 * has evidence for: `OPEN`. The fixture in Core's tests carries it, and it is the
 * venue's own statement that the session was live. Every other spelling —
 * `CLOSE`, `PRE_MARKET`, a future value, or a missing field — falls through to
 * the session table for the row's own timestamp, and to `unknown` if even that
 * cannot be resolved.
 *
 * Only `OPEN` is trusted because guessing the rest is exactly the failure this
 * exists to prevent: an unrecognised status answered as `closed` would widen the
 * freshness window to 24 hours and present a stale price as a valid one. Falling
 * back to the session table narrows the window instead of widening it, which is
 * the safe direction to be wrong in.
 *
 * @param {object} row
 * @param {number} quoteSourceTimeUnix the row's own stamp
 * @returns {string}
 */
function phaseForRow(row, quoteSourceTimeUnix) {
  if (typeof row.marketStatus === 'string' && row.marketStatus.trim().toUpperCase() === 'OPEN') {
    return 'regular';
  }
  return marketPhaseFor(MARKET, quoteSourceTimeUnix) ?? UNKNOWN_PHASE;
}

/**
 * Parses a Naver realtime payload.
 *
 * @param {Buffer|string} body
 * @param {{ symbolKey: string, wireCode: string }} context
 * @returns {object} the quote
 * @throws {QuoteUnavailableError} `unsupported-market` when the endpoint knows no
 *   such code (it answers 200 with an empty `datas` array), `source-invalid`
 *   otherwise
 */
function parseQuoteBody(body, { symbolKey, wireCode }) {
  let payload;
  try {
    payload = JSON.parse(typeof body === 'string' ? body : body.toString('utf8'));
  } catch {
    throw new QuoteUnavailableError('source-invalid', 'naver: response is not JSON');
  }
  const rows = payload && Array.isArray(payload.datas) ? payload.datas : null;
  if (rows === null) {
    throw new QuoteUnavailableError('source-invalid', 'naver: response has no datas array');
  }
  const wanted = wireCode.toUpperCase();
  const row = rows.find((candidate) => (
    candidate && typeof candidate.itemCode === 'string' && candidate.itemCode.toUpperCase() === wanted
  ));
  if (!row) {
    throw new QuoteUnavailableError('unsupported-market', `naver: no quote for ${symbolKey}`);
  }
  if (Array.isArray(row.datas) && row.datas.length > 0) {
    // Defensive: a nested list is a different payload than the one modeled here.
    return parseRow(row.datas[0], { symbolKey });
  }
  return parseRow(row, { symbolKey });
}

/**
 * The Naver adapter. Constructing it performs no I/O; `refresh()` makes the one
 * request, and only for a symbol this module accepts.
 */
class NaverSource {
  constructor({ fetchImpl, now, http = null, timeoutMs = TIMEOUT_MS, maxBytes = MAX_BYTES } = {}) {
    this.id = 'naver';
    this.host = HOST;
    this.market = MARKET;
    this.symbolPattern = /^\d{6}\.(KS|KQ)$/;
    this.http = http ?? createHttpClient({
      host: HOST,
      fetchImpl,
      now,
      timeoutMs,
      maxBytes,
      label: 'naver',
    });
  }

  /** Markets this adapter can quote. Consulted by `PublicQuoteSource`. */
  supportedMarkets() {
    return [MARKET];
  }

  isRefreshable(symbolKey) {
    return naverCodeFor(symbolKey) !== null;
  }

  async refresh(symbolKey) {
    const mapping = naverCodeFor(symbolKey);
    if (!mapping) {
      throw new QuoteUnavailableError('unsupported-market', `naver cannot quote ${symbolKey}`);
    }
    const path = requestPath(mapping);
    const response = await this.http.request(path, { headers: HEADERS, notFoundReason: 'unsupported-market' });
    const quote = parseQuoteBody(response.bytes, { symbolKey, wireCode: mapping.wire });
    quote.sourceID = this.id;
    return quote;
  }
}

module.exports = {
  HEADERS,
  HOST,
  NaverSource,
  naverCodeFor,
  parseQuoteBody,
  parseRow,
  readNumber,
  readRawFirst,
  requestPath,
};
