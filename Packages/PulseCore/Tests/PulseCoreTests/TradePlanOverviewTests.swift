import Foundation
import Testing
@testable import PulseCore

@Suite("Trade plan overview")
struct TradePlanOverviewTests {
    private let symbolA = SymbolID(market: .us, code: "AAPL")
    private let symbolB = SymbolID(market: .us, code: "MSFT")
    private let symbolC = SymbolID(market: .us, code: "NVDA")

    private func plan(
        id: UUID = UUID(),
        kind: TradePlan.Kind = .buy,
        price: Double,
        quantity: Double = 100,
        status: TradePlan.Status = .active
    ) -> TradePlan {
        TradePlan(
            id: id,
            kind: kind,
            price: price,
            quantity: quantity,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func quoteTable(_ table: [SymbolID: Double]) -> (SymbolID) -> Double? {
        { table[$0] }
    }

    // MARK: - Collection

    @MainActor
    @Test("Plans come from group membership, in group order, without duplicates")
    func entriesWalkGroupsWithoutDuplicates() throws {
        let suite = "TradePlanOverview.entries.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")

        store.add(SymbolInfo(symbol: symbolA, name: "Apple"))
        store.setTradePlan(plan(price: 200), for: symbolA)
        store.setTradePlan(plan(price: 190), for: symbolA)

        let watch = try #require(store.createGroup(named: "Watch"))
        // A is tagged into both groups; B only into the second. A's plans must
        // not appear twice just because the symbol does.
        store.setMembership(symbolA, in: watch, included: true)
        store.add(SymbolInfo(symbol: symbolB, name: "Microsoft"), to: watch)
        store.setTradePlan(plan(price: 300), for: symbolB)

        let entries = store.tradePlanEntries
        #expect(entries.count == 3)
        // Group order first: Core's symbol, then the second group's.
        #expect(entries.map(\.symbol) == [symbolA, symbolA, symbolB])
        // Each symbol's own plans stay in `TradePlan.ordered` order, which for
        // two buys is the higher price first.
        #expect(entries.prefix(2).map(\.plan.price) == [200, 190])
    }

    // MARK: - Ordering (derived, never persisted)

    @Test("Reached plans sort ahead of waiting ones")
    func reachedSortsAhead() {
        let waiting = plan(price: 100)      // current 150 → not reached
        let reached = plan(price: 160)      // current 150 → buy reached
        let prices = quoteTable([symbolA: 150, symbolB: 150])

        let ordered = TradePlanOverview.ordered(
            [TradePlanEntry(symbol: symbolA, plan: waiting),
             TradePlanEntry(symbol: symbolB, plan: reached)],
            currentPrice: prices
        )
        #expect(ordered.map(\.plan.id) == [reached.id, waiting.id])
    }

    @Test("Waiting plans sort by how far the quote still has to move")
    func waitingSortsByGap() {
        let far = plan(price: 100)          // current 150 → 33.3% away
        let near = plan(price: 145)         // current 150 → 3.3% away
        let prices = quoteTable([symbolA: 150, symbolB: 150])

        let ordered = TradePlanOverview.ordered(
            [TradePlanEntry(symbol: symbolA, plan: far),
             TradePlanEntry(symbol: symbolB, plan: near)],
            currentPrice: prices
        )
        #expect(ordered.map(\.plan.id) == [near.id, far.id])
    }

    @Test("A missing quote is not treated as reached")
    func missingQuoteIsNotReached() {
        let noQuote = plan(price: 160)
        let waiting = plan(price: 100)
        let prices = quoteTable([symbolB: 150])

        let ordered = TradePlanOverview.ordered(
            [TradePlanEntry(symbol: symbolA, plan: noQuote),
             TradePlanEntry(symbol: symbolB, plan: waiting)],
            currentPrice: prices
        )
        // Unknown price sorts with the waiting band, behind a plan that is
        // measurably closer — never with the reached ones.
        #expect(ordered.map(\.plan.id) == [waiting.id, noQuote.id])
        #expect(!TradePlanOverview.isReached(
            TradePlanEntry(symbol: symbolA, plan: noQuote),
            currentPrice: prices
        ))
    }

    @Test("Settled plans sort behind every live one, whatever the price does")
    func settledSortsLast() {
        let done = plan(price: 160, status: .done)          // price alone would reach
        let cancelled = plan(price: 160, status: .cancelled)
        let live = plan(price: 100)
        let prices = quoteTable([symbolA: 150, symbolB: 150, symbolC: 150])

        let ordered = TradePlanOverview.ordered(
            [TradePlanEntry(symbol: symbolA, plan: done),
             TradePlanEntry(symbol: symbolB, plan: cancelled),
             TradePlanEntry(symbol: symbolC, plan: live)],
            currentPrice: prices
        )
        #expect(ordered.first?.plan.id == live.id)
        #expect(Set(ordered.suffix(2).map(\.plan.id)) == [done.id, cancelled.id])
    }

    @Test("Equal ranks keep input order, so refreshes do not reshuffle the list")
    func tiesKeepInputOrder() {
        let first = plan(price: 100)
        let second = plan(price: 100)
        let prices = quoteTable([symbolA: 150])

        let input = [TradePlanEntry(symbol: symbolA, plan: first),
                     TradePlanEntry(symbol: symbolA, plan: second)]
        let ordered = TradePlanOverview.ordered(input, currentPrice: prices)
        #expect(ordered.map(\.plan.id) == [first.id, second.id])
        // Repeated passes must not drift; the list is rebuilt on every tick.
        #expect(TradePlanOverview.ordered(ordered, currentPrice: prices).map(\.plan.id)
            == [first.id, second.id])
    }

    // MARK: - Summary (shared by the home chip and the page header)

    @Test("The summary counts live, reached, and settled separately")
    func summaryCounts() {
        let reached = plan(price: 160)
        let waiting = plan(price: 100)
        let done = plan(price: 100, status: .done)
        let prices = quoteTable([symbolA: 150, symbolB: 150, symbolC: 150])

        let summary = TradePlanOverview.summary(
            [TradePlanEntry(symbol: symbolA, plan: reached),
             TradePlanEntry(symbol: symbolB, plan: waiting),
             TradePlanEntry(symbol: symbolC, plan: done)],
            currentPrice: prices
        )
        #expect(summary.live == 2)
        #expect(summary.reached == 1)
        #expect(summary.settled == 1)
        #expect(summary.total == 3)
    }

    @Test("An empty watchlist summarises as zeroes rather than nil")
    func emptySummary() {
        let summary = TradePlanOverview.summary([], currentPrice: quoteTable([:]))
        #expect(summary == TradePlanOverview.Summary())
        #expect(summary.total == 0)
    }

    @Test("Reached count agrees with the rows the ordering puts in the reached band")
    func summaryAgreesWithOrder() {
        let entries = [
            TradePlanEntry(symbol: symbolA, plan: plan(price: 160)),
            TradePlanEntry(symbol: symbolB, plan: plan(price: 145)),
            TradePlanEntry(symbol: symbolC, plan: plan(price: 100)),
        ]
        let prices = quoteTable([symbolA: 150, symbolB: 150, symbolC: 150])
        let summary = TradePlanOverview.summary(entries, currentPrice: prices)
        let ordered = TradePlanOverview.ordered(entries, currentPrice: prices)

        let leadingReached = ordered.prefix { TradePlanOverview.isReached($0, currentPrice: prices) }
        #expect(leadingReached.count == summary.reached)
        // The chip on the home page and the page it opens read the same
        // numbers, because both call this one function.
        #expect(summary.live == 3)
    }
}
