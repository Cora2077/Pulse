import Foundation
import Observation

/// Quotes run independently per source. Reference names and sparklines have
/// separate low-frequency tasks, so a slow chart cannot delay a fast quote.
@MainActor
@Observable
public final class RefreshEngine {
    public var idleInterval: TimeInterval = 300
    public var sparklineInterval: TimeInterval = 30
    public private(set) var isRunning = false

    @ObservationIgnored public var writesHeld = false {
        didSet {
            guard oldValue != writesHeld else { return }
            writeEpoch &+= 1
            if !writesHeld { wake() }
        }
    }

    @ObservationIgnored private let provider: CompositeProvider
    @ObservationIgnored private let store: MarketStore
    @ObservationIgnored private let watchlist: WatchlistStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt = 0
    @ObservationIgnored private var writeEpoch: UInt = 0

    private struct Work {
        let id: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var quoteTasks: [String: Work] = [:]
    @ObservationIgnored private var nameTask: Work?
    @ObservationIgnored private var sparklineTask: Work?
    @ObservationIgnored private var lastPollAt: [String: Date] = [:]
    @ObservationIgnored private var forcedSymbols: Set<SymbolID> = []
    @ObservationIgnored private var lastSparklineAt: [SymbolID: Date] = [:]
    @ObservationIgnored private var lastNameRefreshAt: Date = .distantPast
    @ObservationIgnored private var pollOverrides: [String: TimeInterval]
    @ObservationIgnored private lazy var suggestedIntervals = Dictionary(
        uniqueKeysWithValues: provider.registeredDescriptors.compactMap { descriptor in
            descriptor.suggestedPollInterval.map { (descriptor.id, $0) }
        }
    )
    private static let nameRefreshInterval: TimeInterval = 15 * 60

    public convenience init(provider: CompositeProvider, store: MarketStore, watchlist: WatchlistStore,
                            pollOverrides: [String: TimeInterval] = [:]) {
        self.init(provider: provider, store: store, watchlist: watchlist,
                  pollOverrides: pollOverrides, now: Date.init,
                  sleep: { try await Task.sleep(for: $0) })
    }

    /// Clock injection keeps scheduler tests independent of wall time and sessions.
    init(provider: CompositeProvider, store: MarketStore, watchlist: WatchlistStore,
         pollOverrides: [String: TimeInterval], now: @escaping () -> Date,
         sleep: @escaping (Duration) async throws -> Void) {
        self.provider = provider
        self.store = store
        self.watchlist = watchlist
        self.pollOverrides = pollOverrides
        self.now = now
        self.sleep = sleep
    }

    public func pollInterval(for providerID: String) -> TimeInterval {
        let override = pollOverrides[providerID]
        let configured = override.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? suggestedIntervals[providerID] ?? 15
        return configured.isFinite && configured > 0 ? max(1, configured) : 15
    }

    public func setPollOverride(_ interval: TimeInterval?, for providerID: String) {
        pollOverrides[providerID] = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        lastPollAt[providerID] = nil
        wake()
    }

