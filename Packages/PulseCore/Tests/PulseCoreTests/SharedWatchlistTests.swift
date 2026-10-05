import Foundation
import Testing
@testable import PulseCore

/// The shared watchlist is a cross-account *view*, not a second store.
///
/// These tests pin the contract that matters for the UI: the same shared
/// groups/items/selection are visible whatever the financial active account is,
/// reads never move that account or dirty sync state, and every mutation writes
/// membership metadata only — no trade, lot, plan, or allocation is rewritten.
@Suite("Shared watchlist")
struct SharedWatchlistTests {
    private let apple = SymbolID(market: .us, code: "AAPL")
    private let microsoft = SymbolID(market: .us, code: "MSFT")
    private let tencent = SymbolID(market: .hk, code: "00700")

    @MainActor
    private func makeStores(_ label: String) throws
        -> (store: WatchlistStore, shared: SharedWatchlist,
            defaults: UserDefaults, sharedDefaults: UserDefaults, suite: String) {
        let suite = "SharedWatchlistTests.\(label).\(UUID().uuidString)"
        let sharedSuite = "\(suite).shared"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let sharedDefaults = try #require(UserDefaults(suiteName: sharedSuite))
        // Start every case from empty storage so no sibling test leaks in.
        defaults.removePersistentDomain(forName: suite)
        sharedDefaults.removePersistentDomain(forName: sharedSuite)
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        let shared = SharedWatchlist(store: store, defaults: sharedDefaults)
        return (store, shared, defaults, sharedDefaults, suite)
    }

    private func buy(_ id: UUID = UUID(), price: Double, quantity: Double, day: TimeInterval) -> PositionTransaction {
        PositionTransaction(id: id, kind: .buy, price: price, quantity: quantity,
                            date: Date(timeIntervalSince1970: day),
                            createdAt: Date(timeIntervalSince1970: day))
    }

