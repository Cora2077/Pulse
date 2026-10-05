import Foundation
import Testing
@testable import PulseCore

@Suite("Position allocation")
struct PositionAllocationTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private struct V2Snapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        var retainedHistoryItems: [WatchItem]?
    }

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionAllocationTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    @MainActor
    @Test("Legacy positions initialize once from a snapshot and v2 storage upgrades to v3")
    func legacySnapshotInitializesOnce() throws {
        let suite = "PositionAllocationTests.v2.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let legacy = WatchItem(
            symbol: symbol,
            displayName: "Apple",
            lots: [CostLot(price: 100, quantity: 0.3)]
        )
        let v2 = try JSONEncoder().encode(V2Snapshot(
            items: [legacy],
            groups: [group],
            selectedGroupID: group.id,
            retainedHistoryItems: nil
        ))
        defaults.set(v2, forKey: "pulse.watchlists.v2")

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(defaults.data(forKey: "pulse.watchlists.v3") != nil)
        #expect(defaults.data(forKey: "pulse.watchlists.v2") == v2)
        store.initializePositionAllocations()
        let allocation = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(allocation.portions.count == 1)
        #expect(allocation.portions[0].quantity == 0.3)
        #expect(allocation.portions[0].pool == .unassigned)
        #expect(allocation.portions[0].origin.kind == .snapshot)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
        store.initializePositionAllocations()
        #expect(store.item(for: symbol)?.positionAllocation?.revision == allocation.revision)
        #expect(store.item(for: symbol)?.transactions.isEmpty == true)

        let appendedBuy = PositionTransaction(
            kind: .buy,
            price: 120,
            quantity: 0.2,
            date: Date.now.addingTimeInterval(60)
        )
        store.addTransaction(symbol, appendedBuy)
        let afterBuy = try #require(store.item(for: symbol))
        #expect(afterBuy.transactions.count == 2)
        #expect(afterBuy.transactions.last?.id == appendedBuy.id)
        #expect(afterBuy.positionQuantity == 0.5)
        #expect(afterBuy.costBasis == 54)
        #expect(afterBuy.realizedPnL == 0)
        #expect(afterBuy.positionAllocation?.portions.count == 2)
        #expect(afterBuy.positionAllocation?.portions[0].origin.kind == .snapshot)
        #expect(afterBuy.positionAllocation?.portions[0].quantity == 0.3)
        #expect(afterBuy.positionAllocation?.portions[1].origin.transactionID == appendedBuy.id)
        #expect(afterBuy.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Transfers conserve shares, keep source IDs on full moves, split IDs, and undo once")
    func transfersAndOneStepUndo() throws {
        let (store, defaults, suite) = try makeStore("transfer")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 10)
        store.addTransaction(symbol, transaction)
        let before = try #require(store.item(for: symbol)?.positionAllocation)
        let initialID = try #require(before.portions.first?.id)
        let strategic = try store.transferPositionPortion(
            symbol: symbol,
            portionID: initialID,
            quantity: 10,
            to: .strategic,
            reason: "   ",
            expectedRevision: before.revision
        )
        #expect(strategic.portions.count == 1)
        #expect(strategic.portions[0].id == initialID)
        #expect(strategic.changes.last?.reason == "用途调整")

        let moved = try store.transferPositionPortion(
            symbol: symbol,
            portionID: initialID,
            quantity: 2,
            to: .tactical,
            reason: "",
            expectedRevision: strategic.revision
        )
        #expect(moved.portions.count == 2)
        #expect(moved.portions[0].id == initialID)
        #expect(moved.portions[0].quantity == 8)
        #expect(moved.portions[1].id != initialID)
        #expect(moved.portions[1].quantity == 2)
        #expect(moved.portions[0].origin == moved.portions[1].origin)
        #expect(moved.changes.last?.reason == "用途调整")
        #expect(store.item(for: symbol)?.transactions == [transaction])
        #expect(store.item(for: symbol)?.positionQuantity == 10)

        let restored = try store.restorePositionAllocation(
            symbol: symbol,
            previous: strategic,
            expectedRevision: moved.revision
        )
        #expect(restored.portions == strategic.portions)
        #expect(restored.changes.map(\.kind) == [.buy, .transfer, .transfer, .restore])
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
        #expect(throws: PositionAllocationError.noSingleTransferToRestore) {
            try store.restorePositionAllocation(
                symbol: symbol,
                previous: strategic,
                expectedRevision: restored.revision
            )
        }
        let annotated = try store.transferPositionPortion(
            symbol: symbol, portionID: initialID, quantity: 10, to: .tactical,
            reason: "  自愿填写的原因  ", expectedRevision: restored.revision
        )
        #expect(annotated.changes.last?.reason == "自愿填写的原因")
        #expect(annotated.isValid)
    }

    @MainActor
    @Test("Fractional and tiny quantities reject invalid moves without swallowing shares")
    func fractionalTinyAndInvalidQuantities() throws {
        let (store, defaults, suite) = try makeStore("fractional")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 1, quantity: 1e-18))
        let first = try #require(store.item(for: symbol)?.positionAllocation)
        let source = try #require(first.portions.first)
        let updated = try store.transferPositionPortion(
            symbol: symbol,
            portionID: source.id,
            quantity: 2.5e-19,
            to: .strategic,
            reason: "small crypto allocation",
            expectedRevision: first.revision
        )
        #expect(updated.portions.map(\.quantity).reduce(0, +) == 1e-18)
        #expect(updated.portions.contains { $0.quantity == 2.5e-19 })

        let original = try #require(updated.portions.first)
        #expect(throws: PositionAllocationError.invalidQuantity) {
            try store.transferPositionPortion(
                symbol: symbol, portionID: original.id, quantity: .nan, to: .tactical,
                reason: "bad quantity", expectedRevision: updated.revision
            )
        }
        #expect(throws: PositionAllocationError.samePool) {
            try store.transferPositionPortion(
                symbol: symbol, portionID: original.id, quantity: 1e-20, to: .unassigned,
                reason: "same pool", expectedRevision: updated.revision
            )
        }
        #expect(throws: PositionAllocationError.quantityExceedsPortion) {
            try store.transferPositionPortion(
                symbol: symbol, portionID: original.id, quantity: 1e-18, to: .tactical,
                reason: "too much", expectedRevision: updated.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == updated)
    }

    @MainActor
    @Test("Zero and short positions do not initialize or accept allocations")
    func zeroAndShortAreNotApplicable() throws {
        let (store, defaults, suite) = try makeStore("short")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .sell, price: 100, quantity: 1))
        store.initializePositionAllocations()
        let short = try #require(store.item(for: symbol))
        #expect(short.positionQuantity == -1)
        #expect(short.positionAllocation == nil)
        #expect(short.positionAllocationNeedsReconciliation == false)
        #expect(throws: PositionAllocationError.notApplicable) {
            try store.transferPositionPortion(
                symbol: symbol, portionID: UUID(), quantity: 1, to: .strategic,
                reason: "not available", expectedRevision: UUID()
            )
        }
        store.clearPosition(symbol)
        #expect(store.item(for: symbol)?.positionQuantity == 0)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Clean buys gain source cards while sales, calibration, and trade edits require reconciliation")
    func buySourcesAndLedgerChanges() throws {
        let (store, defaults, suite) = try makeStore("sources")
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstBuy = PositionTransaction(
            kind: .buy, price: 100, quantity: 10, date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.addTransaction(symbol, firstBuy)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(initial.portions[0].origin.kind == .buy)
        #expect(initial.portions[0].origin.transactionID == firstBuy.id)

        let secondBuy = PositionTransaction(
            kind: .buy, price: 120, quantity: 2, date: Date(timeIntervalSince1970: 1_700_086_400)
        )
        store.addTransaction(symbol, secondBuy)
        let afterBuy = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(afterBuy.portions.count == 2)
        #expect(afterBuy.portions[1].origin.transactionID == secondBuy.id)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        _ = store.updateTransactionReview(symbol, id: firstBuy.id, note: "entry", review: .init(followedPlan: true))
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        let sell = PositionTransaction(
            kind: .sell, price: 130, quantity: 1, date: Date(timeIntervalSince1970: 1_700_172_800)
        )
        store.addTransaction(symbol, sell)
        #expect(store.item(for: symbol)?.positionQuantity == 11)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == true)
        let sold = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(throws: PositionAllocationError.sourceQuantityExceeded) {
            try store.reconcilePositionAllocation(
                symbol: symbol,
                quantities: [sold.portions[0].id: 11, sold.portions[1].id: 0],
                reason: "must not attribute more shares to a buy than it contained",
                expectedRevision: sold.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == sold)
        let corrected = try store.reconcilePositionAllocation(
            symbol: symbol,
            quantities: [sold.portions[0].id: 9, sold.portions[1].id: 2],
            reason: "confirmed after sale",
            expectedRevision: sold.revision
        )
        #expect(corrected.portions.map(\.quantity).reduce(0, +) == 11)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
        #expect(corrected.portions.allSatisfy { $0.origin.kind == .buy })

        store.calibratePosition(
            symbol, quantity: 14, averageCost: 110,
            date: Date(timeIntervalSince1970: 1_700_259_200)
        )
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == true)
        let calibrated = try #require(store.item(for: symbol)?.positionAllocation)
        let recalibrated = try store.reconcilePositionAllocation(
            symbol: symbol,
            quantities: [calibrated.portions[0].id: 9, calibrated.portions[1].id: 2],
            reason: "broker calibration reviewed",
            expectedRevision: calibrated.revision
        )
        #expect(recalibrated.changes.last?.kind == .sourceInvalidated)
        #expect(recalibrated.portions.map(\.quantity).reduce(0, +) == 14)
        #expect(recalibrated.portions.allSatisfy { $0.origin.kind == .snapshot })
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        var edited = try #require(store.item(for: symbol)?.transactions.first { $0.id == firstBuy.id })
        edited.price = 101
        store.updateTransaction(symbol, edited)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == true)
        #expect(store.item(for: symbol)?.positionQuantity == 14)
    }

    @MainActor
    @Test("Matching fingerprints do not hide broken buy source references")
    func brokenBuySourceRequiresReconciliation() throws {
        let (store, defaults, suite) = try makeStore("broken-source")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 2))
        var item = try #require(store.item(for: symbol))
        var allocation = try #require(item.positionAllocation)
        allocation.portions[0].origin.transactionID = UUID()
        item.positionAllocation = allocation
        #expect(allocation.basisFingerprint == PositionAllocation.basisFingerprint(for: item))

        let snapshot = V2Snapshot(
            items: [item],
            groups: store.groups,
            selectedGroupID: store.selectedGroupID,
            retainedHistoryItems: nil
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "pulse.watchlists.v3")
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let loadedItem = try #require(reloaded.item(for: symbol))
        #expect(loadedItem.positionAllocationNeedsReconciliation)
        #expect(throws: PositionAllocationError.needsReconciliation) {
            try reloaded.transferPositionPortion(
                symbol: symbol,
                portionID: try #require(loadedItem.positionAllocation?.portions.first?.id),
                quantity: 1,
                to: .strategic,
                reason: "should be blocked",
                expectedRevision: try #require(loadedItem.positionAllocation?.revision)
            )
        }
    }

    @MainActor
    @Test("Reconciliation accepts floating tails, preserves confirmed pools, and rejects excess")
    func reconciliationToleranceAndExcess() throws {
        let (store, defaults, suite) = try makeStore("reconcile")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.updateLots(symbol, lots: [CostLot(price: 100, quantity: 0.3)])
        store.initializePositionAllocations()
        var allocation = try #require(store.item(for: symbol)?.positionAllocation)
        let initialPortion = try #require(allocation.portions.first)
        allocation = try store.transferPositionPortion(
            symbol: symbol, portionID: initialPortion.id, quantity: 0.1, to: .strategic,
            reason: "reserve core shares", expectedRevision: allocation.revision
        )
        let values = Dictionary(uniqueKeysWithValues: allocation.portions.enumerated().map { index, portion in
            (portion.id, index == 0 ? 0.1 : 0.2)
        })
        let reconciled = try store.reconcilePositionAllocation(
            symbol: symbol, quantities: values, reason: "verified quantities", expectedRevision: allocation.revision
        )
        #expect(reconciled.portions.map(\.quantity).reduce(0, +) <= 0.3)
        #expect(reconciled.portions.contains { $0.pool == .strategic })
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        let current = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(throws: PositionAllocationError.totalExceedsPosition) {
            try store.reconcilePositionAllocation(
                symbol: symbol,
                quantities: Dictionary(uniqueKeysWithValues: current.portions.map { ($0.id, $0.quantity + 1) }),
                reason: "too many",
                expectedRevision: current.revision
            )
        }
    }

    @MainActor
    @Test("Closing and reopening starts a new buy source and keeps old portions in the audit")
    func flatPositionStartsNewBuySource() throws {
        let (store, defaults, suite) = try makeStore("reopen")
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldBuy = PositionTransaction(kind: .buy, price: 10, quantity: 4)
        store.addTransaction(symbol, oldBuy)
        let oldAllocation = try #require(store.item(for: symbol)?.positionAllocation)
        store.addTransaction(symbol, PositionTransaction(kind: .sell, price: 11, quantity: 4))
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        let newBuy = PositionTransaction(kind: .buy, price: 12, quantity: 2)
        store.addTransaction(symbol, newBuy)
        let current = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(current.portions.count == 1)
        #expect(current.portions[0].origin.transactionID == newBuy.id)
        #expect(current.changes.last?.previousPortions == oldAllocation.portions)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Archive, sync, and backup round trips retain allocations and gate v5/v6")
    func persistenceRoundTrips() throws {
        let (store, defaults, suite) = try makeStore("roundtrip")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 0.3))
        let snapshot = store.syncSnapshot()

        let archive = store.archive()
        #expect(archive.version == 5)
        let decodedArchive = try WatchlistArchive.decoded(from: archive.encoded())
        #expect(decodedArchive.lists[0].entries[0].positionAllocation != nil)

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "pool-test", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 6)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot == snapshot)

        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let backups = LocalBackupStore(bundleIdentifier: "PulseAllocationTests", applicationSupportURL: support)
        let backup = try backups.createBackup(kind: .manual, snapshot: snapshot)
        #expect(try backups.readSnapshot(for: backup) == snapshot)

        let (restored, restoredDefaults, restoredSuite) = try makeStore("archive-restored")
        defer { restoredDefaults.removePersistentDomain(forName: restoredSuite) }
        restored.merge(decodedArchive)
        #expect(restored.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Older archive and sync versions reject allocation fields")
    func olderFormatsRejectAllocationFields() throws {
        let (store, defaults, suite) = try makeStore("version-gate")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 1))

        let encodedArchive = try store.archive().encoded()
        let archiveEncodedData = try #require(encodedArchive.data(using: .utf8))
        var archiveObject = try #require(
            JSONSerialization.jsonObject(with: archiveEncodedData) as? [String: Any]
        )
        archiveObject["version"] = 4
        let modifiedArchiveData = try JSONSerialization.data(withJSONObject: archiveObject)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(5)) {
            try WatchlistArchive.decoded(from: String(decoding: modifiedArchiveData, as: UTF8.self))
        }

        var wireObject = try #require(
            JSONSerialization.jsonObject(with: WatchlistSyncWireCodec.encode(
                deviceID: "pool-test", snapshot: store.syncSnapshot()
            )) as? [String: Any]
        )
        wireObject["version"] = 5
        let wireData = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(6)) {
            try WatchlistSyncWireCodec.decode(wireData)
        }
    }

    @Test("Concurrent allocation edits produce atomic local and remote candidates")
    func syncConflictKeepsWholeCandidates() throws {
        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 10)
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        let originalPortion = PositionPortion(
            quantity: 10,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            )
        )
        let baseAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [originalPortion]
        )
        var localAllocation = baseAllocation
        localAllocation.revision = UUID()
        localAllocation.portions[0].pool = .strategic
        localAllocation.changes.append(.init(
            kind: .transfer, reason: "local", priorRevision: baseAllocation.revision,
            previousPortions: baseAllocation.portions, resultingPortions: localAllocation.portions
        ))
        var remoteAllocation = baseAllocation
        remoteAllocation.revision = UUID()
        remoteAllocation.portions[0].pool = .tactical
        remoteAllocation.changes.append(.init(
            kind: .transfer, reason: "remote", priorRevision: baseAllocation.revision,
            previousPortions: baseAllocation.portions, resultingPortions: remoteAllocation.portions
        ))
        var baseItem = item
        baseItem.positionAllocation = baseAllocation
        var localItem = item
        localItem.positionAllocation = localAllocation
        var remoteItem = item
        remoteItem.positionAllocation = remoteAllocation
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let base = WatchlistSyncSnapshot(items: [baseItem], groups: [group])
        let local = WatchlistSyncSnapshot(items: [localItem], groups: [group])
        let remote = WatchlistSyncSnapshot(items: [remoteItem], groups: [group])

        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(!result.isConflictFree)
        #expect(result.positionAllocationConflicts.count == 1)
        #expect(result.snapshot.items[0].positionAllocation == localAllocation)
        let resolved = WatchlistSyncMerge.resolve(result, choosing: .remote)
        #expect(resolved.items[0].positionAllocation == remoteAllocation)
    }
}
