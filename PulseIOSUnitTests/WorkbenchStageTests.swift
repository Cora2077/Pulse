import XCTest
import PulseCore
@testable import FFFiPhone

final class WorkbenchStageTests: XCTestCase {
    private func date(_ day: Int, _ hour: Int = 16, zone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @MainActor
    private func board(_ items: [WatchItem], history: [WatchItem]? = nil, entries: [TradePlanEntry] = [],
                       now: Date, phase: WorkbenchPhase = .intraday) -> WorkbenchBoard {
        WorkbenchBoard(now: now, phase: phase, items: items, historyItems: history ?? items,
            entries: entries, events: [], quote: { _ in nil }, name: { $0.displayCode },
            cash: WorkbenchCashInput(), sectorLimits: [:])
    }

    @MainActor
    private func stage(_ phase: WorkbenchPhase, items: [WatchItem], history: [WatchItem]? = nil,
                       entries: [TradePlanEntry] = [], now: Date) -> WorkbenchStagePresentation {
        WorkbenchStagePresentation(board: board(items, history: history, entries: entries, now: now, phase: phase),
            phase: phase, items: items, historyItems: history ?? items, entries: entries, now: now, name: { $0.displayCode })
    }

    @MainActor
    func testAShareAssetsDoNotAcquireForeignScopesFromMacroReferences() {
        let asset = WatchItem(symbol: SymbolID(market: .sh, code: "600000"), displayName: "Synthetic holding",
            transactions: [PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(15))])
        let items = [asset,
            WatchItem(symbol: SymbolID(index: .hangSeng), displayName: "Reference only"),
            WatchItem(symbol: SymbolID(index: .sp500), displayName: "Reference only"),
            WatchItem(symbol: SymbolID(market: .metal, code: "XAUUSD"), displayName: "Reference only", instrumentType: .commodity)]
        let before = items
        let context = WorkbenchMarketContext(items: items)
        XCTAssertEqual(context.scopes, [.chinaA])
        XCTAssertEqual(context.label, "A 股资产")
        XCTAssertEqual(context.clockMarkets(for: .all), [.sh])
        XCTAssertEqual(context.resolvedScope(.unitedStates), .chinaA)
        XCTAssertFalse(context.clockMarkets(for: .unitedStates).contains(.us))
        XCTAssertEqual(items, before)
    }

    @MainActor
    func testActuallyOwnedMarketsAppearWithoutUsingCurrencyAsMarket() {
        let a = WatchItem(symbol: SymbolID(market: .sh, code: "600000"), displayName: "Synthetic A",
            transactions: [PositionTransaction(kind: .buy, price: 10, quantity: 100)])
        let us = WatchItem(symbol: SymbolID(market: .us, code: "AAPL"), displayName: "Synthetic US",
            transactions: [PositionTransaction(kind: .buy, price: 10, quantity: 1)])
        let context = WorkbenchMarketContext(items: [a, us])
        XCTAssertEqual(context.scopes, [.all, .chinaA, .unitedStates])
        XCTAssertEqual(context.clockMarkets(for: .chinaA), [.sh])
        XCTAssertEqual(context.clockMarkets(for: .unitedStates), [.us])
        XCTAssertFalse(WorkbenchMarketContext(items: [a]).scopes.contains(.hongKong))
        XCTAssertEqual(WorkbenchMarketContext(items: []).scopes, [.chinaA])
    }

    @MainActor
    func testQuietPlansAppearInPreparationButNotInIntradayOrReview() {
        let now = date(16)
        let symbol = SymbolID(market: .sh, code: "600000")
        let quiet = TradePlan(kind: .buy, price: 9, quantity: 100)
        let cancelled = TradePlan(kind: .buy, price: 8, quantity: 100, status: .cancelled)
        let item = WatchItem(symbol: symbol, displayName: "Synthetic plan", plans: [quiet, cancelled])
        let entries = item.plans.map { TradePlanEntry(symbol: symbol, plan: $0) }
        XCTAssertTrue(board([item], entries: entries, now: now).tasks.isEmpty)
        let pre = stage(.preMarket, items: [item], entries: entries, now: now)
        XCTAssertEqual(pre.activePlanCount, 1)
        XCTAssertEqual(pre.tasks.first?.plans.map(\.id), [quiet.id])
        XCTAssertFalse(pre.allowsPlanFillAction)
        XCTAssertTrue(pre.showsCashTasks)
        XCTAssertTrue(pre.tasks.allSatisfy { $0.reviewTransactionIDs.isEmpty && $0.checkpointID == nil && !$0.reached })
        XCTAssertTrue(stage(.intraday, items: [item], entries: entries, now: now).tasks.isEmpty)
        XCTAssertTrue(stage(.postMarket, items: [item], entries: entries, now: now).tasks.isEmpty)
        XCTAssertEqual(item.plans, [quiet, cancelled])
    }

