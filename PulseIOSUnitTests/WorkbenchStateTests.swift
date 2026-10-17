import XCTest
import PulseCore
@testable import FFFiPhone

final class WorkbenchStateTests: XCTestCase {
    @MainActor
    func testPartialFillIsARecordedFactNotAPriceTrigger() throws {
        let state = IPhoneAppState(demo: true)
        let entry = try XCTUnwrap(state.planEntries.first)
        XCTAssertTrue(TradePlanOverview.isReached(entry, currentPrice: { state.freshPrice($0) }))
        XCTAssertEqual(entry.filledQuantity, 0)
        let beforeHolding = try XCTUnwrap(state.watchlist.item(for: entry.symbol)).positionQuantity
        let trade = PositionTransaction(kind: .buy, price: 208000, quantity: 100, fundingSource: .own)
        _ = try state.recordTrade(trade, symbol: entry.symbol, account: state.accountID,
            plan: entry.plan, planSourceAccount: state.accountID)
        let updated = try XCTUnwrap(state.planEntries.first)
        XCTAssertEqual(updated.filledQuantity, 100)
        XCTAssertEqual(updated.remainingQuantity, 200)
        XCTAssertEqual(state.watchlist.item(for: entry.symbol)?.positionQuantity, beforeHolding + 100)
    }

    @MainActor
    func testReviewCanBeClearedAndStaleDraftCannotOverwriteIt() throws {
        let state = IPhoneAppState(demo: true)
        let item = try XCTUnwrap(state.historyItems.first)
        let original = try XCTUnwrap(item.transactions.first)
        let account = state.accountID
        try state.saveReview(PositionTransactionReview(followedPlan: true, retrospective: "复盘", strategy: "策略"),
            note: original.note, original: original, symbol: item.symbol, account: account)
        let reviewed = try XCTUnwrap(state.watchlist.item(for: item.symbol)?.transactions.first)
        XCTAssertEqual(reviewed.review?.strategy, "策略")
        let saved = state.watchlist.syncSnapshot()
        XCTAssertThrowsError(try state.saveReview(nil, note: nil, original: original, symbol: item.symbol, account: account))
        XCTAssertEqual(state.watchlist.syncSnapshot(), saved, "过期草稿拒绝时不得部分修改任何账户")
        try state.saveReview(nil, note: nil, original: reviewed, symbol: item.symbol, account: account)
        let cleared = try XCTUnwrap(state.watchlist.item(for: item.symbol)?.transactions.first)
        XCTAssertNil(cleared.review)
        XCTAssertNil(cleared.note)
        XCTAssertEqual(cleared.price, original.price)
        XCTAssertEqual(cleared.quantity, original.quantity)
    }

    @MainActor
    func testReviewEditorPreservesCheckpointAndAllExecutionFacts() throws {
        let state = IPhoneAppState(demo: true)
        let item = try XCTUnwrap(state.historyItems.first)
        let original = try XCTUnwrap(item.transactions.first)
        let account = state.accountID
        let checkpoint = PositionTransactionReview(nextReviewDate: Date(timeIntervalSince1970: 1_800_000_000),
            nextReviewNote: "Check the next earnings report")
        try state.saveReview(checkpoint, note: "Execution reason", original: original, symbol: item.symbol, account: account)
        let baseline = try XCTUnwrap(state.watchlist.item(for: item.symbol)?.transactions.first)
        let otherAccount = state.watchlist.brokeragePortfolio(for: .financing)
        let review = try ReviewEditorSheet.reviewForSaving(original: baseline.review,
            followedPlan: true, retrospective: "  Waited for confirmation.\n", strategy: "  Breakout  ")
        XCTAssertEqual(review?.retrospective, "Waited for confirmation.")
        XCTAssertEqual(review?.strategy, "Breakout")
        XCTAssertEqual(review?.nextReviewDate, checkpoint.nextReviewDate)
        XCTAssertEqual(review?.nextReviewNote, checkpoint.nextReviewNote)
        try state.saveReview(review, note: baseline.note, original: baseline, symbol: item.symbol, account: account)

        let updated = try XCTUnwrap(state.watchlist.item(for: item.symbol))
        var expected = baseline
        expected.review = review
        XCTAssertEqual(updated.transactions, [expected], "复盘不得改动价格、数量、日期、账户、成交身份或成交关联")
        XCTAssertEqual(updated.positionQuantity, item.positionQuantity)
        XCTAssertEqual(updated.plans, item.plans)
        XCTAssertEqual(state.watchlist.brokeragePortfolio(for: .financing), otherAccount)
    }

