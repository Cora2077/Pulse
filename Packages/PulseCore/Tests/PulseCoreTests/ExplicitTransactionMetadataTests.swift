import Foundation
import Testing
@testable import PulseCore

@Suite("Explicit optional trade metadata edits")
struct ExplicitTransactionMetadataTests {
    @MainActor
    @Test("A complete editor can deliberately clear note and review without losing identity")
    func explicitClearPersists() throws {
        let suite = "ExplicitMetadata.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        let symbol = SymbolID(market: .us, code: "AAPL")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let trade = PositionTransaction(kind: .buy, price: 10, quantity: 20,
            note: "旧说明", review: PositionTransactionReview(followedPlan: true,
                retrospective: "旧复盘", strategy: "旧策略"), fundingSource: .own)
        store.addTransaction(symbol, trade)
        let original = try #require(store.item(for: symbol)?.transactions.first)
        var edited = original
        edited.note = nil
        edited.review = nil
        edited.createdAt = .distantFuture // chronology cannot be rewritten
        let accepted = try store.updateTransaction(symbol, edited, expected: original,
            account: .unassigned, replaceOptionalMetadata: true)
        #expect(accepted.note == nil && accepted.review == nil)
        #expect(accepted.id == original.id && accepted.createdAt == original.createdAt)
        #expect(accepted.price == original.price && accepted.quantity == original.quantity)
        let restored = WatchlistStore(defaults: defaults)
        #expect(restored.item(for: symbol)?.transactions.first?.review == nil)
        #expect(restored.item(for: symbol)?.transactions.first?.note == nil)
    }

    @MainActor
    @Test("Clearing one review field does not resurrect it from the original")
    func partialClearDoesNotMergeOldValues() throws {
        let suite = "PartialMetadata.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        let symbol = SymbolID(market: .us, code: "MSFT")
        store.add(SymbolInfo(symbol: symbol, name: "Microsoft"))
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 1,
            review: PositionTransactionReview(followedPlan: true, retrospective: "保留", strategy: "清除")))
        let original = try #require(store.item(for: symbol)?.transactions.first)
        var edited = original
        edited.review?.strategy = nil
        edited.review?.followedPlan = nil
        let accepted = try store.updateTransaction(symbol, edited, expected: original,
            account: .unassigned, replaceOptionalMetadata: true)
        #expect(accepted.review?.retrospective == "保留")
        #expect(accepted.review?.strategy == nil && accepted.review?.followedPlan == nil)
        #expect(throws: TradeMutationError.self) {
            _ = try store.updateTransaction(symbol, original, expected: original,
                account: .unassigned, replaceOptionalMetadata: true)
        }
    }
}
