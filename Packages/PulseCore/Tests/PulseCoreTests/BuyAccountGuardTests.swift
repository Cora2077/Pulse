import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Buy account guards")
struct BuyAccountGuardTests {
    private let symbol = SymbolID(market: .us, code: "SYNTH")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func withStore(accounts: Bool = true, _ body: (WatchlistStore) throws -> Void) throws {
        let suite = "BuyAccountGuards.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        if accounts { store.enableBrokerageAccounts() }
        for account in accounts ? BrokerageAccountID.allCases : [.unassigned] {
            store.withBrokerageAccount(account) { store.add(SymbolInfo(symbol: symbol, name: "Synthetic")) }
        }
        try body(store)
    }

    private func buy(_ funding: PositionFundingSource) -> PositionTransaction {
        PositionTransaction(kind: .buy, price: 100, quantity: 5, date: day, fundingSource: funding)
    }

    @Test("Mengmeng edits refuse new margin atomically; financing permits it")
    func editFundingGuard() throws {
        try withStore { store in
            let ordinary = try store.recordBuyTransaction(symbol, buy(.own), account: .mengmeng)
            var edited = ordinary
            edited.price = 999
            edited.fundingSource = .margin
            let before = store.syncSnapshot()
            store.withBrokerageAccount(.mengmeng) { store.updateTransaction(symbol, edited) }
            #expect(store.syncSnapshot() == before)

            let financing = try store.recordBuyTransaction(symbol, buy(.own), account: .financing)
            edited = financing
            edited.fundingSource = .margin
            store.withBrokerageAccount(.financing) { store.updateTransaction(symbol, edited) }
            let item = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
            #expect(item.transactions.first?.fundingSource == .margin)
            // Portions may have been split or relabelled independently, so an
            // edited trade requires review instead of overwriting their history.
            #expect(item.positionAllocationNeedsReconciliation)
            #expect(item.positionAllocation?.portions.first?.fundingSource == .own)
        }
    }

    @Test("An existing legacy margin record stays editable and correctable after accounts are enabled")
    func legacyMarginRemainsEditable() throws {
        try withStore(accounts: false) { store in
            let legacy = buy(.margin)
            store.addTransaction(symbol, legacy)
            #expect(store.enableBrokerageAccounts())
            var edited = legacy
            edited.price = 101
            store.updateTransaction(symbol, edited)
            #expect(store.item(for: symbol)?.transactions.first?.price == 101)
            #expect(store.item(for: symbol)?.transactions.first?.fundingSource == .margin)
            edited.fundingSource = .own
            store.updateTransaction(symbol, edited)
            #expect(store.item(for: symbol)?.transactions.first?.fundingSource == .own)
        }
    }

    @Test("Mengmeng portion funding rejects both whole and partial margin annotations")
    func portionFundingGuard() throws {
        try withStore { store in
            _ = try store.recordBuyTransaction(symbol, buy(.own), account: .mengmeng)
            let item = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
            let allocation = try #require(item.positionAllocation)
            let portion = try #require(allocation.portions.first)
            let before = store.syncSnapshot()
            for quantity in [portion.quantity, 1] {
                #expect(throws: PositionAllocationError.incompatibleAccountFunding) {
                    try store.withBrokerageAccount(.mengmeng) {
                        _ = try store.markPositionFundingSource(symbol: symbol, portionID: portion.id,
                            quantity: quantity, source: .margin, reason: "Synthetic",
                            expectedRevision: allocation.revision)
                    }
                }
                #expect(store.syncSnapshot() == before)
            }
        }
    }

    @Test("A financing portion permits margin but cannot be reassigned to Mengmeng")
    func portionAccountGuard() throws {
        try withStore { store in
            _ = try store.recordBuyTransaction(symbol, buy(.own), account: .financing)
            let item = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
            let allocation = try #require(item.positionAllocation)
            let portion = try #require(allocation.portions.first)
            let marked = try store.withBrokerageAccount(.financing) {
                try store.markPositionFundingSource(symbol: symbol, portionID: portion.id,
                    quantity: portion.quantity, source: .margin, reason: "Synthetic",
                    expectedRevision: allocation.revision)
            }
            #expect(marked.portions.first?.fundingSource == .margin)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.positionAllocation == marked)
            let before = store.syncSnapshot()
            #expect(throws: PositionAllocationError.incompatibleAccountFunding) {
                try store.withBrokerageAccount(.financing) {
                    _ = try store.setPositionBrokerageAccount(symbol: symbol, portionID: marked.portions[0].id,
                        accountID: .mengmeng, expectedRevision: marked.revision)
                }
            }
            #expect(store.syncSnapshot() == before)
        }
    }

    @Test("Agent buys enforce named accounts and account-specific funding, with accurate readback")
    func agentBuyGuardAndReadback() throws {
        try withStore { store in
            let commands = AgentWatchlistCommands(store: store)
            let ref = AgentSymbolRef(market: "us", code: symbol.code)
            func draft(_ funding: PositionFundingSource? = nil) -> AgentTradeDraft {
                AgentTradeDraft(symbol: ref, kind: .buy, quantity: 2, price: 20, date: day, fundingSource: funding)
            }
            let before = store.syncSnapshot()
            #expect(throws: AgentWatchlistError.invalidBuyAccount) { try commands.recordTrade(draft()).get() }
            #expect(throws: AgentWatchlistError.invalidBuyMethod) {
                try commands.scoped(to: .mengmeng).recordTrade(draft(.margin)).get()
            }
            #expect(store.syncSnapshot() == before)

            let ordinary = try commands.scoped(to: .mengmeng).recordTrade(draft()).get()
            let own = try #require(ordinary.value.transactions.first)
            #expect(own.brokerageAccountID == .mengmeng && own.fundingSource == .own)
            let margin = try commands.scoped(to: .financing).recordTrade(draft(.margin)).get()
            let borrowed = try #require(margin.value.transactions.first)
            #expect(borrowed.brokerageAccountID == .financing && borrowed.fundingSource == .margin)
            #expect(store.brokeragePortfolio(for: .mengmeng).items.first?.positionQuantity == 2)
            #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 2)
            #expect(store.item(for: symbol)?.transactions.isEmpty == true)
            #expect(store.activeBrokerageAccountID == .unassigned)
        }
    }

    @Test("No-account data keeps its historical funding behavior")
    func legacyAgentBuy() throws {
        try withStore(accounts: false) { store in
            let command = AgentWatchlistCommands(store: store)
            let ref = AgentSymbolRef(market: "us", code: symbol.code)
            let result = try command.recordTrade(AgentTradeDraft(symbol: ref, kind: .buy,
                quantity: 1, price: 20, date: day, fundingSource: .margin)).get()
            #expect(result.value.transactions.first?.fundingSource == .margin)
            #expect(result.value.transactions.first?.brokerageAccountID == nil)
            #expect(store.item(for: symbol)?.positionQuantity == 1)
        }
    }
}
