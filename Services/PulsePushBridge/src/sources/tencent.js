'use strict';

/**
 * Tencent quote snapshots (`qt.gtimg.cn`) — ordinary SH / SZ / HK / US.
 *
 * Mirrors `TencentProvider`: one line per instrument, `v_<wire>="f0~f1~…"`, with
 * the wire symbol built from the exchange code. Only the four equity boards are
 * wired here. Tencent *does* answer for indices (`usINX`, `hkHSI`, `sh000001`),
 * but an index code is not derivable from a `symbolKey` — `SPX` and `HSI` are
 * Pulse's shorthand, not Tencent's — so no index is attempted rather than a code
 * being guessed at, and indices are `unsupported-market`.
 *
 * The body is GBK-encoded. It is decoded as GB18030 first (with UTF-8 as the
 * documented fallback), and a body that can be decoded neither way is refused
 * instead of being turned into mojibake. Prices are ASCII digits and survive any
 * of the three, so a name that cannot be decoded costs a name — never a number.
 */

const { QuoteUnavailableError } = require('../quote-source');
const { assertSafeCode, createHttpClient } = require('./http');
const {
  ZONE_OFFSETS,
  decodeBody,
  newYorkOffsetAtInstant,
  parseCompactDateTime,
  parseDateSpaceTime,
  parseNewYorkDateTime,
  parseSlashDateTime,
  requireSourceTime,
} = require('./time');
const { marketPhaseFor } = require('./session');

const HOST = 'qt.gtimg.cn';
const MAX_BYTES = 512 * 1024;
const TIMEOUT_MS = 5_000;

const HEADERS = Object.freeze({ Referer: 'https://gu.qq.com/' });

const SHANGHAI_OFFSET = ZONE_OFFSETS['Asia/Shanghai'];
const HONG_KONG_OFFSET = ZONE_OFFSETS['Asia/Hong_Kong'];

/** A-share codes are exactly six digits. */
const A_SHARE_SYMBOL = /^(\d{6})\.(SH|SZ)$/;
/** HK codes are stored unpadded (`700`), so the wire form left-pads to five. */
const HK_SYMBOL = /^(\d{1,5})\.HK$/;
/** A US `symbolKey` is a bare ticker; a suffix means it is not one. */
const US_SYMBOL = /^[A-Z][A-Z0-9.\-]{0,9}$/;

const A_SHARE_CODE = /^\d{6}$/;
const HK_CODE = /^\d{1,5}$/;

/**
 * `SymbolID.description` forms that look like a US equity ticker but are not.
 *
 * A US `symbolKey` is bare, so nothing in the grammar itself distinguishes
 * `AAPL` from `SPX` — and Pulse *does* store two things in the US market whose
 * description is a bare ticker-shaped code:
 *
 *   - **US index shorthands** (`SPX`, `VIX`, `DJI`, `NDX`, `IXIC`, `RUI`, `RUT`),
 *     the `MarketIndexID.displayCode` values for the indices whose `.market` is
 *     `.us`. Core routes those to Tencent's *index* codes (`usINX`, `usVIX`…),
 *     which this adapter does not implement, so they must not fall through to
 *     the equity path and price something else.
 *   - **Precious-metal codes** (`GC`, `XAU`, `SI`, `XAG`, `PL`, `PA`), which
 *     Core stores with `market: .us` and routes to the `hf_` futures channel.
 *     This adapter does not implement that channel either.
 *
 * The cost of getting this wrong is not a missing quote but a *wrong* one:
 * `usSPX` is an ordinary listing, so an index would be priced with whatever
 * instrument that ticker names. Refusing them is `unsupported-market`, which is
 * the honest answer — see `INTEGRATION.md`.
 */
const NON_EQUITY_US_CODES = new Set([
  // US index shorthands (`MarketIndexID.displayCode`, `.us` market).
  'SPX', 'IXIC', 'DJI', 'NDX', 'VIX', 'RUI', 'RUT',
  // Precious-metal codes (`PreciousMetalID`, stored under `market: .us`).
  'GC', 'XAU', 'SI', 'XAG', 'PL', 'PA',
]);

/**
 * The same collision on the A-share boards, where it is worse: the codes are
 * digits, so an index shorthand is indistinguishable from an ordinary six-digit
 * stock by shape alone.
 *
 * `MarketIndexID.resolve` claims `000001` in `.sh` and `399001`/`399006` in
 * `.sz`, so `SymbolID(market: .sh, code: "000001").description` is `000001.SH`
 * — exactly the shape of a Shanghai stock code. `SectorIndexID.resolve` does the
 * same for every `88xxxx` board code, which is why the THS adapter is listed
 * first in `createAdapters` and owns those.
 *
 * The indices are dropped here: Core routes them to Tencent's index codes
 * (`sh000001`, `sz399001`, `sz399006`), which this adapter does not implement,
 * and a bare `sh000001` request is not a route this build can take honestly.
 * Sending one anyway would ask the equity channel for an index.
 */
