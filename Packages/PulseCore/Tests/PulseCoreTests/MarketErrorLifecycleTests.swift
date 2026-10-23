import Foundation
import Testing
@testable import PulseCore

/// 「最近一次尝试」的错误生命周期。
///
/// 界面上"没有数据"有两种说法：取数失败，还是这只标的确实没有。区分它们的唯一
/// 依据是 `MarketStore.lastError`，所以这个字段必须只描述**最近一次尝试**——
/// 失败时写入，一旦有成功就退场。如果它只在失败时写入而从不消除，一次抖动就会
/// 让此后所有真正的空结果都被说成失败。
@Suite("Last source error is about the most recent attempt")
@MainActor
struct MarketErrorLifecycleTests {
    private let symbol = SymbolID(market: .sh, code: "688825")

    /// A provider whose candle call fails or succeeds on demand.
    private final class SwitchableProvider: QuoteProvider, @unchecked Sendable {
        nonisolated let descriptor: ProviderDescriptor
        private let lock = NSLock()
        private var _fails: Bool
        private var _candles: [Candle]

        init(fails: Bool, candles: [Candle]) {
            self._fails = fails
            self._candles = candles
            descriptor = ProviderDescriptor(
                id: "switchable",
                name: "Switchable",
                markets: [.sh, .sz],
                capabilities: [.quotes, .candles],
                candlePeriods: [.day]
            )
        }

        var fails: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _fails }
            set { lock.lock(); _fails = newValue; lock.unlock() }
        }

        func search(_ query: String) async throws -> [SymbolInfo] { [] }
        func quotes(for symbols: [SymbolID]) async throws -> [Quote] { [] }
        func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
            try await candles(for: symbol, period: period, count: count, adjustment: .none)
        }
        func candles(for symbol: SymbolID, period: CandlePeriod, count: Int,
                     adjustment: CandleAdjustment) async throws -> [Candle] {
            if fails { throw ProviderError.network(underlying: "simulated outage") }
            return _candles
        }
    }

    private func makeEngine(_ provider: SwitchableProvider) -> (RefreshEngine, MarketStore) {
        let store = MarketStore()
        let watchlist = WatchlistStore(
            defaults: UserDefaults(suiteName: "pulse.error.lifecycle.\(UUID().uuidString)")!)
        let composite = CompositeProvider(providers: [provider], cooldown: 0)
        let engine = RefreshEngine(provider: composite, store: store, watchlist: watchlist)
        return (engine, store)
    }

    private var bars: [Candle] {
        [Candle(time: Date(timeIntervalSince1970: 1_792_000_000), open: 10, high: 11, low: 9, close: 10.5, volume: 100)]
    }

    @Test("A failed candle load records an error for that request only")
    func failureIsRecorded() async {
        let provider = SwitchableProvider(fails: true, candles: bars)
        let (engine, store) = makeEngine(provider)
        let loaded = await engine.loadCandles(for: symbol, period: .day, count: 60)
        #expect(loaded.isEmpty)
        let key = CandleCacheKey(symbol: symbol, period: .day, adjustment: .none)
        #expect(store.candleError(for: key) != nil)
        // A chart failure is not a quote-round failure, so it must not become the
        // store-wide message that a successful quote round would clear.
        #expect(store.lastError == nil)
        #expect(store.candleError(for: CandleCacheKey(symbol: symbol, period: .week, adjustment: .none)) == nil)
    }

    @Test("A later success retires only its own request's error")
    func successClearsError() async {
        let provider = SwitchableProvider(fails: true, candles: bars)
        let (engine, store) = makeEngine(provider)
        let key = CandleCacheKey(symbol: symbol, period: .day, adjustment: .none)
        _ = await engine.loadCandles(for: symbol, period: .day, count: 60)
        #expect(store.candleError(for: key) != nil)

        provider.fails = false
        // Drop the cached (empty) answer so the retry really reaches the provider.
        store.invalidateCandles(for: key)
        let recovered = await engine.loadCandles(for: symbol, period: .day, count: 60)
        #expect(recovered.count == 1)
        #expect(store.candleError(for: key) == nil, "a successful read retires its own failure")
    }

    @Test("Clearing the error leaves cached data alone")
    func clearingKeepsCache() async {
        let provider = SwitchableProvider(fails: false, candles: bars)
        let (_, store) = makeEngine(provider)
        let key = CandleCacheKey(symbol: symbol, period: .day, adjustment: .none)
        store.cache(candles: bars, for: key)
        store.reportCandleError("something went wrong", for: key)
        store.clearCandleError(for: key)
        #expect(store.candleError(for: key) == nil)
        #expect(store.cachedCandles(for: key, maxAge: .infinity)?.count == 1)
    }
}
