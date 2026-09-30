#if DEBUG
import Foundation
import PulseCore

/// Deterministic in-process verification for the shared detail quote/candle service.
/// Run the DEBUG app binary with `--detail-market-selftest`; no live provider is used.
@MainActor
enum DetailMarketDataSelfTest {
    private struct CandleKey: Hashable, Sendable {
        var symbol: SymbolID
        var period: CandlePeriod
        var count: Int
    }

    private struct MetricsSnapshot: Sendable {
        var quoteRequestCount: Int
        var quoteSymbols: [SymbolID]
        var candleRequestCounts: [CandleKey: Int]
        var candleRequestIDs: [CandleKey: [UUID]]
    }

    private actor Metrics {
        private var quoteSymbols: [SymbolID] = []
        private var candleRequestIDs: [CandleKey: [UUID]] = [:]

        func beginQuote(symbols: [SymbolID]) -> UUID {
            quoteSymbols.append(contentsOf: symbols)
            return UUID()
        }

        func beginCandles(_ key: CandleKey) -> UUID {
            let id = UUID()
            candleRequestIDs[key, default: []].append(id)
            return id
        }

        func snapshot() -> MetricsSnapshot {
            MetricsSnapshot(
                quoteRequestCount: quoteSymbols.count,
                quoteSymbols: quoteSymbols,
                candleRequestCounts: candleRequestIDs.mapValues(\.count),
                candleRequestIDs: candleRequestIDs
            )
        }
    }