const INDEX_SHORTHAND_CODES = new Set(['000001', '399001', '399006']);

/**
 * HK codes Pulse resolves to an index rather than a listing
 * (`MarketIndexID.resolve` in `.hk`). `SymbolID(index: .hangSeng).description`
 * is `HSI.HK`, the same shape as an ordinary Hong Kong stock code, so the
 * grammar alone cannot tell them apart. Core routes these to Tencent's index
 * codes (`hkHSI`, `hkHSTECH`), which this adapter does not implement.
 */
const HK_INDEX_CODES = new Set(['HSI', 'HSTECH']);

/**
 * `symbolKey` -> Tencent's wire symbol, plus what the parser needs to know about
 * the row. Mirrors `TencentProvider.tencentSymbol`.
 *
 * @returns {{ wire: string, market: 'sh'|'sz'|'hk'|'us', delay: number,
 *   currencyCode: string, zoneOffsetSeconds: number, formats: string[] }|null}
 */
function tencentSymbolFor(symbolKey) {
  if (typeof symbolKey !== 'string' || symbolKey.length === 0) return null;

  const aShare = A_SHARE_SYMBOL.exec(symbolKey);
  if (aShare) {
    // A six-digit code that Pulse resolves to an index is not a stock: drop it
    // rather than asking the equity channel for a benchmark.
    if (INDEX_SHORTHAND_CODES.has(aShare[1])) return null;
    const code = assertSafeCode(aShare[1], { pattern: A_SHARE_CODE, maxLength: 6, label: 'tencent code' });
    const market = aShare[2] === 'SH' ? 'sh' : 'sz';
    return {
      wire: `${market}${code}`,
      market,
      delay: 0,
      currencyCode: 'CNY',
      zoneOffsetSeconds: SHANGHAI_OFFSET,
      // A-shares: yyyyMMddHHmmss only.
      formats: ['compact'],
    };
  }

  const hk = HK_SYMBOL.exec(symbolKey);
  if (hk) {
    // `HSI.HK` is the Hang Seng index, not a listing: Core normalizes it away
    // from the `.HK` suffix and answers with Tencent's index code instead.
    if (HK_INDEX_CODES.has(hk[1])) return null;
    const raw = assertSafeCode(hk[1], { pattern: HK_CODE, maxLength: 5, label: 'tencent hk code' });
    return {
      wire: `hk${raw.padStart(5, '0')}`,
      market: 'hk',
      delay: 900,
      currencyCode: 'HKD',
      zoneOffsetSeconds: HONG_KONG_OFFSET,
      formats: ['slash'],
    };
  }

  if (US_SYMBOL.test(symbolKey) && !NON_EQUITY_US_CODES.has(symbolKey)) {
    const ticker = assertSafeCode(symbolKey, {
      pattern: US_SYMBOL,
      maxLength: 10,
      label: 'tencent us ticker',
    });
    return {
      wire: `us${ticker}`,
      market: 'us',
      delay: 0,
      currencyCode: 'USD',
      // The US zone is DST-observing, so there is no single offset to record
      // here; `parseRowTimestamp` resolves the offset per timestamp instead.
      zoneOffsetSeconds: null,
      // US rows report the exchange's local wall clock, in either spelling.
      formats: ['newYork'],
    };
  }

  // jp / kr / kq / crypto / metals, and indices without a derivable mapping.
  return null;
}

/**
 * `yyyyMMddHHmmss` for A-shares, `yyyy/MM/dd HH:mm:ss` or `yyyy-MM-dd HH:mm:ss`
 * for US rows, all strictly round-tripped in the exchange's own zone.
 *
 * @returns {number|null} UNIX seconds
 */
function parseRowTimestamp(raw, { zoneOffsetSeconds, formats }) {
  if (typeof raw !== 'string') return null;
  const text = raw.trim();
  if (text.length === 0) return null;
  for (const format of formats) {
    const parsed = format === 'newYork'
      ? parseNewYorkDateTime(text)
      : format === 'compact'
        ? parseCompactDateTime(text, zoneOffsetSeconds)
        : format === 'slash'
          ? parseSlashDateTime(text, zoneOffsetSeconds)
          : parseDateSpaceTime(text, zoneOffsetSeconds);
    if (parsed !== null) return parsed;
  }
  return null;
}

/**
 * Splits the response into `wire -> fields`.
 *
 * @returns {Map<string, string[]>}
 */
