'use strict';

/**
 * Where a refreshed quote could come from — and, today, mostly where it cannot.
 *
 * The service is allowed to send a quote only if it can say, truthfully, where
 * that number came from and when the source stamped it. There are two honest
 * answers:
 *
 *   - `client` (the default): the phone uploaded its own latest public quote.
 *     The service re-states it and derives the deadline from the *source* time.
 *     This is a snapshot, not a feed. Nothing here refreshes it. A long window
 *     on a client snapshot is exactly the "old snapshot keeps refreshing" claim
 *     the brief forbids, so the scheduler rejects a stale source rather than
 *     dressing it up.
 *   - `none`: no quote source at all. Every market is `unsupported`.
 *   - `public`: the service fetches an independent quote from a public endpoint
 *     (`src/sources/`), with that endpoint's own timestamp. It is **never**
 *     selected implicitly: the operator opts in with
 *     `PULSE_PUSH_QUOTE_SOURCE=public`, because enabling it means the process
 *     contacts third-party hosts.
 *
 * The global `REFRESHABLE_MARKETS` claim stays empty on purpose. It is the
 * statement "the *client* can refresh", and the client cannot. Only a `public`
 * source instance, explicitly selected, reports the markets it can serve — and
 * only for the symbols its adapters implement.
 */

const { REFRESHABLE_MARKETS } = require('./config');

const QUOTE_FAILURE_REASONS = new Set([
  'unsupported-market',
  'source-unavailable',
  'source-error',
  'source-invalid',
]);

class QuoteUnavailableError extends Error {
  constructor(reason, detail) {
    super(detail ?? reason);
    this.name = 'QuoteUnavailableError';
    this.reason = QUOTE_FAILURE_REASONS.has(reason) ? reason : 'source-error';
    this.detail = detail;
  }
}

/**
 * The shape every adapter must produce.
 *
 * Validated rather than trusted: an adapter that returns a stale timestamp, a
 * zero price or a NaN is a bug that would otherwise reach a lock screen.
 */
function assertQuoteShape(quote, { label = 'quote' } = {}) {
  if (!quote || typeof quote !== 'object') {
    throw new QuoteUnavailableError('source-invalid', `${label} is not an object`);
  }
  const { price, quoteSourceTimeUnix, marketPhase, symbolKey } = quote;
  if (typeof price !== 'number' || !Number.isFinite(price) || price <= 0) {
    throw new QuoteUnavailableError('source-invalid', `${label}.price must be a finite positive number`);
  }
  if (!Number.isInteger(quoteSourceTimeUnix) || quoteSourceTimeUnix <= 0) {
    throw new QuoteUnavailableError('source-invalid', `${label}.quoteSourceTimeUnix must be integer UNIX seconds`);
  }
  if (typeof marketPhase !== 'string') {
    throw new QuoteUnavailableError('source-invalid', `${label}.marketPhase missing`);
  }
  if (typeof symbolKey !== 'string' || symbolKey.length === 0) {
    throw new QuoteUnavailableError('source-invalid', `${label}.symbolKey missing`);
  }
  if (quote.change !== null && quote.change !== undefined) {
    if (typeof quote.change !== 'number' || !Number.isFinite(quote.change)) {
      throw new QuoteUnavailableError('source-invalid', `${label}.change must be finite or null`);
    }
  }
  if (quote.changePercent !== null && quote.changePercent !== undefined) {
    if (typeof quote.changePercent !== 'number' || !Number.isFinite(quote.changePercent)) {
      throw new QuoteUnavailableError('source-invalid', `${label}.changePercent must be finite or null`);
    }
  }
  return quote;
}

/**
 * The `client` source.
 *
 * `refresh()` deliberately throws `unsupported-market`: the service has no feed
 * of its own, and returning the client's own snapshot while calling it a refresh
 * would make `/v1/quotes/refresh` a lie. The endpoint is still useful — it
 * reports which markets are refreshable (none, for this source) so the client
 * knows to keep uploading.
 */
class ClientSnapshotQuoteSource {
  constructor({ logger = null } = {}) {
    this.id = 'client';
    this.logger = logger;
  }