    @MainActor
    func testIntradayKeepsConditionButStripsReviewFromMixedTask() {
        let now = date(16)
        let symbol = SymbolID(market: .sz, code: "000001")
        let trade = PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(16, 10))
        let plan = TradePlan(kind: .buy, price: 9, quantity: 100,
            conditions: [TradePlanCondition(title: "Synthetic manual condition", kind: .manual)])
        let item = WatchItem(symbol: symbol, displayName: "Synthetic mixed", transactions: [trade], plans: [plan])
        let entries = [TradePlanEntry(symbol: symbol, plan: plan)]
        let factual = board([item], entries: entries, now: now)
        XCTAssertEqual(factual.tasks.first?.reviewTransactionIDs, [trade.id])
        let intra = stage(.intraday, items: [item], entries: entries, now: now)
        XCTAssertEqual(intra.tasks.count, 1)
        XCTAssertGreaterThan(intra.tasks[0].conditionCount, 0)
        XCTAssertTrue(intra.tasks[0].reviewTransactionIDs.isEmpty)
        XCTAssertNil(intra.tasks[0].checkpointID)
        XCTAssertFalse(intra.tasks[0].reached, "Missing quote is never a reached trigger")
        XCTAssertTrue(intra.allowsPlanFillAction)
        XCTAssertEqual(intra.metrics.first { $0.id == "reached" }?.value, 0)
    }

    @MainActor
    func testReviewCountsActualTodayFillsAndKeepsHistoricalBacklogSeparate() {
        let now = date(16)
        let symbol = SymbolID(market: .sh, code: "600000")
        let today = PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(16, 10))
        let reviewed = PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(16, 11),
            review: .init(retrospective: "Synthetic completed review"))
        let historical = PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(15))
        let adjustment = PositionTransaction(kind: .adjustment, price: 10, quantity: 300, date: date(16, 12))
        let future = PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(17))
        let item = WatchItem(symbol: symbol, displayName: "Synthetic history",
            transactions: [today, reviewed, historical, adjustment, future])
        let factual = board([item], now: now)
        let post = stage(.postMarket, items: [item], now: now)
        XCTAssertEqual(post.todayFillCount, 2)
        XCTAssertEqual(post.metrics.first { $0.id == "reviews" }?.value, 1)
        XCTAssertEqual(factual.historyBacklog?.count, 1)
        XCTAssertEqual(post.tasks.first?.reviewTransactionIDs, [today.id])
        XCTAssertTrue(post.tasks.allSatisfy { $0.plans.isEmpty && !$0.reached })
        XCTAssertTrue(stage(.intraday, items: [item], now: now).tasks.isEmpty)
    }

    @MainActor
    func testDueCheckpointOnRetainedHistoryRemainsReachableAfterMarketClose() {
        let now = date(16)
        let transaction = PositionTransaction(kind: .buy, price: 10, quantity: 1, date: date(10),
            review: .init(retrospective: "Synthetic reviewed trade", nextReviewDate: date(15)))
        let history = WatchItem(symbol: SymbolID(market: .sz, code: "000002"), displayName: "Synthetic removed item",
            transactions: [transaction])
        let post = stage(.postMarket, items: [], history: [history], now: now)
        XCTAssertEqual(post.checkpointCount, 1)
        XCTAssertEqual(post.tasks.first?.checkpointID, transaction.id)
        XCTAssertEqual(post.todayFillCount, 0)
        XCTAssertTrue(stage(.preMarket, items: [], history: [history], now: now).tasks.isEmpty)
    }

    @MainActor
    func testStageSelectionChangesMetricsAndTasksWithoutChangingFacts() {
        let now = date(16)
        let plan = TradePlan(kind: .buy, price: 9, quantity: 100)
        let preparation = WatchItem(symbol: SymbolID(market: .sh, code: "600000"), displayName: "Synthetic preparation", plans: [plan])
        let review = WatchItem(symbol: SymbolID(market: .sz, code: "000001"), displayName: "Synthetic review",
            transactions: [PositionTransaction(kind: .buy, price: 10, quantity: 100, date: date(16, 10))])
        let items = [preparation, review]
        let before = items
        let entries = [TradePlanEntry(symbol: preparation.symbol, plan: plan)]
        let stages = WorkbenchPhase.allCases.map { stage($0, items: items, entries: entries, now: now) }
        XCTAssertEqual(Set(stages.map(\.title)).count, 3)
        XCTAssertEqual(Set(stages.map { $0.metrics.map(\.id).joined(separator: ",") }).count, 3)
        XCTAssertEqual(stages[0].tasks.map(\.symbol), [preparation.symbol])
        XCTAssertTrue(stages[1].tasks.isEmpty)
        XCTAssertEqual(stages[2].tasks.map(\.symbol), [review.symbol])
        XCTAssertEqual(items, before)
        XCTAssertTrue(stages.allSatisfy { $0.activePlanCount == 1 && $0.todayFillCount == 1 })
    }

    @MainActor
    func testInitialStageUsesAShareClockLunchAndWeekend() {
        let zone = Market.sh.timeZone
        XCTAssertEqual(WorkbenchStagePresentation.suggestedPhase(markets: [.sh, .sz], at: date(16, 8, zone: zone)), .preMarket)
        XCTAssertEqual(WorkbenchStagePresentation.suggestedPhase(markets: [.sh, .sz], at: date(16, 12, zone: zone)), .intraday)
        XCTAssertEqual(WorkbenchStagePresentation.suggestedPhase(markets: [.sh, .sz], at: date(16, 16, zone: zone)), .postMarket)
        XCTAssertEqual(WorkbenchStagePresentation.suggestedPhase(markets: [.sh, .sz], at: date(17, 12, zone: zone)), .postMarket)
    }
}
