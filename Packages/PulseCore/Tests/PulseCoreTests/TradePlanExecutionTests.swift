import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Plan execution workflow")
struct TradePlanExecutionTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private func withStore(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.PlanExecution.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        try body(store)
    }

    private func fill(_ store: WatchlistStore, _ plan: TradePlan, _ quantity: Double,
                      date: Date = .now) throws -> PositionTransaction {
        try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: plan.price,
            quantity: quantity, date: date, fee: 1, note: nil)
    }

    @Test("Partial fills keep original size, consume remaining budget and inherit their pool atomically")
    func partialFills() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 200, positionPool: .tactical)
            #expect(store.setTradePlan(plan, for: symbol))
            var writes = 0
            store.onLocalSyncChange = { _ in writes += 1 }
            let first = try fill(store, plan, 80)
            let partial = try #require(store.tradePlanEntries.first)
            #expect(writes == 1)
            #expect(partial.filledQuantity == 80 && partial.remainingQuantity == 120)
            #expect(partial.plan.quantity == 200 && partial.plan.status == .active)
            #expect(first.planExecution?.configuration.quantity == 200)
            _ = try fill(store, plan, 120)
            let item = try #require(store.item(for: symbol))
            let completed = try #require(store.tradePlanEntries.first)
            #expect(writes == 2)
            #expect(completed.plan.status == .done && completed.remainingQuantity == 0)
            #expect(completed.filledQuantity == 200 && completed.plan.quantity == 200)
            #expect(item.positionQuantity == 200 && !item.positionAllocationNeedsReconciliation)
            #expect(item.positionAllocation?.portions.allSatisfy { $0.pool == .tactical } == true)
        }
    }

    @Test("Assigned sales reject insufficient pool capacity without changing any data")
    func assignedSale() throws {
        try withStore { store in
            let buy = TradePlan(kind: .buy, price: 10, quantity: 200, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            _ = try fill(store, buy, 200)
            var sell = TradePlan(kind: .sell, price: 12, quantity: 100, positionPool: .strategic)
            #expect(store.setTradePlan(sell, for: symbol))
            let before = store.item(for: symbol)
            #expect(throws: TradePlanExecutionError.self) { try fill(store, sell, 80) }
            #expect(store.item(for: symbol) == before)
            sell.positionPool = .tactical
            #expect(store.setTradePlan(sell, for: symbol))
            _ = try fill(store, sell, 80)
            let item = try #require(store.item(for: symbol))
            #expect(item.positionQuantity == 120 && !item.positionAllocationNeedsReconciliation)
            #expect(item.positionAllocation?.portions.reduce(0) { $0 + $1.quantity } == 120)
            #expect(store.tradePlanEntries.first { $0.id == sell.id }?.remainingQuantity == 20)
        }
    }

    @Test("Editing or deleting linked trades recomputes progress and preserves immutable context")
    func editedFills() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 200)
            #expect(store.setTradePlan(plan, for: symbol))
            let first = try fill(store, plan, 80)
            let second = try fill(store, plan, 120)
            store.deleteTransaction(symbol, id: first.id)
            #expect(store.tradePlanEntries.first?.plan.status == .active)
            #expect(store.tradePlanEntries.first?.remainingQuantity == 80)
            let assembled = PositionTransaction(id: second.id, kind: .buy, price: 11,
                quantity: 100, date: second.date, fee: second.fee)
            store.updateTransaction(symbol, assembled)
            let transaction = try #require(store.item(for: symbol)?.transactions.first)
            #expect(transaction.planExecution == second.planExecution)
            var forged = transaction
            forged.planExecution = .init(planID: UUID(), configuration: .init(plan: TradePlan(kind: .sell, price: 999, quantity: 1)))
            store.updateTransaction(symbol, forged)
            #expect(store.item(for: symbol)?.transactions.first?.planExecution == second.planExecution)
            #expect(store.tradePlanEntries.first?.remainingQuantity == 100)
            var manualClose = try #require(store.tradePlanEntries.first?.plan)
            manualClose.status = .done
            #expect(store.setTradePlan(manualClose, for: symbol))
            store.deleteTransaction(symbol, id: second.id)
            #expect(store.tradePlanEntries.first?.plan.status == .done)
        }
    }

    @Test("Legacy and repeated IDs are counted once, including fractional fills")
    func progressDeduplication() {
        var plan = TradePlan(kind: .buy, price: 10, quantity: 200)
        let trade = PositionTransaction(kind: .buy, price: 10, quantity: 80,
            planExecution: TradePlanExecution(planID: plan.id, configuration: TradePlanConfiguration(plan: plan)))
        plan.filledTransactionID = trade.id
        let progress = TradePlanExecutionProgress(plan: plan, transactions: [trade, trade])
        #expect(progress.filledQuantity == 80 && progress.remainingQuantity == 120)
        let fractional = TradePlan(kind: .buy, price: 1, quantity: 0.3)
        let fills = [0.1, 0.2].map {
            PositionTransaction(kind: .buy, price: 1, quantity: $0,
                planExecution: TradePlanExecution(planID: fractional.id,
                    configuration: TradePlanConfiguration(plan: fractional)))
        }
        #expect(TradePlanExecutionProgress(plan: fractional, transactions: fills).isComplete)
        var tiny = TradePlan(kind: .buy, price: 1, quantity: 0.000000001)
        let wrongSide = PositionTransaction(kind: .sell, price: 1, quantity: tiny.quantity)
        tiny.filledTransactionID = wrongSide.id
        #expect(!TradePlanExecutionProgress(plan: tiny, transactions: [wrongSide]).isComplete)
    }

    @Test("User configuration revisions exclude no-op saves and keep metadata from older callers")
    func revisionHistory() throws {
        try withStore { store in
            let condition = TradePlanCondition(title: " Demand ", kind: .logic)
            var plan = TradePlan(kind: .buy, price: 10, quantity: 200, conditions: [condition])
            #expect(store.setTradePlan(plan, for: symbol))
            plan = try #require(store.tradePlanEntries.first?.plan)
            #expect(plan.conditions?.first?.title == "Demand")
            #expect(store.setTradePlan(plan, for: symbol))
            #expect(store.tradePlanEntries.first?.plan.history == nil)
            _ = try fill(store, plan, 80)
            let edit = TradePlan(id: plan.id, kind: plan.kind, price: 11, quantity: 200)
            #expect(store.setTradePlan(edit, for: symbol))
            let changed = try #require(store.tradePlanEntries.first)
            #expect(changed.plan.conditions == plan.conditions)
            #expect(changed.plan.history?.count == 1)
            #expect(changed.plan.history?.first?.configuration.price == 10)
            #expect(changed.filledQuantity == 80)
            #expect(store.item(for: symbol)?.transactions.first?.planExecution?.configuration.price == 10)
        }
    }

    @Test("Invalid, duplicate and stale fills fail before a mutation; an actual overfill keeps the original target")
    func atomicValidation() throws {
        try withStore { store in
            let plan = TradePlan(kind: .buy, price: 10, quantity: 200)
            #expect(store.setTradePlan(plan, for: symbol))
            let before = store.item(for: symbol)
            #expect(throws: TradePlanExecutionError.self) {
                try store.recordTradePlanFill(symbol: symbol, planID: plan.id,
                    price: .greatestFiniteMagnitude, quantity: 200, date: .now, fee: nil, note: nil)
            }
            #expect(throws: TradePlanExecutionError.self) {
                try store.recordTradePlanFill(symbol: symbol, planID: plan.id,
                    price: 10, quantity: 1, date: .now, fee: nil, note: nil,
                    expectedPlanUpdatedAt: .distantPast)
            }
            #expect(store.item(for: symbol) == before)
            _ = try fill(store, plan, 220)
            #expect(store.tradePlanEntries.first?.plan.quantity == 200)
            #expect(store.tradePlanEntries.first?.plan.status == .done)
            #expect(store.tradePlanEntries.first?.filledQuantity == 220)
        }
    }
    @Test("Backdated assigned sales fail atomically with a date-specific recovery path")
    func historicalAssignedSale() throws {
        try withStore { store in
            let buy = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            _ = try fill(store, buy, 100, date: Date(timeIntervalSince1970: 1_700_000_100))
            let sell = TradePlan(kind: .sell, price: 12, quantity: 10, positionPool: .tactical)
            #expect(store.setTradePlan(sell, for: symbol))
            let before = store.item(for: symbol)
            #expect(throws: TradePlanExecutionError.historicalPoolSale) {
                try fill(store, sell, 10, date: Date(timeIntervalSince1970: 1_699_827_200))
            }
            #expect(store.item(for: symbol) == before)
        }
    }

}
