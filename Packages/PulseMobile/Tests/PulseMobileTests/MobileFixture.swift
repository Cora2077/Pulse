import Foundation
import PulseCore
import Testing

@testable import PulseMobile

/// Shared fixture helper.
///
/// Every test builds its own store over its own `UserDefaults` suite and
/// deletes the domain afterwards. Nothing here reads `.standard`, so a test run
/// can never see — or damage — a real account's ledger. The symbols are
/// deliberately fictional codes that no provider serves.
@MainActor
enum MobileFixture {
    static func isolatedStore(
        symbolCode: String = "QAMOB1",
        accountsEnabled: Bool = true
    ) throws -> (store: WatchlistStore, defaults: UserDefaults, suite: String, symbol: SymbolID) {
        let suite = "Pulse.Mobile.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults)
        if accountsEnabled {
            #expect(store.enableBrokerageAccounts())
            #expect(store.selectBrokerageAccount(.financing))
        }
        let symbol = SymbolID(market: .us, code: symbolCode)
        store.add(SymbolInfo(symbol: symbol, name: "Fictional mobile fixture"))
        return (store, defaults, suite, symbol)
    }

    static func cleanup(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A buy plan sized to a whole number so fill arithmetic stays exact.
    @discardableResult
    static func seedPlan(
        _ store: WatchlistStore,
        symbol: SymbolID,
        kind: TradePlan.Kind = .buy,
        price: Double = 100,
        quantity: Double = 10
    ) -> TradePlan {
        let plan = TradePlan(kind: kind, price: price, quantity: quantity)
        #expect(store.setTradePlan(plan, for: symbol))
        return plan
    }

    /// Stores a plan verbatim through the store's own peer-snapshot route.
    ///
    /// `setTradePlan` always re-stamps `updatedAt` with `.now` and appends to
    /// `history`, so it cannot produce "the content moved but the clock did
    /// not". A sync merge can — that is the real route by which a peer's
    /// revision arrives — so this uses it rather than reaching into private
    /// state, and returns the plan exactly as the store now holds it.
    @discardableResult
    static func replaceStoredPlan(
        _ plan: TradePlan,
        symbol: SymbolID,
        in store: WatchlistStore,
        account: BrokerageAccountID? = nil
    ) throws -> TradePlan {
        var snapshot = store.syncSnapshot()
        let owner = account ?? store.activeBrokerageAccountID
        // With named ledgers on, the item lives inside its account's portfolio;
        // in single-ledger mode it is the top-level item list.
        if store.brokerageAccountsEnabled,
           let portfolioIndex = snapshot.brokerageAccounts?
            .firstIndex(where: { $0.accountID == owner }) {
            var portfolio = try #require(snapshot.brokerageAccounts?[portfolioIndex])
            try replacing(plan, symbol: symbol, in: &portfolio.items,
                          retained: &portfolio.retainedHistoryItems)
            snapshot.brokerageAccounts?[portfolioIndex] = portfolio
        } else {
            try replacing(plan, symbol: symbol, in: &snapshot.items,
                          retained: &snapshot.retainedHistoryItems)
        }
        #expect(store.applySyncSnapshot(snapshot))
        return try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
    }

    private static func replacing(
        _ plan: TradePlan,
        symbol: SymbolID,
        in items: inout [WatchItem],
        retained: inout [WatchItem]
    ) throws {
        if let index = items.firstIndex(where: { $0.symbol == symbol }),
           let planIndex = items[index].plans.firstIndex(where: { $0.id == plan.id }) {
            items[index].plans[planIndex] = plan
            return
        }
        let retainedIndex = try #require(retained.firstIndex { $0.symbol == symbol })
        let planIndex = try #require(retained[retainedIndex].plans.firstIndex { $0.id == plan.id })
        retained[retainedIndex].plans[planIndex] = plan
    }
}
