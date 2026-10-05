import Foundation
import Testing
@testable import PulseCore

/// Bounded event references on plan conditions, and the forward-looking review
/// checkpoint on a trade's review.
///
/// The recurring themes are that a linked event is a *snapshot* rather than a
/// live pointer, that only changes to the event's meaning reopen a condition
/// (its annotation does not), that a missing event is reported rather than
/// guessed at, and that a checkpoint edit never moves a price, a quantity, a
/// date, or a P&L figure.
@Suite("Plan event references and review checkpoints")
struct PlanEventCheckpointTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")
    private let otherSymbol = SymbolID(market: .us, code: "MSFT")

    private let eventDate = Date(timeIntervalSince1970: 1_800_000_000)
    private let laterDate = Date(timeIntervalSince1970: 1_800_500_000)
    private let now = Date(timeIntervalSince1970: 1_799_000_000)

    private func makeEvent(
        id: UUID = UUID(),
        kind: InstrumentEvent.Kind = .earnings,
        date: Date? = nil,
        endDate: Date? = nil,
        title: String = "Quarterly results",
        sourceURL: String? = nil,
        note: String? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_799_500_000)
    ) -> InstrumentEvent {
        InstrumentEvent(
            id: id,
            kind: kind,
            date: date ?? eventDate,
            title: title,
            endDate: endDate,
            sourceURL: sourceURL,
            note: note,
            updatedAt: updatedAt
        )
    }

    @MainActor
    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "PlanEventCheckpointTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    // MARK: - Backward compatibility

    @Test("Old condition, review, and plan JSON decode with the new fields absent")
    func legacyJSONDecodesWithoutNewFields() throws {
        let legacyCondition = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"Wait for guidance",
         "kind":"event","state":"confirmed","reviewDate":1800000000}
        """
        let condition = try JSONDecoder().decode(
            TradePlanCondition.self, from: Data(legacyCondition.utf8)
        )
        #expect(condition.eventReference == nil)
        #expect(condition.title == "Wait for guidance")
        #expect(condition.reviewDate != nil)

        // A legacy condition with no event link is unaffected by the new API:
        // a confirmed condition with no review date never reopens.
        #expect(!condition.requiresReview(at: now, currentEvents: []))

        let legacyReview = #"{"followedPlan":true,"retrospective":"Kept the limit"}"#
        let review = try JSONDecoder().decode(
            PositionTransactionReview.self, from: Data(legacyReview.utf8)
        )
        #expect(review.nextReviewDate == nil)
        #expect(review.nextReviewNote == nil)
        #expect(!review.hasCheckpoint)

        let legacyTransaction = #"{"id":"A0D0A0D0-A0D0-40D0-80D0-A0D0A0D0A0D0","kind":"buy","price":10,"quantity":1,"date":0,"createdAt":0}"#
        let transaction = try JSONDecoder().decode(
            PositionTransaction.self, from: Data(legacyTransaction.utf8)
        )
        #expect(transaction.review == nil)
        #expect(transaction.planExecution == nil)
    }

    @Test("An old watch item with a plan and review round-trips without inventing fields")
    func legacyItemRoundTripDoesNotInventFields() throws {
        let json = """
        {
          "symbol": {"market": "us", "code": "AAPL"},
          "displayName": "Apple",
          "addedAt": 0,
          "lots": [],
          "transactions": [{
            "id": "A0D0A0D0-A0D0-40D0-80D0-A0D0A0D0A0D0",
            "kind": "buy", "price": 10, "quantity": 1, "date": 0, "createdAt": 0,
            "review": {"followedPlan": false}
          }],
          "plans": [{
            "id": "B0D0A0D0-A0D0-40D0-80D0-A0D0A0D0A0D0",
            "kind": "buy", "price": 9, "quantity": 1, "status": "active",
            "createdAt": 0, "updatedAt": 0,
            "conditions": [{
              "id": "C0D0A0D0-A0D0-40D0-80D0-A0D0A0D0A0D0",
              "title": "Wait", "kind": "event", "state": "pending"
            }]
          }]
        }
        """
        let item = try JSONDecoder().decode(WatchItem.self, from: Data(json.utf8))
        #expect(item.plans.first?.conditions?.first?.eventReference == nil)
        #expect(item.transactions.first?.review?.nextReviewDate == nil)

        // Re-encoding for a build that understands the fields still says nothing.
        let reencoded = try JSONDecoder().decode(
            WatchItem.self, from: try JSONEncoder().encode(item)
        )
        #expect(reencoded == item)
        #expect(!(reencoded.plans.first?.hasEventReferenceMetadata ?? true))
    }

    // MARK: - requiresReview

    @Test("A confirmed condition linked to an unchanged event never reopens")
    func unchangedReferenceDoesNotRequireReview() throws {
        let event = makeEvent()
        let condition = TradePlanCondition(
            title: "Earnings", kind: .event, state: .confirmed, eventReference: event
        )
        #expect(!condition.requiresReview(at: now, currentEvents: [event]))

        // Changing only the event's annotation — updatedAt, note, sourceURL —
        // does not change what the event *is*, so the link stays settled.
        var annotated = event
        annotated.updatedAt = laterDate
        annotated.note = "  moved to a footnote  "
        annotated.sourceURL = "https://example.com/earnings"
        #expect(!condition.requiresReview(at: now, currentEvents: [annotated]))

        // The user's own note on the condition is likewise not the event's.
        var noted = condition
        noted.note = "read the transcript"
        #expect(!noted.requiresReview(at: now, currentEvents: [annotated]))
    }

    @Test("Meaningful event changes reopen a confirmed condition")
    func meaningfulEventChangesRequireReview() {
        let event = makeEvent()
        let condition = TradePlanCondition(
            title: "Earnings", kind: .event, state: .confirmed, eventReference: event
        )

        var movedDate = event
        movedDate.date = laterDate
        #expect(condition.requiresReview(at: now, currentEvents: [movedDate]))

        var changedEnd = event
        changedEnd.endDate = laterDate
        #expect(condition.requiresReview(at: now, currentEvents: [changedEnd]))

        var retitled = event
        retitled.title = "Q4 results (rescheduled)"
        #expect(condition.requiresReview(at: now, currentEvents: [retitled]))

        var rekinded = event
        rekinded.kind = .dividend
        #expect(condition.requiresReview(at: now, currentEvents: [rekinded]))
    }

    @Test("A deleted linked event is reported missing, never matched to a lookalike")
    func missingEventRequiresReviewWithoutGuessing() {
        let linked = makeEvent(title: "Q3 earnings")
        let condition = TradePlanCondition(
            title: "Earnings", kind: .event, state: .confirmed, eventReference: linked
        )

        // Nothing at all to match against.
        #expect(condition.requiresReview(at: now, currentEvents: []))

        // A different identity with the same date and title is not a replacement.
        let lookalike = makeEvent(title: "Q3 earnings")
        #expect(condition.requiresReview(at: now, currentEvents: [lookalike]))

        // The very same identity is still the link.
        #expect(!condition.requiresReview(at: now, currentEvents: [linked, lookalike]))
    }

    @Test("Unconfirmed, review-due, and invalidated states all require review")
    func stateAndDateRequireReview() {
        let event = makeEvent()
        let pending = TradePlanCondition(
            title: "Earnings", kind: .event, state: .pending, eventReference: event
        )
        #expect(pending.requiresReview(at: now, currentEvents: [event]))

        var due = pending
        due.state = .confirmed
        due.reviewDate = now
        #expect(due.requiresReview(at: now, currentEvents: [event]), "today counts as due")

        due.reviewDate = Date(timeIntervalSince1970: 1_798_000_000)
        #expect(due.requiresReview(at: now, currentEvents: [event]), "a past date is due")

        due.reviewDate = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(!due.requiresReview(at: now, currentEvents: [event]), "a future date is not due")

        var invalidated = due
        invalidated.state = .invalidated
        #expect(invalidated.requiresReview(at: now, currentEvents: [event]))
    }

    @Test("requiresReview never mutates the condition and rejects an invalid reference")
    func normalizationValidatesTheReference() throws {
        let condition = TradePlanCondition(
            title: "Earnings", kind: .event, state: .confirmed,
            eventReference: makeEvent(title: "  Quarterly results  ")
        )
        // Normalizing trims the nested snapshot and is idempotent, which is what
        // `hasValidPayload` and the archive/codec validators compare against.
        let normalized = try #require(condition.normalized())
        #expect(normalized.eventReference?.title == "Quarterly results")
        #expect(normalized.normalized() == normalized)

        // An unusable reference refuses the whole condition rather than
        // silently dropping the link.
        var broken = condition
        broken.eventReference = makeEvent(title: "   ")
        #expect(broken.normalized() == nil)
        #expect(broken.requiresReview(at: now, currentEvents: []))

        // A non-finite nested date is likewise refused.
        broken.eventReference = makeEvent(date: Date(timeIntervalSince1970: .nan))
        #expect(broken.normalized() == nil)
    }

    // MARK: - Snapshot survives later plan changes

    @MainActor
    @Test("A linked event snapshot survives plan edits, a fill, and revision history")
    func referenceSurvivesPlanWorkflow() throws {
        let (store, defaults, suite) = try makeStore("snapshot-survives")
        defer { defaults.removePersistentDomain(forName: suite) }

        let event = makeEvent(title: "Q3 earnings")
        let condition = TradePlanCondition(
            title: "Wait for results", kind: .event, state: .pending, eventReference: event
        )
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition])
        #expect(store.setTradePlan(plan, for: symbol))

        // Edit the plan so a revision captures the linked condition.
        var edited = plan
        edited.price = 101
        #expect(store.setTradePlan(edited, for: symbol))
        let saved = try #require(store.item(for: symbol)?.plans.first)
        #expect(saved.conditions?.first?.eventReference == event)
        #expect(saved.history?.first?.configuration.conditions?.first?.eventReference == event)

        // The fill's immutable execution snapshot copies the conditions too.
        let transaction = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 101, quantity: 10,
            date: now, fee: nil, note: nil
        )
        #expect(transaction.planExecution?.configuration.conditions?.first?.eventReference == event)
        #expect(store.item(for: symbol)?.plans.first?.hasEventReferenceMetadata == true)
    }

    // MARK: - Review checkpoint

    @MainActor
    @Test("A checkpoint persists with zero financial or date changes")
    func checkpointPersistsWithoutTouchingTheLedger() throws {
        let (store, defaults, suite) = try makeStore("checkpoint")
        defer { defaults.removePersistentDomain(forName: suite) }

        let tradeDate = Date(timeIntervalSince1970: 1_700_000_000)
        let transaction = PositionTransaction(
            id: UUID(), kind: .buy, price: 180, quantity: 2,
            date: tradeDate, createdAt: tradeDate, fee: 1, note: "entry"
        )
        store.addTransaction(symbol, transaction)
        let before = try #require(store.item(for: symbol))

        // A note can stand on its own, with no date picked yet.
        #expect(store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry",
            review: PositionTransactionReview(nextReviewNote: "  watch next earnings  ")
        ))
        var saved = try #require(store.item(for: symbol))
        #expect(saved.transactions.first?.review?.nextReviewNote == "watch next earnings")
        #expect(saved.transactions.first?.review?.nextReviewDate == nil)

        // Then a date joins it.
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        #expect(store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry",
            review: PositionTransactionReview(
                followedPlan: true, nextReviewDate: due, nextReviewNote: "watch next earnings"
            )
        ))
        saved = try #require(store.item(for: symbol))
        #expect(saved.transactions.first?.review?.nextReviewDate == due)
        #expect(saved.transactions.first?.review?.followedPlan == true)

        // Nothing financial or dated moved.
        #expect(saved.transactions.map(\.id) == before.transactions.map(\.id))
        #expect(saved.transactions.map(\.price) == before.transactions.map(\.price))
        #expect(saved.transactions.map(\.quantity) == before.transactions.map(\.quantity))
        #expect(saved.transactions.map(\.fee) == before.transactions.map(\.fee))
        #expect(saved.transactions.map(\.date) == before.transactions.map(\.date))
        #expect(saved.transactions.map(\.createdAt) == before.transactions.map(\.createdAt))
        #expect(saved.positionQuantity == before.positionQuantity)
        #expect(saved.costBasis == before.costBasis)
        #expect(saved.realizedPnL == before.realizedPnL)

        // It reaches the agent readback and survives a reload.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let persisted = try #require(reloaded.item(for: symbol)?.transactions.first)
        #expect(persisted.review?.nextReviewDate == due)
        #expect(persisted.review?.nextReviewNote == "watch next earnings")
    }

    @MainActor
    @Test("An invalid checkpoint writes nothing and returns false")
    func invalidCheckpointWritesNothing() throws {
        let (store, defaults, suite) = try makeStore("invalid-checkpoint")
        defer { defaults.removePersistentDomain(forName: suite) }

        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 3)
        store.addTransaction(symbol, transaction)
        let before = try #require(store.item(for: symbol))

        #expect(!store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry",
            review: PositionTransactionReview(
                followedPlan: true, nextReviewDate: Date(timeIntervalSince1970: .infinity)
            )
        ))
        #expect(!store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry",
            review: PositionTransactionReview(nextReviewNote: String(repeating: "x", count: 4_001))
        ))

        let after = try #require(store.item(for: symbol))
        #expect(after == before, "a refused checkpoint leaves the transaction exactly as it was")
    }

    @MainActor
    @Test("A checkpoint-only review is stored rather than normalized away")
    func checkpointOnlyReviewIsKept() throws {
        let (store, defaults, suite) = try makeStore("empty-review")
        defer { defaults.removePersistentDomain(forName: suite) }

        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 1)
        store.addTransaction(symbol, transaction)

        #expect(store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry",
            review: PositionTransactionReview(nextReviewNote: "check the thesis")
        ))
        let saved = try #require(store.item(for: symbol)?.transactions.first)
        #expect(saved.review != nil)
        #expect(saved.review == PositionTransactionReview(nextReviewNote: "check the thesis"))

        // Clearing both checkpoint fields and nothing else empties the review.
        #expect(store.updateTransactionReview(
            symbol, id: transaction.id, note: "entry", review: PositionTransactionReview()
        ))
        #expect(store.item(for: symbol)?.transactions.first?.review == nil)
    }

    // MARK: - Archive gating

    @MainActor
    @Test("Archive round-trip keeps an event reference and a checkpoint")
    func archiveRoundTripKeepsNewMetadata() throws {
        let (source, sourceDefaults, sourceSuite) = try makeStore("archive-source")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }

        let event = makeEvent(title: "Q3 earnings")
        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: event
        )
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition])
        #expect(source.setTradePlan(plan, for: symbol))
        var edited = plan
        edited.price = 101
        #expect(source.setTradePlan(edited, for: symbol))
        _ = try source.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 101, quantity: 10,
            date: now, fee: nil, note: nil
        )
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        let tradeID = try #require(source.item(for: symbol)?.transactions.first?.id)
        #expect(source.updateTransactionReview(
            symbol, id: tradeID, note: nil,
            review: PositionTransactionReview(nextReviewDate: due, nextReviewNote: "check")
        ))

        let archive = source.archive()
        #expect(archive.version == 10, "inherited portion conditions must raise the declared version")
        let decoded = try WatchlistArchive.decoded(from: try archive.encoded())
        let entry = try #require(decoded.lists.first?.entries.first)
        #expect(entry.plans?.first?.conditions?.first?.eventReference == event)
        #expect(entry.plans?.first?.history?.first?.configuration.conditions?.first?.eventReference == event)
        #expect(entry.transactions?.first?.planExecution?.configuration.conditions?.first?.eventReference == event)
        #expect(entry.transactions?.first?.review?.nextReviewDate == due)
        #expect(entry.transactions?.first?.review?.nextReviewNote == "check")

        let (restored, restoredDefaults, restoredSuite) = try makeStore("archive-restored")
        defer { restoredDefaults.removePersistentDomain(forName: restoredSuite) }
        restored.merge(decoded)
        let restoredItem = try #require(restored.item(for: symbol))
        #expect(restoredItem.plans.first?.conditions?.first?.eventReference == event)
        #expect(restoredItem.transactions.first?.review?.nextReviewDate == due)
    }

    @MainActor
    @Test("An event reference that lives only in plan history still raises the archive version")
    func historyOnlyReferenceRaisesArchiveVersion() throws {
        let (store, defaults, suite) = try makeStore("archive-history-only")
        defer { defaults.removePersistentDomain(forName: suite) }

        let event = makeEvent()
        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: event
        )
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition])
        #expect(store.setTradePlan(plan, for: symbol))
        var edited = plan
        edited.price = 102
        #expect(store.setTradePlan(edited, for: symbol))
        // Strip the live link so only the revision's copy remains.
        var live = try #require(store.item(for: symbol)?.plans.first)
        live.conditions = live.conditions?.map { condition in
            var copy = condition
            copy.eventReference = nil
            return copy
        }
        #expect(store.setTradePlan(live, for: symbol))

        let archive = store.archive()
        let archivedPlan = try #require(archive.lists.first?.entries.first?.plans?.first)
        #expect(!archivedPlan.hasEventReference, "the live condition no longer links anything")
        #expect(archivedPlan.hasEventReferenceMetadata, "but a revision still does")
        #expect(archive.version == 9)
    }

    @MainActor
    @Test("An archive with only funding data still declares version 8")
    func fundingOnlyArchiveKeepsVersion8() throws {
        let (store, defaults, suite) = try makeStore("archive-funding-only")
        defer { defaults.removePersistentDomain(forName: suite) }

        let plan = TradePlan(kind: .buy, price: 10, quantity: 4, fundingSource: .margin)
        #expect(store.setTradePlan(plan, for: symbol))
        let archive = store.archive()
        #expect(archive.version == 8, "no event reference or checkpoint is present")

        // And a plain trade with no new metadata keeps an even older version.
        let (plain, plainDefaults, plainSuite) = try makeStore("archive-plain")
        defer { plainDefaults.removePersistentDomain(forName: plainSuite) }
        plain.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 1))
        #expect(plain.archive().version < 8)
    }

    @MainActor
    @Test("An archive claiming an old version while carrying new metadata is rejected")
    func lowDeclaredVersionWithNewMetadataIsRejected() throws {
        let (store, defaults, suite) = try makeStore("archive-lie")
        defer { defaults.removePersistentDomain(forName: suite) }

        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: makeEvent()
        )
        #expect(store.setTradePlan(
            TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition]), for: symbol
        ))
        let valid = try store.archive().encoded()
        let lowered = valid.replacingOccurrences(of: "\"version\" : 9", with: "\"version\" : 8")
        #expect(valid != lowered, "the fixture must actually lower the version")
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(9)) {
            try WatchlistArchive.decoded(from: lowered)
        }

        // The same lie told only through a transaction's checkpoint.
        let (checkpoint, checkpointDefaults, checkpointSuite) = try makeStore("archive-lie-checkpoint")
        defer { checkpointDefaults.removePersistentDomain(forName: checkpointSuite) }
        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 1)
        checkpoint.addTransaction(symbol, transaction)
        #expect(checkpoint.updateTransactionReview(
            symbol, id: transaction.id, note: nil,
            review: PositionTransactionReview(nextReviewDate: Date(timeIntervalSince1970: 1_900_000_000))
        ))
        let checkpointText = try checkpoint.archive().encoded()
            .replacingOccurrences(of: "\"version\" : 9", with: "\"version\" : 8")
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(9)) {
            try WatchlistArchive.decoded(from: checkpointText)
        }
    }

    @Test("An archive rejects an invalid event reference nested in history or an execution snapshot")
    func invalidNestedReferenceIsRejected() throws {
        func archive(withPlan plan: TradePlan, transaction: PositionTransaction? = nil) -> WatchlistArchive {
            WatchlistArchive(lists: [
                .init(name: "Core", entries: [
                    .init(market: .us, code: "AAPL", transactions: transaction.map { [$0] }, plans: [plan])
                ])
            ])
        }
        let bad = makeEvent(title: "   ")
        let brokenCondition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: bad
        )
        let goodCondition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: makeEvent()
        )
        let cleanPlan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [goodCondition])

        // Invalid nested in a revision's configuration.
        var brokenRevisionPlan = cleanPlan
        brokenRevisionPlan.conditions = [brokenCondition]
        let brokenConfiguration = TradePlanConfiguration(plan: brokenRevisionPlan)
        let historyPlan = TradePlan(
            kind: .buy, price: 100, quantity: 10, conditions: [goodCondition],
            history: [TradePlanRevision(configuration: brokenConfiguration)]
        )
        #expect(throws: WatchlistArchive.DecodingFailure.invalidTradePlan(historyPlan.id)) {
            try WatchlistArchive.decoded(from: try archive(withPlan: historyPlan).encoded())
        }

        // Invalid nested in the fill's execution snapshot.
        let execution = TradePlanExecution(planID: cleanPlan.id, configuration: brokenConfiguration)
        let transaction = PositionTransaction(
            kind: .buy, price: 100, quantity: 10, planExecution: execution
        )
        #expect(throws: WatchlistArchive.DecodingFailure.invalidPlanExecution(transaction.id)) {
            try WatchlistArchive.decoded(from: try archive(withPlan: cleanPlan, transaction: transaction).encoded())
        }
    }

    // MARK: - Wire format gating

    private func snapshot(plan: TradePlan? = nil, transaction: PositionTransaction? = nil) -> WatchlistSyncSnapshot {
        let item = WatchItem(
            symbol: symbol, displayName: "Apple",
            transactions: transaction.map { [$0] } ?? [],
            plans: plan.map { [$0] } ?? []
        )
        return WatchlistSyncSnapshot(items: [item], groups: [])
    }

    @Test("Wire round-trip keeps an event reference and a checkpoint and declares version 10")
    func wireRoundTripKeepsNewMetadata() throws {
        let event = makeEvent()
        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: event
        )
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition])
        let transaction = PositionTransaction(
            kind: .buy, price: 100, quantity: 10,
            review: PositionTransactionReview(nextReviewNote: "check")
        )
        let data = try WatchlistSyncWireCodec.encode(
            deviceID: "checkpoint-test", snapshot: snapshot(plan: plan, transaction: transaction)
        )
        let file = try WatchlistSyncWireCodec.decode(data)
        #expect(file.version == 10)
        let item = try #require(file.snapshot.items.first)
        #expect(item.plans.first?.conditions?.first?.eventReference == event)
        #expect(item.transactions.first?.review?.nextReviewNote == "check")
    }

    @Test("Funding-only state still encodes as version 9")
    func fundingOnlyStateKeepsVersion9() throws {
        let plan = TradePlan(kind: .buy, price: 10, quantity: 4, fundingSource: .margin)
        let data = try WatchlistSyncWireCodec.encode(
            deviceID: "funding-only", snapshot: snapshot(plan: plan)
        )
        let file = try WatchlistSyncWireCodec.decode(data)
        #expect(file.version == 9)
        #expect(file.snapshot.items.first?.plans.first?.fundingSource == .margin)
    }

    @Test("A payload declaring version 9 while carrying new metadata is rejected")
    func lowDeclaredWireVersionIsRejected() throws {
        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: makeEvent()
        )
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition])
        let data = try WatchlistSyncWireCodec.encode(
            deviceID: "lie", snapshot: snapshot(plan: plan)
        )
        // The envelope's declared version is a JSON number; drop it by ten.
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"version\" : 10", with: "\"version\" : 9")
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(10)) {
            try WatchlistSyncWireCodec.decode(Data(text.utf8))
        }
    }

    // MARK: - Merging

    @Test("Explicitly clearing a known checkpoint or event link survives sync")
    func clearingKnownMetadataSurvivesMerge() throws {
        let event = makeEvent()
        let condition = TradePlanCondition(title: "Review", kind: .event, eventReference: event)
        let plan = TradePlan(kind: .buy, price: 10, quantity: 1, conditions: [condition])
        let transaction = PositionTransaction(kind: .buy, price: 10, quantity: 1,
            review: .init(retrospective: "Reviewed", nextReviewDate: laterDate, nextReviewNote: "Check"))
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        let base = WatchlistSyncSnapshot(items: [.init(symbol: symbol, displayName: "Fictional",
            transactions: [transaction], plans: [plan])], groups: [group])
        var local = base
        local.items[0].transactions[0].review?.nextReviewDate = nil
        local.items[0].transactions[0].review?.nextReviewNote = nil
        local.items[0].plans[0].conditions?[0].eventReference = nil
        local.items[0].plans[0].updatedAt = plan.updatedAt.addingTimeInterval(10)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: base)
        let item = try #require(result.snapshot.items.first)
        #expect(item.transactions.first?.review?.nextReviewDate == nil)
        #expect(item.transactions.first?.review?.nextReviewNote == nil)
        #expect(item.plans.first?.conditions?.first?.eventReference == nil)
    }

    @Test("Merging fills a missing event reference without replacing one that exists")
    func mergeFillsMissingEventReference() throws {
        let linked = makeEvent(title: "Q3 earnings")
        let linkedCondition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: linked
        )
        var strippedCondition = linkedCondition
        strippedCondition.eventReference = nil
        let planID = UUID()
        let group = WatchlistGroup(name: "Core", symbols: [symbol])

        let base = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [
                TradePlan(id: planID, kind: .buy, price: 100, quantity: 10)
            ])], groups: [group]
        )
        let local = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [
                TradePlan(id: planID, kind: .buy, price: 100, quantity: 10, conditions: [linkedCondition])
            ])], groups: [group]
        )
        let remote = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [
                TradePlan(id: planID, kind: .buy, price: 100, quantity: 10, conditions: [strippedCondition])
            ])], groups: [group]
        )

        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        let mergedCondition = try #require(
            result.snapshot.items.first?.plans.first?.conditions?.first
        )
        #expect(mergedCondition.eventReference == linked, "the peer's link must not be lost")
    }

    @Test("Merging fills a checkpoint field by field without dropping the other")
    func mergeFillsCheckpointFieldByField() throws {
        let tradeID = UUID()
        let baseTrade = PositionTransaction(
            id: tradeID, kind: .buy, price: 10, quantity: 1,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var localTrade = baseTrade
        localTrade.review = PositionTransactionReview(nextReviewNote: "check the thesis")
        var remoteTrade = baseTrade
        remoteTrade.review = PositionTransactionReview(
            nextReviewDate: Date(timeIntervalSince1970: 1_900_000_000)
        )
        let group = WatchlistGroup(name: "Core", symbols: [symbol])
        func snapshot(_ transaction: PositionTransaction) -> WatchlistSyncSnapshot {
            WatchlistSyncSnapshot(
                items: [WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])],
                groups: [group]
            )
        }

        let result = WatchlistSyncMerge.merge(
            base: snapshot(baseTrade), local: snapshot(localTrade), remote: snapshot(remoteTrade)
        )
        let merged = try #require(result.snapshot.items.first?.transactions.first?.review)
        #expect(merged.nextReviewNote == "check the thesis")
        #expect(merged.nextReviewDate == Date(timeIntervalSince1970: 1_900_000_000))
    }

    @MainActor
    @Test("An ordinary trade edit cannot clear a checkpoint")
    func tradeEditPreservesCheckpoint() throws {
        let (store, defaults, suite) = try makeStore("edit-preserves")
        defer { defaults.removePersistentDomain(forName: suite) }

        let due = Date(timeIntervalSince1970: 1_900_000_000)
        var transaction = PositionTransaction(kind: .buy, price: 120, quantity: 3)
        transaction.review = PositionTransactionReview(
            followedPlan: true, nextReviewDate: due, nextReviewNote: "check"
        )
        store.addTransaction(symbol, transaction)

        var edited = try #require(store.item(for: symbol)?.transactions.first)
        edited.price = 121
        edited.review = nil
        store.updateTransaction(symbol, edited)

        let saved = try #require(store.item(for: symbol)?.transactions.first)
        #expect(saved.price == 121)
        #expect(saved.review?.nextReviewDate == due)
        #expect(saved.review?.nextReviewNote == "check")
    }

    @MainActor
    @Test("Archives and sync snapshots keep an event reference on a retained item")
    func retainedHistoryKeepsReference() throws {
        let (store, defaults, suite) = try makeStore("retained")
        defer { defaults.removePersistentDomain(forName: suite) }

        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 1))
        let event = makeEvent()
        let condition = TradePlanCondition(
            title: "Wait", kind: .event, state: .pending, eventReference: event
        )
        #expect(store.setTradePlan(
            TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [condition]), for: symbol
        ))
        store.remove(symbol)
        let retained = try #require(store.syncSnapshot().retainedHistoryItems.first)
        #expect(retained.plans.first?.conditions?.first?.eventReference == event)

        // The wire codec sees retained history too.
        let data = try WatchlistSyncWireCodec.encode(deviceID: "retained", snapshot: store.syncSnapshot())
        let file = try WatchlistSyncWireCodec.decode(data)
        #expect(file.version == 10)
        #expect(file.snapshot.retainedHistoryItems.first?.plans.first?.conditions?.first?.eventReference == event)

        // And it survives a reload, which re-normalizes stored state.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        #expect(reloaded.tradeHistoryItems.first?.plans.first?.conditions?.first?.eventReference == event)
    }
}
