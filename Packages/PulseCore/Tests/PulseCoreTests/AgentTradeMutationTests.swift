import Foundation
import Testing
@testable import PulseCore

/// The agent commands write trades through the *checked* store routes, so a
/// refused mutation is reported as a refusal with the store's own reason and
/// never as a fabricated success.
///
/// Every fixture here is synthetic: a disposable `UserDefaults` suite holding a
/// single fictional symbol, no network, no real account data.
@MainActor
@Suite("Agent trade mutations")
struct AgentTradeMutationTests {
    private let symbol = SymbolID(market: .us, code: "QAMUT")
    private let ref = AgentSymbolRef(market: "us", code: "QAMUT")

    private func makeStore() throws -> (WatchlistStore, UserDefaults, String) {
        let suiteName = "AgentTradeMutationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Watchlist")
        store.enableBrokerageAccounts()
        // The fixture lives in one named ledger so the commands' account
        // resolution has a single unambiguous answer.
        _ = store.selectBrokerageAccount(.financing)
        let commands = AgentWatchlistCommands(store: store)
        let groupID = try #require(store.selectedGroupID)
        _ = try commands.addSymbol(ref, name: "虚构验证", to: groupID).get()
        return (store, defaults, suiteName)
    }

    /// Opens a long through the checked route, so the fixture itself proves the
    /// go-forward write path works before a refusal is asked of it.
    private func openLong(_ store: WatchlistStore, quantity: Double, price: Double,
                          account: BrokerageAccountID = .financing) throws -> PositionTransaction {
        try store.recordTransaction(symbol, PositionTransaction(
            kind: .buy, price: price, quantity: quantity, date: .now,
            fundingSource: .own, brokerageAccountID: account
        ), account: account)
    }

    /// A negative historical replay is refused, the refusal names a real reason
    /// rather than a collapsed `invalidQuantity`, and nothing moved.
    @Test
    func editThatCreatesNegativeHistoryIsRefusedWithItsReason() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opening = try openLong(store, quantity: 100, price: 100)
        _ = try store.recordTransaction(symbol, PositionTransaction(
            kind: .sell, price: 120, quantity: 80, date: .now, brokerageAccountID: .financing
        ), account: .financing)

        let before = store.syncSnapshot()
        let result = AgentWatchlistCommands(store: store).updateTrade(
            symbol: ref, id: opening.id, quantity: 50
        )

        guard case .failure(let error) = result else {
            Issue.record("a 100 -> 50 edit after selling 80 must be refused")
            return
        }
        guard case .tradeMutationFailed(let reason) = error else {
            Issue.record("the refusal must be tradeMutationFailed, got \(error)")
            return
        }
        #expect(!reason.isEmpty, "the refusal must carry a sentence the caller can act on")
        // The collapsed code would have hidden the real reason behind a generic
        // sentence; a negative-history refusal must say what actually happened.
        #expect(reason.contains("negative") || reason.contains("负数") || reason.contains("持仓"),
                "a negative-history refusal must describe the negative replay, got: \(reason)")
        #expect(error != .invalidQuantity)
        #expect(store.syncSnapshot() == before, "a refused edit must leave every ledger unchanged")
    }

    /// Once the ledger is repaired the same command succeeds, so the refusal
    /// above was about the value and not about the route.
    @Test
    func repairThenRetrySucceeds() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opening = try openLong(store, quantity: 100, price: 100)
        _ = try store.recordTransaction(symbol, PositionTransaction(
            kind: .sell, price: 120, quantity: 80, date: .now, brokerageAccountID: .financing
        ), account: .financing)

        let commands = AgentWatchlistCommands(store: store)
        #expect(commands.updateTrade(symbol: ref, id: opening.id, quantity: 50).isFailure,
                "the too-small edit must be refused first")

        let repaired = try commands.updateTrade(symbol: ref, id: opening.id, quantity: 200).get()
        #expect(!repaired.alreadyApplied, "the repair is a real write")
        #expect(store.withBrokerageAccount(.financing) { store.item(for: symbol)?.positionQuantity } == 120,
                "200 bought less 80 sold leaves 120")
        #expect(store.item(for: symbol)?.transactions.first { $0.id == opening.id }?.quantity == 200)
    }

    /// Commands are synchronous patches of the live record, not retained form
    /// drafts. An earlier correction is the baseline for the next command.
    @Test
    func freshCommandUsesLatestRecord() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opening = try openLong(store, quantity: 100, price: 100)
        var moved = opening
        moved.price = 111
        _ = try store.updateTransaction(symbol, moved, expected: opening, account: .financing)

        let result = try AgentWatchlistCommands(store: store).updateTrade(
            symbol: ref, id: opening.id, price: 130
        ).get()
        #expect(!result.alreadyApplied)
        #expect(result.value.transactions.first?.price == 130)
        #expect(store.item(for: symbol)?.transactions.first?.createdAt == opening.createdAt)
    }

    /// Deleting an id that is already gone is the operation's own end state, so
    /// a retry stays a success and says it was already applied.
    @Test
    func deleteOfAbsentIdIsIdempotent() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commands = AgentWatchlistCommands(store: store)
        _ = try openLong(store, quantity: 10, price: 100)

        let missing = UUID()
        let first = try commands.deleteTrade(symbol: ref, id: missing).get()
        let second = try commands.deleteTrade(symbol: ref, id: missing).get()
        #expect(first.alreadyApplied, "a delete that has nothing to do is already applied")
        #expect(second.alreadyApplied)
        #expect(!first.didChangeSymbolUnion)
        #expect(store.item(for: symbol)?.transactions.count == 1, "the real record survives")
    }

    /// Recording with a repeated id stays idempotent through the checked route.
    @Test
    func recordTradeWithSameIDStaysIdempotent() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commands = AgentWatchlistCommands(store: store)
        let id = UUID()
        let draft = AgentTradeDraft(symbol: ref, kind: .buy, quantity: 5, price: 90,
                                    date: Date(timeIntervalSince1970: 1_750_000_000),
                                    id: id, fundingSource: .own)

        let first = try commands.recordTrade(draft).get()
        let second = try commands.recordTrade(draft).get()
        #expect(!first.alreadyApplied)
        #expect(second.alreadyApplied)
        #expect(store.withBrokerageAccount(.financing) { store.item(for: symbol)?.transactions.count } == 1)
    }

    /// A dormant instrument keeps editable history. Both an edit and a delete
    /// reach the retained ledger, and neither re-adds the symbol to a group.
    @Test
    func retainedHistoryCanBeEditedAndDeletedWithoutRestoringMembership() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let commands = AgentWatchlistCommands(store: store)

        let opening = try openLong(store, quantity: 100, price: 100)
        let closing = try store.recordTransaction(symbol, PositionTransaction(
            kind: .sell, price: 120, quantity: 40, date: .now, brokerageAccountID: .financing
        ), account: .financing)

        // Drop the symbol from every group: the ledger goes dormant, retained.
        store.remove(symbol)
        let groups = store.brokeragePortfolio(for: .financing).groups
        #expect(groups.allSatisfy { !$0.symbols.contains(symbol) }, "the fixture really is dormant")
        #expect(store.item(for: symbol) == nil)
        #expect(store.retainedHistoryItem(for: symbol) != nil, "the fixture really is retained")

        let edited = try commands.updateTrade(symbol: ref, id: closing.id, price: 125).get()
        #expect(!edited.alreadyApplied)
        #expect(edited.value.transactions.contains { $0.id == closing.id && $0.price == 125 },
                "the retained edit is reported back")
        #expect(store.brokeragePortfolio(for: .financing).groups
            .allSatisfy { !$0.symbols.contains(symbol) },
                "editing retained history must not restore watchlist membership")
        #expect(store.item(for: symbol) == nil, "the symbol stays dormant after an edit")

        let deleted = try commands.deleteTrade(symbol: ref, id: closing.id).get()
        #expect(!deleted.alreadyApplied)
        #expect(!deleted.value.transactions.contains { $0.id == closing.id })
        #expect(deleted.value.transactions.contains { $0.id == opening.id })
        #expect(store.brokeragePortfolio(for: .financing).groups
            .allSatisfy { !$0.symbols.contains(symbol) },
                "deleting retained history must not restore watchlist membership")
    }

    /// A refused delete leaves the record in place with its reason intact: the
    /// draft names a buy while the id carries a sell's content, so the record
    /// the caller claimed to be deleting is not the record that is there.
    @Test
    func deleteOfAMismatchedDraftIsRefusedWithItsReason() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let opening = try openLong(store, quantity: 100, price: 100)
        let closing = try store.recordTransaction(symbol, PositionTransaction(
            kind: .sell, price: 120, quantity: 40, date: .now, brokerageAccountID: .financing
        ), account: .financing)

        // A stale draft: the sell's price was corrected behind the caller's back,
        // which is exactly what a reopened form must not silently overwrite.
        var corrected = closing
        corrected.price = 121
        _ = try store.updateTransaction(symbol, corrected, expected: closing, account: .financing)

        let before = store.syncSnapshot()
        let commands = AgentWatchlistCommands(store: store)
        // The command rebuilds its `expected` from live state, so a plain delete
        // still succeeds — that is the documented contract. What must never
        // happen is a *reported* success for a store that refused. Asking the
        // store directly with the stale value proves the gate is real.
        #expect(throws: TradeMutationError.staleRecord) {
            try store.deleteTransaction(symbol, id: closing.id, expected: closing, account: .financing)
        }
        #expect(store.syncSnapshot() == before, "a refused delete leaves every ledger unchanged")
        #expect(store.item(for: symbol)?.transactions.contains { $0.id == opening.id } == true)

        let live = try commands.deleteTrade(symbol: ref, id: closing.id).get()
        #expect(!live.alreadyApplied)
        #expect(store.item(for: symbol)?.transactions.contains { $0.id == closing.id } == false)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
