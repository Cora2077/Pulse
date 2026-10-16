import Foundation
import PulseCore

/// Checked transaction editing, deletion, and review for the mobile workbench.
///
/// These are the writes that can change what a ledger *means* — a re-priced
/// trade restates cost basis and realized P&L, a deletion can turn a later sale
/// into a short, and a review edit is the only one that touches no number at
/// all. They are deliberately separate methods rather than one `save`, because
/// a single entry point invites a form to submit a review through the value
/// path and rewrite a price by accident.
@MainActor
public struct TransactionWorkflow: Sendable {
    public let store: WatchlistStore

    public init(store: WatchlistStore) {
        self.store = store
    }

    // MARK: - Edit values

    /// Saves corrected trade values.
    ///
    /// The draft carries the whole original record, which is exactly the stamp
    /// `updateTransaction(_:expected:account:)` compares. A review made on
    /// another device between open and submit changes the live record, the
    /// store sees a mismatch, and refuses — instead of the form overwriting
    /// review text the user never saw.
    ///
    /// Account changes are refused before the store is reached. The store also
    /// refuses them, but only after checking the rest, and the message the user
    /// needs is about the account.
    public func save(
        _ draft: TransactionEditDraft
    ) -> MobileWorkflowOutcome<TransactionEditDraft, PositionTransaction> {
        guard draft.accountFreeze.isSelfConsistent else {
            return .refused(.accountUnavailable(draft.accountFreeze.account), draft: draft)
        }
        if store.brokerageAccountsEnabled != draft.accountFreeze.brokerageAccountsEnabled {
            return .refused(.accountModeChanged, draft: draft)
        }
        // The record lives in the ledger the draft froze. Reading the store's
        // *selected* ledger instead would report `transactionNotFound` for a
        // trade that is right there in the account the form is about — a
        // confusing lie that would also hide the real problem from the user.
        guard let account = resolvedAccount(for: draft),
              let item = ledgerItem(for: draft.symbol, account: account) else {
            return .refused(.accountUnavailable(draft.accountFreeze.account), draft: draft)
        }
        guard item.supportsPosition else {
            return .refused(.itemNotFound(draft.symbol), draft: draft)
        }
        guard let live = item.transactions.first(where: { $0.id == draft.original.id }) else {
            return .refused(.transactionNotFound(draft.original.id), draft: draft)
        }
        guard draft.original.matches(live) else {
            return .refused(.staleTransactionRecord(draft.original.id), draft: draft)
        }
        // A plan-linked trade may not change side. The store enforces this too
        // (`immutablePlanContext`); checking here keeps the message on the side
        // selector rather than arriving as a generic store refusal.
        if live.planExecution != nil || hasLegacyPlanLink(live.id, symbol: draft.symbol, account: account) {
            guard draft.candidate.kind == live.kind else {
                return .refused(.immutablePlanContext, draft: draft)
            }
        }
        // A new margin buy is only lawful in the financing account, and only
        // when the trade already said margin. `updateTransaction` asks the same
        // question; this repeats it so the refusal names the funding field.
        if live.kind == .buy, draft.candidate.fundingSource == .margin,
           store.brokerageAccountsEnabled, account != .financing,
           draft.candidate.fundingSource != live.fundingSource {
            return .refused(.fundingNotAllowed(account: account, funding: .margin), draft: draft)
        }
        if store.brokerageAccountsEnabled, live.kind == .buy, account != .financing,
           draft.candidate.fundingSource == .margin, live.fundingSource != .margin {
            return .refused(.fundingNotAllowed(account: account, funding: .margin), draft: draft)
        }

        let candidate = draft.candidate
        guard candidate.price.isFinite,
              candidate.kind == .sell ? candidate.price > 0 : candidate.price >= 0,
              candidate.quantity.isFinite, candidate.quantity > 0,
              candidate.hasValidFee,
              (candidate.price * candidate.quantity).isFinite,
              candidate.date.timeIntervalSince1970.isFinite,
              candidate.note.map({ $0.count <= 4_000 }) ?? true else {
            return .refused(.invalidFillValues, draft: draft)
        }
        if candidate.brokerageAccountID != nil, candidate.brokerageAccountID != live.brokerageAccountID {
            return .refused(.accountUnavailable(account), draft: draft)
        }

        do {
            // The draft was opened from the stored record with every optional
            // metadata field in hand, so its `nil`s are statements — the user
            // cleared the note, the review, or the funding — not omissions.
            // `replaceOptionalMetadata` is what lets the store tell that from
            // an import-style payload that simply never carried them; identity,
            // chronology, account, and plan context stay frozen either way.
            let updated = try store.updateTransaction(draft.symbol, candidate,
                                                     expected: draft.original.record,
                                                     account: account,
                                                     replaceOptionalMetadata: true)
            return .written(updated)
        } catch let error as TradeMutationError {
            return .refused(Self.translate(error, symbol: draft.symbol), draft: draft)
        } catch let error as TradePlanExecutionError {
            return .refused(FillWorkflow.translate(error, draft: FillDraft(
                symbol: draft.symbol, intent: .unlinked, kind: candidate.kind,
                accountFreeze: draft.accountFreeze
            )), draft: draft)
        } catch {
            return .refused(.storeRejected(FillWorkflow.describe(error)), draft: draft)
        }
    }