  /** Markets for which this source could serve a refresh. */
  supportedMarkets() {
    return [...REFRESHABLE_MARKETS];
  }

  isRefreshable(symbolKey) {
    return REFRESHABLE_MARKETS.has(marketOf(symbolKey));
  }

  async refresh(symbolKey) {
    if (!this.isRefreshable(symbolKey)) {
      throw new QuoteUnavailableError(
        'unsupported-market',
        `no refreshable quote source is configured for ${marketOf(symbolKey) || 'this market'}; ` +
        'the client snapshot is used as-is and its source timestamp is preserved',
      );
    }
    // Unreachable while REFRESHABLE_MARKETS is empty; kept so an adapter can be
    // registered without touching this class.
    throw new QuoteUnavailableError('source-unavailable');
  }
}

/**
 * The `public` source: a thin wrapper over the adapters in `src/sources/`.
 *
 * Loading this module opens no socket. The adapters are constructed lazily on
 * the first `refresh()`, so a process that merely holds a `public` source — or
 * one configured with `PULSE_PUSH_QUOTE_SOURCE=client` and never asked to
 * refresh — performs no network I/O at all.
 *
 * `fetchImpl` and `now` are injectable so tests never touch the network and can
 * prove the returned `quoteSourceTimeUnix` is the *source's* time rather than
 * the process clock.
 */
class PublicQuoteSource {
  constructor({ fetchImpl, now, http = null, adapters = null, logger = null } = {}) {
    this.id = 'public';
    this.logger = logger;
    this.#options = { fetchImpl, now, http, adapters };
  }

  #options;

  #delegate() {
    if (this.#impl === null) {
      // Required lazily and on purpose: `require('./sources')` pulls in the HTTP
      // layer, and a process that never refreshes should never build one.
      const { PublicQuoteSource: PublicSource } = require('./sources');
      this.#impl = new PublicSource(this.#options);
    }
    return this.#impl;
  }

  #impl = null;

  /**
   * Markets this instance can serve. Only ever consulted when the operator has
   * explicitly selected `public`; it is not the global refresh claim.
   */
  supportedMarkets() {
    return this.#delegate().supportedMarkets();
  }

  isRefreshable(symbolKey) {
    return this.#delegate().isRefreshable(symbolKey);
  }

  async refresh(symbolKey) {
    return this.#delegate().refresh(symbolKey);
  }
}

/** The `none` source: explicitly no quote capability at all. */
class NoQuoteSource {
  constructor() {
    this.id = 'none';
  }

  supportedMarkets() {
    return [];
  }

  isRefreshable() {
    return false;
  }

  async refresh(symbolKey) {
    throw new QuoteUnavailableError('unsupported-market', `quote source "none" cannot refresh ${symbolKey}`);
  }
}

/**
 * Market suffix of a `symbolKey` (`600519.SH` -> `SH`, `BTC/USDT` -> `CRYPTO`).
 * Only used to answer "is this market supported", never to fetch anything.
 */
function marketOf(symbolKey) {
  if (typeof symbolKey !== 'string') return '';
  if (symbolKey.includes('/')) return 'CRYPTO';
  const dot = symbolKey.lastIndexOf('.');
  if (dot === -1) return symbolKey.toUpperCase();
  return symbolKey.slice(dot + 1).toUpperCase();
}

const QUOTE_SOURCE_FACTORIES = {
  client: (options) => new ClientSnapshotQuoteSource(options),
  none: () => new NoQuoteSource(),
  public: (options) => new PublicQuoteSource(options),
};

function createQuoteSource(id, options = {}) {
  const factory = QUOTE_SOURCE_FACTORIES[id];
  if (!factory) throw new Error(`unknown quote source "${id}"`);
  return factory(options);
}

module.exports = {
  ClientSnapshotQuoteSource,
  NoQuoteSource,
  PublicQuoteSource,
  QUOTE_FAILURE_REASONS,
  QUOTE_SOURCE_FACTORIES,
  QuoteUnavailableError,
  assertQuoteShape,
  createQuoteSource,
  marketOf,
};
