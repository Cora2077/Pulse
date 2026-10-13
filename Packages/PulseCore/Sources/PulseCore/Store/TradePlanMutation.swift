import Foundation

/// Pure plan candidate construction; the store remains the sole publisher of
/// accounts, persistence, and sync notifications. Migration is supplied by the
/// store's shared migration contract, not repeated here.
enum TradePlanMutation {
    static func setting(_ plan: TradePlan, on item: WatchItem,
                        migrate: (TradePlan) -> TradePlan) -> WatchItem? {
        guard item.supportsPosition else { return nil }
        var plans = item.plans
        let existing = plans.firstIndex { $0.id == plan.id }
        let stored = existing.map { plans[$0] }
        let old = stored.map(migrate)
        var incoming = migrate(plan)
        incoming.note = normalizedNote(plan.note)
        if let conditions = incoming.conditions {
            let normalized = conditions.compactMap { $0.normalized() }
            guard normalized.count == conditions.count,
                  Set(normalized.map(\.id)).count == normalized.count else { return nil }
            incoming.conditions = normalized
        }
        guard incoming.hasValidPayload,
              validBinding(incoming, on: item, plans: plans, existing: existing) else { return nil }
        if let existing, let stored, let old {
            incoming.createdAt = old.createdAt
            incoming.filledTransactionID = incoming.filledTransactionID ?? old.filledTransactionID
            incoming.conditions = incoming.conditions ?? old.conditions
            incoming.history = old.history
            let priorConfiguration = TradePlanConfiguration(plan: old)
            let configurationChanged = priorConfiguration != TradePlanConfiguration(plan: incoming)
            let linkChanged = incoming.filledTransactionID != old.filledTransactionID
            guard configurationChanged || linkChanged || stored != old else { return item }
            if configurationChanged {
                incoming.history = (old.history ?? []) + [TradePlanRevision(configuration: priorConfiguration)]
            }
            incoming.updatedAt = .now
            plans[existing] = incoming
        } else {
            incoming.history = plan.positionPool == .observation ? incoming.history.map { Array($0.suffix(1)) } : nil
            incoming.updatedAt = .now
            plans.append(incoming)
        }
        var result = item
        result.plans = TradePlan.ordered(plans)
        return result
    }

    static func normalizedNote(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Settled bindings remain history. An active bound sale must fit the live
    /// card after excluding its own prior claim and subtracting linked fills.
    private static func validBinding(_ incoming: TradePlan, on item: WatchItem,
                                     plans: [TradePlan], existing: Int?) -> Bool {
        guard incoming.status == .active, let portionID = incoming.positionPortionID else { return true }
        guard item.salePlanSource(for: incoming) != nil else { return false }
        var candidate = item
        candidate.plans = plans
        if let existing { candidate.plans[existing] = incoming }
        else { candidate.plans.append(incoming) }
        let remaining = TradePlanExecutionProgress(plan: incoming, transactions: candidate.transactions).remainingQuantity
        guard remaining.isFinite, remaining > 0 else { return true }
        let available = candidate.availableSalePlanQuantity(for: portionID, excludingPlanID: incoming.id)
        return remaining <= available + PositionAllocation.quantityTolerance(remaining, available)
    }
}