    // MARK: - Delete

    /// Deletes exactly the record the draft froze.
    ///
    /// Unlike `deleteTransaction(_:id:)` — which re-reads the original and so
    /// deletes whatever is there *now* — this goes through the `expected` form.
    /// A record that changed since the form was drawn is refused rather than
    /// removed on the strength of a stale confirmation.
    public func delete(
        symbol: SymbolID,
        transaction: PositionTransaction,
        account: BrokerageAccountID
    ) -> MobileWorkflowOutcome<TransactionEditDraft, PositionTransaction> {
        let draft = TransactionEditDraft.editing(transaction, symbol: symbol,
                                                 account: account, in: store)
        if store.brokerageAccountsEnabled != draft.accountFreeze.brokerageAccountsEnabled {
            return .refused(.accountModeChanged, draft: draft)
        }
        guard let resolved = resolvedAccount(symbol: symbol, account: account),
              let item = ledgerItem(for: symbol, account: resolved) else {
            return .refused(.accountUnavailable(account), draft: draft)
        }
        guard item.supportsPosition else {
            return .refused(.itemNotFound(symbol), draft: draft)
        }
        guard let live = item.transactions.first(where: { $0.id == transaction.id }) else {
            return .refused(.transactionNotFound(transaction.id), draft: draft)
        }
        guard live == transaction else {
            return .refused(.staleTransactionRecord(transaction.id), draft: draft)
        }
        do {
            let removed = try store.deleteTransaction(symbol, id: transaction.id,
                                                     expected: transaction, account: resolved)
            return .written(removed)
        } catch let error as TradeMutationError {
            return .refused(Self.translate(error, symbol: symbol), draft: draft)
        } catch {
            return .refused(.storeRejected(FillWorkflow.describe(error)), draft: draft)
        }
    }

    // MARK: - Review

