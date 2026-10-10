import Foundation
import Testing
@testable import PulseCore

/// Bound sell plans inside the dry-run projection.
///
/// A *bound* sell plan names one exact position card (`positionPortionID`)
/// rather than a pool, so the projection has to answer a narrower question than
/// the pool and position passes do: is *that card* still there, and is it big
/// enough for every plan that names it? The tests below are built from
/// synthetic positions only — no store, no ledger, no quote provider — because
/// the subject is arithmetic over inputs the caller already holds.
///
/// Two invariants run through all of them:
///
/// * a broken binding is refused on its own terms and never rescued by a
///   sibling card of the same pool; and
/// * a refused plan is removed *before* the aggregate passes, so it can neither
///   drag a valid neighbour into an over-sell warning nor contribute proceeds
///   to the accepted sell estimate.
@Suite("Position sale projection")
struct PositionSaleProjectionTests {
    private let aapl = SymbolID(market: .us, code: "AAPL")

    // MARK: - Fixtures

    private func card(_ id: UUID, _ quantity: Double, pool: PositionPool = .unassigned) -> PositionPortion {
        PositionPortion(id: id, quantity: quantity, pool: pool, origin: .init(kind: .snapshot))
    }

    private func position(
        _ symbol: SymbolID,
        _ quantity: Double,
        _ price: Double?,
        pools: [PositionPool: Double] = [:],
        portions: [PositionPortion] = []
    ) -> PoolBudgetProjection.Position {
        .init(
            symbol: symbol, name: symbol.displayCode, quantity: quantity, price: price,
            currencyCode: "USD", sector: nil, poolQuantities: pools, portions: portions
        )
    }

    private func sell(
        _ symbol: SymbolID,
        price: Double,
        quantity: Double,
        portionID: UUID?,
        pool: PositionPool? = nil,
        planID: UUID = UUID(),
        transactions: [PositionTransaction] = []
    ) -> TradePlanEntry {
        TradePlanEntry(
            symbol: symbol,
            plan: TradePlan(
                id: planID, kind: .sell, price: price, quantity: quantity,
                positionPool: pool, positionPortionID: portionID
            ),
            transactions: transactions
        )
    }

    /// The warning a specific plan received, if any.
    private func warning(
        _ result: PoolBudgetProjection.Result, planID: UUID
    ) -> PoolBudgetProjection.OverSellWarning? {
        result.overSellWarnings.first { $0.planID == planID }
    }

    // MARK: - The exact source, with a larger sibling in the same pool

