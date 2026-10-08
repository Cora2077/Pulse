import Foundation
import Testing
@testable import PulseCore

@Suite("Allocation reconciliation reasons")
struct AllocationReconciliationIssueTests {
    private let symbol = SymbolID(market: .sh, code: "600000")

    private func allocatedItem(quantity: Double = 600, allocated: Double = 600) -> WatchItem {
        var item = WatchItem(symbol: symbol, displayName: "Synthetic", transactions: [
            PositionTransaction(kind: .buy, price: 10, quantity: quantity)
        ])
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [PositionPortion(quantity: allocated, pool: .tactical, origin: .init(kind: .snapshot))]
        )
        return item
    }

    @Test("Card total cannot become the live ledger total")
    func quantityDifference() {
        let item = allocatedItem(allocated: 800)
        #expect(item.positionQuantity == 600)
        #expect(item.positionAllocationReconciliationIssues == [.quantityMismatch(actual: 600, allocated: 800)])
        #expect(item.positionAllocationNeedsReconciliation)
        #expect(item.positionAccountQuantities(enclosingAccountID: .unassigned) == [.unassigned: 600])
    }

    @Test("Source, quantity and ledger changes remain independently inspectable")
    func multipleReasons() {
        var item = allocatedItem(allocated: 800)
        item.positionAllocation?.portions[0].origin = .init(kind: .buy, transactionID: UUID(), date: .now,
                                                         price: 10, quantity: 800)
        item.positionAllocation?.basisFingerprint = String(repeating: "0", count: 64)
        #expect(item.positionAllocationReconciliationIssues == [
            .ledgerChanged, .sourceMismatch, .quantityMismatch(actual: 600, allocated: 800)
        ])
    }

    @Test("Review notes do not invalidate allocations or manufacture warnings")
    func reviewMetadata() {
        var item = allocatedItem()
        item.transactions[0].note = "Review note"
        item.transactions[0].review = .init(followedPlan: true, retrospective: "As planned")
        #expect(item.positionAllocationReconciliationIssues.isEmpty)
        #expect(!item.positionAllocationNeedsReconciliation)
        item.positionAllocation = nil
        #expect(item.positionAllocationReconciliationIssues == [.missingAllocation])
    }

    @Test("Invalid or flat allocations preserve reconciliation gating")
    func invalidAndFlat() {
        var item = allocatedItem()
        item.positionAllocation?.portions[0].quantity = .infinity
        #expect(item.positionAllocationReconciliationIssues.contains(.invalidAllocation))
        #expect(item.positionAllocationNeedsReconciliation)
        item.transactions = []
        #expect(item.positionAllocationReconciliationIssues.isEmpty)
        #expect(!item.positionAllocationNeedsReconciliation)
    }
}