    /// Writes only the execution reason and the post-trade review.
    ///
    /// The store's own review route addresses a record by **id alone** and
    /// writes through the **selected** ledger: it re-reads whatever is stored
    /// now and overwrites its note and review. Both facts shape this method.
    ///
    /// * The id is not a guard, so the draft's frozen record is. A form that sat
    ///   in the background while another device wrote a review would otherwise
    ///   silently discard that edit, so this refuses unless the frozen record
    ///   still equals the live one — and refuses a draft that froze none at all,
    ///   because an unchecked write here is exactly that hazard.
    /// * The ledger is not the caller's to choose. A named `account` that is not
    ///   the selected one would make the check read one ledger while the store
    ///   wrote another, so a mismatch is refused with `.accountChanged` rather
    ///   than pre-checked into a false success.
    ///
    /// A store that answers `false` for an unchanged payload is a success, not
    /// a failure: the values written are the ones already stored.
    public func saveReview(
        _ draft: ReviewDraft,
        account: BrokerageAccountID? = nil
    ) -> MobileWorkflowOutcome<ReviewDraft, PositionTransaction> {
        guard let owner = resolvedReviewAccount(account) else {
            return .refused(.accountUnavailable(account ?? .unassigned), draft: draft)
        }
        // The store will write the *selected* ledger. Reading any other ledger
        // here would validate one record and let the store touch another, so a
        // request for a different ledger is refused instead of silently
        // re-pointed at the selection.
        if store.brokerageAccountsEnabled, owner != store.activeBrokerageAccountID {
            return .refused(.accountChanged(expected: owner,
                                            actual: store.activeBrokerageAccountID), draft: draft)
        }
        guard let item = ledgerItem(for: draft.symbol, account: owner) else {
            return .refused(.itemNotFound(draft.symbol), draft: draft)
        }
        guard item.supportsPosition else {
            return .refused(.itemNotFound(draft.symbol), draft: draft)
        }
        guard let live = item.transactions.first(where: { $0.id == draft.transactionID }) else {
            return .refused(.transactionNotFound(draft.transactionID), draft: draft)
        }
        // The expectation is mandatory here: without it there is no way to tell
        // this draft's own record from one that moved underneath it.
        guard let expected = draft.expected else {
            return .refused(.staleTransactionRecord(draft.transactionID), draft: draft)
        }
        guard expected.matches(live) else {
            return .refused(.staleTransactionRecord(draft.transactionID), draft: draft)
        }
        // The store's review route answers `false` rather than throwing, so the
        // payload checks it skips have to run here: the same note-length limit
        // the value routes enforce, and the review's own normalization.
        if let note = draft.note, note.count > 4_000 {
            return .refused(.storeRejected(
                "The execution reason is too long; nothing was written."
            ), draft: draft)
        }
        if let review = draft.review, (try? review.normalizedForPersistence()) == nil {
            return .refused(.storeRejected(
                "The review text or dates are not valid; nothing was written."
            ), draft: draft)
        }
        let normalized = try? draft.review?.normalizedForPersistence()
        // `false` can only mean "the values were already exactly this" once the
        // record and the payload have been checked above, so it is reported as a
        // successful no-op rather than a refusal. The stored record is read back
        // so the caller receives the real value, not a rebuilt guess.
        _ = store.updateTransactionReview(
            draft.symbol,
            id: draft.transactionID,
            note: draft.note,
            review: normalized ?? draft.review
        )
        let stored = ledgerItem(for: draft.symbol, account: owner)?
            .transactions.first { $0.id == draft.transactionID }
        return .written(stored ?? live)
    }

    /// Writes a review through the same value-stamped route as an edit, for the
    /// cases where the review and the execution reason must move together with
    /// the values the user also corrected.
    ///
    /// This is not a second review rule: it goes through
    /// `updateTransaction(_:expected:account:)` and therefore carries the
    /// plan-link, funding, and negative-position protections that the
    /// review-only route deliberately skips. Use it only when the form really
    /// did edit a ledger value; a review on its own belongs in `saveReview`.
    public func saveWithValues(
        _ draft: TransactionEditDraft
    ) -> MobileWorkflowOutcome<TransactionEditDraft, PositionTransaction> {
        save(draft)
    }

    // MARK: - Reads

    /// The full ledger for one symbol in one account, as the store replays it.
    public func transactions(symbol: SymbolID, account: BrokerageAccountID) -> [PositionTransaction] {
        ledgerItem(for: symbol, account: account)?.transactions ?? []
    }

    /// The transaction's position allocation revision, for a form that shows
    /// portion cards beside it. Pure read.
    public func allocationRevision(symbol: SymbolID, account: BrokerageAccountID) -> UUID? {
        ledgerItem(for: symbol, account: account)?.positionAllocation?.revision
    }

    // MARK: - Helpers

    func liveItem(for symbol: SymbolID) -> WatchItem? {
        store.item(for: symbol) ?? store.retainedHistoryItem(for: symbol)
    }

