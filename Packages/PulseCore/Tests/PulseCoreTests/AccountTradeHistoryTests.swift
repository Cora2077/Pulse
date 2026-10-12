import Foundation
import Testing
@testable import PulseCore

/// Read-only cross-account trade display.
///
/// The point of these tests is that a ledger is never re-derived across
/// accounts: each account's entries are shown exactly as that account replayed
/// them, and the union is a presentation over the accounts rather than a
/// combined position. All data here is invented.
@MainActor @Suite("Account trade history")
struct AccountTradeHistoryTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private func makeStore() throws -> (store: WatchlistStore, defaults: UserDefaults, suite: String) {
        let suite = "Pulse.AccountTradeHistory.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        return (store, defaults, suite)
    }

    /// Dates are built in the user's own calendar, which is the calendar the
    /// display order reads.
    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 0) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour
        )))
    }

    private func buy(_ price: Double, _ quantity: Double, date: Date, createdAt: Date,
                     account: BrokerageAccountID? = nil,
                     id: UUID = UUID()) -> PositionTransaction {
        PositionTransaction(
            id: id, kind: .buy, price: price, quantity: quantity,
            date: date, createdAt: createdAt, brokerageAccountID: account
        )
    }

    // MARK: - Cross-account plan fills

    @Test("A plan filled into another account shows the same trade from every selected account")
    func crossAccountFillIsVisibleFromEveryAccount() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.withBrokerageAccount(.financing) { store.add(SymbolInfo(symbol: symbol, name: "Apple")) }

        let tradeDate = try day(2026, 8, 11)
        // The plan is written in the unassigned source; the fill it produces is
        // bought with margin in financing.
        let target = TradePlan(kind: .buy, price: 100, quantity: 40, positionPool: .tactical,
                               fundingSource: .margin)
        #expect(store.setTradePlan(target, for: symbol))
        try store.recordTradePlanFill(
            symbol: symbol, planID: target.id, price: 100, quantity: 40,
            date: tradeDate, fee: nil, note: nil,
            fundingSource: .margin, brokerageAccountID: .financing
        )

        // From each account the same single fill is visible, and it is the same
        // trade — not a copy reread into whichever ledger is selected.
        for account in BrokerageAccountID.allCases {
            _ = store.selectBrokerageAccount(account)
            let baseline = store.syncSnapshot()
            let history = store.tradeHistory(for: symbol)
            #expect(store.activeBrokerageAccountID == account)
            #expect(store.syncSnapshot() == baseline)
            #expect(history.count == 1, "the cross-account fill shows once from \(account.rawValue)")
            let entry = try #require(history.first)
            #expect(entry.accountID == .financing)
            #expect(entry.transaction.quantity == 40)
            #expect(entry.transaction.fundingSource == .margin)
            #expect(entry.transaction.planExecution?.sourceAccountID == .unassigned)
            #expect(entry.entry.resultingQuantity == 40)
            #expect(entry.entry.resultingAverageCost == 100)
        }
    }

    @Test("A cross-account fill marks the daily candle as a buy")
    func crossAccountFillProducesCandleMarker() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.withBrokerageAccount(.financing) { store.add(SymbolInfo(symbol: symbol, name: "Apple")) }

        let tradeDate = try day(2026, 8, 11)
        let target = TradePlan(kind: .buy, price: 100, quantity: 25, positionPool: .tactical,
                               fundingSource: .margin)
        #expect(store.setTradePlan(target, for: symbol))
        try store.recordTradePlanFill(
            symbol: symbol, planID: target.id, price: 102, quantity: 25,
            date: tradeDate, fee: nil, note: nil,
            fundingSource: .margin, brokerageAccountID: .financing
        )

        let transactions = store.transactionsForDisplay(symbol)
        #expect(transactions.count == 1)

        let candleDay = try day(2026, 8, 11, hour: 9)
        let candles = [Candle(time: candleDay, open: 100, high: 105, low: 99, close: 104)]
        let markers = CandleTradeMarker.dailyMarkers(
            candles: candles, transactions: transactions, market: .us
        )

        let marker = try #require(markers.first)
        #expect(markers.count == 1)
        #expect(marker.side == .buy)
        #expect(marker.candleIndex == 0)
        #expect(marker.totalQuantity == 25)
        #expect(marker.averagePrice == 102)
    }

    // MARK: - Ledgers stay separate

    @Test("Three accounts' trades are all visible and each keeps its own realized P&L")
    func realizedPnLComesFromEachOwnLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        // Three independent ledgers for one symbol, each with its own entry and
        // its own realized result. The numbers are chosen so a merged replay
        // would produce a visibly different answer than any of them.
        let bought = try day(2026, 8, 10)
        let sold = try day(2026, 8, 12)

        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 10, date: bought, createdAt: bought))
        store.addTransaction(symbol, PositionTransaction(
            kind: .sell, price: 110, quantity: 10, date: sold, createdAt: sold
        ))

        store.withBrokerageAccount(.financing) {
            store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            store.addTransaction(symbol, buy(200, 2, date: bought, createdAt: bought))
            store.addTransaction(symbol, PositionTransaction(
                kind: .sell, price: 190, quantity: 2, date: sold, createdAt: sold
            ))
        }
        store.withBrokerageAccount(.mengmeng) {
            store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            store.addTransaction(symbol, buy(50, 4, date: bought, createdAt: bought))
            store.addTransaction(symbol, PositionTransaction(
                kind: .sell, price: 65, quantity: 4, date: sold, createdAt: sold
            ))
        }

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 6, "every account's two trades are visible")

        // The unassigned ledger: 10 bought at 100, 10 sold at 110 → +100.
        let unassigned = history.filter { $0.accountID == .unassigned }
        #expect(unassigned.count == 2)
        let unassignedSell = try #require(unassigned.first { $0.transaction.kind == .sell })
        #expect(unassignedSell.entry.realizedPnL == 100)

        // Financing: 2 bought at 200, 2 sold at 190 → a 20 loss, not the gain
        // the first account made.
        let financing = history.filter { $0.accountID == .financing }
        #expect(financing.count == 2)
        let financingSell = try #require(financing.first { $0.transaction.kind == .sell })
        #expect(financingSell.entry.realizedPnL == -20)

        // Mengmeng: 4 bought at 50, 4 sold at 65 → +60.
        let mengmeng = history.filter { $0.accountID == .mengmeng }
        #expect(mengmeng.count == 2)
        let mengmengSell = try #require(mengmeng.first { $0.transaction.kind == .sell })
        #expect(mengmengSell.entry.realizedPnL == 60)

        // A cross-account replay would blend the three cost bases into one; the
        // three results above are each the owning account's own number.
        #expect(unassignedSell.entry.realizedPnL != financingSell.entry.realizedPnL)
        #expect(mengmengSell.entry.resultingAverageCost == 0, "each ledger is its own replay")
    }

    // MARK: - Retained history and disabled accounts

    @Test("A retained-history symbol stays visible after it leaves every watchlist")
    func retainedHistorySymbolIsVisible() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))

        let tradeDate = try day(2026, 8, 11)
        store.addTransaction(symbol, buy(100, 7, date: tradeDate, createdAt: tradeDate))
        #expect(store.tradeHistory(for: symbol).count == 1)

        // Removing it from the watchlist retains the ledger rather than the row.
        store.remove(symbol)
        #expect(store.item(for: symbol) == nil)
        #expect(store.retainedHistoryItem(for: symbol) != nil)

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 1, "retained history is still displayed")
        let entry = try #require(history.first)
        #expect(entry.accountID == .unassigned)
        #expect(entry.transaction.quantity == 7)
    }

    @Test("With brokerage accounts disabled only the active ledger is reported")
    func disabledAccountsReportOnlyTheActiveLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Brokerage accounts are never enabled, so there is a single ledger and
        // no per-account duplication is possible.
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let tradeDate = try day(2026, 8, 11)
        store.addTransaction(symbol, buy(100, 3, date: tradeDate, createdAt: tradeDate))

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 1)
        #expect(history.first?.accountID == .unassigned)
        #expect(store.transactionsForDisplay(symbol).count == 1)
    }

    @Test("A symbol tracked in both items and retained history contributes its trades once")
    func duplicateListsDoNotDoubleCount() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))

        let tradeDate = try day(2026, 8, 11)
        store.addTransaction(symbol, buy(100, 5, date: tradeDate, createdAt: tradeDate))

        // Only one item exists for the symbol in this account, so exactly one
        // entry is produced — the "one item per account per symbol" rule.
        #expect(store.brokeragePortfolio(for: .unassigned).items.count == 1)
        #expect(store.tradeHistory(for: symbol).count == 1)
    }

    // MARK: - Compound identity

    @Test("The same transaction UUID in two ledgers yields two distinct entries")
    func sharedUUIDAcrossLedgersDoesNotCollide() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        // The same UUID written independently into two accounts: a copied or
        // imported record. Identity must include the account.
        let sharedID = UUID()
        let tradeDate = try day(2026, 8, 11)

        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 10, date: tradeDate, createdAt: tradeDate, id: sharedID))
        store.withBrokerageAccount(.financing) {
            store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            store.addTransaction(symbol, buy(200, 20, date: tradeDate, createdAt: tradeDate, id: sharedID))
        }

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 2, "the shared UUID must not collapse two ledger rows into one")
        #expect(Set(history.map(\.id)).count == 2, "compound ids stay distinct")
        #expect(Set(history.map(\.transaction.id)) == [sharedID], "both really do share one transaction id")

        let unassigned = try #require(history.first { $0.accountID == .unassigned })
        let financing = try #require(history.first { $0.accountID == .financing })
        #expect(unassigned.id != financing.id)
        #expect(unassigned.id.accountID == .unassigned)
        #expect(financing.id.accountID == .financing)
        // Each row still reports its own ledger's quantity.
        #expect(unassigned.entry.resultingQuantity == 10)
        #expect(financing.entry.resultingQuantity == 20)
    }

    // MARK: - Read-only and stable ordering

    @Test("Reading the history changes neither the selected account nor the snapshot")
    func readingDoesNotSelectAnAccountOrWrite() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        let tradeDate = try day(2026, 8, 11)
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 10, date: tradeDate, createdAt: tradeDate))
        store.withBrokerageAccount(.financing) {
            store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            store.addTransaction(symbol, buy(200, 1, date: tradeDate, createdAt: tradeDate))
        }

        // Sit on .mengmeng, which holds nothing, then read across every account.
        #expect(store.selectBrokerageAccount(.mengmeng))
        let activeBefore = store.activeBrokerageAccountID
        let snapshotBefore = store.syncSnapshot()
        let storedBefore = defaults.data(forKey: "pulse.watchlists.v4")

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 2, "the union is read from every account, not just the active one")
        #expect(store.activeBrokerageAccountID == activeBefore)
        #expect(store.activeBrokerageAccountID == .mengmeng)
        #expect(store.syncSnapshot() == snapshotBefore, "a read must not mutate any ledger")
        #expect(defaults.data(forKey: "pulse.watchlists.v4") == storedBefore, "a read must not write to disk")
    }

    @Test("Ordering is newest-first by day, then createdAt, then ledger index")
    func stableNewestFirstOrdering() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        let older = try day(2026, 8, 10)
        let newer = try day(2026, 8, 12)
        // Two trades on the same day, separated only by insertion order.
        let sameDayEarly = try day(2026, 8, 11, hour: 9)
        let sameDayLate = try day(2026, 8, 11, hour: 15)

        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 1, date: older, createdAt: older))
        store.addTransaction(symbol, buy(101, 2, date: sameDayEarly, createdAt: sameDayEarly))
        store.addTransaction(symbol, buy(102, 3, date: sameDayLate, createdAt: sameDayLate))
        store.addTransaction(symbol, buy(103, 4, date: newer, createdAt: newer))

        let history = store.tradeHistory(for: symbol)
        #expect(history.map(\.transaction.quantity) == [4, 3, 2, 1],
                "newest day first, and same-day trades by insertion order, both descending")

        // The order is a pure function of the data: re-reading gives the same
        // answer, so nothing about the account visit order leaks into it.
        #expect(store.tradeHistory(for: symbol).map(\.id) == history.map(\.id))
        #expect(store.transactionsForDisplay(symbol).map(\.quantity) == [4, 3, 2, 1])
    }

    @Test("Same-day trades at the same instant fall back to the ledger index")
    func identicalTimestampsUseLedgerIndex() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        // Daily trades are dated at local midnight, so same-day entries really
        // do share both timestamps; replay order then decides.
        let tradeDate = try day(2026, 8, 11)
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 1, date: tradeDate, createdAt: tradeDate))
        store.addTransaction(symbol, buy(101, 2, date: tradeDate, createdAt: tradeDate))
        store.addTransaction(symbol, buy(102, 3, date: tradeDate, createdAt: tradeDate))

        let history = store.tradeHistory(for: symbol)
        #expect(history.map(\.transaction.quantity) == [3, 2, 1],
                "the entry that replays last is the most recent event and sorts on top")
        #expect(history.map(\.ledgerIndex) == [2, 1, 0])
    }

    @Test("An exact tie across two accounts resolves by account id, not visit order")
    func crossAccountTieBreaksOnAccountID() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.enableBrokerageAccounts()

        // Identical day, identical createdAt, and each is the only entry in its
        // own ledger — so both carry ledger index 0 and only the account can
        // separate them.
        let tradeDate = try day(2026, 8, 11)
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        store.addTransaction(symbol, buy(100, 1, date: tradeDate, createdAt: tradeDate))
        store.withBrokerageAccount(.financing) {
            store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            store.addTransaction(symbol, buy(100, 1, date: tradeDate, createdAt: tradeDate))
        }

        let history = store.tradeHistory(for: symbol)
        #expect(history.count == 2)
        #expect(history.map(\.ledgerIndex) == [0, 0], "both are the sole entry of their ledger")
        #expect(history.map(\.accountID.rawValue) == ["financing", "unassigned"],
                "the stable account-id tie-break is ascending")
    }
}
