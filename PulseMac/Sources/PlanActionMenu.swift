import SwiftUI
import PulseCore

extension TradePlanAction {
    var titleKey: String {
        switch self {
        case .recordFill: "plans.action.recordFill"
        case .backfill: "plans.action.backfill"
        case .edit: "plan.menu.edit"
        case .history: "plans.action.logicHistory"
        case .snooze: "plans.action.snooze"
        case .abandon: "plan.menu.drop"
        case .revive: "plan.menu.revive"
        case .delete: "plan.delete"
        }
    }
}

/// The only plan-menu action routing. Menus carry a source identity rather than
/// inventing permissions from the current toolbar account. Status/snooze do not
/// switch accounts. Modal drafts select their named source once, then retain the
/// existing guard against a later account switch.
@MainActor
enum PlanActionRouting {
    static func source(_ entry: TradePlanEntry, in state: AppState) throws -> BrokerageAccountID {
        guard let account = entry.accountID,
              state.watchlist.brokerageAccountsEnabled || account == .unassigned else {
            throw TradeMutationError.accountUnavailable
        }
        let portfolio = state.watchlist.brokeragePortfolio(for: account)
        guard let live = (portfolio.items + portfolio.retainedHistoryItems).first(where: { $0.symbol == entry.symbol })?
            .plans.first(where: { $0.id == entry.plan.id }), live == entry.plan else { throw TradePlanExecutionError.stalePlan }
        return account
    }

    static func selectSource(_ entry: TradePlanEntry, in state: AppState) throws {
        let account = try source(entry, in: state)
        if state.watchlist.activeBrokerageAccountID != account {
            guard state.selectBrokerageAccount(account), state.watchlist.activeBrokerageAccountID == account else {
                throw TradeMutationError.accountUnavailable
            }
        }
    }

    static func perform(_ action: TradePlanAction, entry: TradePlanEntry, in state: AppState,
                        present: (TradePlanAction) -> Void) throws {
        guard TradePlanAction.available(for: entry).contains(action) else { throw TradePlanExecutionError.stalePlan }
        let account = try source(entry, in: state)
        switch action {
        case .abandon: _ = try state.watchlist.changeTradePlanStatus(entry, to: .cancelled)
        case .revive: _ = try state.watchlist.changeTradePlanStatus(entry, to: .active)
        case .snooze: state.planAlerts.snooze(entry.plan, account: account)
        case .recordFill, .backfill, .edit, .history, .delete:
            try selectSource(entry, in: state)
            present(action)
        }
    }
}

/// Shared contents for compact list, table, and instrument-page menus.
struct PlanActionMenu: View {
    @Environment(AppState.self) private var appState
    let entry: TradePlanEntry
    let onPresent: (TradePlanAction) -> Void
    let onError: (String) -> Void

    var body: some View {
        if let account = entry.accountID {
            Text(AccountIdentity.title(account))
        }
        ForEach(TradePlanAction.available(for: entry)) { action in
            Button(role: action == .delete ? .destructive : nil) {
                do { try PlanActionRouting.perform(action, entry: entry, in: appState, present: onPresent) }
                catch { onError(error.localizedDescription) }
            } label: {
                Text(PulseLocalization.localizedString(action.titleKey))
            }
            .accessibilityIdentifier("plan.action.\(entry.id.uuidString).\(action.rawValue)")
        }
    }
}
