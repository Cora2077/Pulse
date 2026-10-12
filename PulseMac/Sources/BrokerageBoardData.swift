import Foundation
import PulseCore

/// One instrument as seen from one brokerage ledger.
///
/// The same symbol can be held and planned in two accounts at once, so a bare
/// `WatchItem` cannot say where its position was labelled. The board carries the
/// ledger it came out of beside the item, which is exactly the `enclosingAccountID`
/// a portion with no label of its own inherits.
struct BrokerageBoardItem {
    let accountID: BrokerageAccountID
    let item: WatchItem
}

/// Collects the cross-account board without touching selection or storage.
///
/// A read-only projection: it never switches `activeBrokerageAccountID`, never
/// writes a portfolio back, and derives everything on every call so nothing here
/// can feed a sync round.
@MainActor
enum BrokerageBoardReader {
    /// Every record the board should see.
    ///
    /// With multiple ledgers turned on, all of them are read — each item keeps
    /// the id of the ledger it came from. With them off there is only the active
    /// ledger, and asking for `.allCases` would repeat the same portfolio under
    /// ids it does not belong to.
    static func records(store: WatchlistStore) -> [BrokerageBoardItem] {
        let owners: [BrokerageAccountID] = store.brokerageAccountsEnabled
            ? BrokerageAccountID.allCases
            : [store.activeBrokerageAccountID]
        return owners.flatMap { owner in
            let portfolio = store.brokeragePortfolio(for: owner)
            return (portfolio.items + portfolio.retainedHistoryItems)
                .map { BrokerageBoardItem(accountID: owner, item: $0) }
        }
    }

    /// The same records flattened to plans, each tagged with the ledger that
    /// owns it so an account-scoped overview can keep a plan on the ledger it
    /// was written in.
    ///
    /// The transaction query is per plan and names the ledger the *plan* was
    /// found in, not the ledger that happens to be selected. A plan stored in
    /// the pending-history ledger therefore reads its own fills there instead
    /// of borrowing the active ledger's copy of the same symbol, which is what
    /// keeps two same-symbol plans in two ledgers from sharing one another's
    /// progress.
    static func entries(store: WatchlistStore) -> [TradePlanEntry] {
        records(store: store).flatMap { record in
            record.item.plans.map { plan in
                TradePlanEntry(
                    symbol: record.item.symbol,
                    plan: plan,
                    transactions: store.transactionsForPlan(
                        record.item.symbol, account: record.accountID, planID: plan.id
                    ),
                    accountID: record.accountID
                )
            }
        }
    }

    /// Every plan in every ledger, including the ones nobody has filled yet.
    ///
    /// This is the cross-account board, so it does not narrow itself to the
    /// selected ledger and it does not narrow itself to plans with fills. A
    /// plan written into a ledger the user is not currently standing in is
    /// still the user's plan, and hiding it was what made the account label on
    /// a card look like an ownership decision it never was. The board shows all
    /// of them, each on its real entry.
    ///
    /// Identity is the entry's `id`, which is the plan id for an unassigned row
    /// and the account-qualified id otherwise. Two ledgers holding the same
    /// plan id are two rows here — they are two independent records that happen
    /// to share a UUID, and collapsing them would silently drop one ledger's
    /// plan. Deduplication is by that real id alone, and because every ledger
    /// is read exactly once by `records(store:)`, no record can be visited
    /// twice and no row is duplicated.
    ///
    /// Everything here is a pure read. No account is selected, no portfolio is
    /// written back, and the `accountID` each entry carries is the ledger the
    /// plan was actually found in — which is exactly what the callers that
    /// switch accounts before editing need. It is never the plan's default
    /// execution account: that is an intention and is read from
    /// `PlanExecutionAccountDisplay` where it is shown, never substituted for
    /// the real source a write has to be routed to.
    static func displayPlans(store: WatchlistStore, symbol: SymbolID? = nil) -> [TradePlanEntry] {
        let all = entries(store: store)
        var seen = Set<UUID>()
        return all
            .filter { symbol == nil || $0.symbol == symbol }
            .filter { seen.insert($0.id).inserted }
    }
}
