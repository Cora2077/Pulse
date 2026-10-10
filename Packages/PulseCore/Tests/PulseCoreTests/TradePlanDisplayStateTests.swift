import Foundation
import Testing
@testable import PulseCore

/// The read-only presentation model: what a plan row shows once the fills
/// actually linked to it are taken into account, rather than the status the
/// user last typed.
@Suite("Trade plan display state")
struct TradePlanDisplayStateTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")
    private let otherSymbol = SymbolID(market: .us, code: "MSFT")

    private func plan(
        kind: TradePlan.Kind = .buy,
        price: Double = 10,
        quantity: Double = 100,
        status: TradePlan.Status = .active
    ) -> TradePlan {
        TradePlan(kind: kind, price: price, quantity: quantity, status: status)
    }

    /// A fill linked the modern way, through the immortal plan execution.
    private func fill(
        _ plan: TradePlan,
        quantity: Double,
        price: Double = 10,
        kind: PositionTransaction.Kind = .buy,
        date: TimeInterval = 1_700_000_000,
        id: UUID = UUID()
    ) -> PositionTransaction {
        PositionTransaction(
            id: id, kind: kind, price: price, quantity: quantity,
            date: Date(timeIntervalSince1970: date),
            planExecution: TradePlanExecution(planID: plan.id, configuration: TradePlanConfiguration(plan: plan))
        )
    }

    private func entry(_ plan: TradePlan, _ transactions: [PositionTransaction] = []) -> TradePlanEntry {
        TradePlanEntry(symbol: symbol, plan: plan, transactions: transactions)
    }

    // MARK: - Display state

    @Test("A plan marked done with no trades is not filled")
    func doneWithoutTradesIsNotFilled() {
        let stopped = entry(plan(status: .done))
        #expect(stopped.displayState == .stopped)
        #expect(stopped.filledQuantity == 0 && stopped.remainingQuantity == 100)
        #expect(stopped.averageFillPrice == nil && stopped.lastFillDate == nil)
    }

    @Test("Actual fills read as filled under every raw status")
    func fillsWinOverRawStatus() {
        for status in TradePlan.Status.allCases {
            let subject = plan(status: status)
            let filled = entry(subject, [fill(subject, quantity: 100)])
            #expect(filled.displayState == .filled, "status \(status.rawValue)")
            #expect(filled.remainingQuantity == 0 && filled.filledQuantity == 100)
        }
    }

    @Test("Partial fills fall back to the raw decision")
    func partialFillsFallBackToStatus() {
        let active = plan(status: .active)
        #expect(entry(active, [fill(active, quantity: 40)]).displayState == .waiting)

        let cancelled = plan(status: .cancelled)
        #expect(entry(cancelled, [fill(cancelled, quantity: 40)]).displayState == .abandoned)

        let done = plan(status: .done)
        #expect(entry(done, [fill(done, quantity: 40)]).displayState == .stopped)
    }

    @Test("An untouched plan is waiting and reports no fill history")
    func untouchedIsWaiting() {
        let waiting = entry(plan())
        #expect(waiting.displayState == .waiting)
        #expect(waiting.averageFillPrice == nil && waiting.lastFillDate == nil)
        #expect(entry(plan(status: .cancelled)).displayState == .abandoned)
    }

    // MARK: - Actual price and date

    @Test("The average is the quantity-weighted actual price, taken from the fills not the target")
    func averageIsWeightedActualPrice() {
        // The plan's own price (10) and any quote are irrelevant here.
        var subject = plan(price: 99, quantity: 100)
        subject.kind = .buy
        let progress = TradePlanExecutionProgress(plan: subject, transactions: [
            fill(subject, quantity: 30, price: 8),
            fill(subject, quantity: 70, price: 12),
        ])
        #expect(progress.filledQuantity == 100)
        // (8 * 30 + 12 * 70) / 100 = 10.8 — not 99, the plan's target.
        #expect(progress.averageFillPrice == 10.8)

        let row = entry(subject, [
            fill(subject, quantity: 30, price: 8),
            fill(subject, quantity: 70, price: 12),
        ])
        #expect(row.averageFillPrice == 10.8)
        #expect(row.averageFillPrice != subject.price)
    }

    @Test("The date is the latest actual fill date, and the mean survives a huge quantity")
    func latestDateAndFiniteMean() {
        let subject = plan(quantity: 1e308)
        let progress = TradePlanExecutionProgress(plan: subject, transactions: [
            fill(subject, quantity: 1e308, price: 5),
            fill(subject, quantity: 1e308, price: 7, date: 1_800_000_000),
        ])
        #expect(progress.lastFillDate == Date(timeIntervalSince1970: 1_800_000_000))
        // The exact quantity-weighted mean remains valid even if totals overflow.
        #expect(progress.filledQuantity.isFinite)
        #expect(progress.remainingQuantity == 0)
        #expect(progress.averageFillPrice?.isFinite == true)
        #expect(progress.averageFillPrice == 6)
    }

    @Test("A fill with an unusable date or price is left out of the price and date")
    func invalidFillMetadataIsExcluded() {
        let subject = plan()
        let good = fill(subject, quantity: 10, price: 4, date: 1_700_000_000)
        var broken = fill(subject, quantity: 10, price: 6, date: 1_900_000_000)
        broken.price = .nan
        let progress = TradePlanExecutionProgress(plan: subject, transactions: [good, broken])
        #expect(progress.filledQuantity == 10)
        #expect(progress.averageFillPrice == 4)
        #expect(progress.lastFillDate == Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Deduplication and direction

    @Test("A legacy fill id is counted once even when the trade is listed twice")
    func legacyFillCountedOnce() {
        var subject = plan(quantity: 100)
        let trade = fill(subject, quantity: 60, price: 5)
        subject.filledTransactionID = trade.id
        let progress = TradePlanExecutionProgress(plan: subject, transactions: [trade, trade])
        #expect(progress.filledQuantity == 60 && progress.remainingQuantity == 40)
        #expect(progress.averageFillPrice == 5)
        #expect(entry(subject, [trade, trade]).displayState == .waiting)
    }

    @Test("Opposite-direction and non-positive fills are excluded from size and price")
    func mismatchedDirectionAndInvalidPriceAreExcluded() {
        let subject = plan(kind: .buy, quantity: 100)
        let wrongWay = fill(subject, quantity: 50, price: 1, kind: .sell)
        let zeroQuantity = fill(subject, quantity: 0, price: 1)
        let freeUnits = fill(subject, quantity: 50, price: 0)
        let real = fill(subject, quantity: 20, price: 3, date: 1_700_000_500)

        let progress = TradePlanExecutionProgress(
            plan: subject, transactions: [wrongWay, zeroQuantity, freeUnits, real]
        )
        #expect(progress.filledQuantity == 20)
        #expect(progress.averageFillPrice == 3)
        #expect(progress.lastFillDate == Date(timeIntervalSince1970: 1_700_000_500))
    }

    // MARK: - Bounded reach, ordering, and summary

    @Test("A fully filled stale-active plan is neither live nor reached")
    func fullStaleActiveIsNotLive() {
        let stale = plan(price: 160, quantity: 100, status: .active)   // quote would reach it
        let live = plan(price: 100, quantity: 100)
        let quotes: (SymbolID) -> Double? = { [self.symbol: 150, self.otherSymbol: 150][$0] }

        let filled = TradePlanEntry(symbol: symbol, plan: stale, transactions: [fill(stale, quantity: 100)])
        let waiting = TradePlanEntry(symbol: otherSymbol, plan: live)

        #expect(filled.displayState == .filled)
        #expect(!TradePlanOverview.isReached(filled, currentPrice: quotes))

        let summary = TradePlanOverview.summary([filled, waiting], currentPrice: quotes)
        #expect(summary.live == 1 && summary.reached == 0 && summary.settled == 1)

        // It sorts with the settled rows, behind the one plan still open.
        let ordered = TradePlanOverview.ordered([filled, waiting], currentPrice: quotes)
        #expect(ordered.map(\.plan.id) == [live.id, stale.id])
    }

    @Test("Usual entries keep the ordering and counts they had before")
    func usualEntriesAreUnchanged() {
        let reached = plan(price: 160)
        let waiting = plan(price: 100)
        let stopped = plan(price: 160, status: .done)
        let quotes: (SymbolID) -> Double? = { _ in 150 }
        let entries = [entry(reached), entry(waiting), entry(stopped)]

        let ordered = TradePlanOverview.ordered(entries, currentPrice: quotes)
        #expect(ordered.map(\.plan.id) == [reached.id, waiting.id, stopped.id])

        let summary = TradePlanOverview.summary(entries, currentPrice: quotes)
        #expect(summary.live == 2 && summary.reached == 1 && summary.settled == 1)
        #expect(summary.total == 3)
    }

    @Test("A reached count is always a subset of the live count")
    func reachedIsAlwaysASubsetOfLive() {
        let stale = plan(price: 160, quantity: 100)          // quote reaches, fills close it
        let open = plan(price: 160, quantity: 100)
        let quotes: (SymbolID) -> Double? = { [self.symbol: 150, self.otherSymbol: 150][$0] }
        let entries = [
            TradePlanEntry(symbol: symbol, plan: stale, transactions: [fill(stale, quantity: 100)]),
            TradePlanEntry(symbol: otherSymbol, plan: open),
        ]
        let summary = TradePlanOverview.summary(entries, currentPrice: quotes)
        // Only the open plan can be reached; the closed one cannot inflate the
        // count past the number of live rows.
        #expect(summary.reached <= summary.live)
        #expect(summary.live == 1 && summary.reached == 1 && summary.settled == 1)
    }
}
