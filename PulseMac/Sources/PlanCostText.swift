import Foundation
import PulseCore
import PulseUI

/// The money between a plan and the live quote, for the app's plan surfaces.
///
/// The wording itself lives in `PulseUI.PlanCostText` so the chart tag and
/// these list rows cannot drift apart. What stays here is the symbol-shaped
/// call these three surfaces already had: they hold a `SymbolID` and it is the
/// symbol that knows the currency, so the lookups are resolved once here rather
/// than repeated at every call site.
enum PlanCostText {
    static func string(for plan: TradePlan, current: Double?, symbol: SymbolID) -> String? {
        PulseUI.PlanCostText.string(for: plan, current: current, currencyCode: symbol.currencyCode)
    }

    static func string(for plans: [TradePlan], current: Double?,
                       symbol: SymbolID) -> (text: String, tone: TradePlan.CostTone)? {
        PulseUI.PlanCostText.string(for: plans, current: current, currencyCode: symbol.currencyCode)
    }
}
