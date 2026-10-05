import Foundation
import Testing
@testable import PulseCore

@MainActor @Suite("Brokerage account agent isolation")
struct BrokerageAccountAgentTests {
    @Test func sharedMarketSubscriptionsKeepInactiveHoldingsWithoutBlendingAccounts() throws {
        let suite = "BrokerageQuoteScope.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        let same = SymbolID(market: .sz, code: "000001")
        let other = SymbolID(market: .us, code: "ZZQUOTE")
        for account in [BrokerageAccountID.financing, .mengmeng] {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: same, name: "Fixture"))
                store.addTransaction(same, .init(kind: .buy, price: 10, quantity: 100))
            }
        }
        store.withBrokerageAccount(.mengmeng) {
            store.add(SymbolInfo(symbol: other, name: "Fixture"))
            store.addTransaction(other, .init(kind: .buy, price: 20, quantity: 50))
            store.remove(other)
        }
        let before = store.syncSnapshot()
        #expect(store.symbols.isEmpty)
        #expect(Set(store.quoteSymbols) == [same, other])
        #expect(store.quoteSymbols.count == 2)
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.syncSnapshot() == before)
    }

    @Test func scopedWritesAndReadsRestoreTheUIAccountAndReloadCorrectly() throws {
        let suite = "BrokerageAccountAgentTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        let symbol = SymbolID(market: .sz, code: "000001")
        store.withBrokerageAccount(.financing) {
            store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        }
        store.withBrokerageAccount(.mengmeng) {
            store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        }
        let agent = AgentWatchlistCommands(store: store)
        let financing = agent.scoped(to: .financing)
        let mengmeng = agent.scoped(to: .mengmeng)
        let ref = AgentSymbolRef(market: "sz", code: "000001")
        _ = try financing.recordTrade(.init(symbol: ref, kind: .buy, quantity: 100, price: 10, date: .now)).get()
        _ = try mengmeng.recordTrade(.init(symbol: ref, kind: .buy, quantity: 200, price: 20, date: .now)).get()
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.allItems.isEmpty)
        #expect(financing.listPositions().first?.quantity == 100)
        #expect(mengmeng.listPositions().first?.quantity == 200)
        #expect(financing.listPositions().first?.averageCost == 10)
        #expect(mengmeng.listPositions().first?.averageCost == 20)
        #expect(agent.listBrokerageAccounts().count == 3)
        let restored = WatchlistStore(defaults: defaults)
        #expect(restored.activeBrokerageAccountID == .unassigned)
        #expect(restored.syncSnapshot() == store.syncSnapshot())
    }

    @Test func classifyingIntoThePreviouslySelectedAccountSurvivesScopeRestore() throws {
        let suite = "BrokerageAccountAgentScopeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        let symbol = SymbolID(market: .sz, code: "000001")
        store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        store.addTransaction(symbol, .init(kind: .buy, price: 10, quantity: 100))
        store.enableBrokerageAccounts()
        store.selectBrokerageAccount(.financing)
        let moved = store.withBrokerageAccount(.unassigned) {
            store.assignBrokerageRecords(for: symbol, transactionIDs: nil, to: .financing)
        }
        #expect(moved)
        #expect(store.activeBrokerageAccountID == .financing)
        #expect(store.item(for: symbol)?.positionQuantity == 100)
        #expect(store.brokeragePortfolio(for: .unassigned).items.allSatisfy { !$0.hasPositionHistory })
        #expect(WatchlistStore(defaults: defaults).syncSnapshot() == store.syncSnapshot())
    }
}
