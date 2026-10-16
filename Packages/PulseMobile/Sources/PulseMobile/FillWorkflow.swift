import Foundation
import PulseCore

/// Checked fill recording for the mobile workbench.
///
/// ## What this layer will not do
///
/// It will not fill in a price. `FillDraft.price` starts `nil` and this type
/// refuses a draft that still has none — it never reads a quote, a plan's
/// trigger price, a position's average cost, or a previous fill. The store
/// cannot enforce that (it only sees the number it is handed), so the rule has
/// to live at the one place a mobile fill is assembled. `TradePlan` says it
/// plainly: a plan records an *intention*, never a fill.
///
/// It will not pick an account on the user's behalf. A buy names its
/// destination; a sell names the ledger whose shares it consumes. `nil` means
/// "whichever is selected", which is exactly the silent redirect this wrapper
/// refuses.
///
/// It will not re-derive progress, remaining size, or available shares. Every
/// one of those questions has an existing reader — `TradePlanEntry`,
/// `TradePlanExecutionProgress`, `availableSalePlanQuantity` — and a mobile
/// copy would be a second accounting rule.
///
/// ## The account the draft froze is the account it writes
///
/// Every ledger this type reads is a **named ledger**, resolved from the
/// draft's `accountFreeze`, never from the store's current selection. The
/// store's own `item(for:)` and `recordTradePlanFill` read the *selected*
/// ledger; a plan-scoped write therefore has to be refused outright when the
/// selection has moved, because `recordTradePlanFill` would otherwise look for
/// the plan in a ledger the draft never named — and could find a namesake plan
/// there, or report `planNotFound` for a plan that is untouched in its own
/// ledger. Refusing first is the only answer that keeps the user's input and
/// writes nothing into the wrong account.
///
/// A *destination* is a separate, explicitly chosen thing and may legitimately
/// differ from the frozen source: a buy may be filed into a chosen account, and
/// a sale may consume shares held in another. That freedom is why the source is
/// frozen and checked while the destination is passed through — the two must
/// never be conflated.
///
/// ## Stable ids and honest retries
///
/// `FillDraft.transactionID` is minted once, when the draft is created, and
/// reused on every submission attempt. A retry therefore submits the *same*
/// event under the same id. If the first attempt really landed and the client
/// never saw the answer — a crash, a killed app, a lost confirmation — the
/// second submit finds that record and returns **it**, unchanged, instead of
/// minting a second trade or re-stamping `createdAt`.
///
/// The match is exact and total: the stored record must agree with the draft on
/// the id and on every fact the draft states. Same id with different facts is a
/// different event and is refused, never adopted. Two independent fills at the
/// same price and size carry different ids and are always two events — a
/// price/size lookup is never used, because it cannot tell a retry from a
/// second genuine fill.
@MainActor
public struct FillWorkflow: Sendable {
    public let store: WatchlistStore

    public init(store: WatchlistStore) {
        self.store = store
    }

    // MARK: - Submit

