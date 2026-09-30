import Foundation
import Testing
@testable import PulseCore

@Suite("Watchlist sync merge")
struct WatchlistSyncMergeTests {
    private let symbolA = SymbolID(market: .us, code: "AAPL")
    private let symbolB = SymbolID(market: .us, code: "MSFT")

    private func trade(
        _ id: UUID,
        price: Double,
        date: TimeInterval = 1_700_000_000
    ) -> PositionTransaction {
        PositionTransaction(
            id: id,
            kind: .buy,
            price: price,
            quantity: 1,
            date: Date(timeIntervalSince1970: date),
            createdAt: Date(timeIntervalSince1970: date)
        )
    }

    private func item(
        _ symbol: SymbolID,
        transactions: [PositionTransaction] = []
    ) -> WatchItem {
        WatchItem(symbol: symbol, displayName: symbol.displayCode, transactions: transactions)
    }

    @Test("Initial same-name groups with different IDs coalesce")
    func initialMergeDoesNotDuplicateDefaultGroup() throws {
        let localGroup = WatchlistGroup(name: "Watchlist")
        let remoteGroup = WatchlistGroup(name: "Watchlist", symbols: [symbolA])
        let local = WatchlistSyncSnapshot(items: [], groups: [localGroup])
        let remote = WatchlistSyncSnapshot(items: [item(symbolA)], groups: [remoteGroup])

        let result = WatchlistSyncMerge.merge(
            base: WatchlistSyncSnapshot(items: [], groups: []),
            local: local,
            remote: remote
        )

        #expect(result.conflicts.isEmpty)
        #expect(result.snapshot.groups.count == 1)
        #expect(result.snapshot.groups[0].symbols == [symbolA])
        #expect(result.snapshot.items.map(\.symbol) == [symbolA])
    }

