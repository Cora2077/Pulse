import Foundation
import Testing
@testable import PulseCore

/// A sell plan tied to one existing position card.
///
/// The subject is a *binding*: a plan that names the exact card it means to
/// sell instead of falling back to whichever card of its pool the store finds
/// first. Every test here therefore asks one of two questions — does the store
/// refuse to invent a source the user did not name, and does writing a plan
/// leave the ledger alone. Both are answered on synthetic stores only.
@MainActor @Suite("Position sale plan")
struct PositionSalePlanTests {
    private let symbol = SymbolID(market: .us, code: "SALE")
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func withStore(accounts: Bool = false, _ body: (WatchlistStore) throws -> Void) throws {
        let suite = "PositionSalePlan.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Synthetic")
        if accounts {
            store.enableBrokerageAccounts()
            for account in BrokerageAccountID.allCases {
                store.withBrokerageAccount(account) { store.add(SymbolInfo(symbol: symbol, name: "Synthetic")) }
            }
        } else {
            store.add(SymbolInfo(symbol: symbol, name: "Synthetic"))
        }
        try body(store)
    }

    /// Buys `quantity` into the active ledger and pools the resulting snapshot
    /// card as `pool`.
    private func seed(_ store: WatchlistStore, quantity: Double, pool: PositionPool) throws -> PositionPortion {
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: quantity, date: day))
        let item = try #require(store.item(for: symbol))
        let allocation = try #require(item.positionAllocation)
        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: allocation.portions[0].id, quantity: quantity,
            to: pool, reason: "seed", expectedRevision: allocation.revision
        )
        return try #require(moved.portions.first { $0.pool == pool })
    }

    /// Moves a card to `pool`, returning the allocation it produced.
    private func move(_ store: WatchlistStore, _ portionID: UUID, _ quantity: Double,
                      to pool: PositionPool) throws -> PositionAllocation {
        let allocation = try #require(store.item(for: symbol)?.positionAllocation)
        return try store.transferPositionPortion(
            symbol: symbol, portionID: portionID, quantity: quantity,
            to: pool, reason: "move", expectedRevision: allocation.revision
        )
    }

    /// Builds a second card in the same pool as `portionID` and leaves it
    /// *ahead* of the original in the allocation's own order — the shape a FIFO
    /// pool walk reaches first, and the one a bound fill has to ignore.
    ///
    /// A partial transfer appends the new card and leaves the original where it
    /// was; a whole-card transfer appends the card that moved. So the original
    /// is sent out to the other active pool and back, which lands it last while
    /// both ids survive (a whole-card move keeps the card's identity).
    ///
    /// Returns the sibling's id. The ordering assumption is asserted here so a
    /// change to the transfer shape fails this test rather than quietly making
    /// the sibling test vacuous.
    private func siblingAheadOf(
        _ store: WatchlistStore, _ portionID: UUID, _ quantity: Double, in pool: PositionPool
    ) throws -> UUID {
        let other: PositionPool = pool == .strategic ? .tactical : .strategic
        // Split the sibling off into the other pool, then bring it home.
        let split = try move(store, portionID, quantity, to: other)
        let siblingID = try #require(split.portions.first { $0.id != portionID }?.id)
        let remainder = try #require(split.portions.first { $0.id == portionID }?.quantity)
        _ = try move(store, siblingID, quantity, to: pool)
        // Send the original out and back so it lands after the sibling.
        _ = try move(store, portionID, remainder, to: other)
        _ = try move(store, portionID, remainder, to: pool)

        let ordered = try #require(store.item(for: symbol)?.positionAllocation?.portions)
        #expect(ordered.first?.id == siblingID)
        #expect(ordered.contains { $0.id == portionID })
        return siblingID
    }

    private func sell(_ portionID: UUID, quantity: Double, price: Double = 12, pool: PositionPool = .tactical) -> TradePlan {
        TradePlan(kind: .sell, price: price, quantity: quantity, positionPool: pool, positionPortionID: portionID)
    }

    // MARK: - Binding and pure reads

    @Test("Binding a plan saves it and reading its source leaves holdings untouched")
    func bindAndReadOnly() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            let plan = sell(portion.id, quantity: 40)
            let before = try #require(store.item(for: symbol))

            #expect(store.setTradePlan(plan, for: symbol))
            let stored = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            #expect(stored.positionPortionID == portion.id)

            let item = try #require(store.item(for: symbol))
            #expect(item.salePlanSource(for: stored)?.id == portion.id)
            #expect(item.availableSalePlanQuantity(for: portion.id) == 60)
            // The second half of the same question: none of that moved a share,
            // a transaction, or the allocation revision.
            #expect(item.positionQuantity == before.positionQuantity)
            #expect(item.transactions == before.transactions)
            #expect(item.positionAllocation == before.positionAllocation)
        }
    }

    @Test("A buy, an unknown card, and a card in another pool cannot be bound")
    func invalidBindings() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            let before = try #require(store.item(for: symbol))

            // A binding on a buy is a malformed payload: the store refuses it
            // rather than stripping the field and admitting the plan.
            #expect(!store.setTradePlan(
                TradePlan(kind: .buy, price: 10, quantity: 10, positionPool: .tactical, positionPortionID: portion.id),
                for: symbol
            ))
            // No pool at all names no bucket the card could be read out of.
            #expect(!store.setTradePlan(
                TradePlan(kind: .sell, price: 12, quantity: 10, positionPortionID: portion.id), for: symbol
            ))
            // The retired observation purpose is not an active destination, so
            // the payload itself is invalid — the plan is refused before any
            // live source is even consulted.
            let retired = sell(portion.id, quantity: 10, pool: .observation)
            #expect(!retired.hasValidPayload)
            #expect(!store.setTradePlan(retired, for: symbol))
            // A card that does not exist, and a real card the plan does not
            // claim a pool for.
            #expect(!store.setTradePlan(sell(UUID(), quantity: 10), for: symbol))
            #expect(!store.setTradePlan(sell(portion.id, quantity: 10, pool: .strategic), for: symbol))

            #expect(store.item(for: symbol) == before)
        }
    }

    @Test("A plan larger than its card is refused without writing anything")
    func overbookedBindingRejected() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            #expect(store.setTradePlan(sell(portion.id, quantity: 100), for: symbol))
            let claimed = try #require(store.item(for: symbol))
            // The first plan claims all 100, so a second has nothing left.
            #expect(!store.setTradePlan(sell(portion.id, quantity: 1), for: symbol))
            #expect(store.item(for: symbol) == claimed)
            #expect(claimed.availableSalePlanQuantity(for: portion.id) == 0)
        }
    }

    @Test("Only plans on the same card reserve it; siblings in the pool do not")
    func reservationsArePerCard() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            // A sibling card in the very same pool, sitting before the bound one.
            let siblingID = try siblingAheadOf(store, portion.id, 30, in: .tactical)

            let item = try #require(store.item(for: symbol))
            #expect(item.availableSalePlanQuantity(for: portion.id) == 70)
            #expect(item.availableSalePlanQuantity(for: siblingID) == 30)

            let plan = sell(portion.id, quantity: 70)
            #expect(store.setTradePlan(plan, for: symbol))
            // Reserving one card leaves the pool sibling alone, and vice versa.
            let after = try #require(store.item(for: symbol))
            #expect(after.availableSalePlanQuantity(for: portion.id) == 0)
            #expect(after.availableSalePlanQuantity(for: siblingID) == 30)
            #expect(store.setTradePlan(sell(siblingID, quantity: 30), for: symbol))
            #expect(store.item(for: symbol)?.plans.count == 2)
            // Re-saving the same plan excludes its own claim rather than
            // competing with itself.
            #expect(store.setTradePlan(plan, for: symbol))
            #expect(store.item(for: symbol)?.plans.count == 2)
        }
    }

    @Test("A partial fill frees exactly the quantity it consumed")
    func partialFillFreesReservation() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            let plan = sell(portion.id, quantity: 60)
            #expect(store.setTradePlan(plan, for: symbol))
            #expect(store.item(for: symbol)?.availableSalePlanQuantity(for: portion.id) == 40)

            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: 12, quantity: 20,
                date: day, fee: nil, note: nil
            )
            let item = try #require(store.item(for: symbol))
            #expect(item.positionQuantity == 80)
            // 80 left on the card, 40 still claimed by the plan.
            #expect(item.availableSalePlanQuantity(for: portion.id) == 40)
            #expect(item.availableSalePlanQuantity(for: portion.id, excludingPlanID: plan.id) == 80)
        }
    }

    // MARK: - Fills

    @Test("A bound fill consumes the chosen card even when a sibling comes first")
    func fillUsesBoundCard() throws {
        try withStore { store in
            let bound = try seed(store, quantity: 100, pool: .tactical)
            // A second card of the same pool, same funding, sitting before the
            // bound one — the exact situation a FIFO pool walk gets wrong.
            let siblingID = try siblingAheadOf(store, bound.id, 40, in: .tactical)
            let boundID = bound.id

            let plan = sell(boundID, quantity: 25)
            #expect(store.setTradePlan(plan, for: symbol))
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: 12, quantity: 25,
                date: day, fee: nil, note: nil
            )

            let item = try #require(store.item(for: symbol))
            let portions = try #require(item.positionAllocation?.portions)
            // The sibling is untouched; the bound card paid the whole fill.
            #expect(portions.first { $0.id == siblingID }?.quantity == 40)
            #expect(portions.first { $0.id == boundID }?.quantity == 35)
            #expect(!item.positionAllocationNeedsReconciliation)
        }
    }

    @Test("An explicit map naming the wrong card is rejected atomically")
    func wrongCardMapRejected() throws {
        try withStore { store in
            let bound = try seed(store, quantity: 100, pool: .tactical)
            let otherID = try siblingAheadOf(store, bound.id, 40, in: .tactical)
            let plan = sell(bound.id, quantity: 25)
            #expect(store.setTradePlan(plan, for: symbol))
            let before = try #require(store.item(for: symbol))
            #expect(throws: TradePlanExecutionError.invalidFundingSelection) {
                try store.recordTradePlanFill(
                    symbol: symbol, planID: plan.id, price: 12, quantity: 25,
                    date: self.day, fee: nil, note: nil,
                    salePortionQuantities: [otherID: 25]
                )
            }
            #expect(store.item(for: symbol) == before)
        }
    }

    @Test("A moved or deleted source card is refused rather than substituted")
    func staleSourceRefused() throws {
        try withStore { store in
            let bound = try seed(store, quantity: 100, pool: .tactical)
            let plan = sell(bound.id, quantity: 25)
            #expect(store.setTradePlan(plan, for: symbol))

            // Moving the card to another pool leaves the plan's own pool
            // behind, so the binding no longer resolves.
            let allocation = try #require(store.item(for: symbol)?.positionAllocation)
            _ = try store.transferPositionPortion(
                symbol: symbol, portionID: bound.id, quantity: 100,
                to: .strategic, reason: "moved", expectedRevision: allocation.revision
            )
            let moved = try #require(store.item(for: symbol))
            #expect(moved.salePlanSource(for: plan) == nil)
            // The card still holds 100; the old plan claims 25 until edited or
            // cancelled. Its old pool binding is stale, not the holding itself.
            #expect(moved.availableSalePlanQuantity(for: bound.id) == 75)
            // The stale binding stays on the plan, visible for the user to fix.
            #expect(moved.plans.first { $0.id == plan.id }?.positionPortionID == bound.id)

            let before = moved
            #expect(throws: TradePlanExecutionError.staleAllocation) {
                try store.recordTradePlanFill(
                    symbol: self.symbol, planID: plan.id, price: 12, quantity: 25,
                    date: self.day, fee: nil, note: nil
                )
            }
            #expect(store.item(for: symbol) == before)
        }
    }

    @Test("Another ledger's card cannot be targeted from this account")
    func crossAccountBindingRejected() throws {
        try withStore(accounts: true) { store in
            let financingCard = try store.withBrokerageAccount(.financing) { () -> PositionPortion in
                store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 50, date: day))
                let allocation = try #require(store.item(for: symbol)?.positionAllocation)
                return try store.transferPositionPortion(
                    symbol: symbol, portionID: allocation.portions[0].id, quantity: 50,
                    to: .tactical, reason: "financing", expectedRevision: allocation.revision
                ).portions[0]
            }
            store.withBrokerageAccount(.mengmeng) {
                store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 20, date: day))
            }

            // The card lives in the financing ledger; the plan would be written
            // against the mengmeng item, whose allocation has never heard of it.
            store.withBrokerageAccount(.mengmeng) {
                let item = try? #require(store.item(for: symbol))
                #expect(item?.salePlanSource(for: self.sell(financingCard.id, quantity: 10)) == nil)
                #expect(item?.availableSalePlanQuantity(for: financingCard.id) == 0)
                #expect(!store.setTradePlan(self.sell(financingCard.id, quantity: 10), for: self.symbol))
            }
            store.withBrokerageAccount(.financing) {
                #expect(store.item(for: symbol)?.salePlanSource(for: self.sell(financingCard.id, quantity: 10)) != nil)
            }
        }
    }

    @Test("A settled plan keeps its binding, and cancelling frees the shares")
    func cancellationRetainsBinding() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            var plan = sell(portion.id, quantity: 60)
            #expect(store.setTradePlan(plan, for: symbol))
            plan.status = .cancelled
            // A cancellation is admitted even though it is no longer claimed
            // against the card, and its binding is kept for the history.
            #expect(store.setTradePlan(plan, for: symbol))
            let item = try #require(store.item(for: symbol))
            #expect(item.plans.first { $0.id == plan.id }?.positionPortionID == portion.id)
            #expect(item.availableSalePlanQuantity(for: portion.id) == 100)
        }
    }

    // MARK: - Version gates

    @Test("Archive and wire round-trip the binding and reject a forged older version")
    func roundTripAndGates() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            let plan = sell(portion.id, quantity: 60)
            #expect(store.setTradePlan(plan, for: symbol))

            let archive = store.archive()
            #expect(archive.version == 15)
            let text = try archive.encoded()
            let decoded = try WatchlistArchive.decoded(from: text)
            #expect(decoded.lists.flatMap(\.entries).flatMap { $0.plans ?? [] }
                .first?.positionPortionID == portion.id)

            let wire = try WatchlistSyncWireCodec.encode(deviceID: "sale-plan", snapshot: store.syncSnapshot())
            #expect(try WatchlistSyncWireCodec.decode(wire).version == 17)

            // A payload claiming the older schema while carrying a binding is
            // rejected rather than silently downgraded.
            var object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            object["version"] = 14
            let forged = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(15)) {
                try WatchlistArchive.decoded(from: forged)
            }

            var envelope = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            envelope["version"] = 16
            let forgedWire = try JSONSerialization.data(withJSONObject: envelope)
            #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(17)) {
                try WatchlistSyncWireCodec.decode(forgedWire)
            }
        }
    }

    @Test("A binding on a cancelled plan still claims the new version")
    func cancelledBindingKeepsVersion() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            var plan = sell(portion.id, quantity: 60)
            #expect(store.setTradePlan(plan, for: symbol))
            plan.status = .cancelled
            #expect(store.setTradePlan(plan, for: symbol))
            // The claim on the card is released, but the record of which card
            // it was written against is retained and must travel.
            #expect(store.item(for: symbol)?.availableSalePlanQuantity(for: portion.id) == 100)
            #expect(store.archive().version == 15)
        }

        // Unrelated data keeps the version it always had.
        let plain = WatchlistArchive(lists: [
            .init(name: "Core", entries: [.init(market: .us, code: "NVDA")])
        ])
        #expect(plain.version == 2)
    }

    @Test("A binding that survives only in history or a fill still claims the new version")
    func historyAndFillOnlyGates() throws {
        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            let plan = sell(portion.id, quantity: 60)
            #expect(store.setTradePlan(plan, for: symbol))
            _ = try store.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: 12, quantity: 20,
                date: day, fee: nil, note: nil
            )
            // An edit that clears the live binding appends the configuration
            // that had it as a revision, so the binding is still on the plan.
            var unbound = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            unbound.positionPortionID = nil
            unbound.quantity = 70
            #expect(store.setTradePlan(unbound, for: symbol))

            let stored = try #require(store.item(for: symbol)?.plans.first { $0.id == plan.id })
            #expect(stored.positionPortionID == nil)
            #expect(stored.hasPositionPortionMetadata)
            #expect(TradePlanConfiguration.hasPositionPortionMetadata(
                in: (stored.history ?? []).map(\.configuration)
            ))
            #expect(store.archive().version == 15)

            // The fill's own immutable snapshot kept the card it consumed even
            // though the plan no longer names one.
            let item = try #require(store.item(for: symbol))
            let execution = try #require(item.transactions.first { $0.planExecution != nil }?.planExecution)
            #expect(execution.hasPositionPortionMetadata)
            #expect(execution.configuration.positionPortionID == portion.id)
        }
    }

    @Test("Legacy JSON without the field decodes to no binding")
    func legacyDecodesNil() throws {
        let id = UUID()
        let legacy = """
        {"id":"\(id.uuidString)","kind":"sell","price":12,"quantity":10,"status":"active",\
        "createdAt":0,"updatedAt":0,"positionPool":"tactical"}
        """
        let plan = try JSONDecoder().decode(TradePlan.self, from: Data(legacy.utf8))
        #expect(plan.positionPortionID == nil)
        #expect(!plan.hasPositionPortionMetadata)
        #expect(TradePlanConfiguration(plan: plan).positionPortionID == nil)

        try withStore { store in
            let portion = try seed(store, quantity: 100, pool: .tactical)
            // An old unbound plan is never defaulted onto a card, even when one
            // is sitting right there.
            #expect(store.setTradePlan(TradePlan(kind: .sell, price: 12, quantity: 10, positionPool: .tactical),
                                       for: symbol))
            let item = try #require(store.item(for: symbol))
            #expect(item.plans.first?.positionPortionID == nil)
            #expect(item.availableSalePlanQuantity(for: portion.id) == 100)
        }
    }
}