    /// Submits a fill draft.
    ///
    /// The order of the checks is the order of the harm each one prevents:
    /// account first (a wrong ledger is the hardest mistake to unpick), then the
    /// already-written retry (a real retry must not become a duplicate, and it
    /// must be recognised even when the plan it filled has since moved or been
    /// deleted), then the frozen revisions (a write onto a record that moved),
    /// then the values (a price the user never entered), then the plan's own
    /// state, and only then the store.
    public func submit(_ draft: FillDraft) -> MobileWorkflowOutcome<FillDraft, PositionTransaction> {
        // Account first, and before the instrument is even read: every ledger
        // read below is scoped to the frozen account, and the store's plan-fill
        // route can only write the *selected* ledger — so a draft whose ledger
        // is no longer selected has no lawful write at all and must be refused
        // with the user's input intact.
        guard let account = frozenAccount(of: draft) else {
            return .refused(accountRefusal(for: draft), draft: draft)
        }

        // The idempotent retry, asked before anything else can be refused.
        //
        // This has to run *before* the plan-existence and plan-state checks: a
        // first submit that landed may have completed the plan and derived
        // `.done` — or the user may have deleted the finished plan — and
        // neither says anything about whether the fill was written. A record
        // already stored under this id, agreeing with the draft on every fact
        // the draft states, is the answer to the submission — not a new event
        // and not a refusal. The search spans every ledger, because the write
        // itself may have landed in the destination rather than the frozen
        // source, and transaction ids are unique across the whole store.
        if let stored = writtenRecord(for: draft) {
            return retryOutcome(stored, draft: draft)
        }

        // A plan-scoped fill is read from the ledger that holds the plan. That
        // is the frozen ledger, which the guard above has just proved is also
        // the store's selection — the two are the same ledger here, which is
        // exactly why a namesake plan in another ledger can never be reached.
        let plan: TradePlan?
        switch draft.intent {
        case .planFill, .planBackfill:
            guard let planID = draft.planID else {
                return .refused(.planRequired(draft.intent), draft: draft)
            }
            guard let live = ledgerItem(for: draft.symbol, account: account)?
                .plans.first(where: { $0.id == planID }) else {
                return .refused(.planNotFound(planID), draft: draft)
            }
            plan = live
        case .unlinked:
            guard draft.planID == nil else {
                return .refused(.planNotAllowed(draft.intent), draft: draft)
            }
            plan = nil
        }

        let destination = draft.destinationAccount ?? account

        // The frozen plan revision, fail closed. A plan-scoped draft that froze
        // no revision cannot prove the plan it was drawn against is the plan
        // stored now, so it is refused — exactly as a review draft with no
        // expected record is. Passing the live plan's own `updatedAt` to the
        // store instead would neutralize the store's check too, which is the
        // fail-open shape this guard exists to remove.
        var expectedPlanUpdatedAt: Date?
        if let plan {
            guard let revision = draft.planRevision else {
                return .refused(.stalePlanRevision(plan.id), draft: draft)
            }
            expectedPlanUpdatedAt = revision.updatedAt
            // `.adjustment` has no plan side, so a plan-linked calibration is
            // not a side mismatch — it is a route this build does not wrap, and
            // it is refused as such just below rather than mislabelled.
            if draft.kind != .adjustment, plan.kind.transactionKind != draft.kind {
                return .refused(.kindMismatch(plan: plan.kind, draft: draft.kind), draft: draft)
            }
            // The frozen revision is the whole plan, not just its timestamp, so
            // this refuses an edit the store's `expectedPlanUpdatedAt` alone
            // would have let through in the same clock tick.
            if !revision.matches(plan) {
                return .refused(.stalePlanRevision(plan.id), draft: draft)
            }
            // `.adjustment` is a calibration, not a fill. The store's fill route
            // cannot express it, and this build does not pretend otherwise.
            if draft.kind == .adjustment {
                return .refused(.unsupported("plan-linked calibration"), draft: draft)
            }
            // The entry is read from the ledger the draft froze, never from the
            // store's selection: asking about a different ledger would answer
            // about a different record that merely shares the plan's id.
            let entry = ledgerEntry(symbol: draft.symbol, plan: plan, account: account)
            let intentIsAcceptable: Bool
            switch draft.intent {
            case .planFill:
                // Ordinary recording requires a waiting plan, exactly as the
                // store re-checks on its own values.
                intentIsAcceptable = entry?.displayState == .waiting
            case .planBackfill:
                intentIsAcceptable = entry?.canBackfillFill == true
            case .unlinked:
                intentIsAcceptable = false
            }
            guard intentIsAcceptable else {
                return .refused(.planNotRecordable(status: plan.status, intent: draft.intent), draft: draft)
            }
        } else {
            // A standalone calibration is not wrapped: `recordTransaction` and
            // `recordBuyTransaction` both refuse `.adjustment`, and the one
            // route that accepts it is the import/calibration path, which is not
            // a mobile form. Saying so is better than approximating it.
            if draft.kind == .adjustment {
                return .refused(.unsupported("standalone calibration"), draft: draft)
            }
            // A standalone sale cannot name portions: the store's standalone
            // route (`addNamedTransaction`) has no selection parameter, so the
            // cards could be validated here and then silently dropped at the
            // write. Refusing is the honest answer until the store grows one.
            if draft.kind == .sell, draft.salePortionQuantities != nil {
                return .refused(.unsupported("standalone sale portion selection"), draft: draft)
            }
        }

        // Destination lawfulness. `resolveBuyDestination` enforces the same
        // rule for a buy inside the store; asking first is what lets the form
        // point at the account picker instead of showing a generic rejection.
        if store.brokerageAccountsEnabled {
            // Once named ledgers exist, `.unassigned` is the pending-history
            // ledger — not an account a purchase can be filed into, and not a
            // ledger a named sale can consume through the store's route.
            guard destination != .unassigned else {
                return .refused(.destinationNotAllowed(destination), draft: draft)
            }
            if draft.kind == .buy {
                guard let funding = draft.fundingSource,
                      destination.permitsBuy(fundingSource: funding) else {
                    return .refused(.fundingNotAllowed(account: destination,
                                                       funding: draft.fundingSource ?? .unmarked), draft: draft)
                }
            }
        }

        guard let price = draft.price else {
            return .refused(.fillPriceRequired, draft: draft)
        }
        guard let quantity = draft.quantity else {
            return .refused(.fillQuantityRequired, draft: draft)
        }
        guard price.isFinite, price > 0, quantity.isFinite, quantity > 0,
              (price * quantity).isFinite,
              draft.fee.map({ $0.isFinite && $0 >= 0 }) ?? true,
              draft.date.timeIntervalSince1970.isFinite,
              draft.note.map({ $0.count <= 4_000 }) ?? true else {
            return .refused(.invalidFillValues, draft: draft)
        }

        // A partial card selection is meaningless: the store requires the named
        // quantities to sum to the fill. Catching it here keeps the message
        // about the rows the user drew rather than about the ledger.
        if let selection = draft.salePortionQuantities, draft.kind == .sell {
            guard draft.saleAllocationRevision != nil else {
                return .refused(.saleSelectionIncomplete, draft: draft)
            }
            let total = selection.values.reduce(0, +)
            guard !selection.isEmpty, selection.values.allSatisfy({ $0.isFinite && $0 > 0 }),
                  abs(total - quantity) <= PositionAllocation.quantityTolerance(total, quantity) else {
                return .refused(.saleSelectionIncomplete, draft: draft)
            }
            // The allocation a sale checks against is the *executing* ledger's:
            // a plan sell executed into another account consumes that account's
            // cards, and the store compares the revision against that item too.
            if let frozen = draft.saleAllocationRevision,
               ledgerItem(for: draft.symbol, account: destination)?.positionAllocation?.revision != frozen {
                return .refused(.staleAllocationRevision, draft: draft)
            }
        }

        do {
            let transaction: PositionTransaction
            if let plan {
                transaction = try store.recordTradePlanFill(
                    symbol: draft.symbol,
                    planID: plan.id,
                    price: price,
                    quantity: quantity,
                    date: draft.date,
                    fee: draft.fee,
                    note: draft.note,
                    transactionID: draft.transactionID,
                    // Non-nil here: the plan branch above refuses a draft that
                    // froze no revision, so the store's own timestamp check is
                    // always armed with the frozen value, never with the live
                    // plan's current one.
                    expectedPlanUpdatedAt: expectedPlanUpdatedAt,
                    fundingSource: draft.kind == .buy ? (draft.fundingSource ?? .own) : nil,
                    brokerageAccountID: destination,
                    salePortionQuantities: draft.kind == .sell ? draft.salePortionQuantities : nil,
                    expectedAllocationRevision: draft.saleAllocationRevision,
                    historicalBackfill: draft.intent.historicalBackfill
                )
            } else if draft.kind == .buy {
                transaction = try store.recordBuyTransaction(
                    draft.symbol,
                    PositionTransaction(
                        id: draft.transactionID,
                        kind: .buy,
                        price: price,
                        quantity: quantity,
                        date: draft.date,
                        fee: draft.fee,
                        note: Self.normalizedNote(draft.note),
                        fundingSource: draft.fundingSource ?? .own,
                        brokerageAccountID: destination
                    ),
                    account: destination
                )
            } else {
                // A standalone sale consumes real shares through the same
                // checked replay as every other write. It carries no plan link,
                // so it can never move a plan's progress. The write goes to the
                // *destination* the draft named — the ledger whose shares it
                // consumes — never to the frozen account the form happens to
                // be standing in; the two legitimately differ, and ignoring
                // the destination would be the silent redirect the freeze
                // exists to prevent.
                transaction = try store.recordTransaction(
                    draft.symbol,
                    PositionTransaction(
                        id: draft.transactionID,
                        kind: .sell,
                        price: price,
                        quantity: quantity,
                        date: draft.date,
                        fee: draft.fee,
                        note: Self.normalizedNote(draft.note),
                        brokerageAccountID: destination == .unassigned ? nil : destination
                    ),
                    account: destination
                )
            }
            return .written(transaction)
        } catch let error as TradePlanExecutionError {
            return .refused(Self.translate(error, draft: draft), draft: draft)
        } catch let error as TradeMutationError {
            return .refused(Self.translate(error), draft: draft)
        } catch {
            return .refused(.storeRejected(Self.describe(error)), draft: draft)
        }
    }

