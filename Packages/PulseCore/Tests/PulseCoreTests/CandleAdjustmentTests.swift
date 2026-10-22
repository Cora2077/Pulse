import Foundation
import Testing
@testable import PulseCore

private actor BasisProvider: QuoteProvider {
    nonisolated let descriptor: ProviderDescriptor
    let failure: ProviderError?
    init(id: String = "basis", failure: ProviderError? = nil) {
        descriptor = ProviderDescriptor(id: id, name: id, markets: [.sz], capabilities: [.candles])
        self.failure = failure
    }
    var requests: [CandleAdjustment] = []
    func search(_ query: String) async throws -> [SymbolInfo] { [] }
    func quotes(for symbols: [SymbolID]) async throws -> [Quote] { [] }
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int) async throws -> [Candle] {
        try await candles(for: symbol, period: period, count: count, adjustment: .none)
    }
    func candles(for symbol: SymbolID, period: CandlePeriod, count: Int, adjustment: CandleAdjustment) async throws -> [Candle] {
        requests.append(adjustment)
        if let failure { throw failure }
        let price = adjustment == .none ? 321.43 : 228.522
        return [.init(time: .init(timeIntervalSince1970: 1), open: price, high: price, low: price, close: price)]
    }
}

@Suite("Historical chart price basis")
struct CandleAdjustmentTests {
    let symbol = SymbolID(market: .sz, code: "001309")

    @Test("Composite caches adjusted and actual prices independently")
    func compositeCacheIsolation() async throws {
        let source = BasisProvider()
        let composite = CompositeProvider(providers: [source])
        let actual = try await composite.candles(for: symbol, period: .day, count: 1)
        let adjusted = try await composite.candles(for: symbol, period: .day, count: 1, adjustment: .forward)
        #expect(actual.first?.close == 321.43)
        #expect(adjusted.first?.close == 228.522)
        #expect(try await composite.candles(for: symbol, period: .day, count: 1) == actual)
        #expect(try await composite.candles(for: symbol, period: .day, count: 1, adjustment: .forward) == adjusted)
        #expect(await source.requests == [.none, .forward])
    }

    @Test("An unsupported source cannot return actual prices for an adjusted request")
    func noSilentRawFallback() async throws {
        let composite = CompositeProvider(providers: [MockProvider(id: "raw-only")])
        await #expect(throws: ProviderError.self) {
            try await composite.candles(for: symbol, period: .day, count: 1, adjustment: .forward)
        }
        #expect(try await composite.candles(for: symbol, period: .day, count: 1).count == 1)
    }

    @Test("Rate-limited primary history falls back using the same explicit basis")
    func rateLimitedFallback() async throws {
        let primary = BasisProvider(id: "fuyao", failure: .rateLimited)
        let backup = BasisProvider(id: "tencent")
        let composite = CompositeProvider(providers: [primary, backup])
        let bars = try await composite.candles(for: symbol, period: .day, count: 1, adjustment: .forward)
        #expect(bars.first?.close == 228.522)
        #expect(await primary.requests == [.forward])
        #expect(await backup.requests == [.forward])
    }

    @Test @MainActor
    func storeCacheIsolation() {
        let store = MarketStore()
        let actual = CandleCacheKey(symbol: symbol, period: .day)
        let adjusted = CandleCacheKey(symbol: symbol, period: .day, adjustment: .forward)
        let bar = Candle(time: .now, open: 321.43, high: 321.43, low: 321.43, close: 321.43)
        store.cache(candles: [bar], for: actual)
        #expect(store.cachedCandles(for: adjusted, maxAge: .infinity) == nil)
        store.cache(candles: [], for: adjusted)
        #expect(store.cachedCandles(for: actual, maxAge: .infinity) == [bar])
    }

    @Test("Only historical China stocks and funds opt into this chart basis")
    func chartEligibility() {
        for period in [CandlePeriod.day, .week, .month] {
            #expect(CandleAdjustment.supportsChart(symbol, period: period))
            #expect(CandleAdjustment.supportsChart(.init(market: .sh, code: "510300"), period: period))
            #expect(!CandleAdjustment.supportsChart(.init(market: .sh, code: "000001"), period: period))
            #expect(!CandleAdjustment.supportsChart(.init(market: .us, code: "AAPL"), period: period))
        }
        #expect(!CandleAdjustment.supportsChart(symbol, period: .minute1))
        #expect(!CandleAdjustment.supportsChart(symbol, period: .minute30))
    }

    @Test("Tencent selects qfq daily weekly monthly series without altering volume or dates")
    func tencentExRightsWindow() throws {
        for (period, interval) in [(CandlePeriod.day, "day"), (.week, "week"), (.month, "month")] {
            let fixture = """
            {"code":0,"data":{"sz001309":{
            "\(interval)":[["2026-10-12","332.53","321.43","333.0","321.0","61903"]],
            "qfq\(interval)":[["2026-10-12","236.45","228.522","236.786","228.214","61903"],["2026-10-13","222.0","233.78","237.88","218.03","127003"]]}}}
            """
            let raw = try TencentProvider.parseHistoricalCandles(Data(fixture.utf8), symbol: symbol, wireSymbol: "sz001309", period: period)
            let adjusted = try TencentProvider.parseHistoricalCandles(Data(fixture.utf8), symbol: symbol, wireSymbol: "sz001309", period: period, adjustment: .forward)
            #expect(raw.first?.close == 321.43)
            #expect(adjusted.map(\.close) == [228.522, 233.78])
            #expect(raw.first?.time == adjusted.first?.time)
            #expect(raw.first?.volume == adjusted.first?.volume)
            #expect(abs((321.43 - 1.5) / 1.4 - adjusted[0].close) < 0.01)
        }
        // A share that has never had a corporate action gets no qfq series at all:
        // the endpoint then answers with the plain `day` series, which is identical
        // to the forward-adjusted one by construction. Verified live on 2026-10-22:
        // 001309 and 600519 (both have ex-rights history) return `qfqday`, while a
        // newly listed share returns only `day`.
        let neverAdjusted = #"{"code":0,"data":{"sz001309":{"day":[["2026-10-12","332.53","321.43","333","321","61903"]]}}}"#
        let plain = try TencentProvider.parseHistoricalCandles(
            Data(neverAdjusted.utf8), symbol: symbol, wireSymbol: "sz001309", period: .day, adjustment: .forward)
        #expect(plain.map(\.close) == [321.43])

        // The substitution stays an error when the source *does* offer an adjusted
        // series: an absent key then means something else went wrong.
        let bothSeriesButWrongInterval = #"""
        {"code":0,"data":{"sz001309":{"day":[["2026-10-12","332.53","321.43","333","321","61903"]],
        "qfqweek":[["2026-10-12","236.45","228.522","236.786","228.214","61903"]]}}}
        """#
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(bothSeriesButWrongInterval.utf8), symbol: symbol, wireSymbol: "sz001309",
                period: .day, adjustment: .forward)
        }
    }
}
