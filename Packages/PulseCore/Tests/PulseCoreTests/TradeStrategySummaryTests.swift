import Foundation
import Testing
@testable import PulseCore

@Suite("Strategy rounds and sector exposure")
struct TradeStrategySummaryTests {
    private func trade(_ kind: PositionTransaction.Kind, _ price: Double, _ quantity: Double,
                       day: Double, strategy: String? = nil, fee: Double? = 0) -> PositionTransaction {
        let date = Date(timeIntervalSince1970: 1_700_000_000 + day * 86_400)
        return .init(kind: kind, price: price, quantity: quantity, date: date, createdAt: date,
                     fee: fee, review: .init(followedPlan: true, strategy: strategy))
    }

    @Test("Partial exits are one round, recorded fees are not subtracted twice, open rounds excluded")
    func roundsAndFees() {
        let item = WatchItem(symbol: .init(market: .us, code: "AAPL"), displayName: "Apple", transactions: [
            trade(.buy, 10, 100, day: 0, strategy: "回踩", fee: 10),
            trade(.sell, 12, 50, day: 1, fee: 5), trade(.sell, 11, 50, day: 2, fee: 5),
            trade(.buy, 10, 10, day: 3, strategy: "突破")
        ])
        let rows = TradeStrategySummary.make(from: [item])
        #expect(rows.count == 1)
        #expect(rows[0].strategy == "回踩")
        #expect(rows[0].sampleCount == 1)
        #expect(abs((rows[0].realizedPnL ?? 0) - 130) < 0.00001)
        #expect(rows[0].followedPlanYesCount == 3)
    }

    @Test("Short rounds, losses, currencies, and calibration boundaries stay distinct")
    func shortsAndCalibrations() {
        let us = WatchItem(symbol: .init(market: .us, code: "AAPL"), displayName: "Apple", transactions: [
            trade(.sell, 12, 10, day: 0, strategy: "回踩"), trade(.buy, 10, 10, day: 1),
            trade(.buy, 10, 10, day: 2, strategy: "回踩"), trade(.sell, 9, 10, day: 3),
            trade(.adjustment, 10, 10, day: 4), trade(.sell, 15, 10, day: 5)
        ])
        let cn = WatchItem(symbol: .init(market: .sh, code: "600000"), displayName: "Test", transactions: [
            trade(.buy, 10, 10, day: 0, strategy: "回踩"), trade(.sell, 11, 10, day: 1)
        ])
        let rows = TradeStrategySummary.make(from: [us, cn])
        #expect(rows.count == 2)
        let usd = rows.first { $0.currencyCode == "USD" }!
        #expect(usd.sampleCount == 2)
        #expect(usd.realizedPnL == 10)
        #expect(usd.payoffRatio == 2)
        #expect(TradeStrategySummary.make(from: [us, cn], query: "Apple").count == 1)
    }

    @Test("Sector grouping reuses deduplicated gross exposure and splits currencies")
    func sectors() {
        let a = SymbolID(market: .us, code: "AAPL"), b = SymbolID(market: .us, code: "NVDA")
        let positions = [
            PortfolioAllocation.Position(symbol: a, name: "A", quantity: 1, price: 100, currencyCode: "USD"),
            PortfolioAllocation.Position(symbol: b, name: "B", quantity: -1, price: 100, currencyCode: "USD"),
            PortfolioAllocation.Position(symbol: a, name: "duplicate", quantity: 1, price: 100, currencyCode: "USD")
        ]
        let rows = SectorExposure.make(allocation: PortfolioAllocation.calculate(positions: positions), sectors: [a: "科技", b: "科技"])
        #expect(rows.count == 1)
        #expect(rows[0].holdings.count == 2)
        #expect(rows[0].percent == 100)
        #expect(rows[0].exposure == 200)
    }

    @Test("Reversals split rounds without repeating fees or reviews and filter by closing month")
    func reversalsAndMonth() {
        let trades = [
            trade(.buy, 10, 10, day: 0, strategy: "回踩", fee: 1),
            trade(.sell, 12, 15, day: 60, strategy: "反转", fee: 3),
            trade(.buy, 11, 5, day: 61, fee: 2)
        ]
        let item = WatchItem(symbol: .init(market: .us, code: "AAPL"), displayName: "Apple", transactions: trades)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(TradeStrategySummary.make(from: [item], selectedMonth: trades[0].date, calendar: calendar).isEmpty)
        let rows = TradeStrategySummary.make(from: [item], selectedMonth: trades[1].date, calendar: calendar)
        #expect(rows.count == 2)
        let closedLong = rows.first { $0.strategy == "混合策略" }!
        let closedShort = rows.first { $0.strategy == "反转" }!
        #expect(abs((closedLong.realizedPnL ?? 0) - 16) < 0.00001)
        #expect(closedShort.realizedPnL == 3)
        #expect(closedLong.followedPlanYesCount == 2)
        #expect(closedShort.followedPlanYesCount == 1)
        #expect(rows.allSatisfy { $0.sampleCount == 1 && $0.missingFeeCount == 0 })
    }
}
