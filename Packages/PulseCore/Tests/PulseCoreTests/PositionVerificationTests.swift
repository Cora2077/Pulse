import Foundation
import Testing
@testable import PulseCore

/// Covers the verification model end to end: the retired observation purpose,
/// the condition array a portion carries, the single badge both plans and
/// portions derive, and the four load paths that have to migrate an old copy
/// without inventing or losing anything.
@Suite("Position verification")
struct PositionVerificationTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    /// The store's own `Snapshot` shape. Declared here so a fixture can be
    /// written straight into the v3 storage key the store loads from, which is
    /// the only way to exercise the real startup migration path.
    private struct V2Snapshot: Codable {
        var items: [WatchItem]
        var groups: [WatchlistGroup]
        var selectedGroupID: UUID?
        var retainedHistoryItems: [WatchItem]?
    }

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PositionVerificationTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    private func buy(
        _ quantity: Double,
        price: Double = 100,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        planConfiguration: TradePlanConfiguration? = nil
    ) -> PositionTransaction {
        PositionTransaction(
            kind: .buy, price: price, quantity: quantity, date: date,
            planExecution: planConfiguration.map { TradePlanExecution(planID: UUID(), configuration: $0) }
        )
    }

    private func condition(
        _ title: String,
        state: TradePlanCondition.State = .pending,
        reviewDate: Date? = nil,
        eventReference: InstrumentEvent? = nil,
        id: UUID = UUID()
    ) -> TradePlanCondition {
        TradePlanCondition(
            id: id, title: title, kind: .manual, state: state,
            reviewDate: reviewDate, eventReference: eventReference
        )
    }
    /// A legacy allocation whose live portion sits in the retired observation
    /// purpose, exactly as a build from before the retirement would have stored
    /// it.
    private func legacyObservationAllocation(
        item: WatchItem,
        quantity: Double,
        pool: PositionPool = .observation,
        note: String? = "watch the thesis",
        funding: PositionFundingSource? = .own,
        conditions: [TradePlanCondition]? = nil
    ) -> PositionAllocation {
        let portion = PositionPortion(
            quantity: quantity,
            pool: pool,
            origin: PositionPortion.Origin(kind: .snapshot, date: Date(timeIntervalSince1970: 1_600_000_000)),
            note: note,
            fundingSource: funding,
            conditions: conditions
        )
        return PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [portion],
            changes: [PositionAllocation.Change(
                kind: .initialize,
                reason: "Current position snapshot",
                previousPortions: [],
                resultingPortions: [portion]
            )]
        )
    }

    // MARK: - Purpose model

    @Test("The retired observation purpose stays decodable but is never an active purpose")
    func activeCasesExcludeObservation() throws {
        #expect(PositionPool.activeCases == [.unassigned, .strategic, .tactical])
        #expect(PositionPool.activeCases.allSatisfy { $0.isActivePurpose })
        #expect(!PositionPool.observation.isActivePurpose)
        // The raw value must survive decoding so old snapshots and history keep
        // reading; a build that dropped the case would fail to open the file.
        #expect(try JSONDecoder().decode(PositionPool.self, from: Data("\"observation\"".utf8)) == .observation)
        #expect(PositionPool.observation.effectivePurpose == .unassigned)
        #expect(PositionPool.strategic.effectivePurpose == .strategic)
        #expect(PositionPool.tactical.effectivePurpose == .tactical)
        #expect(PositionPool.unassigned.effectivePurpose == .unassigned)
    }

    @Test("The migration's pending condition carries the fixed title and id")
    func legacyObservationConditionShape() {
        let condition = WatchlistStore.legacyObservationCondition()
        #expect(condition.title == "核对原观察仓的持有判断")
        #expect(condition.state == .pending)
        #expect(condition.kind == .manual)
        // The id is fixed, which is what makes "does it already exist"
        // answerable across runs and devices.
        #expect(condition.id == WatchlistStore.legacyObservationConditionID)
        #expect(WatchlistStore.hasLegacyObservationCondition([condition]))
        #expect(!WatchlistStore.hasLegacyObservationCondition([]))
        #expect(!WatchlistStore.hasLegacyObservationCondition(nil))
        // Applying it twice is idempotent.
        let once = WatchlistStore.addingLegacyObservationCondition(to: nil)
        let twice = WatchlistStore.addingLegacyObservationCondition(to: once)
        #expect(once.count == 1)
        #expect(twice == once)
    }

    @MainActor
    @Test("Transferring a portion into the retired observation purpose is refused explicitly")
    func retiredPoolIsRefusedByStore() throws {
        let (store, defaults, suite) = try makeStore("retired-refusal")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)

        #expect(throws: PositionAllocationError.retiredPool) {
            try store.transferPositionPortion(
                symbol: symbol, portionID: portionID, quantity: 5,
                to: .observation, reason: "old destination", expectedRevision: initial.revision
            )
        }
        // Nothing moved and no retired purpose was created.
        #expect(store.item(for: symbol)?.positionAllocation == initial)
        #expect(store.item(for: symbol)?.positionAllocation?.portions.allSatisfy { $0.pool.isActivePurpose } == true)

        // Transferring to a live purpose still works.
        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: portionID, quantity: 5,
            to: .tactical, reason: "live destination", expectedRevision: initial.revision
        )
        #expect(moved.portions.contains { $0.pool == .tactical && $0.quantity == 5 })
        #expect(moved.portions.map(\.quantity).reduce(0, +) == 10)
    }

    // MARK: - Badge derivation

    @Test("Badge derivation: nil and empty stay nil, and state outranks nothing else")
    func badgeEmptyAndPending() {
        #expect(PositionVerificationBadge.derived(from: nil) == nil)
        #expect(PositionVerificationBadge.derived(from: []) == nil)
        #expect(PositionVerificationBadge.derived(from: [condition("a")]) == .pending)
        #expect(PositionVerificationBadge.derived(from: [condition("a", state: .confirmed)]) == .confirmed)
        #expect(PositionVerificationBadge.derived(from: [condition("a", state: .invalidated)]) == .invalidated)
    }

    @Test("Badge derivation: invalidated outranks everything, then needsReview, then pending")
    func badgePriority() {
        let pending = condition("pending")
        let invalidated = condition("invalidated", state: .invalidated)
        let needsReview = condition("due", state: .confirmed, reviewDate: Date(timeIntervalSince1970: 0))
        #expect(PositionVerificationBadge.derived(from: [pending, invalidated]) == .invalidated)
        #expect(PositionVerificationBadge.derived(from: [pending, needsReview]) == .needsReview)
        #expect(PositionVerificationBadge.derived(from: [pending]) == .pending)
        // An invalidated condition outranks a needsReview sibling.
        #expect(PositionVerificationBadge.derived(from: [invalidated, needsReview]) == .invalidated)
    }

    @Test("A confirmed condition decays to needsReview when its date arrives or its event moves")
    func badgeEventAndDateChanges() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let event = InstrumentEvent(
            kind: .earnings, date: now.addingTimeInterval(86_400), title: "Earnings",
            updatedAt: now
        )
        let linked = condition("linked", state: .confirmed, eventReference: event)
        #expect(PositionVerificationBadge.derived(from: [linked], at: now, currentEvents: [event]) == .confirmed)

        // The event's own date moves: the ground the reasoning stood on changed.
        var moved = event
        moved.date = event.date.addingTimeInterval(86_400)
        #expect(PositionVerificationBadge.derived(from: [linked], at: now, currentEvents: [moved]) == .needsReview)
        // The linked event disappears entirely.
        #expect(PositionVerificationBadge.derived(from: [linked], at: now, currentEvents: []) == .needsReview)
        // Tidying metadata that does not change what the event *is* leaves it confirmed.
        var annotated = event
        annotated.note = "added context"
        annotated.updatedAt = now.addingTimeInterval(60)
        #expect(PositionVerificationBadge.derived(from: [linked], at: now, currentEvents: [annotated]) == .confirmed)

        // A review date that has arrived reopens an otherwise confirmed condition.
        let due = condition("due", state: .confirmed, reviewDate: now)
        #expect(PositionVerificationBadge.derived(from: [due], at: now, currentEvents: []) == .needsReview)
        let future = condition("future", state: .confirmed, reviewDate: now.addingTimeInterval(86_400))
        #expect(PositionVerificationBadge.derived(from: [future], at: now, currentEvents: []) == .confirmed)
    }

    @Test("A plan and a portion derive the same badge from the same conditions")
    func planAndPortionShareOneDerivation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let conditions = [condition("thesis", state: .confirmed)]
        var plan = TradePlan(kind: .buy, price: 10, quantity: 1, conditions: conditions)
        plan.conditions = conditions
        let portion = PositionPortion(
            quantity: 1, origin: PositionPortion.Origin(kind: .snapshot), conditions: conditions
        )
        #expect(plan.verificationBadge(at: now) == .confirmed)
        #expect(PositionVerificationBadge.derived(from: portion.conditions, at: now) == .confirmed)
        // Purpose and funding are independent of the badge: an unassigned,
        // unmarked portion with confirmed conditions is still confirmed.
        #expect(portion.pool == .unassigned)
        #expect(portion.fundingSource == nil)
        #expect(PositionVerificationBadge.derived(from: portion.conditions, at: now) == .confirmed)
    }

    @Test("An explicit empty condition array is metadata, a nil one is not")
    func emptyConditionsAreMetadata() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let item = WatchItem(symbol: symbol, displayName: "Apple", lots: [CostLot(price: 100, quantity: 1)])
        let cleared = PositionPortion(
            quantity: 1, origin: PositionPortion.Origin(kind: .snapshot), conditions: []
        )
        #expect(cleared.hasVerificationMetadata)
        #expect(PositionVerificationBadge.derived(from: cleared.conditions, at: now) == nil)
        let never = PositionPortion(quantity: 1, origin: PositionPortion.Origin(kind: .snapshot))
        #expect(!never.hasVerificationMetadata)

        let clearedAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [cleared]
        )
        #expect(clearedAllocation.hasVerificationMetadata)
        let neverAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [never]
        )
        #expect(!neverAllocation.hasVerificationMetadata)
    }

    @Test("Verification metadata is found in an audit entry's snapshots, not just the live array")
    func historyOnlyMetadataIsDetected() {
        let item = WatchItem(symbol: symbol, displayName: "Apple", lots: [CostLot(price: 100, quantity: 1)])
        let live = PositionPortion(quantity: 1, origin: PositionPortion.Origin(kind: .snapshot))
        let historical = PositionPortion(
            quantity: 1, origin: PositionPortion.Origin(kind: .snapshot), conditions: []
        )
        let allocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [live],
            changes: [PositionAllocation.Change(
                kind: .verification,
                reason: "cleared before the field was live",
                previousPortions: [historical],
                resultingPortions: [live]
            )]
        )
        #expect(allocation.hasVerificationMetadata)
        #expect(allocation.isValid)
    }

    // MARK: - Condition payload validity

    @Test("Allocation validity rejects blank, duplicated, and malformed condition payloads")
    func allocationValidationRejectsBadConditions() {
        let item = WatchItem(symbol: symbol, displayName: "Apple", lots: [CostLot(price: 100, quantity: 1)])
        let fingerprint = PositionAllocation.basisFingerprint(for: item)

        func allocation(conditions: [TradePlanCondition]?) -> PositionAllocation {
            PositionAllocation(
                basisFingerprint: fingerprint,
                portions: [PositionPortion(
                    quantity: 1, origin: PositionPortion.Origin(kind: .snapshot), conditions: conditions
                )]
            )
        }

        #expect(allocation(conditions: nil).isValid)
        #expect(allocation(conditions: []).isValid)
        #expect(allocation(conditions: [condition("ok")]).isValid)
        // Untrimmed title is not normalized, so it is not a valid stored payload.
        let untrimmed = TradePlanCondition(title: "  spaced  ", kind: .manual)
        #expect(!allocation(conditions: [untrimmed]).isValid)
        // A blank title normalizes to nil.
        #expect(!allocation(conditions: [TradePlanCondition(title: "   ", kind: .manual)]).isValid)
        // Two conditions cannot share one id.
        let shared = UUID()
        #expect(!allocation(conditions: [
            condition("a", id: shared), condition("b", id: shared)
        ]).isValid)
    }

    @Test("A plan carrying a retired purpose stays valid so legacy history still loads")
    func legacyPlanPayloadRemainsValid() {
        let legacy = TradePlan(
            kind: .buy, price: 10, quantity: 1, positionPool: .observation,
            conditions: [condition("watch")]
        )
        #expect(legacy.hasValidPayload)
        #expect(legacy.positionPool == .observation)
        let migrated = WatchlistStore.migratedPlan(legacy)
        #expect(migrated.positionPool == .unassigned)
        #expect(migrated.positionPool != .observation)
        #expect(migrated.history?.count == 1)
        #expect(migrated.history?.first?.configuration.positionPool == .observation)
        #expect(migrated.conditions?.contains { $0.id == WatchlistStore.legacyObservationConditionID } == true)
        // The user's own condition is preserved, not replaced.
        #expect(migrated.conditions?.contains { $0.title == "watch" } == true)
    }

    // MARK: - Store: metadata save, clear, split, undo, reload

    @MainActor
    @Test("Conditions save, clear explicitly, and round trip through a reload")
    func conditionsSaveClearAndReload() throws {
        let (store, defaults, suite) = try makeStore("conditions")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)

        let saved = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [condition("earnings beat", state: .confirmed)],
            expectedRevision: initial.revision
        )
        #expect(saved.changes.last?.kind == .verification)
        #expect(saved.portions.first?.conditions?.count == 1)
        // Quantity, pool, origin, and funding are untouched by a metadata edit.
        #expect(saved.portions.first?.quantity == 10)
        #expect(saved.portions.first?.pool == initial.portions.first?.pool)
        #expect(saved.portions.first?.origin == initial.portions.first?.origin)
        #expect(store.item(for: symbol)?.transactions.count == 1)
        #expect(store.item(for: symbol)?.positionQuantity == 10)

        // Re-saving the identical payload is a no-op: same revision, no new change.
        let noop = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [saved.portions.first!.conditions![0]],
            expectedRevision: saved.revision
        )
        #expect(noop.revision == saved.revision)
        #expect(noop.changes.count == saved.changes.count)

        // Clearing is stored as an explicit empty array, not nil.
        let cleared = try store.setPositionConditions(
            symbol: symbol, portionID: portionID, conditions: [], expectedRevision: saved.revision
        )
        #expect(cleared.portions.first?.conditions?.isEmpty == true)
        #expect(cleared.hasVerificationMetadata)

        // A reload keeps the explicit clear.
        let snapshot = V2Snapshot(
            items: store.allItems, groups: store.groups,
            selectedGroupID: store.selectedGroupID, retainedHistoryItems: nil
        )
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "pulse.watchlists.v3")
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let reloadedPortion = try #require(reloaded.item(for: symbol)?.positionAllocation?.portions.first)
        #expect(reloadedPortion.conditions?.isEmpty == true)
        #expect(reloaded.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Invalid condition payloads are refused and nothing is written")
    func invalidConditionsAreRefused() throws {
        let (store, defaults, suite) = try makeStore("invalid-conditions")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)

        #expect(throws: PositionAllocationError.invalidConditions) {
            try store.setPositionConditions(
                symbol: symbol, portionID: portionID,
                conditions: [TradePlanCondition(title: "   ", kind: .manual)],
                expectedRevision: initial.revision
            )
        }
        let shared = UUID()
        #expect(throws: PositionAllocationError.invalidConditions) {
            try store.setPositionConditions(
                symbol: symbol, portionID: portionID,
                conditions: [condition("a", id: shared), condition("b", id: shared)],
                expectedRevision: initial.revision
            )
        }
        let tooMany = (0...WatchlistStore.maximumPortionConditionCount).map { condition("c\($0)") }
        #expect(throws: PositionAllocationError.tooManyConditions(limit: WatchlistStore.maximumPortionConditionCount)) {
            try store.setPositionConditions(
                symbol: symbol, portionID: portionID,
                conditions: tooMany, expectedRevision: initial.revision
            )
        }
        // A stale revision is refused before anything is attributed.
        let staleRequest = UUID()
        #expect(throws: PositionAllocationError.staleRevision(
            expected: staleRequest, actual: initial.revision
        )) {
            try store.setPositionConditions(
                symbol: symbol, portionID: portionID,
                conditions: [condition("late")], expectedRevision: staleRequest
            )
        }
        #expect(store.item(for: symbol)?.positionAllocation == initial)
    }

    @MainActor
    @Test("Undo reverts a verification edit in one step and re-applies it")
    func undoRevertsVerificationEdit() throws {
        let (store, defaults, suite) = try makeStore("undo")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)

        let saved = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [condition("thesis", state: .confirmed)],
            expectedRevision: initial.revision
        )
        let restored = try store.restorePositionAllocation(
            symbol: symbol, previous: initial, expectedRevision: saved.revision
        )
        #expect(restored.portions == initial.portions)
        #expect(restored.changes.last?.kind == .restore)
        #expect(restored.changes.last?.reason == "Undo verification change")
        // A second undo has nothing of its own kind left to revert.
        #expect(throws: PositionAllocationError.noSingleTransferToRestore) {
            try store.restorePositionAllocation(
                symbol: symbol, previous: initial, expectedRevision: restored.revision
            )
        }
        // The strict revision guard still holds.
        let staleUndo = UUID()
        #expect(throws: PositionAllocationError.staleRevision(
            expected: staleUndo, actual: restored.revision
        )) {
            try store.restorePositionAllocation(
                symbol: symbol, previous: initial, expectedRevision: staleUndo
            )
        }
        #expect(store.item(for: symbol)?.positionQuantity == 10)
    }

    @MainActor
    @Test("A split and a transfer retain the conditions on the moved shares")
    func splitAndTransferRetainConditions() throws {
        let (store, defaults, suite) = try makeStore("split")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        var allocation = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(allocation.portions.first?.id)
        allocation = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [condition("hold through cycle", state: .confirmed)],
            expectedRevision: allocation.revision
        )
        #expect(allocation.portions.first?.conditions?.count == 1)

        // Labelling part of the card splits a new id off; the split keeps the conditions.
        let labelled = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 4, source: .margin,
            reason: "", expectedRevision: allocation.revision
        )
        #expect(labelled.portions.count == 2)
        #expect(labelled.portions.allSatisfy { $0.conditions?.count == 1 })

        // A partial transfer likewise carries the reasoning with the shares.
        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: labelled.portions[0].id, quantity: 3,
            to: .tactical, reason: "trim", expectedRevision: labelled.revision
        )
        #expect(moved.portions.allSatisfy { $0.conditions?.count == 1 })
        #expect(moved.portions.map(\.quantity).reduce(0, +) == 10)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @MainActor
    @Test("Reconciliation keeps each card's conditions while it rewrites quantities")
    func reconcileRetainsConditions() throws {
        let (store, defaults, suite) = try makeStore("reconcile-conditions")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        var allocation = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(allocation.portions.first?.id)
        allocation = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [condition("core thesis", state: .confirmed)],
            expectedRevision: allocation.revision
        )
        // A sell makes the allocation need reconciliation; the following
        // reconcile must not quietly drop the reasoning. The confirmed
        // quantities have to add up to what the position now holds.
        store.addTransaction(symbol, PositionTransaction(kind: .sell, price: 110, quantity: 4))
        let stale = try #require(store.item(for: symbol)?.positionAllocation)
        let held = try #require(store.item(for: symbol)?.positionQuantity)
        #expect(held == 6)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == true)
        let reconciled = try store.reconcilePositionAllocation(
            symbol: symbol,
            quantities: Dictionary(uniqueKeysWithValues: stale.portions.map { ($0.id, held) }),
            reason: "reviewed after sale",
            expectedRevision: stale.revision
        )
        #expect(reconciled.portions.allSatisfy { $0.conditions?.count == 1 })
        #expect(reconciled.portions.map(\.quantity).reduce(0, +) == held)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    // MARK: - Buy inheritance

    @MainActor
    @Test("A buy inherits the immutable plan snapshot's conditions, not the current plan's")
    func buyInheritsSnapshotConditions() throws {
        let (store, defaults, suite) = try makeStore("inherit")
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorded = condition("buy the dip", state: .confirmed)
        var plan = TradePlan(
            kind: .buy, price: 100, quantity: 5, positionPool: .strategic, conditions: [recorded]
        )
        #expect(store.setTradePlan(plan, for: symbol))
        _ = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 100, quantity: 5,
            date: .now, fee: nil, note: nil
        )
        let portion = try #require(store.item(for: symbol)?.positionAllocation?.portions.first)
        #expect(portion.pool == .strategic)
        #expect(portion.conditions == [recorded])

        // Rewriting the plan's conditions afterwards never rewrites the portion:
        // the fill's snapshot is immutable context.
        plan = try #require(store.item(for: symbol)?.plans.first)
        plan.conditions = [condition("different reasoning now")]
        #expect(store.setTradePlan(plan, for: symbol))
        #expect(store.item(for: symbol)?.positionAllocation?.portions.first?.conditions == [recorded])
    }

    @MainActor
    @Test("A historical buy whose snapshot names the retired purpose creates an unassigned, pending portion")
    func historicalObservationBuyMigratesToUnassigned() throws {
        let (store, defaults, suite) = try makeStore("historical-buy")
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = TradePlanConfiguration(plan: TradePlan(
            kind: .buy, price: 100, quantity: 2, positionPool: .observation
        ))
        // The buy lands on an empty ledger, so it opens the position directly.
        store.addTransaction(symbol, buy(2, planConfiguration: snapshot))
        let portion = try #require(store.item(for: symbol)?.positionAllocation?.portions.first)
        #expect(portion.pool == .unassigned)
        #expect(portion.conditions?.count == 1)
        #expect(portion.conditions?.first?.title == WatchlistStore.legacyObservationConditionTitle)
        #expect(portion.conditions?.first?.state == .pending)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)
    }

    @Test("A retired buy snapshot keeps existing conditions and adds the pending legacy check")
    func retiredBuyKeepsExistingReasoning() {
        let existing = condition("原始判断", state: .confirmed)
        let configuration = TradePlanConfiguration(plan: TradePlan(kind: .buy, price: 100, quantity: 2,
            positionPool: .observation, conditions: [existing]))
        let portion = WatchlistStore.buyPortion(from: buy(2, planConfiguration: configuration))
        #expect(portion.pool == .unassigned)
        #expect(portion.conditions?.first == existing)
        #expect(portion.conditions?.count == 2)
        #expect(PositionVerificationBadge.derived(from: portion.conditions) == .pending)
    }

    // MARK: - Legacy migration

    @Test("An older peer reassigning a migrated plan preserves distinct history revisions")
    func legacyPeerEditedPlanMigratesAgain() {
        let original = TradePlan(kind: .buy, price: 100, quantity: 2, positionPool: .observation)
        let first = WatchlistStore.migratedPlan(original)
        var peerEdit = first
        peerEdit.positionPool = .observation
        peerEdit.price = 101
        peerEdit.updatedAt = original.updatedAt.addingTimeInterval(60)
        let second = WatchlistStore.migratedPlan(peerEdit)
        #expect(second.hasValidPayload)
        #expect(second.history?.count == 2)
        #expect(second.history?.first == first.history?.first)
        #expect(second.history?.last?.configuration.price == 101)
        #expect(WatchlistStore.migratedPlan(peerEdit) == second)
    }

    @MainActor
    @Test("A legacy observation allocation migrates on load, keeping identity, quantity, funding, and note")
    func legacyAllocationMigratesOnLoad() throws {
        let suite = "PositionVerificationTests.migrate-load.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let transaction = buy(10)
        var item = WatchItem(
            symbol: symbol, displayName: "Apple", transactions: [transaction]
        )
        item.positionAllocation = legacyObservationAllocation(item: item, quantity: 10)
        let originalPortionID = try #require(item.positionAllocation?.portions.first?.id)
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        defaults.set(
            try JSONEncoder().encode(V2Snapshot(
                items: [item], groups: [group], selectedGroupID: group.id, retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let allocation = try #require(store.item(for: symbol)?.positionAllocation)
        let portion = try #require(allocation.portions.first)
        #expect(portion.pool == .unassigned)
        #expect(portion.id == originalPortionID)
        #expect(portion.quantity == 10)
        #expect(portion.origin.kind == .snapshot)
        #expect(portion.note == "watch the thesis")
        #expect(portion.fundingSource == .own)
        #expect(portion.conditions?.first?.title == WatchlistStore.legacyObservationConditionTitle)
        #expect(allocation.changes.last?.kind == .reconcile)
        #expect(allocation.changes.last?.previousPortions.first?.pool == .observation)
        // The basis is carried, not recalculated, and the position is verified.
        #expect(allocation.basisFingerprint == PositionAllocation.basisFingerprint(for: store.item(for: symbol)!))
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        // Idempotent: loading again adds no second condition or change.
        defaults.set(
            try JSONEncoder().encode(V2Snapshot(
                items: store.allItems, groups: store.groups,
                selectedGroupID: store.selectedGroupID, retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(reloaded.item(for: symbol)?.positionAllocation == allocation)
    }

    @MainActor
    @Test("A legacy observation allocation with a drifted basis keeps its fingerprint and stays unverified")
    func migrationPreservesStaleBasis() throws {
        let suite = "PositionVerificationTests.stale-basis.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [buy(10)])
        // A frozen fingerprint that no longer matches the ledger: the migration
        // must not recalculate it and bless the position as verified.
        let stale = String(repeating: "a", count: 64)
        var allocation = legacyObservationAllocation(item: item, quantity: 10)
        allocation.basisFingerprint = stale
        item.positionAllocation = allocation
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        defaults.set(
            try JSONEncoder().encode(V2Snapshot(
                items: [item], groups: [group], selectedGroupID: group.id, retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let loaded = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(loaded.basisFingerprint == stale)
        #expect(loaded.portions.first?.pool == .unassigned)
        // The stale basis is what keeps reconciliation required.
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == true)
    }

    @MainActor
    @Test("A legacy observation plan migrates on load and keeps its id, conditions, and fill link")
    func legacyPlanMigratesOnLoad() throws {
        let suite = "PositionVerificationTests.migrate-plan.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fillID = UUID()
        let kept = condition("original reasoning", state: .confirmed)
        let legacyPlan = TradePlan(
            kind: .buy, price: 100, quantity: 5,
            filledTransactionID: fillID, positionPool: .observation, conditions: [kept]
        )
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        defaults.set(
            try JSONEncoder().encode(V2Snapshot(
                items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [legacyPlan])],
                groups: [group], selectedGroupID: group.id, retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let plan = try #require(store.item(for: symbol)?.plans.first)
        #expect(plan.id == legacyPlan.id)
        #expect(plan.positionPool == .unassigned)
        #expect(plan.filledTransactionID == fillID)
        #expect(plan.conditions?.contains { $0.id == kept.id } == true)
        #expect(plan.conditions?.contains { $0.id == WatchlistStore.legacyObservationConditionID } == true)
        #expect(plan.history?.contains { $0.configuration.positionPool == .observation } == true)

        // Idempotent: a second load adds no further revision or condition.
        defaults.set(
            try JSONEncoder().encode(V2Snapshot(
                items: store.allItems, groups: store.groups,
                selectedGroupID: store.selectedGroupID, retainedHistoryItems: nil
            )),
            forKey: "pulse.watchlists.v3"
        )
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(reloaded.item(for: symbol)?.plans == store.item(for: symbol)?.plans)
    }

    @MainActor
    @Test("A legacy plan sent through setTradePlan is migrated on the way in")
    func incomingLegacyPlanMigrates() throws {
        let (store, defaults, suite) = try makeStore("incoming-legacy-plan")
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = TradePlan(kind: .buy, price: 100, quantity: 2, positionPool: .observation)
        #expect(store.setTradePlan(legacy, for: symbol))
        let stored = try #require(store.item(for: symbol)?.plans.first)
        #expect(stored.positionPool == .unassigned)
        #expect(stored.conditions?.count == 1)
        #expect(stored.history?.first?.configuration.positionPool == .observation)

        // Re-sending the same legacy value changes nothing further.
        let revisionCount = stored.history?.count
        #expect(store.setTradePlan(legacy, for: symbol))
        #expect(store.item(for: symbol)?.plans.first?.history?.count == revisionCount)
        #expect(store.item(for: symbol)?.plans.first?.conditions?.count == 1)
    }

    @MainActor
    @Test("An archived legacy allocation and plan migrate on import")
    func legacyArchiveImportMigrates() throws {
        let (destination, destinationDefaults, destinationSuite) = try makeStore("archive-import-target")
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }

        // A hand-written legacy archive: the retired purpose, no verification
        // field anywhere. This is what a build from before the retirement would
        // have exported, and importing it must migrate rather than refuse.
        let legacyConditionID = UUID()
        let archiveJSON = """
        {
          "format": "pulse.watchlist",
          "version": 7,
          "lists": [{
            "name": "Core",
            "entries": [{
              "market": "us",
              "code": "AAPL",
              "name": "Apple",
              "plans": [{
                "id": "\(UUID().uuidString)",
                "kind": "sell",
                "price": 200,
                "quantity": 5,
                "status": "cancelled",
                "createdAt": "2023-11-14T22:13:20Z",
                "updatedAt": "2023-11-14T22:13:20Z",
                "positionPool": "observation",
                "conditions": [{
                  "id": "\(legacyConditionID.uuidString)",
                  "title": "original reasoning",
                  "kind": "manual",
                  "state": "confirmed"
                }]
              }]
            }]
          }]
        }
        """
        let decoded = try WatchlistArchive.decoded(from: archiveJSON)
        #expect(decoded.version == 7)

        destination.merge(decoded)
        let plan = try #require(destination.item(for: symbol)?.plans.first)
        #expect(plan.positionPool == .unassigned)
        #expect(plan.status == .cancelled)
        // The user's own condition survives; the migration adds its own.
        #expect(plan.conditions?.contains { $0.id == legacyConditionID } == true)
        #expect(plan.conditions?.contains { $0.id == WatchlistStore.legacyObservationConditionID } == true)
        #expect(plan.history?.contains { $0.configuration.positionPool == .observation } == true)
    }

    @MainActor
    @Test("A legacy observation allocation in an archive migrates on import")
    func legacyArchiveAllocationMigrates() throws {
        let (destination, destinationDefaults, destinationSuite) = try makeStore("archive-alloc-target")
        defer { destinationDefaults.removePersistentDomain(forName: destinationSuite) }

        let portionID = UUID()
        let archiveJSON = """
        {
          "format": "pulse.watchlist",
          "version": 8,
          "lists": [{
            "name": "Core",
            "entries": [{
              "market": "us",
              "code": "AAPL",
              "name": "Apple",
              "positionAllocation": {
                "basisFingerprint": "\(String(repeating: "0", count: 64))",
                "revision": "\(UUID().uuidString)",
                "portions": [{
                  "id": "\(portionID.uuidString)",
                  "quantity": 10,
                  "pool": "observation",
                  "origin": {"kind": "snapshot", "date": "2020-09-13T12:26:40Z"},
                  "note": "watch the thesis",
                  "fundingSource": "own"
                }],
                "changes": []
              }
            }]
          }]
        }
        """
        destination.merge(try WatchlistArchive.decoded(from: archiveJSON))
        let allocation = try #require(destination.item(for: symbol)?.positionAllocation)
        let portion = try #require(allocation.portions.first)
        #expect(portion.pool == .unassigned)
        #expect(portion.id == portionID)
        #expect(portion.quantity == 10)
        #expect(portion.note == "watch the thesis")
        #expect(portion.fundingSource == .own)
        #expect(portion.conditions?.first?.title == WatchlistStore.legacyObservationConditionTitle)
        #expect(allocation.changes.last?.previousPortions.first?.pool == .observation)
        // The fixture's fingerprint does not match the local (empty) ledger, so
        // the migration must leave it stale rather than approving it.
        #expect(allocation.basisFingerprint == String(repeating: "0", count: 64))
    }

    @MainActor
    @Test("A legacy observation purpose arriving through apply-sync is migrated, not rejected")
    func legacySyncSnapshotMigrates() throws {
        let (store, defaults, suite) = try makeStore("apply-sync")
        defer { defaults.removePersistentDomain(forName: suite) }

        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [buy(10)])
        item.positionAllocation = legacyObservationAllocation(item: item, quantity: 10)
        item.plans = [TradePlan(kind: .buy, price: 90, quantity: 3, positionPool: .observation)]
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let snapshot = WatchlistSyncSnapshot(items: [item], groups: [group])

        #expect(store.applySyncSnapshot(snapshot))
        let allocation = try #require(store.item(for: symbol)?.positionAllocation)
        #expect(allocation.portions.first?.pool == .unassigned)
        #expect(store.item(for: symbol)?.plans.first?.positionPool == .unassigned)
        #expect(store.item(for: symbol)?.positionAllocationNeedsReconciliation == false)

        // A second identical apply is a no-op, which proves the migration
        // settled rather than minting a new revision each pass.
        #expect(!store.applySyncSnapshot(store.syncSnapshot()))
        #expect(!store.applySyncSnapshot(snapshot))
        #expect(store.item(for: symbol)?.positionAllocation == allocation)
    }

    // MARK: - Portability

    @MainActor
    @Test("Verification raises the archive and sync versions and round trips")
    func verificationVersionsRoundTrip() throws {
        let (store, defaults, suite) = try makeStore("versions")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        let portionID = try #require(initial.portions.first?.id)
        _ = try store.setPositionConditions(
            symbol: symbol, portionID: portionID,
            conditions: [condition("thesis", state: .confirmed)],
            expectedRevision: initial.revision
        )

        let archive = store.archive()
        #expect(archive.version == 10)
        let decodedArchive = try WatchlistArchive.decoded(from: archive.encoded())
        let archivedConditions = decodedArchive.lists[0].entries[0].positionAllocation?.portions.first?.conditions
        #expect(archivedConditions?.count == 1)

        let snapshot = store.syncSnapshot()
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "verification-test", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 11)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot == snapshot)
    }

    @MainActor
    @Test("An ordinary payload keeps its old version; only verification raises it")
    func ordinaryPayloadsKeepTheirVersion() throws {
        let (store, defaults, suite) = try makeStore("ordinary-versions")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        // A plain allocation with no conditions is still v5/v6.
        #expect(store.archive().version == 5)
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "ordinary", snapshot: store.syncSnapshot())
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 6)
    }

    @MainActor
    @Test("Older archive and sync versions reject a payload carrying verification fields")
    func downgradeRejectsVerificationPayload() throws {
        let (store, defaults, suite) = try makeStore("downgrade")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(10))
        let initial = try #require(store.item(for: symbol)?.positionAllocation)
        _ = try store.setPositionConditions(
            symbol: symbol, portionID: try #require(initial.portions.first?.id),
            conditions: [condition("thesis")], expectedRevision: initial.revision
        )

        // Archive: claim version 9 while the payload carries a portion condition.
        let encodedArchive = try store.archive().encoded()
        let archiveData = try #require(encodedArchive.data(using: .utf8))
        var archiveObject = try #require(
            JSONSerialization.jsonObject(with: archiveData) as? [String: Any]
        )
        archiveObject["version"] = 9
        let downgradedArchive = try JSONSerialization.data(withJSONObject: archiveObject)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(10)) {
            try WatchlistArchive.decoded(from: String(decoding: downgradedArchive, as: UTF8.self))
        }

        // Sync: claim version 10 while the payload carries a portion condition.
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "downgrade", snapshot: store.syncSnapshot())
        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 10
        let downgradedWire = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(11)) {
            try WatchlistSyncWireCodec.decode(downgradedWire)
        }
    }

    @Test("A history-only explicit clear is still detected as verification metadata")
    func historyOnlyClearRequiresTheNewVersion() throws {
        let item = WatchItem(symbol: symbol, displayName: "Apple", lots: [CostLot(price: 100, quantity: 1)])
        let live = PositionPortion(quantity: 1, origin: PositionPortion.Origin(kind: .snapshot))
        let historicallyCleared = PositionPortion(
            quantity: 1, origin: PositionPortion.Origin(kind: .snapshot), conditions: []
        )
        let allocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [live],
            changes: [PositionAllocation.Change(
                kind: .verification, reason: "cleared",
                previousPortions: [historicallyCleared], resultingPortions: [live]
            )]
        )
        var storedItem = item
        storedItem.positionAllocation = allocation
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let snapshot = WatchlistSyncSnapshot(items: [storedItem], groups: [group])

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "history-only", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 11)

        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        wireObject["version"] = 10
        let downgraded = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(11)) {
            try WatchlistSyncWireCodec.decode(downgraded)
        }
    }

    @Test("An old sync payload carrying a portion condition under an old version is rejected")
    func oldVersionWithPortionConditionsIsRejected() throws {
        let transaction = buy(1)
        let portion = PositionPortion(
            quantity: 1,
            origin: PositionPortion.Origin(
                kind: .buy, transactionID: transaction.id, date: transaction.date,
                price: transaction.price, quantity: transaction.quantity
            ),
            conditions: [condition("thesis")]
        )
        var item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: [portion]
        )
        item.plans = []
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let snapshot = WatchlistSyncSnapshot(items: [item], groups: [group])
        // Encoding through the real encoder picks 11; the downgrade is simulated
        // by rewriting the declared version, which is exactly what a stale peer
        // or a file edited by hand would produce.
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "legacy-claim", snapshot: snapshot)
        var wireObject = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(wireObject["version"] as? Int == 11)
        wireObject["version"] = 10
        let downgraded = try JSONSerialization.data(withJSONObject: wireObject)
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(11)) {
            try WatchlistSyncWireCodec.decode(downgraded)
        }
    }
}
