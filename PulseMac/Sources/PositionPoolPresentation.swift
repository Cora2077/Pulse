import SwiftUI
import PulseCore
import PulseUI

extension PositionPool {
    /// The label for a purpose. The retired observation case is never an active
    /// destination, so the only place it can still reach a label is a legacy
    /// record being read back — and there it must read as what the product now
    /// means by that value: unassigned shares whose conditions carry the
    /// verification. The parenthetical keeps the origin honest without offering
    /// a purpose that no longer exists.
    var title: String {
        switch self {
        case .unassigned: positionPoolCopy("未分配", "Unassigned")
        case .strategic: positionPoolCopy("战略底仓", "Strategic")
        case .observation: positionPoolCopy("未分配（原观察仓）", "Unassigned (was Observation)")
        case .tactical: positionPoolCopy("机动仓", "Tactical")
        }
    }

    var subtitle: String {
        switch self {
        case .unassigned: positionPoolCopy("等待你确认用途", "Awaiting your classification")
        case .strategic: positionPoolCopy("长期参与", "Long-term participation")
        case .observation: positionPoolCopy("持有判断写在份额的验证条件里", "Conditions live on the portion now")
        case .tactical: positionPoolCopy("按策略灵活管理", "Managed by a trading strategy")
        }
    }

    var symbolName: String {
        switch self {
        case .unassigned: "tray.full"
        case .strategic: "anchor"
        case .observation: "tray.full"
        case .tactical: "arrow.left.arrow.right"
        }
    }

    /// The money-purpose tint. Observation wears the neutral unassigned gray:
    /// it is not an active purpose, and a purple column would imply one.
    /// Purple belongs to verification alone.
    var tint: Color {
        switch self {
        case .unassigned, .observation: Color.gray
        case .strategic: Color.blue
        case .tactical: Color.orange
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

func positionPoolCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}

func allocationReviewDescription(item: WatchItem, syncConflict: Bool = false) -> String {
    let issues = item.positionAllocationReconciliationIssues
    if let mismatch = issues.first(where: {
        if case .quantityMismatch = $0 { return true }
        return false
    }), case let .quantityMismatch(actual, allocated) = mismatch {
        let difference = allocated - actual
        return difference > 0
            ? positionPoolCopy("分配多 \(poolQuantity(difference)) 份", "Overallocated by \(poolQuantity(difference))")
            : positionPoolCopy("少分配 \(poolQuantity(-difference)) 份", "Underallocated by \(poolQuantity(-difference))")
    }
    if issues.contains(.sourceMismatch) { return positionPoolCopy("买入来源待核对", "Buy sources need review") }
    if issues.contains(.invalidAllocation) { return positionPoolCopy("分配记录无效", "Invalid allocation") }
    if issues.contains(.ledgerChanged) { return positionPoolCopy("账本变更待核对", "Ledger changed") }
    if issues.contains(.missingAllocation) { return positionPoolCopy("尚未分配", "Allocation missing") }
    return syncConflict ? positionPoolCopy("同步冲突", "Sync conflict") : positionPoolCopy("待核对", "Review")
}

func poolQuantity(_ value: Double) -> String {
    if value.isFinite, value != 0, abs(value) < 1e-12 { return value.description }
    return value.formatted(.number.precision(.fractionLength(0...12)))
}


func poolQuantityInput(_ value: Double) -> String { String(value) }
