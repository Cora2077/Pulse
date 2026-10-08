import Foundation
import Testing
@testable import PulseCore

/// Account routing for buys: which ledger a purchase actually lands in, which
/// funding each destination permits, and what a refusal leaves behind.
///
/// The corrected contract is that account ownership is a *recorded fact on the
/// transaction*, chosen at entry time — not inferred from whichever ledger the
/// UI happened to have open. A buy names its destination and its money; the
/// destination's independent ledger and cost basis follow from that, while the
/// account the user was looking at stays exactly where it was.
///
/// The legacy path is kept honest here too: with no account named, a buy still
/// behaves exactly as it always did (it lands in the enclosing ledger), except
/// that named accounts being enabled refuses a margin buy into Mengmeng.
@Suite("Buy account selection")
struct BuyAccountSelectionTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    @MainActor
    private func makeStore() throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "BuyAccountSelectionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Fixture")
        store.enableBrokerageAccounts()
        store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        return (store, defaults, suite)
    }

    private func buy(
        _ account: BrokerageAccountID?,
        _ funding: PositionFundingSource?,
        price: Double = 100,
        quantity: Double = 2,
        fee: Double? = nil,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PositionTransaction {
        .init(kind: .buy, price: price, quantity: quantity, date: date,
              fee: fee, fundingSource: funding, brokerageAccountID: account)
    }

    // MARK: - Direct routing to a destination

    @Test @MainActor
    func directBuysRouteToEachNamedDestination() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let own = buy(.financing, .own, quantity: 2)
        let margin = buy(.financing, .margin, quantity: 3)
        let mengmeng = buy(.mengmeng, .own, quantity: 4)
        for transaction in [own, margin, mengmeng] {
            let recorded = try store.recordBuyTransaction(symbol, transaction, account: transaction.brokerageAccountID!)
            #expect(recorded == transaction)
        }

        // Every buy sits in the ledger it named, and nowhere else.
        let financing = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
        let mengmengItem = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
        #expect(financing.transactions.map(\.id) == [own.id, margin.id])
        #expect(mengmengItem.transactions.map(\.id) == [mengmeng.id])

        // The active UI source account never moved, and holds no part of them.
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.item(for: symbol)?.positionQuantity ?? 0 == 0)

        // Tag and ledger values follow the destination each buy named.
        #expect(financing.positionQuantity == 5)
        #expect(financing.positionAllocation?.portions.map(\.brokerageAccountID) == [.financing, .financing])
        #expect(financing.positionAllocation?.portions.map(\.fundingSource) == [.own, .margin])
        #expect(financing.positionAccountQuantities(enclosingAccountID: .financing) == [.financing: 5])
        #expect(!financing.positionAllocationNeedsReconciliation)
        #expect(mengmengItem.positionQuantity == 4)
        #expect(mengmengItem.positionAllocation?.portions.first?.brokerageAccountID == .mengmeng)
    }

    @Test @MainActor
    func financingMarginIsAValidBuyWhileMengmengMarginIsNot() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let margin = try store.recordBuyTransaction(symbol, buy(.financing, .margin, quantity: 5), account: .financing)
        #expect(margin.fundingSource == .margin)
        let portion = try #require(
            store.brokeragePortfolio(for: .financing).items
                .first { $0.symbol == symbol }?.positionAllocation?.portions.first
        )
        #expect(portion.brokerageAccountID == .financing)
        #expect(portion.fundingSource == .margin)
        #expect(portion.quantity == 5)

        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            try store.recordBuyTransaction(symbol, buy(.mengmeng, .margin), account: .mengmeng)
        }
        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            // Mengmeng with no method recorded is not a permitted buy either.
            try store.recordBuyTransaction(symbol, buy(.mengmeng, nil), account: .mengmeng)
        }
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    @Test @MainActor
    func theExplicitDestinationGovernsFundingValidation() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // The `account` parameter is the destination of record: a margin buy into
        // the financing ledger is legal even if the draft still carried another
        // account's label from a previous screen.
        let margin = try store.recordBuyTransaction(symbol, buy(.mengmeng, .margin), account: .financing)
        #expect(margin.brokerageAccountID == .financing)
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)

        // And the destination it names is what refuses an illegal method.
        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            try store.recordBuyTransaction(symbol, buy(.financing, .margin), account: .mengmeng)
        }
        #expect(store.brokeragePortfolio(for: .mengmeng).items.isEmpty)
    }

    // MARK: - Independent ledgers and cost bases

    @Test @MainActor
    func targetLedgerKeepsItsOwnCostAlongsideAnExistingPosition() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Seed the target account with an existing, differently-priced position.
        _ = try store.recordBuyTransaction(symbol, buy(.mengmeng, .own, price: 50, quantity: 2), account: .mengmeng)
        let added = try store.recordBuyTransaction(symbol, buy(.mengmeng, .own, price: 100, quantity: 2), account: .mengmeng)

        let item = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
        #expect(item.transactions.map(\.id).contains(added.id))
        #expect(item.positionQuantity == 4)
        // (50×2 + 100×2) / 4 — the target's own blended cost.
        let ledger = PositionLedger(transactions: item.transactions)
        #expect(ledger.averageCost == 75)
        #expect(ledger.costBasis == 300)
        #expect(item.positionAllocation?.portions.allSatisfy { $0.brokerageAccountID == .mengmeng } == true)
        #expect(!item.positionAllocationNeedsReconciliation)

        // A same-symbol buy in the other account is a separate cost basis.
        _ = try store.recordBuyTransaction(symbol, buy(.financing, .own, price: 10, quantity: 1), account: .financing)
        let other = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
        #expect(PositionLedger(transactions: other.transactions).averageCost == 10)
    }

    @Test @MainActor
    func destinationSymbolIsCreatedFromSourceIdentityWithoutCopyingHistory() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.setThesis("Source reasoning", for: symbol)
        _ = try store.recordBuyTransaction(symbol, buy(.financing, .own, quantity: 1), account: .financing)
        let plan = TradePlan(kind: .buy, price: 10, quantity: 1)
        #expect(store.setTradePlan(plan, for: symbol))

        // A buy into a ledger that has never seen the symbol adds it there...
        _ = try store.recordBuyTransaction(symbol, buy(.mengmeng, .own, quantity: 2), account: .mengmeng)
        let target = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
        #expect(target.displayName == "Fixture")

        // ...but never copies the source's trades, plans, or notes.
        #expect(target.transactions.count == 1)
        #expect(target.plans.isEmpty)
        #expect(target.thesis == nil)
        let source = try #require(store.item(for: symbol))
        #expect(source.plans.map(\.id) == [plan.id])
        #expect(source.thesis == "Source reasoning")
        // The target's buy stayed in the target: nothing of it appears in the
        // source ledger, and the source keeps the reasoning it always had.
        #expect(source.transactions.contains { $0.id == target.transactions[0].id } == false)
    }

    // MARK: - Refusals leave nothing behind

    @Test @MainActor
    func malformedBuysAreRejectedWithoutMutation() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = store.syncSnapshot()

        // Unassigned is not a buy destination.
        #expect(throws: TradePlanExecutionError.invalidBuyAccount) {
            try store.recordBuyTransaction(symbol, buy(.unassigned, .own), account: .unassigned)
        }
        // No method recorded.
        #expect(throws: TradePlanExecutionError.invalidBuyMethod) {
            try store.recordBuyTransaction(symbol, buy(.financing, nil), account: .financing)
        }
        // Non-finite and non-positive numbers, and a malformed date. A zero
        // price is deliberately absent: a buy may bridge a share split at zero.
        for bad in [
            buy(.financing, .own, price: .nan),
            buy(.financing, .own, quantity: 0),
            buy(.financing, .own, quantity: .infinity),
            buy(.financing, .own, fee: -1),
            buy(.financing, .own, fee: .nan),
            buy(.financing, .own, date: Date(timeIntervalSince1970: .nan))
        ] {
            #expect(throws: TradePlanExecutionError.invalidFill) {
                try store.recordBuyTransaction(symbol, bad, account: .financing)
            }
        }
        #expect(store.syncSnapshot() == before, "a refusal writes nothing at all")
    }

    @Test @MainActor
    func unknownInstrumentAndDuplicateIDAreRefused() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorded = try store.recordBuyTransaction(symbol, buy(.financing, .own), account: .financing)
        let before = store.syncSnapshot()

        #expect(throws: TradePlanExecutionError.duplicateTransactionID) {
            try store.recordBuyTransaction(symbol, recorded, account: .financing)
        }

        // A destination only ever receives an instrument the store already knows.
        let unknown = SymbolID(market: .us, code: "MSFT")
        #expect(throws: TradePlanExecutionError.itemNotFound) {
            try store.recordBuyTransaction(unknown, buy(.financing, .own), account: .financing)
        }
        #expect(store.syncSnapshot() == before)
    }

    // MARK: - A later sell stays in the account that owns the shares

    @Test @MainActor
    func sellInTheSourceLedgerDoesNotConsumeATargetBuy() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A source-ledger position the sell is allowed to spend.
        store.addTransaction(symbol, buy(nil, .own, price: 10, quantity: 5))
        // A target position that the source's sell must leave alone.
        _ = try store.recordBuyTransaction(symbol, buy(.mengmeng, .own, price: 100, quantity: 3), account: .mengmeng)

        let sell = PositionTransaction(kind: .sell, price: 12, quantity: 2,
                                       date: Date(timeIntervalSince1970: 1_700_100_000))
        store.addTransaction(symbol, sell)

        // The sale consumed the source ledger only.
        let source = try #require(store.item(for: symbol))
        #expect(source.transactions.count == 2)
        #expect(source.positionQuantity == 3)
        let target = try #require(store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol })
        #expect(target.transactions.count == 1)
        #expect(target.positionQuantity == 3)
        #expect(target.positionAllocation?.portions.first?.brokerageAccountID == .mengmeng)
    }

    // MARK: - Legacy path

    @Test @MainActor
    func legacyBuyWithoutAnAccountKeepsItsEnclosingLedger() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(nil, nil, quantity: 2))
        #expect(store.item(for: symbol)?.transactions.count == 1)
        #expect(store.item(for: symbol)?.transactions.first?.brokerageAccountID == nil)
        #expect(store.item(for: symbol)?.positionAccountQuantities(enclosingAccountID: .unassigned) == [.unassigned: 2])

        // But with named accounts enabled, a legacy margin buy into Mengmeng is
        // refused rather than quietly recorded.
        store.selectBrokerageAccount(.mengmeng)
        store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        let before = store.syncSnapshot()
        store.addTransaction(symbol, buy(nil, .margin))
        #expect(store.syncSnapshot() == before)
        #expect(store.activeBrokerageAccountID == .mengmeng)

        // A margin buy into the financing ledger through the same legacy entry
        // point is legal.
        store.selectBrokerageAccount(.financing)
        store.add(SymbolInfo(symbol: symbol, name: "Fixture"))
        store.addTransaction(symbol, buy(nil, .margin))
        #expect(store.item(for: symbol)?.positionQuantity == 2)
        #expect(store.activeBrokerageAccountID == .financing)
    }

    @Test @MainActor
    func legacyBuyNamingAnAccountRoutesThroughTheNewAPI() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        // `addTransaction` with an explicit named account is the legacy entry
        // point for the corrected routing, so it must land in that ledger.
        store.addTransaction(symbol, buy(.financing, .own, quantity: 2))
        #expect(store.item(for: symbol)?.positionQuantity ?? 0 == 0)
        let financing = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
        #expect(financing.transactions.count == 1)
        #expect(financing.positionQuantity == 2)
        #expect(store.activeBrokerageAccountID == .unassigned)

        // Mengmeng margin through the legacy entry point is still refused.
        let before = store.syncSnapshot()
        store.addTransaction(symbol, buy(.mengmeng, .margin))
        #expect(store.syncSnapshot() == before)
    }

    // MARK: - Reload

    @Test @MainActor
    func recordedAccountsSurviveReload() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try store.recordBuyTransaction(symbol, buy(.financing, .own, quantity: 2), account: .financing)
        _ = try store.recordBuyTransaction(symbol, buy(.financing, .margin, quantity: 3), account: .financing)
        _ = try store.recordBuyTransaction(symbol, buy(.mengmeng, .own, quantity: 4), account: .mengmeng)

        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Fixture")
        #expect(reloaded.brokerageAccountsEnabled)
        #expect(reloaded.brokeragePortfolio(for: .financing)
            .items.first { $0.symbol == symbol }?.positionQuantity == 5)
        #expect(reloaded.brokeragePortfolio(for: .mengmeng)
            .items.first { $0.symbol == symbol }?.positionQuantity == 4)
        #expect(reloaded.activeBrokerageAccountID == .unassigned)
    }

    // MARK: - Legacy schema/import compatibility

    @Test
    func legacyTransactionRemainsUnassignedAndKeepsOldSchemaVersions() throws {
        let original = buy(nil, nil)
        let data = try JSONEncoder().encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["brokerageAccountID"] == nil)
        #expect(try JSONDecoder().decode(PositionTransaction.self, from: data).brokerageAccountID == nil)
        let archive = WatchlistArchive(lists: [.init(name: "Fixture", entries: [.init(market: .us, code: "AAPL", transactions: [original])])])
        #expect(archive.version == 2)
        let snapshot = WatchlistSyncSnapshot(items: [.init(symbol: symbol, displayName: "Fixture", transactions: [original])], groups: [.init(name: "Fixture", symbols: [symbol])])
        #expect(try WatchlistSyncWireCodec.decode(WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: snapshot)).version == 3)
    }

    @Test
    func transactionAccountRaisesTheDeclaredVersionAndRoundTrips() throws {
        let transaction = buy(.mengmeng, .own)
        let item = WatchItem(symbol: symbol, displayName: "Fixture", transactions: [transaction])
        let snapshot = WatchlistSyncSnapshot(
            items: [item],
            groups: [.init(name: "Fixture", symbols: [symbol])]
        )
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: snapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot.items[0].transactions[0].brokerageAccountID == .mengmeng)

        // Claiming an older version while carrying the field is refused.
        var object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let version = try #require(object["version"] as? Int)
        #expect(version >= 15, "an assigned transaction account outranks the per-portion label version")
        object["version"] = version - 1
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(version)) {
            try WatchlistSyncWireCodec.decode(JSONSerialization.data(withJSONObject: object))
        }

        let archive = WatchlistArchive(lists: [.init(name: "Fixture", entries: [.init(market: .us, code: "AAPL", transactions: [transaction])])])
        #expect(archive.version >= 13, "the transaction account raises the archive past an untagged payload")
        #expect(archive.version <= WatchlistArchive.currentVersion)
        #expect(try WatchlistArchive.decoded(from: archive.encoded()).lists[0].entries[0].transactions == [transaction])
        var lowered = archive
        lowered.version = archive.version - 1
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(archive.version)) {
            try WatchlistArchive.decoded(from: lowered.encoded())
        }
    }

    @Test @MainActor
    func anAccountLabelInChangeHistoryStillRaisesTheVersion() throws {
        let (store, defaults, suite) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, buy(.financing, .own))
        // Move the label out of the live portion list and into the change log:
        // an older reader stopping at the declared version would drop that
        // history, so the payload still has to claim the account version.
        var item = try #require(store.brokeragePortfolio(for: .financing).items.first { $0.symbol == symbol })
        item.positionAllocation?.portions = []
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "history-only", snapshot: WatchlistSyncSnapshot(
            items: [], groups: [.init(name: "Fixture", symbols: [symbol])], brokerageAccounts: [
                .init(accountID: .financing, items: [item])
            ]
        ))
        let object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let version = try #require(object["version"] as? Int)
        #expect(version >= 14, "a label kept only in history must never be readable as an older payload")
    }
}