    /// Builds one store with identical group names in several accounts.
    @MainActor
    private func seedSharedAccounts(
        _ store: WatchlistStore
    ) {
        store.enableBrokerageAccounts()
        // Unassigned keeps a symbol and a group named "Core".
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 3, day: 1_700_000_000))

        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        store.addTransaction(microsoft, buy(price: 50, quantity: 1, day: 1_700_000_100))
        #expect(store.renameGroup(store.selectedGroupID!, to: "Core"))

        #expect(store.selectBrokerageAccount(.mengmeng))
        store.add(SymbolInfo(symbol: tencent, name: "Tencent"))

        #expect(store.selectBrokerageAccount(.unassigned))
        #expect(store.renameGroup(store.selectedGroupID!, to: "Core"))
    }

    // MARK: - Cross-account identity


    @MainActor
    @Test("Shared groups, items, and selection are identical while the financial account changes")
    func sharedViewIsAccountIndependent() throws {
        let (store, shared, defaults, _, suite) = try makeStores("independent")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)

        let baselineGroups = shared.groups.map(\.name)
        let baselineSymbols = shared.allItems.map(\.symbol)
        let baselineSelection = shared.selectedGroupID

        #expect(baselineGroups == ["Core", "Watchlist"])
        #expect(Set(baselineSymbols) == Set([apple, microsoft, tencent]))
        #expect(baselineSelection != nil)

        for account in [BrokerageAccountID.financing, .mengmeng, .unassigned] {
            #expect(store.selectBrokerageAccount(account))
            #expect(shared.groups.map(\.name) == baselineGroups)
            #expect(shared.allItems.map(\.symbol) == baselineSymbols)
            #expect(shared.selectedGroupID == baselineSelection)
        }

        // "Core" merges the unassigned and financing memberships uniquely.
        let core = try #require(shared.groups.first { $0.name == "Core" })
        #expect(Set(core.symbols) == Set([apple, microsoft]))
    }


    @MainActor
    @Test("Reads never change the financial selection or the sync snapshot")
    func readsAreSideEffectFree() throws {
        let (store, shared, defaults, _, suite) = try makeStores("readonly")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        #expect(store.selectBrokerageAccount(.financing))

        let beforeSnapshot = store.syncSnapshot()
        let beforeAccount = store.activeBrokerageAccountID
        let beforeSelected = store.selectedGroupID

        _ = shared.groups
        _ = shared.allItems
        _ = shared.items
        _ = shared.items(in: shared.selectedGroupID)
        _ = shared.item(for: apple)
        _ = shared.symbols
        _ = shared.quoteSymbols
        _ = shared.isEmpty
        _ = shared.contains(apple)
        _ = shared.isPinned(apple)
        _ = shared.records(for: apple)
        _ = shared.tradePlanEntries
        _ = shared.hasPosition(for: apple)
        _ = shared.hasActivePlan(for: apple)

        #expect(store.syncSnapshot() == beforeSnapshot)
        #expect(store.activeBrokerageAccountID == beforeAccount)
        #expect(store.selectedGroupID == beforeSelected)
    }


    @MainActor
    @Test("A named-account-only symbol appears in the merged same-name group")
    func namedAccountSymbolMergesIntoSharedGroup() throws {
        let (store, shared, defaults, _, suite) = try makeStores("merge")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        #expect(store.renameGroup(store.selectedGroupID!, to: "Core"))

        // Financing gets the same group name but a different, non-shared symbol.
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        #expect(store.renameGroup(store.selectedGroupID!, to: "Core"))

        #expect(store.selectBrokerageAccount(.unassigned))

        let core = try #require(shared.groups.first { $0.name == "Core" })
        #expect(core.symbols.contains(microsoft), "the financing-only symbol must be visible in the merged group")
        #expect(shared.contains(microsoft, in: core.id))
        #expect(shared.item(for: microsoft)?.displayName == "Microsoft")
    }


    @MainActor
    @Test("The canonical id is the first source group id in account order")
    func canonicalIDComesFromFirstSource() throws {
        let (store, shared, defaults, _, suite) = try makeStores("canonical")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let unassignedGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(unassignedGroupID, to: "Core"))

        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        let financingGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(financingGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.unassigned))

        let core = try #require(shared.groups.first { $0.name == "Core" })
        #expect(core.id == unassignedGroupID)
        #expect(core.id != financingGroupID)
        // Renaming unassigned's only list to "Core" leaves no unassigned
        // "Watchlist"; the named accounts' empty "Watchlist" aliases do not
        // resurrect it as a second tab.
        #expect(shared.groups.count == 1)
        #expect(shared.groups.map(\.name) == ["Core"])
    }


    @MainActor
    @Test("An empty named-account default group does not add a duplicate tab")
    func emptyNamedAccountDefaultGroupDoesNotDuplicate() throws {
        let (store, shared, defaults, _, suite) = try makeStores("emptydefault")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Enabling seeds financing and mengmeng with an empty "Watchlist".
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))

        #expect(shared.groups.map(\.name) == ["Watchlist"])
        let watchlist = try #require(shared.groups.first)
        #expect(watchlist.symbols == [apple])
        // All three accounts share that name; the tab count is one.
        #expect(shared.groups.count == 1)
    }

    @MainActor
    @Test("An empty named-account default group with a different name adds no phantom tab")
    func distinctNameEmptyAccountAddsNoPhantomTab() throws {
        let (store, shared, defaults, _, suite) = try makeStores("phantom")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Enabling seeds financing and mengmeng with a lone empty default
        // group named "Watchlist" (pinned by `makeStores`). Unassigned gets a
        // different user name — the "real user has 持仓/跟踪/美股" shape.
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let renamedTo = "跟踪"
        #expect(store.renameGroup(store.selectedGroupID!, to: renamedTo))
        let seededDefault = "Watchlist"

        // Only the unassigned tab remains; the named-account aliases do not
        // each become their own phantom tab. This is the localized-`自选`
        // regression: the aliases share no name with any unassigned group.
        #expect(shared.groups.map(\.name) == [renamedTo])
        #expect(shared.groups.count == 1)
        #expect(shared.groups.contains { $0.name == seededDefault } == false)

        // A named account that actually watches something owns a real list, so
        // its group is projected rather than treated as an ignorable alias.
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        #expect(store.selectBrokerageAccount(.unassigned))
        let names = shared.groups.map(\.name)
        #expect(names.contains(renamedTo))
        #expect(names.contains(seededDefault), "a named account with a watched symbol is a real list")

        // Creating a real custom group inside a named account is never hidden.
        #expect(store.selectBrokerageAccount(.mengmeng))
        store.createGroup(named: "美股")
        store.add(SymbolInfo(symbol: tencent, name: "Tencent"))
        #expect(store.selectBrokerageAccount(.unassigned))
        #expect(shared.groups.contains { $0.name == "美股" })
    }


    @MainActor
    @Test("Manual order delegates to the core store with empty named accounts present")
    func manualOrderDelegatesWithEmptyNamedAccounts() throws {
        let (store, shared, defaults, _, suite) = try makeStores("manualdelegate")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        let groupID = try #require(store.selectedGroupID)

        // Financing and mengmeng hold only their own empty default list, so this
        // merged-looking tab really has one member-bearing source. Automatic
        // sorting must write through to the core store rather than becoming a
        // UI-only override that never touches financial order.
        shared.selectGroup(groupID)
        shared.reorder([microsoft, apple])
        let physical = try #require(store.groups.first { $0.id == groupID })
        #expect(physical.symbols == [microsoft, apple])
        #expect(shared.selectedGroup?.symbols == [microsoft, apple])

        // A manual move delegates too: it writes through to the core store's
        // list and records the core store's own manual order.
        shared.rememberManualOrder()
        #expect(shared.commitManualMove(orderedSymbols: [apple, microsoft], movingSymbols: [apple]))
        #expect(store.groups.first { $0.id == groupID }?.symbols == [apple, microsoft])
        #expect(shared.selectedGroup?.symbols == [apple, microsoft])
        #expect(store.groups.first { $0.id == groupID }?.manualOrder == [apple, microsoft])

        // Moving back is a real move as well and still writes through.
        #expect(shared.commitManualMove(orderedSymbols: [microsoft, apple], movingSymbols: [microsoft]))
        #expect(store.groups.first { $0.id == groupID }?.symbols == [microsoft, apple])

        // Restoring is the core store's own operation, and it agrees with the
        // order the last manual move committed.
        #expect(shared.restoreManualOrder())
        #expect(store.groups.first { $0.id == groupID }?.symbols == [microsoft, apple])
    }


    // MARK: - Membership mutation


    @MainActor
    @Test("Shared add writes membership only and never duplicates a trade")
    func sharedAddWritesMembershipOnly() throws {
        let (store, shared, defaults, _, suite) = try makeStores("add")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        // "Core" exists in both unassigned and financing.
        let unassignedGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(unassignedGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.financing))
        let financingGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(financingGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.unassigned))

        let transactionsBefore = store.syncSnapshot()
            .allAccountItems.flatMap(\.transactions).count

        let core = try #require(shared.groups.first { $0.name == "Core" })
        shared.add(SymbolInfo(symbol: apple, name: "Apple"), to: core.id)

        // The write landed in the canonical (unassigned) source only.
        let unassignedPortfolio = store.brokeragePortfolio(for: .unassigned)
        #expect(unassignedPortfolio.groups.first { $0.id == unassignedGroupID }?.symbols == [apple])
        let financingPortfolio = store.brokeragePortfolio(for: .financing)
        #expect(financingPortfolio.groups.first { $0.id == financingGroupID }?.symbols.isEmpty == true)
        #expect(financingPortfolio.items.isEmpty)

        let transactionsAfter = store.syncSnapshot()
            .allAccountItems.flatMap(\.transactions).count
        #expect(transactionsAfter == transactionsBefore)
        #expect(shared.contains(apple, in: core.id))
    }


    @MainActor
    @Test("Shared add uses first-source metadata for a symbol already known elsewhere")
    func sharedAddReusesFirstSourceMetadata() throws {
        let (store, shared, defaults, _, suite) = try makeStores("metadata")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        // Unassigned owns the metadata for Apple.
        store.add(SymbolInfo(symbol: apple, name: "Apple Inc.", type: .equity,
                             displayNameSource: DisplayNameSource(providerID: "test", priority: 1, localeIdentifier: "en")))
        store.addTransaction(apple, buy(price: 100, quantity: 3, day: 1_700_000_000))

        #expect(store.selectBrokerageAccount(.financing))
        let financingGroupID = try #require(store.selectedGroupID)
        #expect(store.selectBrokerageAccount(.unassigned))

        let sharedGroup = try #require(shared.groups.first)
        // Adding to the merged group lands in unassigned, the canonical source.
        shared.add(SymbolInfo(symbol: apple, name: "ignored"), to: sharedGroup.id)

        let item = try #require(store.brokeragePortfolio(for: .unassigned).items.first { $0.symbol == apple })
        #expect(item.displayName == "Apple Inc.")
        #expect(item.transactions.count == 1)
        #expect(store.brokeragePortfolio(for: .financing).items.isEmpty)
        _ = financingGroupID
    }


    @MainActor
    @Test("Removing a watched symbol preserves the original account's retained transactions")
    func removalPreservesRetainedFinancialHistory() throws {
        let (store, shared, defaults, _, suite) = try makeStores("retained")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)

        // Apple is only in the unassigned portfolio.
        let appleTransactions = try #require(store.brokeragePortfolio(for: .unassigned)
            .items.first { $0.symbol == apple }?.transactions)
        #expect(appleTransactions.count == 1)

        shared.selectGroup(try #require(shared.groups.first { $0.name == "Core" }).id)
        shared.remove(apple)

        let unassigned = store.brokeragePortfolio(for: .unassigned)
        #expect(unassigned.items.allSatisfy { $0.symbol != apple })
        // The ledger survives in retained history, exactly as the core store keeps it.
        let retained = try #require(unassigned.retainedHistoryItems.first { $0.symbol == apple })
        #expect(retained.transactions.map(\.id) == appleTransactions.map(\.id))
        #expect(shared.retainedHistoryItem(for: apple) != nil)
        #expect(shared.hasPosition(for: apple))
    }


    @MainActor
    @Test("Independent same-symbol records in two accounts are not combined")
    func independentSameSymbolRecordsAreNotCombined() throws {
        let (store, shared, defaults, _, suite) = try makeStores("noncombined")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 100, quantity: 2, day: 1_700_000_000))

        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.addTransaction(apple, buy(price: 200, quantity: 5, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        // The merged presentation uses the first source only — no aggregate.
        let item = try #require(shared.item(for: apple))
        #expect(item.positionQuantity == 2)
        #expect(item.transactions.count == 1)

        // The per-account records stay separate.
        let records = shared.records(for: apple)
        #expect(records.count == 2)
        #expect(Set(records.map(\.positionQuantity)) == Set([2, 5]))
    }


    @MainActor
    @Test("Membership addition targets only the canonical source and copies no financial fields")
    func membershipAdditionTargetsCanonicalSourceOnly() throws {
        let (store, shared, defaults, _, suite) = try makeStores("canonicalmembership")
        defer { defaults.removePersistentDomain(forName: suite) }

        // Three same-name groups: unassigned (canonical), financing, mengmeng.
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let unassignedGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(unassignedGroupID, to: "Core"))

        #expect(store.selectBrokerageAccount(.financing))
        let financingGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(financingGroupID, to: "Core"))
        // Finance-only symbol: it exists solely as a financing ledger entry, so
        // no unassigned or mengmeng copy of its metadata exists.
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        let financeTransaction = buy(price: 50, quantity: 4, day: 1_700_000_200)
        store.addTransaction(microsoft, financeTransaction)

        #expect(store.selectBrokerageAccount(.mengmeng))
        let mengmengGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(mengmengGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.unassigned))

        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        #expect(shared.contains(microsoft, in: coreID), "the financing symbol is visible in the merged tab")

        // Microsoft is already a merged member, so marking it included is a
        // no-op: it must not be materialized into unassigned or mengmeng.
        shared.setMembership(microsoft, in: coreID, included: true)
        #expect(store.brokeragePortfolio(for: .unassigned).items.allSatisfy { $0.symbol != microsoft })
        #expect(store.brokeragePortfolio(for: .mengmeng).items.allSatisfy { $0.symbol != microsoft })
        #expect(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.id == unassignedGroupID }?.symbols == [apple])
        #expect(store.brokeragePortfolio(for: .mengmeng)
            .groups.first { $0.id == mengmengGroupID }?.symbols.isEmpty == true)
        // The original financing record is untouched.
        let financingAfterNoop = try #require(store.brokeragePortfolio(for: .financing).items
            .first { $0.symbol == microsoft })
        #expect(financingAfterNoop.transactions.map(\.id) == [financeTransaction.id])
        #expect(financingAfterNoop.positionQuantity == 4)

        // Adding apple — already in unassigned's "Core" — is a no-op for that
        // tab: it stays a single unassigned membership and gains no copies.
        shared.setMembership(apple, in: unassignedGroupID, included: true)
        #expect(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.id == unassignedGroupID }?.symbols == [apple])
        #expect(store.brokeragePortfolio(for: .financing)
            .groups.first { $0.id == financingGroupID }?.symbols == [microsoft])
        #expect(store.brokeragePortfolio(for: .mengmeng)
            .groups.first { $0.id == mengmengGroupID }?.symbols.isEmpty == true)

        // A different logical group: adding microsoft to a second unassigned
        // group must create exactly one canonical membership, and must not copy
        // the symbol into financing's or mengmeng's groups.
        let secondaryID = try #require(store.createGroup(named: "Watchlist"))
        #expect(store.selectBrokerageAccount(.financing))
        store.createGroup(named: "Watchlist")
        #expect(store.selectBrokerageAccount(.mengmeng))
        store.createGroup(named: "Watchlist")
        #expect(store.selectBrokerageAccount(.unassigned))
        let watchlistID = try #require(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.name == "Watchlist" }?.id)
        #expect(watchlistID == secondaryID)
        shared.setMembership(microsoft, in: watchlistID, included: true)
        #expect(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.id == watchlistID }?.symbols == [microsoft])
        // The canonical membership reuses shared metadata only — no ledger, lot,
        // or transaction is copied from financing.
        let materialized = try #require(store.brokeragePortfolio(for: .unassigned)
            .items.first { $0.symbol == microsoft })
        #expect(materialized.transactions.isEmpty)
        #expect(materialized.displayName == "Microsoft")
        #expect(store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == microsoft }?.transactions.map(\.id) == [financeTransaction.id])

        // No watch entry was duplicated into a second account, and every
        // original financing transaction survived.
        let accountsWithMicrosoft = BrokerageAccountID.allCases.filter { account in
            store.brokeragePortfolio(for: account).items.contains { $0.symbol == microsoft }
        }
        #expect(accountsWithMicrosoft == [.unassigned, .financing])
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
        let financeTrades = store.syncSnapshot().allAccountItems
            .flatMap(\.transactions).filter { $0.id == financeTransaction.id }
        #expect(financeTrades.count == 1)
        #expect(financeTrades.first?.quantity == 4)

        // Removal still clears every concrete source that really holds it.
        shared.setMembership(microsoft, in: coreID, included: false)
        #expect(store.brokeragePortfolio(for: .financing)
            .groups.first { $0.id == financingGroupID }?.symbols.isEmpty == true)
        #expect(store.brokeragePortfolio(for: .financing)
            .retainedHistoryItems.first { $0.symbol == microsoft }?
            .transactions.map(\.id) == [financeTransaction.id])
    }

    // MARK: - Plans


    @MainActor
    @Test("Trade plan entries combine accounts while keeping original plan ids")
    func tradePlanEntriesKeepOriginalPlanIDs() throws {
        let (store, shared, defaults, _, suite) = try makeStores("plans")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let unassignedPlan = TradePlan(kind: .buy, price: 90, quantity: 1)
        #expect(store.setTradePlan(unassignedPlan, for: apple))

        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let financingPlan = TradePlan(kind: .buy, price: 80, quantity: 2)
        #expect(store.setTradePlan(financingPlan, for: apple))
        #expect(store.selectBrokerageAccount(.unassigned))

        let entries = shared.tradePlanEntries
        #expect(entries.count == 2)
        #expect(Set(entries.map(\.plan.id)) == Set([unassignedPlan.id, financingPlan.id]))
        #expect(entries.first { $0.plan.id == financingPlan.id }?.accountID == .financing)

        #expect(shared.hasActivePlan(for: apple))
        // Both records exist, so the global filter sees each independently.
        #expect(shared.records(for: apple).count == 2)
    }


    @MainActor
    @Test("hasPosition and hasActivePlan scan underlying records, not the merged item")
    func filtersScanUnderlyingRecords() throws {
        let (store, shared, defaults, _, suite) = try makeStores("filters")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        // Unassigned: watch only, no position, no plan.
        store.add(SymbolInfo(symbol: apple, name: "Apple"))

        // Financing: a position but no plan.
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        store.addTransaction(microsoft, buy(price: 50, quantity: 1, day: 1_700_000_000))
        #expect(store.selectBrokerageAccount(.unassigned))

        #expect(shared.hasPosition(for: microsoft))
        #expect(shared.hasPosition(for: apple) == false)
        #expect(shared.hasActivePlan(for: microsoft) == false)
        #expect(shared.hasActivePlan(for: apple) == false)
    }

    // MARK: - Selection persistence


    @MainActor
    @Test("The shared selection persists and is restored on a new facade")
    func sharedSelectionPersists() throws {
        let (store, shared, defaults, sharedDefaults, suite) = try makeStores("selection")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        shared.selectGroup(coreID)
        #expect(shared.selectedGroupID == coreID)

        let restored = SharedWatchlist(store: store, defaults: sharedDefaults)
        #expect(restored.selectedGroupID == coreID)
    }


    @MainActor
    @Test("A stale saved selection falls back to the first group")
    func staleSelectionFallsBack() throws {
        let (store, _, defaults, sharedDefaults, suite) = try makeStores("stale")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        sharedDefaults.set(UUID().uuidString, forKey: "pulse.sharedWatchlist.selectedGroup.v1")

        let restored = SharedWatchlist(store: store, defaults: sharedDefaults)
        #expect(restored.selectedGroupID == restored.groups.first?.id)
    }

    // MARK: - Pinning and ordering

    @MainActor
    @Test("Replacing groups externally repairs the live selection without changing the financial account")
    func externallyReplacedSelectionRemainsUsable() throws {
        let (store, shared, defaults, _, suite) = try makeStores("replaced-selection")
        defer { defaults.removePersistentDomain(forName: suite) }
        seedSharedAccounts(store)
        shared.selectGroup(try #require(shared.groups.first { $0.name == "Core" }).id)
        #expect(store.selectBrokerageAccount(.financing))
        var replacement = store.syncSnapshot()
        replacement.groups[0].id = UUID()
        #expect(store.applySyncSnapshot(replacement))

        let beforeRead = store.syncSnapshot()
        #expect(shared.selectedGroupID == shared.groups.first?.id)
        #expect(shared.contains(apple))
        #expect(store.syncSnapshot() == beforeRead)
        shared.add(SymbolInfo(symbol: SymbolID(market: .us, code: "GOOG"), name: "Google"))
        #expect(shared.items.contains { $0.symbol.code == "GOOG" })
        #expect(store.activeBrokerageAccountID == .financing)
    }

    @MainActor
    @Test("Pinning a merged symbol preserves other existing pins")
    func pinningPreservesOtherPins() throws {
        let (store, shared, defaults, _, suite) = try makeStores("preserved-pins")
        defer { defaults.removePersistentDomain(forName: suite) }
        seedSharedAccounts(store)
        #expect(store.setPinned(apple, pinned: true))
        let core = try #require(shared.groups.first { $0.name == "Core" })
        shared.selectGroup(core.id)
        #expect(shared.setPinned(microsoft, pinned: true))
        #expect(shared.isPinned(apple))
        #expect(shared.isPinned(microsoft))
    }


    @MainActor
    @Test("Pin state is set on every merged source and survives a reload")
    func pinningAppliesAcrossSources() throws {
        let (store, shared, defaults, _, suite) = try makeStores("pinning")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        let unassignedGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(unassignedGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.financing))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))
        let financingGroupID = try #require(store.selectedGroupID)
        #expect(store.renameGroup(financingGroupID, to: "Core"))
        #expect(store.selectBrokerageAccount(.unassigned))

        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        #expect(shared.setPinned(apple, in: coreID, pinned: true))
        #expect(shared.setPinned(microsoft, in: coreID, pinned: true))
        #expect(shared.isPinned(apple, in: coreID))
        #expect(shared.isPinned(microsoft, in: coreID))

        // Each physical source group holds its own pin independently.
        let unassigned = store.brokeragePortfolio(for: .unassigned)
        #expect(unassigned.groups.first { $0.id == unassignedGroupID }?.pinnedSymbols == [apple])
        let financing = store.brokeragePortfolio(for: .financing)
        #expect(financing.groups.first { $0.id == financingGroupID }?.pinnedSymbols == [microsoft])

        // Unpinning removes it from the source that holds it.
        #expect(shared.setPinned(apple, in: coreID, pinned: false))
        #expect(shared.isPinned(apple, in: coreID) == false)
        let unassignedAfter = store.brokeragePortfolio(for: .unassigned)
        #expect(unassignedAfter.groups.first { $0.id == unassignedGroupID }?.pinnedSymbols.isEmpty == true)
    }


    @MainActor
    @Test("Multi-source manual order validates permutations and applies pinned-first")
    func multiSourceManualOrder() throws {
        let (store, shared, defaults, _, suite) = try makeStores("manualorder")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        shared.selectGroup(coreID)
        let members = try #require(shared.selectedGroup).symbols
        #expect(Set(members) == Set([apple, microsoft]))

        // A non-permutation is refused without writing.
        #expect(shared.commitManualMove(orderedSymbols: [apple], movingSymbols: [apple]) == false)
        #expect(shared.commitManualMove(orderedSymbols: [microsoft, microsoft],
                                        movingSymbols: [microsoft]) == false)

        // A real move to the front succeeds.
        #expect(shared.commitManualMove(orderedSymbols: [microsoft, apple], movingSymbols: [microsoft]))
        #expect(shared.selectedGroup?.symbols == [microsoft, apple])

        // Cross the pin boundary upward: with only `microsoft` pinned, moving
        // the unpinned `apple` ahead of it pins `apple` too.
        #expect(shared.setPinned(microsoft, in: coreID, pinned: true))
        #expect(shared.selectedGroup?.pinnedSymbols == [microsoft])
        #expect(shared.commitManualMove(orderedSymbols: [apple, microsoft], movingSymbols: [apple]))
        #expect(shared.selectedGroup?.symbols == [apple, microsoft])
        #expect(Set(try #require(shared.selectedGroup).pinnedSymbols) == Set([apple, microsoft]))

        // Moving a pinned symbol below the pinned section unpins it. Pinning is
        // first dropped for one source only, so the merged pin set shrinks.
        #expect(shared.setPinned(microsoft, in: coreID, pinned: false))
        #expect(shared.selectedGroup?.pinnedSymbols == [apple])

        // The manual baseline restores the remembered order.
        shared.rememberManualOrder()
        #expect(shared.restoreManualOrder())
    }


    @MainActor
    @Test("Automatic symbol reorder applies to the selected merged group and restores the manual order")
    func automaticReorderRestoresManualOrderOnMergedGroup() throws {
        let (store, shared, defaults, _, suite) = try makeStores("autoreorder")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        shared.selectGroup(coreID)
        // Two real contributors, so the merged presentation is UI-only.
        #expect(Set(try #require(shared.selectedGroup).symbols) == Set([apple, microsoft]))

        // Remember [apple, microsoft] as the manual baseline.
        shared.rememberManualOrder()
        #expect(shared.selectedGroup?.symbols == [apple, microsoft])

        // The UI's automatic sort sends the symbols it wants in order.
        shared.reorder([microsoft, apple])
        #expect(shared.selectedGroup?.symbols == [microsoft, apple])

        // A partial or stale sort must never drop a row.
        shared.reorder([microsoft])
        #expect(Set(try #require(shared.selectedGroup).symbols) == Set([apple, microsoft]))
        #expect(shared.selectedGroup?.symbols.first == microsoft)

        // Restoring the manual order brings the remembered arrangement back.
        #expect(shared.restoreManualOrder())
        #expect(shared.selectedGroup?.symbols == [apple, microsoft])

        // An automatic reorder is a UI-only override: it never rewrites the
        // physical source groups.
        let unassignedGroupID = try #require(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.name == "Core" }?.id)
        shared.reorder([microsoft, apple])
        #expect(store.brokeragePortfolio(for: .unassigned)
            .groups.first { $0.id == unassignedGroupID }?.symbols == [apple])
    }


    @MainActor
    @Test("Global group order and selection are UI-only preferences")
    func groupOrderIsLocalOnly() throws {
        let (store, shared, defaults, sharedDefaults, suite) = try makeStores("grouporder")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        let before = store.syncSnapshot()
        let names = shared.groups.map(\.name)
        #expect(names.count >= 2)

        // Groups reorder through moveGroup; the symbol-sort entry point is
        // deliberately not a group API.
        shared.moveGroup(try #require(shared.groups.last).id,
                         relativeTo: try #require(shared.groups.first).id)
        #expect(shared.groups.map(\.name).first == names.last)
        // Financial storage is untouched by a UI-only reorder.
        #expect(store.syncSnapshot() == before)

        // The order survives a new facade.
        let restored = SharedWatchlist(store: store, defaults: sharedDefaults)
        #expect(restored.groups.map(\.name) == shared.groups.map(\.name))
        #expect(restored.groups.map(\.name) != names)
    }


    @MainActor
    @Test("Single-source manual order delegates to the core store")
    func singleSourceOrderDelegatesToCore() throws {
        let (store, shared, defaults, _, suite) = try makeStores("singleorder")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))

        let groupID = try #require(shared.groups.first?.id)
        shared.selectGroup(groupID)
        let members = try #require(shared.selectedGroup).symbols
        let reversed = Array(members.reversed())
        #expect(shared.commitManualMove(orderedSymbols: reversed, movingSymbols: [reversed[0]]))

        // The core store's own group recorded the move, not a UI override.
        let physical = try #require(store.groups.first { $0.id == groupID })
        #expect(physical.symbols == reversed)
    }

    // MARK: - Group lifecycle


    @MainActor
    @Test("Shared group creation, rename, and deletion keep the financial account unchanged")
    func groupLifecycleKeepsAccountUnchanged() throws {
        let (store, shared, defaults, _, suite) = try makeStores("lifecycle")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        #expect(store.selectBrokerageAccount(.financing))

        let activeBefore = store.activeBrokerageAccountID
        let selectedBefore = store.selectedGroupID

        let created = try #require(shared.createGroup(named: "Growth"))
        #expect(shared.groups.contains { $0.id == created })

        // The shared selection moved, not the financial one.
        #expect(shared.selectedGroupID == created)
        #expect(store.activeBrokerageAccountID == activeBefore)
        #expect(store.selectedGroupID == selectedBefore)

        #expect(shared.renameGroup(created, to: "Long Term"))
        #expect(shared.groups.contains { $0.name == "Long Term" })
        #expect(store.activeBrokerageAccountID == activeBefore)

        #expect(shared.deleteGroup(created))
        #expect(shared.groups.contains { $0.id == created } == false)
        #expect(store.activeBrokerageAccountID == activeBefore)
        #expect(store.selectedGroupID == selectedBefore)
    }


    @MainActor
    @Test("Deleting a merged group validates every source and keeps the instruments")
    func deleteMergedGroupKeepsInstruments() throws {
        let (store, shared, defaults, _, suite) = try makeStores("deletemerge")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        // Financing's "Core" is its only list, so the core store would refuse.
        // A merged delete must be all-or-nothing rather than partial.
        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        let before = store.syncSnapshot()
        #expect(shared.deleteGroup(coreID) == false)
        #expect(shared.groups.contains { $0.name == "Core" })
        #expect(store.syncSnapshot() == before, "a refused delete must not write anything")

        // Give every source account a spare list so deletion is valid everywhere.
        // The financial store is the only way to create a list inside a named
        // account, and it is used here purely as test setup.
        #expect(store.selectBrokerageAccount(.financing))
        store.createGroup(named: "Financing Spare")
        #expect(store.selectBrokerageAccount(.unassigned))
        store.createGroup(named: "Unassigned Spare")

        #expect(store.brokeragePortfolio(for: .unassigned).items.contains { $0.symbol == apple })
        #expect(shared.deleteGroup(coreID))
        #expect(shared.groups.contains { $0.name == "Core" } == false)

        // The instruments stay, only the tags are gone.
        #expect(store.brokeragePortfolio(for: .unassigned).items.contains { $0.symbol == apple })
        #expect(store.brokeragePortfolio(for: .financing).items.contains { $0.symbol == microsoft })
    }


    @MainActor
    @Test("Renaming to an existing merged name is refused without writing")
    func renameCollisionRefused() throws {
        let (store, shared, defaults, _, suite) = try makeStores("renamecollision")
        defer { defaults.removePersistentDomain(forName: suite) }

        seedSharedAccounts(store)
        let coreID = try #require(shared.groups.first { $0.name == "Core" }).id
        let before = store.syncSnapshot()

        #expect(shared.renameGroup(coreID, to: "Watchlist") == false)
        #expect(shared.groups.contains { $0.name == "Core" })
        #expect(store.syncSnapshot() == before)
    }

    // MARK: - Disabled brokerage


    @MainActor
    @Test("With brokerage disabled the facade projects only the current portfolio")
    func disabledBrokerageProjectsCurrentOnly() throws {
        let (store, shared, defaults, _, suite) = try makeStores("disabled")
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(store.brokerageAccountsEnabled == false)
        store.add(SymbolInfo(symbol: apple, name: "Apple"))
        store.add(SymbolInfo(symbol: microsoft, name: "Microsoft"))

        #expect(shared.groups.count == 1)
        #expect(Set(try #require(shared.groups.first).symbols) == Set([apple, microsoft]))

        let created = try #require(shared.createGroup(named: "Second"))
        #expect(shared.groups.count == 2)
        shared.add(SymbolInfo(symbol: tencent, name: "Tencent"), to: created)
        #expect(shared.contains(tencent, in: created))
        #expect(store.groups.contains { $0.id == created && $0.symbols == [tencent] })
    }
}
