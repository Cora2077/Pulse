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
    static func entries(store: WatchlistStore) -> [TradePlanEntry] {
        records(store: store).flatMap { record in
            record.item.plans.map { plan in
                TradePlanEntry(
                    symbol: record.item.symbol,
                    plan: plan,
                    transactions: store.transactionsForPlan(record.item.symbol, account: record.accountID),
                    accountID: record.accountID
                )
            }
        }
    }
}
