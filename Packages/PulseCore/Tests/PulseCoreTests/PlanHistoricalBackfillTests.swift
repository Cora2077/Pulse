import Foundation
import Testing
@testable import PulseCore

/// Direct historical backfill: entering a fill that already happened against a
/// plan that is already `.done`.
///
/// The ordinary record route is a promise being kept — it attaches a real trade
/// to a live intention and is allowed to close the plan when the aggregate
/// reaches its size. Backfill is the opposite direction: the plan is closed and
/// the trade is only now being written down. The whole point of the feature is
/// that this never requires reviving the plan to `.active` first, so most of
/// what these tests check is what a backfill does *not* do — it does not reopen
/// a stopped plan, it does not invent a `.active` revision, and it does not
/// write anything at all when it refuses.
///
/// The guards that protect ordinary recording are checked here too, because the
/// cheapest way to get backfill wrong is to relax one of them "just for the
/// backfill path". Default behaviour, the stale stamp, the duplicate id, the
/// payload contract, the destination account, and the sale allocation all have
/// to answer exactly as they did before.
@MainActor @Suite("Plan historical backfill")
struct PlanHistoricalBackfillTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")
    private let accountSymbol = SymbolID(market: .us, code: "AAPL")

    /// A past date, used wherever the test is about the date travelling through
    /// rather than about "now". Backfill exists to enter trades that happened
    /// before the plan was closed, so a historical date is the normal case.
    private let pastDate = Date(timeIntervalSince1970: 1_600_000_000)

    private func withStore(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.PlanBackfill.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        try body(store)
    }

    /// The cross-account fixture: accounts enabled, the instrument known in the
    /// source ledger and in both destinations a plan fill can land in.
    private func withCrossAccountStore(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.PlanBackfill.account.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.withBrokerageAccount(.financing) { store.add(SymbolInfo(symbol: symbol, name: "Apple")) }
        try body(store)
    }

    /// Closes a plan by hand, which is the state backfill is for. Returns the
    /// stored plan so the caller can carry its exact `updatedAt` stamp.
    @discardableResult
    private func stop(_ store: WatchlistStore, _ plan: TradePlan) throws -> TradePlan {
        var closed = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
        closed.status = .done
        #expect(store.setTradePlan(closed, for: symbol))
        return try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
    }

    private func entry(_ store: WatchlistStore, _ id: UUID) throws -> TradePlanEntry {
        try #require(store.tradePlanEntries.first { $0.plan.id == id })
    }

    @discardableResult
    private func backfill(
        _ store: WatchlistStore,
        _ plan: TradePlan,
        price: Double,
        quantity: Double,
        date: Date? = nil,
        fee: Double? = nil,
        note: String? = nil,
        transactionID: UUID = UUID(),
        expectedPlanUpdatedAt: Date? = nil,
        fundingSource: PositionFundingSource? = nil,
        brokerageAccountID: BrokerageAccountID? = nil,
        salePortionQuantities: [UUID: Double]? = nil,
        expectedAllocationRevision: UUID? = nil
    ) throws -> PositionTransaction {
        try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: price, quantity: quantity,
            date: date ?? pastDate, fee: fee, note: note,
            transactionID: transactionID,
            expectedPlanUpdatedAt: expectedPlanUpdatedAt,
            fundingSource: fundingSource,
            brokerageAccountID: brokerageAccountID,
            salePortionQuantities: salePortionQuantities,
            expectedAllocationRevision: expectedAllocationRevision,
            historicalBackfill: true
        )
    }

    // MARK: - The entrance predicate

    @Test("A stopped, unfinished plan is backfillable; active, cancelled and complete ones are not")
    func backfillPredicate() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))

            // Active: the ordinary record route's business, not backfill's.
            #expect(try entry(store, plan.id).canBackfillFill == false)

            let closed = try stop(store, plan)
            #expect(try entry(store, plan.id).canBackfillFill)
            #expect(try entry(store, plan.id).displayState == .stopped)

            // Fully filled: nothing left to backfill, and the predicate says so.
            var filled = closed
            filled.status = .active
            #expect(store.setTradePlan(filled, for: symbol))
            let live = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: 10, quantity: 100,
                date: pastDate, fee: nil, note: nil, expectedPlanUpdatedAt: live.updatedAt
            )
            let complete = try entry(store, plan.id)
            #expect(complete.displayState == .filled)
            #expect(complete.canBackfillFill == false)

            // Cancelled: the user gave up, which is a different decision from
            // stopping short and is never read as "the fill is missing". A
            // cancelled plan with nothing filled derives `.abandoned`; its raw
            // status alone rules it out of backfill either way.
            let givenUpPlan = TradePlan(kind: .buy, price: 20, quantity: 50)
            #expect(store.setTradePlan(givenUpPlan, for: symbol))
            var cancelled = try #require(store.item(for: symbol)?.plans.first { $0.id == givenUpPlan.id })
            cancelled.status = .cancelled
            #expect(store.setTradePlan(cancelled, for: symbol))
            let givenUp = try entry(store, givenUpPlan.id)
            #expect(givenUp.plan.status == .cancelled)
            #expect(givenUp.filledQuantity == 0)
            #expect(givenUp.displayState == .abandoned)
            #expect(givenUp.canBackfillFill == false)

            // A cancelled plan that *was* fully filled still derives `.filled`:
            // complete records outrank the raw status, and neither is
            // backfillable.
            var filledAndAbandoned = complete.plan
            filledAndAbandoned.status = .cancelled
            #expect(store.setTradePlan(filledAndAbandoned, for: symbol))
            let completeAbandoned = try entry(store, plan.id)
            #expect(completeAbandoned.displayState == .filled)
            #expect(completeAbandoned.canBackfillFill == false)
        }
    }

    @Test("An invalid payload is never backfillable, however stopped it looks")
    func invalidPayloadIsNotBackfillable() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            // A malformed plan read straight out of the model — the store would
            // never store it, and the predicate must not offer to fill it.
            var broken = closed
            broken.price = .nan
            let item = try #require(store.item(for: symbol))
            let entry = TradePlanEntry(symbol: symbol, plan: broken, transactions: item.transactions)
            #expect(entry.canBackfillFill == false)
        }
    }

    // MARK: - Partial, full, and a different actual price

    @Test("A partial backfill records the real fill and leaves the plan stopped")
    func partialBackfillStaysStopped() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            let revisions = closed.history?.map(\.id) ?? []

            let transaction = try backfill(
                store, closed, price: 9.5, quantity: 40,
                expectedPlanUpdatedAt: closed.updatedAt
            )

            let after = try entry(store, plan.id)
            #expect(after.plan.status == .done, "a partial backfill must not reopen the plan")
            #expect(after.filledQuantity == 40 && after.remainingQuantity == 60)
            #expect(after.plan.quantity == 100)
            // The reported fill is the fact; the plan's price is the intention.
            #expect(transaction.price == 9.5 && transaction.quantity == 40)
            #expect(transaction.planExecution?.configuration.price == 10,
                    "the snapshot keeps the plan's own target, not the reported price")
            // Backfill itself appends no revision at all: no revival entry, no
            // new configuration. The only history a plan has is the one its
            // edits put there.
            #expect(after.plan.history?.map(\.id) ?? [] == revisions)
            // The snapshot it wrote records the plan as it actually was — a
            // stopped plan — rather than a temporarily revived `.active`.
            #expect(transaction.planExecution?.configuration.status == .done)
            #expect(after.plan.status != .active)
        }
    }

    @Test("A backfill that completes the plan derives the real filled state")
    func fullBackfillBecomesFilled() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)

            _ = try backfill(store, closed, price: 10.4, quantity: 100,
                             expectedPlanUpdatedAt: closed.updatedAt)

            let after = try entry(store, plan.id)
            #expect(after.displayState == .filled)
            #expect(after.filledQuantity == 100 && after.remainingQuantity == 0)
            #expect(after.averageFillPrice == 10.4)
            #expect(after.plan.status == .done)
        }
    }

    @Test("The actual price and the historical date are recorded verbatim, never inferred from the plan")
    func actualPriceAndDateAreNotInferred() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            let stamp = closed.updatedAt

            let transaction = try backfill(
                store, closed, price: 8.25, quantity: 30,
                date: pastDate, fee: 1.5, note: "  entered late  ",
                expectedPlanUpdatedAt: stamp
            )

            #expect(transaction.date == pastDate)
            #expect(transaction.date != stamp, "the fill date is the trade's, not the plan's last edit")
            #expect(transaction.price == 8.25)
            #expect(transaction.fee == 1.5)
            #expect(transaction.note == "entered late")
            // The snapshot is the plan's configuration, so it carries the
            // plan's own target and its `.done` status rather than the fill's.
            let snapshot = try #require(transaction.planExecution?.configuration)
            #expect(snapshot.price == 10)
            #expect(snapshot.quantity == 100)
            #expect(snapshot.status == .done)
            #expect(snapshot.createdAt == closed.createdAt)
            #expect(try entry(store, plan.id).lastFillDate == pastDate)
        }
    }

    // MARK: - Refusals leave nothing behind

    @Test("Default recording still refuses a done plan, and backfill still refuses active and cancelled")
    func statusGateIsTwoWay() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            let stopped = store.item(for: symbol)

            // The default did not move: a `.done` plan is still refused.
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try store.recordTradePlanFill(
                    symbol: symbol, planID: plan.id, price: 10, quantity: 10,
                    date: pastDate, fee: nil, note: nil,
                    expectedPlanUpdatedAt: closed.updatedAt
                )
            }
            #expect(store.item(for: symbol) == stopped)

            // And backfill is not a general "any status" bypass.
            var active = closed
            active.status = .active
            #expect(store.setTradePlan(active, for: symbol))
            let live = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            let liveItem = store.item(for: symbol)
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try backfill(store, live, price: 10, quantity: 10,
                             expectedPlanUpdatedAt: live.updatedAt)
            }
            #expect(store.item(for: symbol) == liveItem)

            var cancelled = live
            cancelled.status = .cancelled
            #expect(store.setTradePlan(cancelled, for: symbol))
            let givenUp = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            let givenUpItem = store.item(for: symbol)
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try backfill(store, givenUp, price: 10, quantity: 10,
                             expectedPlanUpdatedAt: givenUp.updatedAt)
            }
            #expect(store.item(for: symbol) == givenUpItem)
        }
    }

    @Test("A fully filled plan is refused under backfill, even though it is raw .done")
    func fullyFilledPlanIsRefused() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            var filled = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            filled.status = .done
            #expect(store.setTradePlan(filled, for: symbol))
            // Record through the ordinary path while it is briefly active, so
            // the aggregate really is complete, then close it.
            var reopen = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            reopen.status = .active
            #expect(store.setTradePlan(reopen, for: symbol))
            let live = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: 10, quantity: 100,
                date: pastDate, fee: nil, note: nil, expectedPlanUpdatedAt: live.updatedAt
            )
            let complete = try entry(store, plan.id)
            #expect(complete.remainingQuantity == 0)
            #expect(complete.canBackfillFill == false)

            let baseline = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try backfill(store, complete.plan, price: 10, quantity: 5,
                             expectedPlanUpdatedAt: complete.plan.updatedAt)
            }
            #expect(store.syncSnapshot() == baseline)
        }
    }

    @Test("An invalid payload, a stale stamp and a duplicate id write nothing")
    func invalidInputsWriteNothing() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            let baseline = store.syncSnapshot()

            #expect(throws: TradePlanExecutionError.invalidFill) {
                try backfill(store, closed, price: .nan, quantity: 10,
                             expectedPlanUpdatedAt: closed.updatedAt)
            }
            #expect(store.syncSnapshot() == baseline)

            #expect(throws: TradePlanExecutionError.invalidFill) {
                try backfill(store, closed, price: 10, quantity: 0,
                             expectedPlanUpdatedAt: closed.updatedAt)
            }
            #expect(store.syncSnapshot() == baseline)

            // A stale stamp: the plan moved after this sheet was built.
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try backfill(store, closed, price: 10, quantity: 10,
                             expectedPlanUpdatedAt: .distantPast)
            }
            #expect(store.syncSnapshot() == baseline)

            // A duplicate id takes the whole tree into account, not just this
            // item, and is refused before any value changes.
            let first = try backfill(store, closed, price: 10, quantity: 10,
                                     expectedPlanUpdatedAt: closed.updatedAt)
            let moved = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            let afterFirst = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.duplicateTransactionID) {
                try backfill(store, moved, price: 10, quantity: 10,
                             transactionID: first.id,
                             expectedPlanUpdatedAt: moved.updatedAt)
            }
            #expect(store.syncSnapshot() == afterFirst)
        }
    }

    // MARK: - Cross-account backfill

    @Test("A cross-account backfill keeps the source plan and lands the buy in the destination")
    func crossAccountBackfill() throws {
        try withCrossAccountStore { store in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(plan, for: symbol))
            var closed = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            closed.status = .done
            #expect(store.setTradePlan(closed, for: symbol))
            let stopped = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })

            let transaction = try backfill(
                store, stopped, price: 99, quantity: 100,
                expectedPlanUpdatedAt: stopped.updatedAt,
                fundingSource: .own, brokerageAccountID: .financing
            )

            // The fill is filed in the destination the user named...
            let destination = try #require(store.brokeragePortfolio(for: .financing)
                .items.first { $0.symbol == symbol })
            #expect(destination.transactions.map(\.id) == [transaction.id])
            #expect(destination.positionQuantity == 100)

            // ...and the source ledger keeps the plan and its own ledger.
            let source = try #require(store.brokeragePortfolio(for: .unassigned)
                .items.first { $0.symbol == symbol })
            #expect(source.transactions.isEmpty)
            #expect(source.plans.map(\.id) == [plan.id])

            // The aggregate is what closes the plan, exactly as ordinary
            // recording does, and the snapshot records where the plan lives.
            let after = try entry(store, plan.id)
            #expect(after.filledQuantity == 100 && after.remainingQuantity == 0)
            #expect(after.displayState == .filled)
            #expect(transaction.planExecution?.sourceAccountID == .unassigned)
            #expect(transaction.planExecution?.configuration.price == 100)
            #expect(transaction.planExecution?.configuration.status == .done)
        }
    }

    @Test("A destination refusal under backfill leaves both ledgers untouched")
    func crossAccountRefusalIsAtomic() throws {
        try withCrossAccountStore { store in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            var closed = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            closed.status = .done
            #expect(store.setTradePlan(closed, for: symbol))
            let stopped = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            let baseline = store.syncSnapshot()

            #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
                try backfill(store, stopped, price: 100, quantity: 10,
                             expectedPlanUpdatedAt: stopped.updatedAt,
                             fundingSource: .own, brokerageAccountID: .unassigned)
            }
            #expect(store.syncSnapshot() == baseline)
        }
    }

    // MARK: - Sells keep their allocation protections

    @Test("A stopped sell that is bound to a card still refuses a stale allocation under backfill")
    func staleSaleAllocationIsRefused() throws {
        try withStore { store in
            // A recorded buy gives the ledger a reconciled card to bind.
            let buy = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            let buyFill = try store.recordTradePlanFill(
                symbol: symbol, planID: buy.id, price: 10, quantity: 100,
                date: pastDate, fee: nil, note: nil
            )
            let item = try #require(store.item(for: symbol))
            let portion = try #require(item.positionAllocation?.portions.first)
            #expect(portion.origin.transactionID == buyFill.id)

            // A second, unbound card in the same pool, created by its own buy.
            // It is the sibling the sale must never touch: the binding, not the
            // pool, is the claim, so a bound 40-share sale leaves its 25 alone.
            let siblingBuy = TradePlan(kind: .buy, price: 10, quantity: 25, positionPool: .tactical)
            #expect(store.setTradePlan(siblingBuy, for: symbol))
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: siblingBuy.id, price: 10, quantity: 25,
                date: pastDate, fee: nil, note: nil
            )
            let seeded = try #require(store.item(for: symbol))
            #expect(seeded.positionQuantity == 125)
            let sibling = try #require(seeded.positionAllocation?.portions.first { $0.id != portion.id })
            #expect(sibling.quantity == 25)
            let siblingBefore = sibling.quantity

            var sell = TradePlan(kind: .sell, price: 12, quantity: 40, positionPool: .tactical)
            sell.positionPortionID = portion.id
            #expect(store.setTradePlan(sell, for: symbol))
            var closed = try #require(store.item(for: symbol)?.plans.first { $0.id == sell.id })
            closed.status = .done
            #expect(store.setTradePlan(closed, for: symbol))
            let stopped = try #require(store.item(for: symbol)?.plans.first { $0.id == sell.id })
            #expect(store.item(for: symbol)?.plans.first { $0.id == sell.id }
                .map { TradePlanEntry(symbol: symbol, plan: $0, transactions: store.transactionsForPlan(symbol)) }
                .map(\.canBackfillFill) == true)

            // A revision the sheet no longer holds is refused before any write.
            let baseline = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.staleAllocation) {
                try backfill(store, stopped, price: 12, quantity: 40,
                             expectedPlanUpdatedAt: stopped.updatedAt,
                             expectedAllocationRevision: UUID())
            }
            #expect(store.syncSnapshot() == baseline)

            // The live revision works, and the sale consumes exactly its card.
            let quantityBefore = try #require(store.item(for: symbol)?.positionQuantity)
            let revision = try #require(store.item(for: symbol)?.positionAllocation?.revision)
            let planStampBefore = try #require(
                store.item(for: symbol)?.plans.first { $0.id == sell.id }?.updatedAt)
            let transaction = try backfill(store, stopped, price: 12, quantity: 40,
                             expectedPlanUpdatedAt: stopped.updatedAt,
                             expectedAllocationRevision: revision)
            let after = try #require(store.item(for: symbol))
            #expect(after.positionQuantity == quantityBefore - 40)
            #expect(after.positionAllocation?.changes.last?.reason == "Recorded plan sale")
            // The bound card is the one that paid: 100 → 60.
            #expect(after.positionAllocation?.portions.first { $0.id == portion.id }?.quantity == 60)
            // The stopped plan is stamped by the write but not revived, and the
            // transaction keeps the plan's own target beside its `.done` status.
            let movedPlan = try #require(after.plans.first { $0.id == sell.id })
            #expect(movedPlan.status == .done)
            #expect(movedPlan.updatedAt != planStampBefore)
            let snapshot = try #require(transaction.planExecution?.configuration)
            #expect(snapshot.status == .done)
            #expect(snapshot.price == 12)
            #expect(snapshot.positionPortionID == portion.id)
            // Only the bound card moved: the sibling the plan never named is
            // whole, and nothing spent it on the plan's behalf.
            #expect(after.positionAllocation?.portions.first { $0.id == sibling.id }?.quantity
                == siblingBefore)
        }
    }

    // MARK: - A successful historical sale

    /// The whole point of a backfill sale, exercised end to end: a mature buy
    /// already sits in the ledger, a stopped sell plan is bound to that one
    /// card, and the fill is written down after the fact at a price the plan
    /// never asked for.
    ///
    /// Everything here is a fact that has to survive the write and nothing
    /// else: the plan keeps the user's `.done` stamp and gains a *fresh* one,
    /// the raw `.done` status is never traded for a derived `.active`, the
    /// recorded transaction snapshots the binding beside the plan's own target
    /// price, and the position gives up exactly the bound card's 40 shares
    /// while a sibling card is left whole.
    @Test("A stopped sale bound to its own card backfills 40 shares at the real price and depletes exactly that card")
    func successfulBoundSaleBackfill() throws {
        try withStore { store in
            // A real, mature buy: its card is what a sell plan can bind to, and
            // it is the source a backfill sale must draw from.
            let buy = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            let buyFill = try store.recordTradePlanFill(
                symbol: symbol, planID: buy.id, price: 10, quantity: 100,
                date: pastDate, fee: nil, note: nil
            )
            let seeded = try #require(store.item(for: symbol))
            #expect(seeded.positionQuantity == 100)
            let bound = try #require(seeded.positionAllocation?.portions.first)
            #expect(bound.origin.transactionID == buyFill.id)
            #expect(bound.quantity == 100)

            // The sell that was written down late, bound to that exact card.
            var sell = TradePlan(kind: .sell, price: 12, quantity: 40, positionPool: .tactical)
            sell.positionPortionID = bound.id
            #expect(store.setTradePlan(sell, for: symbol))
            let stopped = try stop(store, sell)
            // A stopped plan with size left is exactly what backfill is offered.
            #expect(try entry(store, sell.id).canBackfillFill)
            let storedStamp = try #require(
                store.item(for: symbol)?.plans.first { $0.id == sell.id }?.updatedAt)
            #expect(stopped.updatedAt == storedStamp)

            // The sale date is the trade's own — after the seeded buy, before
            // "now" — and the price is not the plan's target.
            let sellDate = Date(timeIntervalSince1970: 1_700_000_000)
            #expect(sellDate > buyFill.date)
            let revisionBefore = try #require(store.item(for: symbol)?.positionAllocation?.revision)

            let transaction = try backfill(
                store, stopped, price: 11.4, quantity: 40,
                date: sellDate,
                expectedPlanUpdatedAt: stopped.updatedAt,
                expectedAllocationRevision: revisionBefore
            )

            // The write itself: a real sell at the price it really paid, on the
            // date it really happened.
            #expect(transaction.kind == .sell)
            #expect(transaction.price == 11.4)
            #expect(transaction.quantity == 40)
            #expect(transaction.date == sellDate)
            #expect(transaction.price != stopped.price, "the reported price is not the plan's target")

            // The full 40/40 backfill completes the plan's own size, so the
            // derived state is filled — without the raw `.done` ever being
            // traded for a revival to `.active` along the way. The plan did
            // move, so its stamp is fresh rather than the one the sheet was
            // built against.
            let after = try #require(store.item(for: symbol))
            let moved = try #require(after.plans.first { $0.id == sell.id })
            #expect(moved.status == .done, "the user's own stop is not undone by a backfill")
            #expect(moved.updatedAt != stopped.updatedAt, "a backfill that wrote a fill stamps the plan")
            #expect(try entry(store, sell.id).filledQuantity == 40)
            #expect(try entry(store, sell.id).remainingQuantity == 0)
            #expect(try entry(store, sell.id).displayState == .filled)

            // The snapshot is the plan *as it was*: stopped, at its own target,
            // still naming the card it was bound to.
            let snapshot = try #require(transaction.planExecution?.configuration)
            #expect(snapshot.status == .done)
            #expect(snapshot.price == 12)
            #expect(snapshot.quantity == 40)
            #expect(snapshot.positionPortionID == bound.id)

            // The ledger fell by the fill, and the allocation moved exactly the
            // bound card — 100 → 60 — while a sibling is untouched.
            #expect(after.positionQuantity == 60)
            let allocation = try #require(after.positionAllocation)
            #expect(allocation.revision != revisionBefore, "a sale reissues the allocation revision")
            #expect(allocation.changes.last?.reason == "Recorded plan sale")
            let depleted = try #require(allocation.portions.first { $0.id == bound.id })
            #expect(depleted.quantity == 60, "the bound card gives up exactly the 40 shares sold")
            #expect(after.positionQuantity == allocation.portions.reduce(0) { $0 + $1.quantity })
        }
    }

    @Test("Two partial bound-sale backfills leave the plan stopped and stamp fresh revisions each time")
    func partialBoundSaleBackfillsAccumulate() throws {
        try withStore { store in
            let buy = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: buy.id, price: 10, quantity: 100,
                date: pastDate, fee: nil, note: nil
            )
            let bound = try #require(store.item(for: symbol)?.positionAllocation?.portions.first)

            var sell = TradePlan(kind: .sell, price: 12, quantity: 40, positionPool: .tactical)
            sell.positionPortionID = bound.id
            #expect(store.setTradePlan(sell, for: symbol))
            let stopped = try stop(store, sell)
            let firstRevision = try #require(store.item(for: symbol)?.positionAllocation?.revision)

            // Ten shares first. The plan stays stopped and keeps a new stamp.
            _ = try backfill(store, stopped, price: 11, quantity: 10,
                             expectedPlanUpdatedAt: stopped.updatedAt,
                             expectedAllocationRevision: firstRevision)
            let afterFirst = try #require(store.item(for: symbol))
            let firstPlan = try #require(afterFirst.plans.first { $0.id == sell.id })
            #expect(firstPlan.status == .done)
            #expect(firstPlan.updatedAt != stopped.updatedAt)
            #expect(afterFirst.positionQuantity == 90)
            #expect(afterFirst.positionAllocation?.portions.first { $0.id == bound.id }?.quantity == 90)

            // The stopped plan is still backfillable for the rest, and the
            // revision the first write produced is the one the second needs.
            #expect(try entry(store, sell.id).canBackfillFill)
            let secondRevision = try #require(afterFirst.positionAllocation?.revision)
            #expect(secondRevision != firstRevision)

            _ = try backfill(store, firstPlan, price: 12.5, quantity: 30,
                             expectedPlanUpdatedAt: firstPlan.updatedAt,
                             expectedAllocationRevision: secondRevision)
            let afterSecond = try #require(store.item(for: symbol))
            let secondPlan = try #require(afterSecond.plans.first { $0.id == sell.id })
            #expect(secondPlan.status == .done)
            #expect(secondPlan.updatedAt != firstPlan.updatedAt)
            #expect(afterSecond.positionQuantity == 60)
            #expect(afterSecond.positionAllocation?.portions.first { $0.id == bound.id }?.quantity == 60)
            #expect(afterSecond.positionAllocation?.revision != secondRevision)
            // The two writes together complete the plan's intended 40 — and
            // completing it is what finally derives `.filled`, not a revival to
            // `.active` along the way.
            #expect(try entry(store, sell.id).filledQuantity == 40)
            #expect(try entry(store, sell.id).remainingQuantity == 0)
            #expect(try entry(store, sell.id).displayState == .filled)
        }
    }

    // MARK: - Deletion core behaviour is untouched

    @Test("Deleting a fully filled plan keeps its transaction, ledger and allocation")
    func deletingAFilledPlanKeepsTheTrade() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(plan, for: symbol))
            let closed = try stop(store, plan)
            let transaction = try backfill(
                store, closed, price: 10, quantity: 100,
                expectedPlanUpdatedAt: closed.updatedAt
            )
            let filled = try #require(store.item(for: symbol))
            #expect(filled.positionQuantity == 100)
            let allocation = try #require(filled.positionAllocation)

            #expect(store.deleteTradePlan(plan.id, for: symbol))

            let after = try #require(store.item(for: symbol))
            #expect(after.plans.isEmpty, "the plan itself is gone")
            #expect(after.transactions.map(\.id) == [transaction.id],
                    "deleting a plan is not a way to delete the trade it recorded")
            #expect(after.positionQuantity == 100)
            #expect(after.positionAllocation?.portions.map(\.quantity) == allocation.portions.map(\.quantity))
            #expect(after.positionAllocation?.portions.map(\.id) == allocation.portions.map(\.id))
            #expect(!after.positionAllocationNeedsReconciliation)
        }
    }
}
