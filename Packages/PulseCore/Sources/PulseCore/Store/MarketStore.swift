import Foundation
import Observation

public struct CandleCacheKey: Hashable, Sendable {
    public var symbol: SymbolID
    public var period: CandlePeriod
    public var adjustment: CandleAdjustment

    public init(symbol: SymbolID, period: CandlePeriod, adjustment: CandleAdjustment = .none) {
        self.symbol = symbol
        self.period = period
        self.adjustment = adjustment
    }
}

/// In-memory quote store: the single data surface for the UI. All surfaces (menu bar / popover / future in-process widgets) read the same instance.
@MainActor
@Observable
public final class MarketStore {
    public private(set) var quotes: [SymbolID: Quote] = [:]
    /// Canonical current-session minute candles used by list rows and share cards.
    public private(set) var sparklines: [SymbolID: [Candle]] = [:]
    public private(set) var lastRefresh: Date?
    public private(set) var lastError: String?

    @ObservationIgnored private var candleCache: [CandleCacheKey: (candles: [Candle], fetchedAt: Date)] = [:]
    @ObservationIgnored private var profileCache: [SymbolID: (profile: SecurityProfile?, fetchedAt: Date)] = [:]

    /// Upper bound on distinct candle-cache keys. This is a menu-bar app that
    /// runs for days while the user pages through instruments and periods, so an
    /// unbounded dictionary would grow for the whole session. The figure is a
    /// deliberate over-estimate: nine periods times a realistic focused set of
    /// symbols (a few watchlist rows plus whatever detail pages were opened).
    /// Eviction only costs a re-fetch; it can never change a rendered result, so
    /// the cap is free to be approximate.
    static let candleCacheCapacity = 48

    public init() {}

    public func quote(for symbol: SymbolID) -> Quote? { quotes[symbol] }

    public func apply(quotes newQuotes: [Quote]) {
        // Merge into a copy first, then assign once: a batch of quotes triggers only one view invalidation.
        // Writing entries one by one would re-render the list N times per tick (one of the culprits behind popover jank)
        var merged = quotes
        for quote in newQuotes where isFresher(quote, than: merged[quote.symbol]) {
            merged[quote.symbol] = quote
        }
        quotes = merged
        lastRefresh = .now
        lastError = nil
    }

    /// Merges push-delivered quotes (already coalesced upstream). Unlike a poll round it
    /// leaves `lastRefresh` and `lastError` alone — pushes are ticks, not health signals.
    public func applyStreamed(_ newQuotes: [Quote]) {
        var merged = quotes
        var changed = false
        for quote in newQuotes where isFresher(quote, than: merged[quote.symbol]) {
            merged[quote.symbol] = quote
            changed = true
        }
        if changed {
            quotes = merged
        }
    }

    /// Polls and pushes race: a poll served from a provider-side cache can arrive after a
    /// fresher push. Never let an older market timestamp overwrite a newer one.
    /// Timestamps are only comparable within one source, though — when the serving source
    /// changes (user toggled a provider, or routing failed over), the replacement carries
    /// the freshest data its source has, even if its market timestamp is older.
    private func isFresher(_ incoming: Quote, than existing: Quote?) -> Bool {
        guard let existing, incoming.sourceID == existing.sourceID else { return true }
        return incoming.timestamp >= existing.timestamp
    }

    public func apply(sparkline candles: [Candle], for symbol: SymbolID) {
        sparklines[symbol] = candles
    }

    public func reportError(_ message: String) {
        lastError = message
    }

    // MARK: - Candle cache

    public func cachedCandles(for key: CandleCacheKey, maxAge: TimeInterval) -> [Candle]? {
        guard let entry = candleCache[key], Date.now.timeIntervalSince(entry.fetchedAt) < maxAge else {
            return nil
        }
        return entry.candles
    }

    public func cache(candles: [Candle], for key: CandleCacheKey) {
        candleCache[key] = (candles, .now)
        evictOldestCandlesIfNeeded()
    }

    /// Drops the least recently fetched entries until the cache fits its cap.
    /// `fetchedAt` doubles as the recency stamp: every write refreshes it, so
    /// the oldest stamp is exactly the entry a re-fetch would cost the least to
    /// recreate. Eviction is a cost trade, never a correctness one — a miss
    /// simply falls through to the provider.
    private func evictOldestCandlesIfNeeded() {
        guard candleCache.count > Self.candleCacheCapacity else { return }
        let overflow = candleCache.count - Self.candleCacheCapacity
        let oldest = candleCache
            .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
            .prefix(overflow)
        for entry in oldest { candleCache.removeValue(forKey: entry.key) }
    }

    // MARK: - Profile cache

    /// Profiles describe a business, not a session, so they are cached for the
    /// day. "This symbol has none" is cached too — an index would otherwise be
    /// looked up every time its page opens.
    public func cachedProfile(for symbol: SymbolID, maxAge: TimeInterval = 86_400) -> SecurityProfile?? {
        guard let entry = profileCache[symbol], Date.now.timeIntervalSince(entry.fetchedAt) < maxAge else {
            return nil
        }
        return .some(entry.profile)
    }

    public func cache(profile: SecurityProfile?, for symbol: SymbolID) {
        profileCache[symbol] = (profile, .now)
    }
}
