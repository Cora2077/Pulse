import Foundation
import Testing
@testable import PulseCore

/// Public endpoints only. Serialized and paced to avoid a burst against Tencent.
@Suite("Tencent index history (live)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PULSE_LIVE_TESTS"] == "1"))
struct TencentIndexHistoryLiveTests {
    @Test("China indices have historical daily bars", arguments: [
        SymbolID(index: .shanghaiComposite),
        SymbolID(index: .chiNext),
        SymbolID(market: .sh, code: "000688")
    ])
    func dailyHistory(symbol: SymbolID) async throws {
        try await Task.sleep(for: .seconds(2))
        let candles = try await TencentProvider().candles(for: symbol, period: .day, count: 250)
        ProviderContractTests.assertCandleContract(candles)
        #expect(candles.count == 250)
        #expect(Set(candles.map(\.time)).count == candles.count)
        print("TENCENT_INDEX_HISTORY \(symbol) day rows=\(candles.count)")
    }

    @Test("STAR 50 has native weekly and monthly history", arguments: [CandlePeriod.week, .month])
    func longerPeriods(period: CandlePeriod) async throws {
        try await Task.sleep(for: .seconds(2))
        let symbol = SymbolID(market: .sh, code: "000688")
        let candles = try await TencentProvider().candles(for: symbol, period: period, count: 260)
        ProviderContractTests.assertCandleContract(candles)
        #expect(candles.count >= 24)
        #expect(candles.count <= 260)
        #expect(Set(candles.map(\.time)).count == candles.count)
        print("TENCENT_INDEX_HISTORY \(symbol) \(period.rawValue) rows=\(candles.count)")
    }
}
