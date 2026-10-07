import SwiftUI
import PulseCore

/// Account switches keep the form mounted. Its source stays visible and the
/// user can return to that ledger without re-entering any fields.
struct AccountDraftNotice: View {
    @Environment(AppState.self) private var appState
    let account: BrokerageAccountID

    var body: some View {
        if appState.watchlist.activeBrokerageAccountID != account {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(PulseLocalization.localizedString("draft.account.kept", AccountIdentity.title(account)),
                      systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(PulseLocalization.localizedString("draft.account.resume", AccountIdentity.title(account))) {
                    _ = appState.selectBrokerageAccount(account)
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
            .controlSize(.small)
        }
    }
}

extension WatchlistStore {
    /// A pure read of the draft's ledger; account selection is never changed
    /// merely to keep an editor visible.
    func draftItem(for symbol: SymbolID, account: BrokerageAccountID) -> WatchItem? {
        let portfolio = brokeragePortfolio(for: account)
        return portfolio.items.first { $0.symbol == symbol }
            ?? portfolio.retainedHistoryItems.first { $0.symbol == symbol }
    }
}
