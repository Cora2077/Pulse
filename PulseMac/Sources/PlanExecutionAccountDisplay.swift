import SwiftUI
import PulseCore

/// Execution intent is distinct from the plan's storage namespace and actual fills.
enum PlanExecutionAccountDisplay {
    static func namedAccount(_ plan: TradePlan) -> BrokerageAccountID? {
        namedAccount(plan.executionAccountID)
    }
    static func namedAccount(_ account: BrokerageAccountID?) -> BrokerageAccountID? {
        guard let account, account != .unassigned else { return nil }
        return account
    }
    static var undecidedTitle: String { PulseLocalization.localizedString("plan.executionAccount.choose") }
    static func title(_ plan: TradePlan) -> String { title(plan.executionAccountID) }
    static func title(_ account: BrokerageAccountID?) -> String {
        guard let account = namedAccount(account) else { return undecidedTitle }
        return PulseLocalization.localizedString("plan.executionAccount.named", AccountIdentity.title(account))
    }
    static func value(_ plan: TradePlan) -> String { value(plan.executionAccountID) }
    static func value(_ account: BrokerageAccountID?) -> String {
        namedAccount(account).map(AccountIdentity.title) ?? undecidedTitle
    }
    static func isDecided(_ plan: TradePlan) -> Bool { namedAccount(plan) != nil }
    static func fillAccountTitle(_ accounts: [BrokerageAccountID]) -> String {
        PulseLocalization.localizedString("plan.fillAccount.named", accounts.map(AccountIdentity.title).joined(separator: "、"))
    }
}

extension TradePlanEntry {
    /// Read the owners of all counted fills, including legacy-only links. Same-id
    /// plans in different source ledgers remain separate through the core query.
    @MainActor
    func actualFillAccountText(store: WatchlistStore, symbol: SymbolID) -> String? {
        guard filledQuantity > 0 else { return nil }
        let ids = Set(store.transactionsForPlan(symbol, account: accountID, planID: plan.id).map(\.id))
        let owners = Set(store.tradeHistory(for: symbol).filter { ids.contains($0.transaction.id) }.map(\.accountID))
        guard !owners.isEmpty else { return nil }
        return PlanExecutionAccountDisplay.fillAccountTitle(BrokerageAccountID.allCases.filter(owners.contains))
    }
}
