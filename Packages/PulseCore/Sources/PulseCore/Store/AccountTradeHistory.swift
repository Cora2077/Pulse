import Foundation

/// One replayed trade as it stands in the account that owns it.
///
/// A trade is displayed from the ledger it was recorded in — never replayed
/// across accounts. Two accounts hold two independent ledgers for the same
/// symbol, and their moving average costs, realized P&L, and running quantities
/// are only meaningful inside the ledger that produced them. Merging them to
/// "recompute" a combined position would invent a cost basis no account ever
/// had, so this type always carries the owning account's own entry verbatim.
public struct AccountTradeHistoryEntry: Identifiable, Sendable {
    /// Compound identity: a transaction's own `UUID` is only unique within the
    /// ledger that holds it. Two accounts may legitimately carry the same
    /// transaction id (a copied record, an imported or synced duplicate), so
    /// the account is part of the identity and the two never collapse into one
    /// row.
    public struct ID: Hashable, Sendable {
        public var accountID: BrokerageAccountID
        public var transactionID: UUID

        public init(accountID: BrokerageAccountID, transactionID: UUID) {
            self.accountID = accountID
            self.transactionID = transactionID
        }
    }

    /// The account whose ledger produced `entry`. `entry.realizedPnL`,
    /// `entry.resultingAverageCost`, and `entry.resultingQuantity` all belong to
    /// this account alone.
    public var accountID: BrokerageAccountID
    /// The transaction annotated with its outcome in `accountID`'s own ledger.
    public var entry: PositionLedger.Entry
    /// This entry's position in its own ledger's replay order. Unique within an
    /// account and the display tie-break just below the two timestamps; carried
    /// on the value because `PositionLedger.Entry` has no back-pointer to the
    /// ledger it came from.
    public var ledgerIndex: Int

    public init(accountID: BrokerageAccountID, entry: PositionLedger.Entry, ledgerIndex: Int) {
        self.accountID = accountID
        self.entry = entry
        self.ledgerIndex = ledgerIndex
    }

    public var id: ID { ID(accountID: accountID, transactionID: entry.transaction.id) }

    public var transaction: PositionTransaction { entry.transaction }
}

/// Cross-account trade display: reads every enabled account's ledger for a
/// symbol and presents the trades newest-first, without changing the selected
/// account or writing anything.
@MainActor
public extension WatchlistStore {
    /// Every visible trade for `symbol`, newest first.
    ///
    /// Accounts are read, never switched: `brokeragePortfolio(for:)` answers
    /// with each account's own portfolio (the active one from live state, the
    /// rest from their stored copies), so a caller on any account sees the same
    /// union and the selected ledger is left exactly as it was. With brokerage
    /// accounts disabled there is a single active ledger and that is all this
    /// reports.
    func tradeHistory(for symbol: SymbolID) -> [AccountTradeHistoryEntry] {
        let accounts = brokerageAccountsEnabled
            ? BrokerageAccountID.allCases
            : [activeBrokerageAccountID]

        var result: [AccountTradeHistoryEntry] = []
        for account in accounts {
            let portfolio = brokeragePortfolio(for: account)
            // One item per account per symbol. A symbol lives in `items` while
            // it is watched and in `retainedHistoryItems` once it is removed but
            // its history is kept; a well-formed snapshot holds it in one or the
            // other, and preferring `items` here means a duplicate across the two
            // lists still contributes its trades only once.
            let item = portfolio.items.first { $0.symbol == symbol }
                ?? portfolio.retainedHistoryItems.first { $0.symbol == symbol }
            guard let ledger = item?.ledger else { continue }
            for (index, entry) in ledger.entries.enumerated() {
                result.append(AccountTradeHistoryEntry(
                    accountID: account, entry: entry, ledgerIndex: index
                ))
            }
        }
        return result.sorted(by: Self.tradeHistoryIsNewerFirst)
    }

    /// Trades for `symbol` in display order, flattened for the daily-candle
    /// markers. `CandleTradeMarker` re-groups them by side and day, so this is
    /// the whole cross-account set with no per-account filtering of its own.
    func transactionsForDisplay(_ symbol: SymbolID) -> [PositionTransaction] {
        tradeHistory(for: symbol).map(\.transaction)
    }

    /// Newest first: trade day, then insertion order, then the entry's position
    /// in its own ledger, then the account as a stable final tie-break.
    ///
    /// The day is compared as a calendar day in the user's zone, the same way
    /// `PositionLedger.replayOrdered` orders a ledger, so a trade entered at
    /// local midnight and a calibration made that morning land on the day the
    /// user sees rather than on whichever instant is numerically larger.
    ///
    /// The ledger index is inverted relative to replay order on purpose: the
    /// same entry that replays last is the most recent event in its account, and
    /// a reader scanning the list expects the latest trade on top. It is unique
    /// within an account, so an exact tie on both timestamps and index can only
    /// come from two different accounts — which is what the final `accountID`
    /// comparison settles, deterministically and independent of the order the
    /// accounts happened to be visited in.
    private static func tradeHistoryIsNewerFirst(
        _ lhs: AccountTradeHistoryEntry,
        _ rhs: AccountTradeHistoryEntry
    ) -> Bool {
        let calendar = Calendar.current
        let lhsDay = calendar.startOfDay(for: lhs.transaction.date)
        let rhsDay = calendar.startOfDay(for: rhs.transaction.date)
        if lhsDay != rhsDay { return lhsDay > rhsDay }

        if lhs.transaction.createdAt != rhs.transaction.createdAt {
            return lhs.transaction.createdAt > rhs.transaction.createdAt
        }

        if lhs.ledgerIndex != rhs.ledgerIndex { return lhs.ledgerIndex > rhs.ledgerIndex }

        return lhs.accountID.rawValue < rhs.accountID.rawValue
    }
}
