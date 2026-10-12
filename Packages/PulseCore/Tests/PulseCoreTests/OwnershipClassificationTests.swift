import Foundation
import Testing
@testable import PulseCore

/// Ownership classification regressions.
///
/// Every case here was a *reproduced* defect in the audit of 2026-10-12; the
/// probes that recorded the old behaviour live in
/// `audit/ownership-2026-10-12/OwnershipAuditProbes.swift` and are evidence, not
/// expectations. This suite states what the boundary must do instead:
///
/// - a whole-ledger move keeps a plan's progress even when its fills were
///   recorded into another account;
/// - a partial move freezes a legacy `nil` source to the ledger it leaves, so
///   the source plan keeps its progress and the same fill cannot be backfilled
///   twice;
/// - a new buy cannot reach the pending-history ledger by leaving its
///   destination `nil`, on either the ordinary or the plan route;
/// - a margin record is refused by an ordinary-only destination, whole snapshot
///   unchanged;
/// - the last remaining trade can still be moved as a *selection*;
/// - a plan reference is matched on symbol + plan id + pre-move source, so a
///   plan reusing the same UUID elsewhere is never rewritten;
/// - every refusal leaves every account, including unnamed ones, byte-identical.
@MainActor @Suite("Ownership classification")
struct OwnershipClassificationTests {
    private let symbol = SymbolID(market: .us, code: "OWN")
    private let other = SymbolID(market: .us, code: "OTHER")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeStore(_ accounts: Bool = true) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "Pulse.OwnershipClassification.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        if accounts {
            store.enableBrokerageAccounts()
            for account in BrokerageAccountID.allCases {
                store.withBrokerageAccount(account) {
                    store.add(SymbolInfo(symbol: symbol, name: "Synthetic ownership"))
                    store.add(SymbolInfo(symbol: other, name: "Synthetic other"))
                }
            }
            store.selectBrokerageAccount(.unassigned)
        } else {
            store.add(SymbolInfo(symbol: symbol, name: "Synthetic ownership"))
        }
        return (store, defaults, suite)
    }

    private func buy(_ quantity: Double, price: Double = 100, funding: PositionFundingSource? = .own,
                     offset: TimeInterval = 0) -> PositionTransaction {
        PositionTransaction(kind: .buy, price: price, quantity: quantity,
                            date: day.addingTimeInterval(offset), createdAt: day.addingTimeInterval(offset),
                            fundingSource: funding)
    }

    private func item(_ store: WatchlistStore, _ account: BrokerageAccountID,
                      _ symbol: SymbolID? = nil) -> WatchItem? {
        let wanted = symbol ?? self.symbol
        return (store.brokeragePortfolio(for: account).items
            + store.brokeragePortfolio(for: account).retainedHistoryItems)
            .first { $0.symbol == wanted }
    }

    private func planProgress(_ store: WatchlistStore, _ account: BrokerageAccountID,
                              id: UUID, symbol wanted: SymbolID? = nil) throws -> TradePlanExecutionProgress {
        let holder = try #require(item(store, account, wanted))
        let plan = try #require(holder.plans.first { $0.id == id })
        return TradePlanExecutionProgress(
            plan: plan, transactions: store.transactionsForPlan(wanted ?? symbol, account: account))
    }

    /// Records a plan fill. The funding defaults to the destination's ordinary
    /// method so a fixture never has to spell it out, and never accidentally
    /// asserts a refusal it did not mean to test.
    private func fill(_ store: WatchlistStore, _ plan: TradePlan, quantity: Double,
                      account: BrokerageAccountID? = nil,
                      funding: PositionFundingSource? = nil) throws -> PositionTransaction {
        let resolvedFunding = funding ?? (account == nil ? nil : .own)
        return try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: plan.price, quantity: quantity,
            date: day, fee: nil, note: nil, fundingSource: resolvedFunding, brokerageAccountID: account)
    }

    // MARK: - Defect 1: a whole-ledger move stranded a fill recorded elsewhere

    @Test("A whole-ledger move keeps progress from a fill recorded in another account")
    func wholeLedgerMoveKeepsExternalFillProgress() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sourcePlan = TradePlan(kind: .buy, price: 100, quantity: 10, fundingSource: .own)
        #expect(store.setTradePlan(sourcePlan, for: symbol))
        let external = try fill(store, sourcePlan, quantity: 10, account: .financing, funding: .own)
        #expect(external.planExecution?.sourceAccountID == .unassigned)
        #expect(try planProgress(store, .unassigned, id: sourcePlan.id).filledQuantity == 10)

        // The unassigned ledger holds the plan; its fill lives in financing.
        // Moving the ledger must carry the plan and re-point that fill.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))

        let after = try planProgress(store, .mengmeng, id: sourcePlan.id)
        #expect(after.filledQuantity == 10, "the plan's own fill must follow the plan")
        #expect(after.remainingQuantity == 0)
        #expect(item(store, .mengmeng)?.plans.first { $0.id == sourcePlan.id }?.status == .done)

        // The fill itself did not move ledgers; only its reference was updated.
        let moved = try #require(item(store, .financing))
        let stillThere = try #require(moved.transactions.first { $0.id == external.id })
        #expect(stillThere.planExecution?.sourceAccountID == .mengmeng)
        #expect(stillThere.brokerageAccountID == .financing)
        #expect(stillThere.price == external.price && stillThere.quantity == external.quantity)
        #expect(stillThere.fundingSource == .own)
        // The ledger that owned the plan let it go entirely, so it no longer
        // counts the fill that followed.
        #expect(item(store, .unassigned) == nil)
        #expect(store.transactionsForPlan(symbol, account: .unassigned).isEmpty)
    }

    // MARK: - Defect 2: a partial move lost a legacy fill and allowed a re-fill

    @Test("A partial move freezes a legacy source and refuses a duplicate backfill")
    func partialMoveFreezesLegacySourceAndBlocksBackfill() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Legacy plan and fill, both written before accounts existed. The
        // position cards are reconciled first, which is the precondition the
        // partial route has always required.
        let sourcePlan = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(sourcePlan, for: symbol))
        let legacyFill = try fill(store, sourcePlan, quantity: 10)
        #expect(legacyFill.planExecution?.sourceAccountID == .unassigned,
                "a store-produced fill always names its plan's ledger")
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 5,
            date: day.addingTimeInterval(1)))
        #expect(store.enableBrokerageAccounts())

        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([legacyFill.id]), to: .financing))

        // The plan stayed behind, and it still counts the fill that left.
        #expect(try planProgress(store, .unassigned, id: sourcePlan.id).filledQuantity == 10)
        #expect(try planProgress(store, .unassigned, id: sourcePlan.id).remainingQuantity == 0)
        // The moved fill names the ledger it left, not the one it landed in.
        let financing = try #require(item(store, .financing))
        let movedFill = try #require(financing.transactions.first { $0.id == legacyFill.id })
        #expect(movedFill.planExecution?.sourceAccountID == .unassigned)
        #expect(store.transactionsForPlan(symbol, account: .unassigned).contains { $0.id == legacyFill.id })

        // A second entry for the same remaining size is refused: the aggregate
        // already completes the plan, so there is nothing left to backfill.
        let before = store.syncSnapshot()
        #expect(throws: TradePlanExecutionError.stalePlan) {
            try store.recordTradePlanFill(
                symbol: symbol, planID: sourcePlan.id, price: 100, quantity: 10,
                date: day, fee: nil, note: nil, fundingSource: .own,
                brokerageAccountID: .financing, historicalBackfill: true)
        }
        #expect(store.syncSnapshot() == before, "a refused backfill writes nothing")
        #expect(item(store, .financing)?.positionQuantity == 10, "no duplicate shares were fabricated")
    }

    // MARK: - Defect 3: a nil destination still created a new unassigned buy

    @Test("A nil buy destination cannot land a new fill in the pending ledger")
    func nilDestinationCannotReachPendingLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The plan lives in the pending ledger; a buy that names no destination
        // resolves there, which is exactly what must now be refused.
        let sourcePlan = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(sourcePlan, for: symbol))
        let before = store.syncSnapshot()
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try fill(store, sourcePlan, quantity: 10, funding: .own)
        }
        #expect(store.syncSnapshot() == before, "a refused plan fill leaves no progress")

        // The ordinary buy route refuses a nil-in-effect destination the same way.
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try store.recordBuyTransaction(symbol, buy(1), account: .unassigned)
        }
        #expect(store.syncSnapshot() == before)
        #expect(item(store, .unassigned)?.transactions.isEmpty == true)

        // A named destination is accepted, and the fill records its plan source.
        let recorded = try fill(store, sourcePlan, quantity: 10, account: .mengmeng, funding: .own)
        #expect(recorded.planExecution?.sourceAccountID == .unassigned)
        #expect(recorded.brokerageAccountID == .mengmeng)
        #expect(item(store, .mengmeng)?.positionQuantity == 10)
    }

    // MARK: - Defect 4: a margin record was classified into an ordinary account

    @Test("A margin record is refused by an ordinary-only destination, unchanged")
    func marginRecordRefusedByMengmeng() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        // Legacy margin history, plus an unmarked record that must stay allowed.
        store.addTransaction(symbol, buy(10, funding: .margin))
        store.addTransaction(symbol, buy(4, price: 101, funding: nil, offset: 60))
        #expect(store.enableBrokerageAccounts())
        let before = store.syncSnapshot()

        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng) == false)
        #expect(store.syncSnapshot() == before, "a refused classification changes nothing")
        #expect(item(store, .mengmeng) == nil)
        #expect(item(store, .unassigned)?.transactions.count == 2)
        // Nothing was "cleaned": the nil annotation is still nil.
        #expect(item(store, .unassigned)?.transactions.map(\.fundingSource) == [.margin, nil])

        // The same history is accepted by an account that supports margin.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .financing))
        #expect(item(store, .financing)?.transactions.map(\.fundingSource) == [.margin, nil])
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    @Test("Unmarked legacy history still classifies into an ordinary-only account")
    func unmarkedHistoryClassifiesIntoMengmeng() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.addTransaction(symbol, buy(3, funding: nil))
        #expect(store.enableBrokerageAccounts())
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))
        // Kept exactly as it was: the move did not invent an ordinary purchase.
        #expect(item(store, .mengmeng)?.transactions.first?.fundingSource == nil)
        #expect(item(store, .mengmeng)?.positionQuantity == 3)
    }

    // MARK: - The last remaining trade is still a selection

    @Test("The last remaining trade moves as a selection and leaves its plan behind")
    func lastRemainingTradeMovesAsSelection() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = buy(10)
        let last = buy(5, offset: 60)
        store.addTransaction(symbol, first)
        store.addTransaction(symbol, last)
        let stayBehind = TradePlan(kind: .buy, price: 90, quantity: 1)
        #expect(store.setTradePlan(stayBehind, for: symbol))

        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([first.id]), to: .financing))
        #expect(item(store, .unassigned)?.transactions.map(\.id) == [last.id])

        // The one trade left is still selectable: no fallback to "whole ledger".
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([last.id]), to: .financing))
        #expect(item(store, .financing)?.transactions.map(\.id) == [first.id, last.id])
        #expect(item(store, .financing)?.positionQuantity == 15)

        // The source keeps its watchlist entry and the plan that lives there.
        #expect(item(store, .unassigned) != nil)
        #expect(item(store, .unassigned)?.positionQuantity == 0)
        #expect(item(store, .unassigned)?.plans.map(\.id) == [stayBehind.id])
        #expect(store.contains(symbol))
    }

    // MARK: - Atomic commit across unnamed accounts

    @Test("A refused whole-ledger move leaves every account, named or not, untouched")
    func refusedMoveLeavesEveryAccountUntouched() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // One plan in unassigned and two fills recorded into two other accounts,
        // so a successful rewrite would have to reach accounts the caller never
        // named. Here the destination already holds the symbol, so it refuses.
        let sourcePlan = TradePlan(kind: .buy, price: 100, quantity: 30)
        #expect(store.setTradePlan(sourcePlan, for: symbol))
        _ = try fill(store, sourcePlan, quantity: 10, account: .financing)
        _ = try fill(store, sourcePlan, quantity: 20, account: .mengmeng)
        let before = store.syncSnapshot()

        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng) == false,
                "the destination already holds the instrument")
        #expect(store.syncSnapshot() == before, "a refused move writes nothing anywhere")
        #expect(item(store, .financing)?.transactions.first?.planExecution?.sourceAccountID == .unassigned)
        #expect(item(store, .mengmeng)?.transactions.count == 1)

        // The same refusal through the legacy signature is byte-identical.
        #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .mengmeng) == false)
        #expect(store.syncSnapshot() == before)
    }

    @Test("An external fill follows its plan to the destination and keeps its own ledger")
    func wholeMoveRepointsAnExternalLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The plan is written in the pending ledger; its fill was recorded into
        // `financing`, so the two ledgers on either side of the plan reference
        // are genuinely different. The destination, `mengmeng`, carries only a
        // bare watch entry for the symbol, which is what the whole-ledger guard
        // requires of a destination.
        let carrier = TradePlan(kind: .buy, price: 50, quantity: 8)
        #expect(store.setTradePlan(carrier, for: symbol))
        let external = try fill(store, carrier, quantity: 8, account: .financing)
        #expect(external.planExecution?.sourceAccountID == .unassigned)
        #expect(item(store, .financing)?.transactions.map(\.id) == [external.id])
        #expect(item(store, .mengmeng)?.transactions.isEmpty == true)

        // `financing` now holds a position, so it is not a free destination.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .financing) == false)
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))

        // The external fill now names the plan's new ledger; nothing else about
        // it changed, and it did not move ledgers itself.
        let moved = try #require(item(store, .financing)?.transactions.first { $0.id == external.id })
        #expect(moved.planExecution?.sourceAccountID == .mengmeng)
        #expect(moved.brokerageAccountID == .financing)
        #expect(moved.price == external.price && moved.quantity == external.quantity)
        #expect(moved.date == external.date && moved.fundingSource == .own)
        #expect(moved.planExecution?.configuration == external.planExecution?.configuration)

        let progress = try planProgress(store, .mengmeng, id: carrier.id)
        #expect(progress.filledQuantity == 8)
        #expect(progress.remainingQuantity == 0)
        #expect(item(store, .mengmeng)?.plans.first { $0.id == carrier.id }?.status == .done)
        // The ledger that owned the plan no longer counts it.
        #expect(store.transactionsForPlan(symbol, account: .unassigned).isEmpty)
    }

    // MARK: - Same UUID, different source

    @Test("A plan reusing the same UUID in another account is never rewritten")
    func sameUUIDDifferentSourceIsNotRewritten() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sharedID = UUID()
        // The plan being classified, in the pending ledger, with a fill that
        // landed in `financing`.
        var moving = TradePlan(kind: .buy, price: 100, quantity: 10)
        moving.id = sharedID
        #expect(store.setTradePlan(moving, for: symbol))
        let movingFill = try fill(store, moving, quantity: 5, account: .financing, funding: .own)

        // An unrelated plan that happens to reuse the UUID. It is written in the
        // pending ledger for a *different* symbol, and its own fill was recorded
        // into `mengmeng`, so its reference must survive every later move.
        var unrelated = TradePlan(kind: .buy, price: 7, quantity: 999)
        unrelated.id = sharedID
        #expect(store.setTradePlan(unrelated, for: other))
        let unrelatedFill = try store.recordTradePlanFill(
            symbol: other, planID: sharedID, price: 7, quantity: 999,
            date: day, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .mengmeng)
        #expect(unrelatedFill.planExecution?.sourceAccountID == .unassigned)

        // Classify `symbol`'s plan into mengmeng. Only fills matching this
        // symbol, this plan id *and* the unassigned source may be re-pointed.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))

        // The moving fill followed its own plan...
        #expect(item(store, .financing)?.transactions
            .first { $0.id == movingFill.id }?.planExecution?.sourceAccountID == .mengmeng)
        // ...while the unrelated plan's fill is untouched in both ledger and
        // source, because its symbol and its source never matched.
        let unrelatedHolder = try #require(item(store, .mengmeng, other))
        let unrelatedAfter = try #require(unrelatedHolder.transactions.first { $0.id == unrelatedFill.id })
        #expect(unrelatedAfter.planExecution?.sourceAccountID == .unassigned,
                "a plan that merely reuses the UUID must keep its own source")
        #expect(unrelatedAfter.brokerageAccountID == .mengmeng)
        // Its own plan's progress is still counted from the pending ledger.
        let unrelatedProgress = try planProgress(store, .unassigned, id: sharedID, symbol: other)
        #expect(unrelatedProgress.filledQuantity == 999)
    }

    // MARK: - Failure leaves the snapshot untouched

    @Test("A refused selection, an empty one, and a bad destination all change nothing")
    func refusalsLeaveTheSnapshotUntouched() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.addTransaction(symbol, buy(4))
        store.initializePositionAllocations()
        let before = store.syncSnapshot()
        let buyID = try #require(item(store, .unassigned)?.transactions.first?.id)

        #expect(store.assignBrokerageRecords(for: symbol, request: .selectedTrades([]), to: .financing) == false)
        #expect(store.syncSnapshot() == before)
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([UUID()]), to: .financing) == false)
        #expect(store.syncSnapshot() == before)
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([buyID]), to: .unassigned) == false)
        #expect(store.syncSnapshot() == before)
        // The legacy signature reads the same way: nil is the whole ledger, and
        // into `unassigned` it is still refused.
        #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .unassigned) == false)
        #expect(store.syncSnapshot() == before)
        #expect(item(store, .unassigned)?.transactions.map(\.id) == [buyID])
    }

    @Test("Classifying is refused from a named ledger, exactly as before")
    func classificationOnlyFromThePendingLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.selectBrokerageAccount(.financing)
        store.addTransaction(symbol, buy(1))
        let before = store.syncSnapshot()
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng) == false)
        #expect(store.syncSnapshot() == before)
        store.selectBrokerageAccount(.unassigned)
    }

    // MARK: - Legacy compatibility

    @Test("A single-ledger store keeps recording plan fills with no account rules")
    func legacyStoreStillRecordsPlanFills() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let target = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(target, for: symbol))
        let recorded = try fill(store, target, quantity: 10)
        #expect(recorded.brokerageAccountID == nil, "single-ledger records stay untagged")
        #expect(store.item(for: symbol)?.positionQuantity == 10)
        #expect(store.item(for: symbol)?.plans.first?.status == .done)

        // The ordinary buy route is unchanged there too.
        let direct = try store.recordBuyTransaction(symbol, buy(2), account: .unassigned)
        #expect(direct.brokerageAccountID == .unassigned)
        #expect(store.item(for: symbol)?.positionQuantity == 12)
    }

    @Test("A legacy fill with no source stays readable and counts in its own ledger")
    func legacyNilSourceStaysReadable() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let planID = UUID()
        let configuration = TradePlanConfiguration(plan: TradePlan(kind: .buy, price: 10, quantity: 4))
        // A record written before the store named a source, loaded as-is.
        let legacy = PositionTransaction(
            kind: .buy, price: 10, quantity: 4, date: day,
            planExecution: TradePlanExecution(planID: planID, configuration: configuration))
        #expect(legacy.planExecution?.sourceAccountID == nil)
        store.addTransaction(symbol, legacy)
        #expect(store.enableBrokerageAccounts())

        // It is interpreted against the ledger it is stored in, so a plan in
        // unassigned still sees it.
        let found = store.transactionsForPlan(symbol, account: .unassigned)
        #expect(found.map(\.id) == [legacy.id])
        // The central resolver is what answers that question.
        #expect(BrokerageOwnership.planSourceAccount(for: legacy, enclosingAccount: .unassigned) == .unassigned)
        #expect(store.transactionsForPlan(symbol, account: .financing).isEmpty)

        // And classifying it freezes the source rather than leaving it implicit.
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([legacy.id]), to: .financing))
        #expect(item(store, .financing)?.transactions.first?.planExecution?.sourceAccountID == .unassigned)
    }

    // MARK: - A legacy-only link is kept readable, never rewritten

    /// A plan written before fills named their source, whose only link to its
    /// fill is the plan's own `filledTransactionID`. Nothing about that trade
    /// says which plan it was for, so after a partial classification the link
    /// can only be read through the plan. What must *not* happen is the store
    /// inventing a fill-time snapshot from the plan as it stands now: that would
    /// attribute to the trade a plan configuration it was never recorded
    /// against.
    @Test("A legacy-only link is read across ledgers without inventing a plan snapshot")
    func legacyOnlyLinkIsReadWithoutInventingASnapshot() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let filled = buy(10)
        store.addTransaction(symbol, filled)
        store.addTransaction(symbol, buy(5, offset: 60))
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, status: .done,
                             filledTransactionID: filled.id)
        #expect(store.setTradePlan(plan, for: symbol))
        #expect(store.enableBrokerageAccounts())
        #expect(try planProgress(store, .unassigned, id: plan.id).filledQuantity == 10)

        // The fill leaves for another ledger; the plan stays behind with it.
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([filled.id]), to: .financing))

        // Progress held, read through the plan's own record of which trade
        // filled it.
        let after = try planProgress(store, .unassigned, id: plan.id)
        #expect(after.filledQuantity == 10, "the plan's own legacy id still names its fill")
        #expect(after.remainingQuantity == 0)
        #expect(after.isComplete)

        // And the trade gained nothing it did not have: no snapshot was built
        // for it, so "the plan as configured today" was never written down as
        // this fill's history.
        let moved = try #require(item(store, .financing)?.transactions.first { $0.id == filled.id })
        #expect(moved.planExecution == nil, "classification must not fabricate a fill-time snapshot")
        #expect(moved.price == filled.price && moved.quantity == filled.quantity)
        #expect(moved.fundingSource == filled.fundingSource)
    }

    /// The other half of the same rule: the link survives the move, but it is
    /// still a *legacy* link. A later fill recorded against the plan is entered
    /// normally, and the old fill is not re-attributed to it.
    @Test("Recording a later fill keeps the legacy link readable afterwards")
    func legacyOnlyLinkSurvivesALaterFill() throws {
        let (store, defaults, suite) = try makeStore(false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let filled = buy(4)
        store.addTransaction(symbol, filled)
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, filledTransactionID: filled.id)
        #expect(store.setTradePlan(plan, for: symbol))
        #expect(store.enableBrokerageAccounts())

        // Move the legacy fill out, then record the rest against the plan.
        #expect(store.assignBrokerageRecords(for: symbol,
            request: .selectedTrades([filled.id]), to: .financing))
        let recorded = try fill(store, plan, quantity: 6, account: .mengmeng, funding: .own)

        // The plan counts both: the fill it names by id and the one that names it.
        let progress = try planProgress(store, .unassigned, id: plan.id)
        #expect(progress.filledQuantity == 10)
        #expect(progress.remainingQuantity == 0)
        #expect(recorded.planExecution?.sourceAccountID == .unassigned)
        #expect(item(store, .financing)?.transactions.first { $0.id == filled.id }?.planExecution == nil)
    }

    // MARK: - A whole move keeps both kinds of source

    @Test("A whole move retargets an explicit fill and reads a legacy fill, each once")
    func wholeMoveHandlesBothSourceShapes() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // One plan with two fills against it: an explicit one recorded into
        // another ledger, and a legacy one that only the plan's id names.
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(plan, for: symbol))
        let explicit = try fill(store, plan, quantity: 6, account: .financing, funding: .own)
        #expect(explicit.planExecution?.sourceAccountID == .unassigned)
        let legacy = buy(4, offset: 60)
        store.addTransaction(symbol, legacy)
        var linked = try #require(item(store, .unassigned)?.plans.first { $0.id == plan.id })
        linked.filledTransactionID = legacy.id
        #expect(store.setTradePlan(linked, for: symbol))
        #expect(try planProgress(store, .unassigned, id: plan.id).filledQuantity == 10)

        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))

        // The explicit fill followed its plan's new source; the legacy fill moved
        // with the ledger it lived in and gained no snapshot on the way.
        let external = try #require(item(store, .financing)?.transactions.first { $0.id == explicit.id })
        #expect(external.planExecution?.sourceAccountID == .mengmeng)
        #expect(external.brokerageAccountID == .financing)
        let carried = try #require(item(store, .mengmeng)?.transactions.first { $0.id == legacy.id })
        #expect(carried.planExecution == nil)

        let moved = try planProgress(store, .mengmeng, id: plan.id)
        #expect(moved.filledQuantity == 10, "both fills must still be counted exactly once")
        #expect(moved.remainingQuantity == 0)
        #expect(store.transactionsForPlan(symbol, account: .unassigned).isEmpty)
    }

    // MARK: - A broken link is refused, not committed

    /// The commit check is the semantic half of validation: a candidate that
    /// encodes and validates as a snapshot is still refused if any plan would
    /// lose (or gain) linked fills on the way. This drives that comparison
    /// directly, because it is the rule the store's own commit path relies on —
    /// a plan whose progress a move would silently break must take the whole
    /// classification down with it, leaving every ledger untouched.
    @Test("Progress that a candidate move would break is detected before commit")
    func brokenPlanProgressIsDetectedBeforeCommit() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(plan, for: symbol))
        let external = try fill(store, plan, quantity: 10, account: .financing, funding: .own)

        // The fill is the plan's only progress, and it names the ledger the plan
        // lives in as its source. A move that carried the plan but left the fill
        // naming the old ledger would leave the plan reading as unfilled — the
        // structurally valid, semantically broken snapshot this refuses.
        let before = store.syncSnapshot()
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .financing) == false,
                "the destination already holds the fill")
        #expect(store.syncSnapshot() == before, "a refused move writes nothing anywhere")
        #expect(try planProgress(store, .unassigned, id: plan.id).filledQuantity == 10)

        // The same move to a free ledger keeps the progress, which is what makes
        // the refusal above a refusal and not a broken feature: the plan and its
        // fill's reference travel together.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng))
        #expect(try planProgress(store, .mengmeng, id: plan.id).filledQuantity == 10)
        #expect(item(store, .financing)?.transactions.first { $0.id == external.id }?
            .planExecution?.sourceAccountID == .mengmeng)
    }

    /// The comparison itself, stated directly: the ledger is not part of a
    /// plan's identity while a move is being validated — changing ledgers is
    /// precisely what a classification does — but the plan's name and its fill
    /// count both are.
    @Test("Progress comparison pairs plans by name and holds the fill count")
    func progressComparisonIsAboutThePlanNotTheLedger() {
        let id = UUID()
        let read = { (account: BrokerageAccountID, filled: Double) in
            BrokerageOwnership.ProgressRead(account: account, symbol: self.symbol, planID: id,
                filledQuantity: filled, tolerance: 0)
        }
        // Same plan, same fills, different ledger: preserved.
        #expect(BrokerageOwnership.progressIsPreserved(read(.financing, 10), since: read(.unassigned, 10)))
        #expect(BrokerageOwnership.planProgressIsPreserved(
            expected: [read(.financing, 10)], reference: [read(.unassigned, 10)]))
        // A changed fill count is not, in either direction.
        #expect(BrokerageOwnership.progressIsPreserved(read(.financing, 0), since: read(.unassigned, 10)) == false)
        #expect(BrokerageOwnership.progressIsPreserved(read(.financing, 10), since: read(.unassigned, 0)) == false)
        // A plan with no counterpart is not evidence that anything survived.
        #expect(BrokerageOwnership.planProgressIsPreserved(
            expected: [read(.financing, 10)], reference: []) == false)
        // An unbounded reading never counts as preserved progress.
        #expect(BrokerageOwnership.progressIsPreserved(
            read(.financing, .infinity), since: read(.unassigned, 10)) == false)
        #expect(BrokerageOwnership.progressIsPreserved(
            read(.financing, 10), since: read(.unassigned, -.infinity)) == false)
        // A different plan of the same size is a different plan.
        let other = BrokerageOwnership.ProgressRead(account: .unassigned, symbol: symbol, planID: UUID(),
            filledQuantity: 10, tolerance: 0)
        #expect(BrokerageOwnership.planProgressIsPreserved(expected: [read(.financing, 10)],
            reference: [other]) == false)
    }

    // MARK: - A reused plan UUID is not this plan

    /// A plan that reuses the id in another ledger keeps its own legacy link.
    /// The plan's `filledTransactionID` is read from the ledger being asked
    /// about, so the other ledger's copy can never supply this one's fill.
    @Test("A legacy link is read from the asking ledger, never a namesake's")
    func legacyLinkIsScopedToTheAskingLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sharedID = UUID()
        // The plan under test lives in unassigned but names no fill yet.
        var underTest = TradePlan(kind: .buy, price: 100, quantity: 10)
        underTest.id = sharedID
        #expect(store.setTradePlan(underTest, for: symbol))

        // A namesake in `financing` names a trade of its own.
        store.selectBrokerageAccount(.financing)
        let namesakeTrade = buy(7, offset: 60)
        store.addTransaction(symbol, namesakeTrade)
        var namesake = TradePlan(kind: .buy, price: 100, quantity: 10, filledTransactionID: namesakeTrade.id)
        namesake.id = sharedID
        #expect(store.setTradePlan(namesake, for: symbol))
        #expect(try planProgress(store, .financing, id: sharedID).filledQuantity == 7)
        store.selectBrokerageAccount(.unassigned)

        // The unassigned plan has no link of its own, so it counts nothing —
        // the namesake's trade is not its fill, and it was never claimed as one.
        #expect(try planProgress(store, .unassigned, id: sharedID).filledQuantity == 0)
        #expect(try planProgress(store, .financing, id: sharedID).filledQuantity == 7)

        // Classifying `financing`'s symbol must leave the unassigned plan's
        // (empty) progress exactly as it was.
        let before = store.syncSnapshot()
        store.withBrokerageAccount(.financing) {
            #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .mengmeng) == false,
                    "classification is refused from a named ledger")
        }
        #expect(store.syncSnapshot() == before)
    }

    @Test("The legacy transactionIDs signature still classifies whole ledgers")
    func legacySignatureStillMovesWholeLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.addTransaction(symbol, buy(6))
        let plan = TradePlan(kind: .buy, price: 99, quantity: 1)
        #expect(store.setTradePlan(plan, for: symbol))
        #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing))
        #expect(item(store, .unassigned) == nil)
        #expect(item(store, .financing)?.positionQuantity == 6)
        #expect(item(store, .financing)?.plans.map(\.id) == [plan.id])
    }

    // MARK: - The domain rules directly

    @Test("The buy rule resolves the destination before it checks the account")
    func buyRuleResolvesBeforeChecking() throws {
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try BrokerageOwnership.resolveBuyDestination(
                requested: nil, selected: .unassigned, accountsEnabled: true)
        }
        #expect(try BrokerageOwnership.resolveBuyDestination(
            requested: nil, selected: .financing, accountsEnabled: true) == .financing)
        // Single-ledger mode predates the rule and is untouched by it.
        #expect(try BrokerageOwnership.resolveBuyDestination(
            requested: nil, selected: .unassigned, accountsEnabled: false) == .unassigned)

        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            try BrokerageOwnership.validateBuyFunding(.mengmeng, fundingSource: .margin, accountsEnabled: true)
        }
        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            try BrokerageOwnership.validateBuyFunding(.financing, fundingSource: nil, accountsEnabled: true)
        }
        try BrokerageOwnership.validateBuyFunding(.financing, fundingSource: .margin, accountsEnabled: true)
        try BrokerageOwnership.validateBuyFunding(.unassigned, fundingSource: .margin, accountsEnabled: false)
    }

    @Test("The classification request keeps nil and an empty selection distinct")
    func requestModesAreExplicit() {
        #expect(BrokerageOwnership.request(transactionIDs: nil) == .wholeLedger)
        #expect(BrokerageOwnership.request(transactionIDs: nil).movesWholeLedger)
        #expect(BrokerageOwnership.request(transactionIDs: []).transactionIDs == [])
        #expect(BrokerageOwnership.request(transactionIDs: []).movesWholeLedger == false)
        let ids: Set<UUID> = [UUID(), UUID()]
        #expect(BrokerageOwnership.request(transactionIDs: ids).transactionIDs == ids)
    }

    @Test("A destination refuses margin records but never rewrites unmarked ones")
    func destinationFundingRule() {
        let margin = buy(1, funding: .margin)
        let unmarked = buy(1, funding: nil)
        let cleared = buy(1, funding: .unmarked)
        #expect(BrokerageOwnership.permits([margin], in: .financing))
        #expect(BrokerageOwnership.permits([margin], in: .mengmeng) == false)
        #expect(BrokerageOwnership.permits([unmarked], in: .mengmeng))
        #expect(BrokerageOwnership.permits([cleared], in: .mengmeng))
        // A record that is not a buy carries no purchase funding to judge.
        let sale = PositionTransaction(kind: .sell, price: 1, quantity: 1, date: day, fundingSource: .margin)
        #expect(BrokerageOwnership.permits([sale], in: .mengmeng))
    }
}