    @Test("A bound plan is judged against its own small card, not the bigger sibling")
    func boundPlanUsesItsOwnCardNotTheSibling() throws {
        // One pool holds 100 shares: the bound card has 30, a sibling has 70.
        // A 20-share bound sale fits the card and must be accepted even though
        // the pool total is far larger.
        let small = UUID()
        let sibling = UUID()
        let entry = sell(aapl, price: 100, quantity: 20, portionID: small, pool: .tactical)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.tactical: 100],
                                portions: [card(small, 30, pool: .tactical),
                                           card(sibling, 70, pool: .tactical)])],
            entries: [entry]
        )

        #expect(result.overSellWarnings.isEmpty)
        let usd = try #require(result.currency("USD"))
        // 100 held − 20 sold. The sale is real and rehearsed.
        #expect(usd.holdingsAfter == 8_000)
        #expect(usd.plannedSellAmount == 2_000)
    }

    @Test("A bound plan larger than its own card fails even when the pool could cover it")
    func boundPlanOverItsOwnCardFailsDespiteTheSibling() throws {
        // The pool holds 100 and the plan asks for 50, so every pool-level check
        // would pass. The bound card holds only 30 — that is the whole point of
        // a binding, and the warning has to name the card, not the pool.
        let small = UUID()
        let entry = sell(aapl, price: 100, quantity: 50, portionID: small, pool: .tactical)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.tactical: 100],
                                portions: [card(small, 30, pool: .tactical),
                                           card(UUID(), 70, pool: .tactical)])],
            entries: [entry]
        )

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(small))
        #expect(warned.available == 30)
        #expect(warned.requested == 50)
        let usd = try #require(result.currency("USD"))
        // The refused sale moves nothing and raises no money.
        #expect(usd.holdingsAfter == 10_000)
        #expect(usd.plannedSellAmount == 0)
    }

    // MARK: - Two plans overbooking one source

    @Test("Two plans overbooking one card warn together instead of spending it twice")
    func twoPlansOverbookOneCard() throws {
        // 40 shares on the card; two plans want 25 each. Letting the first in
        // and refusing the second would invent an ordering the user never
        // stated, so both are refused and both are told why.
        let shared = UUID()
        let first = sell(aapl, price: 100, quantity: 25, portionID: shared, pool: .strategic)
        let second = sell(aapl, price: 100, quantity: 25, portionID: shared, pool: .strategic)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 40, 100, pools: [.strategic: 40],
                                portions: [card(shared, 40, pool: .strategic)])],
            entries: [first, second]
        )

        #expect(result.overSellWarnings.count == 2)
        for entry in [first, second] {
            let warned = try #require(warning(result, planID: entry.id))
            #expect(warned.scope == .portion(shared))
            // The card is really there, so the reader is told its true size.
            #expect(warned.available == 40)
            #expect(warned.requested == 50)
            #expect(warned.shortfall == 10)
        }
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsAfter == 4_000)
        #expect(usd.plannedSellAmount == 0)
    }

    @Test("Two plans that together fit one card are both accepted")
    func twoPlansSharingACardWithinItsSizeBothPass() throws {
        let shared = UUID()
        let first = sell(aapl, price: 100, quantity: 10, portionID: shared, pool: .strategic)
        let second = sell(aapl, price: 100, quantity: 15, portionID: shared, pool: .strategic)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 40, 100, pools: [.strategic: 40],
                                portions: [card(shared, 40, pool: .strategic)])],
            entries: [first, second]
        )

        #expect(result.overSellWarnings.isEmpty)
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsAfter == 1_500)
        #expect(usd.plannedSellAmount == 2_500)
    }

    // MARK: - Missing and moved sources

    @Test("A card that is gone leaves the bound plan with zero available, not a sibling")
    func missingSourceReportsZeroAvailable() throws {
        let gone = UUID()
        let entry = sell(aapl, price: 100, quantity: 10, portionID: gone, pool: .tactical)

        // The pool holds plenty on other cards; none of them is the one named.
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.tactical: 100],
                                portions: [card(UUID(), 100, pool: .tactical)])],
            entries: [entry]
        )

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(gone))
        #expect(warned.available == 0)
        #expect(warned.shortfall == 10)
    }

    @Test("A card refiled under another pool reads as moved, not as available elsewhere")
    func movedSourceReadsAsMissing() throws {
        let moved = UUID()
        // The plan still names `.tactical`; the user has since filed the card
        // under `.strategic`.
        let entry = sell(aapl, price: 100, quantity: 10, portionID: moved, pool: .tactical)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.strategic: 100, .tactical: 0],
                                portions: [card(moved, 100, pool: .strategic)])],
            entries: [entry]
        )

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(moved))
        #expect(warned.available == 0)
    }

    @Test("A duplicate card id is ambiguous and reads as missing")
    func duplicateCardIDIsAmbiguous() throws {
        let duplicated = UUID()
        let entry = sell(aapl, price: 100, quantity: 10, portionID: duplicated, pool: .unassigned)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.unassigned: 100],
                                portions: [card(duplicated, 50), card(duplicated, 50)])],
            entries: [entry]
        )

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(duplicated))
        #expect(warned.available == 0)
    }

    @Test("A bound plan on an instrument with no position has no source")
    func boundPlanWithoutPositionHasNoSource() throws {
        let orphan = UUID()
        let entry = sell(aapl, price: 100, quantity: 10, portionID: orphan, pool: .tactical)

        let result = PoolBudgetProjection.calculate(positions: [], entries: [entry])

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(orphan))
        #expect(warned.available == 0)
    }

    // MARK: - Isolation from the aggregate passes

    @Test("A refused bound plan does not drag a valid sibling into a shortfall")
    func refusedBoundPlanDoesNotFailValidSiblings() throws {
        // 100 shares; the unbound plan sells 60 and a pool-checked plan sells
        // 30, so 90 is comfortably covered. The 500-share bound plan is refused
        // on its own card, and because it is removed first the two valid plans
        // are not made to look over-committed by a phantom 500.
        let small = UUID()
        let boundID = UUID()
        let unbound = sell(aapl, price: 100, quantity: 60, portionID: nil)
        let pooled = sell(aapl, price: 100, quantity: 30, portionID: nil, pool: .unassigned)
        let bound = sell(aapl, price: 100, quantity: 500, portionID: small, pool: .unassigned, planID: boundID)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.unassigned: 100],
                                portions: [card(small, 10)])],
            entries: [unbound, pooled, bound]
        )

        #expect(result.overSellWarnings.count == 1)
        #expect(result.overSellWarnings.first?.planID == boundID)
        #expect(result.overSellWarnings.first?.scope == .portion(small))
        let usd = try #require(result.currency("USD"))
        // 100 − 60 − 30. The refused 500 never touches the projection.
        #expect(usd.holdingsAfter == 1_000)
        #expect(usd.plannedSellAmount == 9_000)
    }

    @Test("A refused bound sale raises no proceeds and cannot fund a buy")
    func refusedBoundSaleExcludesItsProceeds() throws {
        // Without the binding the 300-share sale would cover the 20 000 buy and
        // even leave spendable cash. Refused, it is not proceeds at all.
        let small = UUID()
        let buy = TradePlanEntry(
            symbol: aapl,
            plan: TradePlan(kind: .buy, price: 100, quantity: 200)
        )
        let bound = sell(aapl, price: 100, quantity: 300, portionID: small, pool: .unassigned)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.unassigned: 100],
                                portions: [card(small, 10)])],
            entries: [buy, bound],
            cash: ["USD": 0]
        )

        let usd = try #require(result.currency("USD"))
        #expect(usd.plannedSellAmount == 0)
        // Pending sales never funded buys anyway; this pins that a *refused*
        // one certainly does not.
        #expect(usd.availableCash == -20_000)
        #expect(usd.cashShortfall == 20_000)
    }

    @Test("A future buy cannot back a bound sale")
    func futureBuyDoesNotBackABoundSale() throws {
        // The card holds 10 now. A 90-share buy plan is active, and the sale
        // would fit the *after* position — but a bound sale spends a card that
        // already exists.
        let small = UUID()
        let buy = TradePlanEntry(symbol: aapl, plan: TradePlan(kind: .buy, price: 100, quantity: 90))
        let bound = sell(aapl, price: 100, quantity: 50, portionID: small, pool: .unassigned)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 10, 100, pools: [.unassigned: 10],
                                portions: [card(small, 10)])],
            entries: [buy, bound]
        )

        let warned = try #require(warning(result, planID: bound.id))
        #expect(warned.scope == .portion(small))
        #expect(warned.available == 10)
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsAfter == 10_000)
    }

    // MARK: - Coexistence with unbound behaviour

    @Test("A valid bound plan and an unbound plan coexist and both apply")
    func validBoundAndUnboundCoexist() throws {
        // Card A holds 20 in `.tactical`; the bound plan sells 20 of it. The
        // unbound plan sells 30 with no pool named, so it consumes total shares
        // and needs reconciliation rather than a guessed bucket.
        let boundCard = UUID()
        let sibling = UUID()
        let bound = sell(aapl, price: 100, quantity: 20, portionID: boundCard, pool: .tactical)
        let unbound = sell(aapl, price: 100, quantity: 30, portionID: nil)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.tactical: 50, .unassigned: 50],
                                portions: [card(boundCard, 20, pool: .tactical),
                                           card(sibling, 30, pool: .tactical),
                                           card(UUID(), 50)])],
            entries: [bound, unbound]
        )

        #expect(result.overSellWarnings.isEmpty)
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsAfter == 5_000)
        #expect(usd.plannedSellAmount == 5_000)
        // The poolless sale is flagged as needing reconciliation, exactly as it
        // is today without any binding in play.
        #expect(result.unresolvedPoolPositions.contains(aapl))
        let tactical = try #require(usd.pools.first { $0.pool == .tactical })
        #expect(tactical.projectedAmount == 3_000)
    }

    @Test("Unbound plans keep the exact over-sell behaviour they had before")
    func unboundBehaviourUnchanged() throws {
        // No portions are supplied at all: the classic pool-vs-position shape.
        let pooled = sell(aapl, price: 100, quantity: 40, portionID: nil, pool: .tactical)
        let loose = sell(aapl, price: 100, quantity: 20, portionID: nil)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 50, 100, pools: [.tactical: 20, .unassigned: 30])],
            entries: [pooled, loose]
        )

        // 60 requested against 50 held: the position pass catches it, scoped to
        // `.position`, with no portion case involved.
        #expect(result.overSellWarnings.count == 2)
        #expect(result.overSellWarnings.allSatisfy { $0.scope == .position })
        #expect(result.overSellWarnings.allSatisfy { $0.available == 50 })
    }

    @Test("A bound plan that is not a sell is left to the ordinary passes")
    func bindingOnABuyIsIgnored() throws {
        // `positionPortionID` is only meaningful on a sell. A stray one on a buy
        // must not turn the plan into a refused sale.
        let card_ = UUID()
        let buy = TradePlanEntry(
            symbol: aapl,
            plan: TradePlan(kind: .buy, price: 100, quantity: 10, positionPortionID: card_)
        )

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 0, 100, portions: [card(card_, 5)])],
            entries: [buy]
        )

        #expect(result.overSellWarnings.isEmpty)
        let usd = try #require(result.currency("USD"))
        #expect(usd.plannedBuyAmount == 1_000)
    }

    @Test("A fully filled bound plan contributes nothing and warns about nothing")
    func fullyFilledBoundPlanIsSilent() throws {
        let small = UUID()
        let planID = UUID()
        let fill = PositionTransaction(
            id: UUID(), kind: .sell, price: 100, quantity: 10, date: .now,
            planExecution: TradePlanExecution(
                planID: planID,
                configuration: TradePlanConfiguration(
                    plan: TradePlan(kind: .sell, price: 100, quantity: 10)
                )
            )
        )
        let entry = TradePlanEntry(
            symbol: aapl,
            plan: TradePlan(id: planID, kind: .sell, price: 100, quantity: 10,
                            positionPool: .unassigned, positionPortionID: small),
            transactions: [fill]
        )

        #expect(entry.remainingQuantity == 0)
        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.unassigned: 100],
                                portions: [card(small, 10)])],
            entries: [entry]
        )

        #expect(result.overSellWarnings.isEmpty)
        #expect(result.rejectedEntryCount == 0)
    }

    // MARK: - Scope identity

    @Test("Portion warnings carry the card id so two cards never collapse into one")
    func portionWarningsStayDistinct() throws {
        let first = UUID()
        let second = UUID()
        let firstPlan = sell(aapl, price: 100, quantity: 90, portionID: first, pool: .tactical)
        let secondPlan = sell(aapl, price: 100, quantity: 90, portionID: second, pool: .tactical)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.tactical: 100],
                                portions: [card(first, 30, pool: .tactical),
                                           card(second, 70, pool: .tactical)])],
            entries: [firstPlan, secondPlan]
        )

        let firstWarning = try #require(warning(result, planID: firstPlan.id))
        let secondWarning = try #require(warning(result, planID: secondPlan.id))
        #expect(firstWarning.scope == .portion(first))
        #expect(firstWarning.available == 30)
        #expect(secondWarning.scope == .portion(second))
        #expect(secondWarning.available == 70)
        #expect(result.overSellWarnings.count == 2)
    }

    @Test("A legacy observation card answers an unassigned binding, as every other total reads it")
    func legacyObservationCardMatchesUnassignedPlan() throws {
        // The retired purpose is canonicalized through `effectivePurpose`
        // everywhere else, and a binding has to follow the same rule or a
        // legacy card would read as moved.
        let legacy = UUID()
        let entry = sell(aapl, price: 100, quantity: 10, portionID: legacy, pool: .unassigned)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 100, 100, pools: [.unassigned: 100],
                                portions: [card(legacy, 100, pool: .observation)])],
            entries: [entry]
        )

        #expect(result.overSellWarnings.isEmpty)
        let usd = try #require(result.currency("USD"))
        #expect(usd.holdingsAfter == 9_000)
    }

    @Test("A zero-quantity card is not a source")
    func zeroQuantityCardIsNotASource() throws {
        let empty = UUID()
        let entry = sell(aapl, price: 100, quantity: 10, portionID: empty, pool: .tactical)

        let result = PoolBudgetProjection.calculate(
            positions: [position(aapl, 0, 100, pools: [:], portions: [card(empty, 0, pool: .tactical)])],
            entries: [entry]
        )

        let warned = try #require(warning(result, planID: entry.id))
        #expect(warned.scope == .portion(empty))
        #expect(warned.available == 0)
    }
}
