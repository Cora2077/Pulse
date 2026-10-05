import Foundation
import Testing
@testable import PulseCore

@Suite("Trade review persistence")
struct TradeReviewPersistenceTests {
    @MainActor
    @Test("Review edits persist in retained history without changing the ledger")
    func retainedReviewRoundTrip() throws {
        let suite = "TradeReviewPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let symbol = SymbolID(market: .us, code: "AAPL")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = PositionTransaction(
            id: UUID(), kind: .buy, price: 180, quantity: 2,
            date: date, createdAt: date, note: "Initial reason"
        )
        let second = PositionTransaction(
            id: UUID(), kind: .sell, price: 190, quantity: 1,
            date: date, createdAt: date
        )
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, first)
        store.addTransaction(symbol, second)
        let before = try #require(store.item(for: symbol)?.transactions)

        let review = PositionTransactionReview(followedPlan: false, retrospective: "Wait for confirmation")
        #expect(store.updateTransactionReview(
            symbol, id: first.id, note: "  Chased momentum  ", review: review
        ))
        let reviewed = try #require(store.item(for: symbol)?.transactions)
        #expect(reviewed.map(\.id) == before.map(\.id))
        #expect(reviewed.map(\.price) == before.map(\.price))
        #expect(reviewed.map(\.quantity) == before.map(\.quantity))
        #expect(reviewed.map(\.date) == before.map(\.date))
        #expect(reviewed.map(\.createdAt) == before.map(\.createdAt))
        #expect(reviewed.first?.note == "Chased momentum")
        #expect(reviewed.first?.review == review)

        let agentTransaction = try #require(
            AgentWatchlistCommands(store: store).listPositions().first?.transactions.first
        )
        #expect(agentTransaction.note == "Chased momentum")
        #expect(agentTransaction.review == review)

        store.remove(symbol)
        #expect(store.tradeHistoryItems.map(\.symbol) == [symbol])
        #expect(store.updateTransactionReview(
            symbol,
            id: first.id,
            note: "After removal",
            review: PositionTransactionReview(followedPlan: true, retrospective: "Disciplined")
        ))

        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        let retained = try #require(reloaded.tradeHistoryItems.first)
        let savedTrade = try #require(retained.transactions.first { $0.id == first.id })
        #expect(savedTrade.note == "After removal")
        #expect(savedTrade.review == PositionTransactionReview(followedPlan: true, retrospective: "Disciplined"))

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "trade-review-test", snapshot: reloaded.syncSnapshot())
        let synced = try WatchlistSyncWireCodec.decode(wire)
        #expect(synced.version == 6)
        #expect(synced.snapshot.retainedHistoryItems.first?.transactions.first { $0.id == first.id }?.review == savedTrade.review)
    }

    @MainActor
    @Test("An ordinary trade edit cannot clear a saved review")
    func tradeEditPreservesReview() throws {
        let suite = "TradeReviewEditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let symbol = SymbolID(market: .us, code: "NVDA")
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        store.add(SymbolInfo(symbol: symbol, name: "NVIDIA"))
        var transaction = PositionTransaction(kind: .buy, price: 120, quantity: 3)
        transaction.review = PositionTransactionReview(followedPlan: true, retrospective: "Kept the limit")
        store.addTransaction(symbol, transaction)

        var edited = try #require(store.item(for: symbol)?.transactions.first)
        edited.price = 121
        edited.review = nil
        store.updateTransaction(symbol, edited)

        let saved = try #require(store.item(for: symbol)?.transactions.first)
        #expect(saved.price == 121)
        #expect(saved.review == transaction.review)
    }

    @Test("A transaction written before reviews still decodes")
    func oldTransactionDecodes() throws {
        let data = Data(#"{"id":"A0D0A0D0-A0D0-40D0-80D0-A0D0A0D0A0D0","kind":"buy","price":10,"quantity":1,"date":0,"createdAt":0}"#.utf8)
        let transaction = try JSONDecoder().decode(PositionTransaction.self, from: data)
        #expect(transaction.review == nil)
    }

    @Test("A one-sided review edit merges without a trade conflict")
    func syncMergesReviewEdit() throws {
        let symbol = SymbolID(market: .us, code: "MSFT")
        let baseTrade = PositionTransaction(
            id: UUID(), kind: .buy, price: 400, quantity: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var remoteTrade = baseTrade
        remoteTrade.review = PositionTransactionReview(followedPlan: true, retrospective: "Plan held")
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Microsoft", transactions: [baseTrade])],
            groups: [group]
        )
        let local = base
        let remote = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Microsoft", transactions: [remoteTrade])],
            groups: [group]
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items.first?.transactions.first?.review == remoteTrade.review)
    }
}
