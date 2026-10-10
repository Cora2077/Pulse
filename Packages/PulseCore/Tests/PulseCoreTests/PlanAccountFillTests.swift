import Foundation
import Testing
@testable import PulseCore

/// Cross-account plan fills: a plan lives in the ledger where its author wrote
/// it, while the buys it produces land in the accounts the user names.
///
/// The plan's progress is the *aggregate* of every matching fill recorded
/// against it anywhere — one plan can be filled across several accounts — and
/// it only completes when that aggregate reaches the plan's size. Editing or
/// deleting a fill in a destination must move that same aggregate, and the
/// marks a plan closed by hand are never reopened by a ledger edit.
@MainActor @Suite("Plan account fills")
struct PlanAccountFillTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    /// Two accounts, a source ledger holding the plan, and the symbol known in
    /// both. Selecting `.unassigned` keeps the source identity explicit.
    private func withStore(_ body: (WatchlistStore) throws -> Void) throws {
        let suite = "Pulse.PlanAccountFill.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        // The plan's account needs the instrument too; buys are recorded from
        // the source ledger's plan, into the financing/mengmeng destinations.
        store.withBrokerageAccount(.financing) { store.add(SymbolInfo(symbol: symbol, name: "Apple")) }
        try body(store)
    }

    private func plan(_ quantity: Double, pool: PositionPool = .tactical) -> TradePlan {
        TradePlan(kind: .buy, price: 100, quantity: quantity, positionPool: pool, fundingSource: .margin)
    }

    @discardableResult
    private func fill(
        _ store: WatchlistStore,
        _ plan: TradePlan,
        quantity: Double,
        account: BrokerageAccountID? = nil,
        funding: PositionFundingSource? = nil,
        price: Double = 100,
        at date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> PositionTransaction {
        try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: price, quantity: quantity,
            date: date, fee: nil, note: nil,
            fundingSource: funding, brokerageAccountID: account
        )
    }

    private func sourceItem(_ store: WatchlistStore) -> WatchItem? {
        store.brokeragePortfolio(for: .unassigned).items.first { $0.symbol == symbol }
    }

    private func targetItem(_ store: WatchlistStore, _ account: BrokerageAccountID) -> WatchItem? {
        store.brokeragePortfolio(for: account).items.first { $0.symbol == symbol }
    }

    // MARK: - One plan, several destination accounts

    @Test("A plan split across two accounts completes on the aggregate, not either half")
    func crossAccountAggregateProgress() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            // The plan's configuration is snapshotted into each fill.
            let forty = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let sixty = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)

            // Each fill is recorded into the destination it named.
            let financing = try #require(targetItem(store, .financing))
            let mengmeng = try #require(targetItem(store, .mengmeng))
            #expect(financing.transactions.map(\.id) == [forty.id])
            #expect(mengmeng.transactions.map(\.id) == [sixty.id])
            #expect(financing.positionQuantity == 40)
            #expect(mengmeng.positionQuantity == 60)

            // The source plan is untouched in the account where it was written.
            let source = try #require(sourceItem(store))
            #expect(source.transactions.isEmpty)
            #expect(source.plans.map(\.id) == [target.id])
            #expect(source.plans.first?.quantity == 100)

            // Progress is the sum, and the plan is done only once it is met.
            let entry = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(entry.filledQuantity == 100)
            #expect(entry.remainingQuantity == 0)
            #expect(entry.plan.status == .done)

            // Each snapshot preserves the plan's source configuration.
            #expect(forty.planExecution?.configuration.quantity == 100)
            #expect(forty.planExecution?.configuration.positionPool == .tactical)
            #expect(forty.planExecution?.configuration.fundingSource == .margin)
            #expect(sixty.planExecution?.configuration == forty.planExecution?.configuration)
            // The destination differs, so the snapshot records where to look.
            #expect(forty.planExecution?.sourceAccountID == .unassigned)
            #expect(sixty.planExecution?.sourceAccountID == .unassigned)
        }
    }

    @Test("A partial cross-account fill leaves the plan active until more arrives")
    func partialAggregateStaysActive() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            _ = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let partial = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(partial.plan.status == .active)
            #expect(partial.filledQuantity == 40 && partial.remainingQuantity == 60)

            _ = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)
            let complete = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(complete.plan.status == .done && complete.remainingQuantity == 0)
        }
    }

    @Test("The scoped plan lookup returns the destination fills for a source plan")
    func scopedPlanLookupReturnsCrossAccountFills() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            let forty = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let sixty = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)

            // The lookup is scoped by the plan's *source* account: both fills,
            // recorded into two different destinations, belong to the source.
            let scoped = store.transactionsForPlan(symbol, account: .unassigned)
            #expect(Set(scoped.map(\.id)) == [forty.id, sixty.id])

            // A destination is not a source for this plan, so asking from either
            // destination returns nothing for it — which is what stops a second
            // account from counting the same fill again.
            #expect(store.transactionsForPlan(symbol, account: .financing).isEmpty)
            #expect(store.transactionsForPlan(symbol, account: .mengmeng).isEmpty)
        }
    }

    @Test("A same-UUID plan in another source account never counts toward this plan")
    func sameUUIDInAnotherAccountDoesNotContaminate() throws {
        try withStore { store in
            let sharedID = UUID()
            var sourcePlan = plan(50)
            sourcePlan.id = sharedID
            #expect(store.setTradePlan(sourcePlan, for: symbol))

            // An unrelated plan that happens to reuse the UUID, written in the
            // financing ledger as its own source plan, filled with 999 there.
            store.withBrokerageAccount(.financing) {
                let unrelated = TradePlan(id: sharedID, kind: .buy, price: 5, quantity: 999)
                #expect(store.setTradePlan(unrelated, for: symbol))
                _ = try? store.recordTradePlanFill(
                    symbol: symbol, planID: sharedID, price: 5, quantity: 999,
                    date: Date(timeIntervalSince1970: 1_700_000_500), fee: nil, note: nil,
                    fundingSource: .own
                )
            }

            _ = try fill(store, sourcePlan, quantity: 50, account: .mengmeng, funding: .own)

            // The unassigned source plan sees only its own 50-share fill.
            let unassignedEntry = try #require(store.tradePlanEntries.first { $0.plan.id == sharedID })
            #expect(unassignedEntry.filledQuantity == 50, "the 999-share fill belongs to the other source plan")
            #expect(unassignedEntry.plan.status == .done)

            // The financing source plan keeps its own 999 and is untouched by
            // the other plan that happens to share the id.
            try store.withBrokerageAccount(.financing) {
                let financingEntry = try #require(store.tradePlanEntries.first { $0.plan.id == sharedID })
                #expect(financingEntry.filledQuantity == 999)
            }
        }
    }

    // MARK: - Refusals

    @Test("The shared plan list includes destination fills and remains read-only")
    func sharedPlanListIncludesCrossAccountFills() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            _ = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let suite = "Pulse.SharedPlanFill.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let shared = SharedWatchlist(store: store, defaults: defaults)
            let baseline = store.syncSnapshot()
            let entry = try #require(shared.tradePlanEntries.first { $0.plan.id == target.id && $0.accountID == .unassigned })
            #expect(entry.filledQuantity == 40 && entry.remainingQuantity == 60)
            #expect(store.syncSnapshot() == baseline)
            #expect(store.activeBrokerageAccountID == .unassigned)

            _ = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)
            let completed = try #require(shared.tradePlanEntries.first { $0.plan.id == target.id && $0.accountID == .unassigned })
            #expect(completed.filledQuantity == 100 && completed.plan.status == .done)

            // Removing watch membership retains financial history and its progress.
            store.remove(symbol)
            let retained = try #require(shared.tradePlanEntries.first { $0.plan.id == target.id && $0.accountID == .unassigned })
            #expect(retained.filledQuantity == 100 && retained.remainingQuantity == 0)
        }
    }

    @Test("Explicit unassigned and Mengmeng margin destinations are refused atomically")
    func invalidDestinationsRefused() throws {
        try withStore { store in
            let target = plan(10)
            #expect(store.setTradePlan(target, for: symbol))
            let before = store.syncSnapshot()

            #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
                try fill(store, target, quantity: 1, account: .unassigned, funding: .own)
            }
            #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
                try fill(store, target, quantity: 1, account: .mengmeng, funding: .margin)
            }
            #expect(store.syncSnapshot() == before, "a refused fill leaves no partial plan progress")
        }
    }

    @Test("A stale plan and a duplicate fill id are refused before any write")
    func staleAndDuplicateFillsRefused() throws {
        try withStore { store in
            let target = plan(10)
            #expect(store.setTradePlan(target, for: symbol))
            let staleUpdatedAt = try #require(sourceItem(store)?.plans.first { $0.id == target.id }?.updatedAt)

            // Change the plan so the caller's expectation no longer holds.
            var edited = target
            edited.price = 90
            #expect(store.setTradePlan(edited, for: symbol))
            let before = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.stalePlan) {
                try store.recordTradePlanFill(
                    symbol: symbol, planID: target.id, price: 100, quantity: 5,
                    date: .now, fee: nil, note: nil,
                    expectedPlanUpdatedAt: staleUpdatedAt,
                    fundingSource: .own, brokerageAccountID: .financing
                )
            }
            #expect(store.syncSnapshot() == before)

            // A duplicate transaction id anywhere in the tree is refused.
            let recorded = try fill(store, edited, quantity: 1, account: .financing, funding: .own)
            #expect(throws: TradePlanExecutionError.duplicateTransactionID) {
                try store.recordTradePlanFill(
                    symbol: symbol, planID: edited.id, price: 90, quantity: 1,
                    date: .now, fee: nil, note: nil, transactionID: recorded.id,
                    fundingSource: .own, brokerageAccountID: .financing
                )
            }
        }
    }

    @Test("An explicit destination is not rerouted to the source ledger by a later edit")
    func destinationOwnershipIsNotReassigned() throws {
        try withStore { store in
            let target = plan(10)
            #expect(store.setTradePlan(target, for: symbol))
            let recorded = try fill(store, target, quantity: 10, account: .financing, funding: .margin)

            // An edit that drops the account must not move the fill back into
            // the source ledger.
            var edit = recorded
            edit.brokerageAccountID = nil
            edit.price = 101
            store.withBrokerageAccount(.financing) { store.updateTransaction(symbol, edit) }
            let financing = try #require(targetItem(store, .financing))
            #expect(financing.transactions.first?.brokerageAccountID == .financing)
            #expect(financing.transactions.first?.price == 101)
            #expect(sourceItem(store)?.transactions.isEmpty == true)
        }
    }

    // MARK: - Sells stay with the source plan

    @Test("A plan sell stays in the source ledger and a cross-account sale is refused")
    func planSellsStayInTheSourceLedger() throws {
        try withStore { store in
            // A buy of 20 lands in the source ledger, where the sell plan lives.
            let buy = TradePlan(kind: .buy, price: 10, quantity: 20, positionPool: .tactical)
            #expect(store.setTradePlan(buy, for: symbol))
            _ = try fill(store, buy, quantity: 20, funding: .own)
            #expect(sourceItem(store)?.positionQuantity == 20)

            let sell = TradePlan(kind: .sell, price: 12, quantity: 10, positionPool: .tactical)
            #expect(store.setTradePlan(sell, for: symbol))

            // Naming a different destination for a source plan's sale is refused
            // rather than quietly moving shares between accounts.
            let before = store.syncSnapshot()
            #expect(throws: TradePlanExecutionError.self) {
                try fill(store, sell, quantity: 4, account: .financing)
            }
            #expect(store.syncSnapshot() == before, "a cross-account sale must not half-apply")

            // Without a destination the sale records in the source ledger.
            let recorded = try fill(store, sell, quantity: 4)
            #expect(recorded.brokerageAccountID == nil || recorded.brokerageAccountID == .unassigned)
            #expect(sourceItem(store)?.positionQuantity == 16)
            #expect(targetItem(store, .financing)?.transactions.isEmpty != false)
        }
    }

    // MARK: - Editing and deleting a destination fill

    @Test("Editing or deleting a destination fill reopens an automatically completed plan")
    func destinationEditsReopenCompletedPlan() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            let forty = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let sixty = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)
            #expect(store.tradePlanEntries.first { $0.plan.id == target.id }?.plan.status == .done)

            // Shrink the destination fill: the aggregate no longer completes the
            // plan, so the automatically closed plan reopens.
            var smaller = sixty
            smaller.quantity = 30
            // `updateTransaction` is scoped to a ledger, so edit through the
            // destination account and confirm the source plan moves.
            store.withBrokerageAccount(.mengmeng) {
                store.updateTransaction(symbol, smaller)
            }
            let reopened = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(reopened.filledQuantity == 70)
            #expect(reopened.plan.status == .active)

            // Deleting the other destination fill keeps it incomplete.
            store.withBrokerageAccount(.financing) { store.deleteTransaction(symbol, id: forty.id) }
            let afterDelete = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(afterDelete.filledQuantity == 30)
            #expect(afterDelete.plan.status == .active)
        }
    }

    @Test("Restoring a destination fill re-completes the source plan it reopened")
    func restoredDestinationFillRecompletesPlan() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            _ = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            let sixty = try fill(store, target, quantity: 60, account: .mengmeng, funding: .own)
            #expect(store.tradePlanEntries.first { $0.plan.id == target.id }?.plan.status == .done)

            // Shrink, which reopens the plan...
            var smaller = sixty
            smaller.quantity = 30
            store.withBrokerageAccount(.mengmeng) { store.updateTransaction(symbol, smaller) }
            #expect(store.tradePlanEntries.first { $0.plan.id == target.id }?.plan.status == .active)

            // ...then restore the fill, which completes the aggregate again.
            store.withBrokerageAccount(.mengmeng) { store.updateTransaction(symbol, sixty) }
            let restored = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(restored.filledQuantity == 100)
            #expect(restored.plan.status == .done, "aggregate completion must close the plan again")
        }
    }

    @Test("A partially filled plan closed by hand stays closed after an edit")
    func manualCloseIsNotReopened() throws {
        try withStore { store in
            let target = plan(100)
            #expect(store.setTradePlan(target, for: symbol))
            let forty = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
            var closed = try #require(sourceItem(store)?.plans.first { $0.id == target.id })
            closed.status = .done
            #expect(store.setTradePlan(closed, for: symbol))

            // Deleting the linked fill makes progress incomplete, but a manual
            // close is the user's decision and stays put.
            store.withBrokerageAccount(.financing) { store.deleteTransaction(symbol, id: forty.id) }
            let entry = try #require(store.tradePlanEntries.first { $0.plan.id == target.id })
            #expect(entry.filledQuantity == 0)
            #expect(entry.plan.status == .done)
        }
    }

    // MARK: - Ownership survives a round trip

    @Test("Archive and sync round trips preserve the transaction owner and plan source")
    func roundTripsPreserveOwnership() throws {
        let suite = "Pulse.PlanAccountFill.roundtrip.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let target = plan(100)
        #expect(store.setTradePlan(target, for: symbol))
        let forty = try fill(store, target, quantity: 40, account: .financing, funding: .margin)

        // Sync wire round trip.
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: store.syncSnapshot())
        let decoded = try WatchlistSyncWireCodec.decode(wire)
        let decodedFill = try #require(decoded.snapshot.allAccountItems
            .flatMap(\.transactions).first { $0.id == forty.id })
        #expect(decodedFill.brokerageAccountID == .financing)
        #expect(decodedFill.planExecution?.sourceAccountID == .unassigned)
        #expect(decodedFill.fundingSource == .margin)
        // Trade metadata survives with it.
        #expect(decodedFill.planExecution?.configuration == forty.planExecution?.configuration)

        // The plan's account keeps the plan after a reload.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        #expect(reloaded.brokeragePortfolio(for: .unassigned)
            .items.first { $0.symbol == symbol }?.plans.first?.id == target.id)
        #expect(reloaded.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == symbol }?.transactions.first?.brokerageAccountID == .financing)
    }

    @Test("Merging an older peer that lost the source field restores it, never erasing it")
    func olderPeerLosesSourceFieldButMergePreservesIt() throws {
        // A cross-account fill in the unassigned (top-level) ledger, where the
        // three-way merge reconciles transactions one by one.
        var configuration = TradePlanConfiguration(plan: plan(100))
        configuration.positionPool = .tactical
        let fill = PositionTransaction(
            kind: .buy, price: 100, quantity: 40,
            planExecution: TradePlanExecution(
                planID: UUID(), configuration: configuration, sourceAccountID: .financing
            )
        )
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [fill])
        let snapshot = WatchlistSyncSnapshot(
            items: [item], groups: [.init(name: "Test", symbols: [symbol])]
        )

        // A peer snapshot that still carries `planExecution` but lost the nested
        // source field — an older build re-encoded the transaction.
        var peerFill = fill
        peerFill.planExecution?.sourceAccountID = nil
        var peer = snapshot
        peer.items[0].transactions = [peerFill]

        let result = WatchlistSyncMerge.merge(base: snapshot, local: snapshot, remote: peer)
        let merged = try #require(result.snapshot.items.first { $0.symbol == symbol }?
            .transactions.first { $0.id == fill.id })
        #expect(merged.brokerageAccountID == fill.brokerageAccountID)
        #expect(merged.planExecution?.sourceAccountID == .financing,
                "an older peer's missing source field must not erase the one this copy holds")
        #expect(merged.planExecution?.configuration == configuration)
    }

    @Test("Merging an older peer inside a named account also keeps the nested source")
    func olderPeerInNamedAccountKeepsNestedSource() throws {
        let configuration = TradePlanConfiguration(plan: plan(100))
        let fill = PositionTransaction(
            kind: .buy, price: 100, quantity: 40,
            planExecution: TradePlanExecution(
                planID: UUID(), configuration: configuration, sourceAccountID: .unassigned
            ),
            brokerageAccountID: .financing
        )
        let item = WatchItem(symbol: symbol, displayName: "Apple", transactions: [fill])
        let snapshot = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple")],
            groups: [.init(name: "Test", symbols: [symbol])],
            brokerageAccounts: [.init(accountID: .financing, items: [item])]
        )
        var peerFill = fill
        peerFill.planExecution?.sourceAccountID = nil
        var peer = snapshot
        peer.brokerageAccounts?[0].items[0].transactions = [peerFill]

        let result = WatchlistSyncMerge.merge(base: snapshot, local: snapshot, remote: peer)
        let merged = try #require(result.snapshot.brokerageAccounts?
            .first { $0.accountID == .financing }?.items.first { $0.symbol == symbol }?
            .transactions.first { $0.id == fill.id })
        #expect(merged.planExecution?.sourceAccountID == .unassigned,
                "a named-account merge must preserve the nested source every bit as much")
    }

    @Test("Snapshots without a source field stay readable at their declared version")
    func oldSnapshotsStayReadable() throws {
        // A same-account fill never records a source account, so it stays on the
        // plan-workflow version and remains readable by builds older than the
        // source-account field.
        let configuration = TradePlanConfiguration(plan: TradePlan(kind: .buy, price: 1, quantity: 1))
        let local = PositionTransaction(
            kind: .buy, price: 1, quantity: 1,
            planExecution: TradePlanExecution(planID: UUID(), configuration: configuration)
        )
        let snapshot = WatchlistSyncSnapshot(
            items: [.init(symbol: symbol, displayName: "Apple", transactions: [local])],
            groups: [.init(name: "Test", symbols: [symbol])]
        )
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: snapshot)
        let plainVersion = try WatchlistSyncWireCodec.decode(wire).version
        // Source accounts first appeared in wire v16; later unrelated fields
        // must not raise this payload's minimum version.
        let sourceAccountVersion = 16
        #expect(plainVersion < sourceAccountVersion,
                "a same-account fill must not claim the source-account version")

        // And a cross-account fill raises it and claims the newer version.
        var crossAccount = local
        crossAccount.planExecution = TradePlanExecution(
            planID: local.planExecution!.planID, configuration: configuration, sourceAccountID: .unassigned
        )
        let raised = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: WatchlistSyncSnapshot(
            items: [.init(symbol: symbol, displayName: "Apple", transactions: [crossAccount])],
            groups: [.init(name: "Test", symbols: [symbol])]
        ))
        #expect(try WatchlistSyncWireCodec.decode(raised).version == sourceAccountVersion)

        // Claiming the older version while carrying the source field is refused.
        var object = try #require(JSONSerialization.jsonObject(with: raised) as? [String: Any])
        object["version"] = sourceAccountVersion - 1
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(sourceAccountVersion)) {
            try WatchlistSyncWireCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test("An archive carries the plan source and its version gate")
    func archiveCarriesPlanSource() throws {
        let suite = "Pulse.PlanAccountFill.archive.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Test")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let target = plan(100)
        #expect(store.setTradePlan(target, for: symbol))
        // The plan is written in the unassigned source; its fill lands in the
        // financing destination, so the fill records where the plan lives.
        let fill = try fill(store, target, quantity: 40, account: .financing, funding: .margin)
        #expect(fill.planExecution?.sourceAccountID == .unassigned)

        let archive = store.withBrokerageAccount(.financing) { store.archive() }
        let sourceAccountVersion = 14
        #expect(archive.version == sourceAccountVersion)
        let decoded = try WatchlistArchive.decoded(from: archive.encoded())
        let transaction = try #require(decoded.lists.flatMap(\.entries).flatMap { $0.transactions ?? [] }.first { $0.id == fill.id })
        #expect(transaction.planExecution?.sourceAccountID == .unassigned)
        #expect(transaction.brokerageAccountID == .financing)

        var lowered = archive
        lowered.version = sourceAccountVersion - 1
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(sourceAccountVersion)) {
            try WatchlistArchive.decoded(from: lowered.encoded())
        }
    }
}
