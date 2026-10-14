import Foundation
import Testing
@testable import PulseCore

@Suite("Market store candle cache")
struct MarketStoreCandleCacheTests {
    private static func key(_ index: Int) -> CandleCacheKey {
        CandleCacheKey(symbol: SymbolID(market: .us, code: "CACHE\(index)"), period: .day)
    }

    private static func candles(seed: Double) -> [Candle] {
        [Candle(time: Date(timeIntervalSince1970: 1_800_000_000), open: seed, high: seed + 1,
                low: seed - 1, close: seed, volume: 1_000)]
    }

    @MainActor
    @Test("Cache stays at its cap and evicts the oldest keys first")
    func evictsOldestBeyondCapacity() async throws {
        let store = MarketStore()
        let capacity = MarketStore.candleCacheCapacity
        let overflow = 5
        let total = capacity + overflow

        // Insert in order, sleeping just enough that each `fetchedAt` is strictly
        // later than the previous one — otherwise the sort is ambiguous and the
        // test would not be pinning "oldest first".
        for index in 1...total {
            store.cache(candles: Self.candles(seed: Double(index)), for: Self.key(index))
            try await Task.sleep(for: .milliseconds(2))
        }

        // Only `cachedCandles` can observe the private dictionary. Reading with a
        // generous max age counts exactly the retained keys.
        let retained = (1...total).filter { store.cachedCandles(for: Self.key($0), maxAge: .infinity) != nil }
        #expect(retained.count == capacity,
                "cache must settle at its cap, not keep growing (retained \(retained.count))")
        #expect(Set(retained) == Set((overflow + 1)...total),
                "the oldest \(overflow) keys must be the ones evicted")
        for index in 1...overflow {
            #expect(store.cachedCandles(for: Self.key(index), maxAge: .infinity) == nil,
                    "evicted key \(index) must read as a miss so it re-fetches")
        }
        #expect(store.cachedCandles(for: Self.key(total), maxAge: .infinity)?.first?.close == Double(total),
                "the newest key must survive with its own candles")
    }

    @MainActor
    @Test("Refreshing an existing key does not evict anything")
    func refreshKeepsCapacity() async throws {
        let store = MarketStore()
        let capacity = MarketStore.candleCacheCapacity
        for index in 1...capacity {
            store.cache(candles: Self.candles(seed: Double(index)), for: Self.key(index))
        }
        try await Task.sleep(for: .milliseconds(2))
        // Re-writing an existing key must not push the cache over its cap.
        store.cache(candles: Self.candles(seed: 99), for: Self.key(1))

        let retained = (1...capacity).filter { store.cachedCandles(for: Self.key($0), maxAge: .infinity) != nil }
        #expect(retained.count == capacity, "a refresh must not evict a key")
        #expect(store.cachedCandles(for: Self.key(1), maxAge: .infinity)?.first?.close == 99,
                "the refreshed key must carry the new candles")
    }

    @MainActor
    @Test("Max age still gates reads")
    func maxAgeStillGatesReads() {
        let store = MarketStore()
        store.cache(candles: Self.candles(seed: 5), for: Self.key(1))
        #expect(store.cachedCandles(for: Self.key(1), maxAge: .infinity) != nil)
        #expect(store.cachedCandles(for: Self.key(1), maxAge: 0) == nil,
                "a zero max age must read as stale")
    }
}
