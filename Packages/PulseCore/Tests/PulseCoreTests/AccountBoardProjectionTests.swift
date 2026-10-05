import Foundation
import Testing
@testable import PulseCore

@Suite("Account board projection")
struct AccountBoardProjectionTests {
    let symbol = SymbolID(market: .us, code: "AAPL")

    @Test func independentCashGapsAndSellLimits() throws {
        let plan = TradePlan(kind: .buy, price: 10, quantity: 50)
        let finance = TradePlanEntry(symbol: symbol, plan: plan, accountID: .financing)
        let mengmeng = TradePlanEntry(symbol: symbol, plan: plan, accountID: .mengmeng)
        #expect(finance.id != mengmeng.id)
        #expect(finance.plan.id == plan.id && mengmeng.plan.id == plan.id)
        let first = PoolBudgetProjection.calculate(positions: [], entries: [finance], cash: ["USD": 100])
        let second = PoolBudgetProjection.calculate(positions: [], entries: [mengmeng], cash: ["USD": 1000])
        let combined = PoolBudgetProjection.Result.combiningAccounts([first, second])
        let currency = try #require(combined.currency("USD"))
        #expect(currency.cashBalance == 1100)
        #expect(currency.plannedBuyAmount == 1000)
        #expect(currency.cashShortfall == 400)
        #expect(currency.purchaseBudgetGap == 400)
        // Another account's surplus does not make the financing plan executable.
        #expect(currency.availableCash == 100)
        let sell = TradePlan(kind: .sell, price: 10, quantity: 5)
        let seller = PoolBudgetProjection.calculate(positions: [], entries: [.init(symbol: symbol, plan: sell, accountID: .financing)])
        let holder = PoolBudgetProjection.calculate(positions: [.init(symbol: symbol, name: "Apple", quantity: 10, price: 10, currencyCode: "USD", poolQuantities: [.strategic: 10])], entries: [])
        let sales = PoolBudgetProjection.Result.combiningAccounts([seller, holder])
        #expect(sales.overSellWarnings.count == 1)
        #expect(sales.overSellWarnings.first?.available == 0)
        #expect(sales.currency("USD")?.holdingsAfter == 100)
    }

    @Test func combinedSameSymbolConcentrationAndUnknownCash() throws {
        let a = PoolBudgetProjection.calculate(positions: [.init(symbol: symbol, name: "Apple", quantity: 4, price: 20, currencyCode: "USD", poolQuantities: [.strategic: 4])], entries: [], cash: ["USD": 100])
        let b = PoolBudgetProjection.calculate(positions: [.init(symbol: symbol, name: "Apple", quantity: 6, price: 20, currencyCode: "USD", poolQuantities: [.tactical: 6])], entries: [])
        let row = try #require(PoolBudgetProjection.Result.combiningAccounts([a, b]).currency("USD"))
        #expect(row.holdingsBefore == 200)
        #expect(row.cashBalance == nil && row.availableCash == nil)
        #expect(row.holdings.count == 1)
        #expect(row.holdings.first?.beforeQuantity == 10)
        #expect(row.holdings.first?.beforePercent == 100)
        #expect(row.topThreeBefore == 100)
        #expect(row.pools.first { $0.pool == .strategic }?.heldAmount == 80)
        #expect(row.pools.first { $0.pool == .tactical }?.heldAmount == 120)
    }

    @Test func signedFallbackAndNestedTagWireGates() throws {
        let short = WatchItem(symbol: symbol, displayName: "Apple", transactions: [.init(kind: .sell, price: 10, quantity: 5, date: .now)])
        #expect(short.positionAccountQuantities(enclosingAccountID: .financing) == [.financing: -5])
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 5, date: .now)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [buy])
        let portion = PositionPortion(quantity: 5, origin: .init(kind: .buy, transactionID: buy.id, date: buy.date, price: buy.price, quantity: buy.quantity), brokerageAccountID: .mengmeng)
        item.positionAllocation = .init(basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [portion])
        let snapshot = WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [.init(accountID: .financing, items: [item])])
        let encoded = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["version"] as? Int == 14)
        #expect(try WatchlistSyncWireCodec.decode(encoded).snapshot == snapshot)
        json["version"] = 13
        #expect(throws: (any Error).self) { try WatchlistSyncWireCodec.decode(JSONSerialization.data(withJSONObject: json)) }
        // Even a new audit kind without a live tag needs the new reader.
        var untagged = portion; untagged.brokerageAccountID = nil
        var allocation = try #require(item.positionAllocation)
        allocation.portions = [untagged]
        allocation.changes = [.init(kind: .account, reason: "cleared", previousPortions: [untagged], resultingPortions: [untagged])]
        #expect(allocation.hasBrokerageTagMetadata)
    }
}