    @MainActor
    func testClearingVisibleReviewFieldsDoesNotEraseHiddenCheckpoint() throws {
        let checkpoint = PositionTransactionReview(followedPlan: true, retrospective: "Old review", strategy: "Old strategy",
            nextReviewDate: Date(timeIntervalSince1970: 1_800_000_000), nextReviewNote: "Follow up")
        let cleared = try ReviewEditorSheet.reviewForSaving(original: checkpoint,
            followedPlan: nil, retrospective: " \n", strategy: "\t ")
        XCTAssertEqual(cleared, PositionTransactionReview(nextReviewDate: checkpoint.nextReviewDate, nextReviewNote: "Follow up"))
        let trade = PositionTransaction(kind: .buy, price: 10, quantity: 1, review: cleared)
        XCTAssertTrue(WorkbenchBoard.needsReview(trade), "仅有将来检查点，不等于已经复盘")
        XCTAssertNil(try ReviewEditorSheet.reviewForSaving(original: nil,
            followedPlan: nil, retrospective: " \n", strategy: ""))
    }

    @MainActor
    func testHistoricalBacklogRequiresRetrospectiveAndExcludesAdjustments() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let date = now.addingTimeInterval(-3 * 86400)
        let symbol = SymbolID(market: .us, code: "REVIEW")
        let trades = [
            PositionTransaction(kind: .buy, price: 10, quantity: 1, date: date, note: "Note only"),
            PositionTransaction(kind: .buy, price: 10, quantity: 1, date: date,
                review: PositionTransactionReview(followedPlan: true, retrospective: " \n", strategy: "Strategy only")),
            PositionTransaction(kind: .buy, price: 10, quantity: 1, date: date,
                review: PositionTransactionReview(retrospective: "Reviewed")),
            PositionTransaction(kind: .adjustment, price: 10, quantity: 3, date: date)
        ]
        let board = WorkbenchBoard(now: now, phase: .intraday, items: [],
            historyItems: [WatchItem(symbol: symbol, displayName: "Synthetic", transactions: trades)],
            entries: [], events: [], quote: { _ in nil }, name: { $0.displayCode },
            cash: WorkbenchCashInput(), sectorLimits: [:])
        XCTAssertEqual(board.historyBacklog?.count, 2)
        XCTAssertEqual(board.todayReviewCount, 0)
    }

    @MainActor
    func testUSOvernightRecordingUsesExchangeCalendarDay() {
        let now = Date(timeIntervalSince1970: 1_792_084_800) // arbitrary fixed instant
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!
        var exchange = Calendar(identifier: .gregorian)
        exchange.timeZone = Market.us.timeZone
        var local = Calendar(identifier: .gregorian)
        local.timeZone = shanghai
        let represented = TradeEntryView.marketTradeDay(for: .us, now: now, localTimeZone: shanghai)
        let expected = exchange.dateComponents([.year, .month, .day], from: now)
        let actual = local.dateComponents([.year, .month, .day], from: represented)
        XCTAssertEqual(actual, expected)
    }

    @MainActor
    func testPlanDraftCannotFollowAnAccountSwitch() throws {
        let state = IPhoneAppState(demo: true)
        let entry = try XCTUnwrap(state.planEntries.first)
        let source = state.accountID
        state.selectAccount(.financing)
        var edited = entry.plan; edited.quantity += 1
        XCTAssertThrowsError(try state.savePlan(edited, symbol: entry.symbol, expected: entry.plan, account: source))
        let sourcePlan = state.watchlist.brokeragePortfolio(for: source).items.first { $0.symbol == entry.symbol }?.plans.first
        XCTAssertEqual(sourcePlan, entry.plan)
        XCTAssertTrue(state.watchlist.brokeragePortfolio(for: .financing).items.isEmpty)
    }

    @MainActor
    func testIndependentSamePriceSameSizeFillsAreNotDeduplicated() throws {
        let state = IPhoneAppState(demo: true)
        let item = try XCTUnwrap(state.historyItems.first)
        let originalCount = item.transactions.count
        for _ in 0..<2 {
            let trade = PositionTransaction(kind: .buy, price: 208000, quantity: 1, fundingSource: .own)
            _ = try state.recordTrade(trade, symbol: item.symbol, account: state.accountID)
        }
        XCTAssertEqual(state.watchlist.item(for: item.symbol)?.transactions.count, originalCount + 2)
    }
}
