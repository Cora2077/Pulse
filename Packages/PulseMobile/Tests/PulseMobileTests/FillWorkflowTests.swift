import Foundation
import PulseCore
import Testing

@testable import PulseMobile

@MainActor @Suite("Mobile fill workflow")
struct FillWorkflowTests {
    @Test("The frozen draft never carries a price until the user enters one")
    func priceIsNeverPreFilled() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 250, quantity: 4)

        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let draft = try #require(FillDraft.recording(entry, in: f.store))

        // The plan's trigger price must not leak into the fill draft.
        #expect(draft.price == nil)
        #expect(draft.quantity == nil)

        let fills = FillWorkflow(store: f.store)
        #expect(fills.submit(draft).error == .fillPriceRequired)

        var priced = draft
        priced.price = 249.5
        #expect(fills.submit(priced).error == .fillQuantityRequired)
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A plan-linked fill is written with the user's price and linked to the plan")
    func planFill() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 98.75
        draft.quantity = 4
        draft.fee = 1.5

        let outcome = FillWorkflow(store: f.store).submit(draft)
        let written = try #require(outcome.value)
        #expect(written.price == 98.75, "the fill records the executed price, not the plan's")
        #expect(written.quantity == 4)
        #expect(written.planExecution?.planID == plan.id)

        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(live.filledQuantity == 4)
        #expect(live.remainingQuantity == 6)
    }

    @Test("Retrying a written draft returns the stored record; two independent same-price fills both stay")
    func stableIDsAndSamePriceSameSize() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 20)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        func draft(_ entry: TradePlanEntry, id: UUID) -> FillDraft {
            var d = FillDraft.recording(entry, in: f.store, transactionID: id)!
            d.price = 50
            d.quantity = 5
            d.fee = 2
            return d
        }

        let firstID = UUID()
        let firstEntry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        // The draft is built once and submitted twice: a retry resubmits the
        // *same value*, not a freshly assembled lookalike (a new `recording`
        // call mints its own trade date and would honestly be a different
        // event).
        let submitted = draft(firstEntry, id: firstID)
        let first = try #require(fills.submit(submitted).value)

        // The very same draft, resubmitted. This is a retry of the same event,
        // so it succeeds and returns the record that is actually stored — with
        // its original `createdAt`, not a re-stamped one.
        let retried = fills.submit(submitted)
        let stored = try #require(retried.value)
        #expect(stored.id == firstID)
        #expect(stored.createdAt == first.createdAt, "a retry must not re-stamp createdAt")
        #expect(stored.price == 50)
        #expect(stored.quantity == 5)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1,
                "an idempotent retry must not write a second record")

        // Two independent fills at the same price and size are two events: they
        // carry different ids and are both kept. This one is opened afresh, the
        // way a second entry would be — the first entry's frozen revision is
        // genuinely stale now that the plan has moved.
        let secondEntry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let second = fills.submit(draft(secondEntry, id: UUID()))
        #expect(second.didWrite)
        #expect(second.value?.id != firstID)

        let final = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(final.filledQuantity == 10, "both fills must count")
        #expect(f.store.item(for: f.symbol)?.transactions.count == 2)
    }

    @Test("A retry of the same draft is answered even after the plan moved with the fill")
    func retryAfterPlanMovedWithFill() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 20)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        var submitted = try #require(FillDraft.recording(entry, in: f.store))
        submitted.price = 50
        submitted.quantity = 5
        _ = try #require(fills.submit(submitted).value)

        // The accepted write itself advanced the plan (progress and `updatedAt`),
        // so the draft's frozen revision is now stale. The retry must still be
        // recognised as the event it already wrote, not refused as a stale edit.
        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(live.plan.updatedAt != entry.plan.updatedAt)
        #expect(submitted.planRevision?.matches(live.plan) == false)

        let retried = fills.submit(submitted)
        #expect(retried.error == nil, "a retry of a written fill is a success, not a stale-plan refusal")
        #expect(retried.value?.id == submitted.transactionID)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A retry after an app restart, read back from a fresh store, succeeds with the same record")
    func retrySurvivesRelaunch() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 20)

        let entry = try #require(PlanWorkflow(store: f.store)
            .entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 42.5
        draft.quantity = 3
        draft.date = Date(timeIntervalSince1970: 1_700_000_000)
        let written = try #require(FillWorkflow(store: f.store).submit(draft).value)

        // The client never saw the answer: submit again through a *different*
        // store instance built over the same defaults, which is what a relaunch
        // looks like. The draft itself round-trips through Codable first, so the
        // retry is genuinely the value that was persisted, not a live copy.
        let data = try JSONEncoder().encode(draft)
        let restored = try JSONDecoder().decode(FillDraft.self, from: data)
        #expect(restored == draft)

        let relaunched = WatchlistStore(defaults: f.defaults)
        let outcome = FillWorkflow(store: relaunched).submit(restored)
        let stored = try #require(outcome.value)
        #expect(stored.id == written.id)
        #expect(stored.createdAt == written.createdAt)
        #expect(stored.price == 42.5)
        #expect(relaunched.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A retry whose values changed is refused rather than adopting the stored record")
    func conflictingRetryRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 20)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let id = UUID()
        var draft = try #require(FillDraft.recording(entry, in: f.store, transactionID: id))
        draft.price = 50
        draft.quantity = 5
        draft.fee = 1
        draft.date = Date(timeIntervalSince1970: 1_000)
        #expect(fills.submit(draft).didWrite)

        // An exact resubmission of that same value is the retry, and succeeds.
        #expect(fills.submit(draft).value?.id == id)

        // Each of these is the same id describing a different event. All are
        // refused, and the stored record is left alone.
        var differences: [FillDraft] = []
        var price = draft; price.price = 51; differences.append(price)
        var quantity = draft; quantity.quantity = 6; differences.append(quantity)
        var fee = draft; fee.fee = 9; differences.append(fee)
        var date = draft; date.date = Date(timeIntervalSince1970: 2_000); differences.append(date)
        var funding = draft; funding.fundingSource = .margin; differences.append(funding)
        var destination = draft; destination.destinationAccount = .mengmeng; differences.append(destination)
        // The note is a fact the draft states and the store writes; editing it
        // after the first attempt landed makes this a different event, not a
        // retry — adopting the stored record would silently drop the edit.
        var noted = draft; noted.note = "edited after the first attempt landed"; differences.append(noted)

        for changed in differences {
            let outcome = fills.submit(changed)
            #expect(outcome.error == .conflictingRetry(id), "\(changed) must not be adopted")
            #expect(outcome.draft?.price == changed.price, "the input must come back")
            #expect(!outcome.didWrite)
        }

        // A different plan is a different event too. The id is already taken by
        // the stored record this draft does not describe, so the honest answer
        // is the conflict — the plan-existence question never gets to decide
        // what an already-written id means.
        var otherPlan = FillDraft(
            symbol: draft.symbol, intent: draft.intent, planID: UUID(),
            kind: draft.kind, price: draft.price, quantity: draft.quantity,
            date: draft.date, fee: draft.fee,
            accountFreeze: draft.accountFreeze, transactionID: id)
        #expect(fills.submit(otherPlan).error == .conflictingRetry(id))
        #expect(!fills.submit(otherPlan).didWrite)

        let stored = try #require(f.store.item(for: f.symbol)?.transactions.first { $0.id == id })
        #expect(stored.price == 50)
        #expect(stored.quantity == 5)
        #expect(stored.fee == 1)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A retry is recognised even after the first fill completed the plan")
    func retryRecognisedAfterPlanCompleted() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        // The plan is complete after a single full-size fill, so the accepted
        // write derives `.done`.
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 5)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let id = UUID()
        var draft = try #require(FillDraft.recording(entry, in: f.store, transactionID: id))
        draft.price = 100
        draft.quantity = 5
        let written = try #require(fills.submit(draft).value)

        // The plan is now done, which is exactly the state that would make the
        // identical retry look like a fill against a stopped plan.
        let after = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(after.plan.status == .done)
        #expect(after.displayState == .filled)

        // The retry must be identified as the already-written event *before*
        // the plan-state gate is consulted.
        let retried = fills.submit(draft)
        #expect(retried.value?.id == written.id)
        #expect(retried.value?.createdAt == written.createdAt)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A margin buy in an account that does not permit it is refused and keeps the draft")
    func marginFundingRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 100
        draft.quantity = 1
        draft.destinationAccount = .mengmeng
        draft.fundingSource = .margin

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.error == .fundingNotAllowed(account: .mengmeng, funding: .margin))
        #expect(outcome.draft?.price == 100, "the refusal must return the user's input")
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A buy into the pending-history ledger is refused")
    func unassignedDestinationRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 100
        draft.quantity = 1
        draft.destinationAccount = .unassigned
        draft.fundingSource = .own

        #expect(FillWorkflow(store: f.store).submit(draft).error == .destinationNotAllowed(.unassigned))
    }

    @Test("A fill whose plan moved after the form opened is refused")
    func stalePlanRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 90
        draft.quantity = 10

        // The plan is re-sized on another device.
        var peerEdit = plan
        peerEdit.quantity = 99
        peerEdit.updatedAt = Date(timeIntervalSince1970: 5_000_000)
        #expect(f.store.setTradePlan(peerEdit, for: f.symbol))

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.error == .stalePlanRevision(plan.id))
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A fill is refused when the plan's content moved but its timestamp did not")
    func stalePlanWithoutTimestampChangeRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 90
        draft.quantity = 4

        // A peer rewrites the plan's content while `updatedAt` stays exactly as
        // the draft froze it. `setTradePlan` always re-stamps the clock, so this
        // shape arrives the way it really does in production — a sync merge, a
        // migration, or two edits inside one clock tick. It is constructed here
        // through the store's own sync entry point so the plan really is stored
        // that way.
        var peerEdit = plan
        peerEdit.note = "peer edit in the same tick"
        peerEdit.updatedAt = entry.plan.updatedAt
        let stored = try MobileFixture.replaceStoredPlan(peerEdit, symbol: f.symbol, in: f.store)

        // The plan really is stored with the frozen timestamp and different
        // content, so `expectedPlanUpdatedAt` alone cannot catch this.
        #expect(stored.updatedAt == draft.planRevision?.updatedAt)
        #expect(stored.note == "peer edit in the same tick")
        #expect(draft.planRevision?.matches(stored) == false)

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.error == .stalePlanRevision(plan.id))
        #expect(outcome.draft?.price == 90)
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("An ordinary fill on a stopped plan is refused; a backfill on the same plan is accepted")
    func backfillVersusOrdinary() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        // Reach the stopped state the way the store actually allows it: as a
        // plan edit that writes `.done`, not as a bare action. (There is no
        // "mark done" action; `stop` reports that honestly.)
        let editEntry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let editDraft = try #require(PlanDraft.editing(editEntry, in: f.store))
        let closed = workflow.setStatus(.done, on: editDraft)
        #expect(closed.value?.status == .done)

        let stopped = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(stopped.displayState == .stopped)
        #expect(stopped.canBackfillFill)

        var ordinary = try #require(FillDraft.recording(stopped, in: f.store))
        ordinary.price = 100
        ordinary.quantity = 3
        let refused = fills.submit(ordinary)
        #expect(refused.error == .planNotRecordable(status: .done, intent: .planFill))

        var backfill = try #require(FillDraft.recording(stopped, in: f.store, backfill: true))
        backfill.price = 101
        backfill.quantity = 3
        let written = fills.submit(backfill)
        #expect(written.didWrite)
        #expect(written.value?.price == 101)

        // A partial backfill must leave the plan stopped: the user's own
        // decision is not overturned by writing down a fact.
        let after = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(after.plan.status == .done)
        #expect(after.filledQuantity == 3)
    }

    @Test("An oversell beyond the real position is refused and writes nothing")
    func oversellRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        // Buy 10, then plan to sell 10, then try to sell 25.
        let buyPlan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        let buyEntry = try #require(workflow.entry(symbol: f.symbol, planID: buyPlan.id))
        var buy = try #require(FillDraft.recording(buyEntry, in: f.store))
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)

        let sell = TradePlan(kind: .sell, price: 120, quantity: 25)
        #expect(f.store.setTradePlan(sell, for: f.symbol))
        let sellEntry = try #require(workflow.entry(symbol: f.symbol, planID: sell.id))
        var sellDraft = try #require(FillDraft.recording(sellEntry, in: f.store))
        sellDraft.price = 120
        sellDraft.quantity = 25

        let outcome = fills.submit(sellDraft)
        #expect(outcome.error != nil, "an oversell must be refused")
        #expect(outcome.draft?.quantity == 25)
    }

    @Test("A plan-linked calibration is reported as unsupported, not approximated")
    func planLinkedAdjustmentUnsupported() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.kind = .adjustment
        draft.price = 100
        draft.quantity = 5
        #expect(FillWorkflow(store: f.store).submit(draft).error
            == .unsupported("plan-linked calibration"))
    }

    @Test("A standalone calibration is reported as unsupported and never reaches the ledger")
    func standaloneAdjustmentUnsupported() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        var draft = FillDraft.unlinked(symbol: f.symbol, kind: .adjustment, in: f.store)
        draft.price = 100
        draft.quantity = 5
        #expect(FillWorkflow(store: f.store).submit(draft).error
            == .unsupported("standalone calibration"))
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A standalone buy lands in the store with the draft's own id")
    func unlinkedBuy() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let id = UUID()
        var draft = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store, transactionID: id)
        draft.destinationAccount = .financing
        draft.fundingSource = .own
        draft.price = 42
        draft.quantity = 3

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.value?.id == id)
        #expect(outcome.value?.planExecution == nil, "a standalone fill carries no plan link")
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A plan-scoped intent without a plan, and a standalone intent with one, are both refused")
    func intentShapeRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let fills = FillWorkflow(store: f.store)

        var missingPlan = FillDraft(
            symbol: f.symbol, intent: .planFill, kind: .buy,
            price: 10, quantity: 1,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(fills.submit(missingPlan).error == .planRequired(.planFill))

        var planOnStandalone = FillDraft(
            symbol: f.symbol, intent: .unlinked, planID: plan.id, kind: .buy,
            price: 10, quantity: 1,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(fills.submit(planOnStandalone).error == .planNotAllowed(.unlinked))

        // Silences the unused-mutation warnings while documenting that the
        // values above are the whole draft.
        missingPlan.note = nil
        planOnStandalone.note = nil
    }

    @Test("A sale draft whose named portions do not sum to the fill is refused")
    func partialSaleSelectionRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let buyPlan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        let buyEntry = try #require(workflow.entry(symbol: f.symbol, planID: buyPlan.id))
        var buy = try #require(FillDraft.recording(buyEntry, in: f.store))
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)

        let sell = TradePlan(kind: .sell, price: 110, quantity: 4)
        #expect(f.store.setTradePlan(sell, for: f.symbol))
        let sellEntry = try #require(workflow.entry(symbol: f.symbol, planID: sell.id))
        var sellDraft = try #require(FillDraft.recording(sellEntry, in: f.store))
        sellDraft.price = 110
        sellDraft.quantity = 4
        // A selection that does not add up to the fill, and no frozen revision.
        sellDraft.salePortionQuantities = [UUID(): 2]

        #expect(fills.submit(sellDraft).error == .saleSelectionIncomplete)

        sellDraft.saleAllocationRevision = f.store.item(for: f.symbol)?.positionAllocation?.revision
        #expect(fills.submit(sellDraft).error == .saleSelectionIncomplete)
    }

    @Test("A draft frozen with named ledgers off is refused against a store that has them on")
    func accountModeChangeRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        var draft = FillDraft(
            symbol: f.symbol, intent: .unlinked, kind: .buy,
            price: 10, quantity: 1,
            accountFreeze: AccountFreeze(account: .unassigned, brokerageAccountsEnabled: false)
        )
        draft.destinationAccount = .financing
        // The mode mismatch is the more truthful refusal: the draft describes a
        // store with no named ledgers and this one has them, so the frozen
        // account it names (`.unassigned`) is not even a ledger here.
        #expect(FillWorkflow(store: f.store).submit(draft).error == .accountModeChanged)
    }

    // MARK: - Account switching
    //
    // The store's plan-fill route can only ever fill a plan in the *selected*
    // ledger, and `item(for:)` reads that same ledger. So a draft frozen in one
    // account and submitted while another is selected has no lawful write: it
    // must be refused, with the input kept, rather than quietly landing in — or
    // reading a namesake from — the wrong ledger.

    @Test("A plan draft is refused after the store switches accounts, and reads no namesake plan")
    func planDraftRefusedAfterAccountSwitch() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }

        // Seed the same symbol — and the same plan id — into both ledgers. A
        // wrapper that read the selection instead of the freeze would resolve
        // the *other* ledger's namesake and fill it.
        let sharedPlanID = UUID()
        func seedCopy(in account: BrokerageAccountID, price: Double) {
            f.store.withBrokerageAccount(account) {
                f.store.add(SymbolInfo(symbol: f.symbol, name: "Fictional mobile fixture"))
                var plan = TradePlan(id: sharedPlanID, kind: .buy, price: price, quantity: 10)
                plan.updatedAt = Date(timeIntervalSince1970: 1_000)
                #expect(f.store.setTradePlan(plan, for: f.symbol))
            }
        }
        seedCopy(in: .financing, price: 100)
        seedCopy(in: .mengmeng, price: 999)

        // `withBrokerageAccount` restores whatever was selected when it was
        // entered, so the selection is still the fixture's original. Move away
        // and back to prove the ledger the draft will freeze is really the one
        // selected, and that the switch below is a real move.
        #expect(f.store.activeBrokerageAccountID == .financing)
        #expect(f.store.selectBrokerageAccount(.unassigned))
        #expect(f.store.selectBrokerageAccount(.financing))
        #expect(f.store.activeBrokerageAccountID == .financing)
        let entry = try #require(PlanWorkflow(store: f.store)
            .entry(symbol: f.symbol, planID: sharedPlanID, account: .financing))
        #expect(entry.plan.price == 100)
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 100
        draft.quantity = 4

        // The user switches the whole app to the other ledger.
        #expect(f.store.selectBrokerageAccount(.mengmeng))

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.error == .accountChanged(expected: .financing, actual: .mengmeng))
        #expect(outcome.draft?.price == 100, "the typed price must survive the refusal")
        #expect(outcome.draft?.quantity == 4)

        // Neither ledger was touched: not the frozen one, and above all not the
        // namesake plan in the ledger that happens to be selected.
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.transactions.isEmpty == true)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.isEmpty == true)
    }

    @Test("A standalone draft is refused after the store switches accounts")
    func standaloneDraftRefusedAfterAccountSwitch() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        var draft = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        draft.destinationAccount = .financing
        draft.fundingSource = .own
        draft.price = 10
        draft.quantity = 1

        #expect(f.store.selectBrokerageAccount(.mengmeng))

        let outcome = FillWorkflow(store: f.store).submit(draft)
        #expect(outcome.error == .accountChanged(expected: .financing, actual: .mengmeng))
        #expect(outcome.draft?.price == 10)
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.transactions.isEmpty == true)
    }

    @Test("A plan draft is refused when the mode changed, not merely the selection")
    func planDraftRefusedOnModeChange() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let entry = try #require(PlanWorkflow(store: f.store)
            .entry(symbol: f.symbol, planID: plan.id))

        // A draft frozen in the single-ledger shape, with the mode now on.
        let draft = FillDraft(
            symbol: f.symbol, intent: .planFill, planID: plan.id, kind: .buy,
            price: 10, quantity: 1,
            accountFreeze: AccountFreeze(account: .unassigned, brokerageAccountsEnabled: false)
        )
        #expect(FillWorkflow(store: f.store).submit(draft).error == .accountModeChanged)
        #expect(entry.plan.id == plan.id)
    }

    @Test("An explicit destination may differ from the frozen source, which stays fixed")
    func explicitDestinationAllowed() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        // Opened on financing, executed into mengmeng. The plan stays in its own
        // ledger; only the fill moves, and the source it records is the plan's.
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.destinationAccount = .mengmeng
        draft.fundingSource = .own
        draft.price = 100
        draft.quantity = 3

        let written = try #require(FillWorkflow(store: f.store).submit(draft).value)
        #expect(written.brokerageAccountID == .mengmeng)
        #expect(written.planExecution?.sourceAccountID == .financing,
                "the source ledger is frozen and must not follow the destination")

        // The fill is in the destination; the plan still lives in its own
        // ledger and counts the fill.
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.contains { $0.id == written.id } == true)
        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id, account: .financing))
        #expect(live.accountID == .financing)
    }

    @Test("The destination display read uses the frozen ledger, not the selection")
    func destinationLedgerUsesFrozenAccount() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let entry = try #require(PlanWorkflow(store: f.store)
            .entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.destinationAccount = nil

        #expect(f.store.selectBrokerageAccount(.mengmeng))
        // The draft's own ledger is still the answer: the selection moved, the
        // freeze did not.
        #expect(FillWorkflow(store: f.store).destinationLedger(for: draft) == .financing)
    }

    @Test("A standalone sale is written into its explicit destination ledger")
    func standaloneSellHonoursDestination() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let fills = FillWorkflow(store: f.store)

        // Shares exist only in mengmeng.
        var buy = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        buy.destinationAccount = .mengmeng
        buy.fundingSource = .own
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)

        // The form is frozen on the financing selection, but the sale
        // explicitly names the ledger whose shares it consumes. That statement
        // must be honoured, never silently re-pointed at the frozen account.
        var sell = FillDraft.unlinked(symbol: f.symbol, kind: .sell, in: f.store)
        sell.destinationAccount = .mengmeng
        sell.price = 110
        sell.quantity = 4

        let written = try #require(fills.submit(sell).value)
        #expect(written.brokerageAccountID == .mengmeng)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.contains { $0.id == written.id } == true,
                "the sale must consume the ledger it named")
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.transactions.isEmpty != false,
                "the frozen account was never touched")

        // And the same draft retried is adopted, not refused as a conflict:
        // the record now agrees with every fact the draft states.
        let retried = fills.submit(sell)
        #expect(retried.error == nil)
        #expect(retried.value?.id == written.id)
        #expect(retried.value?.createdAt == written.createdAt)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.count == 2,
                "the seed buy plus exactly one sale — the retry wrote nothing")
    }

    @Test("A standalone sale cannot name portions: the store's route cannot store the selection")
    func standaloneSellPortionsUnsupported() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let fills = FillWorkflow(store: f.store)

        var buy = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        buy.destinationAccount = .financing
        buy.fundingSource = .own
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)
        let portionID = try #require(f.store.item(for: f.symbol)?.positionAllocation?.portions.first?.id)

        var sell = FillDraft.unlinked(symbol: f.symbol, kind: .sell, in: f.store)
        sell.price = 110
        sell.quantity = 4
        sell.salePortionQuantities = [portionID: 4]
        sell.saleAllocationRevision = f.store.item(for: f.symbol)?.positionAllocation?.revision

        // `addNamedTransaction` has no portion-selection parameter, so the
        // selection could be validated and then silently dropped. The honest
        // answer is that this build does not wrap that route.
        let outcome = fills.submit(sell)
        guard case let .unsupported(route) = outcome.error else {
            Issue.record("a standalone sale naming portions must be unsupported, not \(String(describing: outcome.error))")
            return
        }
        #expect(route.contains("standalone sale"))
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1, "nothing was written")
        #expect(f.store.item(for: f.symbol)?.positionAllocation?.portions.first?.quantity == 10)
    }

    @Test("A cross-ledger fill's retry returns the stored record instead of a false conflict")
    func crossLedgerFillRetryAdopted() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        // Opened on financing, executed into mengmeng: the fill is written into
        // the destination ledger, which is not the frozen one.
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.destinationAccount = .mengmeng
        draft.fundingSource = .own
        draft.price = 100
        draft.quantity = 3
        let written = try #require(fills.submit(draft).value)
        #expect(written.brokerageAccountID == .mengmeng)

        // The client never saw the answer. The retry must find the record in
        // the ledger it actually landed in and return it — not report a
        // conflict that invites the user to record the trade a second time.
        let retried = fills.submit(draft)
        #expect(retried.error == nil)
        #expect(retried.value?.id == written.id)
        #expect(retried.value?.createdAt == written.createdAt)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.count == 1,
                "the retry must not write a second record")
    }

    @Test("A retry is recognised even after the plan it filled was deleted")
    func retryRecognisedAfterPlanDeleted() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        // A full-size fill completes the plan, and the user then cleans the
        // finished plan up. The record of the fill is still in the ledger.
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 5)
        let fills = FillWorkflow(store: f.store)
        let entry = try #require(PlanWorkflow(store: f.store)
            .entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(FillDraft.recording(entry, in: f.store))
        draft.price = 100
        draft.quantity = 5
        let written = try #require(fills.submit(draft).value)

        #expect(f.store.deleteTradePlan(plan.id, for: f.symbol))
        #expect(f.store.item(for: f.symbol)?.plans.isEmpty == true)

        // The retry must be recognised as the already-written event *before*
        // the plan-existence question is asked: the plan being gone says
        // nothing about whether the fill landed.
        let retried = fills.submit(draft)
        #expect(retried.error == nil)
        #expect(retried.value?.id == written.id)
        #expect(retried.value?.createdAt == written.createdAt)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 1)
    }

    @Test("A plan fill without a frozen revision is refused rather than writing blind")
    func planFillWithoutRevisionRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let fills = FillWorkflow(store: f.store)

        // Hand-built, as a caller that lost the freeze would construct it: the
        // plan id is right but no revision was ever taken. Every other draft
        // route fails closed on a missing expectation; this one must too.
        let draft = FillDraft(
            symbol: f.symbol, intent: .planFill, planID: plan.id, kind: .buy,
            price: 100, quantity: 4,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(draft.planRevision == nil)
        #expect(fills.submit(draft).error == .stalePlanRevision(plan.id))
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)

        // The backfill intent is held to the same bar.
        let workflow = PlanWorkflow(store: f.store)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let editDraft = try #require(PlanDraft.editing(entry, in: f.store))
        #expect(workflow.setStatus(.done, on: editDraft).didWrite)
        let backfill = FillDraft(
            symbol: f.symbol, intent: .planBackfill, planID: plan.id, kind: .buy,
            price: 100, quantity: 4,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(fills.submit(backfill).error == .stalePlanRevision(plan.id))
        #expect(f.store.item(for: f.symbol)?.transactions.isEmpty == true)
    }

    @Test("A retry that changes the sale portions is refused; the same portions are adopted")
    func portionedSaleRetrySemantics() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        // Hold 10, then sell 4 of one named card against a sell plan.
        let buyPlan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)
        let buyEntry = try #require(workflow.entry(symbol: f.symbol, planID: buyPlan.id))
        var buy = try #require(FillDraft.recording(buyEntry, in: f.store))
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)
        let portionID = try #require(f.store.item(for: f.symbol)?.positionAllocation?.portions.first?.id)

        let sellPlan = TradePlan(kind: .sell, price: 110, quantity: 4)
        #expect(f.store.setTradePlan(sellPlan, for: f.symbol))
        let sellEntry = try #require(workflow.entry(symbol: f.symbol, planID: sellPlan.id))
        var sell = try #require(FillDraft.recording(sellEntry, in: f.store))
        sell.price = 110
        sell.quantity = 4
        sell.salePortionQuantities = [portionID: 4]
        sell.saleAllocationRevision = f.store.item(for: f.symbol)?.positionAllocation?.revision

        let written = try #require(fills.submit(sell).value)

        // The honest retry: the stored record plus the allocation change it
        // produced are exactly what the draft states, so it is adopted.
        let retried = fills.submit(sell)
        #expect(retried.error == nil)
        #expect(retried.value?.id == written.id)
        #expect(f.store.item(for: f.symbol)?.transactions.count == 2)

        // Same id, different portion intent: a different event. Adopting it
        // would tell the user their new split was recorded when nothing moved.
        var otherCard = sell
        otherCard.salePortionQuantities = [UUID(): 4]
        #expect(fills.submit(otherCard).error == .conflictingRetry(sell.transactionID))
        var otherAmount = sell
        otherAmount.salePortionQuantities = [portionID: 2]
        #expect(fills.submit(otherAmount).error == .conflictingRetry(sell.transactionID))

        // Nothing was written by either refusal.
        #expect(f.store.item(for: f.symbol)?.transactions.count == 2)
        #expect(f.store.item(for: f.symbol)?.positionAllocation?.portions.first?.quantity == 6)
    }

    @Test("A cross-account plan sale consumes the executing ledger, and its retry is adopted")
    func crossLedgerPlanSaleRetryAdopted() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let fills = FillWorkflow(store: f.store)

        // Shares exist only in mengmeng; the sell plan lives in financing.
        var buy = FillDraft.unlinked(symbol: f.symbol, kind: .buy, in: f.store)
        buy.destinationAccount = .mengmeng
        buy.fundingSource = .own
        buy.price = 100
        buy.quantity = 10
        #expect(fills.submit(buy).didWrite)

        let sellPlan = TradePlan(kind: .sell, price: 110, quantity: 4)
        #expect(f.store.setTradePlan(sellPlan, for: f.symbol))
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: sellPlan.id,
                                                account: .financing))
        var sell = try #require(FillDraft.recording(entry, in: f.store))
        sell.destinationAccount = .mengmeng
        sell.price = 110
        sell.quantity = 4
        // The cards and the revision are the *executing* ledger's, which is
        // what the store's cross-account route checks them against.
        let executing = try #require(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol })
        let portionID = try #require(executing.positionAllocation?.portions.first?.id)
        sell.salePortionQuantities = [portionID: 4]
        sell.saleAllocationRevision = executing.positionAllocation?.revision

        let written = try #require(fills.submit(sell).value)
        #expect(written.brokerageAccountID == .mengmeng)
        #expect(written.planExecution?.sourceAccountID == .financing,
                "the plan's ledger is the source even when the fill lands elsewhere")
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.contains { $0.id == written.id } == true)
        #expect(f.store.item(for: f.symbol)?.transactions
            .contains { $0.id == written.id } != true,
                "the plan's ledger holds the plan, not the fill")
        let livePlan = try #require(workflow.entry(symbol: f.symbol, planID: sellPlan.id,
                                                   account: .financing))
        #expect(livePlan.filledQuantity == 4, "the plan counts the cross-ledger fill")

        // The retry finds the record in the executing ledger and proves the
        // portion selection from that ledger's allocation history.
        let retried = fills.submit(sell)
        #expect(retried.error == nil)
        #expect(retried.value?.id == written.id)
        #expect(retried.value?.createdAt == written.createdAt)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.count == 2)

        // Same id, changed portion intent: refused, not adopted.
        var otherAmount = sell
        otherAmount.salePortionQuantities = [portionID: 2]
        #expect(fills.submit(otherAmount).error == .conflictingRetry(sell.transactionID))
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.transactions.count == 2)
    }
}
