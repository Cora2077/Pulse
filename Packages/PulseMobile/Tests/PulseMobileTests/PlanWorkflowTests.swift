import Foundation
import PulseCore
import Testing

@testable import PulseMobile

@MainActor @Suite("Mobile plan workflow")
struct PlanWorkflowTests {
    @Test("A new plan is written with the draft's own values and read back from the store")
    func createPlan() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.kind = .buy
        draft.price = 12.5
        draft.quantity = 40
        draft.note = "  entry thesis  "
        draft.positionPool = .tactical
        draft.fundingSource = .own

        let outcome = workflow.save(draft)
        let written = try #require(outcome.value)
        #expect(outcome.didWrite)
        #expect(written.price == 12.5)
        #expect(written.quantity == 40)
        // The store's own note normalization, not a mobile copy of it.
        #expect(written.note == "entry thesis")
        #expect(written.positionPool == .tactical)
        #expect(written.fundingSource == .own)

        // Read back through the store: the write must be persisted, not
        // merely returned.
        let stored = try #require(f.store.item(for: f.symbol)?.plans.first)
        #expect(stored.id == written.id)
        #expect(stored.price == 12.5)
    }

    @Test("An edit preserves the plan's identity, createdAt, and status")
    func editPlanPreservesIdentity() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(PlanDraft.editing(entry, in: f.store))
        draft.price = 88
        draft.quantity = 25

        let outcome = workflow.save(draft)
        let written = try #require(outcome.value)
        #expect(written.id == plan.id)
        #expect(written.createdAt == plan.createdAt)
        #expect(written.status == .active)
        #expect(written.price == 88)
        #expect(written.quantity == 25)
        // The store appends the prior configuration; this layer must not.
        #expect(written.history?.count == 1)
    }

    @Test("A stale plan revision is refused and the draft keeps the user's values")
    func staleRevisionRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(PlanDraft.editing(entry, in: f.store))
        draft.price = 77

        // Another device edits the same plan after the form was opened.
        var peerEdit = plan
        peerEdit.price = 55
        peerEdit.updatedAt = Date(timeIntervalSince1970: 1_000_000)
        #expect(f.store.setTradePlan(peerEdit, for: f.symbol))

        let outcome = workflow.save(draft)
        #expect(outcome.error == .stalePlanRevision(plan.id))
        let returned = try #require(outcome.draft)
        #expect(returned.price == 77, "the user's typed price must survive the refusal")
        // Nothing was written.
        let live = try #require(f.store.item(for: f.symbol)?.plans.first)
        #expect(live.price == 55)
    }

    @Test("An edit draft without a frozen revision is refused rather than overwriting")
    func editWithoutRevisionRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)

        // A hand-built edit draft that forgot to freeze the revision.
        let draft = PlanDraft(
            planID: plan.id,
            symbol: f.symbol,
            kind: .buy,
            price: 999,
            quantity: 10,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        let outcome = workflow.save(draft)
        #expect(outcome.error == .stalePlanRevision(plan.id))
        let live = try #require(f.store.item(for: f.symbol)?.plans.first)
        #expect(live.price == 100)
    }

    @Test("An invalid price or quantity is refused without writing")
    func invalidValuesRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        for (price, quantity) in [(Double.nan, 10.0), (100.0, Double.nan), (0.0, 10.0), (-5.0, 10.0)] {
            var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
            draft.price = price
            draft.quantity = quantity
            let outcome = workflow.save(draft)
            #expect(outcome.error == .invalidFillValues)
        }
        #expect(f.store.item(for: f.symbol)?.plans.isEmpty == true)
    }

    @Test("Abandon and revive follow the store's own availability rule")
    func statusTransitions() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)

        var entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(entry.displayState == .waiting)

        let abandoned = workflow.abandon(entry)
        #expect(abandoned.value?.status == .cancelled)
        entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(entry.displayState == .abandoned)

        let revived = workflow.revive(entry)
        #expect(revived.value?.status == .active)
        entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(entry.displayState == .waiting)

        // Reviving a plan that is already waiting is not an available action,
        // and the wrapper reports that rather than forcing the write.
        #expect(workflow.revive(entry).error != nil)
    }

    @Test("Stopping a plan is reported as unsupported and never faked into a write")
    func stopIsNotAWrappedRoute() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        let outcome = workflow.stop(entry)
        guard case let .unsupported(route) = outcome.error else {
            Issue.record("stop must report an unsupported route, not a fabricated status write")
            return
        }
        #expect(route.contains("stopping a plan"))
        // The store allows only .cancelled and .active through
        // `changeTradePlanStatus`, so a done plan can only be derived from
        // completed fills. Nothing may have changed.
        #expect(outcome.draft?.symbol == f.symbol)
        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(live.plan.status == .active)
        #expect(live.displayState == .waiting)
        #expect(live.plan.status != .done)
    }

    @Test("A stale entry cannot close a plan that already changed")
    func staleEntryRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let staleEntry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let staleDraft = try #require(PlanDraft.editing(staleEntry, in: f.store))

        var peerEdit = plan
        peerEdit.note = "changed on another device"
        peerEdit.updatedAt = Date(timeIntervalSince1970: 2_000_000)
        #expect(f.store.setTradePlan(peerEdit, for: f.symbol))

        // The action route refuses first, on the stale record.
        #expect(workflow.abandon(staleEntry).error == .stalePlanRevision(plan.id))
        // And so does the edit route, which is the only one that could reach
        // `.done`.
        #expect(workflow.setStatus(.done, on: staleDraft).error == .stalePlanRevision(plan.id))

        let live = try #require(f.store.item(for: f.symbol)?.plans.first)
        #expect(live.status == .active, "a stale action must not change the stored status")
    }

    @Test("Delete removes exactly the entry's plan and refuses a stale one")
    func deletePlan() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))

        var staleEntry = entry
        var peerEdit = plan
        peerEdit.note = "moved on"
        peerEdit.updatedAt = Date(timeIntervalSince1970: 3_000_000)
        #expect(f.store.setTradePlan(peerEdit, for: f.symbol))
        // The entry still holds the pre-edit plan.
        #expect(workflow.delete(staleEntry).error == .stalePlanRevision(plan.id))
        #expect(f.store.item(for: f.symbol)?.plans.count == 1)

        staleEntry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let outcome = workflow.delete(staleEntry)
        #expect(outcome.value?.id == plan.id)
        #expect(f.store.item(for: f.symbol)?.plans.isEmpty == true)
    }

    @Test("A draft frozen in another account is refused and keeps the user's values")
    func accountFreezeRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        // Frozen in mengmeng while the store is on financing. `setTradePlan`
        // writes the *selected* ledger, so saving this draft would file the
        // plan into an account the form was never opened against. The write is
        // refused, the draft comes back, and no ledger gains a plan.
        let draft = PlanDraft(
            symbol: f.symbol,
            kind: .buy,
            price: 10,
            quantity: 5,
            accountFreeze: AccountFreeze(account: .mengmeng, brokerageAccountsEnabled: true)
        )
        let moved = workflow.save(draft)
        #expect(moved.error == .accountChanged(expected: .mengmeng, actual: .financing))
        #expect(moved.draft?.price == 10, "the typed values must survive the refusal")
        #expect(!moved.didWrite)

        // A draft frozen with named ledgers disabled describes a store that no
        // longer exists in that shape.
        let disabled = PlanDraft(
            symbol: f.symbol,
            kind: .buy,
            price: 10,
            quantity: 5,
            accountFreeze: AccountFreeze(account: .unassigned, brokerageAccountsEnabled: false)
        )
        #expect(workflow.save(disabled).error == .accountModeChanged)

        let financingPlans = f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.plans ?? []
        let mengmengPlans = f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.plans ?? []
        #expect(financingPlans.isEmpty && mengmengPlans.isEmpty, "nothing was written anywhere")
    }

    @Test("A new-plan save is refused after the store switches accounts, keeping the draft")
    func newPlanRefusedAfterAccountSwitch() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        // The form was opened on financing; the user then switched the app to
        // mengmeng and hit save. The plan belongs in the ledger the form froze,
        // which is no longer the one `setTradePlan` would write — so the save
        // is refused and the input is kept.
        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.price = 10
        draft.quantity = 5

        #expect(f.store.selectBrokerageAccount(.mengmeng))

        let outcome = workflow.save(draft)
        #expect(outcome.error == .accountChanged(expected: .financing, actual: .mengmeng))
        #expect(outcome.draft?.quantity == 5)
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.plans.isEmpty != false)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.plans.isEmpty != false)
    }

    @Test("Duplicate condition ids and empty condition titles are refused")
    func conditionValidation() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        let shared = UUID()
        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.price = 10
        draft.quantity = 5
        draft.conditions = [
            TradePlanCondition(id: shared, title: "earnings", kind: .event, state: .pending),
            TradePlanCondition(id: shared, title: "second", kind: .event, state: .pending)
        ]
        let duplicate = workflow.save(draft)
        #expect(duplicate.error != nil)

        draft.conditions = [
            TradePlanCondition(title: "   ", kind: .manual, state: .pending)
        ]
        #expect(workflow.save(draft).error != nil)
        #expect(f.store.item(for: f.symbol)?.plans.isEmpty == true)
    }

    @Test("An execution default of unassigned is refused; a real account is stored")
    func executionAccountDefault() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.price = 10
        draft.quantity = 5
        draft.executionAccountID = .unassigned
        #expect(workflow.save(draft).error == .accountUnavailable(.unassigned))

        draft.executionAccountID = .mengmeng
        #expect(workflow.save(draft).value?.executionAccountID == .mengmeng)
    }

    @Test("An unknown instrument is refused rather than silently created")
    func unknownInstrumentRefused() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let ghost = SymbolID(market: .us, code: "QAGHOST")
        var draft = PlanDraft.newPlan(symbol: ghost, in: f.store)
        draft.price = 10
        draft.quantity = 5
        #expect(workflow.save(draft).error == .itemNotFound(ghost))
    }

    @Test("A named-ledger read never returns another ledger's namesake plan")
    func namedLedgerReadIsScoped() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        // The same symbol and plan id in two ledgers, with different prices.
        let sharedID = UUID()
        func seed(in account: BrokerageAccountID, price: Double) {
            f.store.withBrokerageAccount(account) {
                f.store.add(SymbolInfo(symbol: f.symbol, name: "Fictional mobile fixture"))
                var plan = TradePlan(id: sharedID, kind: .buy, price: price, quantity: 10)
                plan.updatedAt = Date(timeIntervalSince1970: 4_000)
                #expect(f.store.setTradePlan(plan, for: f.symbol))
            }
        }
        seed(in: .financing, price: 100)
        seed(in: .mengmeng, price: 999)

        // Each named ledger answers with its own copy, no matter which is
        // selected. The id is shared, so reading by id alone would be ambiguous.
        let financing = try #require(workflow.entry(symbol: f.symbol, planID: sharedID,
                                                    account: .financing))
        let mengmeng = try #require(workflow.entry(symbol: f.symbol, planID: sharedID,
                                                   account: .mengmeng))
        #expect(financing.plan.price == 100)
        #expect(mengmeng.plan.price == 999)
        #expect(financing.accountID == .financing)
        #expect(mengmeng.accountID == .mengmeng)
    }

    @Test("A stale whole-plan revision is refused even when the timestamp is unchanged")
    func staleRevisionWithoutTimestampChange() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        var draft = try #require(PlanDraft.editing(entry, in: f.store))
        draft.price = 77

        // A peer's revision arrives with the *same* `updatedAt` but different
        // content — the shape a sync merge really produces. The store compares
        // only its own `updatedAt`, so the wrapper's frozen digest is what must
        // refuse the write; without it the user's edit would silently overwrite
        // a change they never saw.
        var peerEdit = plan
        peerEdit.note = "changed by a peer in the same clock tick"
        peerEdit.updatedAt = entry.plan.updatedAt
        let live = try MobileFixture.replaceStoredPlan(peerEdit, symbol: f.symbol, in: f.store)
        #expect(live.updatedAt == entry.plan.updatedAt, "the timestamp alone did not move")
        #expect(live.note == "changed by a peer in the same clock tick")

        let outcome = workflow.save(draft)
        #expect(outcome.error == .stalePlanRevision(plan.id))
        #expect(outcome.draft?.price == 77)
        #expect(f.store.item(for: f.symbol)?.plans.first?.note
            == "changed by a peer in the same clock tick")
    }

    @Test("A new plan keeps one identity across retries of the same draft")
    func newPlanRetryKeepsIdentity() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.price = 12.5
        draft.quantity = 40
        draft.note = "entry thesis"
        #expect(draft.newPlanID != nil, "a new-plan draft mints its identity once, at open")

        // The first save landed but the client never saw it: relaunch, restore
        // the draft from storage, and submit the exact same value again.
        let restored = try JSONDecoder().decode(PlanDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored.newPlanID == draft.newPlanID, "the identity survives Codable")

        let first = try #require(workflow.save(restored).value)
        let retried = try #require(workflow.save(restored).value)
        #expect(retried.id == first.id)
        #expect(retried.createdAt == first.createdAt)
        #expect(f.store.item(for: f.symbol)?.plans.count == 1,
                "a retry must not file a second plan")
        #expect(retried.history == nil, "a retry must not append a revision either")

        // A *changed* draft under the same new-plan identity is a conflict, not
        // an edit: the draft never froze a revision of the landed plan, so the
        // honest answer is to reopen it. Nothing is overwritten.
        var changed = restored
        changed.price = 99
        let refused = workflow.save(changed)
        #expect(refused.error == .stalePlanRevision(first.id))
        #expect(f.store.item(for: f.symbol)?.plans.count == 1)
        #expect(f.store.item(for: f.symbol)?.plans.first?.price == 12.5)

        // Two genuinely independent new-plan drafts are two plans.
        var second = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        second.price = 20
        second.quantity = 5
        #expect(second.newPlanID != restored.newPlanID)
        #expect(workflow.save(second).didWrite)
        #expect(f.store.item(for: f.symbol)?.plans.count == 2)
    }

    @Test("A legacy draft without a newPlanID still decodes and still saves")
    func legacyDraftWithoutNewPlanID() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        var draft = PlanDraft.newPlan(symbol: f.symbol, in: f.store)
        draft.price = 10
        draft.quantity = 5
        // A draft persisted by an older build has no newPlanID key at all.
        let data = try JSONEncoder().encode(draft)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "newPlanID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(PlanDraft.self, from: legacyData)
        #expect(legacy.newPlanID == nil)

        // Such a draft still saves; the store's own id uniqueness is the
        // backstop a pre-fix build relied on.
        #expect(workflow.save(legacy).didWrite)
        #expect(f.store.item(for: f.symbol)?.plans.count == 1)
    }

    @Test("Abandon reads and writes the entry's own ledger, never the namesake in the selected one")
    func abandonReadsEntryLedger() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)

        // The same plan id in both ledgers, with different content.
        let sharedID = UUID()
        func seed(in account: BrokerageAccountID, price: Double) {
            f.store.withBrokerageAccount(account) {
                f.store.add(SymbolInfo(symbol: f.symbol, name: "Fictional mobile fixture"))
                var plan = TradePlan(id: sharedID, kind: .buy, price: price, quantity: 10)
                plan.updatedAt = Date(timeIntervalSince1970: 4_000)
                #expect(f.store.setTradePlan(plan, for: f.symbol))
            }
        }
        seed(in: .financing, price: 100)
        seed(in: .mengmeng, price: 999)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: sharedID,
                                                account: .financing))
        #expect(entry.plan.price == 100)

        // The selection has moved to the other ledger. The entry still names
        // financing, so the liveness and availability preflight must be read
        // there — reading the selection would find the namesake and misjudge.
        #expect(f.store.selectBrokerageAccount(.mengmeng))

        let outcome = workflow.abandon(entry)
        #expect(outcome.error == nil)
        #expect(outcome.value?.status == .cancelled)
        #expect(f.store.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == f.symbol }?.plans.first?.status == .cancelled)
        #expect(f.store.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == f.symbol }?.plans.first?.status == .active,
                "the namesake plan in the selected ledger was never touched")
    }

    @Test("setStatus is refused after the store switches accounts, keeping the draft")
    func setStatusRefusedAfterAccountSwitch() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let draft = try #require(PlanDraft.editing(entry, in: f.store))

        // The edit draft froze financing; the app has since moved to mengmeng.
        // `setTradePlan` writes the selected ledger, so the write is refused
        // rather than landing somewhere the form was never opened against.
        #expect(f.store.selectBrokerageAccount(.mengmeng))
        let outcome = workflow.setStatus(.done, on: draft)
        #expect(outcome.error == .accountChanged(expected: .financing, actual: .mengmeng))
        #expect(outcome.draft != nil)

        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id,
                                               account: .financing))
        #expect(live.plan.status == .active, "nothing was written")
    }
}