    public func start() {
        guard loopTask == nil else { return }
        // Explicit start/poke/provider changes must work after the close too.
        // Session gates apply again after this one requested round.
        forcedSymbols.formUnion(watchlist.quoteSymbols)
        isRunning = true
        let epoch = generation
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == epoch else { return }
                let delay = await self.scheduleDueWork(generation: epoch)
                guard !Task.isCancelled, self.generation == epoch else { return }
                let sleeper = Task<Void, Never> {
                    do { try await self.sleep(.seconds(delay)) } catch { }
                }
                self.sleepTask = sleeper
                await sleeper.value
            }
        }
    }

    public func stop() {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        for work in quoteTasks.values { work.task.cancel() }
        quoteTasks.removeAll()
        nameTask?.task.cancel()
        nameTask = nil
        sparklineTask?.task.cancel()
        sparklineTask = nil
        isRunning = false
    }

    public func poke() {
        guard isRunning else { return }
        stop()
        lastPollAt.removeAll()
        lastSparklineAt.removeAll()
        lastNameRefreshAt = .distantPast
        start()
    }

    /// Wake the deadline sleep without invalidating in-flight work.
    public func wake() { sleepTask?.cancel() }

    private func scheduleDueWork(generation epoch: UInt) async -> TimeInterval {
        let symbols = watchlist.quoteSymbols
        guard !symbols.isEmpty, !writesHeld else { return 60 }
        let routing = await provider.quoteRouting(for: symbols)
        guard !Task.isCancelled, generation == epoch, !writesHeld else { return 60 }
        let at = now()
        let active = TradingCalendar.anyActive(Set(symbols.map(\.market)), at: at)
        let overnight = Dictionary(uniqueKeysWithValues: provider.registeredDescriptors.map {
            ($0.id, $0.overnightMarkets)
        })
        var nextDelay: TimeInterval = 60
        for (providerID, group) in routing {
            guard quoteTasks[providerID] == nil else { continue }
            let requested = symbolsWorthRefreshing(group, overnightMarkets: overnight[providerID] ?? [], at: at)
            guard !requested.isEmpty else { continue }
            let cadence = pollInterval(for: providerID)
            let remaining = cadence - at.timeIntervalSince(lastPollAt[providerID] ?? .distantPast)
            if remaining <= 0 {
                startQuotes(for: requested, providerID: providerID, at: at)
            } else if active {
                nextDelay = min(nextDelay, remaining)
            }
        }
        if nameTask == nil, at.timeIntervalSince(lastNameRefreshAt) >= Self.nameRefreshInterval {
            startNames(for: symbols, at: at)
        }
        if sparklineTask == nil {
            startSparklines(for: symbols, at: at)
            if sparklineTask == nil {
                for symbol in symbols where shouldRefreshSparkline(symbol, at: at) {
                    let remaining = sparklineInterval - at.timeIntervalSince(lastSparklineAt[symbol] ?? .distantPast)
                    nextDelay = min(nextDelay, max(0.05, remaining))
                }
            }
        }
        return max(0.05, nextDelay)
    }

    private func startQuotes(for symbols: [SymbolID], providerID: String, at: Date) {
        let id = UUID(), epoch = generation, writes = writeEpoch
        lastPollAt[providerID] = at
        forcedSymbols.subtract(symbols)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.quoteTasks[providerID]?.id == id {
                    self.quoteTasks[providerID] = nil
                    self.wake()
                }
            }
            do {
                let quotes = try await self.provider.refreshQuotes(for: symbols)
                try Task.checkCancellation()
                guard self.generation == epoch else { return }
                guard !self.writesHeld, self.writeEpoch == writes else {
                    self.lastPollAt[providerID] = nil
                    self.forcedSymbols.formUnion(symbols)
                    return
                }
                self.store.apply(quotes: quotes)
                self.store.clearError()
                self.applyQuoteNameUpgrades(quotes)
            } catch {
                guard !Task.isCancelled, self.generation == epoch else { return }
                guard !self.writesHeld, self.writeEpoch == writes else {
                    self.lastPollAt[providerID] = nil
                    self.forcedSymbols.formUnion(symbols)
                    return
                }
                self.store.reportError(String(describing: error))
            }
        }
        quoteTasks[providerID] = Work(id: id, task: task)
    }

    private func applyQuoteNameUpgrades(_ quotes: [Quote]) {
        for quote in quotes {
            guard let name = quote.name, let providerID = quote.sourceID,
                  let source = provider.displayNameSource(for: providerID, market: quote.symbol.market, name: name)
            else { continue }
            watchlist.upgradeDisplayName(for: quote.symbol, to: name, source: source)
        }
    }

    private func startNames(for symbols: [SymbolID], at: Date) {
        let id = UUID(), epoch = generation, writes = writeEpoch
        lastNameRefreshAt = at
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.nameTask?.id == id { self.nameTask = nil; self.wake() } }
            guard let names = try? await self.provider.preferredSecurityNames(for: symbols),
                  !Task.isCancelled, self.generation == epoch else { return }
            guard !self.writesHeld, self.writeEpoch == writes else {
                self.lastNameRefreshAt = .distantPast
                return
            }
            for candidate in names {
                self.watchlist.upgradeDisplayName(for: candidate.symbol, to: candidate.name,
                    source: candidate.source, allowSameProviderRefresh: true)
            }
        }
        nameTask = Work(id: id, task: task)
    }

    private func symbolsWorthRefreshing(_ symbols: [SymbolID], overnightMarkets: Set<Market>, at: Date) -> [SymbolID] {
        symbols.filter { symbol in
            if forcedSymbols.contains(symbol) { return true }
            if store.quote(for: symbol) == nil { return true }
            if TradingCalendar.isActive(symbol.market, at: at) { return true }
            if overnightMarkets.contains(symbol.market), TradingCalendar.state(of: symbol.market, at: at) == .overnight {
                return true
            }
            return TradingCalendar.isActive(symbol.market, at: at.addingTimeInterval(-35 * 60))
        }
    }

    private func shouldRefreshSparkline(_ symbol: SymbolID, at: Date) -> Bool {
        TradingCalendar.isActive(symbol.market, at: at)
            || TradingCalendar.isActive(symbol.market, at: at.addingTimeInterval(-35 * 60))
            || (store.sparklines[symbol]?.isEmpty ?? true)
    }

    private func startSparklines(for symbols: [SymbolID], at: Date) {
        let due = symbols.filter { symbol in
            return at.timeIntervalSince(lastSparklineAt[symbol] ?? .distantPast) >= sparklineInterval
                && shouldRefreshSparkline(symbol, at: at)
        }.enumerated().sorted { lhs, rhs in
            let left = lastSparklineAt[lhs.element] ?? .distantPast
            let right = lastSparklineAt[rhs.element] ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        guard !due.isEmpty else { return }
        let id = UUID(), epoch = generation, writes = writeEpoch
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.sparklineTask?.id == id { self.sparklineTask = nil; self.wake() } }
            let batch = Array(due.prefix(6))
            for (index, symbol) in batch.enumerated() {
                guard !Task.isCancelled, self.generation == epoch,
                      !self.writesHeld, self.writeEpoch == writes else { return }
                self.lastSparklineAt[symbol] = self.now()
                let count = IntradayTrendSnapshot.recommendedCandleCount(for: symbol.market)
                let candles = try? await self.provider.refreshCandles(for: symbol, period: .minute1, count: count)
                guard !Task.isCancelled, self.generation == epoch else { return }
                guard !self.writesHeld, self.writeEpoch == writes else {
                    self.lastSparklineAt[symbol] = nil
                    return
                }
                if let candles {
                    self.applyIntradayTrend(candles, for: symbol)
                    self.store.cache(candles: candles.sorted { $0.time < $1.time },
                                     for: CandleCacheKey(symbol: symbol, period: .minute1))
                }
                if index < batch.count - 1 { try? await Task.sleep(for: .milliseconds(350)) }
            }
        }
        sparklineTask = Work(id: id, task: task)
    }

    // MARK: - On-demand detail chart loading (called when the popover opens a detail view)

    public func loadCandles(for symbol: SymbolID, period: CandlePeriod, count: Int = 120, adjustment: CandleAdjustment = .none) async -> [Candle] {
        let key = CandleCacheKey(symbol: symbol, period: period, adjustment: adjustment)
        let maxAge: TimeInterval = period.isIntraday ? 60 : 600
        if let cached = store.cachedCandles(for: key, maxAge: maxAge) {
            return synchronizeIntradayTrend(cached, for: symbol, period: period)
        }
        do {
            let candles = try await provider.candles(for: symbol, period: period, count: count, adjustment: adjustment)
            let synchronized = synchronizeIntradayTrend(candles, for: symbol, period: period)
            store.cache(candles: synchronized, for: key)
            // The error describes the last attempt, so a successful one retires it.
            // Leaving it in place would make every later empty answer read as a
            // failure, long after the source recovered.
            store.clearError()
            return synchronized
        } catch is CancellationError {
            let cached = store.cachedCandles(for: key, maxAge: .infinity) ?? []
            return synchronizeIntradayTrend(cached, for: symbol, period: period)
        } catch {
            store.reportError(String(describing: error))
            let cached = store.cachedCandles(for: key, maxAge: .infinity) ?? []
            return synchronizeIntradayTrend(cached, for: symbol, period: period)
        }
    }

    /// Loads what a symbol is, cached for the day. `nil` means the source had
    /// nothing to say, which is cached like any other answer; a throw means the
    /// asking failed and nothing is cached, so a retry is a real retry rather
    /// than a replay of a failure.
    public func loadProfile(for symbol: SymbolID) async throws -> SecurityProfile? {
        if let cached = store.cachedProfile(for: symbol) { return cached }
        let profile = try await provider.profile(for: symbol)
        store.cache(profile: profile, for: symbol)
        return profile
    }

    private func synchronizeIntradayTrend(
        _ candles: [Candle],
        for symbol: SymbolID,
        period: CandlePeriod
    ) -> [Candle] {
        guard period == .minute1 else { return candles }
        applyIntradayTrend(candles, for: symbol)
        // Return the full series (US bars include pre/post sessions): the detail chart
        // frames it with its own IntradayTrendSnapshot, extended or regular.
        return candles.sorted { $0.time < $1.time }
    }

    private func applyIntradayTrend(_ candles: [Candle], for symbol: SymbolID) {
        let trend = IntradayTrendSnapshot(candles: candles, market: symbol.market)
        // A fetch that carries no regular-session bars yet (e.g. Yahoo during the US
        // pre-market) must not wipe a sparkline that still shows the prior session.
        guard !trend.candles.isEmpty || (store.sparklines[symbol]?.isEmpty ?? true) else { return }
        // Store the full series (US bars include pre/post sessions): the watch row and
        // share cards frame it with their own IntradayTrendSnapshot, extended or regular,
        // exactly like the detail chart frames its cache.
        store.apply(sparkline: candles.sorted { $0.time < $1.time }, for: symbol)
    }
}