    // MARK: - Retry detection

    /// A record found under the draft's transaction id, with the ledger and the
    /// instrument it was found in.
    private struct StoredMatch {
        let account: BrokerageAccountID
        let item: WatchItem
        let record: PositionTransaction
    }

    /// The already-written record a resubmission of this draft refers to, or
    /// `nil` when this is genuinely the first time the event is being written.
    ///
    /// The id is the only key, and the search spans **every** ledger: the
    /// store guarantees transaction ids are unique across all accounts, and the
    /// write itself may legitimately have landed in the draft's destination
    /// rather than its frozen source — a plan fill executed cross-account, or
    /// a standalone sale that named the ledger whose shares it consumed. A
    /// search that only looked in the frozen ledger would miss exactly those
    /// writes and report their honest retries as conflicts.
    ///
    /// A record found under the id is adopted **only** if the draft describes
    /// it exactly (`FillDraft.describes`, plus the source ledger and the
    /// sale-portion proof in `retryOutcome`); otherwise the submission is no
    /// retry at all and the caller refuses. That distinction is what keeps a
    /// reused id from silently standing in for a different trade.
    private func writtenRecord(for draft: FillDraft) -> StoredMatch? {
        for account in BrokerageAccountID.allCases {
            let portfolio = store.brokeragePortfolio(for: account)
            for item in portfolio.items + portfolio.retainedHistoryItems {
                if let record = item.transactions.first(where: { $0.id == draft.transactionID }) {
                    return StoredMatch(account: account, item: item, record: record)
                }
            }
        }
        return nil
    }

