import Foundation
import Testing
@testable import PulseCore

@Suite("Scoped account synchronization")
struct ScopedAccountSyncMergeTests {
    let a = SymbolID(market: .us, code: "QASYNC")
    let other = SymbolID(market: .us, code: "QAOTHER")
    let day = Date(timeIntervalSince1970: 1_700_000_000)

    func trade(price: Double = 100, quantity: Double = 100, kind: PositionTransaction.Kind = .buy, offset: Double = 0) -> PositionTransaction {
        .init(kind: kind, price: price, quantity: quantity, date: day.addingTimeInterval(offset), createdAt: day.addingTimeInterval(offset))
    }
    func base() -> WatchlistSyncSnapshot {
        .init(items: [], groups: [.init(name: "Synthetic")], brokerageAccounts: [.init(accountID: .financing, groups: [.init(name: "Synthetic")]),
            .init(accountID: .mengmeng, groups: [.init(name: "Synthetic")])])
    }
    func put(_ trades: [PositionTransaction], symbol: SymbolID? = nil, account: BrokerageAccountID, into snapshot: inout WatchlistSyncSnapshot, plans: [TradePlan] = []) {
        let symbol = symbol ?? a
        let item = WatchItem(symbol: symbol, displayName: "Fictional sync fixture", addedAt: day, transactions: trades, plans: plans)
        if account == .unassigned {
            snapshot.items.removeAll { $0.symbol == symbol }; snapshot.items.append(item)
            if !snapshot.groups[0].symbols.contains(symbol) { snapshot.groups[0].symbols.append(symbol) }
        } else {
            let i = snapshot.brokerageAccounts!.firstIndex { $0.accountID == account }!
            snapshot.brokerageAccounts![i].items.removeAll { $0.symbol == symbol }; snapshot.brokerageAccounts![i].items.append(item)
            if !snapshot.brokerageAccounts![i].groups[0].symbols.contains(symbol) { snapshot.brokerageAccounts![i].groups[0].symbols.append(symbol) }
        }
    }
    func item(_ snapshot: WatchlistSyncSnapshot, account: BrokerageAccountID, symbol: SymbolID? = nil) -> WatchItem? {
        let items = account == .unassigned ? snapshot.items + snapshot.retainedHistoryItems
            : snapshot.brokerageAccounts?.first { $0.accountID == account }.map { $0.items + $0.retainedHistoryItems } ?? []
        return items.first { $0.symbol == (symbol ?? a) }
    }

