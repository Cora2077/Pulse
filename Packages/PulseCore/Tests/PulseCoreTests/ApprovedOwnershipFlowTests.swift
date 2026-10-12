import Foundation
import Testing
@testable import PulseCore

/// The three approved ownership flows, stated as executable expectations.
///
/// Every fixture here is synthetic: fake symbols, fake prices, fake accounts.
/// No real broker data, credentials or user history is involved, and nothing in
/// this file reaches outside an isolated `UserDefaults` suite.
///
/// The flows are:
///
/// 1. **Correct plan references.** A modern fill (which names its plan) and a
///    legacy fill (which the plan names by id) are two links for the same plan
///    and must both count. A legacy id may never displace an explicit reference
///    belonging to another source. Classification pairs progress per original
///    account + symbol + plan, so two plans reusing one UUID stay separate.
/// 2. **Convergent writes.** The card-label setter no longer writes ownership;
///    a named correction moves real ledgers; a new record names a real account
///    and cannot land in pending history.
/// 3. **Cross-account sales.** One unbound sell plan may reduce positions in two
///    named ledgers, one commit for both, and a card-bound plan may not.
@MainActor @Suite("Approved ownership flows")
struct ApprovedOwnershipFlowTests {
    private let symbol = SymbolID(market: .us, code: "FLOW")
    private let other = SymbolID(market: .us, code: "FLOW2")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Isolated fixtures