    /// Turns an already-stored record into the honest answer for a resubmission.
    ///
    /// An exact match is a success: the event exists, the store is the author of
    /// its `createdAt` and of any plan link the plan side recorded, and the
    /// stored value is returned so the caller adopts the real record rather than
    /// a rebuilt copy. A record under the same id that the draft does *not*
    /// describe — a different symbol, different values, a different plan, a
    /// different note, or a portion selection the allocation history cannot
    /// prove — is refused: adopting it would report somebody else's trade as
    /// this submission's result.
    private func retryOutcome(
        _ stored: StoredMatch,
        draft: FillDraft
    ) -> MobileWorkflowOutcome<FillDraft, PositionTransaction> {
        let sameEvent = stored.item.symbol == draft.symbol
            && draft.describes(stored.record)
            && draft.sourceMatches(stored.record, enclosingAccount: stored.account)
            && draft.saleSelectionProven(by: stored.item)
        guard sameEvent else {
            return .refused(.conflictingRetry(stored.record.id), draft: draft)
        }
        return .written(stored.record)
    }

    // MARK: - Reads

    /// The ledger a fill will be written into, resolved the way `submit`
    /// resolves it.
    ///
    /// This is a *display*: showing it lets the form say where the fill is going
    /// before the user commits, instead of moving them afterwards. The explicit
    /// destination wins, then the plan's own ledger **read from the draft's
    /// frozen account** (never from the store's selection, which may be a
    /// different ledger), and the frozen account is the floor.
    public func destinationLedger(for draft: FillDraft) -> BrokerageAccountID {
        if let explicit = draft.destinationAccount { return explicit }
        if let planID = draft.planID,
           let entry = liveEntry(symbol: draft.symbol, planID: planID,
                                 account: draft.accountFreeze.account) {
            return entry.accountID ?? draft.accountFreeze.account
        }
        return draft.accountFreeze.account
    }

