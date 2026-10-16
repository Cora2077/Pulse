import Foundation
import PulseCore
import Testing

@testable import PulseMobile

@MainActor @Suite("Mobile frozen draft models")
struct MobileDraftModelTests {
    @Test("Plan draft round-trips through Codable without losing a field")
    func planDraftCodable() throws {
        let symbol = SymbolID(market: .us, code: "QACODE")
        let planID = UUID()
        let portionID = UUID()
        let draft = PlanDraft(
            planID: planID,
            symbol: symbol,
            kind: .sell,
            price: 123.456,
            quantity: 7,
            note: "why",
            conditions: [TradePlanCondition(title: "c", kind: .manual, state: .pending)],
            positionPool: .strategic,
            positionPortionID: portionID,
            fundingSource: .margin,
            executionAccountID: .financing,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true),
            revision: PlanRevisionStamp(updatedAt: Date(timeIntervalSince1970: 42),
                                        contentDigest: "abc"),
            allocationRevision: UUID(),
            newPlanID: UUID()
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(PlanDraft.self, from: data)
        #expect(decoded == draft)
        #expect(decoded.positionPortionID == portionID)
        #expect(decoded.revision?.contentDigest == "abc")
        #expect(decoded.newPlanID == draft.newPlanID)
    }

    @Test("Fill draft round-trips, and an absent price stays absent")
    func fillDraftCodable() throws {
        let draft = FillDraft(
            symbol: SymbolID(market: .hk, code: "0700"),
            intent: .planBackfill,
            planID: UUID(),
            kind: .sell,
            price: nil,
            quantity: nil,
            date: Date(timeIntervalSince1970: 1_000),
            fee: 0.5,
            note: nil,
            destinationAccount: .financing,
            salePortionQuantities: [UUID(): 3],
            planRevision: PlanRevisionStamp(updatedAt: .now, contentDigest: "d"),
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true),
            transactionID: UUID()
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(FillDraft.self, from: data)
        #expect(decoded == draft)
        // The critical part: an un-entered price must survive a trip through
        // storage as "no price", never as a zero or a default.
        #expect(decoded.price == nil)
        #expect(decoded.quantity == nil)
    }

    @Test("Transaction edit draft round-trips and rebuilds the frozen original")
    func editDraftCodable() throws {
        let record = PositionTransaction(id: UUID(), kind: .buy, price: 10, quantity: 2,
                                         note: "orig", fundingSource: .own)
        let draft = TransactionEditDraft(
            original: TransactionRevisionStamp(record: record),
            symbol: SymbolID(market: .us, code: "QAEDIT"),
            price: 11, quantity: 3, date: record.date, note: "new",
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(TransactionEditDraft.self, from: data)
        #expect(decoded == draft)
        // Everything the form does not own is carried through from the original.
        #expect(decoded.candidate.id == record.id)
        #expect(decoded.candidate.createdAt == record.createdAt)
        #expect(decoded.candidate.kind == .buy)
        #expect(decoded.candidate.price == 11)
    }

    @Test("A plan revision stamp matches only the exact stored plan")
    func revisionStamp() throws {
        var plan = TradePlan(kind: .buy, price: 100, quantity: 10, note: "a")
        let stamp = PlanRevisionStamp(of: plan)
        #expect(stamp.matches(plan))

        // A value change with the timestamp untouched still breaks the stamp.
        plan.price = 101
        #expect(!stamp.matches(plan))

        // A timestamp-only change breaks it too.
        plan.price = 100
        plan.updatedAt = Date(timeIntervalSince1970: 9_000_000)
        #expect(!stamp.matches(plan))

        // A pool, a funding intention, and a card binding are all part of it.
        plan.updatedAt = stamp.updatedAt
        plan.positionPool = .tactical
        #expect(!stamp.matches(plan))
        plan.positionPool = nil
        plan.fundingSource = .margin
        #expect(!stamp.matches(plan))
        plan.fundingSource = nil
        plan.executionAccountID = .mengmeng
        #expect(!stamp.matches(plan))
        plan.executionAccountID = nil
        #expect(stamp.matches(plan))
    }

    @Test("The revision digest is stable across equal plans and changes when conditions are reordered")
    func revisionDigestStability() {
        let first = TradePlanCondition(title: "one", kind: .manual, state: .pending)
        let second = TradePlanCondition(title: "two", kind: .event, state: .confirmed)
        var a = TradePlan(kind: .buy, price: 100, quantity: 10, conditions: [first, second])
        var b = TradePlan(id: a.id, kind: .buy, price: 100, quantity: 10,
                          createdAt: a.createdAt, updatedAt: a.updatedAt,
                          conditions: [first, second])
        // Two plans with identical values have one digest, regardless of how the
        // values were spelled into the initializer.
        #expect(PlanRevisionStamp.digest(of: a) == PlanRevisionStamp.digest(of: b))

        // Reordering the condition array IS a change: the store persists the
        // array the user saved, so a reorder is a real edit and must not be
        // able to slip past the frozen revision.
        b.conditions = [second, first]
        #expect(PlanRevisionStamp.digest(of: a) != PlanRevisionStamp.digest(of: b))

        b.conditions = [first]
        #expect(PlanRevisionStamp.digest(of: a) != PlanRevisionStamp.digest(of: b))

        // History is part of the stored plan, and a revision that hid it would
        // let an appended revision pass unnoticed.
        b.conditions = [first, second]
        a.history = [TradePlanRevision(configuration: TradePlanConfiguration(plan: a))]
        #expect(PlanRevisionStamp.digest(of: a) != PlanRevisionStamp.digest(of: b))
    }

    @Test("The digest is a real SHA-256 over a deterministic encoding, and fails closed")
    func revisionDigestCanonical() throws {
        var plan = TradePlan(kind: .buy, price: 100, quantity: 10, note: "text")
        plan.conditions = [TradePlanCondition(title: "c", kind: .manual, state: .pending)]

        // A hex SHA-256, not a hand-joined string.
        let digest = PlanRevisionStamp.digest(of: plan)
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit })

