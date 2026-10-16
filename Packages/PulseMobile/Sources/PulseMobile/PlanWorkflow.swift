import Foundation
import PulseCore

/// Checked plan operations for the mobile workbench.
///
/// Every method is a thin, honest translation of one existing
/// `WatchlistStore` entry point. Nothing here re-derives progress, re-implements
/// the allocation rules, or writes a plan field the store would not have written
/// itself — a wrapper that "helped" by computing its own remaining quantity
/// would be a second accounting rule, and the first disagreement between the two
/// would be a silently wrong plan.
///
/// The one thing this layer adds is *pre-flight*: the store's plan routes answer
/// `Bool` (or throw a store error) and leave a caller to guess which field it
/// disliked. A mobile form needs to say "this plan changed while you were away"
/// and keep what the user typed, so the wrapper compares the draft's frozen
/// revision against the live record first, refuses with a specific error, and
/// hands the draft back untouched.
@MainActor
public struct PlanWorkflow: Sendable {
    public let store: WatchlistStore

    public init(store: WatchlistStore) {
        self.store = store
    }

    // MARK: - Create / edit

    /// Saves a new or edited plan.
    ///
    /// An edit starts from the *stored* plan, exactly as the Mac editor does,
    /// so `id`, `createdAt`, `filledTransactionID`, and `history` survive a
    /// price correction. `setTradePlan` appends the prior configuration to
    /// `history` itself; duplicating that here would double-count a revision.
    ///
    /// A refusal returns the draft with the user's values intact. The store's
    /// own `setTradePlan` reports a rejection as `false` with no reason, so the
    /// wrapper's own checks — instrument supports trades, revision still
    /// current, payload shape, condition ids unique — are what turn a silent
    /// `false` into something a form can display.
    ///
    /// The plan lands in the ledger the form was opened against, and only
    /// there: `setTradePlan` writes the store's *selected* ledger, so a
    /// selection that moved since the draft froze its account is refused with
    /// the draft kept, never filed into whichever account is now on screen.
    public func save(_ draft: PlanDraft, newSymbolInfo: SymbolInfo? = nil) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        guard draft.accountFreeze.isSelfConsistent else {
            return .refused(.accountUnavailable(draft.accountFreeze.account), draft: draft)
        }
        // A draft frozen against a different account mode describes a store that
        // no longer exists. `setTradePlan` writes into the *selected* ledger, so
        // letting this through would file the plan somewhere the form never
        // showed.
        guard draft.accountFreeze.brokerageAccountsEnabled == store.brokerageAccountsEnabled else {
            return .refused(.accountModeChanged, draft: draft)
        }
        // The same rule as a fill: the frozen source account is the account the
        // plan is written into, and the store reaches it only through the
        // selection. A moved selection is refused with the draft kept.
        guard store.activeBrokerageAccountID == draft.accountFreeze.account else {
            return .refused(.accountChanged(expected: draft.accountFreeze.account,
                                            actual: store.activeBrokerageAccountID), draft: draft)
        }
        let standIn: WatchItem? = {
            guard draft.planID == nil, let info = newSymbolInfo, info.symbol == draft.symbol else { return nil }
            return WatchItem(symbol: info.symbol, displayName: info.name,
                             displayNameSource: info.displayNameSource, instrumentType: info.type)
        }()
        guard let item = ledgerItem(for: draft.symbol, account: draft.accountFreeze.account) ?? standIn,
              item.supportsPosition else {
            return .refused(.itemNotFound(draft.symbol), draft: draft)
        }

        let existing = draft.planID.flatMap { id in
            item.plans.first { $0.id == id }
        }
        if let planID = draft.planID, existing == nil {
            return .refused(.planNotFound(planID), draft: draft)
        }
        // The frozen revision is the whole point of opening an edit draft: a
        // plan that moved since the form was drawn must not be overwritten. An
        // edit draft that froze no revision would silently overwrite whatever
        // is stored, so it is refused rather than guessed at.
        if let revision = draft.revision {
            guard let existing, revision.matches(existing) else {
                return .refused(.stalePlanRevision(draft.planID ?? UUID()), draft: draft)
            }
        } else if draft.planID != nil {
            return .refused(.stalePlanRevision(draft.planID ?? UUID()), draft: draft)
        }

