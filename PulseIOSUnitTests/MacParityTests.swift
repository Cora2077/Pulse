import XCTest
import PulseCore
@testable import FFFiPhone

final class MacParityTests: XCTestCase {
    @MainActor func testRunsTheOriginalMacWorkbenchAcceptanceChecksUnchanged() {
        XCTAssertTrue(WorkbenchSelfTest.run(), WorkbenchSelfTest.failureReport)
    }

    @MainActor func testAutomaticSortIsStablePinnedFirstMissingLastAndReadOnly() {
        let items = ["A", "B", "C", "D", "E"].map { WatchItem(symbol: SymbolID(market: .us, code: $0), displayName: $0) }
        let metrics: [String: Double] = ["A": 1, "B": .nan, "C": 3, "D": 3]
        let before = items
        let sorted = WatchlistSorting.ordered(items, pinnedSymbols: [items[1].symbol], option: .changePercent) {
            metrics[$0.symbol.code]
        }
        XCTAssertEqual(sorted.map(\.symbol.code), ["B", "C", "D", "A", "E"])
        XCTAssertEqual(items, before)
        let custom = WatchlistSorting.ordered(items, pinnedSymbols: [items[3].symbol], option: .custom) { _ in
            XCTFail("Custom order must not read any quote"); return 0
        }
        XCTAssertEqual(custom.map(\.symbol.code), ["D", "A", "B", "C", "E"])
    }

    @MainActor func testReorderRefusesChangedAccountAndChangedGroupRatherThanWritingElsewhere() throws {
        let state = IPhoneAppState(demo: true)
        let group = try XCTUnwrap(state.watchlist.selectedGroup)
        let account = state.accountID
        let before = state.watchlist.syncSnapshot()
        state.selectAccount(.financing)
        XCTAssertThrowsError(try state.saveWatchlistOrder(group.symbols.reversed(), expectedGroup: group, account: account))
        state.selectAccount(account)
        XCTAssertEqual(state.watchlist.syncSnapshot(), before)
        XCTAssertTrue(state.watchlist.renameGroup(group.id, to: "Changed"))
        let changed = state.watchlist.syncSnapshot()
        XCTAssertThrowsError(try state.saveWatchlistOrder(group.symbols.reversed(), expectedGroup: group, account: account))
        XCTAssertEqual(state.watchlist.syncSnapshot(), changed)
    }

    @MainActor func testSearchSelectionDoesNotAddAnUnwatchedSymbolUntilPlanSave() throws {
        let state = IPhoneAppState(demo: true)
        let info = SymbolInfo(symbol: SymbolID(market: .us, code: "TSLA"), name: "测试新标的", type: .equity)
        let before = state.watchlist.syncSnapshot()
        _ = PlanEditorTarget.create(info: info, account: state.accountID)
        XCTAssertEqual(state.watchlist.syncSnapshot(), before)
        let plan = TradePlan(kind: .buy, price: 100, quantity: 2, fundingSource: .own)
        try state.savePlan(plan, symbol: info.symbol, expected: nil, account: state.accountID, newSymbolInfo: info)
        XCTAssertTrue(state.watchlist.contains(info.symbol))
        XCTAssertEqual(state.watchlist.item(for: info.symbol)?.plans.first?.id, plan.id)
        XCTAssertEqual(state.watchlist.item(for: info.symbol)?.transactions.count, 0)
        // Retrying the same creation is adoption, not a duplicate plan.
        try state.savePlan(plan, symbol: info.symbol, expected: nil, account: state.accountID, newSymbolInfo: info)
        XCTAssertEqual(state.watchlist.item(for: info.symbol)?.plans.count, 1)
    }

    @MainActor func testInvalidNewPlanCreatesNeitherAnEmptyWatchItemNorAGroupMembership() {
        let state = IPhoneAppState(demo: true)
        let info = SymbolInfo(symbol: SymbolID(market: .us, code: "NEW"), name: "拒绝写入测试", type: .equity)
        let before = state.watchlist.syncSnapshot()
        let invalid = TradePlan(kind: .buy, price: -1, quantity: 2)
        XCTAssertThrowsError(try state.savePlan(invalid, symbol: info.symbol, expected: nil, account: state.accountID, newSymbolInfo: info))
        XCTAssertEqual(state.watchlist.syncSnapshot(), before)
        // The Core boundary also rejects invalid linked cards without first
        // adding the searched symbol. No write-and-rollback window exists.
        let invalidCard = TradePlan(kind: .sell, price: 100, quantity: 2, positionPortionID: UUID())
        XCTAssertFalse(state.watchlist.createTradePlan(invalidCard, for: info, account: state.accountID))
        XCTAssertEqual(state.watchlist.syncSnapshot(), before)
    }
}
