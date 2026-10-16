import Foundation
import PulseCore
import Testing

@testable import PulseMobile

@MainActor @Suite("Mobile transaction workflow")
struct TransactionWorkflowTests {
    /// Records one standalone buy so the edit tests have a record to work on.
    private func seedBuy(
        _ f: (store: WatchlistStore, defaults: UserDefaults, suite: String, symbol: SymbolID),
        price: Double = 100,
        quantity: Double = 10
    ) throws -> PositionTransaction {
        var draft = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        draft.destinationAccount = .financing
        draft.fundingSource = .own
        draft.price = price
        draft.quantity = quantity
        return try #require(FillWorkflow(store: f.store).submit(draft).value)
    }

    @Test("An edit writes the corrected values and keeps the record's identity")
    func editValues() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)

        let workflow = TransactionWorkflow(store: f.store)
        var draft = TransactionEditDraft.editing(original, symbol: f.symbol,
                                                account: .financing, in: f.store)
        draft.price = 88
        draft.quantity = 12
        draft.note = "corrected"

        let outcome = workflow.save(draft)
        let updated = try #require(outcome.value)
        #expect(updated.id == original.id)
        #expect(updated.createdAt == original.createdAt)
        #expect(updated.price == 88)
        #expect(updated.quantity == 12)
        #expect(updated.note == "corrected")

        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(stored.price == 88)
    }

    @Test("An edit against a record that changed is refused and keeps the draft")
    func staleRecordRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = TransactionEditDraft.editing(original, symbol: f.symbol,
                                                account: .financing, in: f.store)
        draft.price = 77

        // A review is written on another device between open and submit. That
        // is a content change the draft's frozen original does not contain.
        #expect(f.store.updateTransactionReview(f.symbol, id: original.id,
                                                note: "device review", review: nil))

        let outcome = workflow.save(draft)
        #expect(outcome.error == .staleTransactionRecord(original.id))
        #expect(outcome.draft?.price == 77, "the user's correction must survive")
        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(stored.price == 100, "nothing may be overwritten from a stale draft")
    }

    @Test("An edit that would make a later sale a short is refused")
    func negativePositionRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let buy = try seedBuy(f, price: 100, quantity: 10)

        // Sell 8, leaving 2.
        var sell = FillDraft.unlinked(symbol: f.symbol, kind: .sell, in: f.store)
        sell.destinationAccount = .financing
        sell.price = 110
        sell.quantity = 8
        #expect(FillWorkflow(store: f.store).submit(sell).didWrite)

        // Shrinking the buy to 5 would make the sale of 8 oversell history.
        let workflow = TransactionWorkflow(store: f.store)
        var draft = TransactionEditDraft.editing(buy, symbol: f.symbol,
                                                account: .financing, in: f.store)
        draft.quantity = 5

        let outcome = workflow.save(draft)
        #expect(outcome.error == .negativePosition)
        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first { $0.id == buy.id })
        #expect(stored.quantity == 10)
    }

    @Test("An edit cannot move a record to another account")
    func accountChangeRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = TransactionEditDraft.editing(original, symbol: f.symbol,
                                                account: .financing, in: f.store)
        draft.price = 88
        // The candidate tries to relabel the ledger it belongs to.
        var candidate = draft.candidate
        candidate.brokerageAccountID = .mengmeng
        // Rebuild the draft so the candidate carries the attempt.
        draft = TransactionEditDraft(
            original: draft.original, symbol: f.symbol,
            price: draft.price, quantity: draft.quantity, date: draft.date,
            fee: draft.fee, note: draft.note, fundingSource: draft.fundingSource,
            review: draft.review, accountFreeze: draft.accountFreeze
        )
        // The frozen original still holds the real account, so the rebuilt
        // candidate keeps it; the store is what must refuse a move, and this
        // asserts the wrapper's own candidate never introduces one.
        #expect(draft.candidate.brokerageAccountID == original.brokerageAccountID)
        #expect(candidate.brokerageAccountID == .mengmeng)
        #expect(workflow.save(draft).didWrite)
    }

    @Test("A margin buy in a non-financing account is refused on edit")
    func marginEditRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        var buy = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        buy.destinationAccount = .financing
        buy.fundingSource = .own
        buy.price = 100
        buy.quantity = 10
        let original = try #require(FillWorkflow(store: f.store).submit(buy).value)

        // A second buy in mengmeng, on own funds.
        var second = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        second.destinationAccount = .mengmeng
        second.fundingSource = .own
        second.price = 50
        second.quantity = 2
        let mengmengBuy = try #require(FillWorkflow(store: f.store).submit(second).value)

        let workflow = TransactionWorkflow(store: f.store)
        var draft = TransactionEditDraft.editing(mengmengBuy, symbol: f.symbol,
                                                account: .mengmeng, in: f.store)
        draft.fundingSource = .margin

        let outcome = workflow.save(draft)
        #expect(outcome.error == .fundingNotAllowed(account: .mengmeng, funding: .margin))
        // The untouched record still proves nothing was written.
        #expect(f.store.item(for: f.symbol)?.transactions
            .first { $0.id == original.id }?.price == 100)
    }

    @Test("An edit against a record that is not here is refused")
    func unknownRecordRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let ghost = PositionTransaction(kind: .buy, price: 10, quantity: 1)
        let draft = TransactionEditDraft(
            original: TransactionRevisionStamp(record: ghost),
            symbol: f.symbol, price: 12, quantity: 2, date: .now,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(TransactionWorkflow(store: f.store).save(draft).error
            == .transactionNotFound(ghost.id))
    }

    @Test("Delete removes exactly the frozen record and refuses a stale one")
    func deleteRecord() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        // A review edit changes the record after it was frozen.
        #expect(f.store.updateTransactionReview(f.symbol, id: original.id,
                                                note: "changed", review: nil))
        let stale = workflow.delete(symbol: f.symbol, transaction: original, account: .financing)
        #expect(stale.error == .staleTransactionRecord(original.id))
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)

        let live = try #require(f.store.item(for: f.symbol)?.transactions.first)
        let removed = workflow.delete(symbol: f.symbol, transaction: live, account: .financing)
        #expect(removed.value?.id == original.id)
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A delete that would orphan a recorded sale is refused")
    func deleteWithDependentSaleRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let buy = try seedBuy(f, price: 100, quantity: 10)

        var sell = FillDraft.unlinked(symbol: f.symbol, kind: .sell, in: f.store)
        sell.destinationAccount = .financing
        sell.price = 110
        sell.quantity = 4
        #expect(FillWorkflow(store: f.store).submit(sell).didWrite)

        // Removing the buy leaves the sale with nothing to consume.
        let outcome = TransactionWorkflow(store: f.store).delete(
            symbol: f.symbol, transaction: buy, account: .financing)
        #expect(outcome.error == .negativePosition)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 2)
    }

    @Test("A review write touches only the note and the review")
    func reviewWrite() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f, price: 100, quantity: 10)
        let workflow = TransactionWorkflow(store: f.store)

        let review = PositionTransactionReview(
            followedPlan: true,
            retrospective: "held to plan",
            strategy: "size up next time",
            nextReviewDate: Date(timeIntervalSince1970: 1_700_000_000),
            nextReviewNote: "watch earnings"
        )
        // Opened from the exact stored record, so the draft carries the
        // expectation the store's id-only route cannot supply itself.
        var draft = ReviewDraft.editing(original, symbol: f.symbol)
        draft.note = "executed at the open"
        draft.review = review
        let outcome = workflow.saveReview(draft)
        let written = try #require(outcome.value)
        #expect(outcome.didWrite)
        #expect(written.note == "executed at the open")
        #expect(written.review?.followedPlan == true)

        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(stored.note == "executed at the open")
        #expect(stored.review?.followedPlan == true)
        #expect(stored.review?.retrospective == "held to plan")
        #expect(stored.review?.nextReviewNote == "watch earnings")
        // Ledger values are untouched by the review route.
        #expect(stored.price == 100)
        #expect(stored.quantity == 10)
        #expect(stored.id == original.id)
    }

    @Test("A review for a record that is not here is refused")
    func reviewUnknownRecordRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let ghost = UUID()
        let draft = ReviewDraft(symbol: f.symbol, transactionID: ghost, note: "n",
                                expected: TransactionRevisionStamp(
                                    record: PositionTransaction(id: ghost, kind: .buy,
                                                                price: 1, quantity: 1)))
        #expect(TransactionWorkflow(store: f.store).saveReview(draft).error
            == .transactionNotFound(ghost))
    }

    @Test("A review is refused when the record changed after the form was opened")
    func reviewStaleRecordRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = ReviewDraft.editing(original, symbol: f.symbol)
        draft.review = PositionTransactionReview(retrospective: "mine")

        // Another device writes its own review between open and submit. The
        // store's review route would overwrite it on the strength of the id
        // alone; the frozen expectation is what refuses that.
        #expect(f.store.updateTransactionReview(f.symbol, id: original.id,
                                                note: "peer note",
                                                review: PositionTransactionReview(
                                                    retrospective: "peer review")))

        let outcome = workflow.saveReview(draft)
        #expect(outcome.error == .staleTransactionRecord(original.id))
        #expect(outcome.draft?.review?.retrospective == "mine",
                "the user's review text must survive the refusal")

        // Nothing of the peer's edit was lost, and nothing of the draft landed.
        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(stored.note == "peer note")
        #expect(stored.review?.retrospective == "peer review")
    }

    @Test("A review draft with no frozen record is refused rather than written blind")
    func reviewWithoutExpectationRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)

        // A hand-built draft that forgot to freeze the record it edits. Writing
        // it would be exactly the id-only overwrite the expectation prevents.
        let draft = ReviewDraft(symbol: f.symbol, transactionID: original.id, note: "blind")
        let outcome = TransactionWorkflow(store: f.store).saveReview(draft)
        #expect(outcome.error == .staleTransactionRecord(original.id))
        #expect(f.store.item(for: f.symbol)?.transactions.first?.note != "blind")
    }

    @Test("A review named against a non-selected ledger is refused, not silently re-pointed")
    func reviewNamedLedgerRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)
        let draft = ReviewDraft.editing(original, symbol: f.symbol)

        // The store's review route writes the *selected* ledger. Asking for a
        // different one would validate a record here and let the store touch
        // another, so it is refused rather than quietly answered from the
        // selection.
        #expect(f.store.selectBrokerageAccount(.mengmeng))
        let outcome = workflow.saveReview(draft, account: .financing)
        #expect(outcome.error == .accountChanged(expected: .financing, actual: .mengmeng))
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.transactions.first?.note
            == original.note)
    }

    @Test("Saving the same review twice is a successful no-op, not a refusal")
    func reviewIdempotent() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = ReviewDraft.editing(original, symbol: f.symbol)
        draft.note = "same"
        #expect(workflow.saveReview(draft).didWrite)

        // The retry is opened from the record the first save produced, so its
        // expectation is current — a real resubmission, not a stale one.
        let saved = try #require(f.store.item(for: f.symbol)?.transactions.first)
        var retry = ReviewDraft.editing(saved, symbol: f.symbol)
        retry.note = "same"
        // `updateTransactionReview` answers `false` for "no change"; that is a
        // success, and reporting it as an error would make an idempotent submit
        // look broken.
        #expect(workflow.saveReview(retry).didWrite)
        #expect(f.store.item(for: f.symbol)?.transactions.first?.note == "same")
    }

    @Test("The ledger read helpers return the store's own values")
    func reads() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        let records = workflow.transactions(symbol: f.symbol, account: .financing)
        #expect(records.count == 1)
        #expect(records.first?.id == original.id)
        #expect(workflow.allocationRevision(symbol: f.symbol, account: .financing)
            == f.store.item(for: f.symbol)?.positionAllocation?.revision)
    }

    @Test("A full edit can clear the note, the review, and the funding annotation")
    func editClearsOptionalMetadata() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        // Record a note and a review first, through the dedicated route.
        #expect(f.store.updateTransactionReview(
            f.symbol, id: original.id, note: "entered at the open",
            review: PositionTransactionReview(followedPlan: true, strategy: "sized right")))
        let reviewed = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(reviewed.note == "entered at the open")
        #expect(reviewed.review?.strategy == "sized right")
        #expect(reviewed.fundingSource == .own)

        // The full-edit draft owns every optional field, so clearing one is a
        // statement, not an omission: the values must actually be cleared.
        var draft = TransactionEditDraft.editing(reviewed, symbol: f.symbol,
                                                 account: .financing, in: f.store)
        draft.note = nil
        draft.review = nil
        draft.fundingSource = nil
        let updated = try #require(workflow.save(draft).value)
        #expect(updated.note == nil)
        #expect(updated.review == nil)
        // An explicit funding clear is stored as `.unmarked` — the user said
        // "unclassified" — never as nil's "nobody has said anything", which
        // would pass the old value off as still true on legacy merge routes.
        #expect(updated.fundingSource == .unmarked)
        // Ledger values and identity are untouched.
        #expect(updated.price == original.price)
        #expect(updated.quantity == original.quantity)
        #expect(updated.createdAt == original.createdAt)

        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first)
        #expect(stored.note == nil)
        #expect(stored.review == nil)
        #expect(stored.fundingSource == .unmarked)
    }

    @Test("An untouched funding annotation survives a value edit unchanged")
    func editKeepsUntouchedFunding() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = TransactionEditDraft.editing(original, symbol: f.symbol,
                                                 account: .financing, in: f.store)
        draft.price = 88
        let updated = try #require(workflow.save(draft).value)
        #expect(updated.fundingSource == .own,
                "an edit that never touched funding keeps the stored annotation")
        #expect(updated.note == original.note)
        #expect(updated.review == original.review)
    }

    @Test("A review note longer than the store's limit is refused before the write")
    func reviewNoteLengthRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let original = try seedBuy(f)
        let workflow = TransactionWorkflow(store: f.store)

        var draft = ReviewDraft.editing(original, symbol: f.symbol)
        draft.note = String(repeating: "x", count: 4_001)
        let outcome = workflow.saveReview(draft)
        #expect(outcome.error != nil)
        #expect(outcome.draft?.note?.count == 4_001, "the input comes back")
        #expect(f.store.item(for: f.symbol)?.transactions.first?.note == original.note)

        // The limit itself still writes.
        draft.note = String(repeating: "x", count: 4_000)
        #expect(workflow.saveReview(draft).didWrite)
        #expect(f.store.item(for: f.symbol)?.transactions.first?.note?.count == 4_000)
    }
}
