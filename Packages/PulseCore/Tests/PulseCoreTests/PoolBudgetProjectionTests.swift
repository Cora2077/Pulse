import Foundation
import Testing
@testable import PulseCore

/// Covers the arithmetic that a budget page must not get wrong: partial fills,
/// currency separation, missing quotes, over-selling, overflow, and the
/// difference between net cash and a purchase budget.
@Suite("Pool budget projection")
struct PoolBudgetProjectionTests {
    private let aapl = SymbolID(market: .us, code: "AAPL")
    private let msft = SymbolID(market: .us, code: "MSFT")
    private let hk = SymbolID(market: .hk, code: "0700")

    private func position(
        _ symbol: SymbolID,
        _ quantity: Double,
        _ price: Double?,
        currency: String? = "USD",
        sector: String? = nil,
        pools: [PositionPool: Double] = [:]
    ) -> PoolBudgetProjection.Position {
        .init(
            symbol: symbol, name: symbol.displayCode, quantity: quantity, price: price,
            currencyCode: currency, sector: sector, poolQuantities: pools
        )
    }

    private func plan(
        _ symbol: SymbolID,
        kind: TradePlan.Kind,
        price: Double,
        quantity: Double,
        status: TradePlan.Status = .active,
        pool: PositionPool? = nil,
        transactions: [PositionTransaction] = []
    ) -> TradePlanEntry {
        TradePlanEntry(
            symbol: symbol,
            plan: TradePlan(kind: kind, price: price, quantity: quantity, status: status, positionPool: pool),
            transactions: transactions
        )
    }

    // MARK: - Partial fill

    @Test("A plan filled 80 of 200 contributes only the remaining 120")
    func partialFillUsesRemainingQuantity() throws {
        let planID = UUID()
        // 80 units already bought at 10 against a 200-unit plan.
        let fill = PositionTransaction(
            id: UUID(), kind: .buy, price: 10, quantity: 80, date: .now,
            planExecution: TradePlanExecution(
                planID: planID,
                configuration: TradePlanConfiguration(plan: TradePlan(kind: .buy, price: 10, quantity: 200))
            )
        )
        let entry = TradePlanEntry(
            symbol: aapl,
            plan: TradePlan(id: planID, kind: .buy, price: 10, quantity: 200),
            transactions: [fill]
        )

        #expect(entry.remainingQuantity == 120)
        // The plan's original quantity is preserved, never rewritten.
        #expect(entry.plan.quantity == 200)

        let result = PoolBudgetProjection.calculate(positions: [], entries: [entry])
        let usd = try #require(result.currency("USD"))
        // Money is sized by the remaining 120, not the original 200.
        #expect(usd.plannedBuyAmount == 1200)
    }

    @Test("A fully filled plan contributes nothing and is not an error")
    func fullyFilledPlanContributesNothing() throws {
        let planID = UUID()
        let fill = PositionTransaction(
            id: UUID(), kind: .buy, price: 10, quantity: 200, date: .now,
            planExecution: TradePlanExecution(
                planID: planID,
                configuration: TradePlanConfiguration(plan: TradePlan(kind: .buy, price: 10, quantity: 200))
            )
        )
        let entry = TradePlanEntry(
            symbol: aapl,
            plan: TradePlan(id: planID, kind: .buy, price: 10, quantity: 200),
            transactions: [fill]
        )

        #expect(entry.remainingQuantity == 0)
        let result = PoolBudgetProjection.calculate(positions: [], entries: [entry])
        #expect(result.rejectedEntryCount == 0)
        // No currency is invented for a plan that has nothing left to do.
        #expect(result.currencies.isEmpty)
    }

    // MARK: - Currency separation