    /// The plan-linked fills already recorded against one plan, as the store
    /// counts them. Read-only, and deliberately the store's own list rather
    /// than a filtered copy — a mobile summary that disagreed with the Mac
    /// board about which fills count would be worse than no summary.
    ///
    /// The account is required, not defaulted to the selection: a summary about
    /// a draft's plan must be read from the ledger that draft is about.
    public func linkedFills(symbol: SymbolID, planID: UUID,
                            account: BrokerageAccountID) -> [PositionTransaction] {
        store.transactionsForPlan(symbol, account: account, planID: planID)
    }

    // MARK: - Helpers

    /// The ledger a submission is allowed to read and write, or `nil` when the
    /// store no longer matches the freeze.
    ///
    /// This is the single account gate, applied to plan-linked and standalone
    /// fills alike. Both routes resolve their ledger from it, and the store's
    /// plan-fill route can only ever fill a plan in the *selected* ledger
    /// (`recordTradePlanFill` searches `allItems` and sets
    /// `source = activeBrokerageAccountID`), so a mismatch cannot be worked
    /// around by naming another ledger: it has to be refused.
    ///
    /// The `.accountModeChanged` spelling is preferred when the mode itself
    /// moved, because that is the more truthful description — a store with
    /// named ledgers on and a draft frozen with them off shares no ledger
    /// identity to compare, and `.unassigned` in that draft is not a ledger the
    /// live store has.
    func frozenAccount(of draft: FillDraft) -> BrokerageAccountID? {
        guard draft.accountFreeze.isSelfConsistent else { return nil }
        guard store.brokerageAccountsEnabled == draft.accountFreeze.brokerageAccountsEnabled else {
            return nil
        }
        guard store.activeBrokerageAccountID == draft.accountFreeze.account else { return nil }
        return draft.accountFreeze.account
    }

    /// The refusal that matches why `frozenAccount` returned `nil`.
    func accountRefusal(for draft: FillDraft) -> MobileWorkflowError {
        guard draft.accountFreeze.isSelfConsistent else {
            return .accountUnavailable(draft.accountFreeze.account)
        }
        guard store.brokerageAccountsEnabled == draft.accountFreeze.brokerageAccountsEnabled else {
            return .accountModeChanged
        }
        return .accountChanged(expected: draft.accountFreeze.account,
                               actual: store.activeBrokerageAccountID)
    }

    /// One instrument as it exists inside a **named** ledger.
    ///
    /// `store.item(for:)` reads the selected ledger, which is the wrong question
    /// whenever a draft is about an account the user is not currently standing
    /// in. `brokeragePortfolio(for:)` answers for the ledger that was asked
    /// about, and it is the same accessor the store's own `transactionItem`
    /// uses.
    func ledgerItem(for symbol: SymbolID, account: BrokerageAccountID) -> WatchItem? {
        let portfolio = store.brokeragePortfolio(for: account)
        return portfolio.items.first { $0.symbol == symbol }
            ?? portfolio.retainedHistoryItems.first { $0.symbol == symbol }
    }

    /// In the selected-ledger view. Kept for the callers that are genuinely
    /// asking about the store's selection rather than about a draft's ledger.
    func liveItem(for symbol: SymbolID) -> WatchItem? {
        store.item(for: symbol) ?? store.retainedHistoryItem(for: symbol)
    }

