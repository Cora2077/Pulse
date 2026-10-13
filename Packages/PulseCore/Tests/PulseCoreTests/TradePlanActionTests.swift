import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Plan actions and source accounts")
struct TradePlanActionTests {
    private let symbol = SymbolID(market: .us, code: "QAACTION")

    @Test("Derived state determines actions independently of storage account", arguments: BrokerageAccountID.allCases)
    func actionAvailability(account: BrokerageAccountID) {
        var plan = TradePlan(kind: .buy, price: 100, quantity: 100)
        func actions(_ fills: [PositionTransaction] = []) -> [TradePlanAction] {
            TradePlanAction.available(for: .init(symbol: symbol, plan: plan, transactions: fills, accountID: account))
        }
        #expect(actions() == [.recordFill, .edit, .history, .snooze, .abandon, .delete])
        let fill = PositionTransaction(kind: .buy, price: 100, quantity: 100,
            planExecution: .init(planID: plan.id, configuration: .init(plan: plan)))
        #expect(actions([fill]) == [.edit, .history, .delete])
        plan.status = .done
        #expect(actions() == [.backfill, .edit, .history, .revive, .delete])
        plan.status = .cancelled
        #expect(actions() == [.edit, .history, .revive, .delete])
    }

    @Test("Completed stale-active plans refuse another fill using the same progress as menus and alerts")
    func rawActiveFillGuard() throws {
        let suite = "Pulse.PlanActions.Progress.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        store.selectBrokerageAccount(.financing)
        store.add(SymbolInfo(symbol: symbol, name: "Fictional progress"))
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
        store.setTradePlan(plan, for: symbol)
        _ = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
            date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .mengmeng)
        var peer = store.syncSnapshot()
        peer.brokerageAccounts![0].items[0].plans[0].status = .active
        #expect(store.applySyncSnapshot(peer))
        let before = store.syncSnapshot()
        var writes = 0
        store.onLocalSyncChange = { _ in writes += 1 }
        #expect(throws: TradePlanExecutionError.stalePlan) {
            try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 1,
                date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .mengmeng)
        }
        #expect(store.syncSnapshot() == before && writes == 0)
    }

    @Test("Status writes address the named source, preserve selection and refuse stale plans")
    func explicitStatusWrite() throws {
        let suite = "Pulse.PlanActions.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        let plan = TradePlan(kind: .buy, price: 100, quantity: 100)
        for account in [BrokerageAccountID.financing, .mengmeng] {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: symbol, name: "Fictional action fixture"))
                store.setTradePlan(plan, for: symbol)
            }
        }
        let stored = try #require(store.brokeragePortfolio(for: .financing).items.first?.plans.first)
        let entry = TradePlanEntry(symbol: symbol, plan: stored, accountID: .financing)
        var writes = 0
        store.onLocalSyncChange = { _ in writes += 1 }
        let changed = try store.changeTradePlanStatus(entry, to: .cancelled)
        #expect(changed.status == .cancelled && changed.history?.last?.configuration.status == .active)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.first?.plans.first?.status == .active)
        #expect(store.activeBrokerageAccountID == .unassigned && writes == 1)
        let before = store.syncSnapshot()
        #expect(throws: TradePlanExecutionError.stalePlan) { try store.changeTradePlanStatus(entry, to: .cancelled) }
        #expect(store.syncSnapshot() == before && writes == 1)
        store.withBrokerageAccount(.financing) { store.remove(symbol) }
        let revived = try store.changeTradePlanStatus(.init(symbol: symbol, plan: changed, accountID: .financing), to: .active)
        #expect(revived.status == .active)
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
        #expect(store.brokeragePortfolio(for: .financing).retainedHistoryItems.first?.plans.first?.status == .active)
        #expect(throws: TradePlanExecutionError.stalePlan) {
            try store.deleteTradePlan(changed, for: symbol, account: .financing)
        }
        try store.deleteTradePlan(revived, for: symbol, account: .financing)
        #expect(store.brokeragePortfolio(for: .financing).retainedHistoryItems.first?.plans.isEmpty == true)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.first?.plans.first?.id == plan.id)
        #expect(store.activeBrokerageAccountID == .unassigned)
    }
}
