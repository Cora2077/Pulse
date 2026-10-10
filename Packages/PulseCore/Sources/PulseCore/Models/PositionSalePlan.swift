import Foundation

/// A sell plan's tie to one existing position card.
///
/// A plan records an intention and a holding bucket; a *binding* goes one step
/// further and names the exact card the user meant to sell. It is deliberately
/// the narrowest possible claim:
///
/// * It is never guessed. A plan without `positionPortionID` stays unbound
///   forever, and a bound plan whose card moved, was spent, or was deleted
///   reads as having no source rather than falling back to a sibling card in
///   the same pool. The user is shown the stale state and edits or cancels it;
///   nothing here silently re-points a plan.
/// * It is never a reservation of shares by itself. `availableSalePlanQuantity`
///   exists so a second plan cannot be written against shares the first one
///   already claims, but a plan still moves nothing: only recording a fill
///   changes the ledger.
/// * Everything here is a pure read. No account is selected, no allocation is
///   touched, and asking a question never writes an answer back.
public extension WatchItem {
    /// The exact card a sell plan is bound to, or `nil` when there is not one.
    ///
    /// Every condition has to hold for the plan to have a live source, and any
    /// failure returns `nil` rather than the nearest lookalike:
    ///
    /// * the plan is a sell, carries a binding, and names an active pool;
    /// * the item is a position-bearing instrument with shares outstanding;
    /// * the allocation exists, is reconciled, and still holds a card with
    ///   exactly that id;
    /// * the card's quantity is finite and positive; and
    /// * the card's pool reads as the plan's pool once the retired observation
    ///   purpose is folded away — a binding recorded against `unassigned` is
    ///   not satisfied by a card the user has since filed under a real bucket,
    ///   and vice versa.
    ///
    /// Pool equality is asked through `effectivePurpose` on both sides so a
    /// legacy card stored as observation matches an unassigned plan, exactly as
    /// every other pool total reads it.
    func salePlanSource(for plan: TradePlan) -> PositionPortion? {
        guard plan.kind == .sell,
              let portionID = plan.positionPortionID,
              let planPool = plan.positionPool,
              planPool.isActivePurpose,
              supportsPosition,
              positionQuantity.isFinite, positionQuantity > 0,
              let allocation = positionAllocation,
              !positionAllocationNeedsReconciliation else { return nil }
        guard let portion = allocation.portions.first(where: { $0.id == portionID }),
              portion.quantity.isFinite, portion.quantity > 0,
              portion.pool.effectivePurpose == planPool.effectivePurpose else { return nil }
        return portion
    }

    /// How much of one card a new or edited sell plan may still claim.
    ///
    /// Answers "the card's verified quantity, less what other active sell plans
    /// already say they will take from it". Three deliberate choices:
    ///
    /// * Only *other* live plans count. `excludingPlanID` removes the plan being
    ///   edited, so re-saving a plan unchanged does not make it compete with
    ///   itself; cancelled and done plans are history and hold nothing back, so
    ///   cancelling a plan frees its claim immediately.
    /// * A plan that is not bound to this exact card reserves none of it. A plan
    ///   on a sibling card of the same pool, or one with no binding at all, is
    ///   not a claim on these shares — the store's pool-level accounting already
    ///   covers the coarser question.
    /// * The result is floored at zero and never negative, and an unusable
    ///   source (no allocation, unreconciled shares, a card that is gone or
    ///   non-finite) returns zero rather than a guess. Zero here means "do not
    ///   let a new plan be written against this card", which is the safe
    ///   reading for a store that cannot verify what is there.
    ///
    /// This is a pure read: no account is selected, nothing is persisted, and
    /// the ledger and allocation are left exactly as they were.
    func availableSalePlanQuantity(for portionID: UUID, excludingPlanID: UUID? = nil) -> Double {
        guard supportsPosition,
              positionQuantity.isFinite, positionQuantity > 0,
              let allocation = positionAllocation,
              !positionAllocationNeedsReconciliation else { return 0 }
        guard let portion = allocation.portions.first(where: { $0.id == portionID }),
              portion.quantity.isFinite, portion.quantity > 0 else { return 0 }

        var claimed = 0.0
        for plan in plans where plan.kind == .sell
            && plan.status == .active
            && plan.id != excludingPlanID
            && plan.positionPortionID == portionID {
            let remaining = TradePlanExecutionProgress(plan: plan, transactions: transactions).remainingQuantity
            guard remaining.isFinite, remaining > 0 else { continue }
            let next = claimed + remaining
            claimed = next.isFinite ? next : .greatestFiniteMagnitude
        }
        let tolerance = PositionAllocation.quantityTolerance(portion.quantity, claimed)
        let available = portion.quantity - claimed
        return available > tolerance ? available : 0
    }
}
