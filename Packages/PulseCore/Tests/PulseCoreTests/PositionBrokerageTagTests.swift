import Foundation
import Testing
@testable import PulseCore

/// Covers per-card brokerage-account metadata: independently labelling two
/// cards for the same symbol, the derived account attribution the Mac UI reads,
/// the metadata-only change/undo contract, label preservation across every path
/// that copies or splits a portion, and the archive/wire version gates the new
/// field requires.
///
/// Everything here is synthetic and in-memory. No account, credential, or real
/// holding is touched.
@Suite("Position brokerage tag")
struct PositionBrokerageTagTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionBrokerageTagTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    private func buy(
        _ quantity: Double,
        price: Double = 100,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PositionTransaction {
        PositionTransaction(kind: .buy, price: price, quantity: quantity, date: date)
    }

    // MARK: - Per-card labels

    @MainActor
    @Test("Two cards for one symbol in different pools carry independent accounts")
    func independentLabelsOnTwoCards() throws {
        let (store, defaults, suite) = try makeStore("two-cards")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        #expect(initial.portions.first?.brokerageAccountID == nil)

        // Split the single card so one symbol has two pools, then label each.
        let split = try store.transferPositionPortion(
            symbol: symbol, portionID: sourceID, quantity: 4, to: .tactical,
            reason: "trading sleeve", expectedRevision: initial.revision
        )
        #expect(split.portions.count == 2)
        // The split copies the source, and the source was untagged, so both
        // halves still inherit rather than being handed a guessed owner.
        #expect(split.portions.allSatisfy { $0.brokerageAccountID == nil })

        let coreID = try #require(split.portions.first { $0.pool == .unassigned }?.id)
        let tradingID = try #require(split.portions.first { $0.pool == .tactical }?.id)

        let coreTagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: coreID, accountID: .mengmeng,
            expectedRevision: split.revision
        )
        let bothTagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: tradingID, accountID: .financing,
            expectedRevision: coreTagged.revision
        )

        #expect(bothTagged.portions.first { $0.id == coreID }?.brokerageAccountID == .mengmeng)
        #expect(bothTagged.portions.first { $0.id == tradingID }?.brokerageAccountID == .financing)
        #expect(bothTagged.changes.last?.kind == .account)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        let item = try #require(store.item(for: symbol))
        let attribution = item.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.mengmeng]?[.unassigned] == 6)
        #expect(attribution[.financing]?[.tactical] == 4)
        #expect(attribution[.unassigned] == nil)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // The flattened helper agrees with the pool split.
        let totals = item.positionAccountQuantities(enclosingAccountID: .unassigned)
        #expect(totals == [.mengmeng: 6, .financing: 4])
        #expect(totals.values.reduce(0, +) == 10)
        // A deterministic, complete map: both accounts present, no extras.
        #expect(Set(totals.keys) == [.mengmeng, .financing])
    }

    @MainActor
    @Test("Tagging one card touches only its label, revision, and audit entry")
    func singleCardChangePreservesEverythingElse() throws {
        let (store, defaults, suite) = try makeStore("preserve")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(6))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        _ = try store.setPositionConditions(
            symbol: symbol, portionID: sourceID,
            conditions: [TradePlanCondition(title: "thesis", kind: .manual, state: .confirmed)],
            expectedRevision: initial.revision
        )
        let prepared = try #require(store.item(for: symbol)?.positionAllocation)
        let itemBefore = try #require(store.item(for: symbol))

        let tagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .financing,
            expectedRevision: prepared.revision
        )

        #expect(tagged.revision != prepared.revision)
        #expect(tagged.portions.count == prepared.portions.count)
        #expect(tagged.portions.first?.brokerageAccountID == .financing)
        // Every other field on the card survives untouched.
        #expect(tagged.portions.first?.id == prepared.portions.first?.id)
        #expect(tagged.portions.first?.quantity == prepared.portions.first?.quantity)
        #expect(tagged.portions.first?.pool == prepared.portions.first?.pool)
        #expect(tagged.portions.first?.origin == prepared.portions.first?.origin)
        #expect(tagged.portions.first?.note == prepared.portions.first?.note)
        #expect(tagged.portions.first?.fundingSource == prepared.portions.first?.fundingSource)
        #expect(tagged.portions.first?.conditions == prepared.portions.first?.conditions)
        #expect(tagged.basisFingerprint == prepared.basisFingerprint)
        #expect(tagged.changes.count == prepared.changes.count + 1)

        // Only the label differs between the audit's before/after snapshots.
        let last = try #require(tagged.changes.last)
        #expect(last.kind == .account)
        #expect(last.priorRevision == prepared.revision)
        #expect(last.previousPortions.map(\.brokerageAccountID) == [nil])
        #expect(last.resultingPortions.map(\.brokerageAccountID) == [.financing])
        var withoutLabel = last.resultingPortions
        withoutLabel[0].brokerageAccountID = nil
        #expect(withoutLabel == last.previousPortions)

        // The ledger itself is untouched: same transactions, snapshot, lots.
        let itemAfter = try #require(store.item(for: symbol))
        #expect(itemAfter.transactions == itemBefore.transactions)
        #expect(itemAfter.lots == itemBefore.lots)
        #expect(itemAfter.positionQuantity == itemBefore.positionQuantity)
        #expect(itemAfter.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Stale revisions are rejected, including a repeated tag, and a no-op keeps the allocation")
    func staleRevisionAndNoOp() throws {
        let (store, defaults, suite) = try makeStore("stale")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)

        let tagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .financing,
            expectedRevision: initial.revision
        )
        // Repeating the same tag with the old revision is a stale revision.
        #expect(throws: PositionAllocationError.staleRevision(expected: initial.revision, actual: tagged.revision)) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: sourceID, accountID: .financing,
                expectedRevision: initial.revision
            )
        }
        // Repeating it with the current revision is refused as a no-op rather
        // than minting a revision and a change entry.
        #expect(throws: Never.self) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: sourceID, accountID: .financing,
                expectedRevision: tagged.revision
            )
        }
        let afterNoOp = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(afterNoOp == tagged)
        #expect(afterNoOp.revision == tagged.revision)
        #expect(afterNoOp.changes.count == tagged.changes.count)

        // An unknown card is reported rather than silently ignored.
        let missing = UUID()
        #expect(throws: PositionAllocationError.unknownPortion(missing)) {
            try store.setPositionBrokerageAccount(
                symbol: symbol, portionID: missing, accountID: .mengmeng,
                expectedRevision: tagged.revision
            )
        }

        // Moving the label to another account is a real edit again.
        let retagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .mengmeng,
            expectedRevision: tagged.revision
        )
        #expect(retagged.portions.first?.brokerageAccountID == .mengmeng)
        #expect(retagged.changes.last?.kind == .account)
    }

    @MainActor
    @Test("A label change is undone in one step and restores the original attribution")
    func accountChangeUndoesOnce() throws {
        let (store, defaults, suite) = try makeStore("undo")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(3))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        let tagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .financing,
            expectedRevision: initial.revision
        )

        let restored = try store.restorePositionAllocation(
            symbol: symbol, previous: initial, expectedRevision: tagged.revision
        )
        #expect(restored.portions == initial.portions)
        #expect(restored.portions.first?.brokerageAccountID == nil)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    // MARK: - Copy, split, and merge preservation

    @MainActor
    @Test("A partial transfer and a partial funding split both carry the label")
    func splitPathsPreserveLabel() throws {
        let (store, defaults, suite) = try makeStore("split-paths")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        let tagged = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .mengmeng,
            expectedRevision: initial.revision
        )

        // Partial transfer: both the remainder and the moved card keep the label.
        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: sourceID, quantity: 4, to: .tactical,
            reason: "sleeve", expectedRevision: tagged.revision
        )
        #expect(moved.portions.count == 2)
        #expect(moved.portions.allSatisfy { $0.brokerageAccountID == .mengmeng })
        #expect(moved.portions.first { $0.pool == .unassigned }?.quantity == 6)
        #expect(moved.portions.first { $0.pool == .tactical }?.quantity == 4)

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
    }

    @Test("Two copies with incompatible labels never merge into one attribution")
    func incompatibleLabelsDoNotMerge() throws {
        let transaction = buy(10)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        let portion = PositionPortion(
            quantity: 10,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            )
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [portion]
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

        // Whichever side the user picks, the surviving allocation is whole.
        let resolvedRemote = WatchlistSyncMerge.resolve(result, choosing: .remote)
        #expect(resolvedRemote.items[0].positionAllocation?.portions.count == 1)
        #expect(resolvedRemote.items[0].positionAllocation?.portions[0].brokerageAccountID == .financing)
        let resolvedLocal = WatchlistSyncMerge.resolve(result, choosing: .local)
        #expect(resolvedLocal.items[0].positionAllocation?.portions[0].brokerageAccountID == .mengmeng)
    }

    @MainActor
    @Test("A newly purchased card invents no attribution; an existing card keeps its label")
    func buyOriginCarriesOnlyExistingLabels() throws {
        let (store, defaults, suite) = try makeStore("buy-origin")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(4))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        _ = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: sourceID, accountID: .financing,
            expectedRevision: initial.revision
        )
        let afterBuy = try store.addTransactionAndReadBack(symbol, buy(3))

        #expect(afterBuy.positionAllocation?.portions.count == 2)
        // The pre-existing card keeps its label.
        #expect(afterBuy.positionAllocation?.portions.first { $0.id == sourceID }?.brokerageAccountID == .financing)
        // The newly bought card is untagged and therefore inherits.
        let newPortion = try #require(afterBuy.positionAllocation?.portions.first { $0.id != sourceID })
        #expect(newPortion.brokerageAccountID == nil)
        #expect(newPortion.origin.kind == .buy)

        // The untagged card attributes to whatever ledger encloses it.
        let attribution = afterBuy.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.financing]?[.unassigned] == 4)
        #expect(attribution[.unassigned]?[.unassigned] == 3)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == afterBuy.positionQuantity)
    }

    // MARK: - Derived attribution and fallbacks

    @Test("Nil labels inherit the enclosing ledger and every share lands once")
    func nilLabelsInheritEnclosingAccount() throws {
        let transaction = buy(7)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        let untagged = PositionPortion(
            quantity: 4,
            pool: .strategic,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            )
        )
        let explicit = PositionPortion(
            quantity: 3,
            pool: .tactical,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            ),
            brokerageAccountID: .financing
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [untagged, explicit]
        )
        #expect(!item.positionAllocationNeedsReconciliation)

        let attribution = item.positionAccountAttribution(enclosingAccountID: .mengmeng)
        #expect(attribution[.mengmeng]?[.strategic] == 4)
        #expect(attribution[.financing]?[.tactical] == 3)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)
    }

    @Test("A legacy observation card folds into unassigned and still conserves shares")
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
        // legacy record is fully allocated. Its label is honoured and its shares
        // fold into `unassigned` rather than disappearing from the totals.
        #expect(!item.positionAllocationNeedsReconciliation)
        let attribution = item.positionAccountAttribution(enclosingAccountID: .mengmeng)
        #expect(attribution == [.financing: [.unassigned: 5]])
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == item.positionQuantity)

        // Without a label the same legacy card attributes to its enclosing ledger.
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

        // 2. An allocation whose source no longer matches the ledger.
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
            brokerageAccountID: .financing
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

    // MARK: - Persistence and versioning

    @MainActor
    @Test("A tagged allocation raises the archive and sync versions and round trips")
    func taggedPayloadsRoundTrip() throws {
        let (store, defaults, suite) = try makeStore("roundtrip")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        _ = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: try #require(initial.portions.first?.id),
            accountID: .financing, expectedRevision: initial.revision
        )

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
        // not the new tag version.
        let (accountStore, accountDefaults, accountSuite) = try makeStore("untagged-account")
        defer { accountDefaults.removePersistentDomain(forName: accountSuite) }
        #expect(accountStore.enableBrokerageAccounts())
        #expect(accountStore.activeBrokerageAccountID == .unassigned)
        accountStore.addTransaction(symbol, buy(5))
        #expect(accountStore.archive().version == 11)
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "untagged-account", snapshot: accountStore.syncSnapshot())
        ).version == 12)

        // Adding per-account settings on top does not reach the tag version.
        #expect(accountStore.setBrokerageSettings(BrokerageAccountSettings(), for: .unassigned))
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "settings", snapshot: accountStore.syncSnapshot())
        ).version == 13)
    }

    @MainActor
    @Test("A payload declaring an older version is rejected when it carries a label")
    func downgradeRejectsTaggedPayload() throws {
        let (store, defaults, suite) = try makeStore("downgrade")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(5))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        _ = try store.setPositionBrokerageAccount(
            symbol: symbol, portionID: try #require(initial.portions.first?.id),
            accountID: .mengmeng, expectedRevision: initial.revision
        )

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

    @Test("A label surviving only in the change history still requires the new version")
    func historyOnlyLabelRequiresTheNewVersion() throws {
        let transaction = buy(5)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        let untagged = PositionPortion(
            quantity: 5,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            )
        )
        var historicallyTagged = untagged
        historicallyTagged.brokerageAccountID = .financing
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [untagged],
            changes: [PositionAllocation.Change(
                kind: .account, reason: "cleared", previousPortions: [historicallyTagged],
                resultingPortions: [untagged]
            )]
        )
        #expect(item.positionAllocation?.hasBrokerageTagMetadata == true)
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let snapshot = WatchlistSyncSnapshot(items: [item], groups: [group])

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "history-only", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 14)

        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 13
        let downgraded = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(14)) {
            try WatchlistSyncWireCodec.decode(downgraded)
        }

        // The same holds for an archive whose only label is in the history.
        let archive = WatchlistArchive(lists: [
            .init(name: "Core", entries: [.init(market: .us, code: "AAPL", positionAllocation: item.positionAllocation)])
        ])
        #expect(archive.version == 12)
    }

    @MainActor
    @Test("An imported archive keeps each card's label")
    func archiveImportPreservesLabels() throws {
        // Source store: one symbol split across two pools, each tagged to a
        // different account, exported and imported fresh.
        let (source, sourceDefaults, sourceSuite) = try makeStore("import-source")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        source.addTransaction(symbol, buy(10))
        let initial = try #require(source.item(for: symbol)?.positionAllocation)
        let sourceID = try #require(initial.portions.first?.id)
        let split = try source.transferPositionPortion(
            symbol: symbol, portionID: sourceID, quantity: 4, to: .tactical,
            reason: "sleeve", expectedRevision: initial.revision
        )
        let coreID = try #require(split.portions.first { $0.pool == .unassigned }?.id)
        let tradingID = try #require(split.portions.first { $0.pool == .tactical }?.id)
        let coreTagged = try source.setPositionBrokerageAccount(
            symbol: symbol, portionID: coreID, accountID: .mengmeng, expectedRevision: split.revision
        )
        _ = try source.setPositionBrokerageAccount(
            symbol: symbol, portionID: tradingID, accountID: .financing, expectedRevision: coreTagged.revision
        )

        let encoded = try source.archive().encoded()
        let decodedArchive = try WatchlistArchive.decoded(from: encoded)

        let (target, targetDefaults, targetSuite) = try makeStore("import-target")
        defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
        _ = target.merge(decodedArchive)

        let imported = try #require(target.item(for: symbol))
        let attribution = imported.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(attribution[.mengmeng]?[.unassigned] == 6)
        #expect(attribution[.financing]?[.tactical] == 4)
        #expect(attribution.values.flatMap { $0.values }.reduce(0, +) == imported.positionQuantity)

        // The same holds through the sync wire.
        let (peer, peerDefaults, peerSuite) = try makeStore("import-peer")
        defer { peerDefaults.removePersistentDomain(forName: peerSuite) }
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "peer", snapshot: source.syncSnapshot())
        #expect(peer.applySyncSnapshot(try WatchlistSyncWireCodec.decode(wire).snapshot))
        let peerItem = try #require(peer.item(for: symbol))
        let peerAttribution = peerItem.positionAccountAttribution(enclosingAccountID: .unassigned)
        #expect(peerAttribution[.mengmeng]?[.unassigned] == 6)
        #expect(peerAttribution[.financing]?[.tactical] == 4)
    }

    @Test("An untagged mixed history keeps the older version it was written with")
    func untaggedHistoryKeepsOlderVersion() throws {
        let transaction = buy(5)
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        let portion = PositionPortion(
            quantity: 5,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            ),
            conditions: [TradePlanCondition(title: "thesis", kind: .manual, state: .pending)]
        )
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [portion]
        )
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let snapshot = WatchlistSyncSnapshot(items: [item], groups: [group])
        // Verification still outranks the older reasons; the tag threshold adds
        // nothing when no label is present.
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "verification-only", snapshot: snapshot)
        ).version == 11)
    }
}

private extension WatchlistStore {
    /// Records a transaction and hands back the item it produced, so a test can
    /// assert on the derived allocation without a second lookup.
    @MainActor
    func addTransactionAndReadBack(_ symbol: SymbolID, _ transaction: PositionTransaction) throws -> WatchItem {
        addTransaction(symbol, transaction)
        guard let item = item(for: symbol) else { throw PositionAllocationError.itemNotFound(symbol) }
        return item
    }
}