        guard let price = validatedAmount(draft.price), let quantity = validatedAmount(draft.quantity) else {
            return .refused(.invalidFillValues, draft: draft)
        }
        if case let .failure(error) = validateConditions(draft.conditions) {
            return .refused(error, draft: draft)
        }
        if let execution = draft.executionAccountID, !Self.isStorableExecutionAccount(execution, store: store) {
            return .refused(.accountUnavailable(execution), draft: draft)
        }

        // The idempotent create retry. A new plan has no `planID`, so its
        // identity is the `newPlanID` minted when the draft was opened. If that
        // identity is already stored, the first save landed without the client
        // seeing the answer: an identical draft is adopted, and a changed one
        // is refused — the draft froze no revision of the landed plan, so
        // overwriting it would be a blind edit. Editing drafts never reach
        // this branch: their `planID` routes them through the revision checks
        // above, which the retry must not bypass.
        if draft.planID == nil, let newPlanID = draft.newPlanID,
           let landed = item.plans.first(where: { $0.id == newPlanID }) {
            guard Self.isLandedRetry(of: landed, draft: draft, price: price, quantity: quantity) else {
                return .refused(.stalePlanRevision(newPlanID), draft: draft)
            }
            return .written(landed)
        }

        var plan = existing ?? TradePlan(
            id: draft.planID ?? draft.newPlanID ?? UUID(),
            kind: draft.kind,
            price: price,
            quantity: quantity
        )
        plan.kind = draft.kind
        plan.price = price
        plan.quantity = quantity
        plan.note = Self.normalizedNote(draft.note)
        plan.positionPool = draft.positionPool
        plan.positionPortionID = draft.positionPortionID
        plan.fundingSource = draft.fundingSource
        plan.executionAccountID = draft.executionAccountID
        // An empty list is an explicit "no conditions"; a plan that never had
        // the field keeps `nil` so the two stay distinguishable — the same rule
        // the Mac editor applies.
        plan.conditions = draft.conditions.isEmpty && existing?.conditions == nil ? nil : draft.conditions

        // The allocation a bound sell was written against. `setTradePlan` asks
        // the same question on its own values, but a stale mobile form would
        // otherwise be refused with a generic "rejected" and no field to fix.
        if draft.positionPortionID != nil, plan.status == .active, draft.kind == .sell,
           let frozen = draft.allocationRevision,
           item.positionAllocation?.revision != frozen {
            return .refused(.staleAllocationRevision, draft: draft)
        }

