import Foundation
import Testing
@testable import PulseCore

@Suite("Position valuation")
struct PositionValuationTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_750_000_000 + TimeInterval(offset) * 86_400)
    }

    private func quote(_ price: Double, previousClose: Double = 100, timestamp: Date? = nil) -> Quote {
        Quote(
            symbol: symbol,
            price: price,
            previousClose: previousClose,
            timestamp: timestamp ?? day(20)
        )
    }

    @Test("Average and diluted costs split holding P&L differently while total remains average floating plus realized")
    func averageAndDilutedBasis() throws {
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [
            PositionTransaction(kind: .buy, price: 100, quantity: 10, date: day(0), createdAt: day(0)),
            PositionTransaction(kind: .sell, price: 150, quantity: 4, date: day(1), createdAt: day(1)),
        ])

        let average = try #require(PositionValuation(item: item, quote: quote(90), basis: .average, now: day(20)))
        let diluted = try #require(PositionValuation(item: item, quote: quote(90), basis: .diluted, now: day(20)))

        #expect(average.quantity == 6)
        #expect(average.averageCost == 100)
        #expect(average.costPrice == 100)
        #expect(average.marketValue == 540)
        #expect(average.holdingPnL == -60)
        #expect(average.realizedPnL == 200)
        #expect(average.totalPnL == 140)
        #expect(diluted.costPrice == 200.0 / 3)
        #expect(abs(diluted.holdingPnL - 140) < 0.0001)
        #expect(diluted.totalPnL == average.totalPnL)
    }

    @Test("Trade fees already included in cost and realized P&L are not subtracted again")
    func feesAreNotDoubleCounted() throws {
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [
            PositionTransaction(kind: .buy, price: 100, quantity: 10, date: day(0), createdAt: day(0), fee: 10),
            PositionTransaction(kind: .sell, price: 120, quantity: 2, date: day(1), createdAt: day(1), fee: 5),
        ])

        let valuation = try #require(PositionValuation(item: item, quote: quote(110), basis: .average, now: day(20)))

        #expect(valuation.averageCost == 101)
        #expect(valuation.holdingPnL == 72)
        #expect(valuation.realizedPnL == 33)
        #expect(valuation.totalFees == 15)
        #expect(valuation.totalPnL == 105)
    }

    @Test("Short positions use signed quantity for market value and holding P&L")
    func shortPosition() throws {
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [
            PositionTransaction(kind: .sell, price: 150, quantity: 10, date: day(0), createdAt: day(0), fee: 5),
        ])

        let valuation = try #require(PositionValuation(item: item, quote: quote(140), basis: .average, now: day(20)))

        #expect(valuation.quantity == -10)
        #expect(valuation.averageCost == 149.5)
        #expect(valuation.marketValue == -1_400)
        #expect(valuation.holdingPnL == 95)
        #expect(valuation.totalPnL == 95)
        #expect(valuation.totalFees == 5)
    }

    @Test("Legacy lots keep their cost and a flat ledger has no open valuation")
    func legacyLotsAndClosedLedger() throws {
        let legacy = WatchItem(
            symbol: symbol,
            displayName: "Apple",
            lots: [CostLot(price: 100, quantity: 3)]
        )
        let legacyValuation = try #require(PositionValuation(
            item: legacy,
            quote: quote(120),
            basis: .diluted,
            now: day(20)
        ))
        #expect(legacyValuation.quantity == 3)
        #expect(legacyValuation.averageCost == 100)
        #expect(legacyValuation.costPrice == 100)
        #expect(legacyValuation.holdingPnL == 60)
        #expect(legacyValuation.totalPnL == 60)
        #expect(legacyValuation.realizedPnL == 0)
        #expect(legacyValuation.totalFees == 0)

        let closed = WatchItem(symbol: symbol, displayName: "Apple", transactions: [
            PositionTransaction(kind: .buy, price: 100, quantity: 2, date: day(0), createdAt: day(0)),
            PositionTransaction(kind: .sell, price: 120, quantity: 2, date: day(1), createdAt: day(1)),
        ])
        #expect(closed.realizedPnL == 40)
        #expect(PositionValuation(item: closed, quote: quote(130), basis: .average, now: day(20)) == nil)
    }

    @Test("Calibration changes the open holding cost but retains prior realized P&L")
    func calibrationKeepsRealizedPnL() throws {
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [
            PositionTransaction(kind: .buy, price: 100, quantity: 10, date: day(0), createdAt: day(0)),
            PositionTransaction(kind: .sell, price: 120, quantity: 5, date: day(1), createdAt: day(1)),
            PositionTransaction(kind: .adjustment, price: 200, quantity: 5, date: day(2), createdAt: day(2)),
        ])

        let average = try #require(PositionValuation(item: item, quote: quote(210), basis: .average, now: day(20)))
        let diluted = try #require(PositionValuation(item: item, quote: quote(210), basis: .diluted, now: day(20)))

        #expect(average.quantity == 5)
        #expect(average.averageCost == 200)
        #expect(average.realizedPnL == 100)
        #expect(average.holdingPnL == 50)
        #expect(average.totalPnL == 150)
        #expect(diluted.holdingPnL == 50)
        #expect(diluted.totalPnL == 150)
    }

    @Test("Items without supported position history have no position valuation")
    func noPositionAndUnsupportedInstrument() {
        let empty = WatchItem(symbol: symbol, displayName: "Apple")
        #expect(PositionValuation(item: empty, quote: quote(120), basis: .average, now: day(20)) == nil)

        let indexSymbol = SymbolID(index: .sp500)
        let index = WatchItem(
            symbol: indexSymbol,
            displayName: "S&P 500",
            transactions: [PositionTransaction(kind: .adjustment, price: 500, quantity: 1)]
        )
        let indexQuote = Quote(symbol: indexSymbol, price: 500, previousClose: 490)
        #expect(PositionValuation(item: index, quote: indexQuote, basis: .average, now: day(20)) == nil)
    }
}
