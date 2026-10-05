import Foundation

/// Complete flat-to-flat position rounds, grouped by user-authored strategy and currency.
/// Partial exits remain one sample. Calibrations and still-open rounds are excluded.
public struct TradeStrategySummary: Identifiable, Sendable {
    public let strategy: String
    public let currencyCode: String
    public let sampleCount: Int
    public let realizedPnL: Double?
    public let wins: Int
    public let losses: Int
    public let averageWin: Double?
    public let averageLoss: Double?
    public let followedPlanYesCount: Int
    public let followedPlanNoCount: Int
    public let missingFeeCount: Int
    public var id: String { "\(currencyCode):\(strategy)" }
    public var winPercent: Double? {
        guard sampleCount > 0, realizedPnL != nil else { return nil }
        return Double(wins) / Double(sampleCount) * 100
    }
    public var payoffRatio: Double? {
        guard realizedPnL != nil, let averageWin, let averageLoss, averageLoss > 0 else { return nil }
        let value = averageWin / averageLoss
        return value.isFinite ? value : nil
    }
    public var followedPlanPercent: Double? {
        let count = followedPlanYesCount + followedPlanNoCount
        return count > 0 ? Double(followedPlanYesCount) / Double(count) * 100 : nil
    }

    public static func make(from items: [WatchItem], query: String = "", selectedMonth: Date? = nil,
                            calendar: Calendar = .current) -> [Self] {
        struct Round {
            var strategies = Set<String>()
            var pnl = 0.0
            var yes = 0
            var no = 0
            var missingFees = 0
            var completeOpening = true
            mutating func record(_ trade: PositionTransaction, realized: Double?) {
                if let label = trade.review?.strategy?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    strategies.insert(label)
                }
                pnl += realized ?? 0
                if trade.fee == nil || !trade.hasValidFee { missingFees += 1 }
                if trade.review?.followedPlan == true { yes += 1 }
                if trade.review?.followedPlan == false { no += 1 }
            }
        }
        struct Key: Hashable { let strategy: String; let currency: String }
        var grouped: [Key: [Round]] = [:]
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for item in items where needle.isEmpty || item.symbol.displayCode.localizedCaseInsensitiveContains(needle)
            || item.resolvedDisplayName.localizedCaseInsensitiveContains(needle) {
            var previous = 0.0
            var round = Round()
            for entry in item.ledger?.entries ?? [] {
                let trade = entry.transaction
                let next = entry.resultingQuantity
                if trade.kind == .adjustment {
                    round = Round(completeOpening: false)
                    previous = next
                    continue
                }
                if previous == 0 { round = Round() }
                round.record(trade, realized: entry.realizedPnL)
                let crossed = previous != 0 && next != 0 && (previous > 0) != (next > 0)
                if next == 0 || crossed {
                    if round.completeOpening,
                       selectedMonth.map({ calendar.isDate(trade.date, equalTo: $0, toGranularity: .month) }) ?? true {
                        let strategy = round.strategies.count > 1 ? "混合策略" : round.strategies.first ?? "未分类"
                        grouped[Key(strategy: strategy, currency: item.symbol.currencyCode), default: []].append(round)
                    }
                    round = Round()
                    // A reversal closes one round and opens the next. Its ledger P&L/review
                    // belongs to the closed side; carry only its strategy to the new side.
                    if crossed, let strategy = trade.review?.strategy?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !strategy.isEmpty { round.strategies.insert(strategy) }
                }
                previous = next
            }
        }
        return grouped.map { key, rounds in
            let valid = rounds.map(\.pnl).filter(\.isFinite)
            let positive = valid.filter { $0 > 0 }
            let negative = valid.filter { $0 < 0 }.map { abs($0) }
            let total = valid.reduce(0, +)
            let winSum = positive.reduce(0, +), lossSum = negative.reduce(0, +)
            return Self(strategy: key.strategy, currencyCode: key.currency, sampleCount: rounds.count,
                        realizedPnL: valid.count == rounds.count && total.isFinite ? total : nil,
                        wins: positive.count, losses: negative.count,
                        averageWin: !positive.isEmpty && winSum.isFinite ? winSum / Double(positive.count) : nil,
                        averageLoss: !negative.isEmpty && lossSum.isFinite ? lossSum / Double(negative.count) : nil,
                        followedPlanYesCount: rounds.reduce(0) { $0 + $1.yes },
                        followedPlanNoCount: rounds.reduce(0) { $0 + $1.no },
                        missingFeeCount: rounds.reduce(0) { $0 + $1.missingFees })
        }.sorted { $0.currencyCode == $1.currencyCode ? $0.strategy < $1.strategy : $0.currencyCode < $1.currencyCode }
    }
}