        // The canonical encoding is deterministic and key-sorted, so two
        // encodings of equal values are byte-identical.
        let first = try #require(PlanRevisionStamp.canonicalEncoding(of: plan))
        let second = try #require(PlanRevisionStamp.canonicalEncoding(of: plan))
        #expect(first == second)
        let json = try #require(String(data: first, encoding: .utf8))
        #expect(json.contains("\"conditions\""), "every stored field must be covered")
        #expect(json.contains("\"updatedAt\""))

        // `history` is covered too. JSON omits a `nil` optional, so it appears
        // exactly when the plan carries one — which is the point: an appended
        // revision changes the bytes.
        var withHistory = plan
        withHistory.history = [TradePlanRevision(configuration: TradePlanConfiguration(plan: plan))]
        let historyData = try #require(PlanRevisionStamp.canonicalEncoding(of: withHistory))
        let historyJSON = try #require(String(data: historyData, encoding: .utf8))
        #expect(historyJSON.contains("\"history\""))
        #expect(PlanRevisionStamp.digest(of: withHistory) != digest)

        // Free text cannot forge a boundary: the old separator-joined form could
        // collide when a note contained the separator.
        var forged = plan
        forged.note = "text\u{1f}buy"
        #expect(PlanRevisionStamp.digest(of: forged) != digest)

