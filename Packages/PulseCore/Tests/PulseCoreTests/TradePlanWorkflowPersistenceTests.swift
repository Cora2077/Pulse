import Foundation
import Testing
@testable import PulseCore

/// Round-trip and compatibility coverage for a plan's conditions/history and
/// the plan snapshot a transaction recorded its fill from.
///
/// The two storage surfaces version independently: `WatchlistArchive` keeps its
/// human-readable shape, `WatchlistSyncWireCodec` its numeric dates. Both gain a
/// tier only when the workflow payload is actually present, so older exports and
/// sync files keep the smallest version that describes them.
@Suite("Trade plan workflow persistence")
struct TradePlanWorkflowPersistenceTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private func condition(
        id: UUID = UUID(),
        title: String,
        kind: TradePlanCondition.Kind = .manual,
        state: TradePlanCondition.State = .pending,
        note: String? = nil,
        sourceURL: String? = nil,
        reviewDate: Date? = nil
    ) -> TradePlanCondition {
        TradePlanCondition(
            id: id, title: title, kind: kind, state: state,
            note: note, sourceURL: sourceURL, reviewDate: reviewDate
        )
    }

    private func configuration(
        price: Double = 200,
        quantity: Double = 100,
        kind: TradePlan.Kind = .buy,
        status: TradePlan.Status = .active,
        note: String? = nil,
        positionPool: PositionPool? = nil,
        conditions: [TradePlanCondition]? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TradePlanConfiguration {
        TradePlanConfiguration(plan: TradePlan(
            kind: kind, price: price, quantity: quantity, status: status,
            note: note, createdAt: createdAt, updatedAt: createdAt,
            positionPool: positionPool, conditions: conditions
        ))
    }

    private func plan(
        id: UUID = UUID(),
        kind: TradePlan.Kind = .buy,
        price: Double = 200,
        quantity: Double = 100,
        status: TradePlan.Status = .active,
        note: String? = nil,
        updatedAt: TimeInterval = 1_700_000_000,
        filledTransactionID: UUID? = nil,
        positionPool: PositionPool? = nil,
        conditions: [TradePlanCondition]? = nil,
        history: [TradePlanRevision]? = nil
    ) -> TradePlan {
        TradePlan(
            id: id, kind: kind, price: price, quantity: quantity, status: status,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            filledTransactionID: filledTransactionID,
            positionPool: positionPool,
            conditions: conditions,
            history: history
        )
    }

    private func archive(_ plan: TradePlan, transactions: [PositionTransaction]? = nil) -> WatchlistArchive {
        WatchlistArchive(lists: [
            .init(name: "Core", entries: [
                .init(market: .us, code: "AAPL", name: "Apple", transactions: transactions, plans: [plan])
            ])
        ])
    }

    // MARK: - Old JSON still decodes

    @Test("A plan written before conditions, history, or execution still decodes")
    func legacyPlanDecodes() throws {
        // The exact shape an export wrote before this workflow existed: no
        // conditions, no history, no planExecution on the transaction.
        let legacyPlan = """
        {"id":"11111111-1111-1111-1111-111111111111","kind":"buy","price":200,"quantity":100,
         "status":"active","createdAt":0,"updatedAt":0,"positionPool":"strategic"}
        """
        let decodedPlan = try JSONDecoder().decode(TradePlan.self, from: Data(legacyPlan.utf8))
        #expect(decodedPlan.conditions == nil)
        #expect(decodedPlan.history == nil)
        #expect(decodedPlan.positionPool == .strategic)

        let legacyTransaction = """
        {"id":"22222222-2222-2222-2222-222222222222","kind":"buy","price":200,"quantity":40,
         "date":0,"createdAt":0}
        """
        let decodedTransaction = try JSONDecoder().decode(PositionTransaction.self, from: Data(legacyTransaction.utf8))
        #expect(decodedTransaction.planExecution == nil)

        // An archive carrying only a pool keeps the pool tier, not the newer one.
        let plain = archive(plan(positionPool: .strategic))
        #expect(plain.version == 6)
        let decoded = try WatchlistArchive.decoded(from: plain.encoded())
        #expect(decoded.lists[0].entries[0].plans?[0].conditions == nil)
        #expect(decoded.lists[0].entries[0].plans?[0].history == nil)

        let wire = try WatchlistSyncWireCodec.encode(
            deviceID: "legacy-workflow",
            snapshot: WatchlistSyncSnapshot(
                items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [plan(positionPool: .strategic)])],
                groups: []
            )
        )
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 7)
    }

    // MARK: - New JSON round-trips

    @Test("Conditions, history, and a fill snapshot round-trip through the archive")
    func archiveRoundTripsWorkflowPayload() throws {
        let conditionID = UUID()
        let revisionID = UUID()
        let transactionID = UUID()
        let planID = UUID()
        let conditions = [
            condition(id: conditionID, title: "Volume above average", kind: .logic, note: "20-day"),
            condition(title: "Earnings cleared", kind: .event, state: .confirmed,
                      sourceURL: "https://example.com/earnings", reviewDate: Date(timeIntervalSince1970: 1_800_000_000))
        ]
        let history = [
            TradePlanRevision(
                id: revisionID,
                date: Date(timeIntervalSince1970: 1_700_000_500),
                configuration: configuration(price: 210, quantity: 80, note: "first draft")
            )
        ]
        let execution = TradePlanExecution(
            planID: planID,
            configuration: configuration(price: 200, quantity: 100, conditions: [conditions[0]])
        )
        let transaction = PositionTransaction(
            id: transactionID,
            kind: .buy,
            price: 198,
            quantity: 40,
            date: Date(timeIntervalSince1970: 1_700_100_000),
            createdAt: Date(timeIntervalSince1970: 1_700_100_000),
            planExecution: execution
        )
        let source = archive(
            plan(id: planID, conditions: conditions, history: history),
            transactions: [transaction]
        )
        #expect(source.version == 7)

        let decoded = try WatchlistArchive.decoded(from: source.encoded())
        let decodedPlan = try #require(decoded.lists[0].entries[0].plans?.first)
        #expect(decodedPlan.conditions == conditions)
        #expect(decodedPlan.history == history)
        #expect(decodedPlan.history?.first?.id == revisionID)
        let decodedTransaction = try #require(decoded.lists[0].entries[0].transactions?.first)
        #expect(decodedTransaction.planExecution?.planID == planID)
        #expect(decodedTransaction.planExecution?.configuration == execution.configuration)
        #expect(decodedTransaction.planExecution?.configuration.conditions == [conditions[0]])
    }

    @Test("Conditions, history, and a fill snapshot round-trip through the sync wire")
    func wireRoundTripsWorkflowPayload() throws {
        let planID = UUID()
        let transactionID = UUID()
        let conditions = [condition(title: "Break above 210", kind: .logic)]
        let history = [TradePlanRevision(
            date: Date(timeIntervalSince1970: 1_700_000_500),
            configuration: configuration(price: 205)
        )]
        let execution = TradePlanExecution(
            planID: planID,
            configuration: configuration(price: 200, positionPool: .tactical)
        )
        let snapshot = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbol,
                displayName: "Apple",
                transactions: [PositionTransaction(
                    id: transactionID, kind: .buy, price: 199, quantity: 30,
                    date: Date(timeIntervalSince1970: 1_700_100_000),
                    planExecution: execution
                )],
                plans: [plan(id: planID, conditions: conditions, history: history)]
            )],
            groups: [WatchlistGroup(name: "Core", symbols: [symbol])]
        )

        let wire = try WatchlistSyncWireCodec.encode(deviceID: "workflow-wire", snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(wire, expectedDeviceID: "workflow-wire")
        #expect(decoded.version == 8)
        #expect(decoded.snapshot == snapshot)
        #expect(decoded.snapshot.items[0].plans[0].conditions == conditions)
        #expect(decoded.snapshot.items[0].plans[0].history == history)
        #expect(decoded.snapshot.items[0].transactions[0].planExecution?.configuration.positionPool == .tactical)
    }

    @Test("A payload without workflow data still encodes at its original minimal version")
    func workflowFreePayloadKeepsMinimalVersion() throws {
        let plainPlan = plan()
        let plainTransaction = PositionTransaction(kind: .buy, price: 200, quantity: 1)
        let plainArchive = archive(plainPlan, transactions: [plainTransaction])
        #expect(plainArchive.version == 2)
        #expect(try WatchlistArchive.decoded(from: plainArchive.encoded()).version == 2)

        let plainSnapshot = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple", transactions: [plainTransaction], plans: [plainPlan])],
            groups: []
        )
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "plain", snapshot: plainSnapshot)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 3)

        // An empty condition array is not payload: it must not bump the tier.
        let emptyConditions = archive(plan(conditions: []))
        #expect(emptyConditions.version == 2)
        let emptyWire = try WatchlistSyncWireCodec.encode(
            deviceID: "plain-empty",
            snapshot: WatchlistSyncSnapshot(
                items: [WatchItem(symbol: symbol, displayName: "Apple", plans: [plan(conditions: [])])],
                groups: []
            )
        )
        #expect(try WatchlistSyncWireCodec.decode(emptyWire).version == 3)
    }

    @Test("A transaction fill snapshot alone bumps the archive and wire tiers")
    func executionAloneBumpsVersion() throws {
        let transaction = PositionTransaction(
            kind: .buy, price: 200, quantity: 20,
            planExecution: TradePlanExecution(planID: UUID(), configuration: configuration())
        )
        let planOnly = archive(plan())
        #expect(planOnly.version == 2)

        let withExecution = archive(plan(), transactions: [transaction])
        #expect(withExecution.version == 7)
        #expect(try WatchlistArchive.decoded(from: withExecution.encoded()).version == 7)

        let wire = try WatchlistSyncWireCodec.encode(
            deviceID: "execution",
            snapshot: WatchlistSyncSnapshot(
                items: [WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction])],
                groups: []
            )
        )
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 8)
    }

    // MARK: - Downgrade rejection

    @Test("A workflow payload masquerading as an older archive is rejected")
    func archiveDowngradeIsRejected() throws {
        let workflowArchive = archive(plan(conditions: [condition(title: "Wait for volume")]))
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(try workflowArchive.encoded().utf8)) as? [String: Any]
        )

        for staleVersion in [2, 5, 6] {
            object["version"] = staleVersion
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(7)) {
                try WatchlistArchive.decoded(from: String(decoding: data, as: UTF8.self))
            }
        }

        // A freshly written workflow archive is accepted at its own version.
        #expect(try WatchlistArchive.decoded(from: workflowArchive.encoded()).version == 7)

        // The transaction half of the payload is gated the same way.
        let executionArchive = archive(plan(), transactions: [PositionTransaction(
            kind: .buy, price: 200, quantity: 1,
            planExecution: TradePlanExecution(planID: UUID(), configuration: configuration())
        )])
        var executionObject = try #require(
            JSONSerialization.jsonObject(with: Data(try executionArchive.encoded().utf8)) as? [String: Any]
        )
        executionObject["version"] = 6
        let staleExecution = try JSONSerialization.data(withJSONObject: executionObject, options: [.sortedKeys])
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(7)) {
            try WatchlistArchive.decoded(from: String(decoding: staleExecution, as: UTF8.self))
        }
    }

    @Test("A workflow payload masquerading as an older wire version is rejected")
    func wireDowngradeIsRejected() throws {
        let snapshot = WatchlistSyncSnapshot(
            items: [WatchItem(
                symbol: symbol,
                displayName: "Apple",
                plans: [plan(conditions: [condition(title: "Wait for volume")], history: [
                    TradePlanRevision(configuration: configuration(price: 190))
                ])]
            )],
            groups: []
        )
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "downgrade", snapshot: snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])

        for staleVersion in [3, 6, 7] {
            object["version"] = staleVersion
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(8)) {
                _ = try WatchlistSyncWireCodec.decode(data)
            }
        }

        // A transaction fill snapshot alone is gated too.
        let executionSnapshot = WatchlistSyncSnapshot(
            items: [WatchItem(symbol: symbol, displayName: "Apple", transactions: [PositionTransaction(
                kind: .buy, price: 200, quantity: 1,
                planExecution: TradePlanExecution(planID: UUID(), configuration: configuration())
            )])],
            groups: []
        )
        let executionWire = try WatchlistSyncWireCodec.encode(deviceID: "downgrade-exec", snapshot: executionSnapshot)
        var executionObject = try #require(JSONSerialization.jsonObject(with: executionWire) as? [String: Any])
        executionObject["version"] = 7
        let staleExecution = try JSONSerialization.data(withJSONObject: executionObject, options: [.sortedKeys])
        #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(8)) {
            _ = try WatchlistSyncWireCodec.decode(staleExecution)
        }
    }

    // MARK: - Fresh metadata validation on decode

    @Test("Fresh workflow metadata is validated on decode")
    func freshMetadataValidation() throws {
        // A condition that does not survive normalization (blank title) cannot
        // be written by the store, so a file claiming it is malformed.
        let blankCondition = TradePlanCondition(title: "   ", kind: .manual)
        let blankArchive = archive(plan(conditions: [blankCondition]))
        #expect(throws: WatchlistArchive.DecodingFailure.invalidTradePlan(
            blankArchive.lists[0].entries[0].plans![0].id
        )) {
            try WatchlistArchive.decoded(from: blankArchive.encoded())
        }

        // Duplicate revision ids would make the history ambiguous.
        let revision = TradePlanRevision(configuration: configuration(price: 190))
        let duplicateArchive = archive(plan(history: [revision, revision]))
        #expect(throws: WatchlistArchive.DecodingFailure.duplicateTradePlanRevisionID(revision.id)) {
            try WatchlistArchive.decoded(from: duplicateArchive.encoded())
        }

        // Duplicate condition ids on a plan are caught as well.
        let shared = condition(title: "Shared")
        let duplicateConditions = archive(plan(conditions: [shared, shared]))
        #expect(throws: WatchlistArchive.DecodingFailure.duplicateTradePlanConditionID(shared.id)) {
            try WatchlistArchive.decoded(from: duplicateConditions.encoded())
        }

        // A revision whose configuration has no usable price is not replayable.
        let badRevision = TradePlanRevision(configuration: configuration(price: 0))
        let badRevisionArchive = archive(plan(history: [badRevision]))
        #expect(throws: WatchlistArchive.DecodingFailure.invalidTradePlan(
            badRevisionArchive.lists[0].entries[0].plans![0].id
        )) {
            try WatchlistArchive.decoded(from: badRevisionArchive.encoded())
        }

        // A fill snapshot whose configuration has no usable price is rejected
        // against its transaction. (Zero, not NaN: JSON cannot carry the latter.)
        let badExecution = TradePlanExecution(planID: UUID(), configuration: configuration(price: 0))
        let transaction = PositionTransaction(kind: .buy, price: 200, quantity: 1, planExecution: badExecution)
        #expect(throws: WatchlistArchive.DecodingFailure.invalidPlanExecution(transaction.id)) {
            try WatchlistArchive.decoded(from: archive(plan(), transactions: [transaction]).encoded())
        }
    }

    @Test("The wire codec validates fresh workflow metadata the same way")
    func wireFreshMetadataValidation() throws {
        func snapshot(_ item: WatchItem) -> WatchlistSyncSnapshot {
            WatchlistSyncSnapshot(items: [item], groups: [WatchlistGroup(name: "Core", symbols: [symbol])])
        }

        let blankCondition = TradePlanCondition(title: " ", kind: .manual)
        let badPlan = plan(conditions: [blankCondition])
        #expect(throws: WatchlistSyncWireCodec.CodecError.invalidTradePlan(badPlan.id)) {
            _ = try WatchlistSyncWireCodec.encode(
                deviceID: "invalid",
                snapshot: snapshot(WatchItem(symbol: symbol, displayName: "Apple", plans: [badPlan]))
            )
        }

        let revision = TradePlanRevision(configuration: configuration(price: 190))
        let duplicatePlan = plan(history: [revision, revision])
        #expect(throws: WatchlistSyncWireCodec.CodecError.duplicateTradePlanRevisionID(revision.id)) {
            _ = try WatchlistSyncWireCodec.encode(
                deviceID: "invalid",
                snapshot: snapshot(WatchItem(symbol: symbol, displayName: "Apple", plans: [duplicatePlan]))
            )
        }

        let shared = condition(title: "Shared")
        let duplicateConditions = plan(conditions: [shared, shared])
        #expect(throws: WatchlistSyncWireCodec.CodecError.duplicateTradePlanConditionID(shared.id)) {
            _ = try WatchlistSyncWireCodec.encode(
                deviceID: "invalid",
                snapshot: snapshot(WatchItem(symbol: symbol, displayName: "Apple", plans: [duplicateConditions]))
            )
        }

        let transaction = PositionTransaction(
            kind: .buy, price: 200, quantity: 1,
            planExecution: TradePlanExecution(planID: UUID(), configuration: configuration(price: 0))
        )
        #expect(throws: WatchlistSyncWireCodec.CodecError.invalidPlanExecution(transaction.id)) {
            _ = try WatchlistSyncWireCodec.encode(
                deviceID: "invalid",
                snapshot: snapshot(WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction]))
            )
        }
    }

    // MARK: - Agent readback

    @MainActor
    @Test("Agent readback carries conditions, history, fill progress, and the fill snapshot")
    func agentReadbackCarriesWorkflow() throws {
        let suite = "TradePlanWorkflowPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))

        let planID = UUID()
        let conditions = [condition(title: "Volume above average", kind: .logic)]
        #expect(store.setTradePlan(
            plan(id: planID, quantity: 100, conditions: conditions),
            for: symbol
        ))
        // A second edit appends the prior configuration to the history.
        #expect(store.setTradePlan(plan(id: planID, price: 190, quantity: 100, conditions: conditions), for: symbol))
        let saved = try #require(store.item(for: symbol)?.plans.first)
        #expect(saved.conditions == conditions)
        #expect(saved.history?.isEmpty == false)

        let fill = PositionTransaction(
            id: UUID(), kind: .buy, price: 198, quantity: 40,
            date: Date(timeIntervalSince1970: 1_700_100_000),
            planExecution: TradePlanExecution(planID: planID, configuration: configuration(price: 190, quantity: 100))
        )
        store.addTransaction(symbol, fill)

        let agentPlan = try #require(
            AgentWatchlistCommands(store: store).listPositions().first?.plans.first
        )
        #expect(agentPlan.id == planID)
        #expect(agentPlan.conditions == conditions)
        #expect(agentPlan.history == saved.history)
        #expect(agentPlan.fillQuantity == 40)
        #expect(agentPlan.remainingQuantity == 60)

        let agentTransaction = try #require(
            AgentWatchlistCommands(store: store).listPositions().first?.transactions.first
        )
        #expect(agentTransaction.planExecution?.planID == planID)
        #expect(agentTransaction.planExecution?.configuration.price == 190)
    }

    @MainActor
    @Test("An agent plan edit cannot clear conditions or history")
    func agentEditPreservesWorkflowMetadata() throws {
        let suite = "TradePlanWorkflowEditTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let planID = UUID()
        let conditions = [condition(title: "Volume above average")]
        #expect(store.setTradePlan(
            plan(id: planID, quantity: 100, positionPool: .strategic, conditions: conditions),
            for: symbol
        ))
        #expect(store.setTradePlan(
            plan(id: planID, price: 190, quantity: 100, positionPool: .strategic, conditions: conditions),
            for: symbol
        ))
        let historyBefore = try #require(store.item(for: symbol)?.plans.first?.history)

        // The agent command only knows kind/price/quantity; the metadata the
        // user owns has to survive it.
        _ = try AgentWatchlistCommands(store: store).setTradePlan(
            symbol: AgentSymbolRef(market: "us", code: "AAPL"),
            id: planID,
            kind: .buy,
            price: 185,
            quantity: 120
        ).get()

        let saved = try #require(store.item(for: symbol)?.plans.first)
        #expect(saved.price == 185)
        #expect(saved.quantity == 120)
        #expect(saved.positionPool == .strategic)
        #expect(saved.conditions == conditions)
        // The agent edit is a real configuration change, so the store appends
        // the prior one — the earlier revisions survive as a prefix.
        #expect(saved.history.map { Array($0.prefix(historyBefore.count)) } == historyBefore)
        #expect(saved.history?.count == historyBefore.count + 1)
        #expect(saved.history?.last?.configuration.price == 190)
    }

    @MainActor
    @Test("Workflow metadata survives store reload, archive, and merge into a fresh install")
    func endToEndPersistence() throws {
        let suite = "TradePlanWorkflowPersistenceTests.e2e.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        let planID = UUID()
        let conditions = [condition(title: "Volume above average", kind: .logic)]
        #expect(store.setTradePlan(plan(id: planID, quantity: 100, conditions: conditions), for: symbol))
        #expect(store.setTradePlan(plan(id: planID, price: 190, quantity: 100, conditions: conditions), for: symbol))
        let fill = PositionTransaction(
            kind: .buy, price: 198, quantity: 40,
            planExecution: TradePlanExecution(planID: planID, configuration: configuration(price: 190))
        )
        store.addTransaction(symbol, fill)

        // Reload from disk: the same JSON the app writes.
        let reloaded = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        let reloadedPlan = try #require(reloaded.item(for: symbol)?.plans.first)
        #expect(reloadedPlan.conditions == conditions)
        #expect(reloadedPlan.history?.isEmpty == false)
        #expect(reloaded.item(for: symbol)?.transactions.first?.planExecution?.planID == planID)

        // Archive into a fresh install and confirm nothing was lost.
        let archive = reloaded.archive()
        #expect(archive.version == 7)
        let restoredDefaults = try #require(UserDefaults(suiteName: "\(suite).restore"))
        defer { restoredDefaults.removePersistentDomain(forName: "\(suite).restore") }
        let restored = WatchlistStore(defaults: restoredDefaults, defaultGroupName: "Watchlist")
        restored.merge(try WatchlistArchive.decoded(from: archive.encoded()))
        let restoredPlan = try #require(restored.item(for: symbol)?.plans.first)
        #expect(restoredPlan.id == planID)
        #expect(restoredPlan.conditions == conditions)
        #expect(restoredPlan.history == reloadedPlan.history)
        #expect(restored.item(for: symbol)?.transactions.first?.planExecution?.configuration.price == 190)
    }
    @Test("Old-peer edits and conflict choices preserve the fill snapshot and workflow metadata")
    func mergePreservesUnknownWorkflowMetadata() throws {
        var p = plan(conditions: [condition(title: "Demand")], history: [.init(configuration: configuration(price: 190))])
        let execution = TradePlanExecution(planID: p.id, configuration: .init(plan: p))
        var transaction = PositionTransaction(kind: .buy, price: 200, quantity: 40, planExecution: execution)
        func snapshot(_ transaction: PositionTransaction, _ plan: TradePlan) -> WatchlistSyncSnapshot {
            .init(items: [WatchItem(symbol: symbol, displayName: "Apple", transactions: [transaction], plans: [plan])], groups: [])
        }
        let base = snapshot(transaction, p)
        var legacyTransaction = transaction
        legacyTransaction.price = 201
        legacyTransaction.planExecution = nil
        var legacyPlan = p
        legacyPlan.price = 205
        legacyPlan.updatedAt = p.updatedAt.addingTimeInterval(1)
        legacyPlan.conditions = nil
        legacyPlan.history = nil
        let remote = snapshot(legacyTransaction, legacyPlan)
        let ordinary = WatchlistSyncMerge.merge(base: base, local: base, remote: remote)
        #expect(ordinary.conflicts.isEmpty)
        #expect(ordinary.snapshot.items.first?.transactions.first?.price == 201)
        #expect(ordinary.snapshot.items.first?.transactions.first?.planExecution == execution)
        #expect(ordinary.snapshot.items.first?.plans.first?.conditions == p.conditions)
        #expect(ordinary.snapshot.items.first?.plans.first?.history == p.history)
        transaction.price = 202
        p.note = "Local"
        let conflict = WatchlistSyncMerge.merge(base: base, local: snapshot(transaction, p), remote: remote)
        #expect(conflict.conflicts.count == 1)
        let accepted = WatchlistSyncMerge.resolve(conflict, choosing: .remote)
        #expect(accepted.items.first?.transactions.first?.price == 201)
        #expect(accepted.items.first?.transactions.first?.planExecution == execution)
        let deleted = snapshot(legacyTransaction, legacyPlan)
        var deleting = deleted
        deleting.items[0].transactions = []
        let deletionConflict = WatchlistSyncMerge.merge(base: base, local: snapshot(transaction, p), remote: deleting)
        #expect(WatchlistSyncMerge.resolve(deletionConflict, choosing: .remote).items.first?.transactions.isEmpty == true)
    }

}
