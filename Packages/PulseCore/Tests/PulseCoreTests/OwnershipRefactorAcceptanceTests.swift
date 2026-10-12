import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Ownership refactor independent acceptance")
struct OwnershipRefactorAcceptanceTests {
    let symbol = SymbolID(market: .us, code: "ACCEPT")
    func fixture(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.OwnershipAcceptance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.add(SymbolInfo(symbol: symbol, name: "虚构归属验收"))
        try body(store)
    }
    func entry(_ store: WatchlistStore, account: BrokerageAccountID, id: UUID) throws -> TradePlanEntry {
        let owner = store.brokeragePortfolio(for: account)
        let item = try #require((owner.items + owner.retainedHistoryItems).first { $0.symbol == symbol })
        let plan = try #require(item.plans.first { $0.id == id })
        return TradePlanEntry(symbol: symbol, plan: plan, transactions: store.transactionsForPlan(symbol, account: account, planID: id))
    }

    @Test("Whole classification retargets the moved ledger's own explicit fill")
    func wholeMoveKeepsOwnExplicitFill() throws {
        try fixture { store in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: .now, fee: nil, note: nil)
            #expect(fill.planExecution?.sourceAccountID == .unassigned)
            store.enableBrokerageAccounts()
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing))
            let after = try entry(store, account: .financing, id: plan.id)
            #expect(after.filledQuantity == 10 && after.displayState == .filled)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.transactions.first?.id == fill.id)
        }
    }

    @Test("A filledTransactionID-only legacy link survives partial classification")
    func partialMoveKeepsLegacyIDOnlyLink() throws {
        try fixture { store in
            let buy = PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now)
            store.addTransaction(symbol, buy)
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 5,
                date: Date.now.addingTimeInterval(1)))
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10, status: .done, filledTransactionID: buy.id)
            #expect(store.setTradePlan(plan, for: symbol))
            store.enableBrokerageAccounts()
            #expect(try entry(store, account: .unassigned, id: plan.id).filledQuantity == 10)
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: [buy.id], to: .financing))
            let after = try entry(store, account: .unassigned, id: plan.id)
            #expect(after.filledQuantity == 10 && after.displayState == .filled)
            #expect(!after.canBackfillFill)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.transactions.first?.planExecution == nil,
                    "Classification must not invent a fill-time plan snapshot from the current plan configuration")
        }
    }
    @Test("Single-ledger mode rejects nonexistent named destinations without half-applying")
    func legacyModeRejectsNamedDestination() throws {
        try fixture { store in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            let baseline = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
                try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                    date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .financing)
            }
            #expect(store.syncSnapshot() == baseline)
            #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
                try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100,
                    quantity: 10, date: .now, fundingSource: .own), account: .financing)
            }
            #expect(store.syncSnapshot() == baseline)
        }
    }

    @Test("Legacy-only and modern fills remain counted together after classification")
    func legacyAndModernFillsBothCount() throws {
        try fixture { store in
            let legacy = PositionTransaction(kind: .buy, price: 80, quantity: 10, date: .now)
            store.addTransaction(symbol, legacy)
            let plan = TradePlan(kind: .buy, price: 100, quantity: 20, filledTransactionID: legacy.id)
            #expect(store.setTradePlan(plan, for: symbol))
            store.enableBrokerageAccounts()
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: [legacy.id], to: .financing))
            _ = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 90, quantity: 5,
                date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .mengmeng)
            let result = try entry(store, account: .unassigned, id: plan.id)
            #expect(result.filledQuantity == 15 && result.remainingQuantity == 5)
            #expect(store.transactionsForPlan(symbol, account: .unassigned).contains { $0.id == legacy.id })
        }
    }

    @Test("Namesake plan ids in separate sources retain different progress during a move")
    func namesakePlansKeepIndependentProgress() throws {
        try fixture { store in
            let id = UUID()
            let plan = TradePlan(id: id, kind: .buy, price: 100, quantity: 20)
            #expect(store.setTradePlan(plan, for: symbol))
            _ = try store.recordTradePlanFill(symbol: symbol, planID: id, price: 100, quantity: 5,
                date: .now, fee: nil, note: nil)
            store.enableBrokerageAccounts()
            try store.withBrokerageAccount(.mengmeng) {
                store.add(SymbolInfo(symbol: symbol, name: "同名计划反例"))
                #expect(store.setTradePlan(plan, for: symbol))
                _ = try store.recordTradePlanFill(symbol: symbol, planID: id, price: 100, quantity: 7,
                    date: .now, fee: nil, note: nil, fundingSource: .own, brokerageAccountID: .mengmeng)
            }
            #expect(store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing))
            #expect(try entry(store, account: .financing, id: id).filledQuantity == 5)
            #expect(try entry(store, account: .mengmeng, id: id).filledQuantity == 7)
        }
    }

    @Test("Old card labels cannot manufacture holdings in another account")
    func legacyLabelsDoNotDetermineActualOwner() throws {
        let buy = PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now)
        var item = WatchItem(symbol: symbol, displayName: "旧标签反例", transactions: [buy])
        item.positionAllocation = PositionAllocation(basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [PositionPortion(quantity: 10, origin: .init(kind: .buy, transactionID: buy.id,
                date: buy.date, price: buy.price, quantity: buy.quantity), brokerageAccountID: .mengmeng)])
        #expect(!item.positionAllocationNeedsReconciliation)
        #expect(item.positionAccountQuantities(enclosingAccountID: .financing) == [.financing: 10])
        #expect(item.positionAccountAttribution(enclosingAccountID: .financing)[.mengmeng] == nil)
        #expect(item.positionAllocation?.portions.first?.brokerageAccountID == .mengmeng)
    }

    @Test("Cross-account sales consume only the explicitly chosen ledger")
    func onePlanCanSellAcrossActualAccounts() throws {
        try fixture { store in
            store.enableBrokerageAccounts()
            for account in [BrokerageAccountID.financing, .mengmeng] {
                _ = try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100,
                    quantity: 10, date: .now, fundingSource: .own), account: account)
            }
            let plan = TradePlan(kind: .sell, price: 110, quantity: 10)
            #expect(store.setTradePlan(plan, for: symbol))
            for account in [BrokerageAccountID.financing, .mengmeng] {
                let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 110,
                    quantity: 5, date: .now, fee: nil, note: nil, brokerageAccountID: account)
                #expect(fill.brokerageAccountID == account)
                #expect(fill.planExecution?.sourceAccountID == .unassigned)
                #expect(store.brokeragePortfolio(for: account).items.first { $0.symbol == symbol }?.positionQuantity == 5)
            }
            #expect(try entry(store, account: .unassigned, id: plan.id).displayState == .filled)
            #expect(store.activeBrokerageAccountID == .unassigned)
        }
    }

    @Test("A cross-account sale validates the executing allocation revision and refuses overselling atomically")
    func crossAccountSaleUsesTargetRevisionAndAvailableShares() throws {
        try fixture { store in
            store.enableBrokerageAccounts()
            _ = try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100,
                quantity: 10, date: .now, fundingSource: .own), account: .financing)
            let target = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
            let allocation = try #require(target.positionAllocation)
            let portion = try #require(allocation.portions.first)
            let plan = TradePlan(kind: .sell, price: 110, quantity: 20)
            #expect(store.setTradePlan(plan, for: symbol))
            _ = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 110, quantity: 5,
                date: .now, fee: nil, note: nil, brokerageAccountID: .financing,
                salePortionQuantities: [portion.id: 5], expectedAllocationRevision: allocation.revision)
            #expect(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol }?.positionQuantity == 5)
            let before = store.syncSnapshot()
            #expect(throws: (any Error).self) {
                try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 110, quantity: 6,
                    date: .now, fee: nil, note: nil, brokerageAccountID: .financing)
            }
            #expect(store.syncSnapshot() == before)
        }
    }

    @Test("Backup validation preserves the new execution-account payload contract")
    func backupRejectsInvalidExecutionAccount() throws {
        var plan = TradePlan(kind: .buy, price: 100, quantity: 10, executionAccountID: .unassigned)
        let group = WatchlistGroup(name: "虚构备份", symbols: [symbol])
        var item = WatchItem(symbol: symbol, displayName: "虚构备份", plans: [plan])
        #expect(throws: (any Error).self) {
            try LocalBackupStore.validateSnapshot(WatchlistSyncSnapshot(items: [item], groups: [group]))
        }
        let invalidConfiguration = TradePlanConfiguration(plan: plan)
        plan.executionAccountID = nil
        item.plans = [plan]
        item.transactions = [PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now,
            planExecution: .init(planID: plan.id, configuration: invalidConfiguration))]
        #expect(throws: (any Error).self) {
            try LocalBackupStore.validateSnapshot(WatchlistSyncSnapshot(items: [item], groups: [group]))
        }
        item.transactions = []
        #expect(throws: Never.self) {
            try LocalBackupStore.validateSnapshot(WatchlistSyncSnapshot(items: [item], groups: [group]))
        }
    }

    @Test("An explicit old buy account is not enough to detach the sale that depends on it")
    func reliableRecordRepairCannotLeaveAnUnfundedSale() throws {
        try fixture { store in
            let day = Date(timeIntervalSince1970: 1_700_000_000)
            let buy = PositionTransaction(kind: .buy, price: 100, quantity: 10, date: day,
                fundingSource: .own, brokerageAccountID: .financing)
            let sell = PositionTransaction(kind: .sell, price: 110, quantity: 5,
                date: day.addingTimeInterval(86_400))
            var item = WatchItem(symbol: symbol, displayName: "不可拆分的旧买卖", transactions: [buy, sell])
            item.positionAllocation = PositionAllocation(basisFingerprint: PositionAllocation.basisFingerprint(for: item),
                portions: [PositionPortion(quantity: 5, origin: .init(kind: .buy, transactionID: buy.id,
                    date: buy.date, price: buy.price, quantity: buy.quantity), fundingSource: .own)])
            #expect(!item.positionAllocationNeedsReconciliation)
            store.applySyncSnapshot(WatchlistSyncSnapshot(items: [item],
                groups: [WatchlistGroup(name: "旧数据", symbols: [symbol])], brokerageAccounts: [
                    .init(accountID: .financing, groups: [WatchlistGroup(name: "目标")]),
                    .init(accountID: .mengmeng, groups: [WatchlistGroup(name: "其他")])]))
            let before = store.syncSnapshot()
            #expect(store.repairExplicitBrokerageOwnership() == 0)
            #expect(store.syncSnapshot() == before)
            #expect(store.brokeragePortfolio(for: .unassigned).items.first?.positionQuantity == 5)
        }
    }

    func boundFixture(_ check: (WatchlistStore, PositionTransaction, TradePlan) throws -> Void) throws {
        try fixture { store in
            store.enableBrokerageAccounts()
            let buy = try store.recordBuyTransaction(symbol, PositionTransaction(kind: .buy, price: 100,
                quantity: 10, date: .now, fundingSource: .own), account: .financing)
            try store.withBrokerageAccount(.financing) {
                let allocation = try #require(store.item(for: symbol)?.positionAllocation)
                let card = try #require(allocation.portions.first)
                let moved = try store.transferPositionPortion(symbol: symbol, portionID: card.id, quantity: 10,
                    to: .strategic, reason: "虚构绑定验收", expectedRevision: allocation.revision)
                let plan = TradePlan(kind: .sell, price: 110, quantity: 5, positionPool: .strategic,
                    positionPortionID: try #require(moved.portions.first?.id), executionAccountID: .financing)
                #expect(store.setTradePlan(plan, for: symbol))
                try check(store, buy, plan)
            }
        }
    }

    @Test("Selected classification cannot orphan an active bound sell plan")
    func partialMoveCannotBreakBoundSale() throws {
        try boundFixture { store, buy, _ in
            let before = store.syncSnapshot()
            #expect(!store.correctBrokerageOwnership(for: symbol, request: .selectedTrades([buy.id]),
                from: .financing, to: .mengmeng))
            #expect(store.syncSnapshot() == before)
        }
    }

    @Test("Whole classification keeps the bound card and records its execution-default change")
    func wholeMoveKeepsBoundSaleDefaultConsistent() throws {
        try boundFixture { store, _, plan in
            #expect(store.correctBrokerageOwnership(for: symbol, request: .wholeLedger,
                from: .financing, to: .mengmeng))
            let target = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
            let changed = try #require(target.plans.first { $0.id == plan.id })
            #expect(target.salePlanSource(for: changed) != nil)
            #expect(changed.executionAccountID == .mengmeng)
            #expect(changed.history?.last?.configuration.executionAccountID == .financing)
            #expect(changed.quantity == plan.quantity && changed.status == plan.status)
        }
    }

    @Test("Importing an unscoped legacy plan into a named ledger preserves its filled progress")
    func legacyImportRebasesItsPlanNamespace() throws {
        try fixture { source in
            let plan = TradePlan(kind: .buy, price: 100, quantity: 10)
            #expect(source.setTradePlan(plan, for: symbol))
            _ = try source.recordTradePlanFill(symbol: symbol, planID: plan.id, price: 100, quantity: 10,
                date: .now, fee: nil, note: nil)
            let archive = source.archive()
            #expect(archive.brokerageAccountID == nil)
            try fixture { target in
                target.enableBrokerageAccounts()
                target.selectBrokerageAccount(.financing)
                #expect(target.merge(archive).rejectionReason == nil)
                let imported = try entry(target, account: .financing, id: plan.id)
                #expect(imported.filledQuantity == 10)
                #expect(target.transactionsForPlan(symbol, account: .unassigned, planID: plan.id).isEmpty)
                #expect(throws: Never.self) {
                    try WatchlistSyncWireCodec.encode(deviceID: "虚构导入", snapshot: target.syncSnapshot())
                }
            }
        }
    }

    @Test("An old archive cannot duplicate a trade into another account or import unsupported margin")
    func archiveOwnershipConflictsRefuseAtomically() throws {
        try fixture { store in
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10, date: .now))
            let archive = store.archive()
            store.enableBrokerageAccounts()
            store.selectBrokerageAccount(.financing)
            let before = store.syncSnapshot()
            #expect(store.merge(archive).rejectionReason != nil)
            #expect(store.syncSnapshot() == before)
        }
        try fixture { source in
            source.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10,
                date: .now, fundingSource: .margin))
            let archive = source.archive()
            try fixture { target in
                target.enableBrokerageAccounts()
                target.selectBrokerageAccount(.mengmeng)
                let before = target.syncSnapshot()
                #expect(target.merge(archive).rejectionReason == .incompatibleAccountFunding(accountID: .mengmeng))
                #expect(target.syncSnapshot() == before)
            }
        }
    }

}