    /// One instrument as it exists inside a *named* ledger.
    ///
    /// `WatchlistStore.item(for:)` reads the selected ledger, which is the wrong
    /// question whenever a draft is about an account the user is not currently
    /// standing in. `brokeragePortfolio(for:)` answers for the ledger that was
    /// asked about, and it is the same accessor the store's own
    /// `transactionItem` uses.
    func ledgerItem(for symbol: SymbolID, account: BrokerageAccountID) -> WatchItem? {
        let portfolio = accountPortfolio(account)
        return portfolio?.items.first { $0.symbol == symbol }
            ?? portfolio?.retainedHistoryItems.first { $0.symbol == symbol }
    }

    /// The ledger an edit will be written through.
    ///
    /// The draft's own freeze names it; the store's selection is used only to
    /// resolve `.unassigned` when named ledgers are off, which is the one case
    /// where the two are the same ledger under two spellings.
    private func resolvedAccount(for draft: TransactionEditDraft) -> BrokerageAccountID? {
        resolvedAccount(symbol: draft.symbol, account: draft.accountFreeze.account)
    }

    private func resolvedAccount(symbol: SymbolID, account: BrokerageAccountID) -> BrokerageAccountID? {
        if !store.brokerageAccountsEnabled {
            return account == .unassigned ? .unassigned : nil
        }
        guard account != .unassigned else { return nil }
        // The record must actually be reachable in that ledger, or the store's
        // `transactionItem` would throw `accountUnavailable` for a reason the
        // user cannot see.
        return ledgerItem(for: symbol, account: account) == nil ? nil : account
    }

    /// The ledger a review write will reach.
    ///
    /// A `ReviewDraft` carries no account of its own, and the store's review
    /// route writes through the selected ledger. The named ledger is used when
    /// one was given, and the selection otherwise — which is the same rule the
    /// store applies, so the record is looked for exactly where it will be
    /// written. The instrument is not consulted here: `saveReview` reads it
    /// from the resolved ledger itself and reports a missing one as
    /// `itemNotFound`, which is the more truthful error.
    private func resolvedReviewAccount(_ account: BrokerageAccountID?) -> BrokerageAccountID? {
        guard store.brokerageAccountsEnabled else {
            // Single-ledger mode keeps exactly one ledger for every caller.
            return account == nil || account == .unassigned ? .unassigned : nil
        }
        let owner = account ?? store.activeBrokerageAccountID
        // `.unassigned` is the pending-history ledger, which no named review
        // may be filed through.
        return owner == .unassigned ? nil : owner
    }

    private func accountPortfolio(_ account: BrokerageAccountID) -> BrokerageAccountPortfolio? {
        store.brokeragePortfolio(for: account)
    }

    private func hasLegacyPlanLink(_ id: UUID, symbol: SymbolID, account: BrokerageAccountID) -> Bool {
        let accounts = store.brokerageAccountsEnabled ? BrokerageAccountID.allCases : [account]
        return accounts.contains { owner in
            let portfolio = store.brokeragePortfolio(for: owner)
            return (portfolio.items + portfolio.retainedHistoryItems).contains { item in
                item.symbol == symbol && item.plans.contains { $0.filledTransactionID == id }
            }
        }
    }

    static func translate(_ error: TradeMutationError,
                          symbol: SymbolID) -> MobileWorkflowError {
        switch error {
        case .staleRecord: return .staleTransactionRecord(UUID())
        case .transactionNotFound: return .transactionNotFound(UUID())
        case .itemNotFound: return .itemNotFound(symbol)
        case .negativePosition: return .negativePosition
        case .immutablePlanContext: return .immutablePlanContext
        case .accountUnavailable: return .accountUnavailable(.unassigned)
        case .duplicateTransactionID: return .storeRejected(
            "This transaction id is already used by another record. Nothing was written."
        )
        case .fundingIncompatible: return .storeRejected(
            "Only the financing account can accept a new margin buy."
        )
        case .planDependencyConflict, .allocationNeedsReconciliation, .destinationConflict, .invalidSelection:
            return .storeRejected(error.errorDescription ?? "The store refused this change.")
        case .invalidValues, .invalidCandidate:
            return .invalidFillValues
        }
    }
}
