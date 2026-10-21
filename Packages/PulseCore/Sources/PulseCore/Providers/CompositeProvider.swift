import Foundation
import OSLog

private let quoteRoutingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app.pulse.mac",
    category: "QuoteRouting"
)

/// Routing + failover: dispatches each request, keyed by capability x market, to the first healthy provider in registration order.
/// On failure it trips that provider's circuit breaker for a while and falls back to the next one. The core and the UI only ever talk to this type.
public actor CompositeProvider: QuoteProvider {
    private let providers: [any QuoteProvider]
    private var unhealthyUntil: [String: Date] = [:]
    private var lastProviderRequestAt: [String: Date] = [:]
    private var searchCache: [String: CacheEntry<[SymbolInfo]>] = [:]
    private var quoteCache: [SymbolID: CacheEntry<Quote>] = [:]
    private var candleCache: [ProviderCandleCacheKey: CacheEntry<[Candle]>] = [:]
    private var delayedStreamLogAt: [String: Date] = [:]
    private var disabledIDs: Set<String>
    private let cooldown: TimeInterval
    private let searchCacheTTL: TimeInterval
    private let quoteCacheTTL: TimeInterval
    private let candleCacheTTL: TimeInterval
    private let searchResultSettleDelay: Duration
    private let searchDeadline: Duration

    public init(providers: [any QuoteProvider],
                disabledIDs: Set<String> = [],
                cooldown: TimeInterval = 120,
                searchCacheTTL: TimeInterval = 300,
                quoteCacheTTL: TimeInterval = 12,
                candleCacheTTL: TimeInterval = 60,
                // Long enough for the securities sources to answer a cold
                // query: Binance replies from an in-memory catalog in under
                // 10ms and Tencent in about 100ms, but Yahoo — the only source
                // for US equities — measured 223-487ms cold. At 350ms it lost
                // that race often enough that searching a ticker like APT or
                // SOL returned the coin and no stock at all. Waiting costs
                // nothing in the common case: the loop returns the moment every
                // source has answered, and warm sources answer in milliseconds.
                searchResultSettleDelay: Duration = .milliseconds(800),
                searchDeadline: Duration = .seconds(3)) {
        self.providers = providers
        self.disabledIDs = disabledIDs
        self.cooldown = cooldown
        self.searchCacheTTL = searchCacheTTL
        self.quoteCacheTTL = quoteCacheTTL
        self.candleCacheTTL = candleCacheTTL
        self.searchResultSettleDelay = searchResultSettleDelay
        self.searchDeadline = searchDeadline
    }

    /// Descriptors of all registered providers (including disabled ones), for display on the settings page
    public nonisolated var registeredDescriptors: [ProviderDescriptor] {
        providers.map(\.descriptor)
    }

    /// Lets the user toggle data sources in settings
    public func setDisabled(_ ids: Set<String>) {
        guard disabledIDs != ids else { return }
        disabledIDs = ids
        // Cached payloads retain source provenance. A deliberate provider change
        // must re-run routing and name ranking rather than serving the old order.
        searchCache.removeAll()
        quoteCache.removeAll()
        candleCache.removeAll()
    }

    /// User-initiated retries should not remain trapped behind a previous circuit-breaker
    /// cooldown. The next request re-evaluates the provider immediately.
    public func resetHealth(_ providerID: String) {
        unhealthyUntil[providerID] = nil
    }

    public nonisolated var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "composite",
            name: PulseLocalization.localizedString("provider.composite"),
            markets: Set(providers.flatMap { $0.descriptor.markets }),
            capabilities: Set(providers.flatMap { $0.descriptor.capabilities })
        )
    }

    // MARK: - Routing

    private func candidates(_ capability: Capability, market: Market) -> [any QuoteProvider] {
        providers.filter { provider in
            let id = provider.descriptor.id
            return provider.descriptor.supports(capability, in: market)
                && !disabledIDs.contains(id) && isHealthy(id)
        }
    }

    /// The candidates that can actually address `symbol`. Market-level routing
    /// picks a source for everything in a market; a sector board is the one
    /// instrument that needs a narrower question, since it sits in a market whose
    /// sources cannot price it.
    private func candidates(
        _ capability: Capability,
        market: Market,
        covering symbol: SymbolID
    ) -> [any QuoteProvider] {
        candidates(capability, market: market).filter { $0.covers(symbol) }
    }

    private func isHealthy(_ id: String) -> Bool {
        guard let until = unhealthyUntil[id] else { return true }
        if until < .now {
            unhealthyUntil[id] = nil
            return true
        }
        return false
    }

    private func markUnhealthy(_ id: String, cooldown: TimeInterval) {
        unhealthyUntil[id] = Date.now.addingTimeInterval(cooldown)
    }

    private func waitForProviderBudget(_ provider: any QuoteProvider) async throws {
        guard let minInterval = provider.descriptor.rateLimit?.minInterval, minInterval > 0 else { return }
        let id = provider.descriptor.id

        // Reserve the budget only when the request is actually ready to start.
        // A cancelled search must not leave a future reservation behind and push
        // every subsequent keystroke farther into a throttling queue.
        while true {
            try Task.checkCancellation()
            let now = Date.now
            let earliestStart = (lastProviderRequestAt[id] ?? .distantPast)
                .addingTimeInterval(minInterval)
            let delay = earliestStart.timeIntervalSince(now)
            guard delay > 0 else {
                lastProviderRequestAt[id] = now
                return
            }
            try await Task.sleep(for: .seconds(delay))
        }
    }

    private func cachedQuote(for symbol: SymbolID, maximumCacheAge: TimeInterval?) -> Quote? {
        guard let entry = quoteCache[symbol] else { return nil }
        guard let maximumCacheAge, maximumCacheAge > 0 else { return nil }
        guard entry.isFresh(maxAge: maximumCacheAge) else { return nil }
        return entry.value
    }

    private func cachedCandles(for key: ProviderCandleCacheKey, maxAge: TimeInterval) -> [Candle]? {
        guard let entry = candleCache[key], entry.isFresh(maxAge: maxAge) else { return nil }
        return entry.value
    }

    private nonisolated func orderedByQuotePriority(
        _ available: [any QuoteProvider],
        market: Market
    ) -> [any QuoteProvider] {
        let registrationOrder = Dictionary(
            uniqueKeysWithValues: providers.enumerated().map { ($0.element.descriptor.id, $0.offset) }
        )
        func preferredWeight(_ provider: any QuoteProvider) -> Int {
            let id = provider.descriptor.id
            if market == .crypto, id == BinanceProvider.providerID { return 0 }
            // Spelled out: LongbridgeProvider only compiles on macOS, but routing
            // rank must stay identical on every platform the composite runs on.
            if market != .crypto, id == "longbridge" { return 0 }
            // Official BYOK A-share source: when the user configured a key it
            // outranks the free endpoints, but never the streaming Longbridge.
            if market.isChinaA, id == FuyaoProvider.providerID { return 1 }
            if market == .us, id == "yahoo" { return 1 }
            return 100 + (registrationOrder[id] ?? 10_000)
        }
        return available.sorted {
            let lhsWeight = preferredWeight($0)
            let rhsWeight = preferredWeight($1)
            if lhsWeight != rhsWeight { return lhsWeight < rhsWeight }
            return (registrationOrder[$0.descriptor.id] ?? 10_000)
                < (registrationOrder[$1.descriptor.id] ?? 10_000)
        }
    }

    private nonisolated func preferredQuoteProvider(
        for market: Market,
        among providers: [any QuoteProvider]
    ) -> (any QuoteProvider)? {
        orderedByQuotePriority(providers, market: market).first
    }

    /// Stable provider rank for names in a market. It deliberately ignores
    /// transient health and enablement so a fallback can never lower a saved
    /// name's watermark.
    public nonisolated func namePriority(for providerID: String, market: Market) -> Int? {
        let ordered = orderedByQuotePriority(
            providers.filter { $0.descriptor.supports(.quotes, in: market) },
            market: market
        )
        return ordered.firstIndex { $0.descriptor.id == providerID }
    }

    public nonisolated func displayNameSource(
        for providerID: String,
        market: Market,
        localeIdentifier: String? = nil
    ) -> DisplayNameSource? {
        guard let priority = namePriority(for: providerID, market: market) else { return nil }
        return DisplayNameSource(
            providerID: providerID,
            priority: priority,
            localeIdentifier: localeIdentifier ?? Self.nameLocaleIdentifier(for: providerID)
        )
    }

    /// Like the variant above, but records the language the supplied name is
    /// actually written in rather than the language the source advertises.
    ///
    /// A source's advertised name language describes the source, not every string
    /// it returns: Tencent names most US instruments in Chinese and a handful in
    /// Latin script — `usIBM` answers `IBM`, `usMETA` answers `Meta Platforms`.
    /// Stamping the advertised language on such a name claims Chinese provenance
    /// for an English word, and because a locale match now outranks every
    /// provider rank, that stamp would not merely install the English label: it
    /// would also keep the real Chinese name from ever replacing it. Callers
    /// holding the text must use this variant.
    public nonisolated func displayNameSource(
        for providerID: String,
        market: Market,
        name: String
    ) -> DisplayNameSource? {
        displayNameSource(
            for: providerID,
            market: market,
            localeIdentifier: Self.languageIdentifier(of: name, advertisedBy: providerID)
        )
    }

    /// The language to record for one received name: what the source advertises,
    /// corrected when the text is plainly not written in it.
    private nonisolated static func languageIdentifier(
        of name: String,
        advertisedBy providerID: String
    ) -> String {
        let advertised = nameLocaleIdentifier(for: providerID)
        // A source that advertises Chinese and answers with a Latin listing name
        // is naming the instrument in English; record that, so a real Chinese
        // name from anywhere else still outranks it.
        if advertised.hasPrefix("zh"), !SecurityName.isChineseName(name) {
            return "en"
        }
        return advertised
    }

    /// Only infrastructure-level errors (network down / 5xx / rate limiting) trip the circuit breaker;
    /// request-level errors (4xx, symbol not found) don't indicate a source failure and never trip it.
    /// Rate limiting gets a short cooldown (recovers quickly); network/5xx errors get the long one.
    private func noteFailure(_ id: String, _ error: any Error) {
        guard ProviderError.shouldTrip(error) else { return }
        if case ProviderError.rateLimited = error {
            markUnhealthy(id, cooldown: min(30, cooldown))
        } else {
            markUnhealthy(id, cooldown: cooldown)
        }
    }

    /// Preferred-provider grouping for a symbol set, before failover. The refresh engine
    /// uses it to poll each group at its source's own cadence; symbols with no available
    /// candidate are omitted.
    public func quoteRouting(for symbols: [SymbolID]) -> [String: [SymbolID]] {
        var groups: [String: [SymbolID]] = [:]
        for symbol in symbols {
            guard let primary = preferredQuoteProvider(
                for: symbol.market,
                among: candidates(.quotes, market: symbol.market, covering: symbol)
            ) else { continue }
            groups[primary.descriptor.id, default: []].append(symbol)
        }
        return groups
    }

    /// Current health status of each data source (for debugging / the settings page)
    public func healthReport() -> [String: String] {
        var report: [String: String] = [:]
        for provider in providers {
            let id = provider.descriptor.id
            if disabledIDs.contains(id) {
                report[id] = "disabled"
            } else if let until = unhealthyUntil[id], until > .now {
                report[id] = "cooling until \(until.formatted(date: .omitted, time: .standard))"
            } else {
                report[id] = "healthy"
            }
        }
        return report
    }

    // MARK: - QuoteProvider

    /// Consumers of a snapshot (UI detail views, one-off reads) share the recent
    /// cache. The refresh engine does not go through here: a scheduled round must
    /// ask the sources again, see `refreshQuotes(for:)`.
    public func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
        try await fetchQuotes(for: symbols, maximumCacheAge: quoteCacheTTL)
    }

    /// A round that must reach the sources. A cached quote never answers it,
    /// however recent: quoting cadence can be as short as one second, so a cache
    /// window longer than that would hold every tick inside itself.
    ///
    /// Caching is not "skipped" so much as passed through — the refreshed quotes
    /// are stored as they arrive, so an ordinary `quotes(for:)` right after still
    /// shares the freshest answer.
    public func refreshQuotes(for symbols: [SymbolID]) async throws -> [Quote] {
        try await fetchQuotes(for: symbols, maximumCacheAge: nil)
    }

    /// The same round as `quotes(for:)`, but only entries no older than
    /// `maximumCacheAge` seconds are reused; `nil` refetches everything.
    public func quotes(for symbols: [SymbolID], maximumCacheAge: TimeInterval?) async throws -> [Quote] {
        try await fetchQuotes(for: symbols, maximumCacheAge: maximumCacheAge)
    }

    private func fetchQuotes(for symbols: [SymbolID], maximumCacheAge: TimeInterval?) async throws -> [Quote] {
        guard !symbols.isEmpty else { return [] }
        var quotesBySymbol: [SymbolID: Quote] = [:]
        var missing: [SymbolID] = []
        for symbol in symbols {
            if let cached = cachedQuote(for: symbol, maximumCacheAge: maximumCacheAge) {
                quotesBySymbol[symbol] = cached
            } else {
                missing.append(symbol)
            }
        }
        guard !missing.isEmpty else {
            return symbols.compactMap { quotesBySymbol[$0] }
        }

        // Group symbols by their preferred provider to merge batch requests as much as possible
        var groups: [String: [SymbolID]] = [:]
        var providerByID: [String: any QuoteProvider] = [:]
        for symbol in missing {
            guard let primary = preferredQuoteProvider(
                for: symbol.market,
                among: candidates(.quotes, market: symbol.market, covering: symbol)
            ) else { continue }
            let id = primary.descriptor.id
            groups[id, default: []].append(symbol)
            providerByID[id] = primary
        }

        var result: [Quote] = []
        var delayedFallbacks: [SymbolID: Quote] = [:]
        var lastError: (any Error)?
        for (id, group) in groups {
            do {
                let provider = providerByID[id]!
                try await waitForProviderBudget(provider)
                let quotes = try await provider.quotes(for: group).map { $0.sourced(by: provider.descriptor) }
                try Task.checkCancellation()
                for quote in quotes {
                    if let actualDelay = quote.sourceDelay,
                       candidates(.quotes, market: quote.symbol.market, covering: quote.symbol).contains(where: {
                           $0.descriptor.id != id
                               && ($0.descriptor.delay[quote.symbol.market] ?? .infinity)
                                   < actualDelay
                       }) {
                        delayedFallbacks[quote.symbol] = quote
                        continue
                    }
                    quoteCache[quote.symbol] = CacheEntry(value: quote)
                    quotesBySymbol[quote.symbol] = quote
                }
                result += quotes
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                noteFailure(id, error)
                lastError = error
            }

            // A provider may legally return a partial batch (for example Longbridge
            // does not carry every Yahoo index). Recover only the omitted symbols,
            // keeping successful Longbridge quotes and its circuit healthy.
            let unresolved = group.filter { quotesBySymbol[$0] == nil }
            for (market, marketSymbols) in Dictionary(grouping: unresolved, by: \.market) {
                var remaining = marketSymbols
                var attemptedIDs: Set<String> = [id]
                while !remaining.isEmpty {
                    // A source is only offered the symbols it can address. A
                    // board and an ordinary A-share share a market but never a
                    // source, so each batch is narrowed to the covered subset
                    // while the market's own priority order still picks who goes
                    // first.
                    let ordered = orderedByQuotePriority(
                        candidates(.quotes, market: market)
                            .filter { !attemptedIDs.contains($0.descriptor.id) },
                        market: market
                    )
                    guard let (fallback, batch) = ordered.lazy.compactMap({ provider
                        -> (any QuoteProvider, [SymbolID])? in
                        let covered = remaining.filter { provider.covers($0) }
                        return covered.isEmpty ? nil : (provider, covered)
                    }).first else {
                        break
                    }
                    let fallbackID = fallback.descriptor.id
                    attemptedIDs.insert(fallbackID)
                    do {
                        let recovered = try await fallbackQuotes(from: fallback, for: batch)
                        for quote in recovered {
                            quoteCache[quote.symbol] = CacheEntry(value: quote)
                            quotesBySymbol[quote.symbol] = quote
                        }
                        result += recovered
                        remaining.removeAll { quotesBySymbol[$0] != nil }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try Task.checkCancellation()
                        noteFailure(fallbackID, error)
                        lastError = error
                    }
                }
            }
        }
        for symbol in missing where quotesBySymbol[symbol] == nil {
            quotesBySymbol[symbol] = delayedFallbacks[symbol] ?? quoteCache[symbol]?.value
        }
        let ordered = symbols.compactMap { quotesBySymbol[$0] }
        if ordered.isEmpty, let lastError { throw lastError }
        return ordered
    }

    private func fallbackQuotes(
        from provider: any QuoteProvider,
        for symbols: [SymbolID]
    ) async throws -> [Quote] {
        try await waitForProviderBudget(provider)
        let quotes = try await provider.quotes(for: symbols).map { $0.sourced(by: provider.descriptor) }
        try Task.checkCancellation()
        return quotes
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        try await candles(for: symbol, period: period, count: count, adjustment: .none)
    }

    public func candles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle] {
        guard count > 0 else { return [] }
        let key = ProviderCandleCacheKey(symbol: symbol, period: period, count: count, adjustment: adjustment)
        if let cached = cachedCandles(for: key, maxAge: candleCacheTTL) {
            return cached
        }
        return try await refreshCandles(for: symbol, period: period, count: count, adjustment: adjustment)
    }

    /// Scheduled history refreshes and explicit retries must reach a source,
    /// rather than replaying the composite's longer-lived read-through cache.
    public func refreshCandles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment = .none) async throws -> [Candle] {
        guard count > 0 else { return [] }
        let key = ProviderCandleCacheKey(symbol: symbol, period: period, count: count, adjustment: adjustment)
        let candles = try await fetchCandles(for: symbol, period: period, count: count, adjustment: adjustment)
        try Task.checkCancellation()
        candleCache[key] = CacheEntry(value: candles)
        return candles
    }

    /// Resolves the best currently available static names without changing quote
    /// routing health. A metadata failure must not make prices fall back.
    public func preferredSecurityNames(for symbols: [SymbolID]) async throws -> [SourcedSecurityName] {
        // Indices and metals carry Pulse's own catalog name; asking a source to
        // name them would only invite a provider spelling to win. A sector board
        // is the same: its name is the catalog's, so `881155` reads 银行 no matter
        // which source answers the quotes.
        let requested = symbols.filter {
            $0.indexID == nil && $0.metalID == nil && $0.sectorIndex == nil
        }
        guard !requested.isEmpty else { return [] }

        var resolved: [SymbolID: SourcedSecurityName] = [:]
        var lastError: (any Error)?

        for (market, marketSymbols) in Dictionary(grouping: requested, by: \.market) {
            let available = orderedByQuotePriority(
                providers.filter {
                    $0.descriptor.supports(.referenceData, in: market)
                        && !disabledIDs.contains($0.descriptor.id)
                        && isHealthy($0.descriptor.id)
                },
                market: market
            )
            var remaining = marketSymbols
            for provider in available where !remaining.isEmpty {
                do {
                    try await waitForProviderBudget(provider)
                    let names = try await provider.securityNames(for: remaining)
                    let priority = namePriority(
                        for: provider.descriptor.id,
                        market: market
                    ) ?? Int.max
                    for name in names {
                        let trimmed = name.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        let candidate = SourcedSecurityName(
                            symbol: name.symbol,
                            name: trimmed,
                            source: DisplayNameSource(
                                providerID: provider.descriptor.id,
                                priority: priority,
                                localeIdentifier: name.localeIdentifier
                            )
                        )
                        // Sources are consulted best-first, but "best" orders the
                        // *market's* data, not the label the user reads. A later
                        // source still wins when its name is the better label —
                        // the same rule the watchlist applies before it stores one.
                        if let existing = resolved[name.symbol], !candidate.source.outranks(existing.source) {
                            continue
                        }
                        resolved[name.symbol] = candidate
                    }
                    // A symbol is settled once its name is in the interface
                    // language, because no later source can offer a better label.
                    // A name in any other language stays queued so a later source
                    // can still improve it; the resolved entry remains the
                    // fallback if none does.
                    remaining.removeAll { symbol in
                        resolved[symbol]?.source.localeIdentifier
                            == PulseLocalization.currentLanguageIdentifier
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Reference data is best-effort and must not trip the quote
                    // circuit. Actual quote/stream failures still own health.
                    lastError = error
                }
            }
        }

        if resolved.isEmpty, let lastError { throw lastError }
        return symbols.compactMap { resolved[$0] }
    }

    /// Asks each source that claims to describe this market, best first, and
    /// takes the first answer — including "nothing to say", which is an answer.
    /// Like names, a description failing must not make prices fall back, so
    /// nothing here touches provider health.
    public func profile(for symbol: SymbolID) async throws -> SecurityProfile? {
        let available = orderedByQuotePriority(
            providers.filter {
                $0.descriptor.supports(.profile, in: symbol.market)
                    && !disabledIDs.contains($0.descriptor.id)
                    && isHealthy($0.descriptor.id)
            },
            market: symbol.market
        )
        guard !available.isEmpty else { throw ProviderError.unsupported(.profile) }

        var lastError: (any Error) = ProviderError.unsupported(.profile)
        for provider in available {
            do {
                try await waitForProviderBudget(provider)
                return try await provider.profile(for: symbol)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func securityNames(for symbols: [SymbolID]) async throws -> [SecurityName] {
        try await preferredSecurityNames(for: symbols).map {
            SecurityName(
                symbol: $0.symbol,
                name: $0.name,
                localeIdentifier: $0.source.localeIdentifier
            )
        }
    }

    /// Real-time push is routed per market and then merged. This lets Longbridge stream
    /// securities while Binance streams crypto over the same app-level subscription.
    public nonisolated func quoteStream(for symbols: [SymbolID]) -> AsyncThrowingStream<Quote, any Error>? {
        guard providers.contains(where: { $0.descriptor.capabilities.contains(.streaming) }) else {
            return nil
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                let routes = await self.streamingRoutes(for: symbols)
                guard !routes.isEmpty else {
                    continuation.finish()
                    return
                }

                await withTaskGroup(of: Void.self) { group in
                    for route in routes {
                        group.addTask {
                            guard let inner = route.provider.quoteStream(for: route.symbols) else { return }
                            do {
                                for try await quote in inner {
                                    let sourced = quote.sourced(by: route.provider.descriptor)
                                    guard await self.shouldYieldStreamedQuote(
                                        sourced,
                                        from: route.provider
                                    ) else { continue }
                                    continuation.yield(sourced)
                                }
                            } catch {
                                // One market stream can disappear independently; the remaining
                                // streams keep running and REST polling continues as a fallback.
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct StreamingRoute: Sendable {
        var provider: any QuoteProvider
        var symbols: [SymbolID]
    }

    /// A delayed push must not overwrite a fresher quote recovered by polling.
    /// Providers without streaming (for example Tencent A-shares) keep refreshing
    /// through the existing polling engine.
    private func shouldYieldStreamedQuote(
        _ quote: Quote,
        from provider: any QuoteProvider
    ) -> Bool {
        guard let actualDelay = quote.sourceDelay,
              candidates(.quotes, market: quote.symbol.market, covering: quote.symbol).contains(where: {
                  $0.descriptor.id != provider.descriptor.id
                      && ($0.descriptor.delay[quote.symbol.market] ?? .infinity) < actualDelay
              }) else {
            return true
        }

        let logKey = "\(provider.descriptor.id):\(quote.symbol.market.rawValue)"
        let now = Date.now
        if now.timeIntervalSince(delayedStreamLogAt[logKey] ?? .distantPast) >= 5 * 60 {
            delayedStreamLogAt[logKey] = now
            quoteRoutingLogger.info(
                "Suppressed delayed stream market=\(quote.symbol.market.rawValue, privacy: .public) source=\(provider.descriptor.id, privacy: .public) delaySeconds=\(Int(actualDelay), privacy: .public); fresher polling source available"
            )
        }
        return false
    }

    private func streamingRoutes(for symbols: [SymbolID]) -> [StreamingRoute] {
        var symbolsByProvider: [String: [SymbolID]] = [:]
        var providerByID: [String: any QuoteProvider] = [:]
        for symbol in symbols {
            let available = candidates(.streaming, market: symbol.market, covering: symbol)
            guard let streamer = preferredQuoteProvider(for: symbol.market, among: available) else { continue }
            let id = streamer.descriptor.id
            symbolsByProvider[id, default: []].append(symbol)
            providerByID[id] = streamer
        }
        return symbolsByProvider.compactMap { id, symbols in
            providerByID[id].map { StreamingRoute(provider: $0, symbols: symbols) }
        }
    }

    public func search(_ query: String) async throws -> [SymbolInfo] {
        let cacheKey = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let entry = searchCache[cacheKey], entry.isFresh(maxAge: searchCacheTTL) {
            return entry.value
        }
        // Search is market-agnostic: query search-capable providers in registration order, then merge,
        // dedupe, and apply one cross-provider relevance ranking.
        // (Tencent excels at Chinese / pinyin / A-share codes, Yahoo at English names / global symbols — merging gives the widest coverage.)
        let enabled = providers.filter {
            $0.descriptor.capabilities.contains(.search) && !disabledIDs.contains($0.descriptor.id)
        }
        guard !enabled.isEmpty else { throw ProviderError.unsupported(.search) }
        let capable = enabled.filter { isHealthy($0.descriptor.id) }
        // Sources exist but are all in circuit-breaker cooldown — that's not the same as disabled: report rate limiting, which recovers automatically
        guard !capable.isEmpty else { throw ProviderError.rateLimited }

        // Pulse carries the metal catalog itself: no provider search covers the
        // international channel these contracts are quoted on, so the identities
        // can only come from the app. Offer them only while some source can
        // actually price them.
        let metals = candidates(.quotes, market: .metal).isEmpty
            ? []
            : PreciousMetalCatalog.search(query)

        // Seed local board hits even if provider search is cancelled at the
        // aggregation deadline. Disabled or cooling sources do not offer them.
        let boards = candidates(.quotes, market: .sh).contains(where: {
            $0.descriptor.id == ThsSectorProvider.providerID
        })
            ? SectorIndexCatalog.search(query)
            : []

        // Chinese names for known Korean listings must not depend on a remote
        // autocomplete response winning the enrichment race. Use ordinary
        // SymbolIDs so adding them cannot duplicate existing Korean watch rows.
        let korean = candidates(.quotes, market: .kr).isEmpty
            ? [] : KoreanSecurityCatalog.search(query)

        // Search providers are independent. Return soon after the first useful source,
        // while keeping a short window for other fast sources to enrich the result set.
        // A hard deadline prevents one stalled source from holding every result hostage.
        let aggregation = await withTaskGroup(
            of: SearchEvent.self,
            returning: SearchAggregation.self
        ) { group in
            for (index, provider) in capable.enumerated() {
                group.addTask {
                    do {
                        try await self.waitForProviderBudget(provider)
                        try Task.checkCancellation()
                        return .provider(index, .success(try await provider.search(query)))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .provider(index, .failure(error))
                    }
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: self.searchDeadline)
                    return .hardDeadline
                } catch {
                    return .cancelled
                }
            }

            var completed: [(Int, Result<[SymbolInfo], any Error>)] = []
            var completedProviderCount = 0
            var settleTimerStarted = false
            while let event = await group.next() {
                switch event {
                case .provider(let index, let outcome):
                    completed.append((index, outcome))
                    completedProviderCount += 1

                    if !settleTimerStarted,
                       case .success(let results) = outcome,
                       Self.containsPreferredSearchResult(results, for: query) {
                        settleTimerStarted = true
                        group.addTask {
                            do {
                                try await Task.sleep(for: self.searchResultSettleDelay)
                                return .settleDeadline
                            } catch {
                                return .cancelled
                            }
                        }
                    }

                    if completedProviderCount == capable.count {
                        group.cancelAll()
                        return SearchAggregation(
                            outcomes: completed.sorted { $0.0 < $1.0 },
                            completedAllProviders: true
                        )
                    }
                case .settleDeadline, .hardDeadline:
                    group.cancelAll()
                    return SearchAggregation(
                        outcomes: completed.sorted { $0.0 < $1.0 },
                        completedAllProviders: false
                    )
                case .cancelled:
                    continue
                }
            }
            group.cancelAll()
            return SearchAggregation(
                outcomes: completed.sorted { $0.0 < $1.0 },
                completedAllProviders: false
            )
        }
        try Task.checkCancellation()

        // Catalog hits lead the merge: an exact alias match ("黄金", "XAU") is a
        // stronger answer than anything a provider returns for the same words.
        var merged: [SymbolInfo] = metals + boards + korean
        var indexBySymbol = Dictionary(
            uniqueKeysWithValues: merged.enumerated().map { ($0.element.symbol, $0.offset) }
        )
        var lastError: (any Error)?
        for (index, outcome) in aggregation.outcomes {
            switch outcome {
            case .success(let infos):
                let sourceProviderID = capable[index].descriptor.id
                for var info in infos {
                    // Name-aware: Tencent's smartbox answers several US tickers
                    // in Latin script (`meta` → `metaplatforms`, `ibm` → `ibm`)
                    // and `nameLocaleIdentifier` would call all of them zh-Hans.
                    // A false Chinese tag now outranks every provider rank, so it
                    // would also reject Yahoo's real English name for the same row.
                    info.displayNameSource = displayNameSource(
                        for: sourceProviderID,
                        market: info.symbol.market,
                        name: info.name
                    )
                    if let existingIndex = indexBySymbol[info.symbol] {
                        let existing = merged[existingIndex]
                        let existingIsPlaceholder = Self.isPlaceholderName(
                            existing.name,
                            for: existing.symbol
                        )
                        let candidateIsPlaceholder = Self.isPlaceholderName(
                            info.name,
                            for: info.symbol
                        )
                        let candidateOutranksExisting =
                            info.displayNameSource?.outranks(existing.displayNameSource) ?? true
                        if !candidateIsPlaceholder
                            && (existingIsPlaceholder || candidateOutranksExisting) {
                            merged[existingIndex].name = info.name
                            merged[existingIndex].displayNameSource = info.displayNameSource
                        }
                    } else {
                        indexBySymbol[info.symbol] = merged.count
                        merged.append(info)
                    }
                }
            case .failure(let error):
                noteFailure(capable[index].descriptor.id, error)
                lastError = error
            }
        }
        if merged.isEmpty {
            if let lastError,
               aggregation.outcomes.allSatisfy({ if case .failure = $0.1 { true } else { false } }) {
                throw lastError
            }
            if !aggregation.completedAllProviders {
                throw lastError ?? ProviderError.network(underlying: "Search timed out")
            }
        }

        let ranked = Self.rankSearchResults(merged, for: query)

        // Cache only a complete, fully successful answer. Partial results are useful
        // for the current interaction but should not mask a recovered source later.
        let allProvidersSucceeded = aggregation.completedAllProviders
            && aggregation.outcomes.allSatisfy { if case .success = $0.1 { true } else { false } }
        if allProvidersSucceeded {
            searchCache[cacheKey] = CacheEntry(value: ranked)
        }
        return ranked
    }

    /// Prevents provider registration order from making crypto an unconditional prefix.
    /// Explicit base/pair queries keep crypto useful, while every other crypto result
    /// follows securities. Each bucket preserves the providers' original ranking.
    private nonisolated static func rankSearchResults(
        _ results: [SymbolInfo],
        for query: String
    ) -> [SymbolInfo] {
        let compactQuery = compactSearchCode(query)
        var leadCrypto: [SymbolInfo] = []
        var metals: [SymbolInfo] = []
        var boards: [SymbolInfo] = []
        var exactSecurities: [SymbolInfo] = []
        var securities: [SymbolInfo] = []
        var otherCrypto: [SymbolInfo] = []
        var leadingBases: Set<String> = []

        for info in results {
            guard let pair = info.symbol.cryptoPair else {
                // Catalog identities keep the lead the merge gave them: an exact
                // alias ("黄金", "XAU") is a stronger answer than a listed
                // company whose ticker happens to read the same way.
                if info.symbol.metalID != nil {
                    metals.append(info)
                    continue
                }
                // A board is a catalog identity too, and the more precise one for
                // a bare industry word: "银行" is `881155`, not the tenth bank ETF.
                if info.symbol.sectorIndex != nil {
                    boards.append(info)
                    continue
                }
                // A ticker is unique on its exchange, so a code that matches the
                // query exactly is a stronger answer than one that merely
                // contains it, whatever order the sources happened to return.
                if isExactSecurityMatch(info.symbol, compactQuery: compactQuery) {
                    exactSecurities.append(info)
                } else {
                    securities.append(info)
                }
                continue
            }
            guard isExactCryptoMatch(pair, compactQuery: compactQuery) else {
                otherCrypto.append(info)
                continue
            }
            // One coin trades against a dozen quote currencies, and every one of
            // them matches the base asset exactly. Ranking them all as top hits
            // buried the securities: "APT" led with seven Aptos pairs before the
            // first stock. Only the best-quoted pair per coin leads — sources
            // already order their own pairs, so that is the one in hand first —
            // and the rest stay reachable behind the securities.
            if leadingBases.insert(compactSearchCode(pair.baseAsset)).inserted {
                leadCrypto.append(info)
            } else {
                otherCrypto.append(info)
            }
        }
        // Both catalog identities lead, ahead of anything a source returned: for a
        // bare industry word the board is the precise answer ("银行" is `881155`,
        // not the tenth bank ETF a smartbox lists).
        return metals + boards + exactSecurities + leadCrypto + securities + otherCrypto
    }

    private nonisolated static func isExactSecurityMatch(
        _ symbol: SymbolID,
        compactQuery: String
    ) -> Bool {
        guard !compactQuery.isEmpty else { return false }
        return compactQuery == compactSearchCode(symbol.code)
            || compactQuery == compactSearchCode(symbol.displayCode)
    }

    /// A weak crypto-only hit must not close the enrichment window before a slower
    /// securities source has had a chance to answer. Exact crypto queries remain fast.
    private nonisolated static func containsPreferredSearchResult(
        _ results: [SymbolInfo],
        for query: String
    ) -> Bool {
        let compactQuery = compactSearchCode(query)
        return results.contains { info in
            guard let pair = info.symbol.cryptoPair else { return true }
            return isExactCryptoMatch(pair, compactQuery: compactQuery)
        }
    }

    private nonisolated static func isExactCryptoMatch(
        _ pair: CryptoPair,
        compactQuery: String
    ) -> Bool {
        guard !compactQuery.isEmpty else { return false }
        return compactQuery == compactSearchCode(pair.baseAsset)
            || compactQuery == compactSearchCode(pair.displayCode)
    }

    private nonisolated static func compactSearchCode(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private enum SearchEvent: Sendable {
        case provider(Int, Result<[SymbolInfo], any Error>)
        case settleDeadline
        case hardDeadline
        case cancelled
    }

    private struct SearchAggregation: Sendable {
        var outcomes: [(Int, Result<[SymbolInfo], any Error>)]
        var completedAllProviders: Bool
    }

    private nonisolated static func isPlaceholderName(_ name: String, for symbol: SymbolID) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized == symbol.code.uppercased()
            || normalized == symbol.displayCode.uppercased()
            || normalized == symbol.cryptoPair?.baseAsset
    }

    private nonisolated static func nameLocaleIdentifier(for providerID: String) -> String {
        switch providerID {
        case "tencent": "zh-Hans"
        case FuyaoProvider.providerID: "zh-Hans"
        case "yahoo": "en"
        case NaverProvider.providerID: "ko"
        default: PulseLocalization.currentLanguageIdentifier
        }
    }

    private func fetchCandles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle] {
        // `covers` is what keeps a nonexistent exchange symbol off an exchange
        // source it would only fail on — and a board off every source but its own.
        let enabled = providers.filter {
            $0.descriptor.supports(candles: period, in: symbol.market)
                && !disabledIDs.contains($0.descriptor.id)
                && $0.covers(symbol)
        }
        guard !enabled.isEmpty else { throw ProviderError.unsupported(.candles) }
        let healthy = enabled.filter { isHealthy($0.descriptor.id) }
        guard !healthy.isEmpty else { throw ProviderError.rateLimited }  // All in cooldown; recovers automatically shortly

        // Health is checked above so a market with every source cooling says so;
        // among healthy sources the quote priority decides, the same order
        // quotes route by (Longbridge, then Fuyao, then everything else). Without
        // it a board's daily history fell through the market's generic sources to
        // Ths (registered last) instead of reaching Fuyao first.
        var lastError: (any Error) = ProviderError.symbolNotFound(symbol)
        var singleBarHistory: [Candle]?
        for provider in orderedByQuotePriority(healthy, market: symbol.market) {
            do {
                try await waitForProviderBudget(provider)
                let result = try await provider.candles(for: symbol, period: period, count: count, adjustment: adjustment)
                try Task.checkCancellation()
                // Some index endpoints return HTTP 200 and only today's snapshot
                // for a multi-year request. Try the next source before accepting it.
                // Keep a genuine newly listed instrument's sole bar if no source
                // has more history, without penalizing this provider's quote health.
                guard !result.isEmpty else { continue }
                if period.isIntraday || count == 1 || result.count > 1 { return result }
                if singleBarHistory == nil { singleBarHistory = result }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                noteFailure(provider.descriptor.id, error)
                lastError = error
            }
        }
        if let singleBarHistory { return singleBarHistory }
        throw lastError
    }
}

private struct CacheEntry<Value> {
    var value: Value
    var storedAt: Date = .now

    func isFresh(maxAge: TimeInterval) -> Bool {
        Date.now.timeIntervalSince(storedAt) <= maxAge
    }
}

private struct ProviderCandleCacheKey: Hashable {
    var symbol: SymbolID
    var period: CandlePeriod
    var count: Int
    var adjustment: CandleAdjustment
}
