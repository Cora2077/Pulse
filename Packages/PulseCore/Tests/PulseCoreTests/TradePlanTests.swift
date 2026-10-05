import Foundation
import Testing
@testable import PulseCore

@Suite("Trade plans")
struct TradePlanTests {
    private let symbolA = SymbolID(market: .us, code: "AAPL")
    private let symbolB = SymbolID(market: .us, code: "MSFT")

    private func plan(
        id: UUID = UUID(),
        kind: TradePlan.Kind = .buy,
        price: Double,
        quantity: Double = 100,
        status: TradePlan.Status = .active,
        note: String? = nil,
        updatedAt: TimeInterval = 1_700_000_000,
        positionPool: PositionPool? = nil
    ) -> TradePlan {
        TradePlan(
            id: id,
            kind: kind,
            price: price,
            quantity: quantity,
            status: status,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            positionPool: positionPool
        )
    }

    private func item(_ symbol: SymbolID, plans: [TradePlan] = []) -> WatchItem {
        WatchItem(symbol: symbol, displayName: symbol.displayCode, plans: plans)
    }

    private func snapshot(_ items: [WatchItem], groupID: UUID = UUID()) -> WatchlistSyncSnapshot {
        WatchlistSyncSnapshot(
            items: items,
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: items.map(\.symbol))]
        )
    }

    // MARK: - Derived state (never persisted)

    @Test("A buy is reached by falling to its price, a sell by rising to it")
    func isReachedBoundaries() {
        let buy = plan(kind: .buy, price: 200)
        #expect(buy.isReached(at: 200))          // equality counts
        #expect(buy.isReached(at: 199.99))       // overshot
        #expect(!buy.isReached(at: 200.01))

        let sell = plan(kind: .sell, price: 260)
        #expect(sell.isReached(at: 260))
        #expect(sell.isReached(at: 260.01))
        #expect(!sell.isReached(at: 259.99))

        // A missing quote must not read as "in range".
        #expect(!buy.isReached(at: 0))
        #expect(!sell.isReached(at: 0))
    }

    @Test("The gap shrinks to zero as the quote arrives and never goes negative")
    func gapPercent() {
        let buy = plan(kind: .buy, price: 200)
        #expect(abs(buy.gapPercent(from: 212.6) - 5.934) < 0.01)
        #expect(buy.gapPercent(from: 200) == 0)
        #expect(buy.gapPercent(from: 180) == 0)   // already past it
        #expect(buy.gapPercent(from: 0) == 0)

        let sell = plan(kind: .sell, price: 260)
        #expect(abs(sell.gapPercent(from: 212.6) - 22.29) < 0.01)
        #expect(sell.gapPercent(from: 260) == 0)
        #expect(sell.gapPercent(from: 300) == 0)
    }

    @Test("The money side of the gap folds its sign into a tone")
    func costDelta() {
        let buy = plan(kind: .buy, price: 200)

        // Above the plan price a buy pays more; below it, less. The amount is
        // the same either way round, and only the tone says which is which.
        let aboveBuy = buy.costDelta(from: 212.6)
        #expect(aboveBuy?.tone == .paysMore)
        #expect(abs((aboveBuy?.amount ?? 0) - 1_260) < 0.01)   // (212.6 − 200) × 100

        let belowBuy = buy.costDelta(from: 180)
        #expect(belowBuy?.tone == .paysLess)
        #expect(abs((belowBuy?.amount ?? 0) - 2_000) < 0.01)

        // A sell reads the other way: a lower quote raises less, a higher one
        // raises more.
        let sell = plan(kind: .sell, price: 260)
        let belowSell = sell.costDelta(from: 212.6)
        #expect(belowSell?.tone == .earnsLess)
        #expect(abs((belowSell?.amount ?? 0) - 4_740) < 0.01)  // (260 − 212.6) × 100

        let aboveSell = sell.costDelta(from: 300)
        #expect(aboveSell?.tone == .earnsMore)
        #expect(abs((aboveSell?.amount ?? 0) - 4_000) < 0.01)

        // Sitting exactly on the plan price is not a cost, so there is nothing
        // to print and the caller keeps the percentage alone.
        #expect(buy.costDelta(from: 200) == nil)

        // No quote, no size, or a plan that was never priced: nothing to show
        // rather than a phantom zero.
        #expect(buy.costDelta(from: 0) == nil)
        #expect(buy.costDelta(from: .nan) == nil)
        #expect(plan(kind: .buy, price: 200, quantity: 0).costDelta(from: 210) == nil)
        #expect(plan(kind: .buy, price: 200, quantity: -100).costDelta(from: 210) == nil)
        #expect(plan(kind: .buy, price: 0).costDelta(from: 210) == nil)
    }

    @Test("The stored order is deterministic and buys lead from the nearest price down")
    func orderedIsDeterministic() {
        let low = plan(kind: .buy, price: 185)
        let high = plan(kind: .buy, price: 200)
        let sell = plan(kind: .sell, price: 260)

        let forward = TradePlan.ordered([high, sell, low])
        let reversed = TradePlan.ordered([low, sell, high])
        #expect(forward == reversed)
        #expect(forward.map(\.price) == [200, 185, 260])

        // Same kind and price: the id decides, so two devices agree.
        let first = plan(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, price: 200)
        let second = plan(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, price: 200)
        #expect(TradePlan.ordered([second, first]) == [first, second])
        #expect(TradePlan.ordered([first, second]) == [first, second])
    }

    // MARK: - Three-way merge

    @Test("Concurrent plans added on two devices are both kept, in one shared order")
    func concurrentPlanAdditionsMerge() {
        let groupID = UUID()
        let base = snapshot([item(symbolA)], groupID: groupID)
        let localPlan = plan(kind: .buy, price: 200)
        let remotePlan = plan(kind: .buy, price: 185)
        let local = snapshot([item(symbolA, plans: [localPlan])], groupID: groupID)
        let remote = snapshot([item(symbolA, plans: [remotePlan])], groupID: groupID)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)

        #expect(merged.conflicts.isEmpty)
        #expect(Set(merged.snapshot.items[0].plans.map(\.id)) == [localPlan.id, remotePlan.id])
        #expect(merged.snapshot.items[0].plans.map(\.price) == [200, 185])
    }

    @Test("A deleted plan is not restored from an unchanged stale snapshot")
    func planDeletionWins() {
        let groupID = UUID()
        let existing = plan(kind: .buy, price: 200)
        let base = snapshot([item(symbolA, plans: [existing])], groupID: groupID)
        let local = snapshot([item(symbolA)], groupID: groupID)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base)

        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items[0].plans.isEmpty)
    }

    @Test("Two devices editing one plan settle by updatedAt, on either side, and stay settled")
    func concurrentPlanEditsUseLastWriteWins() {
        let groupID = UUID()
        let id = UUID()
        let original = plan(id: id, price: 200, updatedAt: 1_700_000_000)
        let localEdit = plan(id: id, price: 205, updatedAt: 1_700_000_100)
        let remoteEdit = plan(id: id, price: 210, updatedAt: 1_700_000_200)
        let base = snapshot([item(symbolA, plans: [original])], groupID: groupID)
        let local = snapshot([item(symbolA, plans: [localEdit])], groupID: groupID)
        let remote = snapshot([item(symbolA, plans: [remoteEdit])], groupID: groupID)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        // A plan is a note to self, not money changing hands: it converges
        // instead of stopping to ask which edit to keep.
        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items[0].plans.map(\.price) == [210])

        // The choice does not depend on which device ran the merge.
        let swapped = WatchlistSyncMerge.merge(base: base, local: remote, remote: local)
        #expect(swapped.snapshot == merged.snapshot)

        // Re-merging what we just produced changes nothing, so a converge loop
        // cannot run forever.
        let reapplied = WatchlistSyncMerge.merge(base: base, local: merged.snapshot, remote: remote)
        #expect(reapplied.snapshot == merged.snapshot)
    }

    @Test("A merge pass leaves plans in the order the store itself would keep")
    func mergedOrderMatchesStoredOrder() {
        let groupID = UUID()
        let base = snapshot([item(symbolA)], groupID: groupID)
        let plans = [
            plan(kind: .sell, price: 260),
            plan(kind: .buy, price: 185),
            plan(kind: .buy, price: 200),
        ]
        let local = snapshot([item(symbolA, plans: plans)], groupID: groupID)
        let remote = snapshot([item(symbolA, plans: [])], groupID: groupID)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)

        // Anything but the canonical order would make the peer's snapshot read
        // as changed on every pass and write the sync file for nothing.
        #expect(merged.snapshot.items[0].plans == TradePlan.ordered(plans))
    }

    @Test("A plan survives as dormant history when the list membership was deleted")
    func planFollowsSurvivingTradeIntoDormantHistory() {
        let groupID = UUID()
        let trade = PositionTransaction(
            kind: .buy,
            price: 100,
            quantity: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let existingPlan = plan(kind: .buy, price: 90)
        let base = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbolA, displayName: "AAPL", transactions: [trade], plans: [existingPlan])],
            groups: [WatchlistGroup(id: groupID, name: "Core", symbols: [symbolA])]
        )
        let local = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(id: groupID, name: "Core")],
            retainedHistoryItems: base.items
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base)

        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items.isEmpty)
        #expect(merged.snapshot.retainedHistoryItems.first?.plans.map(\.id) == [existingPlan.id])
    }

    @Test("Plans alone do not resurrect an instrument removed from every list")
    func plansCannotResurrectADeletedItem() {
        let groupID = UUID()
        let base = snapshot([item(symbolA, plans: [plan(kind: .buy, price: 200)])], groupID: groupID)
        let local = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(id: groupID, name: "Core")]
        )

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: base)

        #expect(merged.snapshot.items.isEmpty)
        #expect(merged.snapshot.retainedHistoryItems.isEmpty)
    }

    // MARK: - Persistence

    @Test("A watch item carrying plans survives encoding, and older JSON still decodes")
    func codableRoundTripAndLegacyDecode() throws {
        let oldPlan = plan(kind: .buy, price: 200)
        let oldPlanData = try JSONEncoder().encode(oldPlan)
        let oldPlanObject = try #require(JSONSerialization.jsonObject(with: oldPlanData) as? [String: Any])
        #expect(oldPlanObject["positionPool"] == nil)
        let decodedPlan = try JSONDecoder().decode(TradePlan.self, from: oldPlanData)
        #expect(decodedPlan.positionPool == nil)

        let stored = item(symbolA, plans: [oldPlan, plan(kind: .sell, price: 260)])
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(WatchItem.self, from: data) == stored)

        // A watchlist written before plans existed has no key at all; it has to
        // decode to an empty list rather than failing the whole load.
        let legacy = """
        {"symbol":{"market":"us","code":"AAPL"},"displayName":"Apple","addedAt":0,
         "lots":[],"transactions":[]}
        """
        let decoded = try JSONDecoder().decode(WatchItem.self, from: Data(legacy.utf8))
        #expect(decoded.plans.isEmpty)
        #expect(decoded.thesis == nil)

        let archive = WatchlistArchive(lists: [
            .init(name: "Core", entries: [
                .init(market: .us, code: "AAPL", plans: [oldPlan])
            ])
        ])
        #expect(archive.version == 2)
        #expect(try WatchlistArchive.decoded(from: archive.encoded()).lists[0].entries[0].plans?.first?.positionPool == nil)

        let wire = try WatchlistSyncWireCodec.encode(
            deviceID: "legacy-plan",
            snapshot: snapshot([item(symbolA, plans: [oldPlan])])
        )
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 3)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot.items[0].plans[0].positionPool == nil)
    }

    @MainActor
    @Test("Storing a plan fires the sync callback and keeps the entry's identity")
    func storeWritesAreSyncRelevant() throws {
        let suite = "TradePlanTests.store.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        var callbacks = 0
        store.onLocalSyncChange = { _ in callbacks += 1 }

        store.add(SymbolInfo(symbol: symbolA, name: "Apple"))
        let afterAdd = callbacks

        let created = plan(kind: .buy, price: 200)
        #expect(store.setTradePlan(created, for: symbolA))
        #expect(callbacks == afterAdd + 1)
        let stored = try #require(store.item(for: symbolA)?.plans.first)
        #expect(stored.id == created.id)
        let createdAt = stored.createdAt

        // An edit keeps createdAt and moves updatedAt, which is the field the
        // merge reads.
        var edited = created
        edited.price = 190
        #expect(store.setTradePlan(edited, for: symbolA))
        let updated = try #require(store.item(for: symbolA)?.plans.first)
        #expect(updated.price == 190)
        #expect(updated.createdAt == createdAt)
        #expect(updated.updatedAt > created.updatedAt)

        // Deleting the last one removes it; deleting it again is a no-op.
        #expect(store.deleteTradePlan(created.id, for: symbolA))
        #expect(store.item(for: symbolA)?.plans.isEmpty == true)
        #expect(!store.deleteTradePlan(created.id, for: symbolA))
    }

    @MainActor
    @Test("An index refuses a plan, matching the position rule it inherits")
    func indexCannotHoldAPlan() throws {
        let suite = "TradePlanTests.index.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let index = SymbolID(market: .us, code: "^GSPC")
        store.add(SymbolInfo(symbol: index, name: "S&P 500", type: .index))

        #expect(!store.setTradePlan(plan(kind: .buy, price: 5000), for: index))
        #expect(store.item(for: index)?.plans.isEmpty == true)
    }

    @MainActor
    @Test("Plans travel through the archive, and an import never replaces local ones")
    func archiveCarriesPlans() throws {
        let sourceSuite = "TradePlanTests.archiveSource.\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let source = WatchlistStore(defaults: sourceDefaults, defaultGroupName: "Core")
        source.add(SymbolInfo(symbol: symbolA, name: "Apple"))
        let exported = TradePlan(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .buy,
            price: 200,
            quantity: 500,
            note: "add on the dip",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            positionPool: .strategic
        )
        #expect(source.setTradePlan(exported, for: symbolA))
        // The store stamps `updatedAt` itself — that is the field the merge
        // reads, so a write has to move it.
        let stored = try #require(source.item(for: symbolA)?.plans.first)
        #expect(stored.createdAt == exported.createdAt)
        #expect(stored.updatedAt > exported.updatedAt)
        let locallyReloaded = WatchlistStore(defaults: sourceDefaults, defaultGroupName: "Core")
        #expect(locallyReloaded.item(for: symbolA)?.plans.first?.positionPool == .strategic)

        let text = try source.archive().encoded()
        #expect(source.archive().version == 6)

        // Untouched install: the archive supplies the plan. Compared field by
        // field because the archive's ISO-8601 dates are second-precision.
        let freshSuite = "TradePlanTests.archiveFresh.\(UUID().uuidString)"
        let freshDefaults = try #require(UserDefaults(suiteName: freshSuite))
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let fresh = WatchlistStore(defaults: freshDefaults, defaultGroupName: "Watchlist")
        fresh.merge(try WatchlistArchive.decoded(from: text))
        let imported = try #require(fresh.item(for: symbolA)?.plans.first)
        #expect(imported.id == stored.id)
        #expect(imported.kind == stored.kind)
        #expect(imported.price == stored.price)
        #expect(imported.quantity == stored.quantity)
        #expect(imported.status == stored.status)
        #expect(imported.note == stored.note)
        #expect(imported.createdAt == stored.createdAt)
        #expect(imported.positionPool == .strategic)

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "plan-pool", snapshot: source.syncSnapshot())
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 7)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot.items[0].plans.first?.positionPool == .strategic)

        var archiveObject = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        archiveObject["version"] = 5
        let olderArchiveHeader = try JSONSerialization.data(withJSONObject: archiveObject)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(6)) {
            try WatchlistArchive.decoded(from: String(decoding: olderArchiveHeader, as: UTF8.self))
        }

        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 6
        let olderWireHeader = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(7)) {
            try WatchlistSyncWireCodec.decode(olderWireHeader)
        }

        // Install that already wrote its own plan: the file does not overwrite
        // it, the same rule trades and thesis follow.
        let keptSuite = "TradePlanTests.archiveKept.\(UUID().uuidString)"
        let keptDefaults = try #require(UserDefaults(suiteName: keptSuite))
        defer { keptDefaults.removePersistentDomain(forName: keptSuite) }
        let kept = WatchlistStore(defaults: keptDefaults, defaultGroupName: "Watchlist")
        kept.add(SymbolInfo(symbol: symbolA, name: "Apple"))
        let mine = plan(kind: .sell, price: 300)
        #expect(kept.setTradePlan(mine, for: symbolA))
        kept.merge(try WatchlistArchive.decoded(from: text))
        #expect(kept.item(for: symbolA)?.plans.map(\.id) == [mine.id])
    }

    @Test("A one-sided sync edit carries a plan's intended pool")
    func syncMergePreservesPlanPoolEdit() {
        let groupID = UUID()
        let original = plan(id: UUID(), price: 200, updatedAt: 1_700_000_000)
        var localEdit = original
        localEdit.positionPool = .tactical
        localEdit.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let base = snapshot([item(symbolA, plans: [original])], groupID: groupID)
        let local = snapshot([item(symbolA, plans: [localEdit])], groupID: groupID)
        let remote = snapshot([item(symbolA, plans: [original])], groupID: groupID)

        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(merged.conflicts.isEmpty)
        #expect(merged.snapshot.items[0].plans.first?.positionPool == .tactical)
    }

    @Test("An archive carries plans through its own encoding unchanged")
    func archiveDocumentRoundTripsPlans() throws {
        let archive = WatchlistArchive(
            exportedAt: Date(timeIntervalSince1970: 1_767_225_600),
            app: "Pulse test",
            lists: [.init(name: "Core", entries: [
                .init(
                    market: .us,
                    code: "AAPL",
                    name: "Apple",
                    plans: [plan(kind: .buy, price: 200), plan(kind: .sell, price: 260)]
                )
            ])]
        )
        let text = try archive.encoded()
        #expect(text.contains("\"plans\""))
        #expect(try WatchlistArchive.decoded(from: text) == archive)
    }

    @Test("A sync payload carrying one plan id twice is rejected rather than half-applied")
    func wireCodecRejectsDuplicatePlanIDs() throws {
        let id = UUID()
        let snapshot = WatchlistSyncSnapshot(
            items: [item(symbolA, plans: [plan(id: id, price: 200), plan(id: id, price: 190)])],
            groups: [WatchlistGroup(name: "Core", symbols: [symbolA])]
        )

        #expect(throws: WatchlistSyncWireCodec.CodecError.duplicateTradePlanID(id)) {
            _ = try WatchlistSyncWireCodec.encode(deviceID: "test", snapshot: snapshot)
        }
    }
}
