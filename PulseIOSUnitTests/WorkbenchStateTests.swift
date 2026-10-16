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
        XCTAssertThrowsError(try state.saveReview(nil, note: nil, original: original, symbol: item.symbol, account: account))
        try state.saveReview(nil, note: nil, original: reviewed, symbol: item.symbol, account: account)
        let cleared = try XCTUnwrap(state.watchlist.item(for: item.symbol)?.transactions.first)
        XCTAssertNil(cleared.review)
        XCTAssertNil(cleared.note)
        XCTAssertEqual(cleared.price, original.price)
        XCTAssertEqual(cleared.quantity, original.quantity)
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