    @Test("Initial same-ID groups merge even when their names changed independently")
    func initialMergeMatchesGroupsByIDBeforeName() throws {
        let groupID = UUID()
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA)],
            groups: [WatchlistGroup(id: groupID, name: "Core local", symbols: [symbolA])]
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolB)],
            groups: [WatchlistGroup(id: groupID, name: "Core remote", symbols: [symbolB])]
        )

        let result = WatchlistSyncMerge.merge(
            base: WatchlistSyncSnapshot(items: [], groups: []),
            local: local,
            remote: remote
        )

        #expect(result.conflicts.isEmpty)
        #expect(result.snapshot.groups.count == 1)
        #expect(Set(result.snapshot.groups[0].symbols) == [symbolA, symbolB])
    }

    @Test("Independent two-device edits preserve additions, membership, pins, and trades")
    func independentDeviceEditsMerge() throws {
        let groupID = UUID()
        let baseTrade = trade(UUID(), price: 100)
        let remoteTrade = trade(UUID(), price: 110, date: 1_700_000_100)
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [baseTrade])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [baseTrade]), item(symbolB)],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolB, symbolA])]
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [baseTrade, remoteTrade])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA], pinnedSymbols: [symbolA])]
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)

        #expect(merged.conflicts.isEmpty)
        #expect(Set(merged.snapshot.groups[0].symbols) == [symbolA, symbolB])
        #expect(merged.snapshot.groups[0].pinnedSymbols == [symbolA])
        #expect(merged.snapshot.items.first { $0.symbol == symbolA }?.transactions.map(\.id) == [baseTrade.id, remoteTrade.id])
        #expect(merged.snapshot.items.contains { $0.symbol == symbolB })
    }

    @Test("A deleted transaction is not restored from an unchanged stale snapshot")
    func deletionBeatsStaleTransaction() throws {
        let groupID = UUID()
        let existing = trade(UUID(), price: 100)
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [existing])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA)],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base)

        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items.first?.transactions.isEmpty == true)
    }

    @Test("Concurrent new trades with different IDs are both retained")
    func concurrentTradesMerge() throws {
        let groupID = UUID()
        let existing = trade(UUID(), price: 100)
        let localTrade = trade(UUID(), price: 105, date: 1_700_000_100)
        let remoteTrade = trade(UUID(), price: 110, date: 1_700_000_200)
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [existing])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [existing, localTrade])],
            groups: base.groups
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [existing, remoteTrade])],
            groups: base.groups
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)

        #expect(merged.conflicts.isEmpty)
        #expect(Set(merged.snapshot.items[0].transactions.map(\.id)) == [existing.id, localTrade.id, remoteTrade.id])
    }

    @Test("Equal-timestamp replay keeps stored order and remains stable across merges")
    func equalTimestampMergeKeepsStoredOrder() throws {
        let stamp = Date(timeIntervalSince1970: 1_787_000_000)
        let buy = PositionTransaction(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            kind: .buy, price: 100, quantity: 10, date: stamp, createdAt: stamp
        )
        let adjustment = PositionTransaction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            kind: .adjustment, price: 80, quantity: 20, date: stamp, createdAt: stamp
        )
        let snapshot = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [buy, adjustment])],
            groups: []
        )

        let first = WatchlistSyncMerge.merge(base: snapshot, local: snapshot, remote: snapshot).snapshot
        let repeated = WatchlistSyncMerge.merge(base: snapshot, local: first, remote: snapshot).snapshot
        let mergedItem = try #require(first.items.first)

        #expect(mergedItem.transactions.map(\.id) == [buy.id, adjustment.id])
        #expect(PositionLedger(transactions: mergedItem.transactions).quantity == 20)
        #expect(PositionLedger(transactions: mergedItem.transactions).averageCost == 80)
        #expect(repeated == first)
    }

    @Test("Stable fallback orders only concurrent entries without breaking a source order")
    func concurrentUnorderedTradesKeepSourceOrder() throws {
        let stamp = Date(timeIntervalSince1970: 1_787_000_000)
        func trade(_ id: String) -> PositionTransaction {
            PositionTransaction(
                id: UUID(uuidString: id)!, kind: .buy, price: 100, quantity: 1,
                date: stamp, createdAt: stamp
            )
        }
        let firstLocal = trade("ffffffff-ffff-ffff-ffff-ffffffffffff")
        let secondLocal = trade("00000000-0000-0000-0000-000000000001")
        let concurrentRemote = trade("88888888-8888-8888-8888-888888888888")
        let base = WatchlistSyncSnapshot(items: [], groups: [])
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [firstLocal, secondLocal])], groups: []
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [concurrentRemote])], groups: []
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let swapped = WatchlistSyncMerge.merge(base: base, local: remote, remote: local).snapshot
        let ids = try #require(merged.items.first).transactions.map(\.id)

        #expect(ids.firstIndex(of: firstLocal.id)! < ids.firstIndex(of: secondLocal.id)!)
        #expect(swapped == merged)
    }

    @Test("Choosing remote restores a conflicted trade to its original replay position")
    func resolvingDeletedTradePreservesItsOrder() throws {
        let stamp = Date(timeIntervalSince1970: 1_787_000_000)
        let buyID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let adjustmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let buy = PositionTransaction(
            id: buyID, kind: .buy, price: 100, quantity: 10, date: stamp, createdAt: stamp
        )
        let editedBuy = PositionTransaction(
            id: buyID, kind: .buy, price: 110, quantity: 10, date: stamp, createdAt: stamp
        )
        let adjustment = PositionTransaction(
            id: adjustmentID, kind: .adjustment, price: 80, quantity: 20,
            date: stamp, createdAt: stamp
        )
        let base = WatchlistSyncSnapshot(items: [item(symbolA, transactions: [buy, adjustment])], groups: [])
        let local = WatchlistSyncSnapshot(items: [item(symbolA, transactions: [adjustment])], groups: [])
        let remote = WatchlistSyncSnapshot(items: [item(symbolA, transactions: [editedBuy, adjustment])], groups: [])

        let conflict = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        let resolved = WatchlistSyncMerge.resolve(conflict, choosing: .remote)
        let transactions = try #require(resolved.items.first).transactions

        #expect(conflict.conflicts.count == 1)
        #expect(transactions.map(\.id) == [buyID, adjustmentID])
        #expect(transactions.first?.price == 110)
        #expect(PositionLedger(transactions: transactions).quantity == 20)
        #expect(PositionLedger(transactions: transactions).averageCost == 80)
    }

    @Test("Incompatible edits to the same trade are reported and can choose remote")
    func conflictingTradeCanBeResolved() throws {
        let groupID = UUID()
        let id = UUID()
        let original = trade(id, price: 100)
        let localTrade = trade(id, price: 105)
        let remoteTrade = trade(id, price: 110)
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [original])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [localTrade])],
            groups: base.groups
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [remoteTrade])],
            groups: base.groups
        )

        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(result.conflicts.count == 1)
        #expect(result.snapshot.items[0].transactions.first?.price == 105)

        let resolved = WatchlistSyncMerge.resolve(result, choosing: .remote)
        #expect(resolved.items[0].transactions.first?.price == 110)
        #expect(resolved.items[0].lots.first?.price == 110)
    }

    @Test("Choosing deletion of the last conflicting trade clears its derived lot")
    func resolvingLastTradeDeletionClearsDerivedLot() throws {
        let groupID = UUID()
        let id = UUID()
        let original = trade(id, price: 100)
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [original])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [trade(id, price: 105)])],
            groups: base.groups
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA)],
            groups: base.groups
        )

        let conflict = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(conflict.conflicts.count == 1)
        let resolved = WatchlistSyncMerge.resolve(conflict, choosing: .remote)

        #expect(resolved.items[0].transactions.isEmpty)
        #expect(resolved.items[0].lots.isEmpty)
        #expect(resolved.items[0].hasPosition == false)
    }

    @Test("A local deletion against a remote trade edit drops the stale lot cache")
    func localTradeDeletionBeatsEditedRemoteWithoutStaleLot() throws {
        let groupID = UUID()
        let transactionID = UUID()
        let lotID = UUID()
        let original = trade(transactionID, price: 100)
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbolA,
                displayName: "AAPL",
                lots: [CostLot(id: lotID, price: 100, quantity: 1)],
                transactions: [original]
            )],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [item(symbolA)],
            groups: base.groups
        )
        let remote = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbolA,
                displayName: "AAPL",
                lots: [CostLot(id: lotID, price: 105, quantity: 1)],
                transactions: [trade(transactionID, price: 105)]
            )],
            groups: base.groups
        )

        let conflict = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(conflict.conflicts.count == 1)
        #expect(conflict.snapshot.items[0].transactions.isEmpty)
        #expect(conflict.snapshot.items[0].lots.isEmpty)

        let resolved = WatchlistSyncMerge.resolve(conflict, choosing: .local)
        #expect(resolved.items[0].transactions.isEmpty)
        #expect(resolved.items[0].lots.isEmpty)
        #expect(resolved.items[0].hasPosition == false)
    }

    @Test("Choosing a remote edit after local item deletion keeps dormant history and metadata")
    func remoteTradeEditSurvivesLocalItemDeletion() throws {
        let groupID = UUID()
        let transactionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let original = trade(transactionID, price: 100)
        let edited = trade(transactionID, price: 105)
        let baseGroup = WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbolA,
                displayName: "Old name",
                instrumentType: .equity,
                addedAt: timestamp,
                transactions: [original]
            )],
            groups: [baseGroup]
        )
        let local = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(id: groupID, name: "Core")]
        )
        let remote = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbolA,
                displayName: "Apple",
                instrumentType: .equity,
                addedAt: timestamp,
                transactions: [edited]
            )],
            groups: [baseGroup]
        )

        let conflict = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(conflict.conflicts.count == 1)
        #expect(conflict.snapshot.items.isEmpty)
        #expect(conflict.snapshot.groups[0].symbols.isEmpty)
        #expect(conflict.snapshot.retainedHistoryItems.first?.transactions.isEmpty == true)

        let resolved = WatchlistSyncMerge.resolve(conflict, choosing: .remote)
        #expect(resolved.items.isEmpty)
        #expect(resolved.groups[0].symbols.isEmpty)
        #expect(resolved.retainedHistoryItems.first?.displayName == "Apple")
        #expect(resolved.retainedHistoryItems.first?.instrumentType == .equity)
        #expect(resolved.retainedHistoryItems.first?.addedAt == timestamp)
        #expect(resolved.retainedHistoryItems.first?.transactions == [edited])
    }

    @Test("Derived lot identity is stable across repeated and swapped merges")
    func derivedLotIdentityIsStable() throws {
        let groupID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let transaction = trade(UUID(), price: 100)
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbolA, displayName: "AAPL", addedAt: timestamp)],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let changedItem = WatchItem(
            symbol: symbolA,
            displayName: "AAPL",
            addedAt: timestamp,
            transactions: [transaction]
        )
        let local = WatchlistSyncSnapshot(items: [changedItem], groups: base.groups)
        let remote = WatchlistSyncSnapshot(items: [changedItem], groups: base.groups)

        let first = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let repeated = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let reapplied = WatchlistSyncMerge.merge(base: base, local: first, remote: remote).snapshot
        let swapped = WatchlistSyncMerge.merge(base: base, local: remote, remote: local).snapshot

        #expect(first.items[0].lots.count == 1)
        #expect(first.items[0].lots[0].id == repeated.items[0].lots[0].id)
        #expect(first == repeated)
        #expect(first == reapplied)
        #expect(first == swapped)
    }

    @Test("Removing membership against an unchanged peer does not resurrect it")
    func removedMembershipBeatsStaleGroup() throws {
        let groupID = UUID()
        let retained = item(symbolA, transactions: [trade(UUID(), price: 100)])
        let base = WatchlistSyncSnapshot(
            items: [retained],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(id: groupID, name: "Core")],
            retainedHistoryItems: [retained]
        )
        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base)

        #expect(merged.snapshot.groups[0].symbols.isEmpty)
        #expect(merged.snapshot.items.isEmpty)
        #expect(merged.snapshot.retainedHistoryItems.map(\.symbol) == [symbolA])
    }

    @Test("A concurrent trade survives as dormant history when the list membership was deleted")
    func concurrentTradeDoesNotRestoreDeletedMembership() throws {
        let groupID = UUID()
        let baseItem = item(symbolA)
        let newTrade = trade(UUID(), price: 100)
        let base = WatchlistSyncSnapshot(
            items: [baseItem],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(id: groupID, name: "Core")]
        )
        let remote = WatchlistSyncSnapshot(
            items: [item(symbolA, transactions: [newTrade])],
            groups: base.groups
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)

        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.groups[0].symbols.isEmpty)
        #expect(merged.snapshot.items.isEmpty)
        #expect(merged.snapshot.retainedHistoryItems.first?.transactions.map(\.id) == [newTrade.id])
    }

    @Test("Store sync callback fires on local writes but not selection or remote apply")
    @MainActor
    func callbackScope() throws {
        let suite = "WatchlistSyncMergeTests.callback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        var callbacks: [WatchlistSyncSnapshot] = []
        store.onLocalSyncChange = { callbacks.append($0) }

        store.add(SymbolInfo(symbol: symbolA, name: "Apple"))
        #expect(callbacks.count == 1)
        let originalGroup = try #require(store.groups.first?.id)
        let otherGroup = try #require(store.createGroup(named: "Other"))
        let countAfterLocalWrites = callbacks.count
        store.selectGroup(originalGroup)
        #expect(callbacks.count == countAfterLocalWrites)
        store.selectGroup(otherGroup)
        #expect(callbacks.count == countAfterLocalWrites)

        var remote = store.syncSnapshot()
        remote.items.append(item(symbolB))
        #expect(store.applySyncSnapshot(remote))
        #expect(callbacks.count == countAfterLocalWrites)
    }

    @Test("Snapshots retain full trade and dormant history data through Codable")
    func snapshotCodableRoundTrip() throws {
        let tx = trade(UUID(), price: 12.5)
        let dormant = item(symbolA, transactions: [tx])
        let snapshot = WatchlistSyncSnapshot(
            items: [item(symbolB)],
            groups: [WatchlistGroup(name: "Core", symbols: [symbolB], manualOrder: [symbolB], pinnedSymbols: [symbolB])],
            retainedHistoryItems: [dormant]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WatchlistSyncSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("Independent drawing additions merge and remain stable on repeat")
    func independentDrawingAdditionsMerge() throws {
        let base = WatchlistSyncSnapshot(
            items: [item(symbolA)],
            groups: [WatchlistGroup(name: "Core", symbols: [symbolA])]
        )
        let first = ChartDrawing(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            geometry: .horizontal(price: 100),
            createdAt: Date(timeIntervalSince1970: 10)
        )
        let second = ChartDrawing(
            id: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
            geometry: .horizontal(price: 110),
            createdAt: Date(timeIntervalSince1970: 20)
        )
        var localItem = item(symbolA)
        localItem.drawings = [first]
        var remoteItem = item(symbolA)
        remoteItem.drawings = [second]
        let local = WatchlistSyncSnapshot(items: [localItem], groups: base.groups)
        let remote = WatchlistSyncSnapshot(items: [remoteItem], groups: base.groups)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let repeated = WatchlistSyncMerge.merge(base: base, local: merged, remote: remote).snapshot
        let drawings = try #require(merged.items.first).drawings

        #expect(Set(drawings.map(\.id)) == [first.id, second.id])
        #expect(drawings == ChartDrawing.ordered([first, second]))
        #expect(repeated == merged)
    }

    @Test("A drawing tombstone beats a concurrent edit and cannot be resurrected")
    func drawingDeletionBeatsConcurrentEdit() throws {
        let groupID = UUID()
        let original = ChartDrawing(
            id: UUID(),
            geometry: .horizontal(price: 100),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        var tombstone = original
        tombstone.deletedAt = Date(timeIntervalSince1970: 30)
        tombstone.updatedAt = Date(timeIntervalSince1970: 30)
        var edit = original
        edit.geometry = .horizontal(price: 120)
        edit.updatedAt = Date(timeIntervalSince1970: 200)

        var baseItem = item(symbolA)
        baseItem.drawings = [original]
        var localItem = item(symbolA)
        localItem.drawings = [tombstone]
        var remoteItem = item(symbolA)
        remoteItem.drawings = [edit]
        let base = WatchlistSyncSnapshot(
            items: [baseItem],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(items: [localItem], groups: base.groups)
        let remote = WatchlistSyncSnapshot(items: [remoteItem], groups: base.groups)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote).snapshot
        let swapped = WatchlistSyncMerge.merge(base: base, local: remote, remote: local).snapshot
        let result = try #require(merged.items.first?.drawings.first)

        #expect(result.isDeleted)
        #expect(result.deletedAt == tombstone.deletedAt)
        #expect(swapped == merged)
        #expect(WatchlistSyncMerge.merge(base: base, local: merged, remote: remote).snapshot == merged)
    }

    @Test("A legacy peer's missing drawing field carries no deletion information")
    func missingDrawingFieldIsNotDeletion() throws {
        let drawing = ChartDrawing(geometry: .horizontal(price: 100))
        var fullItem = item(symbolA)
        fullItem.drawings = [drawing]
        var legacyItem = fullItem
        legacyItem.drawings = []
        let group = WatchlistGroup(name: "Core", symbols: [symbolA])
        let base = WatchlistSyncSnapshot(items: [fullItem], groups: [group])
        let local = WatchlistSyncSnapshot(items: [legacyItem], groups: [group])

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base).snapshot

        #expect(merged.items.first?.drawings == [drawing])
    }
}