    /// The plan entry for one plan, read from the ledger the draft froze.
    ///
    /// The account is never the store's selection: the question being asked is
    /// "what does this plan look like in the ledger this draft is about", and
    /// reading the selected ledger instead would answer about a different
    /// record that merely shares the plan's id.
    func ledgerEntry(symbol: SymbolID, plan: TradePlan,
                     account: BrokerageAccountID) -> TradePlanEntry? {
        guard ledgerItem(for: symbol, account: account) != nil else { return nil }
        return TradePlanEntry(
            symbol: symbol,
            plan: plan,
            transactions: store.transactionsForPlan(symbol, account: account, planID: plan.id),
            accountID: account
        )
    }

    /// One plan re-read from the named ledger, paired with that ledger.
    ///
    /// Unlike the previous version this no longer conflates the two readings:
    /// the plan is read from `account` (never from the selection) and so are its
    /// fills, so an entry built here can never describe a namesake plan in
    /// another ledger.
    func liveEntry(symbol: SymbolID, planID: UUID,
                   account: BrokerageAccountID? = nil) -> TradePlanEntry? {
        let owner = account ?? store.activeBrokerageAccountID
        guard let item = ledgerItem(for: symbol, account: owner),
              let plan = item.plans.first(where: { $0.id == planID }) else { return nil }
        return TradePlanEntry(
            symbol: symbol,
            plan: plan,
            transactions: store.transactionsForPlan(symbol, account: owner, planID: planID),
            accountID: owner
        )
    }

    static func normalizedNote(_ note: String?) -> String? {
        MobileDraftNormalization.note(note)
    }

    static func translate(_ error: TradePlanExecutionError,
                          draft: FillDraft) -> MobileWorkflowError {
        switch error {
        case .itemNotFound: return .itemNotFound(draft.symbol)
        case .planNotFound: return .planNotFound(draft.planID ?? UUID())
        case .stalePlan:
            return draft.planID.map { .stalePlanRevision($0) } ?? .storeRejected("The plan changed.")
        case .duplicateTransactionID:
            // The wrapper already searched every ledger for this id and found
            // no record the draft describes, so an id collision here means a
            // record this draft does not describe owns it. Reporting that as a
            // conflict (rather than a bare store refusal) says why a retry that
            // should have been recognised was not.
            return .conflictingRetry(draft.transactionID)
        case .invalidFill: return .invalidFillValues
        case .invalidBuyAccount, .invalidBuyMethod:
            return .destinationNotAllowed(draft.destinationAccount ?? draft.accountFreeze.account)
        case .staleAllocation: return .staleAllocationRevision
        case .allocationNeedsReconciliation:
            return .storeRejected("Reconcile the position allocation before recording this sale.")
        case .fundingSelectionRequired:
            return .storeRejected("This sale spans more than one funding source. Choose which portions to sell.")
        case .invalidFundingSelection: return .saleSelectionIncomplete
        case .unsupportedInstrument: return .itemNotFound(draft.symbol)
        case .historicalPoolSale:
            return .storeRejected("A historical sale cannot consume today's pool shares. Record it as a regular trade, then reconcile.")
        case let .insufficientPoolQuantity(_, requested, available):
            return .storeRejected("The pool has \(available) units; \(requested) were requested.")
        }
    }

    static func translate(_ error: TradeMutationError) -> MobileWorkflowError {
        switch error {
        case .staleRecord: return .staleTransactionRecord(UUID())
        case .transactionNotFound: return .transactionNotFound(UUID())
        case .negativePosition: return .negativePosition
        case .immutablePlanContext: return .immutablePlanContext
        case .accountUnavailable: return .accountUnavailable(.unassigned)
        case .fundingIncompatible: return .storeRejected(
            "Only the financing account can accept a new margin buy."
        )
        case .duplicateTransactionID: return .storeRejected(
            "This transaction id is already used by another record. Nothing was written."
        )
        case .itemNotFound: return .itemNotFound(SymbolID(market: .us, code: "?"))
        default:
            return .storeRejected(error.errorDescription ?? "The store refused this write.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let execution = error as? TradePlanExecutionError {
            return execution.errorDescription ?? String(describing: execution)
        }
        if let mutation = error as? TradeMutationError {
            return mutation.errorDescription ?? String(describing: mutation)
        }
        let localized = error.localizedDescription
        return localized.isEmpty ? String(describing: error) : localized
    }
}
