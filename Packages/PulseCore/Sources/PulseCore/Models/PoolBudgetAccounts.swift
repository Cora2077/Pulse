import Foundation

public extension PoolBudgetProjection.Result {
    /// Accounts are calculated separately before totals are displayed together.
    /// Surplus cash or pool capacity in one account cannot erase another's gap.
    static func combiningAccounts(_ results: [Self]) -> Self {
        var combined = Self(
            unvaluablePriceCount: results.reduce(0) { $0 + $1.unvaluablePriceCount },
            rejectedInputCount: results.reduce(0) { $0 + $1.rejectedInputCount },
            rejectedEntryCount: results.reduce(0) { $0 + $1.rejectedEntryCount },
            overSellWarnings: results.flatMap(\.overSellWarnings),
            unsupportedShortCount: results.reduce(0) { $0 + $1.unsupportedShortCount },
            unresolvedPoolPositions: Array(Set(results.flatMap(\.unresolvedPoolPositions)))
        )
        let groups = Dictionary(grouping: results.flatMap(\.currencies), by: \.code)
        combined.currencies = groups.keys.sorted().map { code in
            let rows = groups[code] ?? []
            func sum(_ key: KeyPath<PoolBudgetProjection.CurrencyProjection, Double>) -> Double { rows.reduce(0) { $0 + $1[keyPath: key] } }
            let knownCash = rows.allSatisfy { $0.cashBalance != nil }
            var row = PoolBudgetProjection.CurrencyProjection(
                code: code,
                cashBalance: knownCash ? rows.reduce(0) { $0 + ($1.cashBalance ?? 0) } : nil,
                cashUpdatedAt: knownCash ? rows.compactMap(\.cashUpdatedAt).min() : nil,
                plannedBuyAmount: sum(\.plannedBuyAmount), plannedSellAmount: sum(\.plannedSellAmount),
                availableCash: knownCash ? rows.reduce(0) { $0 + ($1.availableCash ?? 0) } : nil,
                cashShortfall: sum(\.cashShortfall), purchaseBudgetGap: sum(\.purchaseBudgetGap),
                hasOverflow: rows.contains(where: \.hasOverflow),
                holdingsBefore: sum(\.holdingsBefore), holdingsAfter: sum(\.holdingsAfter),
                unvaluableQuantity: rows.reduce(0) { $0 + $1.unvaluableQuantity }
            )
            let pools = Dictionary(grouping: rows.flatMap(\.pools), by: \.pool)
            row.pools = PositionPool.activeCases.compactMap { pool in
                guard let values = pools[pool] else { return nil }
                return .init(pool: pool,
                    heldAmount: values.reduce(0) { $0 + $1.heldAmount },
                    unvaluableQuantity: values.reduce(0) { $0 + $1.unvaluableQuantity },
                    plannedBuyAmount: values.reduce(0) { $0 + $1.plannedBuyAmount },
                    plannedSellAmount: values.reduce(0) { $0 + $1.plannedSellAmount },
                    limit: values.allSatisfy { $0.limit != nil } ? values.reduce(0) { $0 + ($1.limit ?? 0) } : nil,
                    projectedAmount: values.reduce(0) { $0 + $1.projectedAmount },
                    overLimitAmount: values.reduce(0) { $0 + $1.overLimitAmount },
                    needsReconciliation: values.contains(where: \.needsReconciliation))
            }
            let sectors = Dictionary(grouping: rows.flatMap(\.sectors), by: \.name)
            row.sectors = sectors.keys.sorted().map { name in
                let values = sectors[name] ?? []
                return .init(name: name,
                    holdingsBefore: values.reduce(0) { $0 + $1.holdingsBefore },
                    plannedBuyAmount: values.reduce(0) { $0 + $1.plannedBuyAmount },
                    holdingsAfter: values.reduce(0) { $0 + $1.holdingsAfter },
                    unvaluableQuantity: values.reduce(0) { $0 + $1.unvaluableQuantity })
            }
            var holdings: [SymbolID: (name: String, before: Double, after: Double, beforeValue: Double, afterValue: Double)] = [:]
            for accountRow in rows {
                for holding in accountRow.holdings {
                    let old = holdings[holding.symbol] ?? (holding.name, 0, 0, 0, 0)
                    holdings[holding.symbol] = (old.name,
                        old.before + holding.beforeQuantity, old.after + holding.afterQuantity,
                        old.beforeValue + (holding.beforePercent ?? 0) * accountRow.holdingsBefore / 100,
                        old.afterValue + (holding.afterPercent ?? 0) * accountRow.holdingsAfter / 100)
                }
            }
            let reliable = row.unvaluableQuantity == 0 && !row.hasOverflow
            row.holdings = holdings.keys.sorted { $0.description < $1.description }.map { symbol in
                let h = holdings[symbol]!
                return .init(symbol: symbol, name: h.name, beforeQuantity: h.before, afterQuantity: h.after,
                    beforePercent: reliable && row.holdingsBefore > 0 ? h.beforeValue / row.holdingsBefore * 100 : nil,
                    afterPercent: reliable && row.holdingsAfter > 0 ? h.afterValue / row.holdingsAfter * 100 : nil)
            }
            if reliable {
                row.topThreeBefore = row.holdings.compactMap(\.beforePercent).sorted(by: >).prefix(3).reduce(0, +)
                row.topThreeAfter = row.holdings.compactMap(\.afterPercent).sorted(by: >).prefix(3).reduce(0, +)
            }
            let amounts = [row.holdingsBefore, row.holdingsAfter, row.plannedBuyAmount, row.plannedSellAmount,
                           row.cashShortfall, row.purchaseBudgetGap] + [row.cashBalance, row.availableCash].compactMap { $0 }
            row.hasOverflow = row.hasOverflow || !amounts.allSatisfy(\.isFinite)
                || row.pools.contains { ![$0.heldAmount, $0.plannedBuyAmount, $0.plannedSellAmount, $0.projectedAmount, $0.overLimitAmount].allSatisfy(\.isFinite) }
            return row
        }
        return combined
    }
}