    /// A cancellation-aware continuation gate lets the test hold provider work
    /// in flight while it cancels one or more UI consumers.
    private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]
        private var releasedValues: [UUID: Value] = [:]
        private var cancelledIDs: Set<UUID> = []

        func wait(for id: UUID, default value: Value) async throws -> Value {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                    lock.lock()
                    if cancelledIDs.contains(id) {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else if let released = releasedValues.removeValue(forKey: id) {
                        lock.unlock()
                        continuation.resume(returning: released)
                    } else {
                        continuations[id] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancel(id)
            }
        }

        func release(_ id: UUID, with value: Value) {
            lock.lock()
            guard let continuation = continuations.removeValue(forKey: id) else {
                releasedValues[id] = value
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(returning: value)
        }

        func cancel(_ id: UUID) {
            lock.lock()
            cancelledIDs.insert(id)
            let continuation = continuations.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }

        var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return continuations.count
        }

        var cancelledCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return cancelledIDs.count
        }
    }

    private final class FakeProvider: QuoteProvider, @unchecked Sendable {
        let descriptor = ProviderDescriptor(
            id: "detail-market-selftest",
            name: "Detail market self-test",
            markets: [.us],
            capabilities: [.quotes, .candles]
        )

        let metrics: Metrics
        let quoteGate: ContinuationGate<Quote>
        let candleGate: ContinuationGate<[Candle]>

        init(
            metrics: Metrics,
            quoteGate: ContinuationGate<Quote>,
            candleGate: ContinuationGate<[Candle]>
        ) {
            self.metrics = metrics
            self.quoteGate = quoteGate
            self.candleGate = candleGate
        }

        func search(_ query: String) async throws -> [SymbolInfo] {
            throw ProviderError.unsupported(.search)
        }

        func quotes(for symbols: [SymbolID]) async throws -> [Quote] {
            guard let symbol = symbols.first else { return [] }
            let id = await metrics.beginQuote(symbols: symbols)
            let quote = Quote(symbol: symbol, price: 123, previousClose: 120)
            return [try await quoteGate.wait(for: id, default: quote)]
        }

        func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
            let key = CandleKey(symbol: symbol, period: period, count: count)
            let id = await metrics.beginCandles(key)
            let close: Double
            switch (symbol.code, period) {
            case ("AAA", .minute5): close = 111
            case ("BBB", .day): close = 222
            default: close = 300 + Double(count)
            }
            let bars = [Candle(
                time: Date(timeIntervalSince1970: TimeInterval(count)),
                open: close - 1,
                high: close + 1,
                low: close - 2,
                close: close
            )]
            return try await candleGate.wait(for: id, default: bars)
        }
    }

    static func run() async -> Bool {
        let suite = "app.pulse.mac.detail-market-selftest"
        guard let defaults = UserDefaults(suiteName: suite) else {
            print("PULSE_DETAIL_MARKET_SELFTEST failed: unable-to-create-isolated-store")
            return false
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_700))
        var failures: [String] = []
        if !(await verifySubscriptionLifecycle(defaults: defaults, deadline: deadline)) {
            failures.append("subscription-lifecycle")
        }
        if !(await verifyIdenticalCandleSharing(defaults: defaults, deadline: deadline)) {
            failures.append("identical-candle-sharing")
        }
        if !(await verifyIndependentCandleKeys(defaults: defaults, deadline: deadline)) {
            failures.append("independent-candle-keys")
        }

        let passed = 3 - failures.count
        if failures.isEmpty {
            print("PULSE_DETAIL_MARKET_SELFTEST PASS 3/3: shared quote interest/poll cancellation; shared candle request survives one consumer cancellation; independent candle keys keep their own results")
        } else {
            print("PULSE_DETAIL_MARKET_SELFTEST FAIL \(passed)/3: \(failures.joined(separator: ","))")
        }
        return failures.isEmpty
    }

    private static func verifySubscriptionLifecycle(
        defaults: UserDefaults,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        let symbol = SymbolID(market: .us, code: "LIFE")
        let metrics = Metrics()
        let quoteGate = ContinuationGate<Quote>()
        let provider = FakeProvider(metrics: metrics, quoteGate: quoteGate, candleGate: ContinuationGate<[Candle]>())
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Detail Self-Test")
        let composite = CompositeProvider(
            providers: [provider], quoteCacheTTL: 0, candleCacheTTL: 0
        )
        let market = MarketStore()
        var interestChanges: [Set<SymbolID>] = []
        var deliveredQuotes = 0
        let controller = DetailMarketDataController(
            provider: composite,
            engine: RefreshEngine(provider: composite, store: market, watchlist: watchlist),
            market: market,
            watchlist: watchlist,
            onQuote: { _ in deliveredQuotes += 1 },
            onInterestsChanged: { interestChanges.append($0) }
        )

        let runSignals = RunSignals()
        let first = Task { @MainActor in
            await runSignals.markStarted()
            await controller.run(symbol: symbol)
        }
        guard await wait(until: deadline, condition: {
            let snapshot = await metrics.snapshot()
            return interestChanges == [Set([symbol])] && snapshot.quoteRequestCount == 1
                && quoteGate.pendingCount == 1
        }) else {
            first.cancel()
            return false
        }
        guard watchlist.symbols.isEmpty else { first.cancel(); return false }

        let second = Task { @MainActor in
            await runSignals.markStarted()
            await controller.run(symbol: symbol)
        }
        guard await wait(until: deadline, condition: { await runSignals.count == 2 }) else {
            first.cancel(); second.cancel()
            return false
        }
        // The second run resumes on MainActor and acquires synchronously before sleeping.
        try? await Task.sleep(for: .milliseconds(15))
        first.cancel()
        await first.value
        let afterFirstCancel = await metrics.snapshot()
        guard interestChanges == [Set([symbol])], quoteGate.pendingCount == 1,
              quoteGate.cancelledCount == 0, afterFirstCancel.quoteRequestCount == 1 else {
            second.cancel()
            await second.value
            return false
        }

        second.cancel()
        await second.value
        let released = await wait(until: deadline, condition: {
            interestChanges == [Set([symbol]), Set<SymbolID>()]
                && quoteGate.cancelledCount == 1
                && quoteGate.pendingCount == 0
        })
        let finalMetrics = await metrics.snapshot()
        let passed = released && finalMetrics.quoteRequestCount == 1
            && finalMetrics.quoteSymbols == [symbol] && deliveredQuotes == 0
        return passed
    }

    private static func verifyIdenticalCandleSharing(
        defaults: UserDefaults,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        let metrics = Metrics()
        let quoteGate = ContinuationGate<Quote>()
        let candleGate = ContinuationGate<[Candle]>()
        let provider = FakeProvider(metrics: metrics, quoteGate: quoteGate, candleGate: candleGate)
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Detail Self-Test")
        let composite = CompositeProvider(providers: [provider], quoteCacheTTL: 0, candleCacheTTL: 0)
        let market = MarketStore()
        let engine = RefreshEngine(provider: composite, store: market, watchlist: watchlist)
        let controller = DetailMarketDataController(
            provider: composite, engine: engine, market: market, watchlist: watchlist,
            onQuote: { _ in }, onInterestsChanged: { _ in }
        )
        let symbol = SymbolID(market: .us, code: "AAA")
        let key = CandleKey(symbol: symbol, period: .minute5, count: 4)
        let signals = RunSignals()

        let cancelledConsumer = Task { @MainActor in
            await signals.markStarted()
            return await controller.loadCandles(symbol: symbol, period: .minute5, count: 4)
        }
        guard await wait(until: deadline, condition: {
            let snapshot = await metrics.snapshot()
            return snapshot.candleRequestCounts[key] == 1 && candleGate.pendingCount == 1
        }) else {
            cancelledConsumer.cancel()
            return false
        }

        let retainedConsumer = Task { @MainActor in
            await signals.markStarted()
            return await controller.loadCandles(symbol: symbol, period: .minute5, count: 4)
        }
        guard await wait(until: deadline, condition: { await signals.count == 2 }) else {
            cancelledConsumer.cancel(); retainedConsumer.cancel()
            return false
        }
        try? await Task.sleep(for: .milliseconds(15))
        cancelledConsumer.cancel()
        // Cancellation of a UI waiter must leave the shared provider continuation intact.
        let requestIDs = await metrics.snapshot().candleRequestIDs[key] ?? []
        guard requestIDs.count == 1, candleGate.pendingCount == 1, candleGate.cancelledCount == 0 else {
            retainedConsumer.cancel()
            return false
        }

        let expected = [Candle(time: Date(timeIntervalSince1970: 4), open: 110, high: 112, low: 109, close: 111)]
        candleGate.release(requestIDs[0], with: expected)
        let firstValue = await cancelledConsumer.value
        let secondValue = await retainedConsumer.value
        let finalSnapshot = await metrics.snapshot()
        return firstValue == expected && secondValue == expected
            && finalSnapshot.candleRequestCounts[key] == 1
    }

    private static func verifyIndependentCandleKeys(
        defaults: UserDefaults,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        let metrics = Metrics()
        let candleGate = ContinuationGate<[Candle]>()
        let provider = FakeProvider(metrics: metrics, quoteGate: ContinuationGate<Quote>(), candleGate: candleGate)
        let watchlist = WatchlistStore(defaults: defaults, defaultGroupName: "Detail Self-Test")
        let composite = CompositeProvider(providers: [provider], quoteCacheTTL: 0, candleCacheTTL: 0)
        let market = MarketStore()
        let controller = DetailMarketDataController(
            provider: composite,
            engine: RefreshEngine(provider: composite, store: market, watchlist: watchlist),
            market: market,
            watchlist: watchlist,
            onQuote: { _ in }, onInterestsChanged: { _ in }
        )
        let keyA = CandleKey(symbol: SymbolID(market: .us, code: "AAA"), period: .minute5, count: 4)
        let keyB = CandleKey(symbol: SymbolID(market: .us, code: "BBB"), period: .day, count: 6)
        let loadA = Task { @MainActor in
            await controller.loadCandles(symbol: keyA.symbol, period: keyA.period, count: keyA.count)
        }
        let loadB = Task { @MainActor in
            await controller.loadCandles(symbol: keyB.symbol, period: keyB.period, count: keyB.count)
        }
        guard await wait(until: deadline, condition: {
            let snapshot = await metrics.snapshot()
            return snapshot.candleRequestCounts[keyA] == 1
                && snapshot.candleRequestCounts[keyB] == 1
                && candleGate.pendingCount == 2
        }) else {
            loadA.cancel(); loadB.cancel()
            return false
        }

        let requestIDs = await metrics.snapshot().candleRequestIDs
        guard let idA = requestIDs[keyA]?.first, let idB = requestIDs[keyB]?.first else {
            loadA.cancel(); loadB.cancel()
            return false
        }
        let expectedA = [Candle(time: Date(timeIntervalSince1970: 4), open: 110, high: 112, low: 109, close: 111)]
        let expectedB = [Candle(time: Date(timeIntervalSince1970: 6), open: 221, high: 223, low: 220, close: 222)]
        candleGate.release(idA, with: expectedA)
        candleGate.release(idB, with: expectedB)
        let resultA = await loadA.value
        let resultB = await loadB.value
        let finalSnapshot = await metrics.snapshot()
        return resultA == expectedA && resultB == expectedB
            && finalSnapshot.candleRequestCounts[keyA] == 1
            && finalSnapshot.candleRequestCounts[keyB] == 1
    }

    private static func wait(
        until deadline: ContinuousClock.Instant,
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private actor RunSignals {
        private(set) var count = 0
        func markStarted() { count += 1 }
    }
}
#endif
