import Foundation
import Testing
@testable import PulseCore

/// Named brokerage accounts: one stable store, several independent portfolios.
///
/// The store's public arrays always describe the *selected* account, so these
/// tests assert both what the user sees right now and what each account holds
/// once it is selected — a move that looks right while selected but loses the
/// other account's ledger is the failure this suite exists to catch.
@Suite("Brokerage account store")
struct BrokerageAccountStoreTests {
    private let apple = SymbolID(market: .us, code: "AAPL")

    @MainActor
    private func makeStore(
        _ label: String
    ) throws -> (store: WatchlistStore, defaults: UserDefaults, suite: String) {
        let suite = "BrokerageAccountStoreTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist"), defaults, suite)
    }

    /// A snapshot shaped like the pre-account payload, used to prove old data
    /// still loads and that nothing about it is guessed into a named account.
    private struct LegacySnapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        var retainedHistoryItems: [WatchItem]?
    }

    private func buy(
        _ id: UUID = UUID(),
        price: Double,
        quantity: Double,
        day: TimeInterval,
        fee: Double? = nil,
        fundingSource: PositionFundingSource? = nil
    ) -> PositionTransaction {
        PositionTransaction(
            id: id,
            kind: .buy,
            price: price,
            quantity: quantity,
            date: Date(timeIntervalSince1970: day),
            createdAt: Date(timeIntervalSince1970: day),
            fee: fee,
            fundingSource: fundingSource
        )
    }

    private func sell(
        _ id: UUID = UUID(),
        price: Double,
        quantity: Double,
        day: TimeInterval
    ) -> PositionTransaction {
        PositionTransaction(
            id: id,
            kind: .sell,
            price: price,
            quantity: quantity,
            date: Date(timeIntervalSince1970: day),
            createdAt: Date(timeIntervalSince1970: day)
        )
    }

    // MARK: - Opt-in and legacy data

    @MainActor
    @Test("A store without accounts behaves exactly as it did before the feature")
    func legacyStoreIsUnchanged() throws {
        let (store, defaults, suite) = try makeStore("legacy")
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.brokerageAccountsEnabled == false)
        #expect(store.activeBrokerageAccountID == .unassigned)

        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 3, day: 1_700_000_000))

        #expect(store.allItems.map(\.symbol) == [apple])
        #expect(store.item(for: apple)?.positionQuantity == 3)
        // Enabling is the user's decision: a snapshot written by the old store
        // never turns the feature on by itself.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        #expect(reloaded.brokerageAccountsEnabled == false)
        #expect(reloaded.syncSnapshot().brokerageAccounts == nil)
        #expect(reloaded.item(for: apple)?.positionQuantity == 3)
    }

    @MainActor
    @Test("Enabling seeds fixed named accounts empty and keeps legacy data unassigned")
    func enablingPreservesLegacyDataUnderUnassigned() throws {
        let (store, defaults, suite) = try makeStore("enable")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 3, day: 1_700_000_000))
        let retainedSymbol = SymbolID(market: .us, code: "MSFT")
        store.add(SymbolInfo(symbol: retainedSymbol, name: "Microsoft"))
        store.addTransaction(retainedSymbol, buy(price: 50, quantity: 1, day: 1_700_000_100))
        store.add(SymbolInfo(symbol: SymbolID(market: .hk, code: "700"), name: "Tencent"))
        store.remove(retainedSymbol)

        #expect(store.enableBrokerageAccounts())
        // Idempotent: a second call changes nothing.
        #expect(store.enableBrokerageAccounts() == false)

        #expect(store.brokerageAccountsEnabled)
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: apple)?.positionQuantity == 3)
        #expect(store.retainedHistoryItem(for: retainedSymbol)?.positionQuantity == 1)

        let financing = store.brokeragePortfolio(for: .financing)
        let mengmeng = store.brokeragePortfolio(for: .mengmeng)
        #expect(financing.accountID == .financing)
        #expect(mengmeng.accountID == .mengmeng)
        #expect(financing.items.isEmpty)
        #expect(mengmeng.items.isEmpty)
        // Each named account starts with one default list so it is immediately
        // usable rather than needing a group created first.
        #expect(financing.groups.count == 1)
        #expect(financing.groups.first?.name == "Watchlist")
        #expect(mengmeng.groups.count == 1)
        // The legacy data was not guessed into either named account.
        #expect(financing.items.contains { $0.symbol == apple } == false)
        #expect(mengmeng.items.contains { $0.symbol == apple } == false)
    }

    @MainActor
    @Test("The selected account and its named portfolios survive a reload")
    func optInSelectionAndPortfoliosReload() throws {
        let (store, defaults, suite) = try makeStore("reload")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 3, day: 1_700_000_000))
        store.enableBrokerageAccounts()
        #expect(store.selectBrokerageAccount(.mengmeng))
        store.add(SymbolInfo(symbol: SymbolID(market: .hk, code: "700"), name: "Tencent"))

        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        #expect(reloaded.brokerageAccountsEnabled)
        #expect(reloaded.activeBrokerageAccountID == .mengmeng)
        #expect(reloaded.allItems.map(\.symbol) == [SymbolID(market: .hk, code: "700")])

        #expect(reloaded.selectBrokerageAccount(.unassigned))
        #expect(reloaded.item(for: apple)?.positionQuantity == 3)
        #expect(reloaded.brokeragePortfolio(for: .mengmeng).items.map(\.symbol)
            == [SymbolID(market: .hk, code: "700")])
    }

    @MainActor
    @Test("A pre-account payload loads into unassigned with the feature off")
    func preAccountPayloadLoadsAsUnassigned() throws {
        let suite = "BrokerageAccountStoreTests.preaccount.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let group = WatchlistGroup(name: "Core", symbols: [apple])
        let legacyItem = WatchItem(
            symbol: apple,
            displayName: "Apple",
            transactions: [buy(price: 100, quantity: 2, day: 1_700_000_000)],
            thesis: "long term"
        )
        defaults.set(
            try JSONEncoder().encode(LegacySnapshot(
                items: [legacyItem],
                groups: [group],
                selectedGroupID: group.id,
                retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(store.brokerageAccountsEnabled == false)
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: apple)?.thesis == "long term")
        #expect(store.item(for: apple)?.positionQuantity == 2)
        // Nothing was invented about who owned it.
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    // MARK: - Independent ledgers

    @MainActor
    @Test("The same symbol keeps a separate ledger in each account")
    func sameSymbolHasIndependentLedgers() throws {
        let (store, defaults, suite) = try makeStore("independent")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()

        // Unassigned: two buys, then a plan.
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let unassignedFirst = UUID()
        store.addTransaction(apple, buy(unassignedFirst, price: 100, quantity: 2, day: 1_700_000_000))
        store.addTransaction(apple, buy(price: 110, quantity: 2, day: 1_700_086_400))
        let plan = TradePlan(kind: .buy, price: 90, quantity: 1)
        #expect(store.setTradePlan(plan, for: apple))
        store.setThesis("unassigned thesis", for: apple)
        #expect(store.item(for: apple)?.positionQuantity == 4)

        // Financing: one buy and a calibration.
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 1, day: 1_700_000_000))
        store.calibratePosition(apple, quantity: 7, averageCost: 210, date: Date(timeIntervalSince1970: 1_700_172_800))
        #expect(store.item(for: apple)?.positionQuantity == 7)
        #expect(store.item(for: apple)?.plans.isEmpty == true)
        #expect(store.item(for: apple)?.thesis == nil)

        // Mengmeng: a buy, a sell, and funding/pool annotations.
        #expect(store.selectBrokerageAccount(.mengmeng))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 300, quantity: 5, day: 1_700_000_000, fundingSource: .own))
        store.initializePositionAllocations()
        let portion = try #require(store.item(for: apple)?.positionAllocation?.portions.first)
        _ = try store.markPositionFundingSource(
            symbol: apple,
            portionID: portion.id,
            quantity: 2,
            source: .unmarked,
            reason: "split",
            expectedRevision: try #require(store.item(for: apple)?.positionAllocation?.revision)
        )
        store.addTransaction(apple, sell(price: 320, quantity: 1, day: 1_700_086_400))

        // Re-selecting the active account does not change it.
        #expect(store.selectBrokerageAccount(.mengmeng) == false)
        #expect(store.item(for: apple)?.positionQuantity == 4)
        #expect(store.item(for: apple)?.transactions.count == 2)
        #expect(store.item(for: apple)?.positionAllocation?.portions.count == 2)

        #expect(store.selectBrokerageAccount(.financing))
        #expect(store.item(for: apple)?.positionQuantity == 7)
        #expect(store.item(for: apple)?.transactions.count == 2)

        #expect(store.selectBrokerageAccount(.unassigned))
        #expect(store.item(for: apple)?.positionQuantity == 4)
        #expect(store.item(for: apple)?.transactions.first?.id == unassignedFirst)
        #expect(store.item(for: apple)?.plans.map(\.id) == [plan.id])
        #expect(store.item(for: apple)?.thesis == "unassigned thesis")

        // Every account is still present after a reload.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        #expect(reloaded.brokeragePortfolio(for: .unassigned).items.first?.positionQuantity == 4)
        #expect(reloaded.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 7)
        #expect(reloaded.brokeragePortfolio(for: .mengmeng).items.first?.positionQuantity == 4)
    }

    // MARK: - Selection is local

    @MainActor
    @Test("Switching accounts is local and never announces a sync change")
    func selectionDoesNotNotifySync() throws {
        let (store, defaults, suite) = try makeStore("selection")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))

        var notified: [WatchlistSyncSnapshot] = []
        store.onLocalSyncChange = { notified.append($0) }

        #expect(store.selectBrokerageAccount(.financing))
        #expect(store.selectBrokerageAccount(.mengmeng))
        #expect(store.selectBrokerageAccount(.unassigned))
        // Re-selecting the account already active is not a change at all.
        #expect(store.selectBrokerageAccount(.unassigned) == false)
        #expect(notified.isEmpty)

        // Looking at another account does not change what sync would publish,
        // and the published payload is still the unassigned portfolio.
        #expect(store.selectBrokerageAccount(.financing))
        let snapshot = store.syncSnapshot()
        #expect(snapshot.items.map(\.symbol) == [apple])
        #expect(snapshot.items.first?.positionQuantity == 1)
        #expect(snapshot.brokerageAccounts?.isEmpty == false)
        #expect(notified.isEmpty)

        // Start with an explicitly watched instrument in this empty account.
        store.onLocalSyncChange = nil
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.onLocalSyncChange = { notified.append($0) }
        // A real edit inside the selected account still notifies.
        store.addTransaction(apple, buy(price: 120, quantity: 1, day: 1_700_086_400))
        #expect(notified.count == 1)
        let announcement = try #require(notified.first)
        #expect(announcement.items.first?.positionQuantity == 1)
        #expect(announcement.brokerageAccounts?
            .first { $0.accountID == .financing }?.items.first?.positionQuantity == 1)
    }

    @MainActor
    @Test("A scoped operation restores the previous selection and array state")
    func scopedOperationRestoresSelection() throws {
        let (store, defaults, suite) = try makeStore("scope")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 2, day: 1_700_000_000))

        var notified: [WatchlistSyncSnapshot] = []
        store.onLocalSyncChange = { notified.append($0) }

        let observed = try store.withBrokerageAccount(.mengmeng) {
            #expect(store.activeBrokerageAccountID == .mengmeng)
            #expect(store.allItems.isEmpty)
            store.add(SymbolInfo(symbol: self.apple, name: "Apple"))
            store.addTransaction(self.apple, buy(price: 300, quantity: 1, day: 1_700_000_000))
            return store.item(for: self.apple)?.positionQuantity
        }
        #expect(observed == 1)

        // Back where the user was, with the arrays they were looking at.
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.allItems.map(\.symbol) == [apple])
        #expect(store.item(for: apple)?.positionQuantity == 2)
        // Adding the watchlist item and its first trade are two real edits.
        #expect(notified.count == 2)
        let announcement = try #require(notified.last)
        #expect(announcement.items.first?.positionQuantity == 2)
        #expect(announcement.brokerageAccounts?
            .first { $0.accountID == .mengmeng }?.items.first?.positionQuantity == 1)

        // Restoring the selection is persisted, not just in memory.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        #expect(reloaded.activeBrokerageAccountID == .unassigned)
        #expect(reloaded.brokeragePortfolio(for: .mengmeng).items.first?.positionQuantity == 1)
    }

    @MainActor
    @Test("A throwing scoped operation still restores the previous selection")
    func throwingScopeRestoresSelection() throws {
        let (store, defaults, suite) = try makeStore("scope-throw")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))

        struct ScopeFailure: Error {}
        #expect(throws: ScopeFailure.self) {
            try store.withBrokerageAccount(.financing) {
                #expect(store.activeBrokerageAccountID == .financing)
                throw ScopeFailure()
            }
        }
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.allItems.map(\.symbol) == [apple])
    }

    // MARK: - Sync and backups

    @MainActor
    @Test("A full snapshot carries every account, not just the selected one")
    func fullSnapshotIncludesInactiveAccounts() throws {
        let (store, defaults, suite) = try makeStore("snapshot")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        // Seed all three accounts, ending on unassigned.
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 2, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.mengmeng))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 300, quantity: 3, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        let snapshot = store.syncSnapshot()
        #expect(snapshot.items.first?.positionQuantity == 1)
        let accounts = try #require(snapshot.brokerageAccounts)
        #expect(accounts.map(\.accountID) == [.financing, .mengmeng])
        #expect(accounts.first { $0.accountID == .financing }?.items.first?.positionQuantity == 2)
        #expect(accounts.first { $0.accountID == .mengmeng }?.items.first?.positionQuantity == 3)

        // The snapshot is symmetric: applying it back reproduces every account.
        let (other, otherDefaults, otherSuite) = try makeStore("snapshot-target")
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        other.applySyncSnapshot(snapshot)
        #expect(other.brokeragePortfolio(for: .unassigned).items.first?.positionQuantity == 1)
        #expect(other.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 2)
        #expect(other.brokeragePortfolio(for: .mengmeng).items.first?.positionQuantity == 3)
    }

    @MainActor
    @Test("A canonical-only peer payload updates unassigned and keeps named accounts")
    func canonicalPeerUpdatePreservesNamedAccounts() throws {
        let (store, defaults, suite) = try makeStore("peer-canonical")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 2, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        // A peer that does not know about accounts sends only canonical data.
        let peerItem = WatchItem(
            symbol: apple,
            displayName: "Apple",
            transactions: [buy(price: 150, quantity: 4, day: 1_700_000_000)]
        )
        let peer = WatchlistSyncSnapshot(
            items: [peerItem],
            groups: store.groups,
            retainedHistoryItems: []
        )
        #expect(store.applySyncSnapshot(peer))
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: apple)?.positionQuantity == 4)
        // The account the peer never mentioned is untouched.
        #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 2)
        #expect(store.syncSnapshot().brokerageAccounts?
            .first { $0.accountID == .financing }?.items.first?.positionQuantity == 2)
    }

    @MainActor
    @Test("A peer update to an inactive account keeps the selected account in view")
    func peerUpdateToInactiveAccountPreservesSelection() throws {
        let (store, defaults, suite) = try makeStore("peer-inactive")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))

        let peerItem = WatchItem(
            symbol: apple,
            displayName: "Apple",
            transactions: [buy(price: 200, quantity: 6, day: 1_700_000_000)]
        )
        let peer = WatchlistSyncSnapshot(
            items: store.allItems,
            groups: store.groups,
            retainedHistoryItems: [],
            brokerageAccounts: [
                BrokerageAccountPortfolio(
                    accountID: .financing,
                    items: [peerItem],
                    groups: [WatchlistGroup(name: "Watchlist", symbols: [apple])]
                ),
                BrokerageAccountPortfolio(
                    accountID: .mengmeng,
                    groups: [WatchlistGroup(name: "Watchlist")]
                )
            ]
        )
        #expect(store.applySyncSnapshot(peer))
        // Still looking at unassigned, and its data is exactly what it was.
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: apple)?.positionQuantity == 1)
        #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 6)
    }

    @MainActor
    @Test("A legacy backup restore clears named accounts but leaves them enabled")
    func legacyBackupRestoreClearsNamedAccounts() throws {
        let (store, defaults, suite) = try makeStore("backup")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 9, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        let backupItem = WatchItem(
            symbol: apple,
            displayName: "Apple",
            transactions: [buy(price: 120, quantity: 3, day: 1_700_000_000)]
        )
        let backup = WatchlistSyncSnapshot(
            items: [backupItem],
            groups: store.groups,
            retainedHistoryItems: []
        )
        #expect(try store.restoreBackup(backup))
        #expect(store.brokerageAccountsEnabled)
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: apple)?.positionQuantity == 3)
        // The backup said nothing about named accounts, so they are emptied
        // rather than left holding data the user just replaced.
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
        #expect(store.brokeragePortfolio(for: .financing).groups.count == 1)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    @MainActor
    @Test("No existing mutation can drop an inactive account")
    func existingMutationsPreserveInactiveAccounts() throws {
        let (store, defaults, suite) = try makeStore("preserve")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 5, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        // A spread of the store's ordinary mutations, all made while a
        // different account is selected.
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))
        let group = try #require(store.selectedGroup?.id)
        #expect(store.createGroup(named: "Second") != nil)
        store.add(SymbolInfo(symbol: SymbolID(market: .us, code: "MSFT"), name: "Microsoft"))
        #expect(store.setPinned(apple, in: group, pinned: true))
        store.setThesis("why I hold it", for: apple)
        store.renameGroup(group, to: "Renamed")
        store.deleteTransaction(apple, id: try #require(store.item(for: apple)?.transactions.first?.id))
        store.calibratePosition(apple, quantity: 2, averageCost: 101)
        store.merge(WatchlistArchive(lists: [
            .init(name: "Imported", entries: [.init(market: .hk, code: "700")])
        ]))

        #expect(store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 5)
        #expect(store.brokeragePortfolio(for: .financing).groups.first?.name == "Watchlist")
        #expect(store.brokeragePortfolio(for: .mengmeng).accountID == .mengmeng)
    }

    // MARK: - Whole-instrument assignment

    @MainActor
    @Test("A whole assignment conserves ids, funding, reviews, and allocations")
    func wholeAssignmentConservesRecords() throws {
        let (store, defaults, suite) = try makeStore("whole")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed the historic unassigned ledger before account rules are enabled.
        store.add(SymbolInfo(symbol: apple, name: "Apple"))

        let firstBuy = UUID()
        let secondBuy = UUID()
        let sold = UUID()
        store.addTransaction(apple, buy(firstBuy, price: 100, quantity: 4, day: 1_700_000_000, fee: 2, fundingSource: .margin))
        store.addTransaction(apple, buy(secondBuy, price: 110, quantity: 2, day: 1_700_086_400, fundingSource: .own))
        store.addTransaction(apple, sell(sold, price: 130, quantity: 1, day: 1_700_172_800))
        store.initializePositionAllocations()
        let review = PositionTransactionReview(followedPlan: true, retrospective: "held the line")
        #expect(store.updateTransactionReview(apple, id: firstBuy, note: "first entry", review: review))
        let plan = TradePlan(kind: .buy, price: 95, quantity: 2)
        #expect(store.setTradePlan(plan, for: apple))
        store.setThesis("core position", for: apple)

        store.enableBrokerageAccounts()
        let before = try #require(store.item(for: apple))
        let beforePortions = try #require(before.positionAllocation?.portions)
        let beforeMembership = store.groups.first { $0.symbols.contains(apple) }?.name

        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .financing))

        // Gone from the source entirely: not a holding, not dormant history.
        #expect(store.item(for: apple) == nil)
        #expect(store.retainedHistoryItem(for: apple) == nil)
        #expect(store.tradeHistoryItems.contains { $0.symbol == apple } == false)

        let moved = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == apple })
        #expect(moved.transactions.map(\.id) == [firstBuy, secondBuy, sold])
        #expect(moved.transactions.map(\.fundingSource) == [.margin, .own, nil])
        #expect(moved.transactions.first?.fee == 2)
        #expect(moved.transactions.first?.note == "first entry")
        #expect(moved.transactions.first?.review == review)
        #expect(moved.positionQuantity == before.positionQuantity)
        #expect(moved.plans.map(\.id) == [plan.id])
        #expect(moved.thesis == "core position")
        // Shares are conserved, and no portion was duplicated or dropped.
        #expect(moved.positionAllocation?.portions.count == beforePortions.count)
        #expect(moved.positionAllocation?.portions.map(\.id).sorted(by: { $0.uuidString < $1.uuidString })
            == beforePortions.map(\.id).sorted(by: { $0.uuidString < $1.uuidString }))
        #expect(moved.positionAllocation?.portions.map(\.quantity).reduce(0, +) == beforePortions.map(\.quantity).reduce(0, +))
        // The list membership travelled with it.
        #expect(store.brokeragePortfolio(for: .financing).groups.contains { group in
            group.name == beforeMembership && group.symbols.contains(apple)
        })
        // No transaction id exists twice anywhere in the store afterwards.
        var seen = Set<UUID>()
        for item in store.syncSnapshot().allAccountItems {
            for transaction in item.transactions {
                #expect(seen.insert(transaction.id).inserted)
            }
        }
    }

    @MainActor
    @Test("An assignment is refused when the destination already holds the instrument")
    func wholeAssignmentRejectsConflictingDestination() throws {
        let (store, defaults, suite) = try makeStore("whole-conflict")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let sourceBuy = UUID()
        store.addTransaction(apple, buy(sourceBuy, price: 100, quantity: 4, day: 1_700_000_000))

        // The destination independently recorded the same instrument.
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let destinationBuy = UUID()
        store.addTransaction(apple, buy(destinationBuy, price: 500, quantity: 1, day: 1_700_000_000))
        let destinationBefore = try #require(store.item(for: apple))
        #expect(store.selectBrokerageAccount(.unassigned))
        let sourceBefore = try #require(store.item(for: apple))

        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .financing) == false)

        // Nothing moved and nothing was averaged together.
        #expect(store.item(for: apple)?.transactions.map(\.id) == [sourceBuy])
        #expect(store.item(for: apple)?.positionQuantity == 4)
        #expect(store.item(for: apple)?.positionAllocation?.basisFingerprint
            == sourceBefore.positionAllocation?.basisFingerprint)
        let destinationAfter = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == apple })
        #expect(destinationAfter.transactions.map(\.id) == [destinationBuy])
        #expect(destinationAfter.positionQuantity == 1)
        #expect(destinationAfter.positionAllocation?.basisFingerprint
            == destinationBefore.positionAllocation?.basisFingerprint)
    }

    @MainActor
    @Test("Assignment is refused unless the selected account is unassigned")
    func assignmentOnlyFromUnassigned() throws {
        let (store, defaults, suite) = try makeStore("whole-source")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 1, day: 1_700_000_000))

        // No named-to-named transfer, and no assignment into the current account.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .mengmeng) == false)
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .financing) == false)
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .unassigned) == false)
        #expect(store.item(for: apple)?.positionQuantity == 1)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    // MARK: - Partial assignment

    @MainActor
    @Test("A partial assignment splits a ledger and conserves fees and quantity")
    func partialAssignmentConservesFeesAndQuantity() throws {
        let (store, defaults, suite) = try makeStore("partial")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let movedBuy = UUID()
        let stayingBuy = UUID()
        store.addTransaction(apple, buy(movedBuy, price: 100, quantity: 2, day: 1_700_000_000, fee: 1))
        store.addTransaction(apple, buy(stayingBuy, price: 120, quantity: 3, day: 1_700_086_400, fee: 2))
        store.initializePositionAllocations()
        let totalFeesBefore = try #require(store.item(for: apple)).transactions.compactMap(\.fee).reduce(0, +)
        let quantityBefore = try #require(store.item(for: apple)).positionQuantity

        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [movedBuy], to: .financing))

        let source = try #require(store.item(for: apple))
        let destination = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == apple })
        #expect(source.transactions.map(\.id) == [stayingBuy])
        #expect(destination.transactions.map(\.id) == [movedBuy])
        #expect(destination.transactions.first?.fee == 1)
        #expect(source.positionQuantity + destination.positionQuantity == quantityBefore)
        #expect(source.transactions.compactMap(\.fee).reduce(0, +)
            + destination.transactions.compactMap(\.fee).reduce(0, +) == totalFeesBefore)
        // The moved buy brought its own card rather than a fabricated one.
        let destinationPortion = try #require(destination.positionAllocation?.portions.first)
        #expect(destinationPortion.quantity == 2)
        #expect(destinationPortion.origin.kind == .buy)
        #expect(destinationPortion.origin.transactionID == movedBuy)
        #expect(destinationPortion.origin.price == 100)
        // The source keeps a usable remaining allocation.
        #expect(try #require(source.positionAllocation).portions.map(\.quantity).reduce(0, +) == 3)
        #expect(source.positionAllocationNeedsReconciliation == false)
        // The list entry survived as a clean quote-only template.
        #expect(source.transactions.isEmpty == false)
        #expect(store.groups.contains { $0.symbols.contains(apple) })
    }

    @MainActor
    @Test("A partial assignment completes a ledger already split into the account")
    func partialAssignmentCompletesSplitLedger() throws {
        let (store, defaults, suite) = try makeStore("partial-complete")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let firstBuy = UUID()
        let secondBuy = UUID()
        store.addTransaction(apple, buy(firstBuy, price: 100, quantity: 2, day: 1_700_000_000, fee: 1))
        store.addTransaction(apple, buy(secondBuy, price: 120, quantity: 3, day: 1_700_086_400, fee: 2))
        store.initializePositionAllocations()

        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [firstBuy], to: .financing))
        #expect(store.item(for: apple)?.transactions.map(\.id) == [secondBuy])

        // Hand the rest of the same ledger to the same account.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [secondBuy], to: .financing))
        let destination = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == apple })
        #expect(destination.transactions.map(\.id) == [firstBuy, secondBuy])
        #expect(destination.positionQuantity == 5)
        #expect(destination.transactions.compactMap(\.fee).reduce(0, +) == 3)
        #expect(destination.positionAllocation?.portions.map(\.quantity).reduce(0, +) == 5)
        // The source keeps the watchlist entry but no longer counts as holding.
        #expect(store.item(for: apple)?.positionQuantity == 0)
        #expect(store.tradeHistoryItems.contains { $0.symbol == apple } == false)
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [firstBuy], to: .financing) == false)
    }

    @MainActor
    @Test("An unknown transaction id or an orphan sale is refused without change")
    func partialAssignmentRejectsInvalidSelections() throws {
        let (store, defaults, suite) = try makeStore("partial-reject")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let buyID = UUID()
        store.addTransaction(apple, buy(buyID, price: 100, quantity: 2, day: 1_700_000_000))
        store.initializePositionAllocations()
        let before = try #require(store.item(for: apple))

        // An id that is not on this instrument at all.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [UUID()], to: .financing) == false)
        // An empty selection is not a move.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [], to: .financing) == false)
        // A destination that does not exist / is not allowed.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [buyID], to: .unassigned) == false)

        #expect(store.item(for: apple)?.transactions.map(\.id) == [buyID])
        #expect(store.item(for: apple)?.positionQuantity == before.positionQuantity)
        #expect(store.item(for: apple)?.positionAllocation?.revision == before.positionAllocation?.revision)
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)

        // A sale whose own buy stays behind would open a short that never
        // happened, so it is refused and the source is untouched.
        store.addTransaction(apple, sell(price: 130, quantity: 1, day: 1_700_086_400))
        let saleID = try #require(store.item(for: apple)?.transactions.last?.id)
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [saleID], to: .financing) == false)
        #expect(store.item(for: apple)?.transactions.count == 2)
        #expect(store.item(for: apple)?.positionQuantity == 1)
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
    }

    @MainActor
    @Test("A source whose ledger no longer matches its allocation is refused")
    func partialAssignmentRejectsUnreconciledSource() throws {
        let (store, defaults, suite) = try makeStore("partial-unreconciled")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let buyID = UUID()
        store.addTransaction(apple, buy(buyID, price: 100, quantity: 2, day: 1_700_000_000))
        store.initializePositionAllocations()
        // A calibration replaces the position without touching the cards, which
        // is exactly the state the reconciliation guard exists for.
        store.calibratePosition(apple, quantity: 9, averageCost: 105)
        #expect(store.item(for: apple)?.positionAllocationNeedsReconciliation == true)

        let before = try #require(store.item(for: apple))
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [buyID], to: .financing) == false)
        #expect(store.item(for: apple)?.transactions == before.transactions)
        #expect(store.item(for: apple)?.positionAllocation?.revision == before.positionAllocation?.revision)
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
    }

    @MainActor
    @Test("A partial assignment refuses a destination holding unrelated metadata")
    func partialAssignmentRejectsDestinationMetadata() throws {
        let (store, defaults, suite) = try makeStore("partial-metadata")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let sourceBuy = UUID()
        store.addTransaction(apple, buy(sourceBuy, price: 100, quantity: 2, day: 1_700_000_000))

        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.setThesis("a different position entirely", for: apple)
        #expect(store.selectBrokerageAccount(.unassigned))

        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: [sourceBuy], to: .financing) == false)
        #expect(store.item(for: apple)?.transactions.map(\.id) == [sourceBuy])
        #expect(store.brokeragePortfolio(for: .financing).items.first?.thesis == "a different position entirely")
        #expect(store.brokeragePortfolio(for: .financing).items.first?.transactions.isEmpty == true)
    }

    // MARK: - Dormant history

    @MainActor
    @Test("Assigning a dormant instrument moves its retained history too")
    func wholeAssignmentMovesRetainedHistory() throws {
        let (store, defaults, suite) = try makeStore("retained")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 2, day: 1_700_000_000))
        store.remove(apple)
        #expect(store.item(for: apple) == nil)
        #expect(store.retainedHistoryItem(for: apple)?.positionQuantity == 2)

        // Dormant history is still assignable without re-adding a watchlist row.
        #expect(store.assignBrokerageRecords(for: apple, transactionIDs: nil, to: .financing))
        #expect(store.retainedHistoryItem(for: apple) == nil)
        #expect(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == apple }?.positionQuantity == 2)
    }
}