        // An event reference is covered, so changing the linked event changes
        // the digest rather than hiding inside an unhashed nested value.
        var withEvent = plan
        let event = InstrumentEvent(kind: .earnings, date: Date(timeIntervalSince1970: 500), title: "E")
        withEvent.conditions = [TradePlanCondition(title: "c", kind: .event, state: .pending,
                                                   eventReference: event)]
        #expect(PlanRevisionStamp.digest(of: withEvent) != digest)
        var movedEvent = withEvent
        movedEvent.conditions = [TradePlanCondition(
            title: "c", kind: .event, state: .pending,
            eventReference: InstrumentEvent(id: event.id, kind: .earnings,
                                            date: Date(timeIntervalSince1970: 900), title: "E"))]
        #expect(PlanRevisionStamp.digest(of: movedEvent) != PlanRevisionStamp.digest(of: withEvent))
    }

    @Test("A stamp taken from an unencodable plan fails closed and never matches")
    func revisionStampFailsClosed() {
        // A NaN price is not representable in JSON, so the canonical encoding
        // genuinely fails. The stamp must not fall back to a weaker comparison.
        let broken = TradePlan(kind: .buy, price: .nan, quantity: 10)
        let stamp = PlanRevisionStamp(of: broken)
        #expect(stamp.contentDigest == PlanRevisionStamp.unencodableDigest)
        // Even the same value it was built from does not match: a revision this
        // layer could not read is not a revision it froze.
        #expect(!stamp.matches(broken))
        // And it can never be confused with a real digest.
        let real = TradePlan(kind: .buy, price: 100, quantity: 10)
        #expect(PlanRevisionStamp.digest(of: real) != PlanRevisionStamp.unencodableDigest)
        #expect(!PlanRevisionStamp(of: real).matches(broken))
    }

    @Test("A same-timestamp edit is caught by the digest, not by updatedAt")
    func revisionCatchesSameTimestampEdit() {
        var plan = TradePlan(kind: .buy, price: 100, quantity: 10, note: "first")
        let stamp = PlanRevisionStamp(of: plan)
        #expect(stamp.matches(plan))

        // A peer rewrites the note without the clock moving. `updatedAt` alone
        // would call this current; the digest must not.
        plan.note = "second"
        #expect(plan.updatedAt == stamp.updatedAt)
        #expect(!stamp.matches(plan))

        // A whole-field addition the old manual digest never knew about.
        plan.note = "first"
        #expect(stamp.matches(plan))
        plan.history = [TradePlanRevision(configuration: TradePlanConfiguration(plan: plan))]
        #expect(!stamp.matches(plan))
    }

    @Test("A transaction revision stamp is exact equality, not a timestamp")
    func transactionStamp() throws {
        var record = PositionTransaction(kind: .buy, price: 10, quantity: 2)
        let stamp = TransactionRevisionStamp(record: record)
        #expect(stamp.matches(record))

        // A review edit changes content without touching any date the wrapper
        // could have compared.
        record.review = PositionTransactionReview(retrospective: "learned something")
        #expect(!stamp.matches(record))
    }

    @Test("The account freeze distinguishes the three ways a draft can go stale")
    func accountFreeze() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }

        let live = AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        #expect(live.matches(f.store))
        #expect(live.isSelfConsistent)
        #expect(live.allowsNamed(.mengmeng))
        #expect(!live.allowsNamed(.unassigned))

        let otherAccount = AccountFreeze(account: .mengmeng, brokerageAccountsEnabled: true)
        #expect(!otherAccount.matches(f.store))

        let otherMode = AccountFreeze(account: .financing, brokerageAccountsEnabled: false)
        #expect(!otherMode.matches(f.store))
        #expect(!otherMode.isSelfConsistent)

        let unnamed = AccountFreeze(account: .unassigned, brokerageAccountsEnabled: false)
        #expect(unnamed.isSelfConsistent)
        #expect(!unnamed.allowsNamed(.financing))
    }

    @Test("An outcome carries the draft back on refusal and nothing on success")
    func outcomeShape() {
        let success: MobileWorkflowOutcome<String, Int> = .written(7)
        #expect(success.value == 7)
        #expect(success.error == nil)
        #expect(success.draft == nil)

        let refused: MobileWorkflowOutcome<String, Int> = .refused(.fillPriceRequired, draft: "typed")
        #expect(refused.value == nil)
        #expect(refused.error == .fillPriceRequired)
        #expect(refused.draft == "typed")
        #expect(!refused.didWrite)
    }

    @Test("Kind bridging is explicit in both directions")
    func kindBridging() {
        #expect(TradePlan.Kind.buy.transactionKind == .buy)
        #expect(TradePlan.Kind.sell.transactionKind == .sell)
        #expect(PositionTransaction.Kind.buy.planKind == .buy)
        #expect(PositionTransaction.Kind.sell.planKind == .sell)
        // A calibration is not a side, and must not masquerade as one.
        #expect(PositionTransaction.Kind.adjustment.planKind == nil)
    }

    @Test("Every refusal describes itself in words")
    func refusalDescriptions() {
        let all: [MobileWorkflowError] = [
            .itemNotFound(SymbolID(market: .us, code: "X")),
            .planNotFound(UUID()),
            .stalePlanRevision(UUID()),
            .staleTransactionRecord(UUID()),
            .accountChanged(expected: .financing, actual: .mengmeng),
            .accountModeChanged,
            .accountUnavailable(.unassigned),
            .destinationNotAllowed(.unassigned),
            .fundingNotAllowed(account: .mengmeng, funding: .margin),
            .fillPriceRequired,
            .fillQuantityRequired,
            .invalidFillValues,
            .planRequired(.planFill),
            .planNotAllowed(.unlinked),
            .kindMismatch(plan: .buy, draft: .sell),
            .planNotRecordable(status: .done, intent: .planFill),
            .saleSelectionIncomplete,
            .staleAllocationRevision,
            .transactionNotFound(UUID()),
            .immutablePlanContext,
            .negativePosition,
            .storeRejected("because"),
            .unsupported("a route")
        ]
        for error in all {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "\(error) has no description")
        }
    }
}
