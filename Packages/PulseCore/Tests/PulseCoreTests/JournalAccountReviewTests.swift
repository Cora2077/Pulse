import Foundation
import Testing
@testable import PulseCore

@Suite("Journal review account ownership")
struct JournalAccountReviewTests {
    @Test("Empty, trimmed and invalid reviews have distinct persistence outcomes")
    func reviewNormalization() throws {
        #expect(try PositionTransactionReview(retrospective: "  ").normalizedForPersistence() == nil)
        let review = PositionTransactionReview(retrospective: "  Follow-up  ", nextReviewNote: "  Check event  ")
        #expect(try review.normalizedForPersistence() == .init(retrospective: "Follow-up", nextReviewNote: "Check event"))
        #expect(throws: PositionTransactionReviewValidationError.self) {
            try PositionTransactionReview(nextReviewDate: Date(timeIntervalSince1970: .infinity)).normalizedForPersistence()
        }
    }

    @MainActor @Test("Reviewing another ledger preserves selection, quantities and allocations")
    func reviewOwnerWhileAnotherAccountIsActive() throws {
        let suite = "JournalAccountReviewTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Fixture")
        let symbol = SymbolID(market: .sh, code: "600000")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        let financingBuy = try store.recordBuyTransaction(symbol,
            .init(kind: .buy, price: 10, quantity: 100, fundingSource: .margin), account: .financing)
        _ = try store.recordBuyTransaction(symbol,
            .init(kind: .buy, price: 20, quantity: 200, fundingSource: .own), account: .mengmeng)
        _ = store.selectBrokerageAccount(.mengmeng)
        let before = store.brokeragePortfolio(for: .financing)
        let other = store.brokeragePortfolio(for: .mengmeng)
        let review = PositionTransactionReview(followedPlan: true, retrospective: "Fixture review")
        let changed = store.withBrokerageAccount(.financing) {
            store.updateTransactionReview(symbol, id: financingBuy.id, note: "Saved to owner", review: review)
        }
        #expect(changed)
        #expect(store.activeBrokerageAccountID == .mengmeng)
        #expect(store.brokeragePortfolio(for: .mengmeng) == other)
        let updated = try #require(store.brokeragePortfolio(for: .financing).items.first)
        #expect(updated.positionQuantity == before.items.first?.positionQuantity)
        #expect(updated.positionAllocation == before.items.first?.positionAllocation)
        #expect(updated.transactions.first?.review == review)
        #expect(updated.transactions.first?.note == "Saved to owner")
        #expect(!updated.positionAllocationNeedsReconciliation)

        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Fixture")
        #expect(reloaded.brokeragePortfolio(for: .financing).items.first?.transactions.first?.review == review)
        #expect(reloaded.brokeragePortfolio(for: .mengmeng) == other)
    }
}
