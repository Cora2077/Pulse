import Foundation
import Testing
@testable import PulseCore

/// Diagnostic evidence of current behavior, not desired regression assertions.
@MainActor @Suite("Ownership audit probes")
struct OwnershipAuditProbes {
    let symbol = SymbolID(market: .us, code: "AUDIT")
    func fixture(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.OwnershipAudit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.add(SymbolInfo(symbol: symbol, name: "虚构归属审计"))
        try body(store)
    }
    func progress(_ store: WatchlistStore, account: BrokerageAccountID, id: UUID) throws -> TradePlanExecutionProgress {
        let item = try #require(store.brokeragePortfolio(for: account).items.first { $0.symbol == symbol })
        let plan = try #require(item.plans.first { $0.id == id })
        return TradePlanExecutionProgress(plan: plan, transactions: store.transactionsForPlan(symbol, account: account))
    }

    @Test func wholeClassificationOrphansExternalFill() throws {
        try fixture { store in
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 7,
                date: Date.now.addingTimeInterval(-86400)))
            store.enableBrokerageAccounts()
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .financing)
            #expect(try progress(store, account: .unassigned, id: plan.id).filledQuantity == 10)
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .mengmeng))
            let after = try progress(store, account: .mengmeng, id: plan.id)
            #expect(after.filledQuantity == 0 && after.remainingQuantity == 10)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.transactions.first?.id == fill.id)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.transactions.first?.planExecution?.sourceAccountID == .unassigned)
            print("AUDIT_PROBE whole-classification: fill survived; plan filledQuantity 10 -> 0")
        }
    }

    @Test func partialClassificationLosesLegacyFillAndAllowsDuplicateBackfill() throws {
        try fixture { store in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: .now, fee: nil, note: nil)
            #expect(fill.planExecution?.sourceAccountID == nil)
            // Keep another trade in the source so this is a genuine UI-reachable partial selection.
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 5,
                date: Date.now.addingTimeInterval(1)))
            store.enableBrokerageAccounts()
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: [fill.id], to: .financing))
            #expect(try progress(store, account: .unassigned, id: plan.id).filledQuantity == 0)
            let duplicate = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: fill.date, fee: nil, note: nil, fundingSource: .own,
                brokerageAccountID: .financing, historicalBackfill: true)
            #expect(duplicate.id != fill.id)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 20)
            print("AUDIT_PROBE partial-classification: original fill no longer linked; duplicate backfill accepted; quantity 10 -> 20")
        }
    }

    @Test func nilBuyDestinationStillCreatesNewUnassignedFill() throws {
        try fixture { store in
            store.enableBrokerageAccounts()
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: .now, fee: nil, note: nil, fundingSource: .own)
            #expect(fill.brokerageAccountID == nil)
            #expect(store.item(for: symbol)?.positionQuantity == 10)
            #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
                try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 1,
                    date: .now, fundingSource: .own), account: .unassigned)
            }
            print("AUDIT_PROBE nil-destination: plan-fill accepted new unassigned buy; direct-buy rejected")
        }
    }

    @Test func classificationAcceptsMarginInOrdinaryOnlyAccount() throws {
        try fixture { store in
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10,
                date: .now, fundingSource: .margin))
            store.enableBrokerageAccounts()
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .mengmeng))
            let target = try #require(store.brokeragePortfolio(for: .mengmeng).items.first)
            #expect(target.transactions.first?.fundingSource == .margin)
            #expect(!BrokerageAccountID.mengmeng.permitsBuy(fundingSource: .margin))
            print("AUDIT_PROBE margin-classification: margin record accepted into ordinary-only mengmeng")
        }
    }

    @Test func tagChangesAttributionWithoutChangingLedger() throws {
        try fixture { store in
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now))
            store.enableBrokerageAccounts()
            store.initializePositionAllocations()
            let allocation = try #require(store.item(for: symbol)?.positionAllocation)
            let portion = try #require(allocation.portions.first)
            _ = try store.setPositionBrokerageAccount(symbol: symbol, portionID: portion.id, accountID: .financing,
                expectedRevision: allocation.revision)
            let source = try #require(store.item(for: symbol))
            #expect(source.positionAccountQuantities(enclosingAccountID: .unassigned) == [.financing: 10])
            #expect(source.positionQuantity == 10)
            #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
            print("AUDIT_PROBE tag-only: financing attribution 10; financing ledger absent; unassigned ledger quantity 10")
        }
    }

    @Test func wholeClassificationCannotConsolidateSameSymbolWithExistingFill() throws {
        try fixture { store in
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now))
            store.enableBrokerageAccounts()
            _ = try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 5,
                date: .now, fundingSource: .own), account: .financing)
            #expect(!store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing))
            #expect(store.item(for: symbol)?.positionQuantity == 10)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 5)
            print("AUDIT_PROBE whole-classification-existing-target: refused; old unassigned ledger remains")
        }
    }
    @Test func lastRemainingTradeCannotFinishClassificationThroughWholeLedgerRoute() throws {
        try fixture { store in
            let first = PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now)
            let last = PositionTransaction(kind: .buy, price: 100, quantity: 5, date: Date.now.addingTimeInterval(1))
            store.addTransaction(symbol, first)
            store.addTransaction(symbol, last)
            store.enableBrokerageAccounts()
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: [first.id], to: .financing))
            // The sheet turns selection of all remaining trades into transactionIDs:nil.
            #expect(!store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing))
            #expect(store.item(for: symbol)?.positionQuantity == 5)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 10)
            print("AUDIT_PROBE final-classification-step: first subset moved; last remaining subset forced to whole-ledger route and refused")
        }
    }

}