    private func makeStore(accounts: Bool = true) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "Pulse.ApprovedOwnershipFlow.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        if accounts {
            store.enableBrokerageAccounts()
            for account in BrokerageAccountID.allCases {
                store.withBrokerageAccount(account) {
                    store.add(SymbolInfo(symbol: symbol, name: "虚构流程标的"))
                    store.add(SymbolInfo(symbol: other, name: "虚构流程标的二"))
                }
            }
            store.selectBrokerageAccount(.unassigned)
        } else {
            store.add(SymbolInfo(symbol: symbol, name: "虚构流程标的"))
        }
        return (store, defaults, suite)
    }

    private func buy(_ quantity: Double, price: Double = 100,
                     funding: PositionFundingSource? = .own,
                     offset: TimeInterval = 0) -> PositionTransaction {
        PositionTransaction(kind: .buy, price: price, quantity: quantity,
                            date: day.addingTimeInterval(offset),
                            createdAt: day.addingTimeInterval(offset),
                            fundingSource: funding)
    }

    /// A store whose pending history was *loaded from stored data*.
    ///
    /// This is the only honest way to build the fixture the repair path exists
    /// for: a record that predates accounts and carries an explicit account while
    /// still sitting in pending history. No public write route can create one —
    /// which is itself the rule under test — so the fixture writes the bytes a
    /// previous build would have written and loads them.
    private func makeLoadedStore(
        records: [PositionTransaction]
    ) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "Pulse.ApprovedOwnershipFlow.loaded.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let item = WatchItem(symbol: symbol, displayName: "虚构历史", transactions: records)
        let snapshot = WatchlistSyncSnapshot(
            items: [item], groups: [WatchlistGroup(name: "Synthetic", symbols: [symbol])],
            retainedHistoryItems: [], brokerageAccounts: [], accountSettings: nil)
        let envelope: [String: Any] = [
            "version": 1,
            "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)),
            "activeAccountID": BrokerageAccountID.unassigned.rawValue,
            "selectedGroupIDs": [String: String](),
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: "pulse.watchlists.v4")
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        return (store, defaults, suite)
    }

    private func item(_ store: WatchlistStore, _ account: BrokerageAccountID,
                      _ wanted: SymbolID? = nil) -> WatchItem? {
        let target = wanted ?? symbol
        return (store.brokeragePortfolio(for: account).items
            + store.brokeragePortfolio(for: account).retainedHistoryItems)
            .first { $0.symbol == target }
    }

    private func plans(_ store: WatchlistStore, _ account: BrokerageAccountID,
                       _ wanted: SymbolID? = nil) -> [TradePlan] {
        item(store, account, wanted)?.plans ?? []
    }

    /// Reads a plan's progress the way the store's own plan rows do: through the
    /// plan-scoped query, which is the one that resolves both kinds of link
    /// without letting a legacy id claim a fill that already names a plan.
    private func progress(_ store: WatchlistStore, _ account: BrokerageAccountID,
                          id: UUID, _ wanted: SymbolID? = nil) throws -> TradePlanExecutionProgress {
        let target = wanted ?? symbol
        let plan = try #require(item(store, account, target)?.plans.first { $0.id == id })
        return TradePlanExecutionProgress(
            plan: plan, transactions: store.transactionsForPlan(target, account: account, planID: id))
    }

    private func fill(_ store: WatchlistStore, _ plan: TradePlan, quantity: Double,
                      account: BrokerageAccountID? = nil,
                      funding: PositionFundingSource? = nil,
                      symbol override: SymbolID? = nil) throws -> PositionTransaction {
        try store.recordTradePlanFill(
            symbol: override ?? symbol, planID: plan.id, price: plan.price, quantity: quantity,
            date: day, fee: nil, note: nil,
            fundingSource: funding ?? (account == nil ? nil : .own),
            brokerageAccountID: account)
    }

    // MARK: - Flow 1: two accounts buy into one plan in batches

    @Test("Two accounts buy the same plan in batches and each fill keeps its own ledger")
    func twoAccountsBuyOnePlanInBatches() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let plan = TradePlan(kind: .buy, price: 100, quantity: 20, fundingSource: .own)
        #expect(store.setTradePlan(plan, for: symbol))

        let first = try fill(store, plan, quantity: 8, account: .financing, funding: .own)
        let second = try fill(store, plan, quantity: 6, account: .mengmeng, funding: .own)
        let third = try fill(store, plan, quantity: 6, account: .financing, funding: .own)

        // The plan lives in pending history and counts every fill, wherever the
        // shares actually are.
        let aggregate = try progress(store, .unassigned, id: plan.id)
        #expect(aggregate.filledQuantity == 20)
        #expect(aggregate.remainingQuantity == 0)
        #expect(plans(store, .unassigned).first { $0.id == plan.id }?.status == .done)

        // Each fill states the account it was executed in, and the plan's own
        // ledger as its source — a cross-account fill still belongs to this plan.
        for (record, account) in [(first, BrokerageAccountID.financing), (second, .mengmeng),
                                  (third, .financing)] {
            #expect(record.brokerageAccountID == account)
            #expect(record.planExecution?.sourceAccountID == .unassigned)
        }
        #expect(item(store, .financing)?.positionQuantity == 14)
        #expect(item(store, .mengmeng)?.positionQuantity == 6)
        // The pending ledger owns the plan but holds none of the shares.
        #expect(item(store, .unassigned)?.positionQuantity == 0)
    }

    // MARK: - Flow 1: legacy and modern links coexist

    @Test("A legacy-only fill and a modern fill are counted together, not instead of each other")
    func legacyOnlyAndModernFillsBothCount() throws {
        let (store, defaults, suite) = try makeStore(accounts: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = buy(10)
        store.addTransaction(symbol, legacy)
        let plan = TradePlan(kind: .buy, price: 100, quantity: 20, filledTransactionID: legacy.id)
        #expect(store.setTradePlan(plan, for: symbol))
        #expect(store.enableBrokerageAccounts())

        // The plan's legacy id names one old trade; a later fill names the plan
        // explicitly. Both are links to the same plan and both count.
        _ = try fill(store, plan, quantity: 5, account: .mengmeng, funding: .own)
        let total = try progress(store, .unassigned, id: plan.id)
        #expect(total.filledQuantity == 15)
        #expect(total.remainingQuantity == 5)
        #expect(store.transactionsForPlan(symbol, account: .unassigned).contains { $0.id == legacy.id })

        // Classify the legacy fill away. The plan stays behind and still counts
        // both: the old trade travels with the plan's id, the modern one names
        // the plan directly.
        #expect(store.assignBrokerageRecords(for: symbol, request: .selectedTrades([legacy.id]),
                                             to: .financing))
        let afterMove = try progress(store, .unassigned, id: plan.id)
        #expect(afterMove.filledQuantity == 15, "a legacy id must not displace the modern fill")
        #expect(afterMove.remainingQuantity == 5)
        #expect(item(store, .financing)?.transactions.first { $0.id == legacy.id }?.planExecution == nil,
                "classification must not invent a fill-time plan snapshot")
    }

    @Test("A legacy id never overrides an explicit reference owned by another source")
    func legacyIDDoesNotOverrideAnExplicitReference() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // An explicit fill recorded into `financing` names the pending ledger as
        // its plan source. A namesake plan in pending history points its legacy
        // id at that very trade — which it has no claim to.
        let planID = UUID()
        let explicitPlan = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(store.setTradePlan(explicitPlan, for: symbol))
        let explicit = try fill(store, explicitPlan, quantity: 10, account: .financing, funding: .own)
        #expect(explicit.planExecution?.sourceAccountID == .unassigned)

        var namesake = TradePlan(kind: .buy, price: 100, quantity: 10, filledTransactionID: explicit.id)
        namesake.id = planID
        #expect(store.setTradePlan(namesake, for: symbol))

        // The explicit fill belongs to `explicitPlan`, not to the namesake, so
        // the namesake counts nothing.
        #expect(try progress(store, .unassigned, id: planID).filledQuantity == 0)
        #expect(try progress(store, .unassigned, id: explicitPlan.id).filledQuantity == 10)
    }

    // MARK: - Flow 1: same UUID, different sources, different progress

    @Test("Same plan UUID in two sources keeps each source's own progress after a move")
    func sameUUIDInTwoSourcesKeepsIndependentProgress() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let sharedID = UUID()
        // The plan under test lives in pending history and its own fill was
        // recorded into `mengmeng`, so a whole move of the pending ledger must
        // carry the plan to a destination free of any of it.
        var pending = TradePlan(kind: .buy, price: 100, quantity: 20)
        pending.id = sharedID
        #expect(store.setTradePlan(pending, for: symbol))
        _ = try fill(store, pending, quantity: 5, account: .mengmeng)

        // A namesake that reuses the same UUID in another ledger, for a
        // *different* symbol, with its own fill in `.financing`. Its progress
        // must survive every later move untouched.
        store.selectBrokerageAccount(.financing)
        var namesake = TradePlan(kind: .buy, price: 7, quantity: 999)
        namesake.id = sharedID
        #expect(store.setTradePlan(namesake, for: other))
        _ = try store.recordTradePlanFill(
            symbol: other, planID: sharedID, price: 7, quantity: 999, date: day,
            fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .financing)
        // Each plan counts its own fill and only its own.
        #expect(try progress(store, .unassigned, id: sharedID).filledQuantity == 5)
        #expect(try progress(store, .financing, id: sharedID, other).filledQuantity == 999)
        store.selectBrokerageAccount(.unassigned)

        // Classify the pending ledger into the free destination. Its plan
        // travels with its own fill; the namesake for the other symbol keeps
        // both its ledger and its progress.
        #expect(store.assignBrokerageRecords(for: symbol, request: .wholeLedger, to: .financing))
        #expect(try progress(store, .financing, id: sharedID).filledQuantity == 5)
        #expect(try progress(store, .financing, id: sharedID, other).filledQuantity == 999,
                "a namesake's progress must not be merged with the moving plan's")
    }

    // MARK: - Flow 2: the card label setter no longer writes ownership

    @Test("The card label setter refuses a real change and is inert when asked for the same value")
    func labelSetterNoLongerWritesOwnership() throws {
        let (store, defaults, suite) = try makeStore(accounts: false)
        defer { defaults.removePersistentDomain(forName: suite) }

        store.addTransaction(symbol, buy(10))
        store.initializePositionAllocations()
        #expect(store.enableBrokerageAccounts())
        let allocation = try #require(item(store, .unassigned)?.positionAllocation)
        let portion = try #require(allocation.portions.first)
        // A card that predates the field inherits its ledger; `nil` is that
        // inherit value and is what a no-op call has to ask for.
        #expect(portion.brokerageAccountID == nil)
        let baseline = store.syncSnapshot()

        // A real change is refused: a label is not a trade.
        #expect(throws: PositionAllocationError.accountOwnershipRequiresClassification) {
            try store.setPositionBrokerageAccount(symbol: symbol, portionID: portion.id,
                                                  accountID: .mengmeng,
                                                  expectedRevision: allocation.revision)
        }
        #expect(store.syncSnapshot() == baseline, "a refused label write changes nothing")

        // Asking for the value the card already carries is the one accepted
        // request. A card that inherits its ledger has no stored label, so the
        // value it reads as is the enclosing ledger's; asking for that is a
        // no-op rather than an error, and it bumps no revision.
        let same = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: portion.id,
            accountID: store.activeBrokerageAccountID,
            expectedRevision: allocation.revision)
        #expect(same.revision == allocation.revision)
        #expect(same.portions.first?.brokerageAccountID == nil,
                "the presented value is the ledger's, and no label was written")
        #expect(store.syncSnapshot() == baseline)
    }

    // MARK: - Flow 2: a named correction updates the fill's real account

    @Test("Correcting a fill's account updates the record and leaves its values intact")
    func namedCorrectionUpdatesTheFillAccount() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Recorded into `financing` by mistake; it really happened in `mengmeng`.
        store.selectBrokerageAccount(.financing)
        let misplaced = buy(4)
        store.addTransaction(symbol, misplaced)
        #expect(item(store, .financing)?.positionQuantity == 4)

        store.selectBrokerageAccount(.mengmeng)
        #expect(store.correctBrokerageOwnership(for: symbol, request: .selectedTrades([misplaced.id]),
                                                from: .financing, to: .mengmeng))

        // The trade is in the corrected ledger, states that account, and kept
        // every value it had.
        let moved = try #require(item(store, .mengmeng)?.transactions.first { $0.id == misplaced.id })
        #expect(moved.brokerageAccountID == .mengmeng)
        #expect(moved.price == misplaced.price && moved.quantity == misplaced.quantity)
        #expect(moved.date == misplaced.date && moved.fundingSource == misplaced.fundingSource)
        #expect(item(store, .mengmeng)?.positionQuantity == 4)
        #expect(item(store, .financing)?.positionQuantity == 0)
        // The user's selection is where they left it.
        #expect(store.activeBrokerageAccountID == .mengmeng)
    }

    @Test("A correction refuses pending history at either end, leaving everything unchanged")
    func correctionRefusesPendingHistory() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.selectBrokerageAccount(.financing)
        let held = buy(3)
        store.addTransaction(symbol, held)
        let baseline = store.syncSnapshot()

        // "Belongs to nobody" is not a fact a record can acquire, and pending
        // history is not a real source to correct out of by this route.
        #expect(store.correctBrokerageOwnership(for: symbol, request: .selectedTrades([held.id]),
                                                from: .financing, to: .unassigned) == false)
        #expect(store.syncSnapshot() == baseline)
        #expect(store.correctBrokerageOwnership(for: symbol, request: .selectedTrades([held.id]),
                                                from: .unassigned, to: .mengmeng) == false)
        #expect(store.syncSnapshot() == baseline)
        // Asking for the ledger it already sits in is not a correction.
        #expect(store.correctBrokerageOwnership(for: symbol, request: .selectedTrades([held.id]),
                                                from: .financing, to: .financing) == false)
        #expect(store.syncSnapshot() == baseline)
    }

    // MARK: - Flow 2: new records must name a real account

    @Test("A new named add is refused in pending history and cannot be written label-only")
    func newNamedRecordCannotLandInPendingHistory() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let draft = buy(5, funding: .own)
        let baseline = store.syncSnapshot()
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try store.addNamedTransaction(symbol, draft, account: .unassigned)
        }
        #expect(store.syncSnapshot() == baseline, "a refused add writes nothing")

        // Naming `mengmeng` while `unassigned` is selected writes to `mengmeng`
        // and stamps the record there — never a label-only write elsewhere.
        let recorded = try store.addNamedTransaction(symbol, draft, account: .mengmeng)
        #expect(recorded.brokerageAccountID == .mengmeng)
        #expect(item(store, .mengmeng)?.transactions.contains { $0.id == recorded.id } == true)
        #expect(item(store, .unassigned)?.transactions.contains { $0.id == recorded.id } != true)
        #expect(store.activeBrokerageAccountID == .unassigned, "the selection is not moved by a write")
    }

    // MARK: - Flow 3: cross-account sales

    @Test("One unbound sell plan reduces two named ledgers and the plan aggregates both")
    func unboundSellSpansTwoNamedLedgers() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        for account in [BrokerageAccountID.financing, .mengmeng] {
            _ = try store.recordBuyTransaction(
                symbol, buy(10, funding: .own), account: account)
        }
        let plan = TradePlan(kind: .sell, price: 110, quantity: 10)
        #expect(store.setTradePlan(plan, for: symbol))

        for account in [BrokerageAccountID.financing, .mengmeng] {
            let sold = try fill(store, plan, quantity: 5, account: account)
            #expect(sold.brokerageAccountID == account)
            // The plan did not move: the fill names the plan's own ledger.
            #expect(sold.planExecution?.sourceAccountID == .unassigned)
            #expect(item(store, account)?.positionQuantity == 5)
        }

        // Both fills belong to the one plan, which aggregates them.
        let aggregate = try progress(store, .unassigned, id: plan.id)
        #expect(aggregate.filledQuantity == 10)
        #expect(aggregate.remainingQuantity == 0)
        #expect(plans(store, .unassigned).first { $0.id == plan.id }?.status == .done)
        // Each execution ledger kept its own plan list untouched.
        #expect(plans(store, .financing).isEmpty)
        #expect(plans(store, .mengmeng).isEmpty)
    }

    @Test("A card-bound sell plan refuses execution in another account")
    func boundSellRefusesAnotherAccount() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        for account in [BrokerageAccountID.financing, .mengmeng] {
            _ = try store.recordBuyTransaction(symbol, buy(10, funding: .own), account: account)
        }
        // The plan is written where its bound card lives, which is the ledger it
        // is allowed to sell from.
        store.selectBrokerageAccount(.financing)
        store.initializePositionAllocations()
        let boundPortion = try #require(item(store, .financing)?.positionAllocation?.portions.first)

        var plan = TradePlan(kind: .sell, price: 110, quantity: 4)
        plan.positionPortionID = boundPortion.id
        plan.positionPool = boundPortion.pool
        #expect(store.setTradePlan(plan, for: symbol))

        let baseline = store.syncSnapshot()
        #expect(throws: TradePlanExecutionError.self) {
            try fill(store, plan, quantity: 4, account: .mengmeng)
        }
        #expect(store.syncSnapshot() == baseline, "a refused bound sale writes nothing anywhere")
        #expect(item(store, .mengmeng)?.positionQuantity == 10)
    }

    @Test("A cross-account sale cannot exceed the executing ledger's real shares")
    func crossAccountSaleCannotOversell() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        _ = try store.recordBuyTransaction(symbol, buy(3, funding: .own), account: .mengmeng)
        let plan = TradePlan(kind: .sell, price: 110, quantity: 10)
        #expect(store.setTradePlan(plan, for: symbol))
        let baseline = store.syncSnapshot()

        // The plan has room, the ledger does not: the real shares are the limit.
        #expect(throws: TradePlanExecutionError.self) {
            try fill(store, plan, quantity: 10, account: .mengmeng)
        }
        #expect(store.syncSnapshot() == baseline, "a refused oversell writes nothing")
        #expect(item(store, .mengmeng)?.positionQuantity == 3)
    }

    @Test("A same-account sale keeps its historical behaviour")
    func sameAccountSaleIsUnchanged() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.selectBrokerageAccount(.financing)
        _ = try store.recordBuyTransaction(symbol, buy(10, funding: .own), account: .financing)
        let plan = TradePlan(kind: .sell, price: 110, quantity: 4)
        #expect(store.setTradePlan(plan, for: symbol))

        let sold = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 110, quantity: 4, date: day,
            fee: nil, note: nil, brokerageAccountID: .financing)
        #expect(sold.brokerageAccountID == .financing)
        #expect(sold.planExecution?.sourceAccountID == .financing)
        #expect(item(store, .financing)?.positionQuantity == 6)
        #expect(try progress(store, .financing, id: plan.id).filledQuantity == 4)
    }

    // MARK: - Safe repair of explicit old ownership

    @Test("An explicit old account is repaired, unsafe records stay, and a repeat is a no-op")
    func repairExplicitOwnershipIsSafeAndIdempotent() throws {
        // Two old records, both sitting in pending history. Only one of them
        // states a real account it can actually belong to.
        let explicit = PositionTransaction(
            kind: .buy, price: 100, quantity: 6, date: day, createdAt: day,
            fundingSource: .own, brokerageAccountID: .financing)
        // And one whose stated account cannot hold it: a margin buy into an
        // ordinary-only destination. It must stay put.
        let unsafe = PositionTransaction(
            kind: .buy, price: 100, quantity: 4, date: day.addingTimeInterval(1),
            createdAt: day.addingTimeInterval(1),
            fundingSource: .margin, brokerageAccountID: .mengmeng)
        let (store, defaults, suite) = try makeLoadedStore(records: [explicit, unsafe])
        defer { defaults.removePersistentDomain(forName: suite) }
        store.selectBrokerageAccount(.unassigned)
        store.initializePositionAllocations()
        // A card label decides nothing: the fixtures' cards carry none.
        let labelled = try #require(item(store, .unassigned)?.positionAllocation?.portions.first)
        #expect(labelled.brokerageAccountID == nil)

        let repaired = store.repairExplicitBrokerageOwnership()
        #expect(repaired == 1, "only the safely explicable record is repaired")
        #expect(item(store, .financing)?.transactions.first { $0.id == explicit.id } != nil)
        let stillPending = try #require(item(store, .unassigned))
        #expect(stillPending.transactions.contains { $0.id == unsafe.id },
                "a record the destination cannot hold is left for a human")
        #expect(item(store, .mengmeng)?.transactions.isEmpty != false)

        // The repaired record kept its own account and values.
        let moved = try #require(item(store, .financing)?.transactions.first { $0.id == explicit.id })
        #expect(moved.brokerageAccountID == .financing)
        #expect(moved.price == explicit.price && moved.quantity == explicit.quantity)

        // Nothing left to do, and the selection was not moved by the scan.
        #expect(store.activeBrokerageAccountID == .unassigned)
        let baseline = store.syncSnapshot()
        #expect(store.repairExplicitBrokerageOwnership() == 0)
        #expect(store.syncSnapshot() == baseline)
    }

    @Test("A repair moves no card label and leaves unlabelled history unlabelled")
    func repairDoesNotMigrateLabels() throws {
        // An old record that names no account at all: there is nothing the store
        // may safely infer, and a card's label is not evidence about a fill.
        let plain = PositionTransaction(kind: .buy, price: 100, quantity: 5, date: day,
                                        createdAt: day, fundingSource: .own)
        let (store, defaults, suite) = try makeLoadedStore(records: [plain])
        defer { defaults.removePersistentDomain(forName: suite) }
        // Stored data carrying a brokerage snapshot already loads in multi-account
        // mode; the fixture is old *history*, not an old single-ledger store.
        store.selectBrokerageAccount(.unassigned)
        store.initializePositionAllocations()
        let portion = try #require(item(store, .unassigned)?.positionAllocation?.portions.first)
        // A card that predates the field inherits its ledger: `nil`, not a guess.
        #expect(portion.brokerageAccountID == nil)

        #expect(store.repairExplicitBrokerageOwnership() == 0)
        #expect(item(store, .unassigned)?.transactions.contains { $0.id == plain.id } == true)
        #expect(item(store, .unassigned)?.positionAllocation?.portions.first?.brokerageAccountID == nil,
                "a repair never writes a label")
    }

    // MARK: - The domain rules directly

    @Test("The sale rule resolves a named execution ledger and refuses pending history")
    func sellDestinationRule() throws {
        // A named execution ledger is honoured: this is what makes a
        // cross-account sale possible.
        #expect(try BrokerageOwnership.resolveSellDestination(
            requested: .mengmeng, planSource: .unassigned, accountsEnabled: true) == .mengmeng)
        #expect(try BrokerageOwnership.resolveSellDestination(
            requested: .financing, planSource: .mengmeng, accountsEnabled: true) == .financing)
        // Omitting the name means the plan's own ledger.
        #expect(try BrokerageOwnership.resolveSellDestination(
            requested: nil, planSource: .financing, accountsEnabled: true) == .financing)
        // Pending history is never where a new sale's shares came from, neither
        // by omission nor by name.
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try BrokerageOwnership.resolveSellDestination(
                requested: nil, planSource: .unassigned, accountsEnabled: true)
        }
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try BrokerageOwnership.resolveSellDestination(
                requested: .unassigned, planSource: .financing, accountsEnabled: true)
        }
        // Single-ledger mode predates the rule.
        #expect(try BrokerageOwnership.resolveSellDestination(
            requested: nil, planSource: .unassigned, accountsEnabled: false) == .unassigned)
    }

    @Test("A correction is only ever between two different named ledgers")
    func correctionRule() {
        #expect(BrokerageOwnership.permitsAccountCorrection(from: .financing, to: .mengmeng))
        #expect(BrokerageOwnership.permitsAccountCorrection(from: .unassigned, to: .mengmeng) == false)
        #expect(BrokerageOwnership.permitsAccountCorrection(from: .financing, to: .unassigned) == false)
        #expect(BrokerageOwnership.permitsAccountCorrection(from: .financing, to: .financing) == false)
    }

    @Test("The legacy id rule declines any fill that already names a plan")
    func legacyIDRuleDeclinesExplicitFills() throws {
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
        let configuration = TradePlanConfiguration(plan: plan)
        var linked = plan
        let bare = buy(1)
        linked.filledTransactionID = bare.id
        #expect(BrokerageOwnership.legacyIDNames(bare, owningPlan: linked))

        var explicit = buy(1)
        explicit.planExecution = TradePlanExecution(planID: plan.id, configuration: configuration)
        #expect(BrokerageOwnership.legacyIDNames(explicit, owningPlan: linked) == false)
    }
}
