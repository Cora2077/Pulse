'use strict';

/**
 * Tonghuashun industry boards (`d.10jqka.com.cn`).
 *
 * Mirrors `ThsSectorProvider`: the wire identity is the board code inside a
 * `bk_` prefix, the response is a JSONP envelope rather than JSON, and every
 * field is a string-or-number that has to be read tolerantly.
 *
 * The timestamp is Beijing time (+08:00) because that is the session the board
 * trades in, and it is parsed strictly: `2025-13-45` is not a date, and a row
 * without a usable stamp is `source-invalid` rather than "now".
 */

const { QuoteUnavailableError } = require('../quote-source');
const { assertSafeCode, createHttpClient } = require('./http');
const { ZONE_OFFSETS, decodeBody, parseDateSpaceTime, requireSourceTime } = require('./time');
const { marketPhaseFor } = require('./session');

const HOST = 'd.10jqka.com.cn';
const MARKET = 'SH';
const CURRENCY = 'CNY';
const MAX_BYTES = 256 * 1024;
const TIMEOUT_MS = 5_000;

/** `SectorIndexID.isValidWireCode`: exactly six characters, `88` prefix, all digits. */
const BOARD_SYMBOL = /^(88\d{4})\.SH$/;
const BOARD_CODE = /^88\d{4}$/;

const HEADERS = Object.freeze({ 'Cache-Control': 'no-cache' });

const SHANGHAI_OFFSET = ZONE_OFFSETS['Asia/Shanghai'];

/** `881155.SH` (银行) -> `881155`, or null when THS does not serve it. */
function boardCodeFor(symbolKey) {
  if (typeof symbolKey !== 'string') return null;
  const match = BOARD_SYMBOL.exec(symbolKey);
  if (!match) return null;
  return assertSafeCode(match[1], { pattern: BOARD_CODE, maxLength: 6, label: 'ths board code' });
}

function requestPath(code) {
  return `/v6/realhead/bk_${code}/defer/last.js`;
}

/**
 * Reads a JSONP envelope: the text between the FIRST `(` and the LAST `)`.
 *
 * @returns {string|null} the inner JSON text, or null when there is no envelope
 */
function extractJsonPayload(text) {
  if (typeof text !== 'string') return null;
  const start = text.indexOf('(');
  const end = text.lastIndexOf(')');
  if (start === -1 || end === -1 || start >= end) return null;
  const inner = text.slice(start + 1, end).trim();
  return inner.length === 0 ? null : inner;
}

/**
 * A tolerant field reader mirroring `ThsSectorProvider.FieldValue`: the value may
 * be a JSON string or a finite double, and both spell the same number.
 *
 * @returns {number|null}
 */
function fieldNumber(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') {
    const text = value.trim();
    if (text.length === 0) return null;
    const parsed = Number(text);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** `FieldValue.stringValue`: a double becomes its plain string form. */
function fieldString(value) {
  if (typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return null;
}

/**
 * Items into a quote. `10` is the price and `6` the previous close; both must be
 * positive, which is what makes a derived percent safe to compute.
 *
 * @throws {QuoteUnavailableError} `source-invalid`
 */
function parseItems(items, { symbolKey }) {
  if (!items || typeof items !== 'object' || Array.isArray(items)) {
    throw new QuoteUnavailableError('source-invalid', 'ths: payload has no items object');
  }
  const price = fieldNumber(items['10']);
  const previousClose = fieldNumber(items['6']);
  if (price === null || !Number.isFinite(price) || price <= 0) {
    throw new QuoteUnavailableError('source-invalid', `ths: unusable price for ${symbolKey}`);
  }
  if (previousClose === null || !Number.isFinite(previousClose) || previousClose <= 0) {
    throw new QuoteUnavailableError('source-invalid', `ths: unusable previous close for ${symbolKey}`);
  }
  const change = price - previousClose;
  const name = fieldString(items.name);

  const quoteSourceTimeUnix = requireSourceTime(
    parseDateSpaceTime(fieldString(items.time), SHANGHAI_OFFSET),
    { label: 'ths', field: 'items.time' },
  );

  return {
    symbolKey,
    name: typeof name === 'string' && name.trim().length > 0 ? name.trim() : null,
    price,
    previousClose,
    change,
    changePercent: (change / previousClose) * 100,
    currencyCode: CURRENCY,
    quoteSourceTimeUnix,
    sourceDelay: 0,
    marketPhase: marketPhaseFor(MARKET, quoteSourceTimeUnix),
    timeZoneOffsetSeconds: SHANGHAI_OFFSET,
  };
}

/**
 * Decodes and parses a THS board response.
 *
 * Mirroring `jsonPayload(from:)`, UTF-8 is tried first and GB18030 second.
 *
 * @param {Buffer} bytes
 * @param {{ symbolKey: string, code: string }} context
 * @returns {object} the quote
 */
function parseQuoteBody(bytes, { symbolKey, code }) {
  const decoded = decodeBody(bytes, { prefer: 'utf8' });
  if (decoded.text === null) {
    throw new QuoteUnavailableError('source-invalid', 'ths: undecodable response body');
  }
  const inner = extractJsonPayload(decoded.text);
  if (inner === null) {
    throw new QuoteUnavailableError('source-invalid', 'ths: invalid JSONP envelope');
  }
  let payload;
  try {
    payload = JSON.parse(inner);
  } catch {
    throw new QuoteUnavailableError('source-invalid', 'ths: JSONP payload is not JSON');
  }
  const items = payload && typeof payload === 'object' ? payload.items : undefined;
  // An endpoint that answers with no items at all does not know the board; a
  // board code already validated as a real wire code cannot be a path error.
  if (!items || typeof items !== 'object' || Object.keys(items).length === 0) {
    throw new QuoteUnavailableError('unsupported-market', `ths: no fields for ${symbolKey}`);
  }
  void code;
  return parseItems(items, { symbolKey });
}

/** The THS adapter. No I/O until `refresh()`. */
class ThsSource {
  constructor({ fetchImpl, now, http = null, timeoutMs = TIMEOUT_MS, maxBytes = MAX_BYTES } = {}) {
    this.id = 'ths';
    this.host = HOST;
    this.market = MARKET;
    this.symbolPattern = /^88\d{4}\.SH$/;
    this.http = http ?? createHttpClient({
      host: HOST,
      fetchImpl,
      now,
      timeoutMs,
      maxBytes,
      label: 'ths',
    });
  }

  supportedMarkets() {
    return [MARKET];
  }

  isRefreshable(symbolKey) {
    return boardCodeFor(symbolKey) !== null;
  }

  async refresh(symbolKey) {
    const code = boardCodeFor(symbolKey);
    if (code === null) {
      throw new QuoteUnavailableError('unsupported-market', `ths cannot quote ${symbolKey}`);
    }
    const response = await this.http.request(requestPath(code), {
      headers: HEADERS,
      notFoundReason: 'unsupported-market',
    });
    const quote = parseQuoteBody(response.bytes, { symbolKey, code });
    quote.sourceID = this.id;
    return quote;
  }
}

module.exports = {
  BOARD_CODE,
  BOARD_SYMBOL,
  HEADERS,
  HOST,
  ThsSource,
  boardCodeFor,
  extractJsonPayload,
  fieldNumber,
  fieldString,
  parseItems,
  parseQuoteBody,
  requestPath,
};
