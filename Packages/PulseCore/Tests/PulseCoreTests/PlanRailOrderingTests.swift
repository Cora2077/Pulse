import Foundation
import Testing
@testable import PulseCore

/// The main window's plan rail is a view, but the two rules it applies — what
/// belongs in it and in which order — are pure. They are asserted here rather
/// than through a rendered window, which is what makes the ordering's tiebreaks
/// checkable at all.
struct PlanRailOrderingTests {
    private let symbol = SymbolID(market: .us, code: "AAPL")
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func plan(
        id: UUID = UUID(),
        kind: TradePlan.Kind = .buy,
        price: Double,
        status: TradePlan.Status = .active,
        updatedAt: Date
    ) -> TradePlan {
        TradePlan(
            id: id,
            kind: kind,
            price: price,
            quantity: 100,
            status: status,
            createdAt: base,
            updatedAt: updatedAt
        )
    }

    private func entry(_ plan: TradePlan) -> TradePlanEntry {
        TradePlanEntry(symbol: symbol, plan: plan)
    }

    private func orderedIDs(_ entries: [TradePlanEntry], price: Double?, current: Bool = true) -> [UUID] {
        PlanRailOrdering.sortedWaiting(entries, currentPrice: price, quoteIsCurrent: current).map(\.plan.id)
    }

    // MARK: - Membership

    @Test("Only plans still waiting on a price condition reach the rail")
    func settledPlansStayOutOfTheRail() {
        let waiting = plan(price: 100, updatedAt: base)
        let stopped = plan(price: 110, status: .done, updatedAt: base.addingTimeInterval(60))
        let abandoned = plan(price: 120, status: .cancelled, updatedAt: base.addingTimeInterval(120))

        let result = PlanRailOrdering.sortedWaiting(
            [entry(stopped), entry(abandoned), entry(waiting)],
            currentPrice: 105,
            quoteIsCurrent: true
        )
        #expect(result.map(\.plan.id) == [waiting.id])
    }

    @Test("A plan closed by its own fills is a record, not a pending decision")
    func fullyFilledPlanLeavesTheRail() {
        let plan = plan(price: 100, updatedAt: base)
        let fill = PositionTransaction(
            kind: .buy,
            price: 99,
            quantity: 100,
            date: base,
            planExecution: TradePlanExecution(planID: plan.id, configuration: TradePlanConfiguration(plan: plan))
        )
        let filled = TradePlanEntry(symbol: symbol, plan: plan, transactions: [fill])

        #expect(filled.displayState == .filled)
        #expect(PlanRailOrdering.sortedWaiting([filled], currentPrice: 105, quoteIsCurrent: true).isEmpty)
    }

    // MARK: - Without a usable quote

    @Test("Without a quote the rail falls back to recency, newest first")
    func recencyOrderWithoutAQuote() {
        let oldest = plan(price: 100, updatedAt: base)
        let newest = plan(price: 140, updatedAt: base.addingTimeInterval(120))
        let middle = plan(price: 120, updatedAt: base.addingTimeInterval(60))

        let entries = [entry(oldest), entry(newest), entry(middle)]
        #expect(orderedIDs(entries, price: nil) == [newest.id, middle.id, oldest.id])
        // The fallback is the same answer whether the price is absent or simply
        // not trustworthy enough to sort by.
        #expect(orderedIDs(entries, price: 105, current: false) == [newest.id, middle.id, oldest.id])
        #expect(orderedIDs(entries, price: 0) == [newest.id, middle.id, oldest.id])
        #expect(orderedIDs(entries, price: .infinity) == [newest.id, middle.id, oldest.id])
    }

    @Test("A recency tie breaks by id so the order is stable across re-renders")
    func recencyTieBreaksByID() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = plan(id: high, price: 100, updatedAt: base)
        let second = plan(id: low, price: 130, updatedAt: base)

        let entries = [entry(first), entry(second)]
        #expect(orderedIDs(entries, price: nil) == [low, high])
        // Input order must not decide it: the same set reversed gives the same list.
        #expect(orderedIDs(entries.reversed(), price: nil) == [low, high])
    }

    // MARK: - With a usable quote

    @Test("A reached plan leads, then the rest by how far the quote has to move")
    func reachedFirstThenNearest() {
        let reached = plan(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
                           price: 110, updatedAt: base)
        let near = plan(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
                        price: 102, updatedAt: base)
        // A far *sell*: a buy above the quote is already reached, so only a sell
        // can sit far away and still be waiting.
        let far = plan(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
                       kind: .sell, price: 140, updatedAt: base)

        // A buy at 110 is reached once the quote is at or below it, and 105 is,
        // so it leads; the two waiting plans then follow nearest-first.
        #expect(orderedIDs([entry(far), entry(near), entry(reached)], price: 105)
                == [reached.id, near.id, far.id])
    }

    @Test("Distance is absolute, so a far sell and a far buy compare on distance alone")
    func distanceIgnoresWhichSideThePlanSitsOn() {
        let buyBelow = plan(kind: .buy, price: 95, updatedAt: base)   // 10 away
        let sellAbove = plan(kind: .sell, price: 120, updatedAt: base) // 15 away
        let sellReached = plan(kind: .sell, price: 100, updatedAt: base)

        #expect(orderedIDs([entry(sellAbove), entry(buyBelow), entry(sellReached)], price: 105)
                == [sellReached.id, buyBelow.id, sellAbove.id])
    }

    @Test("Equal distance defers to recency and then to id")
    func distanceTieBreaksByRecencyThenID() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        // Both three away from 105, so only recency can separate them.
        let older = plan(id: low, price: 102, updatedAt: base)
        let newer = plan(id: high, price: 108, updatedAt: base.addingTimeInterval(60))
        #expect(orderedIDs([entry(older), entry(newer)], price: 105) == [newer.id, older.id])

        // Same distance *and* same timestamp: id decides, deterministically.
        let first = plan(id: high, price: 102, updatedAt: base)
        let second = plan(id: low, price: 108, updatedAt: base)
        #expect(orderedIDs([entry(first), entry(second)], price: 105) == [low, high])
    }

    // MARK: - Rail visibility

    @Test("The rail needs a wide window, a tab that is not the plans list, and something to show")
    func railVisibilityBoundaries() {
        #expect(PlanRailOrdering.showsRail(width: 1120, plansTabActive: false, hasWaitingPlans: true))
        #expect(!PlanRailOrdering.showsRail(width: 1119.9, plansTabActive: false, hasWaitingPlans: true))

        #expect(!PlanRailOrdering.showsRail(width: 1400, plansTabActive: true, hasWaitingPlans: true))
        #expect(!PlanRailOrdering.showsRail(width: 1400, plansTabActive: false, hasWaitingPlans: false))

        #expect(!PlanRailOrdering.showsRail(width: 900, plansTabActive: true, hasWaitingPlans: false))
    }
}
