import Foundation
import XCTest
@testable import PulseCore

/// Funding-source annotations: where the money behind a position is recorded,
/// how it survives copying, and how a sale is stopped from spending a source
/// the user never chose.
///
/// The recurring theme is that `nil` ("never recorded") and `.unmarked`
/// ("cleared on purpose") are different states, and that no annotation ever
/// moves a share, a price, or a P&L figure.
@MainActor
final class FundingSourceTests: XCTestCase {
    private let symbol = SymbolID(market: .us, code: "AAPL")

    private func makeStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let suite = "FundingSourceTests.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = WatchlistStore(defaults: defaults, defaultGroupName: "Core")
        store.add(SymbolInfo(symbol: symbol, name: "Apple"))
        return (store, defaults, suite)
    }

    private func item(_ store: WatchlistStore) throws -> WatchItem {
        try XCTUnwrap(store.item(for: symbol))
    }

    private func allocation(_ store: WatchlistStore) throws -> PositionAllocation {
        try XCTUnwrap(store.item(for: symbol)?.positionAllocation)
    }

    // MARK: - Reading data written before the field existed

    func testLegacyJSONWithoutTheFieldDecodesAsNilAndIsNotInvented() throws {
        // A payload written by a build that had no funding field at all.
        let legacy = """
        {
          "id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
          "quantity": 4,
          "pool": "strategic",
          "origin": {
            "kind": "buy",
            "transactionID": "3f2504e0-4f89-11d3-9a0c-0305e82c3302",
            "date": 800000000,
            "price": 10,
            "quantity": 4
          }
        }
        """
        let decoder = JSONDecoder()
        let portion = try decoder.decode(PositionPortion.self, from: Data(legacy.utf8))
        XCTAssertNil(portion.fundingSource, "an absent field must decode as nil, not as .unmarked")
        XCTAssertFalse(PositionFundingSource.hasMetadata(in: [portion]))

        // Re-encoding for a build that understands the field still says nothing.
        let reencoded = try decoder.decode(
            PositionPortion.self,
            from: try JSONEncoder().encode(portion)
        )
        XCTAssertNil(reencoded.fundingSource)
    }

    func testLegacyTransactionAndPlanDecodeWithoutAFundingSource() throws {
        let transaction = PositionTransaction(kind: .buy, price: 10, quantity: 4)
        let plan = TradePlan(kind: .buy, price: 10, quantity: 4)
        for data in [try JSONEncoder().encode(transaction), try JSONEncoder().encode(plan)] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["fundingSource"])
        }
        XCTAssertFalse(plan.hasFundingMetadata)
    }

    // MARK: - Annotating portions

    func testWholePortionAnnotationConservesSharesAndLedger() throws {
        let (store, defaults, suite) = try makeStore("whole")
        defer { defaults.removePersistentDomain(forName: suite) }
        let buy = PositionTransaction(kind: .buy, price: 100, quantity: 10)
        store.addTransaction(symbol, buy)
        let before = try item(store)

        let annotated = try store.markPositionFundingSource(
            symbol: symbol,
            portionID: XCTUnwrap(before.positionAllocation?.portions.first?.id),
            quantity: 10,
            source: .margin,
            reason: "  ",
            expectedRevision: XCTUnwrap(before.positionAllocation?.revision)
        )
        XCTAssertEqual(annotated.portions.count, 1)
        XCTAssertEqual(annotated.portions[0].fundingSource, .margin)
        XCTAssertEqual(annotated.portions[0].quantity, 10)
        XCTAssertEqual(annotated.changes.last?.kind, .funding)
        XCTAssertEqual(annotated.changes.last?.reason, "资金来源标注", "an empty reason takes the default label")

        let after = try item(store)
        XCTAssertEqual(after.transactions, before.transactions, "annotating must not touch the ledger")
        XCTAssertEqual(after.positionQuantity, 10)
        XCTAssertEqual(after.costBasis, 1000)
        XCTAssertEqual(after.realizedPnL, 0)
        XCTAssertFalse(after.positionAllocationNeedsReconciliation)
    }

    func testPartialAnnotationSplitsThePortionAndKeepsMetadata() throws {
        let (store, defaults, suite) = try makeStore("partial")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let before = try item(store)
        let original = try XCTUnwrap(before.positionAllocation?.portions.first)

        let annotated = try store.markPositionFundingSource(
            symbol: symbol,
            portionID: original.id,
            quantity: 4,
            source: .own,
            reason: "half from cash",
            expectedRevision: XCTUnwrap(before.positionAllocation?.revision)
        )
        XCTAssertEqual(annotated.portions.count, 2)
        let remainder = try XCTUnwrap(annotated.portions.first { $0.id == original.id })
        let labelled = try XCTUnwrap(annotated.portions.first { $0.id != original.id })
        XCTAssertEqual(remainder.quantity, 6)
        XCTAssertNil(remainder.fundingSource)
        XCTAssertEqual(labelled.quantity, 4)
        XCTAssertEqual(labelled.fundingSource, .own)
        // The split carries the origin, pool, and note across rather than
        // inventing a fresh buy source.
        XCTAssertEqual(labelled.origin, original.origin)
        XCTAssertEqual(labelled.pool, original.pool)
        XCTAssertEqual(labelled.note, original.note)
        XCTAssertEqual(annotated.portions.reduce(0) { $0 + $1.quantity }, 10)

        let after = try item(store)
        XCTAssertEqual(after.transactions.count, 1)
        XCTAssertEqual(after.positionQuantity, 10)
        XCTAssertFalse(after.positionAllocationNeedsReconciliation)
    }

    func testUnmarkedIsAnExplicitClearingDistinctFromNil() throws {
        let (store, defaults, suite) = try makeStore("unmarked")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let first = try allocation(store)
        let portionID = try XCTUnwrap(first.portions.first?.id)

        let cleared = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .unmarked,
            reason: "not sure yet", expectedRevision: first.revision
        )
        XCTAssertEqual(cleared.portions.first?.fundingSource, .unmarked)

        // The clearing is a value, so it is carried by the metadata detector and
        // a re-annotation to a real source is a genuine change, not a no-op.
        XCTAssertTrue(cleared.hasFundingMetadata)
        let owned = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .own,
            reason: "", expectedRevision: cleared.revision
        )
        XCTAssertEqual(owned.portions.first?.fundingSource, .own)
    }

    func testAnnotationMovesSharesToTheCorrectRemainderWhenSplit() throws {
        let (store, defaults, suite) = try makeStore("split-remainder")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let first = try allocation(store)
        let portionID = try XCTUnwrap(first.portions.first?.id)

        let partlyOwn = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 3, source: .own,
            reason: "", expectedRevision: first.revision
        )
        let ownPortion = try XCTUnwrap(partlyOwn.portions.first { $0.fundingSource == .own })
        let marginPart = try store.markPositionFundingSource(
            symbol: symbol, portionID: ownPortion.id, quantity: 2, source: .margin,
            reason: "", expectedRevision: partlyOwn.revision
        )
        XCTAssertEqual(marginPart.portions.first { $0.id == ownPortion.id }?.quantity, 1)
        XCTAssertEqual(marginPart.portions.first { $0.id == ownPortion.id }?.fundingSource, .own)
        XCTAssertEqual(marginPart.portions.first { $0.fundingSource == .margin }?.quantity, 2)
        XCTAssertEqual(marginPart.portions.reduce(0) { $0 + $1.quantity }, 10)
    }

    func testStaleNaNExcessAndNoOpAnnotationsAreRejectedWithoutWriting() throws {
        let (store, defaults, suite) = try makeStore("invalid")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let first = try allocation(store)
        let portionID = try XCTUnwrap(first.portions.first?.id)
        let before = try item(store)

        let staleRevision = UUID()
        XCTAssertThrowsError(try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .own,
            reason: "", expectedRevision: staleRevision
        )) { XCTAssertEqual($0 as? PositionAllocationError,
                           .staleRevision(expected: staleRevision, actual: first.revision)) }

        XCTAssertThrowsError(try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: .nan, source: .own,
            reason: "", expectedRevision: first.revision
        )) { XCTAssertEqual($0 as? PositionAllocationError, .invalidQuantity) }

        XCTAssertThrowsError(try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 11, source: .own,
            reason: "", expectedRevision: first.revision
        )) { XCTAssertEqual($0 as? PositionAllocationError, .quantityExceedsPortion) }

        let unknownID = UUID()
        XCTAssertThrowsError(try store.markPositionFundingSource(
            symbol: symbol, portionID: unknownID, quantity: 1, source: .own,
            reason: "", expectedRevision: first.revision
        )) { XCTAssertEqual($0 as? PositionAllocationError, .unknownPortion(unknownID)) }

        // Annotating the same value again is not a change, so nothing is written.
        let annotated = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .own,
            reason: "", expectedRevision: first.revision
        )
        XCTAssertThrowsError(try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .own,
            reason: "", expectedRevision: annotated.revision
        )) { XCTAssertEqual($0 as? PositionAllocationError, .sameFundingSource) }

        XCTAssertEqual(try item(store), {
            var expected = before
            expected.positionAllocation = annotated
            return expected
        }())
    }

    func testAnnotationIsUndoneInOneStep() throws {
        let (store, defaults, suite) = try makeStore("undo")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let first = try allocation(store)
        let portionID = try XCTUnwrap(first.portions.first?.id)

        let annotated = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 4, source: .margin,
            reason: "levered add", expectedRevision: first.revision
        )
        XCTAssertEqual(annotated.changes.last?.kind, .funding)
        let restored = try store.restorePositionAllocation(
            symbol: symbol, previous: first, expectedRevision: annotated.revision
        )
        XCTAssertEqual(restored.portions, first.portions)
        XCTAssertEqual(restored.changes.map(\.kind), [.buy, .funding, .restore])
        // Only one step is undoable, same as a transfer.
        XCTAssertThrowsError(try store.restorePositionAllocation(
            symbol: symbol, previous: first, expectedRevision: restored.revision
        )) { XCTAssertEqual($0 as? PositionAllocationError, .noSingleTransferToRestore) }
    }

    func testTransferInheritsTheFundingSourceOnBothSidesOfASplit() throws {
        let (store, defaults, suite) = try makeStore("transfer-inherit")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 100, quantity: 10))
        let first = try allocation(store)
        let portionID = try XCTUnwrap(first.portions.first?.id)
        let annotated = try store.markPositionFundingSource(
            symbol: symbol, portionID: portionID, quantity: 10, source: .margin,
            reason: "", expectedRevision: first.revision
        )

        let moved = try store.transferPositionPortion(
            symbol: symbol, portionID: portionID, quantity: 4, to: .tactical,
            reason: "", expectedRevision: annotated.revision
        )
        XCTAssertEqual(moved.portions.count, 2)
        XCTAssertTrue(moved.portions.allSatisfy { $0.fundingSource == .margin },
                      "a pool move is not a funding change; both cards keep the annotation")
        XCTAssertEqual(moved.portions.reduce(0) { $0 + $1.quantity }, 10)
    }

    // MARK: - Buys inherit the fill, not the plan

    func testRecordedBuyTakesTheFillsFundingNotThePlansIntent() throws {
        let (store, defaults, suite) = try makeStore("buy-intent")
        defer { defaults.removePersistentDomain(forName: suite) }
        // The plan intends margin.
        let plan = TradePlan(kind: .buy, price: 10, quantity: 100, positionPool: .tactical,
                             fundingSource: .margin)
        XCTAssertTrue(store.setTradePlan(plan, for: symbol))

        // The fill actually used the user's own cash.
        let fill = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 10, quantity: 100,
            date: .now, fee: nil, note: nil, fundingSource: .own
        )
        XCTAssertEqual(fill.fundingSource, .own)
        // The plan's intent is still snapshotted, so the difference is auditable.
        XCTAssertEqual(fill.planExecution?.configuration.fundingSource, .margin)

        let after = try item(store)
        XCTAssertEqual(after.positionAllocation?.portions.count, 1)
        XCTAssertEqual(after.positionAllocation?.portions.first?.fundingSource, .own,
                       "the portion follows the money that moved")
    }

    func testPlannedBuyWithoutAReportedSourceLeavesThePortionUnannotated() throws {
        let (store, defaults, suite) = try makeStore("buy-unreported")
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = TradePlan(kind: .buy, price: 10, quantity: 50, fundingSource: .margin)
        XCTAssertTrue(store.setTradePlan(plan, for: symbol))
        let fill = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 10, quantity: 50,
            date: .now, fee: nil, note: nil
        )
        XCTAssertNil(fill.fundingSource)
        let after = try item(store)
        XCTAssertNil(after.positionAllocation?.portions.first?.fundingSource,
                     "an unreported fill must not inherit the plan's guess")
    }

    func testManuallyAddedBuyCarriesItsOwnFundingSource() throws {
        let (store, defaults, suite) = try makeStore("manual-buy")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(
            kind: .buy, price: 10, quantity: 5, fundingSource: .margin
        ))
        let after = try item(store)
        XCTAssertEqual(after.positionAllocation?.portions.first?.fundingSource, .margin)
    }

    // MARK: - Sales must not spend an unchosen source

    /// Two tactical buys of five each: one paid for with the user's own money
    /// and one with margin, so the position holds two funding sources.
    private func mixedSourceStore(_ label: String) throws -> (WatchlistStore, UserDefaults, String) {
        let made = try makeStore(label)
        for (source, price) in [(PositionFundingSource.own, 10.0), (.margin, 10.0)] {
            let plan = TradePlan(kind: .buy, price: price, quantity: 5, positionPool: .tactical)
            XCTAssertTrue(made.0.setTradePlan(plan, for: symbol))
            _ = try made.0.recordTradePlanFill(
                symbol: symbol, planID: plan.id, price: price, quantity: 5,
                date: .now, fee: nil, note: nil, fundingSource: source
            )
        }
        return made
    }

    func testMixedFundingSaleWithoutSelectionIsRefusedAndWritesNothing() throws {
        let (store, defaults, suite) = try mixedSourceStore("mixed-refuse")
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = try item(store)
        XCTAssertEqual(Set(before.positionAllocation?.portions.map(\.fundingSource) ?? []), [.own, .margin])

        let sell = TradePlan(kind: .sell, price: 12, quantity: 4, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        let beforeSell = try item(store)

        XCTAssertThrowsError(try store.recordTradePlanFill(
            symbol: symbol, planID: sell.id, price: 12, quantity: 4,
            date: .now, fee: nil, note: nil
        )) { error in
            guard case .fundingSelectionRequired(let available) = error as? TradePlanExecutionError else {
                return XCTFail("expected fundingSelectionRequired, got \(error)")
            }
            XCTAssertEqual(available[.own], 5)
            XCTAssertEqual(available[.margin], 5)
        }
        // The refusal happens before any commit: no trade, no allocation change.
        XCTAssertEqual(try item(store), beforeSell)
        XCTAssertEqual(try item(store).transactions.count, before.transactions.count)
    }

    func testExplicitFundingSelectionReducesExactlyTheChosenPortions() throws {
        let (store, defaults, suite) = try mixedSourceStore("mixed-select")
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = try item(store)
        let ownPortion = try XCTUnwrap(before.positionAllocation?.portions.first { $0.fundingSource == .own })
        let marginPortion = try XCTUnwrap(before.positionAllocation?.portions.first { $0.fundingSource == .margin })

        let sell = TradePlan(kind: .sell, price: 12, quantity: 4, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        let fill = try store.recordTradePlanFill(
            symbol: symbol, planID: sell.id, price: 12, quantity: 4,
            date: .now, fee: nil, note: nil,
            salePortionQuantities: [ownPortion.id: 3, marginPortion.id: 1]
        )
        XCTAssertEqual(fill.kind, .sell)

        let after = try item(store)
        XCTAssertEqual(after.positionAllocation?.portions.first { $0.id == ownPortion.id }?.quantity, 2)
        XCTAssertEqual(after.positionAllocation?.portions.first { $0.id == marginPortion.id }?.quantity, 4)
        XCTAssertEqual(after.positionAllocation?.portions.reduce(0) { $0 + $1.quantity }, 6)
        XCTAssertEqual(after.positionQuantity, 6)
        XCTAssertFalse(after.positionAllocationNeedsReconciliation)
        // A sale never repays margin and never moves cash.
        XCTAssertEqual(after.positionAllocation?.portions.first { $0.id == ownPortion.id }?.fundingSource, .own)
        XCTAssertEqual(after.positionAllocation?.portions.first { $0.id == marginPortion.id }?.fundingSource, .margin)
    }

    func testChangedFundingRevisionRefusesAnOldSelectionWithoutWriting() throws {
        let (store, defaults, suite) = try mixedSourceStore("stale-selection")
        defer { defaults.removePersistentDomain(forName: suite) }
        let allocation = try allocation(store)
        let portion = try XCTUnwrap(allocation.portions.first)
        let sell = TradePlan(kind: .sell, price: 12, quantity: 2, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        _ = try store.markPositionFundingSource(symbol: symbol, portionID: portion.id,
            quantity: portion.quantity, source: .unmarked, reason: "", expectedRevision: allocation.revision)
        let before = try item(store)
        XCTAssertThrowsError(try store.recordTradePlanFill(symbol: symbol, planID: sell.id,
            price: 12, quantity: 2, date: .now, fee: nil, note: nil,
            salePortionQuantities: [portion.id: 2], expectedAllocationRevision: allocation.revision)) {
            XCTAssertEqual($0 as? TradePlanExecutionError, .staleAllocation)
        }
        XCTAssertEqual(try item(store), before)
    }

    func testCorrectingReportedBuyFundingRequiresAllocationReviewWithoutChangingMoney() throws {
        let (store, defaults, suite) = try makeStore("correct-buy-funding")
        defer { defaults.removePersistentDomain(forName: suite) }
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 5, fundingSource: .own)
        store.addTransaction(symbol, buy)
        let before = try item(store)
        var corrected = buy
        corrected.fundingSource = .margin
        store.updateTransaction(symbol, corrected)
        let after = try item(store)
        XCTAssertTrue(after.positionAllocationNeedsReconciliation)
        XCTAssertEqual(after.positionQuantity, before.positionQuantity)
        XCTAssertEqual(after.averageCost, before.averageCost)
        XCTAssertEqual(after.realizedPnL, before.realizedPnL)
    }

    func testUnspecifiedPoolSaleCanRecordFactsWhenAllocationNeedsReview() throws {
        let (store, defaults, suite) = try mixedSourceStore("unspecified-stale")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, .init(kind: .sell, price: 12, quantity: 1))
        XCTAssertTrue(try item(store).positionAllocationNeedsReconciliation)
        let plan = TradePlan(kind: .sell, price: 12, quantity: 1)
        XCTAssertTrue(store.setTradePlan(plan, for: symbol))
        let fill = try store.recordTradePlanFill(symbol: symbol, planID: plan.id,
            price: 12, quantity: 1, date: .now, fee: nil, note: nil)
        XCTAssertEqual(fill.kind, .sell)
        XCTAssertTrue(try item(store).positionAllocationNeedsReconciliation)
    }

    func testInvalidFundingSelectionsAreRejectedBeforeCommitting() throws {
        let (store, defaults, suite) = try mixedSourceStore("mixed-invalid")
        defer { defaults.removePersistentDomain(forName: suite) }
        let before = try item(store)
        let ownPortion = try XCTUnwrap(before.positionAllocation?.portions.first { $0.fundingSource == .own })
        let marginPortion = try XCTUnwrap(before.positionAllocation?.portions.first { $0.fundingSource == .margin })
        let sell = TradePlan(kind: .sell, price: 12, quantity: 4, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        let beforeSell = try item(store)

        let badSelections: [[UUID: Double]] = [
            [ownPortion.id: 4, marginPortion.id: 1],      // sums to 5, not the fill's 4
            [ownPortion.id: 3],                            // sums to 3
            [ownPortion.id: 9],                            // exceeds the portion
            [ownPortion.id: -4],                           // not positive
            [ownPortion.id: .nan],                         // not finite
            [UUID(): 4],                                   // not a live portion
            [ownPortion.id: 2, marginPortion.id: 2, UUID(): 0] // unknown id, zero amount
        ]
        for selection in badSelections {
            XCTAssertThrowsError(try store.recordTradePlanFill(
                symbol: symbol, planID: sell.id, price: 12, quantity: 4,
                date: .now, fee: nil, note: nil, salePortionQuantities: selection
            ), "selection \(selection) should be refused") { error in
                XCTAssertEqual(error as? TradePlanExecutionError, .invalidFundingSelection)
            }
            XCTAssertEqual(try item(store), beforeSell, "a refused selection must not write")
        }
    }

    func testSelectionOutsideThePlansPoolIsRejected() throws {
        let (store, defaults, suite) = try makeStore("wrong-pool")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(
            kind: .buy, price: 10, quantity: 5, fundingSource: .own
        ))
        let before = try item(store)
        let portionID = try XCTUnwrap(before.positionAllocation?.portions.first?.id)
        let sell = TradePlan(kind: .sell, price: 12, quantity: 5, positionPool: .strategic)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        let beforeSell = try item(store)

        XCTAssertThrowsError(try store.recordTradePlanFill(
            symbol: symbol, planID: sell.id, price: 12, quantity: 5,
            date: .now, fee: nil, note: nil, salePortionQuantities: [portionID: 5]
        )) { XCTAssertEqual($0 as? TradePlanExecutionError, .invalidFundingSelection) }
        XCTAssertEqual(try item(store), beforeSell)
    }

    func testSingleSourcePoolSaleStillDeductsAutomatically() throws {
        let (store, defaults, suite) = try makeStore("single-source")
        defer { defaults.removePersistentDomain(forName: suite) }
        let buy = TradePlan(kind: .buy, price: 10, quantity: 10, positionPool: .tactical, fundingSource: .margin)
        XCTAssertTrue(store.setTradePlan(buy, for: symbol))
        _ = try store.recordTradePlanFill(
            symbol: symbol, planID: buy.id, price: 10, quantity: 10,
            date: .now, fee: nil, note: nil, fundingSource: .margin
        )
        let sell = TradePlan(kind: .sell, price: 12, quantity: 4, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        _ = try store.recordTradePlanFill(
            symbol: symbol, planID: sell.id, price: 12, quantity: 4,
            date: .now, fee: nil, note: nil
        )
        let after = try item(store)
        XCTAssertEqual(after.positionQuantity, 6)
        XCTAssertEqual(after.positionAllocation?.portions.count, 1)
        XCTAssertEqual(after.positionAllocation?.portions.first?.fundingSource, .margin)
        XCTAssertFalse(after.positionAllocationNeedsReconciliation)
    }

    func testUnannotatedPortionsReadAsOneUnmarkedSource() throws {
        let (store, defaults, suite) = try makeStore("nil-is-unmarked")
        defer { defaults.removePersistentDomain(forName: suite) }
        // Two buys with no annotation at all: both nil, which is one source.
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 5))
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 5))
        let sell = TradePlan(kind: .sell, price: 12, quantity: 4, positionPool: .unassigned)
        XCTAssertTrue(store.setTradePlan(sell, for: symbol))
        _ = try store.recordTradePlanFill(
            symbol: symbol, planID: sell.id, price: 12, quantity: 4,
            date: .now, fee: nil, note: nil
        )
        let after = try item(store)
        XCTAssertEqual(after.positionQuantity, 6)
        XCTAssertEqual(after.positionAllocation?.portions.reduce(0) { $0 + $1.quantity }, 6)
    }

    // MARK: - Archives

    func testArchiveRoundTripKeepsFundingInHistoryAndSnapshots() throws {
        let (source, sourceDefaults, sourceSuite) = try makeStore("archive-source")
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite) }
        let plan = TradePlan(kind: .buy, price: 100, quantity: 10, positionPool: .strategic,
                             fundingSource: .margin)
        XCTAssertTrue(source.setTradePlan(plan, for: symbol))
        // Create a revision so the history carries a funding configuration too.
        var edited = plan
        edited.price = 101
        XCTAssertTrue(source.setTradePlan(edited, for: symbol))
        let fill = try source.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 101, quantity: 10,
            date: .now, fee: nil, note: nil, fundingSource: .own
        )
        let annotation = try source.markPositionFundingSource(
            symbol: symbol,
            portionID: XCTUnwrap(source.item(for: symbol)?.positionAllocation?.portions.first?.id),
            quantity: 4, source: .margin, reason: "split source",
            expectedRevision: XCTUnwrap(source.item(for: symbol)?.positionAllocation?.revision)
        )
        XCTAssertEqual(annotation.portions.filter { $0.fundingSource == .margin }.count, 1)

        let archive = source.archive()
        XCTAssertEqual(archive.version, 8, "funding data must raise the declared version")
        let text = try archive.encoded()

        let decoded = try WatchlistArchive.decoded(from: text)
        let entry = try XCTUnwrap(decoded.lists.first?.entries.first)
        XCTAssertEqual(entry.transactions?.first?.fundingSource, .own)
        XCTAssertEqual(entry.transactions?.first?.planExecution?.configuration.fundingSource, .margin)
        XCTAssertEqual(entry.plans?.first?.fundingSource, .margin)
        XCTAssertEqual(entry.plans?.first?.history?.first?.configuration.fundingSource, .margin)
        XCTAssertTrue(entry.positionAllocation?.hasFundingMetadata == true)
        XCTAssertTrue(entry.positionAllocation?.changes.contains {
            PositionFundingSource.hasMetadata(in: $0.resultingPortions)
        } == true)

        let (restored, restoredDefaults, restoredSuite) = try makeStore("archive-restored")
        defer { restoredDefaults.removePersistentDomain(forName: restoredSuite) }
        restored.merge(decoded)
        let restoredItem = try item(restored)
        XCTAssertEqual(restoredItem.transactions.first?.fundingSource, .own)
        XCTAssertEqual(restoredItem.plans.first?.fundingSource, .margin)
        XCTAssertEqual(restoredItem.positionAllocation, annotation)
        XCTAssertEqual(fill.fundingSource, .own)
    }

    func testArchiveWithoutAnyFundingKeepsItsOlderVersion() throws {
        let (store, defaults, suite) = try makeStore("archive-old-version")
        defer { defaults.removePersistentDomain(forName: suite) }
        store.addTransaction(symbol, PositionTransaction(kind: .buy, price: 10, quantity: 4))
        let archive = store.archive()
        XCTAssertLessThan(archive.version, 8, "a payload with no funding field must not claim v8")

        // And the version it does claim still decodes.
        let text = try archive.encoded()
        let decoded = try WatchlistArchive.decoded(from: text)
        XCTAssertNil(decoded.lists.first?.entries.first?.transactions?.first?.fundingSource)
    }

    func testArchiveDeclaringAnOldVersionButCarryingFundingIsRejected() throws {
        let (store, defaults, suite) = try makeStore("archive-lie")
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = TradePlan(kind: .buy, price: 10, quantity: 4, positionPool: .tactical)
        XCTAssertTrue(store.setTradePlan(plan, for: symbol))
        _ = try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 10, quantity: 4,
            date: .now, fee: nil, note: nil, fundingSource: .margin
        )
        let valid = try store.archive().encoded()
        let lowered = valid.replacingOccurrences(of: "\"version\" : 8", with: "\"version\" : 7")
        XCTAssertNotEqual(valid, lowered, "the fixture must actually lower the version")
        XCTAssertThrowsError(try WatchlistArchive.decoded(from: lowered)) { error in
            XCTAssertEqual(error as? WatchlistArchive.DecodingFailure, .unsupportedVersion(8))
        }

        // The same lie told only through the plan's own intent.
        var planOnly = try makeStore("archive-lie-plan")
        planOnly.0.setTradePlan(TradePlan(kind: .buy, price: 10, quantity: 4, fundingSource: .own),
                                for: symbol)
        let planText = try planOnly.0.archive().encoded()
            .replacingOccurrences(of: "\"version\" : 8", with: "\"version\" : 7")
        XCTAssertThrowsError(try WatchlistArchive.decoded(from: planText)) { error in
            XCTAssertEqual(error as? WatchlistArchive.DecodingFailure, .unsupportedVersion(8))
        }
        planOnly.1.removePersistentDomain(forName: planOnly.2)
    }

    // MARK: - Sync wire format

    private func makeSnapshot() -> WatchlistSyncSnapshot {
        var portion = PositionPortion(
            quantity: 5, pool: .strategic,
            origin: PositionPortion.Origin(kind: .snapshot, date: Date(timeIntervalSince1970: 0)),
            fundingSource: .margin
        )
        portion.fundingSource = .margin
        let allocation = PositionAllocation(
            basisFingerprint: String(repeating: "a", count: 64),
            portions: [portion],
            changes: [PositionAllocation.Change(
                kind: .funding, reason: "annotate",
                previousPortions: [PositionPortion(
                    quantity: 5, pool: .strategic,
                    origin: portion.origin
                )],
                resultingPortions: [portion]
            )]
        )
        let plan = TradePlan(kind: .buy, price: 10, quantity: 5, fundingSource: .own)
        let transaction = PositionTransaction(
            kind: .buy, price: 10, quantity: 5,
            planExecution: TradePlanExecution(
                planID: plan.id,
                configuration: TradePlanConfiguration(plan: plan)
            ),
            fundingSource: .margin
        )
        let item = WatchItem(
            symbol: symbol, displayName: "Apple",
            transactions: [transaction], plans: [plan], positionAllocation: allocation
        )
        return WatchlistSyncSnapshot(items: [item], groups: [])
    }

    func testSyncRoundTripKeepsFundingAndRaisesTheVersion() throws {
        let snapshot = makeSnapshot()
        let data = try WatchlistSyncWireCodec.encode(deviceID: "device-a", snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data, expectedDeviceID: "device-a")
        XCTAssertEqual(decoded.version, 9)
        XCTAssertEqual(decoded.snapshot, snapshot)
        let item = try XCTUnwrap(decoded.snapshot.items.first)
        XCTAssertEqual(item.transactions.first?.fundingSource, .margin)
        XCTAssertEqual(item.transactions.first?.planExecution?.configuration.fundingSource, .own)
        XCTAssertEqual(item.plans.first?.fundingSource, .own)
        XCTAssertEqual(item.positionAllocation?.portions.first?.fundingSource, .margin)
    }

    func testSyncWithoutFundingKeepsTheOlderVersion() throws {
        let symbol = SymbolID(market: .us, code: "AAPL")
        let snapshot = WatchlistSyncSnapshot(items: [
            WatchItem(symbol: symbol, displayName: "Apple", transactions: [
                PositionTransaction(kind: .buy, price: 10, quantity: 1)
            ])
        ], groups: [])
        let data = try WatchlistSyncWireCodec.encode(deviceID: "device-a", snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data)
        XCTAssertLessThan(decoded.version, 9)
        XCTAssertNil(decoded.snapshot.items.first?.transactions.first?.fundingSource)
    }

    func testSyncDeclaringAnOldVersionButCarryingFundingIsRejected() throws {
        let snapshot = makeSnapshot()
        let data = try WatchlistSyncWireCodec.encode(deviceID: "device-a", snapshot: snapshot)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 9)
        payload["version"] = 8
        let lowered = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(lowered)) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .unsupportedVersion(9))
        }
    }

    func testSyncRoundTripDropsNothingWhenTheAnnotationWasCleared() throws {
        // An explicit .unmarked must survive as a value: it is the only thing
        // that keeps "cleared" from being re-filled by an older peer record.
        var snapshot = makeSnapshot()
        snapshot.items[0].positionAllocation?.portions[0].fundingSource = .unmarked
        snapshot.items[0].positionAllocation?.changes[0].resultingPortions[0].fundingSource = .unmarked
        let data = try WatchlistSyncWireCodec.encode(deviceID: "device-a", snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data)
        XCTAssertEqual(decoded.version, 9)
        XCTAssertEqual(decoded.snapshot.items[0].positionAllocation?.portions[0].fundingSource, .unmarked)
        XCTAssertEqual(
            decoded.snapshot.items[0].positionAllocation?.changes[0].resultingPortions[0].fundingSource,
            .unmarked
        )
    }

    // MARK: - Merges

    func testMergeFillsOnlyMissingAnnotationsAndNeverOverwritesAClearing() throws {
        let empty = WatchlistSyncSnapshot(items: [], groups: [])
        var base = makeSnapshot()
        base.items[0].transactions[0].fundingSource = nil
        base.items[0].plans[0].fundingSource = nil
        var local = base
        local.items[0].transactions[0].fundingSource = .own
        local.items[0].plans[0].fundingSource = .unmarked
        // The remote still has the base's nil values, i.e. it never learned.
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: base)
        let merged = try XCTUnwrap(result.snapshot.items.first)
        XCTAssertEqual(merged.transactions.first?.fundingSource, .own,
                       "a peer that never learned the field must not erase it")
        XCTAssertEqual(merged.plans.first?.fundingSource, .unmarked,
                       "an explicit clearing is a value, not a gap")
    }

    func testMergeKeepsAClearingInsteadOfBackfillingFromTheOtherSide() throws {
        var base = makeSnapshot()
        base.items[0].transactions[0].fundingSource = .margin
        var local = base
        local.items[0].transactions[0].fundingSource = .unmarked
        var remote = base
        remote.items[0].transactions[0].fundingSource = .margin
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        let merged = try XCTUnwrap(result.snapshot.items.first)
        XCTAssertEqual(merged.transactions.first?.fundingSource, .unmarked)
    }

    func testStoreRejectsAStalePlanRevisionBeforeAnyFundingIsWritten() throws {
        let (store, defaults, suite) = try makeStore("stale-plan")
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = TradePlan(kind: .buy, price: 10, quantity: 5)
        XCTAssertTrue(store.setTradePlan(plan, for: symbol))
        let before = try item(store)
        XCTAssertThrowsError(try store.recordTradePlanFill(
            symbol: symbol, planID: plan.id, price: 10, quantity: 5,
            date: .now, fee: nil, note: nil, transactionID: UUID(),
            expectedPlanUpdatedAt: .distantPast, fundingSource: .margin
        )) { XCTAssertEqual($0 as? TradePlanExecutionError, .stalePlan) }
        XCTAssertEqual(try item(store), before)
    }
}
