import Foundation

/// Ordering and visibility rules for the main window's persistent plan rail,
/// lifted out of the view so the rules are unit-testable. Pure functions:
/// the caller resolves the quote health and which tab is on screen.
public enum PlanRailOrdering {
    /// Waiting plans, reached-first then nearest to the current price.
    /// Without a usable price the order falls back to recency; ties break
    /// by id so the order is stable across re-renders.
    public static func sortedWaiting(
        _ entries: [TradePlanEntry],
        currentPrice: Double?,
        quoteIsCurrent: Bool
    ) -> [TradePlanEntry] {
        let waiting = entries.filter { $0.displayState == .waiting }
        guard let currentPrice, quoteIsCurrent, currentPrice.isFinite, currentPrice > 0 else {
            return waiting.sorted {
                if $0.plan.updatedAt != $1.plan.updatedAt { return $0.plan.updatedAt > $1.plan.updatedAt }
                return $0.plan.id.uuidString < $1.plan.id.uuidString
            }
        }
        return waiting.sorted { lhs, rhs in
            let lhsReached = lhs.plan.isReached(at: currentPrice)
            let rhsReached = rhs.plan.isReached(at: currentPrice)
            if lhsReached != rhsReached { return lhsReached }
            let lhsGap = abs(lhs.plan.price - currentPrice)
            let rhsGap = abs(rhs.plan.price - currentPrice)
            if lhsGap != rhsGap { return lhsGap < rhsGap }
            if lhs.plan.updatedAt != rhs.plan.updatedAt { return lhs.plan.updatedAt > rhs.plan.updatedAt }
            return lhs.plan.id.uuidString < rhs.plan.id.uuidString
        }
    }

    /// The rail appears only when the window can afford the column, the
    /// plans tab is not already showing the full list, and there is
    /// something waiting to show.
    public static func showsRail(width: CGFloat, plansTabActive: Bool, hasWaitingPlans: Bool) -> Bool {
        width >= 1120 && !plansTabActive && hasWaitingPlans
    }
}
