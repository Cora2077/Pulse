import Foundation
import Testing
@testable import PulseCore

/// Legacy per-portion brokerage-account label compatibility, and the new
/// ownership contract that replaced the label-only setter.
///
/// The stored `PositionPortion.brokerageAccountID` field is now **metadata
/// only**. Account attribution is derived exclusively from the ledger that
/// actually encloses a record, so a label can never move a share, change an
/// account total, or decide where a new trade goes. What this suite pins down:
///
/// - old data that really carries a label still decodes, still round-trips, and
///   still declares the archive/wire version the label requires;
/// - an old label that disagrees with the enclosing ledger is *preserved* but
///   ignored — attribution stays with the real ledger and every share is still
///   counted exactly once;
/// - `setPositionBrokerageAccount` is retired as a write: a request naming a
///   different real account is refused with
///   `accountOwnershipRequiresClassification` and leaves every snapshot byte
///   identical, while asking for the account a card already reads as is a no-op
///   that writes no label, no history, and no revision;
/// - merge, split, funding split, undo, and new-buy paths keep carrying existing
///   labels forward as history, without any of them inventing an owner.
///
/// Legacy fixtures are built as *synthetic old snapshots* and loaded through
/// `applySyncSnapshot`, which is how a real pre-change payload reaches the store.
/// Nothing here re-implements the retired setter to produce its own expectation.
///
/// Everything is synthetic and in-memory, on isolated `UserDefaults` suites. No
/// account, credential, or real holding is touched.
@Suite("Position brokerage tag legacy compatibility")
struct PositionBrokerageTagTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionBrokerageTagTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    /// A store with named accounts on and the same symbol visible in every
    /// ledger, which is the shape a legacy cross-account snapshot loads into.
    @MainActor
    private func makeAccountStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionBrokerageTagTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(store.enableBrokerageAccounts())
        for account in BrokerageAccountID.allCases {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: symbol, name: "Apple"))
            }
        }
        store.selectBrokerageAccount(.unassigned)
        return (store, defaults, suite)
    }

    private func buy(
        _ quantity: Double,
        price: Double = 100,
        date: Date? = nil,
        id: UUID = UUID()
    ) -> PositionTransaction {
        PositionTransaction(id: id, kind: .buy, price: price, quantity: quantity,
                            date: date ?? day, createdAt: date ?? day)
    }

    /// A synthetic *legacy* portion: one that already carries a stored account
    /// label, exactly as a payload written before the ownership change would.
    private func legacyPortion(
        _ quantity: Double,
        pool: PositionPool = .unassigned,
        label: BrokerageAccountID?,
        transaction: PositionTransaction
    ) -> PositionPortion {
        PositionPortion(
            quantity: quantity,
            pool: pool,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            ),
            brokerageAccountID: label
        )
    }

    /// Wraps a legacy allocation into a one-item snapshot. The revision is
    /// deliberately a fresh value: loading normalizes, so a test reads whatever
    /// revision the store actually ended up with rather than assuming this one.
    private func legacySnapshot(
        transactions: [PositionTransaction],
        portions: [PositionPortion],
        changes: [PositionAllocation.Change] = [],
        plans: [TradePlan] = []
    ) -> WatchlistSyncSnapshot {
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: transactions, plans: plans)
        item.positionAllocation = PositionAllocation(
            revision: UUID(),
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: portions,
            changes: changes
        )
        return WatchlistSyncSnapshot(items: [item], groups: [WatchlistGroup(name: "Core", symbols: [symbol])])
    }

    // MARK: - The setter is retired as a write

    @MainActor
    @Test("A request naming a different real account is refused and changes nothing")
    func differentAccountRequestIsRefused() throws {
        let (store, defaults, suite) = try makeStore("refused")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(6))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)
        let before = store.syncSnapshot()

        // The card carries no label and the selected ledger is pending history,
        // so naming a real account asks for a move the label-only writer must
        // not perform: only classifying the recorded trades can do it.
        #expect(throws: PositionAllocationError.accountOwnershipRequiresClassification) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: portionID, accountID: .mengmeng,
                expectedRevision: initial.revision
            )
        }
        #expect(store.syncSnapshot() == before)
        #expect(store.item(for: symbol)?.positionAllocation == initial)
    }

    @MainActor
    @Test("Asking for the account a card already reads as is a no-op write")
    func sameAccountRequestIsANoOp() throws {
        let (store, defaults, suite) = try makeStore("noop")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)
        let before = store.syncSnapshot()

        // The enclosing ledger of this store is pending history, so the value the
        // card already reads as is `.unassigned`. Asking for it is idempotent.
        let returned = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: portionID, accountID: .unassigned,
            expectedRevision: initial.revision
        )
        #expect(returned == initial)
        #expect(returned.revision == initial.revision)
        #expect(returned.changes.count == initial.changes.count)
        #expect(returned.portions.first?.brokerageAccountID == nil)
        #expect(store.syncSnapshot() == before)
    }

    @MainActor
    @Test("Stale revisions and unknown cards are still refused")
    func staleRevisionAndUnknownPortionStillRefused() throws {
        let (store, defaults, suite) = try makeStore("stale")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)

        // The revision guard is checked before the ownership question, so a stale
        // caller is told its view is old rather than that the write is retired.
        let stale = UUID()
        #expect(throws: PositionAllocationError.staleRevision(expected: stale, actual: initial.revision)) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: portionID, accountID: .unassigned,
                expectedRevision: stale
            )
        }
        // An unknown card is reported rather than silently ignored.
        let missing = UUID()
        #expect(throws: PositionAllocationError.unknownPortion(missing)) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: missing, accountID: .unassigned,
                expectedRevision: initial.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == initial)
    }

    @MainActor
    @Test("A legacy label cannot be relabelled or cleared; only a classification moves the record")
    func labelCannotBeRelabelledOrCleared() throws {
        let (store, defaults, suite) = try makeAccountStore("label-move")
        defer { defaults.removePersistentDomain(forName: suite) }
        // A legacy payload states the label `.financing` while the record really
        // sits in pending history. The label is stored history, so the retired
        // writer must leave it exactly where it is.
        let record = buy(4)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [record], portions: [legacyPortion(4, label: .financing, transaction: record)]
        )))
        let loaded = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(loaded.portions.first?.id)
        #expect(loaded.portions.first?.brokerageAccountID == .financing)
        // The store must be reporting the position as fully allocated, or the
        // guards below would answer `needsReconciliation` and the assertions
        // would be testing the wrong refusal.
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
        // Requesting the actual enclosing owner is a no-op. The contradictory
        // historical label remains intact and cannot turn into a new ownership.
        let unchanged = store.syncSnapshot()
        let noOp = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: portionID, accountID: .unassigned, expectedRevision: loaded.revision
        )
        #expect(noOp == loaded)
        #expect(noOp.revision == loaded.revision)
        #expect(noOp.changes.count == loaded.changes.count)
        #expect(noOp.portions.first?.brokerageAccountID == .financing)
        #expect(store.syncSnapshot() == unchanged)
        #expect(throws: PositionAllocationError.accountOwnershipRequiresClassification) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: portionID, accountID: .financing,
                expectedRevision: loaded.revision
            )
        }
        // Moving it to a different real account is refused for the same reason.
        #expect(throws: PositionAllocationError.accountOwnershipRequiresClassification) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: portionID, accountID: .mengmeng,
                expectedRevision: loaded.revision
            )
        }
        #expect(store.syncSnapshot() == unchanged)
    }

    // MARK: - Attribution ignores labels

    @MainActor
    @Test("Two cards with independent legacy labels both attribute to the enclosing ledger")
    func independentLabelsStillAttributeToTheEnclosingLedger() throws {
        let (store, defaults, suite) = try makeAccountStore("two-labels")
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = buy(6)
        let second = buy(4, date: day.addingTimeInterval(60))
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [first, second],
            portions: [
                legacyPortion(6, pool: .unassigned, label: .mengmeng, transaction: first),
                legacyPortion(4, pool: .tactical, label: .financing, transaction: second)
            ]
        )))

        let item = try #require(store.item(for: symbol))
        let loaded = try #require(item.positionAllocation)
        // The labels really survived the load — this is legacy data, not a
        // cleared field, and the payload still declares the version it needs.
        #expect(loaded.portions.map(\.brokerageAccountID) == [.mengmeng, .financing])
        #expect(loaded.hasBrokerageTagMetadata)
        #expect(!item.positionAllocationNeedsReconciliation)

        // Attribution, though, is the ledger the record actually lives in. Both
        // cards are in pending history, so both report there, and the pool split
        // the user really made is retained.
        let attribution = item.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.unassigned]?[.unassigned] == 6)
        #expect(attribution[.unassigned]?[.tactical] == 4)
        #expect(attribution[.mengmeng] == nil)
        #expect(attribution[.financing] == nil)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // Asking about a *real* ledger attributes the whole position there,
        // labels notwithstanding, and still conserves every share.
        let asFinancing = item.positionAccountAttribution(enclosingAccountID: .financing)
        #expect(asFinancing[.financing]?[.unassigned] == 6)
        #expect(asFinancing[.financing]?[.tactical] == 4)
        #expect(asFinancing.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // The flattened helper agrees, and is a complete deterministic map.
        let totals = item.positionAccountQuantities(enclosingAccountID: .financing)
        #expect(totals == [.financing: 10])
        #expect(totals.values.reduce(0, +) == 10)
    }

    @Test("A legacy label on one card cannot split a position across two accounts")
    func labelsCannotSplitAttribution() throws {
        let transaction = buy(7)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [
                legacyPortion(4, pool: .strategic, label: nil, transaction: transaction),
                legacyPortion(3, pool: .tactical, label: .financing, transaction: transaction)
            ]
        )
        #expect(!item.positionAllocationNeedsReconciliation)

        // The untagged card used to "inherit" and the tagged one used to claim
        // its own account. Now both follow the ledger that encloses them.
        let attribution = item.positionAccountAttribution(enclosingAccountID: .mengmeng)
        #expect(attribution[.mengmeng]?[.strategic] == 4)
        #expect(attribution[.mengmeng]?[.tactical] == 3)
        #expect(attribution[.financing] == nil)
        #expect(Set(attribution.keys) == [.mengmeng])
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)
    }

    @Test("A legacy observation card folds into unassigned, label or not")
    func legacyPoolFoldsIntoUnassigned() throws {
        var item = WatchItem(symbol: symbol, displayName: "Apple", lots: [CostLot(price: 100, quantity: 5)])
        let portion = PositionPortion(
            quantity: 5,
            pool: .observation,
            origin: PositionPortion.Origin(kind: .snapshot, date: Date(timeIntervalSince1970: 1_600_000_000)),
            brokerageAccountID: .financing
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [portion]
        )
        // `observation` is retired but still a decodable stored value, so a
        // legacy record is fully allocated. Its shares fold into `unassigned`
        // rather than disappearing from the totals, and its label neither
        // overrides the real ledger nor vanishes from the stored card.
        #expect(!item.positionAllocationNeedsReconciliation)
        #expect(item.positionAllocation?.portions.first?.brokerageAccountID == .financing)
        let attribution = item.positionAccountAttribution(enclosingAccountID: .mengmeng)
        #expect(attribution == [.mengmeng: [.unassigned: 5]])
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // Without a label the same legacy card attributes identically.
        var untagged = item
        untagged.positionAllocation?.portions[0].brokerageAccountID = nil
        #expect(untagged.positionAccountAttribution(enclosingAccountID: .mengmeng) == [.mengmeng: [.unassigned: 5]])
    }

    @Test("Invalid, stale, or partially allocated positions fall back and conserve quantity")
    func invalidAllocationsConserveQuantity() throws {
        let transaction = buy(9)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])

        // 1. No allocation at all.
        #expect(item.positionAccountAttribution(enclosingAccountID: .unassigned) == [.unassigned: [.unassigned: 9]])

        // 2. An allocation whose source no longer matches the ledger. The stale
        //    card also carries a label, which must not rescue it.
        let stalePortion = PositionPortion(
            quantity: 9,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: 999, quantity: transaction.quantity
            ),
            brokerageAccountID: .financing
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [stalePortion]
        )
        #expect(item.positionAccountAttribution(enclosingAccountID: .mengmeng) == [.mengmeng: [.unassigned: 9]])

        // 3. A valid allocation that does not sum to the position.
        let shortPortion = PositionPortion(
            quantity: 4,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: 4
            ),
            brokerageAccountID: .mengmeng
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [shortPortion]
        )
        #expect(item.positionAllocationNeedsReconciliation)
        let fallback = item.positionAccountAttribution(enclosingAccountID: .financing)
        #expect(fallback == [.financing: [.unassigned: 9]])
        #expect(fallback.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // 4. A flat position attributes nothing rather than a zero row.
        var flat = item
        flat.transactions = [buy(9), PositionTransaction(kind: .sell, price: 100, quantity: 9, date: .now)]
        flat.positionAllocation = nil
        #expect(flat.positionAccountAttribution(enclosingAccountID: .unassigned).isEmpty)
    }

    // MARK: - Labels survive the metadata paths

    @MainActor
    @Test("A partial transfer and a partial funding split both carry the legacy label")
    func splitPathsPreserveLabel() throws {
        let (store, defaults, suite) = try makeStore("split-paths")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = buy(10)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [transaction],
            portions: [legacyPortion(10, label: .mengmeng, transaction: transaction)]
        )))
        let loaded = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(loaded.portions.first?.id)
        #expect(loaded.portions.first?.brokerageAccountID == .mengmeng)

        // Partial transfer: both the remainder and the moved card keep the label.
        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: sourceID, quantity: 4, to: .tactical,
            reason: "sleeve", expectedRevision: loaded.revision
        )
        #expect(moved.portions.count == 2)
        #expect(moved.portions.allSatisfy { $0.brokerageAccountID == .mengmeng })
        #expect(moved.portions.first { $0.pool == .unassigned }?.quantity == 6)
        #expect(moved.portions.first { $0.pool == .tactical }?.quantity == 4)
        #expect(moved.portions.reduce(0) { $0 + $1.quantity } == 10)

        // Partial funding split: the same rule, on the other copy path.
        let remainingID = try #require(moved.portions.first { $0.pool == .unassigned }?.id)
        let fundingSplit = try store.markPositionFundingSource(
            symbol: symbol, portionID: remainingID, quantity: 2, source: .margin,
            reason: "borrowed", expectedRevision: moved.revision
        )
        #expect(fundingSplit.portions.count == 3)
        #expect(fundingSplit.portions.allSatisfy { $0.brokerageAccountID == .mengmeng })
        #expect(fundingSplit.portions.first { $0.pool == .unassigned }?.quantity == 4)
        #expect(fundingSplit.portions.first { $0.fundingSource == .margin }?.quantity == 2)
        #expect(fundingSplit.portions.reduce(0) { $0 + $1.quantity } == 10)
        #expect(fundingSplit.hasBrokerageTagMetadata)

        // Every metadata path kept the label readable while the projection still
        // reports the real enclosing ledger and conserves the shares. The funding
        // split added a third card without changing any total: 10 shares over one
        // unassigned card and two tactical cards.
        let item = try #require(store.item(for: symbol))
        let attribution = item.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution.keys.sorted { $0.rawValue < $1.rawValue } == [.unassigned])
        #expect(attribution[.unassigned]?[.unassigned] == 6)
        #expect(attribution[.unassigned]?[.tactical] == 4)
        #expect(attribution[.unassigned]?.values.reduce(0, +) == 10)
        #expect(attribution[.mengmeng] == nil)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)
    }

    @MainActor
    @Test("Undoing a pool move restores the legacy label with the shares")
    func transferUndoRestoresLegacyLabel() throws {
        let (store, defaults, suite) = try makeStore("undo-transfer")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = buy(8)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [transaction],
            portions: [legacyPortion(8, label: .financing, transaction: transaction)]
        )))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)

        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: sourceID, quantity: 3, to: .strategic,
            reason: "sleeve", expectedRevision: initial.revision
        )
        #expect(moved.portions.allSatisfy { $0.brokerageAccountID == .financing })

        let restored = try store.restorePositionAllocation(
            symbol: symbol, previous: initial, expectedRevision: moved.revision
        )
        #expect(restored.portions == initial.portions)
        #expect(restored.portions.first?.brokerageAccountID == .financing)
        #expect(restored.portions.reduce(0) { $0 + $1.quantity } == 8)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
        // The undo is a real change and is recorded as one.
        #expect(restored.changes.last?.kind == .restore)
        #expect(restored.revision != moved.revision)
    }

    @MainActor
    @Test("A newly purchased card invents no label; an existing card keeps its own")
    func buyOriginCarriesOnlyExistingLabels() throws {
        let (store, defaults, suite) = try makeStore("buy-origin")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = buy(4)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [transaction],
            portions: [legacyPortion(4, label: .financing, transaction: transaction)]
        )))
        let before = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(before.portions.first?.id)

        store.addTransaction(symbol, buy(3, date: day.addingTimeInterval(120)))
        let afterBuy = try #require(store.item(for: symbol))

        #expect(afterBuy.positionAllocation?.portions.count == 2)
        // The pre-existing card keeps its label.
        #expect(afterBuy.positionAllocation?.portions.first { $0.id == sourceID }?.brokerageAccountID == .financing)
        // The newly bought card is untagged.
        let newPortion = try #require(afterBuy.positionAllocation?.portions.first { $0.id != sourceID })
        #expect(newPortion.brokerageAccountID == nil)
        #expect(newPortion.origin.kind == .buy)

        // Both cards attribute to the ledger that encloses them, and the whole
        // position is still accounted for exactly once.
        let attribution = afterBuy.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.unassigned]?[.unassigned] == 7)
        #expect(attribution[.financing] == nil)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == afterBuy.positionQuantity)
    }

    @Test("Two copies with incompatible labels never merge into one attribution")
    func incompatibleLabelsDoNotMerge() throws {
        let transaction = buy(10)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [legacyPortion(10, label: nil, transaction: transaction)]
        )
        // Two devices independently label the same untagged card. There is no
        // field-wise merge that would not fabricate an owner, so the difference
        // stays a conflict for the user to resolve.
        var local = item
        local.positionAllocation?.portions[0].brokerageAccountID = .mengmeng
        local.positionAllocation?.revision = UUID()
        var remote = item
        remote.positionAllocation?.portions[0].brokerageAccountID = .financing
        remote.positionAllocation?.revision = UUID()
        let group = WatchlistGroup(name: "Core", symbols: [symbol])

        let result = WatchlistSyncMerge.merge(
            base: WatchlistSyncSnapshot(items: [item], groups: [group]),
            local: WatchlistSyncSnapshot(items: [local], groups: [group]),
            remote: WatchlistSyncSnapshot(items: [remote], groups: [group])
        )
        #expect(result.positionAllocationConflicts.count == 1)
        #expect(!result.isConflictFree)

        // Whichever side the user picks, the surviving allocation is whole and
        // keeps the label that side recorded.
        let resolvedRemote = WatchlistSyncMerge.resolve(result, choosing: .remote)
        #expect(resolvedRemote.items[0].positionAllocation?.portions.count == 1)
        #expect(resolvedRemote.items[0].positionAllocation?.portions[0].brokerageAccountID == .financing)
        let resolvedLocal = WatchlistSyncMerge.resolve(result, choosing: .local)
        #expect(resolvedLocal.items[0].positionAllocation?.portions[0].brokerageAccountID == .mengmeng)

        // Either way the shares still belong to the enclosing ledger, once.
        let chosen = try #require(resolvedRemote.items[0].positionAllocation)
        #expect(chosen.portions.reduce(0) { $0 + $1.quantity } == 10)
        #expect(resolvedRemote.items[0].positionAccountAttribution(enclosingAccountID: .unassigned)
            == [.unassigned: [.unassigned: 10]])
    }

    // MARK: - Persistence and versioning

    @MainActor
    @Test("A legacy-labelled allocation raises the archive and sync versions and round trips")
    func taggedPayloadsRoundTrip() throws {
        let (store, defaults, suite) = try makeStore("roundtrip")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = buy(5)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [transaction],
            portions: [legacyPortion(5, label: .financing, transaction: transaction)]
        )))
        #expect(store.item(for: symbol)?.positionAllocation?.portions.first?.brokerageAccountID == .financing)

        let archive = store.archive()
        #expect(archive.version == 12)
        let decodedArchive = try WatchlistArchive.decoded(from: archive.encoded())
        #expect(decodedArchive.lists[0].entries[0].positionAllocation?.portions.first?.brokerageAccountID == .financing)

        let snapshot = store.syncSnapshot()
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "brokerage-tag", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 14)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot == snapshot)
    }

    @MainActor
    @Test("A store whose labels exist only in legacy history still raises the versions")
    func historyOnlyLabelRequiresTheNewVersion() throws {
        let transaction = buy(5)
        let untagged = legacyPortion(5, label: nil, transaction: transaction)
        var historicallyTagged = untagged
        historicallyTagged.brokerageAccountID = .financing
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        item.positionAllocation = PositionAllocation(
            revision: UUID(),
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [untagged],
            changes: [PositionAllocation.Change(
                kind: .account, reason: "cleared", previousPortions: [historicallyTagged],
                resultingPortions: [untagged]
            )]
        )
        #expect(item.positionAllocation?.hasBrokerageTagMetadata == true)
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let wire = try WatchlistSyncWireCodec.encode(
            deviceID: "history-only",
            snapshot: WatchlistSyncSnapshot(items: [item], groups: [group])
        )
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 14)

        // A payload claiming the older version while carrying the label — even
        // only inside the change log — is rejected rather than downgraded.
        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 13
        let downgraded = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(14)) {
            try WatchlistSyncWireCodec.decode(downgraded)
        }

        // The same holds for an archive whose only label is in the history.
        let archive = WatchlistArchive(lists: [
            .init(name: "Core", entries: [.init(market: .us, code: "AAPL",
                                                positionAllocation: item.positionAllocation)])
        ])
        #expect(archive.version == 12)
    }

    @MainActor
    @Test("Untagged data keeps its original version; raising currentVersion does not advance it")
    func untaggedPayloadsKeepTheirVersion() throws {
        let (store, defaults, suite) = try makeStore("untagged")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        // A plain allocation stays on the allocation versions.
        #expect(store.archive().version == 5)
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "untagged", snapshot: store.syncSnapshot())
        ).version == 6)

        // An account-scoped but untagged store stays on the account thresholds,
        // not the tag version.
        let (accountStore, accountDefaults, accountSuite) = try makeAccountStore("untagged-account")
        defer { accountDefaults.removePersistentDomain(forName: accountSuite) }
        #expect(accountStore.activeBrokerageAccountID == .unassigned)
        accountStore.addTransaction(symbol, buy(5))
        #expect(accountStore.archive().version == 11)
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "untagged-account", snapshot: accountStore.syncSnapshot())
        ).version == 12)

        // Adding non-empty per-account settings on top still does not reach the
        // tag version: the settings threshold (13) is what the payload declares.
        let settings = BrokerageAccountSettings(poolLimits: [
            BrokeragePoolLimit(currency: "USD", pool: .strategic, amount: 1_000)
        ])
        #expect(settings.isValid)
        #expect(accountStore.setBrokerageSettings(settings, for: .unassigned))
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "settings", snapshot: accountStore.syncSnapshot())
        ).version == 13)
    }

    @MainActor
    @Test("A payload declaring an older version is rejected when it carries a label")
    func downgradeRejectsTaggedPayload() throws {
        let (store, defaults, suite) = try makeStore("downgrade")
        defer { defaults.removePersistentDomain(forName: suite) }
        let transaction = buy(5)
        #expect(store.applySyncSnapshot(legacySnapshot(
            transactions: [transaction],
            portions: [legacyPortion(5, label: .mengmeng, transaction: transaction)]
        )))

        // Archive: claim 10 while the payload carries a portion account label.
        let encodedArchive = try store.archive().encoded()
        let archiveData = try #require(encodedArchive.data(using: .utf8))
        var archiveObject = try #require(JSONSerialization.jsonObject(with: archiveData) as? [String: Any])
        archiveObject["version"] = 10
        let downgradedArchive = try JSONSerialization.data(withJSONObject: archiveObject)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(12)) {
            try WatchlistArchive.decoded(from: String(decoding: downgradedArchive, as: UTF8.self))
        }

        // Archive: claim 11 (account-scoped) while still carrying the label.
        archiveObject["version"] = 11
        let accountClaim = try JSONSerialization.data(withJSONObject: archiveObject)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(12)) {
            try WatchlistArchive.decoded(from: String(decoding: accountClaim, as: UTF8.self))
        }

        // Sync: claim 13 while the payload carries a portion account label.
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "downgrade", snapshot: store.syncSnapshot())
        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 13
        let downgradedWire = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(14)) {
            try WatchlistSyncWireCodec.decode(downgradedWire)
        }
    }

    @MainActor
    @Test("An imported archive keeps each card's legacy label")
    func archiveImportPreservesLabels() throws {
        // Source store: one symbol split across two pools, each card carrying a
        // different legacy label, exported and imported fresh.
        let (source, sourceDefaults, sourceSuite) = try makeStore("import-source")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let first = buy(6)
        let second = buy(4, date: day.addingTimeInterval(60))
        #expect(source.applySyncSnapshot(legacySnapshot(
            transactions: [first, second],
            portions: [
                legacyPortion(6, pool: .unassigned, label: .mengmeng, transaction: first),
                legacyPortion(4, pool: .tactical, label: .financing, transaction: second)
            ]
        )))

        let decodedArchive = try WatchlistArchive.decoded(from: source.archive().encoded())
        #expect(decodedArchive.lists[0].entries[0].positionAllocation?.portions
            .map(\.brokerageAccountID) == [.mengmeng, .financing])

        let (target, targetDefaults, targetSuite) = try makeStore("import-target")
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        _ = target.merge(decodedArchive)

        let imported = try #require(target.item(for: symbol))
        #expect(imported.positionAllocation?.portions.map(\.brokerageAccountID) == [.mengmeng, .financing])
        let attribution = imported.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.unassigned]?[.unassigned] == 6)
        #expect(attribution[.unassigned]?[.tactical] == 4)
        #expect(attribution[.mengmeng] == nil)
        #expect(attribution[.financing] == nil)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == imported.positionQuantity)

        // The same holds through the sync wire.
        let (peer, peerDefaults, peerSuite) = try makeStore("import-peer")
        defer { peerDefaults.removePersistentDomain(forName: peerSuite) }
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "peer", snapshot: source.syncSnapshot())
        #expect(peer.applySyncSnapshot(try WatchlistSyncWireCodec.decode(wire).snapshot))
        let peerItem = try #require(peer.item(for: symbol))
        #expect(peerItem.positionAllocation?.portions.map(\.brokerageAccountID) == [.mengmeng, .financing])
        let peerAttribution = peerItem.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(peerAttribution[.unassigned]?[.unassigned] == 6)
        #expect(peerAttribution[.unassigned]?[.tactical] == 4)
        #expect(peerAttribution.values.flatMap { $0.values }.reduce(0, +) == peerItem.positionQuantity)
    }

    @Test("An untagged mixed history keeps the older version it was written with")
    func untaggedHistoryKeepsOlderVersion() throws {
        let transaction = buy(5)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [PositionPortion(
                quantity: 5,
                origin: PositionPortion.Origin(
                    kind: .buy, transactionID: transaction.id, date: transaction.date,
                    price: transaction.price, quantity: transaction.quantity
                ),
                conditions: [TradePlanCondition(title: "thesis", kind: .manual, state: .pending)]
            )]
        )
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        // Verification still outranks the older reasons; the tag threshold adds
        // nothing when no label is present.
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(
                deviceID: "verification-only",
                snapshot: WatchlistSyncSnapshot(items: [item], groups: [group])
            )
        ).version == 11)
    }
}