        let saved: Bool
        if draft.planID == nil, store.item(for: draft.symbol) == nil,
           let info = newSymbolInfo, info.symbol == draft.symbol {
            saved = store.createTradePlan(plan, for: info, account: draft.accountFreeze.account)
        } else {
            saved = store.setTradePlan(plan, for: draft.symbol)
        }
        guard saved else {
            return .refused(.storeRejected(
                "The store rejected this plan. Check the price, size, linked position card, and conditions."
            ), draft: draft)
        }
        // Read back rather than echoing the candidate: the store may have
        // migrated a legacy payload or filled a default, and the caller needs
        // the value that will be there on the next launch.
        let stored = ledgerItem(for: draft.symbol, account: draft.accountFreeze.account)?
            .plans.first { $0.id == plan.id } ?? plan
        return .written(stored)
    }

    /// Whether the stored plan is exactly the plan this new draft already wrote.
    ///
    /// Compared on the fields the draft owns, against the values the store
    /// actually persisted (the store's own note normalization is applied to the
    /// draft side). `id`, `createdAt`, `updatedAt`, `history`, and
    /// `filledTransactionID` are excluded: they are the store's, not the
    /// draft's, and a retry must not re-stamp them. Conditions compare exactly
    /// as stored; a condition payload the store's own normalization would have
    /// adjusted (e.g. a padded title) conservatively fails the match, refusing
    /// the retry rather than claiming a plan nobody proved identical.
    private static func isLandedRetry(
        of stored: TradePlan,
        draft: PlanDraft,
        price: Double,
        quantity: Double
    ) -> Bool {
        let conditions: [TradePlanCondition]? = draft.conditions.isEmpty ? nil : draft.conditions
        return stored.kind == draft.kind
            && stored.price == price
            && stored.quantity == quantity
            && stored.note == MobileDraftNormalization.note(draft.note)
            && stored.conditions == conditions
            && stored.positionPool == draft.positionPool
            && stored.positionPortionID == draft.positionPortionID
            && stored.fundingSource == draft.fundingSource
            && stored.executionAccountID == draft.executionAccountID
    }

    /// Reports that "stop this plan" is **not a route this build can wrap**.
    ///
    /// `changeTradePlanStatus` accepts exactly two targets: `.cancelled`
    /// (abandon) and `.active` (revive). It refuses every other status
    /// explicitly (`status == .active || status == .cancelled`), and its own
    /// availability rule derives the action from the record, so there is no
    /// "mark it done" *action* anywhere in the store or in the Mac menu. A
    /// `.done` plan is normally *derived*: it is what a plan becomes when its
    /// linked fills complete it.
    ///
    /// A `.done` status can still be written, but only as a plan *edit* —
    /// `setTradePlan` accepts it, and that is how the backfill fixtures in
    /// PulseCore's own tests reach a stopped plan. That is a different act with
    /// a different meaning ("this plan is settled, write it down") than the
    /// action-shaped "stop" a user taps in a list, and folding the two together
    /// here would let a stale row close a plan the user never re-opened. Use
    /// `setStatus(_:on:)` when the intent really is an edit, and `abandon(_:)`
    /// for the one close-without-filling action the store offers.
    public func stop(_ entry: TradePlanEntry) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        let draft = PlanDraft.editing(entry, in: store) ?? PlanDraft(
            symbol: entry.symbol, kind: entry.plan.kind, price: entry.plan.price,
            quantity: entry.plan.quantity,
            accountFreeze: AccountFreeze(account: store.activeBrokerageAccountID,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled)
        )
        return .refused(.unsupported(
            "manually stopping a plan (the store allows only abandon or revive; "
            + "a done plan is derived from completed fills)"
        ), draft: draft)
    }

    /// Writes an explicit plan status as part of a plan *edit*.
    ///
    /// This is deliberately not called `stop`. It reaches `.done` through
    /// `setTradePlan`, the same route PulseCore's backfill fixtures use, and it
    /// requires the caller to have opened an edit draft — so the write is always
    /// against a revision the user was actually shown, never against a row that
    /// happened to be on screen. A draft that does not freeze a revision is
    /// refused, exactly as `save` refuses it.
    ///
    /// `.active` and `.cancelled` are accepted here too, but `revive(_:)` and
    /// `abandon(_:)` remain the right calls for those: they additionally check
    /// the store's action-availability rule, which this route does not.
    public func setStatus(
        _ status: TradePlan.Status,
        on draft: PlanDraft
    ) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        guard let planID = draft.planID else {
            return .refused(.planNotFound(UUID()), draft: draft)
        }
        // The same account law as `save`: `setTradePlan` writes the store's
        // *selected* ledger, so a draft whose frozen account is no longer
        // selected is refused with the draft kept, never written into
        // whichever account is now on screen.
        guard draft.accountFreeze.isSelfConsistent else {
            return .refused(.accountUnavailable(draft.accountFreeze.account), draft: draft)
        }
        guard draft.accountFreeze.brokerageAccountsEnabled == store.brokerageAccountsEnabled else {
            return .refused(.accountModeChanged, draft: draft)
        }
        guard store.activeBrokerageAccountID == draft.accountFreeze.account else {
            return .refused(.accountChanged(expected: draft.accountFreeze.account,
                                            actual: store.activeBrokerageAccountID), draft: draft)
        }
        guard let item = ledgerItem(for: draft.symbol, account: draft.accountFreeze.account),
              item.supportsPosition else {
            return .refused(.itemNotFound(draft.symbol), draft: draft)
        }
        guard let existing = item.plans.first(where: { $0.id == planID }) else {
            return .refused(.planNotFound(planID), draft: draft)
        }
        guard let revision = draft.revision, revision.matches(existing) else {
            return .refused(.stalePlanRevision(planID), draft: draft)
        }
        // A settled or abandoned plan with linked fills still has to satisfy the
        // same binding rule an active one does; `setTradePlan` checks that on
        // its own values, and this guard only stops the obviously meaningless
        // write of a status that is already stored.
        guard existing.status != status else {
            return .written(existing)
        }
        var plan = existing
        plan.status = status
        guard store.setTradePlan(plan, for: draft.symbol) else {
            return .refused(.storeRejected(
                "The store rejected this status change. Check the linked position card and the plan's payload."
            ), draft: draft)
        }
        let stored = ledgerItem(for: draft.symbol, account: draft.accountFreeze.account)?
            .plans.first { $0.id == planID } ?? plan
        return .written(stored)
    }

    /// Abandons a live plan: the user gave up on it.
    ///
    /// This is the one "close this plan without filling it" route the store
    /// actually has. It is not a synonym for "stop" — an abandoned plan reads as
    /// abandoned, not as settled.
    public func abandon(_ entry: TradePlanEntry) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        changeStatus(entry, to: .cancelled)
    }

    /// Revives a stopped or abandoned plan back to waiting.
    ///
    /// The store's availability rule decides whether reviving is even
    /// meaningful — a fully filled plan has nothing to revive — and this method
    /// reports that as a refusal rather than forcing a status write.
    public func revive(_ entry: TradePlanEntry) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        changeStatus(entry, to: .active)
    }

    private func changeStatus(
        _ entry: TradePlanEntry,
        to status: TradePlan.Status
    ) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        let draft = PlanDraft.editing(entry, in: store) ?? PlanDraft(
            symbol: entry.symbol, kind: entry.plan.kind, price: entry.plan.price,
            quantity: entry.plan.quantity,
            accountFreeze: AccountFreeze(account: store.activeBrokerageAccountID,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled)
        )
        guard let account = entry.accountID else {
            return .refused(.accountUnavailable(store.activeBrokerageAccountID), draft: draft)
        }
        // The preflight reads the entry's own ledger by name, never the
        // selection: the store's write is addressed by that same named account,
        // so reading the selected ledger instead would judge — and could
        // misrefuse on — a namesake plan the entry is not about.
        guard let live = ledgerItem(for: entry.symbol, account: account)?
            .plans.first(where: { $0.id == entry.plan.id }) else {
            return .refused(.planNotFound(entry.plan.id), draft: draft)
        }
        guard live == entry.plan else {
            return .refused(.stalePlanRevision(entry.plan.id), draft: draft)
        }
        // Ask the same availability rule the menus ask, so a button that is
        // hidden in the UI cannot be reached by a stale deep link. The store
        // re-derives the identical rule and re-checks the target status on its
        // own values, so a stale entry still cannot talk it into a write.
        let required: TradePlanAction = status == .cancelled ? .abandon : .revive
        let liveEntry = TradePlanEntry(
            symbol: entry.symbol,
            plan: live,
            transactions: store.transactionsForPlan(entry.symbol, account: account, planID: live.id),
            accountID: account
        )
        guard TradePlanAction.available(for: liveEntry).contains(required) else {
            return .refused(.planNotRecordable(status: live.status,
                                               intent: .unlinked), draft: draft)
        }
        do {
            let updated = try store.changeTradePlanStatus(liveEntry, to: status)
            return .written(updated)
        } catch let error as TradePlanExecutionError {
            return .refused(Self.translate(error), draft: draft)
        } catch {
            return .refused(.storeRejected(Self.describe(error)), draft: draft)
        }
    }

    // MARK: - Delete

    /// Deletes exactly the plan the entry froze, in exactly the account it
    /// names.
    ///
    /// The account is passed through rather than re-read from the store's
    /// selection: `deleteTradePlan(_:for:account:)` addresses a named ledger,
    /// and a confirmation sheet that outlived an account switch must not remove
    /// a same-id plan from a ledger the user never opened. The wrapper checks
    /// the frozen account against the live selection first and refuses, which is
    /// the same protection the Mac confirmation applies.
    public func delete(_ entry: TradePlanEntry) -> MobileWorkflowOutcome<PlanDraft, TradePlan> {
        let draft = PlanDraft.editing(entry, in: store) ?? PlanDraft(
            symbol: entry.symbol, kind: entry.plan.kind, price: entry.plan.price,
            quantity: entry.plan.quantity,
            accountFreeze: AccountFreeze(account: store.activeBrokerageAccountID,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled)
        )
        guard let account = entry.accountID else {
            return .refused(.accountUnavailable(store.activeBrokerageAccountID), draft: draft)
        }
        let freeze = AccountFreeze(account: account,
                                   brokerageAccountsEnabled: store.brokerageAccountsEnabled)
        guard freeze.matches(store) else {
            if store.activeBrokerageAccountID != account {
                return .refused(.accountChanged(expected: account,
                                                actual: store.activeBrokerageAccountID), draft: draft)
            }
            return .refused(.accountModeChanged, draft: draft)
        }
        guard let live = ledgerItem(for: entry.symbol, account: account)?
            .plans.first(where: { $0.id == entry.plan.id }) else {
            return .refused(.planNotFound(entry.plan.id), draft: draft)
        }
        guard live == entry.plan else {
            return .refused(.stalePlanRevision(entry.plan.id), draft: draft)
        }
        do {
            try store.deleteTradePlan(live, for: entry.symbol, account: account)
            return .written(live)
        } catch let error as TradePlanExecutionError {
            return .refused(Self.translate(error), draft: draft)
        } catch {
            return .refused(.storeRejected(Self.describe(error)), draft: draft)
        }
    }

    // MARK: - Reads

    /// Every plan the store can offer, in the store's own display order.
    ///
    /// This is `store.tradePlanEntries` unchanged. It is exposed so a mobile
    /// list has one call to make and cannot accidentally build its own ordering
    /// or its own filled-quantity arithmetic.
    public var entries: [TradePlanEntry] { store.tradePlanEntries }

    /// One plan entry, re-read from the ledger that was asked about.
    ///
    /// The account defaults to the store's selection only because a caller that
    /// does not name one is asking about the selected ledger; a caller holding a
    /// draft must pass the draft's frozen account, and the draft-taking methods
    /// below do. The plan and its fills are both read from `account`, so an
    /// entry can never describe a namesake plan in another ledger.
    public func entry(symbol: SymbolID, planID: UUID,
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

    // MARK: - Helpers

    func liveItem(for symbol: SymbolID) -> WatchItem? {
        store.item(for: symbol) ?? store.retainedHistoryItem(for: symbol)
    }

    /// One instrument as it exists inside a **named** ledger.
    ///
    /// `store.item(for:)` reads the selected ledger, which is the wrong question
    /// for a draft frozen in a ledger the user is not standing in.
    /// `brokeragePortfolio(for:)` answers for the ledger that was asked about.
    func ledgerItem(for symbol: SymbolID, account: BrokerageAccountID) -> WatchItem? {
        let portfolio = store.brokeragePortfolio(for: account)
        return portfolio.items.first { $0.symbol == symbol }
            ?? portfolio.retainedHistoryItems.first { $0.symbol == symbol }
    }

    /// A finite, strictly positive number. `NaN` — the empty-draft sentinel —
    /// and infinities never pass.
    func validatedAmount(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Whether a plan may store this execution default. `nil` is the ordinary
    /// "decide when it fills"; `.unassigned` is refused because leaving the
    /// account blank already means that, and a stored value the reader cannot
    /// tell from "not chosen" would be a second spelling of the same thing.
    static func isStorableExecutionAccount(
        _ account: BrokerageAccountID,
        store: WatchlistStore
    ) -> Bool {
        guard account != .unassigned else { return false }
        return store.brokerageAccountsEnabled
    }

    func validateConditions(
        _ conditions: [TradePlanCondition]
    ) -> Result<Void, MobileWorkflowError> {
        // `TradePlanCondition.normalized()` is internal to PulseCore, and this
        // module deliberately does not re-implement it: a second copy of the
        // normalization rule is a second answer to "is this condition storable",
        // and the two would drift. The store performs the real check inside
        // `setTradePlan` and refuses the whole plan when any condition fails.
        //
        // What is checked here is only what is genuinely observable from the
        // public surface and would otherwise come back as an unexplained
        // `false`: duplicate ids (the store requires the set to be unique) and
        // empty titles (a condition with no title cannot be rendered or
        // reviewed, and the store's normalization trims it away).
        var seen = Set<UUID>()
        for condition in conditions {
            guard seen.insert(condition.id).inserted else {
                return .failure(.storeRejected("Two plan conditions share an id."))
            }
            let title = condition.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return .failure(.storeRejected("A plan condition has no title."))
            }
        }
        return .success(())
    }

    static func normalizedNote(_ note: String?) -> String? {
        MobileDraftNormalization.note(note)
    }

    static func translate(_ error: TradePlanExecutionError) -> MobileWorkflowError {
        switch error {
        case .itemNotFound: return .itemNotFound(SymbolID(market: .us, code: "?"))
        case .planNotFound: return .planNotFound(UUID())
        case .stalePlan: return .stalePlanRevision(UUID())
        case .staleAllocation: return .staleAllocationRevision
        case .allocationNeedsReconciliation, .insufficientPoolQuantity, .fundingSelectionRequired,
             .invalidFundingSelection, .historicalPoolSale:
            return .storeRejected(error.errorDescription ?? "The store refused this plan write.")
        case .invalidBuyAccount, .invalidBuyMethod: return .accountUnavailable(.unassigned)
        case .unsupportedInstrument: return .itemNotFound(SymbolID(market: .us, code: "?"))
        case .invalidFill, .duplicateTransactionID: return .invalidFillValues
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
