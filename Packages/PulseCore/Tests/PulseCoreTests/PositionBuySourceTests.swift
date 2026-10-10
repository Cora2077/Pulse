import Foundation
import Testing
@testable import PulseCore

/// The evidence rules behind source recovery and explicit linking.
///
/// Every fixture here is fictional: made-up tickers, prices, and quantities.
/// Each store runs on its own throwaway `UserDefaults` suite, so no test can see
/// another's — or the user's — records.
@Suite("Position buy sources")
struct PositionBuySourceTests {
    private let symbol = SymbolID(market: .us, code: "ZZQA")

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionBuySourceTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Zeta Quant"))
        return (store, defaults, suite)
    }

    private struct V3Snapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        var retainedHistoryItems: [WatchItem]?
    }

    /// Writes `allocation` onto the stored item the way a reload would find it.
    ///
    /// The production API intentionally has no "set an allocation directly"
    /// entry point, so a test that needs a hand-built allocation goes through
    /// the same `UserDefaults` payload the store reads at launch — exactly the
    /// path a real device takes after the record was written by another build.
    @MainActor
    private func persist(
        allocation: PositionAllocation,
        for item: WatchItem,
        store: WatchlistStore,
        defaults: UserDefaults
    ) throws {
        var updated = item
        updated.positionAllocation = allocation
        let snapshot = V3Snapshot(
            items: [updated],
            groups: store.groups,
            selectedGroupID: store.selectedGroupID,
            retainedHistoryItems: nil
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "pulse.watchlists.v3")
    }

    private func buy(
        _ price: Double,
        _ quantity: Double,
        day: TimeInterval,
        id: UUID = UUID()
    ) -> PositionTransaction {
        PositionTransaction(
            id: id,
            kind: .buy,
            price: price,
            quantity: quantity,
            date: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + day * 86_400)
        )
    }

    // MARK: - Reconciliation scope

    @MainActor
    @Test("An unrelated edit resets only the card whose own source broke")
    func unrelatedEditKeepsUntouchedBuyOrigins() throws {
        let (store, defaults, suite) = try makeStore("scope")
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = buy(41.25, 6, day: 0)
        let second = buy(52.5, 4, day: 1)
        store.addTransaction(symbol, first)
        store.addTransaction(symbol, second)
        let before = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(before.portions.count == 2)
        let secondPortion = try #require(before.portions.first { $0.origin.transactionID == second.id })
        let firstPortion = try #require(before.portions.first { $0.origin.transactionID == first.id })

        // Delete the *first* buy: only its card loses its evidence.
        store.deleteTransaction(symbol, id: first.id)
        let broken = try #require(store.item(for: symbol)?.positionAllocation)
        // Every live card is confirmed; the orphaned one is reconciled to zero.
        let quantities = Dictionary(uniqueKeysWithValues: broken.portions.map { portion in
            (portion.id, portion.id == secondPortion.id ? 4.0 : 0.0)
        })
        let reconciled = try store.reconcilePositionAllocation(
            symbol: symbol,
            quantities: quantities,
            reason: "recorded a broker correction",
            expectedRevision: broken.revision
        )
        let survivor = try #require(reconciled.portions.first { $0.id == secondPortion.id })
        #expect(survivor.origin.kind == .buy)
        #expect(survivor.origin.transactionID == second.id)
        #expect(survivor.origin.price == 52.5)
        #expect(survivor.origin.date == second.date)
        #expect(!reconciled.portions.contains { $0.id == firstPortion.id })
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("A calibration invalidates every origin that preceded it")
    func calibrationInvalidatesPrecedingOrigins() throws {
        let (store, defaults, suite) = try makeStore("calibration")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(30, 5, day: 0))
        store.addTransaction(symbol, buy(44, 5, day: 1))
        let before = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(before.portions.count == 2)
        #expect(before.portions.allSatisfy { $0.origin.kind == .buy })

        store.calibratePosition(
            symbol, quantity: 10, averageCost: 37,
            date: Date(timeIntervalSince1970: 1_800_000_000 + 5 * 86_400)
        )
        let calibrated = try #require(store.item(for: symbol)?.positionAllocation)
        let reconciled = try store.reconcilePositionAllocation(
            symbol: symbol,
            quantities: Dictionary(uniqueKeysWithValues: calibrated.portions.map { ($0.id, $0.quantity) }),
            reason: "reviewed the calibration",
            expectedRevision: calibrated.revision
        )
        #expect(reconciled.changes.last?.kind == .sourceInvalidated)
        #expect(reconciled.portions.allSatisfy { $0.origin.kind == .snapshot })
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    // MARK: - Audit recovery

    @MainActor
    @Test("Split cards recover their original buy through the audit trail")
    func splitCardsRecoverOriginalBuy() throws {
        let (store, defaults, suite) = try makeStore("recovery")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(17.5, 8, day: 0)
        store.addTransaction(symbol, source)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(initial.portions.first?.id)
        let split = try store.transferPositionPortion(
            symbol: symbol, portionID: cardID, quantity: 3, to: .strategic,
            reason: "reserve a third", expectedRevision: initial.revision
        )
        #expect(split.portions.count == 2)
        #expect(split.portions.allSatisfy { $0.origin.transactionID == source.id })

        // Drop the live origins to snapshots, the way a reconciliation would
        // after a ledger edit, while leaving the audit trail intact.
        var allocation = split
        allocation.portions = allocation.portions.map { portion in
            var reset = portion
            reset.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            return reset
        }
        var item = try #require(store.item(for: symbol))
        item.positionAllocation = allocation
        let resolved = allocation.resolvedBuyOrigins(for: item)
        #expect(resolved.count == 2)
        for portion in allocation.portions {
            let origin = try #require(resolved[portion.id])
            #expect(origin.kind == .buy)
            #expect(origin.transactionID == source.id)
            #expect(origin.price == 17.5)
            #expect(origin.quantity == 8)
        }
    }

    @MainActor
    @Test("A card with no historical buy stays unresolved however alike the trades look")
    func noHistoricalBuyMeansNoRecovery() throws {
        let (_, defaults, suite) = try makeStore("no-history")
        defer { defaults.removePersistentDomain(forName: suite) }
        // Two identical, same-priced buys: one is linked, one was never
        // recorded against any card. A snapshot card cannot tell them apart.
        let known = buy(23, 5, day: 0)
        let twin = buy(23, 5, day: 1)
        var item = WatchItem(
            symbol: symbol,
            displayName: "Zeta Quant",
            transactions: [known, twin]
        )
        let orphan = PositionPortion(
            quantity: 5,
            origin: PositionPortion.Origin(kind: .snapshot, date: .now)
        )
        let linked = PositionPortion(
            quantity: 5,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: known.id, date: known.date,
                price: known.price, quantity: known.quantity
            )
        )
        // The audit trail only ever named `known`, and only for the other card.
        var allocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [orphan, linked],
            changes: [.init(
                kind: .buy, reason: "Buy transaction",
                previousPortions: [], resultingPortions: [linked]
            )]
        )
        item.positionAllocation = allocation
        let resolved = allocation.resolvedBuyOrigins(for: item)
        #expect(resolved[linked.id]?.transactionID == known.id)
        #expect(resolved[orphan.id] == nil, "an equal-sized buy is not evidence")

        // Spend the linked buy's capacity entirely: the orphan still gets
        // nothing, proving the twin was never the answer.
        allocation.portions = [
            { var value = orphan; value.quantity = 1; return value }(),
            linked
        ]
        item.positionAllocation = allocation
        #expect(allocation.resolvedBuyOrigins(for: item)[allocation.portions[0].id] == nil)
    }

    @MainActor
    @Test("A deleted or repriced historical buy cannot be recovered")
    func editedOrDeletedHistoryCannotRecover() throws {
        let (store, defaults, suite) = try makeStore("edited-history")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(61, 4, day: 0)
        store.addTransaction(symbol, source)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(initial.portions.first?.id)
        let split = try store.transferPositionPortion(
            symbol: symbol, portionID: cardID, quantity: 1.5, to: .tactical,
            reason: "split", expectedRevision: initial.revision
        )
        var reset = split
        reset.portions = reset.portions.map { portion in
            var value = portion
            value.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            return value
        }

        // The buy was repriced after the audit recorded it.
        var edited = try #require(store.item(for: symbol)?.transactions.first { $0.id == source.id })
        edited.price = 62
        store.updateTransaction(symbol, edited)
        var item = try #require(store.item(for: symbol))
        item.positionAllocation = reset
        #expect(reset.resolvedBuyOrigins(for: item).isEmpty)

        // And it was deleted entirely.
        store.deleteTransaction(symbol, id: source.id)
        item = try #require(store.item(for: symbol))
        item.positionAllocation = reset
        #expect(reset.resolvedBuyOrigins(for: item).isEmpty)
    }

    @Test("The newest historical source wins and never falls back to an older one")
    func newestHistoricalSourceDoesNotFallBack() {
        let older = buy(12, 6, day: 0)
        let newer = buy(19, 6, day: 1)
        var card = PositionPortion(quantity: 6, origin: .init(kind: .snapshot, date: .now))
        var oldCard = card
        oldCard.origin = .init(kind: .buy, transactionID: older.id, date: older.date, price: older.price, quantity: older.quantity)
        var newCard = card
        newCard.origin = .init(kind: .buy, transactionID: newer.id, date: newer.date, price: newer.price, quantity: newer.quantity)
        var item = WatchItem(symbol: symbol, displayName: "Fictional", transactions: [older, newer])
        let allocation = PositionAllocation(basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [card], changes: [
            .init(kind: .reconcile, reason: "old source", previousPortions: [card], resultingPortions: [oldCard]),
            .init(kind: .reconcile, reason: "new source", previousPortions: [oldCard], resultingPortions: [newCard]),
            .init(kind: .sourceInvalidated, reason: "legacy reset", previousPortions: [newCard], resultingPortions: [card])
        ])
        item.positionAllocation = allocation
        #expect(allocation.resolvedBuyOrigins(for: item)[card.id]?.transactionID == newer.id)
        item.transactions[1].price = 20
        #expect(allocation.resolvedBuyOrigins(for: item)[card.id] == nil)
        card.origin.price = .nan
        #expect(!allocation.hasMatchingSource(for: card, item: item))
    }

    @Test("Source selection excludes closed trades and allows buys after calibration")
    func candidatePositionEpoch() {
        let old = buy(10, 4, day: 0)
        let closed = PositionTransaction(kind: .sell, price: 12, quantity: 4, date: old.date.addingTimeInterval(86_400))
        let calibration = PositionTransaction(kind: .adjustment, price: 9, quantity: 2, date: old.date.addingTimeInterval(2 * 86_400))
        let current = buy(11, 3, day: 3)
        let card = PositionPortion(quantity: 2, origin: .init(kind: .snapshot, date: .now))
        let item = WatchItem(symbol: symbol, displayName: "Fictional", transactions: [old, closed, calibration, current])
        let allocation = PositionAllocation(basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [card])
        #expect(allocation.availableBuySources(for: card.id, item: item).map(\.id) == [current.id])
        let roundTrip = WatchItem(symbol: symbol, displayName: "Fictional", transactions: [old, closed, current])
        #expect(allocation.availableBuySources(for: card.id, item: roundTrip).map(\.id) == [current.id])
    }

    // MARK: - Capacity

    @MainActor
    @Test("Capacity keeps one buy from being assigned to every card that fits")
    func capacityStopsDuplicateAssignment() throws {
        let (store, defaults, suite) = try makeStore("capacity")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(28, 6, day: 0)
        store.addTransaction(symbol, source)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(initial.portions.first?.id)
        // Two real cards whose combined claim would exceed the buy once both
        // are pointed at it: 4 + 4 against a buy of 6.
        let split = try store.transferPositionPortion(
            symbol: symbol, portionID: cardID, quantity: 2, to: .strategic,
            reason: "split for capacity", expectedRevision: initial.revision
        )
        let live = try #require(split.portions.first { $0.quantity == 4 })
        let looser = try #require(split.portions.first { $0.quantity == 2 })

        // Only the *live* card keeps its origin; the other becomes a snapshot
        // card whose audit trail still names the same buy.
        var stripped = split
        stripped.portions = stripped.portions.map { portion in
            guard portion.id == looser.id else { return portion }
            var value = portion
            value.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            return value
        }
        stripped.changes.append(.init(
            kind: .reconcile, reason: "provenance cleared",
            priorRevision: split.revision,
            previousPortions: split.portions, resultingPortions: stripped.portions
        ))
        var item = try #require(store.item(for: symbol))
        item.positionAllocation = stripped
        // 4 (live) + 2 (recovered) = 6, exactly the buy: both resolve.
        var resolved = stripped.resolvedBuyOrigins(for: item)
        #expect(resolved[live.id]?.transactionID == source.id)
        #expect(resolved[looser.id]?.transactionID == source.id)

        // Grow the live card to 5. Now 5 + 2 = 7 > 6, so the *snapshot-derived*
        // candidate is withheld while the explicit live link stays.
        var grown = stripped
        grown.portions = grown.portions.map { portion in
            guard portion.id == live.id else { return portion }
            var value = portion
            value.quantity = 5
            return value
        }
        item.positionAllocation = grown
        resolved = grown.resolvedBuyOrigins(for: item)
        #expect(resolved[live.id]?.transactionID == source.id, "an explicit link is not a guess")
        #expect(resolved[looser.id] == nil, "the ambiguous snapshot candidate is withheld")

        // Six shares exist; the live card holds five, so only one is free — and
        // that is too little for the two-share snapshot card.
        let sources = grown.availableBuySources(for: looser.id, item: item)
        #expect(sources.isEmpty, "no capacity is left for a two-share card")

        // Shrink the live card and the remainder covers the snapshot card again.
        var shrunk = stripped
        shrunk.portions = shrunk.portions.map { portion in
            guard portion.id == live.id else { return portion }
            var value = portion
            value.quantity = 3
            return value
        }
        item.positionAllocation = shrunk
        #expect(shrunk.availableBuySources(for: looser.id, item: item).map(\.id) == [source.id])
        #expect(shrunk.resolvedBuyOrigins(for: item)[looser.id]?.transactionID == source.id)
    }

    @MainActor
    @Test("A snapshot card cannot take a buy whose whole quantity is already claimed")
    func overclaimedBuyWithholdsSnapshotCandidates() throws {
        let (store, defaults, suite) = try makeStore("overclaim")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(33, 5, day: 0)
        store.addTransaction(symbol, source)
        var item = try #require(store.item(for: symbol))
        var allocation = try #require(item.positionAllocation)
        let card = try #require(allocation.portions.first)
        // A snapshot card whose audit names the buy, beside a live link that
        // already claims the whole buy.
        var snapshotCard = card
        snapshotCard.id = UUID()
        snapshotCard.quantity = 4
        snapshotCard.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
        var liveClaim = card
        liveClaim.quantity = 4
        allocation.portions = [liveClaim, snapshotCard]
        allocation.changes.append(.init(
            kind: .reconcile, reason: "split recorded",
            previousPortions: [card], resultingPortions: [liveClaim, snapshotCard]
        ))
        item.positionAllocation = allocation
        let resolved = allocation.resolvedBuyOrigins(for: item)
        #expect(resolved[liveClaim.id]?.transactionID == source.id)
        #expect(resolved[snapshotCard.id] == nil)
    }

    // MARK: - Linking

    @MainActor
    @Test("Linking an exact buy preserves every other field, the audit, and the ledger")
    func linkingPreservesSurroundingState() throws {
        let (store, defaults, suite) = try makeStore("link")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(45.5, 7, day: 0)
        store.addTransaction(symbol, source)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(initial.portions.first?.id)
        let planned = try store.transferPositionPortion(
            symbol: symbol, portionID: cardID, quantity: 3, to: .strategic,
            reason: "core", expectedRevision: initial.revision
        )
        let target = try #require(planned.portions.first { $0.quantity == 3 })
        let sibling = try #require(planned.portions.first { $0.quantity == 4 })

        // Force the target card to snapshot, then link it back explicitly.
        var stripped = planned
        stripped.portions = stripped.portions.map { portion in
            guard portion.id == target.id else { return portion }
            var value = portion
            value.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            return value
        }
        stripped.changes.append(.init(
            kind: .reconcile, reason: "provenance cleared",
            priorRevision: planned.revision,
            previousPortions: planned.portions, resultingPortions: stripped.portions
        ))
        stripped.revision = UUID()
        stripped.basisFingerprint = PositionAllocation.basisFingerprint(for: try #require(store.item(for: symbol)))
        try persist(
            allocation: stripped,
            for: try #require(store.item(for: symbol)),
            store: store,
            defaults: defaults
        )
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        // A plan and an unrelated third card are attached *after* the reload, so
        // the assertions below can prove the link left them exactly as they were.
        let plan = TradePlan(
            kind: .buy, price: 40, quantity: 3, status: .active,
            note: "core sleeve", positionPool: .tactical
        )
        #expect(reloaded.setTradePlan(plan, for: symbol))
        let transactionsBefore = try #require(reloaded.item(for: symbol)?.transactions)
        let plansBefore = try #require(reloaded.item(for: symbol)?.plans)
        let before = try #require(reloaded.item(for: symbol)?.positionAllocation)

        let linked = try reloaded.linkPositionPortionToBuy(
            symbol: symbol, portionID: target.id, transactionID: source.id,
            expectedRevision: before.revision
        )
        let linkedCard = try #require(linked.portions.first { $0.id == target.id })
        #expect(linkedCard.origin.kind == .buy)
        #expect(linkedCard.origin.transactionID == source.id)
        #expect(linkedCard.origin.price == 45.5)
        #expect(linkedCard.origin.quantity == 7)
        #expect(linkedCard.origin.date == source.date)

        // Nothing but the origin moved.
        let originalCard = try #require(planned.portions.first { $0.id == target.id })
        #expect(linkedCard.quantity == originalCard.quantity)
        #expect(linkedCard.pool == originalCard.pool)
        #expect(linkedCard.id == originalCard.id)
        #expect(linkedCard.brokerageAccountID == originalCard.brokerageAccountID)
        #expect(linkedCard.fundingSource == originalCard.fundingSource)
        #expect(linkedCard.conditions == originalCard.conditions)
        #expect(linkedCard.note == originalCard.note)
        #expect(linked.portions.first { $0.id == sibling.id } == sibling)
        #expect(linked.changes.last?.kind == .reconcile)
        #expect(linked.changes.last?.reason == "关联买入成交")
        #expect(linked.basisFingerprint == planned.basisFingerprint)
        let after = try #require(reloaded.item(for: symbol))
        #expect(after.transactions == transactionsBefore)
        #expect(after.plans == plansBefore)
        #expect(after.positionAllocationNeedsReconciliation == false)

        // The same link again is a no-op that does not bump the revision.
        let again = try reloaded.linkPositionPortionToBuy(
            symbol: symbol, portionID: target.id, transactionID: source.id,
            expectedRevision: linked.revision
        )
        #expect(again.revision == linked.revision)
        #expect(again == linked)
    }

    @MainActor
    @Test("A linked allocation survives the archive and sync wire round trips")
    func linkedAllocationRoundTrips() throws {
        let (store, defaults, suite) = try makeStore("link-roundtrip")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(58.75, 9, day: 0)
        store.addTransaction(symbol, source)
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(initial.portions.first?.id)
        let split = try store.transferPositionPortion(
            symbol: symbol, portionID: cardID, quantity: 5, to: .tactical,
            reason: "tactical sleeve", expectedRevision: initial.revision
        )
        let moving = try #require(split.portions.first { $0.quantity == 5 })
        var stripped = split
        stripped.portions = stripped.portions.map { portion in
            guard portion.id == moving.id else { return portion }
            var value = portion
            value.origin = PositionPortion.Origin(kind: .snapshot, date: .now)
            return value
        }
        stripped.changes.append(.init(
            kind: .reconcile, reason: "provenance cleared",
            priorRevision: split.revision,
            previousPortions: split.portions, resultingPortions: stripped.portions
        ))
        stripped.revision = UUID()
        stripped.basisFingerprint = PositionAllocation.basisFingerprint(for: try #require(store.item(for: symbol)))
        try persist(
            allocation: stripped,
            for: try #require(store.item(for: symbol)),
            store: store,
            defaults: defaults
        )
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")

        let before = try #require(reloaded.item(for: symbol)?.positionAllocation)
        let linked = try reloaded.linkPositionPortionToBuy(
            symbol: symbol, portionID: moving.id, transactionID: source.id,
            expectedRevision: before.revision
        )

        let decodedArchive = try WatchlistArchive.decoded(from: reloaded.archive().encoded())
        let archived = try #require(decodedArchive.lists.flatMap(\.entries).first { $0.code == symbol.code })
        #expect(archived.positionAllocation == linked)

        let snapshot = reloaded.syncSnapshot()
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "buy-source-test", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot == snapshot)

        let (restored, restoredDefaults, restoredSuite) = try makeStore("link-restored")
        defer { restoredDefaults.removePersistentDomain(forName: restoredSuite) }
        restored.merge(decodedArchive)
        let restoredItem = try #require(restored.item(for: symbol))
        let restoredCard = try #require(restoredItem.positionAllocation?.portions.first { $0.id == moving.id })
        #expect(restoredCard.origin.kind == .buy)
        #expect(restoredCard.origin.transactionID == source.id)
        #expect(restoredItem.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("A stale revision and an unknown buy are both refused without a write")
    func staleRevisionAndUnknownBuyAreAtomic() throws {
        let (store, defaults, suite) = try makeStore("atomic")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(71, 4, day: 0)
        store.addTransaction(symbol, source)
        let allocation = try #require(store.item(for: symbol)?.positionAllocation)
        let cardID = try #require(allocation.portions.first?.id)

        let stale = UUID()
        #expect(throws: PositionAllocationError.staleRevision(expected: stale, actual: allocation.revision)) {
            try store.linkPositionPortionToBuy(
                symbol: symbol, portionID: cardID, transactionID: source.id, expectedRevision: stale
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == allocation)

        #expect(throws: PositionAllocationError.needsReconciliation) {
            try store.linkPositionPortionToBuy(
                symbol: symbol, portionID: cardID, transactionID: UUID(),
                expectedRevision: allocation.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == allocation)

        // A sell is not a buy source, and neither is another ledger's buy.
        store.addTransaction(symbol, PositionTransaction(kind: .sell, price: 80, quantity: 1))
        let sold = try #require(store.item(for: symbol)?.positionAllocation)
        let sellID = try #require(store.item(for: symbol)?.transactions.last?.id)
        #expect(throws: PositionAllocationError.needsReconciliation) {
            try store.linkPositionPortionToBuy(
                symbol: symbol, portionID: cardID, transactionID: sellID,
                expectedRevision: sold.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == sold)

        let foreign = buy(64, 3, day: 9)
        let other = WatchItem(
            symbol: SymbolID(market: .us, code: "ZZQB"),
            displayName: "Zeta Bank",
            transactions: [foreign]
        )
        #expect(other.positionAllocation?.portions.contains { $0.origin.transactionID == foreign.id } != true)
        #expect(throws: PositionAllocationError.needsReconciliation) {
            try store.linkPositionPortionToBuy(
                symbol: symbol, portionID: cardID, transactionID: foreign.id,
                expectedRevision: sold.revision
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == sold)
    }

    // MARK: - Read-only helpers

    @MainActor
    @Test("Source helpers never write to the store")
    func helperReadsDoNotMutate() throws {
        let (store, defaults, suite) = try makeStore("readonly")
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = buy(88, 5, day: 0)
        store.addTransaction(symbol, source)
        let item = try #require(store.item(for: symbol))
        let allocation = try #require(item.positionAllocation)
        let cardID = try #require(allocation.portions.first?.id)
        let storedV3 = defaults.data(forKey: "pulse.watchlists.v3")

        _ = allocation.hasMatchingSources(for: item)
        _ = allocation.hasMatchingSource(for: try #require(allocation.portions.first), item: item)
        _ = allocation.resolvedBuyOrigins(for: item)
        _ = allocation.availableBuySources(for: cardID, item: item)

        #expect(store.item(for: symbol) == item)
        #expect(store.item(for: symbol)?.positionAllocation == allocation)
        #expect(defaults.data(forKey: "pulse.watchlists.v3") == storedV3)
    }

    // MARK: - Per-portion predicate

    @Test("The single-card predicate agrees with the global one, card by card")
    func singleCardPredicateMatchesGlobalRule() {
        let good = buy(15, 4, day: 0)
        let dead = buy(21, 4, day: 1)
        var item = WatchItem(symbol: symbol, displayName: "Zeta Quant", transactions: [good, dead])
        let goodPortion = PositionPortion(
            quantity: 4,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: good.id, date: good.date,
                price: good.price, quantity: good.quantity
            )
        )
        let deadPortion = PositionPortion(
            quantity: 3,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: dead.id, date: dead.date,
                price: dead.price, quantity: dead.quantity
            )
        )
        let allocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [goodPortion, deadPortion]
        )
        item.positionAllocation = allocation
        #expect(allocation.hasMatchingSource(for: goodPortion, item: item))
        #expect(allocation.hasMatchingSource(for: deadPortion, item: item))
        #expect(allocation.hasMatchingSources(for: item))

        // Delete the second buy: the global check fails, and only that card's
        // per-portion check fails with it.
        var trimmed = item
        trimmed.transactions = [good]
        #expect(allocation.hasMatchingSource(for: goodPortion, item: trimmed))
        #expect(!allocation.hasMatchingSource(for: deadPortion, item: trimmed))
        #expect(!allocation.hasMatchingSources(for: trimmed))

        // A structurally broken origin is refused rather than matched loosely.
        var broken = deadPortion
        broken.origin.price = .nan
        #expect(!allocation.hasMatchingSource(for: broken, item: item))
        var negative = deadPortion
        negative.origin.price = -1
        #expect(!allocation.hasMatchingSource(for: negative, item: item))
        var zeroSize = deadPortion
        zeroSize.origin.quantity = 0
        #expect(!allocation.hasMatchingSource(for: zeroSize, item: item))
    }
}
