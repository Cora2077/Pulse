import Foundation
import PulseCore

/// The money between a plan and the live quote, worded once for every surface
/// that shows it.
///
/// The menu-bar list, the detail page, the main-window table, and the chart tag
/// all answer the same question about the same plan, so they share one wording
/// function rather than four copies of the same four-way switch. The number
/// comes from `TradePlan.costDelta(from:)`; the words come from the tone's own
/// `localizationKey`, so a tone cannot reach a surface without its translation.
///
/// The figure and its wording are kept apart so the arithmetic stays testable:
/// a test bundle ships no `.strings` table, so anything that can only be
/// observed through the rendered sentence cannot really be checked.
public enum PlanCostText {
    /// A figure and the direction it cuts. `amount` is always a magnitude.
    public struct Summary: Equatable, Sendable {
        public let amount: Double
        public let tone: TradePlan.CostTone

        public init(amount: Double, tone: TradePlan.CostTone) {
            self.amount = amount
            self.tone = tone
        }

        /// The sentence shown to the reader, in the reader's language.
        ///
        /// The warning directions name the action at the live quote in front of
        /// the figure — "现价买入 多花 ¥2,696.00" — so the reader is told what
        /// the number means for the trade they would place, not just that it
        /// moved. The action is a sentence of its own and is composed here
        /// rather than baked into each table value, so the direction rule stays
        /// in `CostTone` where the other three surfaces can see it.
        public func text(currencyCode: String?) -> String {
            let figure = PriceFormatter.money(amount, currencyCode: currencyCode)
            let sentence = PulseLocalization.localizedString(tone.localizationKey, figure)
            guard let actionKey = tone.actionKey else { return sentence }
            return PulseLocalization.localizedString(actionKey, sentence)
        }
    }

    /// `nil` means there is nothing worth printing: the plan is settled rather
    /// than live, there is no quote, the plan has no size attached, or the
    /// quote sits exactly on the plan price.
    ///
    /// Settled plans are filtered here rather than at each call site, because
    /// "what this would cost at today's price" is a question only a plan you
    /// still mean to act on can answer.
    public static func summary(for plan: TradePlan, current: Double?) -> Summary? {
        guard plan.status == .active else { return nil }
        guard let current, let delta = plan.costDelta(from: current) else { return nil }
        return Summary(amount: delta.amount, tone: delta.tone)
    }

    /// The same figure for a whole group of plans sharing one kind and price.
    ///
    /// The chart stacks those into a single tag, so the tag has to answer for
    /// all of them. The live plans are priced one by one and the results added,
    /// which is the same number as pricing the combined size once, without
    /// depending on a single representative price staying in step with the rest.
    public static func summary(for plans: [TradePlan], current: Double?) -> Summary? {
        var amount = 0.0
        var tone: TradePlan.CostTone?
        for plan in plans {
            guard let part = summary(for: plan, current: current) else { continue }
            amount += part.amount
            tone = part.tone
        }
        guard let tone, amount > 0, amount.isFinite else { return nil }
        return Summary(amount: amount, tone: tone)
    }

    public static func string(for plan: TradePlan, current: Double?, currencyCode: String?) -> String? {
        summary(for: plan, current: current)?.text(currencyCode: currencyCode)
    }

    public static func string(for plans: [TradePlan], current: Double?,
                              currencyCode: String?) -> (text: String, tone: TradePlan.CostTone)? {
        guard let summary = summary(for: plans, current: current) else { return nil }
        return (summary.text(currencyCode: currencyCode), summary.tone)
    }
}
