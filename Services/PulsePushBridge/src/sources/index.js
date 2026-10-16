'use strict';

/**
 * The `public` source: adapters for genuinely independent, publicly reachable
 * quote endpoints.
 *
 * Each adapter owns one fixed host and one strict symbol grammar. Nothing here
 * accepts a URL, a host, or a path fragment from a caller, and constructing the
 * source opens no socket — the first (and only) I/O happens inside `refresh()`.
 *
 * Coverage is exactly what the adapters implement:
 *
 *   | symbolKey form            | host                     | note                    |
 *   |---------------------------|--------------------------|-------------------------|
 *   | `NNNNNN.KS` / `NNNNNN.KQ` | polling.finance.naver.com| Korea, delay 0          |
 *   | `KOSPI.KS`                | polling.finance.naver.com| the composite index     |
 *   | `88xxxx.SH`               | d.10jqka.com.cn          | THS industry board      |
 *   | `NNNNNN.SH` / `.SZ`       | qt.gtimg.cn              | A-shares, delay 0       |
 *   | `NNN.HK`                  | qt.gtimg.cn              | Hong Kong, delay 900    |
 *   | `TICKER` (bare, no dot)   | qt.gtimg.cn              | US, delay 0             |
 *
 * Everything else — crypto, Tokyo, Korean codes via Tencent, every index that is
 * not `KOSPI.KS` — is `unsupported-market`. No index wire code is invented.
 */

const { QuoteUnavailableError, assertQuoteShape } = require('../quote-source');
const { NaverSource } = require('./naver');
const { ThsSource } = require('./ths');
const { TencentSource } = require('./tencent');

/** Markets this source can serve, derived from the adapters above. */
const PUBLIC_QUOTE_MARKETS = Object.freeze(['KR', 'SH', 'SZ', 'HK', 'US']);

/**
 * Builds the adapter list. Order does not affect dispatch (the grammars are
 * disjoint), but it is fixed so `supportedMarkets()` is deterministic.
 */
function createAdapters(options = {}) {
  return [new NaverSource(options), new ThsSource(options), new TencentSource(options)];
}

/**
 * The `public` quote source.
 *
 * `refresh()` picks the adapter by the adapter's own validator — a symbol only
 * reaches a host after a validator that belongs to that host has accepted it —
 * and re-validates the returned quote against `assertQuoteShape` so an adapter
 * bug cannot hand a NaN or a fabricated clock to the scheduler.
 */
class PublicQuoteSource {
  constructor({ fetchImpl, now, http = null, adapters = null, logger = null } = {}) {
    this.id = 'public';
    this.logger = logger;
    this.adapters = adapters ?? createAdapters({ fetchImpl, now, http });
    if (!Array.isArray(this.adapters) || this.adapters.length === 0) {
      throw new TypeError('PublicQuoteSource requires at least one adapter');
    }
  }

  /**
   * Markets for which a refresh could succeed. This is a property of *this
   * instance*, selected explicitly by the operator, and it never feeds the
   * global `REFRESHABLE_MARKETS` claim.
   */
  supportedMarkets() {
    const markets = new Set();
    for (const adapter of this.adapters) {
      for (const market of adapter.supportedMarkets()) markets.add(market);
    }
    return [...markets].sort();
  }

  /** The adapter that would answer for this symbol, or null. */
  adapterFor(symbolKey) {
    if (typeof symbolKey !== 'string' || symbolKey.length === 0 || symbolKey.length > 32) return null;
    return this.adapters.find((adapter) => adapter.isRefreshable(symbolKey)) ?? null;
  }

  isRefreshable(symbolKey) {
    return this.adapterFor(symbolKey) !== null;
  }

  /**
   * Fetches one quote from the adapter's own host.
   *
   * @param {string} symbolKey a `SymbolID.description` form
   * @returns {Promise<object>} a quote that has passed `assertQuoteShape`
   * @throws {QuoteUnavailableError} `unsupported-market` when no adapter claims
   *   the symbol; whatever typed reason the adapter reported otherwise
   */
  async refresh(symbolKey) {
    const adapter = this.adapterFor(symbolKey);
    if (adapter === null) {
      throw new QuoteUnavailableError(
        'unsupported-market',
        `no public quote source serves ${typeof symbolKey === 'string' ? symbolKey : 'that symbol'}`,
      );
    }
    const quote = await adapter.refresh(symbolKey);
    return assertQuoteShape(quote, { label: `public(${adapter.id})` });
  }
}

module.exports = {
  PUBLIC_QUOTE_MARKETS,
  PublicQuoteSource,
  createAdapters,
};
