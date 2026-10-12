import Foundation
import Testing
@testable import PulseCore

/// A plan's optional default execution account.
///
/// The subject is a *default*, not a constraint: `executionAccountID` says which
/// ledger the user means to act in when they have decided in advance, and `nil`
/// says they have not decided yet — the ordinary case, and the only thing old
/// data can mean. Nothing here creates a transaction, and a recorded fill keeps
/// saying what was intended when it was recorded even after the plan's default
/// moves.
///
/// Every test is synthetic: hand-built plans and JSON, plus the version gates
/// the archive and sync wire already use. No store is written and no user
/// default domain outside a throwaway suite is touched.
@Suite("Plan execution account")
struct PlanExecutionAccountTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    private func plan(
        kind: TradePlan.Kind = .buy,
        account: BrokerageAccountID? = nil,
        history: [TradePlanRevision]? = nil
    ) -> TradePlan {
        TradePlan(
            kind: kind, price: 12, quantity: 10, createdAt: day, updatedAt: day,
            history: history, executionAccountID: account
        )
    }

    private func configuration(_ plan: TradePlan) -> TradePlanConfiguration {
        TradePlanConfiguration(plan: plan)
    }

    private func entry(_ plans: [TradePlan], transactions: [PositionTransaction] = []) -> WatchlistArchive.Entry {
        .init(
            market: .us, code: "EXEC",
            transactions: transactions.isEmpty ? nil : transactions,
            plans: plans
        )
    }

    // MARK: - Codable compatibility

    @Test("Legacy JSON without the field decodes to no account on every carrier")
    func legacyDecodesNil() throws {
        let planID = UUID()
        let revisionID = UUID()
        let legacy = """
        {"id":"\(planID.uuidString)","kind":"buy","price":12,"quantity":10,"status":"active",\
        "createdAt":0,"updatedAt":0,"positionPool":"tactical","history":[\
        {"id":"\(revisionID.uuidString)","date":0,"configuration":{\
        "kind":"buy","price":12,"quantity":10,"status":"active","createdAt":0}}]}
        """
        let decoded = try JSONDecoder().decode(TradePlan.self, from: Data(legacy.utf8))
        #expect(decoded.executionAccountID == nil)
        #expect(!decoded.hasExecutionAccountMetadata)
        let revision = try #require(decoded.history?.first)
        #expect(revision.configuration.executionAccountID == nil)
        #expect(!revision.configuration.hasExecutionAccountMetadata)
        // A configuration decoded on its own, as a fill snapshot is, is just as
        // untouched.
        let legacyConfiguration = """
        {"kind":"buy","price":12,"quantity":10,"status":"active","createdAt":0,"positionPool":"tactical"}
        """
        let configuration = try JSONDecoder().decode(
            TradePlanConfiguration.self, from: Data(legacyConfiguration.utf8)
        )
        #expect(configuration.executionAccountID == nil)
        // Nothing was inferred from the surrounding data: a legacy plan beside
        // another that names a ledger stays unnamed.
        #expect(plan(account: .financing).executionAccountID == .financing)
    }

    @Test("The account survives a plan, revision, and fill-snapshot round trip")
    func roundTripsEveryCarrier() throws {
        for account in BrokerageAccountID.allCases where account != .unassigned {
            let revision = TradePlanRevision(
                id: UUID(), date: day,
                configuration: configuration(plan(account: account))
            )
            let source = plan(account: account, history: [revision])
            let encoded = try JSONEncoder().encode(source)
            let decoded = try JSONDecoder().decode(TradePlan.self, from: encoded)
            #expect(decoded.executionAccountID == account)
            #expect(decoded.history?.first?.configuration.executionAccountID == account)

            let execution = TradePlanExecution(
                planID: source.id, configuration: configuration(source), sourceAccountID: account
            )
            let executionRoundTrip = try JSONDecoder().decode(
                TradePlanExecution.self, from: JSONEncoder().encode(execution)
            )
            #expect(executionRoundTrip.configuration.executionAccountID == account)
        }

        // The revision copy is taken from the plan at capture time, and the
        // default is what it copies.
        #expect(configuration(plan()).executionAccountID == nil)
        #expect(configuration(plan(account: .mengmeng)).executionAccountID == .mengmeng)
    }

    // MARK: - Validity

    @Test("A named account is valid on a plan and on the configurations a revision or fill captured")
    func namedAccountsAreValid() {
        #expect(plan(account: .financing).hasValidPayload)
        #expect(plan(account: .mengmeng).hasValidPayload)
        #expect(plan().hasValidPayload)
        #expect(TradePlanConfiguration.isValidExecutionAccount(nil))
        #expect(TradePlanConfiguration.isValidExecutionAccount(.financing))
        #expect(TradePlanConfiguration.isValidExecutionAccount(.mengmeng))

        let named = plan(account: .financing)
        #expect(configuration(named).executionAccountID == .financing)
        #expect(TradePlanExecution(planID: named.id, configuration: configuration(named)).hasExecutionAccountMetadata)
    }

    @Test("The legacy unassigned label is refused on the plan and in its history")
    func unassignedIsRefused() {
        #expect(!TradePlanConfiguration.isValidExecutionAccount(.unassigned))
        #expect(!plan(account: .unassigned).hasValidPayload)

        // A plan whose live field is clean but whose revision captured the
        // legacy label is refused too: history is not a way to smuggle one in.
        let tainted = TradePlanRevision(
            id: UUID(), date: day, configuration: configuration(plan(account: .unassigned))
        )
        let carrier = plan(account: .financing, history: [tainted])
        #expect(carrier.executionAccountID == .financing)
        #expect(carrier.hasExecutionAccountMetadata)
        #expect(!carrier.hasValidPayload)

        // Sibling fields stay valid, so a refusal is about this rule alone.
        let sound = plan(account: .financing, history: [
            TradePlanRevision(id: UUID(), date: day, configuration: configuration(plan(account: .mengmeng)))
        ])
        #expect(sound.hasValidPayload)
    }

    // MARK: - Version gates

    @Test("An account on the plan, in a revision, or on a fill raises the declared version")
    func threePathsRaiseTheVersion() throws {
        // 1. The plan itself.
        let live = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([plan(account: .financing)])])])
        #expect(live.version == 16)
        #expect(WatchlistSyncWireCodec.currentVersion == 18)

        // 2. An edit that clears the live default appends the configuration that
        //    had it as a revision; the plan alone would show nothing.
        let revision = TradePlanRevision(
            id: UUID(), date: day, configuration: configuration(plan(account: .financing))
        )
        let cleared = plan(account: nil, history: [revision])
        #expect(cleared.executionAccountID == nil)
        #expect(cleared.hasExecutionAccountMetadata)
        #expect(TradePlanConfiguration.hasExecutionAccountMetadata(in: (cleared.history ?? []).map(\.configuration)))
        let historical = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([cleared])])])
        #expect(historical.version == 16)

        // 3. A fill's immutable snapshot, with no plan present at all.
        let execution = TradePlanExecution(
            planID: UUID(), configuration: configuration(plan(account: .mengmeng)), sourceAccountID: .mengmeng
        )
        let fill = PositionTransaction(
            kind: .buy, price: 12, quantity: 10, date: day, planExecution: execution
        )
        #expect(execution.hasExecutionAccountMetadata)
        let fillOnly = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([], transactions: [fill])])])
        #expect(fillOnly.version == 16)
    }

    @Test("A payload claiming an older version while carrying an account is refused on all three paths")
    func forgedOlderVersionIsRefused() throws {
        let live = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([plan(account: .financing)])])])
        let liveText = try live.encoded()
        #expect(try WatchlistArchive.decoded(from: liveText).version == 16)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(16)) {
            try WatchlistArchive.decoded(from: try Self.reframed(liveText, version: 15))
        }

        let revision = TradePlanRevision(
            id: UUID(), date: day, configuration: configuration(plan(account: .financing))
        )
        let cleared = WatchlistArchive(lists: [
            .init(name: "Core", entries: [entry([plan(account: nil, history: [revision])])])
        ])
        let clearedText = try cleared.encoded()
        #expect(try WatchlistArchive.decoded(from: clearedText).version == 16)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(16)) {
            try WatchlistArchive.decoded(from: try Self.reframed(clearedText, version: 15))
        }

        let execution = TradePlanExecution(
            planID: UUID(), configuration: configuration(plan(account: .mengmeng)), sourceAccountID: .mengmeng
        )
        let fillOnly = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([], transactions: [
            PositionTransaction(kind: .buy, price: 12, quantity: 10, date: day, planExecution: execution)
        ])])])
        let fillText = try fillOnly.encoded()
        #expect(try WatchlistArchive.decoded(from: fillText).version == 16)
        #expect(throws: WatchlistArchive.DecodingFailure.unsupportedVersion(16)) {
            try WatchlistArchive.decoded(from: try Self.reframed(fillText, version: 15))
        }

        // The same three carriers through the sync wire.
        for snapshot in [Self.snapshot([plan(account: .financing)]),
                         Self.snapshot([plan(account: nil, history: [revision])]),
                         Self.snapshot([], transactions: [
                            PositionTransaction(kind: .buy, price: 12, quantity: 10, date: day, planExecution: execution)
                         ])] {
            let wire = try WatchlistSyncWireCodec.encode(deviceID: "exec-account", snapshot: snapshot)
            #expect(try WatchlistSyncWireCodec.decode(wire).version == 18)
            let envelope = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
            var forged = envelope
            forged["version"] = 17
            #expect(throws: WatchlistSyncWireCodec.CodecError.unsupportedVersion(18)) {
                try WatchlistSyncWireCodec.decode(try JSONSerialization.data(withJSONObject: forged))
            }
        }
    }

    @Test("Data without the field keeps the version it already had")
    func olderDataKeepsItsVersion() throws {
        // Unrelated data keeps the oldest version that describes it.
        let plain = WatchlistArchive(lists: [.init(name: "Core", entries: [.init(market: .us, code: "NVDA")])])
        #expect(plain.version == 2)

        // A plan with a pool still declares 6, not the new 16.
        #expect(plan().positionPool == nil)
        let withPool = TradePlan(kind: .buy, price: 12, quantity: 10, positionPool: .tactical)
        #expect(WatchlistArchive(lists: [.init(name: "Core", entries: [entry([withPool])])]).version == 6)

        // A plan naming a card still declares the binding version, unchanged.
        let bound = TradePlan(
            kind: .sell, price: 12, quantity: 10, positionPool: .tactical, positionPortionID: UUID()
        )
        let boundArchive = WatchlistArchive(lists: [.init(name: "Core", entries: [entry([bound])])])
        #expect(boundArchive.version == 15)

        // The wire side answers the same way.
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "plain", snapshot: Self.snapshot([]))
        ).version == 3)
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "pool", snapshot: Self.snapshot([withPool]))
        ).version == 7)
        #expect(try WatchlistSyncWireCodec.decode(
            WatchlistSyncWireCodec.encode(deviceID: "bound", snapshot: Self.snapshot([bound]))
        ).version == 17)
    }

    // MARK: - Intent is frozen

    @Test("Changing the plan's default never rewrites what a recorded fill intended")
    func recordedFillKeepsItsIntent() throws {
        let plan = plan(account: .financing)
        let execution = TradePlanExecution(
            planID: plan.id, configuration: configuration(plan), sourceAccountID: .unassigned
        )
        let fill = PositionTransaction(
            kind: .buy, price: 12, quantity: 10, date: day,
            planExecution: execution, brokerageAccountID: .mengmeng
        )

        // The plan's default moves, and is later cleared.
        var edited = plan
        edited.executionAccountID = .mengmeng
        edited.updatedAt = day.addingTimeInterval(60)
        edited.executionAccountID = nil

        // The fill still says what was intended, and where the money actually
        // went, exactly as first recorded.
        #expect(fill.planExecution?.configuration.executionAccountID == .financing)
        #expect(fill.brokerageAccountID == .mengmeng)
        #expect(fill.planExecution?.sourceAccountID == .unassigned)
        let roundTripped = try JSONDecoder().decode(
            PositionTransaction.self, from: JSONEncoder().encode(fill)
        )
        #expect(roundTripped.planExecution?.configuration.executionAccountID == .financing)
        #expect(roundTripped.brokerageAccountID == .mengmeng)
    }

    // MARK: - Helpers

    /// Re-declares an encoded archive at an older version, as a peer that lost
    /// the field would.
    private static func reframed(_ text: String, version: Int) throws -> String {
        var object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        object["version"] = version
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func snapshot(
        _ plans: [TradePlan],
        transactions: [PositionTransaction] = []
    ) -> WatchlistSyncSnapshot {
        WatchlistSyncSnapshot(
            items: [
                WatchItem(
                    symbol: SymbolID(market: .us, code: "EXEC"),
                    displayName: "Synthetic",
                    transactions: transactions,
                    plans: plans
                )
            ],
            groups: []
        )
    }
}
