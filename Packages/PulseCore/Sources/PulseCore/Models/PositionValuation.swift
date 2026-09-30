import Foundation

/// One shared view of a position's selected holding cost, realized result,
/// and current market value. `PositionMetrics` remains the average-cost
/// calculation used by existing Core consumers; this type adds the selected
/// cost-basis presentation without changing ledger replay semantics.
public struct PositionValuation: Sendable, Hashable {
    public var quantity: Double
    public var averageCost: Double
    public var costPrice: Double
    public var marketValue: Double
    public var holdingPnL: Double
    public var holdingReturnPercent: Double
    public var realizedPnL: Double
    public var totalPnL: Double
    public var totalFees: Double
    public var todayPnL: Double
    public var todayReturnPercent: Double

    public init?(item: WatchItem, quote: Quote, basis: PositionCostBasis, now: Date = .now) {
        guard let metrics = PositionMetrics(item: item, quote: quote, now: now) else { return nil }

        let costPrice: Double
        switch basis {
        case .average:
            costPrice = metrics.averageCost
        case .diluted:
            costPrice = item.ledger?.dilutedCost ?? metrics.averageCost
        }

        let selectedCostBasis = costPrice * metrics.quantity
        let holdingPnL = metrics.marketValue - selectedCostBasis

        self.quantity = metrics.quantity
        self.averageCost = metrics.averageCost
        self.costPrice = costPrice
        self.marketValue = metrics.marketValue
        self.holdingPnL = holdingPnL
        self.holdingReturnPercent = PositionMetrics.returnPercent(
            pnl: holdingPnL,
            invested: selectedCostBasis
        )
        self.realizedPnL = item.realizedPnL
        // Fees are already included by PositionLedger in open cost and
        // realized results. Do not subtract them a second time here.
        self.totalPnL = metrics.totalPnL + item.realizedPnL
        self.totalFees = item.ledger?.totalFees ?? 0
        self.todayPnL = metrics.todayPnL
        self.todayReturnPercent = metrics.todayReturnPercent
    }
}