    @Test("Currencies are never mixed and there is no pseudo-total")
    func currenciesStaySeparate() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, 10, 100, currency: "USD"),
                position(hk, 100, 400, currency: "HKD"),
            ],
            entries: [
                plan(aapl, kind: .buy, price: 90, quantity: 2),
                plan(hk, kind: .buy, price: 380, quantity: 10),
            ],
            cash: ["USD": 5_000, "HKD": 10_000]
        )

        #expect(result.currencies.count == 2)
        let usd = try #require(result.currency("USD"))
        let hkd = try #require(result.currency("HKD"))

        #expect(usd.holdingsBefore == 1_000)
        #expect(usd.plannedBuyAmount == 180)
        #expect(hkd.holdingsBefore == 40_000)
        #expect(hkd.plannedBuyAmount == 3_800)
        // USD cash never covers HKD buys.
        #expect(usd.availableCash == 4_820)
        #expect(hkd.availableCash == 6_200)
        #expect(!usd.hasOverflow && !hkd.hasOverflow)
    }

    @Test("A plan on a symbol with no holding still lands in its own currency")
    func planWithoutHoldingStillCounts() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [],
            entries: [plan(hk, kind: .buy, price: 400, quantity: 5)]
        )
        let hkd = try #require(result.currency("HKD"))
        #expect(hkd.plannedBuyAmount == 2_000)
        #expect(hkd.holdingsBefore == 0)
    }

    // MARK: - Missing quotes

    @Test("A missing quote is unknown, not zero, and is reported")
    func missingQuoteIsReportedNotZeroed() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, 10, 100),
                position(msft, 4, nil),
            ],
            entries: []
        )

        #expect(result.unvaluablePriceCount == 1)
        #expect(result.isIncomplete)
        let usd = try #require(result.currency("USD"))
        // Only the priced position counts; the unpriced one is excluded rather
        // than added as 0.
        #expect(usd.holdingsBefore == 1_000)
        #expect(usd.unvaluableQuantity == 1)
    }

    @Test("Non-finite and non-positive quotes are unusable")
    func invalidQuotesAreUnusable() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, 1, .infinity),
                position(msft, 1, 0),
                position(hk, 1, -5, currency: "HKD"),
            ],
            entries: []
        )
        #expect(result.unvaluablePriceCount == 3)
        #expect(result.isIncomplete)
    }

    @Test("A missing quote makes its pool row explicitly incomplete")
    func missingQuoteMarksPoolIncomplete() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, nil, pools: [.strategic: 10])],
            entries: []
        )
        let usd = try #require(result.currency("USD"))
        let strategic = try #require(usd.pools.first { $0.pool == .strategic })
        #expect(strategic.heldAmount == 0)
        #expect(strategic.unvaluableQuantity == 1)
    }

    // MARK: - Over-selling

    @Test("Selling more than the position holds warns and does not fabricate a short")
    func overSellWarnsWithoutNegativeLong() throws {
        let entry = plan(aapl, kind: .sell, price: 120, quantity: 50)
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100)],
            entries: [entry]
        )

        #expect(result.overSellWarnings.count == 1)
        let warning = try #require(result.overSellWarnings.first)
        #expect(warning.requested == 50)
        #expect(warning.available == 10)
        #expect(warning.shortfall == 40)
        #expect(warning.scope == .position)

        let usd = try #require(result.currency("USD"))
        // Holdings after a sell plan are not driven negative; `holdingsAfter`
        // here reflects buy plans only, and no negative long is invented.
        #expect(usd.holdingsAfter >= 0)
        // The sale proceeds are reported, but never folded into available cash.
        #expect(usd.plannedSellAmount == 6_000)
    }

    @Test("Over-selling a named pool warns against that pool's verified share")
    func overSellWithinPoolUsesPoolShare() throws {
        let entry = plan(aapl, kind: .sell, price: 100, quantity: 8, pool: .tactical)
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.tactical: 3, .strategic: 7])],
            entries: [entry]
        )

        let warning = try #require(result.overSellWarnings.first)
        #expect(warning.scope == .pool(.tactical))
        #expect(warning.available == 3)
        #expect(warning.shortfall == 5)
    }

    @Test("A sell that no pool names is not falsely flagged")
    func unpooledSellWithinPositionIsFine() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 10])],
            entries: [plan(aapl, kind: .sell, price: 100, quantity: 10)]
        )
        #expect(result.overSellWarnings.isEmpty)
    }

    @Test("Selling an unheld symbol is a warning, not a short position")
    func sellingUnheldSymbolWarns() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [],
            entries: [plan(aapl, kind: .sell, price: 100, quantity: 5)]
        )
        let warning = try #require(result.overSellWarnings.first)
        #expect(warning.available == 0)
        #expect(warning.shortfall == 5)
    }

    @Test("A negative holding is flagged as an unsupported short")
    func negativeHoldingIsFlaggedAsShort() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, -5, 100)],
            entries: []
        )
        #expect(result.unsupportedShortCount == 1)
        // Shorting is not modelled, but the row is still priced so the caller
        // can show what it is being told to ignore.
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsBefore == 500)
    }

    // MARK: - Overflow and invalid input

    @Test("Overflowing money latches an error flag instead of reporting infinity")
    func overflowIsFlaggedNotSilentlyZeroed() throws {
        let huge = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, .greatestFiniteMagnitude, 100),
                position(msft, .greatestFiniteMagnitude, 100),
            ],
            entries: []
        )
        let usd = try #require(huge.currency("USD"))
        #expect(usd.hasOverflow)
        #expect(usd.holdingsAfter.isFinite)

        let bigPlan = PoolBudgetProjection.calculate(
            positions: [],
            entries: [
                plan(aapl, kind: .buy, price: .greatestFiniteMagnitude, quantity: 2),
                plan(msft, kind: .buy, price: .greatestFiniteMagnitude, quantity: 3),
            ]
        )
        let planCurrency = try #require(bigPlan.currency("USD"))
        #expect(planCurrency.hasOverflow)
        #expect(planCurrency.plannedBuyAmount.isFinite)
    }

    @Test("Invalid quantities and prices are rejected, never zeroed")
    func invalidInputIsRejected() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, .nan, 100),
                position(msft, 0, 100),
                position(hk, 5, 400, currency: "   "),
            ],
            entries: [
                plan(aapl, kind: .buy, price: 0, quantity: 1),
                plan(msft, kind: .buy, price: -5, quantity: 1),
                plan(hk, kind: .buy, price: 400, quantity: .infinity),
            ]
        )

        #expect(result.rejectedInputCount == 2)
        #expect(result.rejectedEntryCount == 3)
        #expect(result.isIncomplete)
        #expect(result.currency("USD")?.holdingsBefore == 0)
    }

    // MARK: - Net cash vs purchase budget

    @Test("Net cash subtracts buys and never adds pending sale proceeds")
    func netCashExcludesSaleProceeds() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 50)],
            entries: [
                plan(aapl, kind: .buy, price: 40, quantity: 10),   // 400 out
                plan(msft, kind: .sell, price: 60, quantity: 10),  // 600 in
            ],
            cash: ["USD": 1_000]
        )

        let usd = try #require(result.currency("USD"))
        #expect(usd.cashBalance == 1_000)
        #expect(usd.plannedBuyAmount == 400)
        #expect(usd.plannedSellAmount == 600)
        // Available cash is 1,000 − 400 only. The 600 of pending sales is not
        // money the user can spend yet, so it is deliberately excluded.
        #expect(usd.availableCash == 600)
        #expect(usd.cashShortfall == 0)
        #expect(usd.purchaseBudgetGap == 0)
    }

    @Test("The purchase budget gap is buys over the balance, floored at zero")
    func purchaseBudgetGapIgnoresPendingSales() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 50)],
            entries: [
                plan(aapl, kind: .buy, price: 100, quantity: 10),  // 1,000 out
                plan(msft, kind: .sell, price: 500, quantity: 10), // 5,000 in
            ],
            cash: ["USD": 200]
        )

        let usd = try #require(result.currency("USD"))
        #expect(usd.availableCash == -800)
        #expect(usd.cashShortfall == 800)
        // The gap does not shrink because a sale is pending.
        #expect(usd.purchaseBudgetGap == 800)
    }

    @Test("An unrecorded balance is unknown: no gap is invented")
    func unknownBalanceHasNoGap() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [],
            entries: [plan(aapl, kind: .buy, price: 100, quantity: 10)],
            cash: [:]
        )

        let usd = try #require(result.currency("USD"))
        #expect(usd.cashBalance == nil)
        #expect(usd.availableCash == nil)
        #expect(usd.cashShortfall == 0)
        #expect(usd.purchaseBudgetGap == 0)
        #expect(usd.plannedBuyAmount == 1_000)
    }

    @Test("A cash balance is carried through with its update time")
    func cashBalanceCarriesUpdateTime() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let result = PoolBudgetProjection.calculate(
            positions: [], entries: [], cash: ["USD": 42], cashUpdatedAt: ["USD": when]
        )
        let usd = try #require(result.currency("USD"))
        #expect(usd.cashBalance == 42)
        #expect(usd.cashUpdatedAt == when)
    }

    // MARK: - Pools

    @Test("A pool's projected amount is held plus buys against the user limit")
    func poolProjectionCombinesHeldAndPlanned() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 10]), position(msft, 0, 60)],
            entries: [plan(msft, kind: .buy, price: 50, quantity: 4, pool: .strategic)],
            poolLimits: ["USD": [.strategic: 1_500]]
        )

        let usd = try #require(result.currency("USD"))
        let strategic = try #require(usd.pools.first { $0.pool == .strategic })
        #expect(strategic.heldAmount == 1_000)
        #expect(strategic.plannedBuyAmount == 200)
        #expect(strategic.projectedAmount == 1_240)
        #expect(strategic.limit == 1_500)
        #expect(strategic.hasLimit)
        #expect(strategic.overLimitAmount == 0)
    }

    @Test("Exceeding a pool limit is reported as the overage")
    func poolOverLimitIsReported() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 10]), position(msft, 0, 120)],
            entries: [plan(msft, kind: .buy, price: 100, quantity: 8, pool: .strategic)],
            poolLimits: ["USD": [.strategic: 1_200]]
        )
        let strategic = try #require(result.currency("USD")?.pools.first { $0.pool == .strategic })
        #expect(strategic.projectedAmount == 1_960)
        #expect(strategic.overLimitAmount == 600)
    }

    @Test("No limit means no budget, not a zero budget")
    func missingLimitIsNoBudget() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 10])],
            entries: []
        )
        let strategic = try #require(result.currency("USD")?.pools.first { $0.pool == .strategic })
        #expect(strategic.limit == nil)
        #expect(!strategic.hasLimit)
        #expect(strategic.overLimitAmount == 0)
    }

    @Test("All active pools are emitted even when empty")
    func allPoolsAlwaysPresent() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 1, 100)],
            entries: [],
            poolLimits: ["USD": [.tactical: 500]]
        )
        let usd = try #require(result.currency("USD"))
        #expect(Set(usd.pools.map(\.pool)) == Set(PositionPool.activeCases))
        #expect(usd.pools.count == PositionPool.activeCases.count)
    }

    @Test("Unverified pool shares are reported, never guessed into a pool")
    func unassignedSharesAreFlagged() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 4])],
            entries: []
        )
        #expect(result.unresolvedPoolPositions.contains(aapl))
        let strategic = try #require(result.currency("USD")?.pools.first { $0.pool == .strategic })
        // The verified four are counted at their share.
        #expect(strategic.heldAmount == 400)
        #expect(strategic.needsReconciliation)
    }

    @Test("A fully verified allocation needs no reconciliation")
    func fullyVerifiedAllocationIsClean() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 6, .tactical: 4])],
            entries: []
        )
        #expect(result.unresolvedPoolPositions.isEmpty)
        let usd = try #require(result.currency("USD"))
        #expect(usd.pools.allSatisfy { !$0.needsReconciliation })
        #expect(usd.pools.first { $0.pool == .strategic }?.heldAmount == 600)
        #expect(usd.pools.first { $0.pool == .tactical }?.heldAmount == 400)
    }

    @Test("An unpooled sell is not attributed to any one pool's limit")
    func unpooledSellDoesNotHitPoolLimit() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.strategic: 10])],
            entries: [plan(aapl, kind: .sell, price: 100, quantity: 5)]
        )
        let usd = try #require(result.currency("USD"))
        // The unassigned sale is recorded against the default pool only.
        #expect(usd.pools.first { $0.pool == .unassigned }?.plannedSellAmount == 500)
        #expect(usd.pools.first { $0.pool == .strategic }?.plannedSellAmount == 0)
        #expect(usd.holdingsAfter == 500)
        #expect(usd.pools.first { $0.pool == .strategic }?.needsReconciliation == true)
    }

    // MARK: - Sectors

    @Test("Sector totals combine current holdings with planned buys")
    func sectorTotalsCombineHeldAndPlanned() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [
                position(aapl, 10, 100, sector: "Technology"),
                position(msft, 5, 200, sector: "Technology"),
            ],
            entries: [plan(msft, kind: .buy, price: 200, quantity: 2)]
        )
        let usd = try #require(result.currency("USD"))
        let tech = try #require(usd.sectors.first { $0.name == "Technology" })
        #expect(tech.holdingsBefore == 2_000)
        #expect(tech.plannedBuyAmount == 400)
        #expect(tech.holdingsAfter == 2_400)
    }

    @Test("A plan in a sector with no current holding still gets a row")
    func plannedBuyCreatesSectorRow() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, sector: "Technology")],
            entries: [plan(hk, kind: .buy, price: 400, quantity: 1)]
        )
        let hkd = try #require(result.currency("HKD"))
        #expect(hkd.sectors.count == 1)
        let row = try #require(hkd.sectors.first)
        #expect(row.holdingsBefore == 0)
        #expect(row.plannedBuyAmount == 400)
    }

    @Test("A holding with no sector is grouped, not dropped")
    func unsectoredHoldingIsGrouped() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 2, 100)],
            entries: []
        )
        let usd = try #require(result.currency("USD"))
        let row = try #require(usd.sectors.first)
        #expect(row.name == PoolBudgetProjection.uncategorizedSectorName)
        #expect(row.holdingsBefore == 200)
    }

    // MARK: - Whole-currency shape

    @Test("Overall holdings after combines current value with planned buys")
    func holdingsAfterCombinesValueAndBuys() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100), position(msft, 0, 60)],
            entries: [plan(msft, kind: .buy, price: 50, quantity: 3)]
        )
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsBefore == 1_000)
        #expect(usd.holdingsAfter == 1_180)
        #expect(usd.plannedBuyAmount == 150)
    }

    @Test("A settled plan is excluded entirely")
    func settledPlansAreExcluded() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [],
            entries: [plan(aapl, kind: .buy, price: 100, quantity: 10, status: .cancelled)]
        )
        #expect(result.currencies.isEmpty)
        #expect(result.rejectedEntryCount == 0)
    }

    @Test("Duplicate symbols count once, matching the app's exposure rule")
    func duplicateSymbolsCountOnce() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100), position(aapl, 10, 100)],
            entries: []
        )
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsBefore == 1_000)
    }

    @Test("A calculation with nothing at all returns an empty, clean result")
    func emptyInputIsClean() {
        let result = PoolBudgetProjection.calculate(positions: [], entries: [])
        #expect(result.currencies.isEmpty)
        #expect(!result.isIncomplete)
        #expect(result.overSellWarnings.isEmpty)
        #expect(result.unsupportedShortCount == 0)
    }
    @Test("Combined sales cannot reuse the same actual shares")
    func combinedSalesAreRejectedTogether() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 12, pools: [.strategic: 100])],
            entries: [plan(aapl, kind: .sell, price: 11, quantity: 60, pool: .strategic),
                      plan(aapl, kind: .sell, price: 11, quantity: 60, pool: .strategic)]
        )
        #expect(result.overSellWarnings.count == 2)
        #expect(result.isIncomplete)
        #expect(result.currency("USD")?.holdingsAfter == 1200)
        #expect(result.currency("USD")?.holdings.first?.afterQuantity == 100)
    }

    @Test("Quote valuation, remaining quantities and cash budget stay separate")
    func buysAndSalesShareConsistentValuation() throws {
        let buyPlan = TradePlan(kind: .buy, price: 10, quantity: 200, positionPool: .tactical)
        let fill = PositionTransaction(kind: .buy, price: 10, quantity: 80,
            planExecution: .init(planID: buyPlan.id, configuration: .init(plan: buyPlan)))
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 180, 12, sector: "Tech", pools: [.strategic: 100, .tactical: 80])],
            entries: [TradePlanEntry(symbol: aapl, plan: buyPlan, transactions: [fill]),
                      plan(aapl, kind: .sell, price: 15, quantity: 40, pool: .strategic)],
            cash: ["USD": 1000], poolLimits: ["USD": [.tactical: 2000]]
        )
        let usd = try #require(result.currency("USD"))
        #expect(usd.plannedBuyAmount == 1200)
        #expect(usd.plannedSellAmount == 600)
        #expect(usd.availableCash == -200)
        #expect(usd.purchaseBudgetGap == 200)
        #expect(usd.holdingsBefore == 2160)
        #expect(usd.holdingsAfter == 3120)
        #expect(usd.holdings.first?.afterQuantity == 260)
        #expect(usd.sectors.first?.holdingsAfter == 3120)
        #expect(usd.pools.first { $0.pool == .strategic }?.projectedAmount == 720)
        #expect(usd.pools.first { $0.pool == .tactical }?.projectedAmount == 2400)
        #expect(usd.pools.first { $0.pool == .tactical }?.overLimitAmount == 160)
    }

    @Test("A sale of unreconciled actual shares does not consume a future purchase's pool")
    func futurePoolSharesCannotBeConsumedAsActual() throws {
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 12)],
            entries: [plan(aapl, kind: .buy, price: 10, quantity: 40, pool: .tactical),
                      plan(aapl, kind: .sell, price: 15, quantity: 60)]
        )
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdings.first?.afterQuantity == 80)
        #expect(usd.pools.first { $0.pool == .tactical }?.projectedAmount == 480)
        #expect(result.unresolvedPoolPositions == [aapl])
    }

}
