import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Checked trade mutations")
struct TradeMutationTests {
    private let symbol = SymbolID(market: .us, code: "QAMUTATION")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func withStore(accounts: Bool = true,
                           _ body: (WatchlistStore, UserDefaults) throws -> Void) throws {
        let suite = "Pulse.TradeMutationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        store.add(SymbolInfo(symbol: symbol, name: "Fictional mutation fixture", type: .equity))
        if accounts { store.enableBrokerageAccounts() }
        try body(store, defaults)
    }

    private func trade(_ kind: PositionTransaction.Kind = .buy, quantity: Double = 100,
                       price: Double = 110, offset: Double = 0) -> PositionTransaction {
        PositionTransaction(kind: kind, price: price, quantity: quantity,
            date: day.addingTimeInterval(offset), createdAt: day.addingTimeInterval(offset), fundingSource: kind == .buy ? .own : nil)
    }

    private func item(_ store: WatchlistStore, account: BrokerageAccountID = .mengmeng) throws -> WatchItem {
        let portfolio = store.brokeragePortfolio(for: account)
        return try #require((portfolio.items + portfolio.retainedHistoryItems).first { $0.symbol == symbol })
    }

    @Test("A synchronized edit cannot be overwritten or deleted by an older draft")
    func staleAfterSync() throws {
        try withStore { store, defaults in
            let original = try store.recordBuyTransaction(symbol, trade(), account: .mengmeng)
            var remote = store.syncSnapshot()
            let accountIndex = try #require(remote.brokerageAccounts?.firstIndex { $0.accountID == .mengmeng })
            remote.brokerageAccounts?[accountIndex].items[0].transactions[0].price = 120
            #expect(store.applySyncSnapshot(remote))
            let before = store.syncSnapshot()
            let bytes = defaults.data(forKey: "pulse.watchlists.v4")
            var writes = 0
            store.onLocalSyncChange = { _ in writes += 1 }
            var oldDraft = original
            oldDraft.quantity = 90
            #expect(throws: TradeMutationError.staleRecord) {
                try store.updateTransaction(symbol, oldDraft, expected: original, account: .mengmeng)
            }
            #expect(throws: TradeMutationError.staleRecord) {
                try store.deleteTransaction(symbol, id: original.id, expected: original, account: .mengmeng)
            }
            #expect(try item(store).transactions.first?.price == 120)
            #expect(store.syncSnapshot() == before && defaults.data(forKey: "pulse.watchlists.v4") == bytes)
            #expect(writes == 0)
        }
    }

    @Test("Shrinking or deleting a buy cannot leave oversold history", arguments: [BrokerageAccountID.mengmeng, .financing])
    func negativeEditOrDelete(account: BrokerageAccountID) throws {
        try withStore { store, defaults in
            let buy = try store.recordBuyTransaction(symbol, trade(), account: account)
            _ = try store.recordTransaction(symbol, trade(.sell, quantity: 80, offset: 86_400), account: account)
            let before = store.syncSnapshot()
            let bytes = defaults.data(forKey: "pulse.watchlists.v4")
            var writes = 0
            store.onLocalSyncChange = { _ in writes += 1 }
            var smaller = buy
            smaller.quantity = 50
            #expect(throws: TradeMutationError.negativePosition) {
                try store.updateTransaction(symbol, smaller, expected: buy, account: account)
            }
            #expect(throws: TradeMutationError.negativePosition) {
                try store.deleteTransaction(symbol, id: buy.id, expected: buy, account: account)
            }
            #expect(store.syncSnapshot() == before && defaults.data(forKey: "pulse.watchlists.v4") == bytes && writes == 0)
        }
    }

    @Test("Date edits and backdated sells validate intermediate positions, not just final totals")
    func intermediateNegative() throws {
        try withStore { store, _ in
            let buy = try store.recordBuyTransaction(symbol, trade(), account: .mengmeng)
            _ = try store.recordTransaction(symbol, trade(.sell, quantity: 80, offset: 86_400), account: .mengmeng)
            var later = buy
            later.date = day.addingTimeInterval(172_800)
            let before = store.syncSnapshot()
            #expect(throws: TradeMutationError.negativePosition) {
                try store.updateTransaction(symbol, later, expected: buy, account: .mengmeng)
            }
            #expect(throws: TradeMutationError.negativePosition) {
                try store.recordTransaction(symbol, trade(.sell, quantity: 1, offset: -86_400), account: .mengmeng)
            }
            #expect(store.syncSnapshot() == before)
        }
    }

    @Test("Retained edits and deletes preserve removal, cache, selection, and reload")
    func retainedHistoryWrites() throws {
        try withStore { store, defaults in
            let original = try store.recordBuyTransaction(symbol, trade(quantity: 10), account: .mengmeng)
            store.withBrokerageAccount(.mengmeng) { store.remove(symbol) }
            var edited = original
            edited.price = 120
            var writes = 0
            store.onLocalSyncChange = { _ in writes += 1 }
            let saved = try store.updateTransaction(symbol, edited, expected: original, account: .mengmeng)
            #expect(store.activeBrokerageAccountID == .unassigned && writes == 1)
            #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
            #expect(try item(store).lots.first?.price == 120)
            let reloaded = WatchlistStore(defaults: defaults)
            #expect(try item(reloaded).transactions == [saved])
            _ = try store.deleteTransaction(symbol, id: saved.id, expected: saved, account: .mengmeng)
            #expect(writes == 2)
            #expect(try item(store).transactions.isEmpty && item(store).lots.isEmpty)
            #expect(store.brokeragePortfolio(for: .mengmeng).groups.allSatisfy { !$0.symbols.contains(symbol) })
            let emptyReload = WatchlistStore(defaults: defaults)
            #expect(try item(emptyReload).materializedTransactions().isEmpty)
        }
    }

    @Test("A review update, ownership move, and unavailable account all invalidate old requests")
    func metadataAndOwnershipStamps() throws {
        try withStore { store, _ in
            let original = try store.recordBuyTransaction(symbol, trade(), account: .mengmeng)
            #expect(store.withBrokerageAccount(.mengmeng) {
                store.updateTransactionReview(symbol, id: original.id, note: "Synthetic review", review: .init(followedPlan: true))
            })
            #expect(throws: TradeMutationError.staleRecord) {
                try store.updateTransaction(symbol, original, expected: original, account: .mengmeng)
            }
            let live = try #require(item(store).transactions.first)
            try store.assignBrokerageRecordsChecked(for: symbol, request: .wholeLedger, from: .mengmeng, to: .financing)
            let before = store.syncSnapshot()
            #expect(throws: TradeMutationError.itemNotFound) {
                try store.deleteTransaction(symbol, id: live.id, expected: live, account: .mengmeng)
            }
            #expect(store.syncSnapshot() == before)
        }
        try withStore(accounts: false) { store, _ in
            #expect(throws: TradeMutationError.accountUnavailable) {
                try store.updateTransaction(symbol, trade(), expected: trade(), account: .financing)
            }
        }
    }

    @Test("Invalid values and duplicate IDs refuse atomically", arguments: 0..<7)
    func invalidPayload(index: Int) throws {
        try withStore { store, defaults in
            let original = try store.recordBuyTransaction(symbol, trade(), account: .mengmeng)
            var invalid = original
            switch index {
            case 0: invalid.price = .infinity
            case 1: invalid.quantity = .nan
            case 2: invalid.fee = -1
            case 3: invalid.date = Date(timeIntervalSince1970: .infinity)
            case 4: invalid.price = Double.greatestFiniteMagnitude
            case 5: invalid.note = String(repeating: "x", count: 4_001)
            default: invalid.review = .init(nextReviewDate: Date(timeIntervalSince1970: .nan))
            }
            let before = store.syncSnapshot()
            let bytes = defaults.data(forKey: "pulse.watchlists.v4")
            #expect(throws: TradeMutationError.invalidValues) {
                try store.updateTransaction(symbol, invalid, expected: original, account: .mengmeng)
            }
            #expect(throws: TradePlanExecutionError.duplicateTransactionID) {
                try store.recordBuyTransaction(symbol, original, account: .financing)
            }
            #expect(store.syncSnapshot() == before && defaults.data(forKey: "pulse.watchlists.v4") == bytes)
        }
    }

    @Test("Plan-linked edits keep immutable execution metadata and update inactive source progress once")
    func linkedPlanAtomicity() throws {
        try withStore { store, _ in
            let plan = TradePlan(kind: .buy, price: 110, quantity: 100)
            #expect(store.setTradePlan(plan, for: symbol))
            let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 110,
                quantity: 100, date: day, fee: 1, note: "Synthetic", fundingSource: .own, brokerageAccountID: .mengmeng)
            store.withBrokerageAccount(.mengmeng) { store.remove(symbol) }
            store.selectBrokerageAccount(.financing)
            var writes = 0
            store.onLocalSyncChange = { _ in writes += 1 }
            var edited = fill
            edited.quantity = 50
            edited.createdAt = .now
            edited.planExecution = nil
            let saved = try store.updateTransaction(symbol, edited, expected: fill, account: .mengmeng)
            #expect(saved.planExecution == fill.planExecution && saved.createdAt == fill.createdAt)
            #expect(writes == 1 && store.activeBrokerageAccountID == .financing)
            #expect(store.brokeragePortfolio(for: .unassigned).items.first?.plans.first?.status == .active)
            var differentSide = saved
            differentSide.kind = .sell
            #expect(throws: TradeMutationError.immutablePlanContext) {
                try store.updateTransaction(symbol, differentSide, expected: saved, account: .mengmeng)
            }
            _ = try store.deleteTransaction(symbol, id: saved.id, expected: saved, account: .mengmeng)
            #expect(writes == 2 && store.transactionsForPlan(symbol, account: .unassigned, planID: plan.id).isEmpty)
        }
    }

    @Test("Classification shares replay gates and gives specific atomic refusal reasons")
    func classificationRefusals() throws {
        try withStore { store, _ in
            let buy = trade()
            let sell = trade(.sell, quantity: 80, offset: 86_400)
            store.addTransaction(symbol, buy)
            store.addTransaction(symbol, sell)
            let allocation = try #require(store.item(for: symbol)?.positionAllocation)
            let portion = try #require(allocation.portions.first)
            _ = try store.reconcilePositionAllocation(symbol: symbol, quantities: [portion.id: 20],
                reason: "Synthetic remaining shares", expectedRevision: allocation.revision)
            let before = store.syncSnapshot()
            #expect(throws: TradeMutationError.negativePosition) {
                try store.assignBrokerageRecordsChecked(for: symbol, request: .selectedTrades([buy.id]), from: .unassigned, to: .mengmeng)
            }
            #expect(throws: TradeMutationError.invalidSelection) {
                try store.assignBrokerageRecordsChecked(for: symbol, request: .selectedTrades([]), from: .unassigned, to: .mengmeng)
            }
            #expect(store.syncSnapshot() == before)
            try store.assignBrokerageRecordsChecked(for: symbol, request: .selectedTrades([buy.id, sell.id]), from: .unassigned, to: .mengmeng)
            #expect(try item(store).positionQuantity == 20)
            #expect(store.activeBrokerageAccountID == .unassigned)
        }
    }

    @Test("Legacy shorts are readable and repairable but do not license new deficits")
    func legacyShortGrandfathering() throws {
        try withStore { store, _ in
            let short = trade(.sell, quantity: 10)
            store.withBrokerageAccount(.mengmeng) {
                store.add(SymbolInfo(symbol: symbol, name: "Fictional imported short"))
                store.addTransaction(symbol, short)
            }
            var corrected = short
            corrected.price = 120
            _ = try store.updateTransaction(symbol, corrected, expected: short, account: .mengmeng)
            _ = try store.recordBuyTransaction(symbol, trade(quantity: 5, offset: 86_400), account: .mengmeng)
            let before = store.syncSnapshot()
            var larger = corrected
            larger.quantity = 20
            #expect(throws: TradeMutationError.negativePosition) {
                try store.updateTransaction(symbol, larger, expected: corrected, account: .mengmeng)
            }
            #expect(store.syncSnapshot() == before)
        }
    }

    @Test("Tiny quantities cannot bypass the long-only gate; decimal rounding does not fabricate rejection")
    func tinyAndFractionalReplay() throws {
        try withStore { store, _ in
            _ = try store.recordBuyTransaction(symbol, trade(quantity: 1e-18), account: .mengmeng)
            let before = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.allocationNeedsReconciliation) {
                try store.recordTransaction(symbol, trade(.sell, quantity: 2e-18, offset: -86_400), account: .mengmeng)
            }
            #expect(store.syncSnapshot() == before)
            #expect(throws: TradeMutationError.negativePosition) {
                try TradeMutationValidation.validateReplay(previous: [],
                    proposed: [trade(.sell, quantity: 2e-18)], longOnly: true)
            }
        }
        let buy = trade(quantity: 0.3)
        let sale1 = trade(.sell, quantity: 0.1, offset: 86_400)
        let sale2 = trade(.sell, quantity: 0.2, offset: 172_800)
        try TradeMutationValidation.validateReplay(previous: [], proposed: [buy, sale1, sale2], longOnly: true)
    }
}
