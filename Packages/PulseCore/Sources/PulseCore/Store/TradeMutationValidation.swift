import Foundation

/// Refusals shared by user-facing trade writes. Legacy import and calibration
/// may still describe shorts; a named ledger cannot acquire a new short by edit.
public enum TradeMutationError: LocalizedError, Equatable, Sendable {
    case staleRecord
    case itemNotFound
    case transactionNotFound
    case accountUnavailable
    case fundingIncompatible
    case invalidValues
    case duplicateTransactionID
    case negativePosition
    case destinationConflict
    case invalidSelection
    case allocationNeedsReconciliation
    case planDependencyConflict
    case immutablePlanContext
    case invalidCandidate

    public var errorDescription: String? {
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        switch self {
        case .staleRecord:
            return chinese ? "这笔成交已变化。输入已保留，请返回并重新打开记录后再修改。" : "This trade changed. Your input was kept; go back and reopen the record before editing."
        case .itemNotFound:
            return chinese ? "找不到这项持仓或保留的成交历史。" : "Position or retained trade history not found."
        case .transactionNotFound:
            return chinese ? "这笔成交已不存在或已归类到其他账户，请重新打开历史记录。" : "This trade no longer exists or belongs to another account. Reopen the history."
        case .accountUnavailable:
            return chinese ? "成交账户不可用，请核对来源和目标账户。" : "Trade account is unavailable. Check the source and destination accounts."
        case .fundingIncompatible:
            return chinese ? "资金方式不符合账户规则；只有融资账户可以新增融资买入。" : "Funding is incompatible with the account; new margin buys require the financing account."
        case .invalidValues:
            return chinese ? "成交价格、数量、费用、日期或备注无效。" : "Trade price, quantity, fee, date, or notes are invalid."
        case .duplicateTransactionID:
            return chinese ? "成交编号已被其他记录使用，未做任何更改。" : "Transaction ID is already in use. Nothing was changed."
        case .negativePosition:
            return chinese ? "此操作会使历史持仓出现负数或扩大原有缺口。请先核对相关买卖成交及日期，未做任何更改。" : "This change would create or worsen a negative historical position. Check related buys, sells, and dates. Nothing was changed."
        case .destinationConflict:
            return chinese ? "目标账户已有该标的的成交或关联记录，无法整体覆盖；请改为选择成交或先核对记录。" : "The destination already has trades or related records. Choose specific trades or reconcile the records instead of replacing the whole ledger."
        case .invalidSelection:
            return chinese ? "所选成交为空、已不存在或与目标记录重复，请重新选择。" : "The trade selection is empty, missing, or duplicates destination records. Select again."
        case .allocationNeedsReconciliation:
            return chinese ? "仓位份额需要核对，请先完成核对再修改成交归属。" : "Position allocation needs reconciliation before changing trade ownership."
        case .planDependencyConflict:
            return chinese ? "此操作会破坏计划与成交或仓位份额的关联，请一并核对相关记录。" : "This change would break plan links to trades or position portions. Reconcile the related records together."
        case .immutablePlanContext:
            return chinese ? "关联计划的成交不能改为另一买卖方向或校准记录，请保留原方向。" : "A plan-linked trade cannot change its side or become an adjustment. Keep its original kind."
        case .invalidCandidate:
            return chinese ? "修改后的账户数据未通过完整校验，未做任何更改。" : "The proposed account data failed validation. Nothing was changed."
        }
    }
}

/// Pure gates: callers build candidates first, validate, then publish once.
enum TradeMutationValidation {
    static func validatePayload(_ transaction: PositionTransaction) throws {
        let priceIsValid = transaction.price.isFinite
            && (transaction.kind == .sell ? transaction.price > 0 : transaction.price >= 0)
        let quantityIsValid = transaction.quantity.isFinite
            && (transaction.kind == .adjustment || transaction.quantity > 0)
        guard priceIsValid, quantityIsValid, transaction.hasValidFee,
              (transaction.price * transaction.quantity).isFinite,
              (transaction.price * transaction.quantity + (transaction.fee ?? 0)).isFinite,
              transaction.date.timeIntervalSince1970.isFinite,
              transaction.createdAt.timeIntervalSince1970.isFinite,
              transaction.note.map({ $0.count <= 4_000 }) ?? true else {
            throw TradeMutationError.invalidValues
        }
        do { _ = try transaction.review?.normalizedForPersistence() }
        catch { throw TradeMutationError.invalidValues }
    }

    static func validateReplay(previous: [PositionTransaction], proposed: [PositionTransaction],
                               longOnly: Bool) throws {
        guard Set(proposed.map(\.id)).count == proposed.count else {
            throw TradeMutationError.duplicateTransactionID
        }
        let ledger = PositionLedger(transactions: proposed)
        guard [ledger.quantity, ledger.averageCost, ledger.costBasis, ledger.realizedPnL,
               ledger.totalFees, ledger.dilutedCost].allSatisfy(\.isFinite),
              ledger.entries.allSatisfy({ $0.resultingQuantity.isFinite && $0.resultingAverageCost.isFinite
                  && ($0.realizedPnL?.isFinite ?? true) }) else {
            throw TradeMutationError.invalidValues
        }
        guard longOnly else { return }
        let before = PositionLedger(transactions: previous)
        let previousQuantities = Dictionary(before.entries.map { ($0.id, $0.resultingQuantity) },
                                             uniquingKeysWith: { first, _ in first })
        var priorQuantity = 0.0
        for entry in ledger.entries {
            defer { priorQuantity = entry.resultingQuantity }
            guard entry.resultingQuantity < 0 else { continue }
            // A new cover may reduce an already validated imported short without
            // having to close all of it in one trade. A new sale gets no exemption.
            if previousQuantities[entry.id] == nil, entry.transaction.kind == .buy,
               priorQuantity < 0, entry.resultingQuantity > priorQuantity { continue }
            // Grandfather only this same entry's existing deficit, never an entire
            // ledger because some unrelated older entry happened to be short.
            let old = min(previousQuantities[entry.id] ?? 0, 0)
            // Scale rounding tolerance to this entry's real quantity: an absolute
            // epsilon would accidentally license shorting tiny crypto positions.
            let tolerance = max(abs(old), abs(entry.transaction.quantity)).ulp * 8
            guard entry.resultingQuantity >= old - tolerance else {
                throw TradeMutationError.negativePosition
            }
        }
    }
}