function parseLines(text) {
  const lines = new Map();
  for (const rawLine of text.split(';')) {
    const line = rawLine.trim();
    if (line.length === 0) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    if (!key.startsWith('v_')) continue;
    const wire = key.slice(2);
    const payload = line.slice(eq + 1).trim().replace(/^["']|["']$/g, '');
    if (payload.length === 0) continue;
    lines.set(wire, payload.split('~'));
  }
  return lines;
}

/**
 * One row into a quote, mirroring `TencentProvider.parseQuotes`: the price is
 * field 3, the previous close field 4, and the arithmetic form of `change` is
 * authoritative when the source's own fields 31/32 disagree.
 *
 * @throws {QuoteUnavailableError} `source-invalid`
 */
function parseFields(fields, { symbolKey, mapping }) {
  if (!Array.isArray(fields) || fields.length <= 37) {
    throw new QuoteUnavailableError('source-invalid', `tencent: short row for ${symbolKey}`);
  }
  const price = Number(fields[3]);
  if (!Number.isFinite(price) || price <= 0) {
    throw new QuoteUnavailableError('source-invalid', `tencent: unusable price for ${symbolKey}`);
  }
  const previousClose = Number(fields[4]);
  const change = Number.isFinite(previousClose) ? price - previousClose : null;
  const changePercent = Number.isFinite(change) && previousClose > 0 ? (change / previousClose) * 100 : null;

  const quoteSourceTimeUnix = requireSourceTime(
    parseRowTimestamp(fields[30], mapping),
    { label: 'tencent', field: 'f[30]' },
  );

  const name = typeof fields[1] === 'string' ? fields[1].trim() : '';
  return {
    symbolKey,
    name: name.length > 0 ? name : null,
    price,
    previousClose: Number.isFinite(previousClose) && previousClose > 0 ? previousClose : null,
    change,
    changePercent,
    currencyCode: mapping.currencyCode,
    quoteSourceTimeUnix,
    sourceDelay: mapping.delay,
    marketPhase: marketPhaseFor(mapping.market.toUpperCase(), quoteSourceTimeUnix),
    // For the DST-observing US board this is the offset that was actually in
    // force at the source's own timestamp, not a constant.
    timeZoneOffsetSeconds: mapping.zoneOffsetSeconds ?? newYorkOffsetAtInstant(quoteSourceTimeUnix * 1000),
  };
}

/**
 * Parses a Tencent body for the requested symbols.
 *
 * One request here carries exactly one symbol, so a body that omits it means the
 * endpoint does not know that instrument: `unsupported-market`, not a parse
 * failure.
 *
 * @param {Buffer} bytes
 * @param {{ symbolKey: string, mapping: object }} context
 */
function parseQuoteBody(bytes, { symbolKey, mapping }) {
  const decoded = decodeBody(bytes, { prefer: 'gb18030' });
  if (decoded.text === null) {
    throw new QuoteUnavailableError('source-invalid', 'tencent: undecodable response body');
  }
  const lines = parseLines(decoded.text);
  const fields = lines.get(mapping.wire);
  if (!fields) {
    throw new QuoteUnavailableError('unsupported-market', `tencent: no quote for ${symbolKey}`);
  }
  const quote = parseFields(fields, { symbolKey, mapping });
  quote.bodyEncoding = decoded.encoding;
  return quote;
}

/** The Tencent adapter. No I/O until `refresh()`. */
class TencentSource {
  constructor({ fetchImpl, now, http = null, timeoutMs = TIMEOUT_MS, maxBytes = MAX_BYTES } = {}) {
    this.id = 'tencent';
    this.host = HOST;
    this.market = null;
    this.markets = ['SH', 'SZ', 'HK', 'US'];
    this.symbolPattern = [A_SHARE_SYMBOL, HK_SYMBOL, US_SYMBOL];
    this.http = http ?? createHttpClient({
      host: HOST,
      fetchImpl,
      now,
      timeoutMs,
      maxBytes,
      label: 'tencent',
    });
  }

  supportedMarkets() {
    return [...this.markets];
  }

  isRefreshable(symbolKey) {
    return tencentSymbolFor(symbolKey) !== null;
  }

  async refresh(symbolKey) {
    const mapping = tencentSymbolFor(symbolKey);
    if (mapping === null) {
      throw new QuoteUnavailableError('unsupported-market', `tencent cannot quote ${symbolKey}`);
    }
    // One wire symbol per request, so the path never contains a comma the caller
    // could have influenced.
    const response = await this.http.request(`/q=${mapping.wire}`, {
      headers: HEADERS,
      notFoundReason: 'unsupported-market',
    });
    const quote = parseQuoteBody(response.bytes, { symbolKey, mapping });
    quote.sourceID = this.id;
    return quote;
  }
}

module.exports = {
  A_SHARE_SYMBOL,
  HEADERS,
  HK_SYMBOL,
  HOST,
  TencentSource,
  US_SYMBOL,
  parseFields,
  parseLines,
  parseQuoteBody,
  parseRowTimestamp,
  tencentSymbolFor,
};
