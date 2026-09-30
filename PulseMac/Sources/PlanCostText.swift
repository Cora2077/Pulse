import Foundation
import PulseCore
import PulseUI

/// The money between a plan and the live quote, worded once for every surface
/// that shows it.
///
/// The menu-bar list, the detail page, and the main-window table all answer the
/// same question about the same plan, so they share one wording function rather
/// than three copies of the same four-way switch. The number comes from
/// `TradePlan.costDelta(from:)`; all that lives here is turning a tone into a
/// label and a `Double` into money.
enum PlanCostText {
    /// `nil` means there is nothing worth printing: the plan is settled rather
    /// than live, there is no quote, the plan has no size attached, or the
    /// quote sits exactly on the plan price.
    ///
    /// Settled plans are filtered here rather than at each call site, because
    /// "what this would cost at today's price" is a question only a plan you
    /// still mean to act on can answer.
    static func string(for plan: TradePlan, current: Double?, symbol: SymbolID) -> String? {
        guard plan.status == .active else { return nil }
        guard let current, let delta = plan.costDelta(from: current) else { return nil }
        let amount = PriceFormatter.money(delta.amount, currencyCode: symbol.currencyCode)
        return PulseLocalization.localizedString(key(for: delta.tone), amount)
    }

    /// Kept next to the string so the four tones and their keys cannot drift
    /// apart, and so a missing translation shows up as one key rather than as
    /// four call sites guessing.
    static func key(for tone: TradePlan.CostTone) -> String {
        switch tone {
        case .paysMore: "plan.cost.paysMore"
        case .paysLess: "plan.cost.paysLess"
        case .earnsLess: "plan.cost.earnsLess"
        case .earnsMore: "plan.cost.earnsMore"
        }
    }
}