    @Test("Trade choices preserve independent changes in both the same and another account", arguments: [WatchlistSyncMerge.ConflictResolution.local, .remote])
    func recordConflictPreservesUnrelated(choice: WatchlistSyncMerge.ConflictResolution) throws {
        let original = trade()
        var base = base(); put([original], account: .financing, into: &base)
        var local = base, remote = base
        local.brokerageAccounts![0].items[0].transactions[0].price = 110
        remote.brokerageAccounts![0].items[0].transactions[0].price = 120
        let sameAccount = trade(quantity: 5, offset: 86_400)
        remote.brokerageAccounts![0].items[0].transactions.append(sameAccount)
        let independent = trade(price: 200, quantity: 30)
        put([independent], account: .mengmeng, into: &remote)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(result.brokerageConflict == nil && result.conflicts.count == 1)
        #expect(result.conflicts.first?.accountID == .financing)
        let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: choice)
        #expect(item(resolved, account: .financing)?.transactions.first?.price == (choice == .local ? 110 : 120))
        #expect(item(resolved, account: .financing)?.transactions.contains { $0.id == sameAccount.id } == true)
        #expect(item(resolved, account: .mengmeng)?.transactions == [independent])
    }

    @Test("Cash conflict selection does not discard sector limits, other cash, or trades")
    func settingsAreFieldScoped() throws {
        var base = base()
        base.brokerageAccounts![0].settings = .init(cashBalances: ["USD": .init(amount: 10, updatedAt: day)])
        var local = base, remote = base
        local.brokerageAccounts![0].settings!.cashBalances["USD"] = .init(amount: 100, updatedAt: day)
        remote.brokerageAccounts![0].settings!.cashBalances["USD"] = .init(amount: 200, updatedAt: day)
        remote.brokerageAccounts![0].settings!.cashBalances["HKD"] = .init(amount: 300, updatedAt: day)
        remote.brokerageAccounts![0].settings!.sectorLimits["USD:Tech"] = 35
        let newTrade = trade()
        put([newTrade], account: .mengmeng, into: &remote)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(result.brokerageConflict?.settingKeys.count == 1)
        let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: .local)
        let settings = resolved.brokerageAccounts![0].settings
        #expect(settings?.cashBalances["USD"]?.amount == 100)
        #expect(settings?.cashBalances["HKD"]?.amount == 300)
        #expect(settings?.sectorLimits["USD:Tech"] == 35)
        #expect(item(resolved, account: .mengmeng)?.transactions == [newTrade])
    }

    @Test("Conflicting ownership selects connected ledgers, not whole accounts", arguments: [WatchlistSyncMerge.ConflictResolution.local, .remote])
    func ownershipIsGrouped(choice: WatchlistSyncMerge.ConflictResolution) throws {
        let original = trade()
        var base = base(); put([original], account: .unassigned, into: &base)
        var local = base, remote = base
        local.items[0].transactions = []; remote.items[0].transactions = []
        put([original], account: .financing, into: &local)
        put([original], account: .mengmeng, into: &remote)
        let independent = trade(price: 90, quantity: 5)
        put([independent], symbol: other, account: .financing, into: &remote)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(result.brokerageConflict?.dependencyGroups.first?.count == 3)
        let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: choice)
        #expect(resolved.allAccountItems.flatMap(\.transactions).filter { $0.id == original.id }.count == 1)
        #expect(item(resolved, account: choice == .local ? .financing : .mengmeng)?.transactions == [original])
        #expect(item(resolved, account: .financing, symbol: other)?.transactions == [independent])
    }

    @Test("Independent edits that combine into overselling require a replay dependency choice")
    func combinedReplayIsValidated() throws {
        let buy = trade(), sale = trade(quantity: 40, kind: .sell, offset: 86_400)
        var base = base(); put([buy, sale], account: .financing, into: &base)
        var local = base, remote = base
        local.brokerageAccounts![0].items[0].transactions[0].quantity = 60
        remote.brokerageAccounts![0].items[0].transactions[1].quantity = 80
        let independent = trade(quantity: 5)
        put([independent], account: .mengmeng, into: &remote)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(!result.isConflictFree && result.brokerageConflict?.dependencyGroups.count == 1)
        for choice in [WatchlistSyncMerge.ConflictResolution.local, .remote] {
            let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: choice)
            #expect(item(resolved, account: .financing)?.positionQuantity == 20)
            #expect(item(resolved, account: .mengmeng)?.transactions == [independent])
        }
    }

    @Test("Relocating a plan against a remote edit keeps third-account fills in the dependency group")
    func planReferencesAreClosed() throws {
        let plan = TradePlan(kind: .buy, price: 100, quantity: 100, updatedAt: day)
        var fill = trade()
        fill.planExecution = .init(planID: plan.id, configuration: .init(plan: plan), sourceAccountID: .unassigned)
        var base = base()
        put([], account: .unassigned, into: &base, plans: [plan])
        put([fill], account: .mengmeng, into: &base)
        var local = base, remote = base
        local.items[0].plans = []
        put([], account: .financing, into: &local, plans: [plan])
        local.brokerageAccounts![1].items[0].transactions[0].planExecution?.sourceAccountID = .financing
        remote.items[0].plans[0].price = 120
        remote.items[0].plans[0].updatedAt = day.addingTimeInterval(1)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(Set(result.brokerageConflict?.dependencyGroups.first?.map(\.accountID) ?? []) == Set(BrokerageAccountID.allCases))
        let resolved = try WatchlistSyncMerge.resolveValidated(result, choosing: .local)
        #expect(item(resolved, account: .financing)?.plans.first?.id == plan.id)
        #expect(item(resolved, account: .unassigned)?.plans.isEmpty == true)
        #expect(item(resolved, account: .mengmeng)?.transactions.first?.planExecution?.sourceAccountID == .financing)
    }
}