@MainActor @Suite("Mobile plan status edits")
struct PlanStatusEditTests {
    @Test("setStatus writes .done through the edit route and keeps the draft's revision honest")
    func setStatusDone() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol, price: 100, quantity: 10)

        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let draft = try #require(PlanDraft.editing(entry, in: f.store))

        let outcome = workflow.setStatus(.done, on: draft)
        #expect(outcome.value?.status == .done)

        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(live.displayState == .stopped)
        #expect(live.canBackfillFill, "a stopped, unfinished plan is the backfillable one")
    }

    @Test("setStatus refuses a draft that froze no revision, and one that went stale")
    func setStatusGuards() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)

        // No revision: the caller never showed the plan it is about to close.
        let unrevisioned = PlanDraft(
            planID: plan.id, symbol: f.symbol, kind: .buy, price: 100, quantity: 10,
            accountFreeze: AccountFreeze(account: .financing, brokerageAccountsEnabled: true)
        )
        #expect(workflow.setStatus(.done, on: unrevisioned).error == .stalePlanRevision(plan.id))

        // Stale: another device moved the plan.
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let stale = try #require(PlanDraft.editing(entry, in: f.store))
        var peerEdit = plan
        peerEdit.note = "moved"
        peerEdit.updatedAt = Date(timeIntervalSince1970: 7_000_000)
        #expect(f.store.setTradePlan(peerEdit, for: f.symbol))

        #expect(workflow.setStatus(.done, on: stale).error == .stalePlanRevision(plan.id))
        let live = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        #expect(live.plan.status == .active)
    }

    @Test("setStatus to the status already stored is a no-op success")
    func setStatusNoOp() throws {
        let f = try MobileFixture.isolatedStore()
        defer { MobileFixture.cleanup(f.defaults, f.suite) }
        let workflow = PlanWorkflow(store: f.store)
        let plan = MobileFixture.seedPlan(f.store, symbol: f.symbol)
        let entry = try #require(workflow.entry(symbol: f.symbol, planID: plan.id))
        let draft = try #require(PlanDraft.editing(entry, in: f.store))

        let outcome = workflow.setStatus(.active, on: draft)
        #expect(outcome.value?.status == .active)
        #expect(outcome.value?.id == plan.id)
    }
}
