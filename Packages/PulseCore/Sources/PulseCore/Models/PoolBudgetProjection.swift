import Foundation

/// Cash, pool-capacity, and multi-plan dry-run arithmetic.
///
/// This is a pure calculator: it reads positions and plans, returns numbers,
/// and never writes to the store, the ledger, or a quote provider. A preview
/// that could move real money would be a different, much more dangerous thing.
///
/// Three rules shape everything below, and each exists because the obvious
/// alternative quietly lies:
///
/// 1. **Currencies never mix.** There is no FX rate here and no pseudo-total.
///    CNY cash cannot cover a HKD buy, so every figure is reported per
///    `currencyCode`.
/// 2. **Holdings before/after and pool/sector totals are marked-to-quote**,
///    while a fill's cash flow is sized at the *plan* price.
/// 3. **Unknown is not zero.** A missing quote is reported as unvaluable
///    rather than counted as 0, and overflow/invalid input is counted as
///    rejected rather than silently flattened.
public enum PoolBudgetProjection {
    public static let uncategorizedSectorName = "未分类"

    // MARK: - Input

    /// One holding, as the caller sees it.
    ///
    /// `price` is the caller's quote (nil when there is none — a stale or
    /// absent quote must arrive as nil, because this type cannot tell a good
    /// price from a bad one). `poolQuantities` carries only *verified*
    /// allocation shares: a caller that has not reconciled an allocation must
    /// pass an empty dictionary rather than guessing, and the projection will
    /// report the resulting shortfall instead of inventing a pool.
    public struct Position: Sendable, Hashable {
        public let symbol: SymbolID
        public let name: String
        /// Signed. Negative means short; see `unsupportedShort`.
        public let quantity: Double
        public let price: Double?
        public let currencyCode: String?
        public let sector: String?
        /// Per-pool share of the position, in the instrument's own unit.
        /// Pass verified shares only; omit any pool whose share is unknown.
        ///
        /// A caller may still hand in the retired observation purpose — an
        /// allocation written before the retirement is a legitimate input — and
        /// it is folded into `unassigned` here rather than being dropped, so a
        /// legacy position's shares keep adding up instead of disappearing from
        /// the active distribution.
        public let poolQuantities: [PositionPool: Double]

        /// The caller's shares with every retired purpose folded into its active
        /// equivalent. The stored dictionary is left as given so a caller can
        /// still see exactly what it passed.
        public var effectivePoolQuantities: [PositionPool: Double] {
            var result: [PositionPool: Double] = [:]
            for (pool, quantity) in poolQuantities {
                result[pool.effectivePurpose, default: 0] += quantity
            }
            return result
        }

        public init(
            symbol: SymbolID,
            name: String,
            quantity: Double,
            price: Double?,
            currencyCode: String? = nil,
            sector: String? = nil,
            poolQuantities: [PositionPool: Double] = [:]
        ) {
            self.symbol = symbol
            self.name = name
            self.quantity = quantity
            self.price = price
            self.currencyCode = currencyCode
            self.sector = sector
            self.poolQuantities = poolQuantities
        }
    }

    // MARK: - Result

    /// Everything the three budget surfaces need, computed in one pass.
    public struct Result: Sendable, Hashable {
        /// One row per currency that produced any figure. Never merged.
        public var currencies: [CurrencyProjection]
        /// Positions whose quote was nil, non-finite, or non-positive. These
        /// could not be valued; they are *not* worth zero.
        public var unvaluablePriceCount: Int
        /// Positions dropped because their quantity or a pool share overflowed
        /// or was non-finite.
        public var rejectedInputCount: Int
        /// Entries dropped because their plan price or quantity was unusable.
        public var rejectedEntryCount: Int
        /// Sell plans whose remaining quantity exceeds what the position (or
        /// the named pool) actually holds. Each is a warning the caller must
        /// surface; none of them fabricate a short.
        public var overSellWarnings: [OverSellWarning]
        /// Positions with a negative quantity. Shorting is not modelled here.
        public var unsupportedShortCount: Int
        /// Positions carrying unassigned pool shares, i.e. an allocation that
        /// still needs reconciling.
        public var unresolvedPoolPositions: [SymbolID]

        public init(
            currencies: [CurrencyProjection] = [],
            unvaluablePriceCount: Int = 0,
            rejectedInputCount: Int = 0,
            rejectedEntryCount: Int = 0,
            overSellWarnings: [OverSellWarning] = [],
            unsupportedShortCount: Int = 0,
            unresolvedPoolPositions: [SymbolID] = []
        ) {
            self.currencies = currencies
            self.unvaluablePriceCount = unvaluablePriceCount
            self.rejectedInputCount = rejectedInputCount
            self.rejectedEntryCount = rejectedEntryCount
            self.overSellWarnings = overSellWarnings
            self.unsupportedShortCount = unsupportedShortCount
            self.unresolvedPoolPositions = unresolvedPoolPositions
        }

        /// Whether any holding could not be valued. Drives the "incomplete"
        /// badge — an unknown position makes every total below it a floor,
        /// not a fact.
        public var isIncomplete: Bool {
            unvaluablePriceCount > 0 || rejectedInputCount > 0 || rejectedEntryCount > 0
                || !unresolvedPoolPositions.isEmpty || unsupportedShortCount > 0 || !overSellWarnings.isEmpty
        }

        public func currency(_ code: String) -> CurrencyProjection? {
            currencies.first { $0.code == code }
        }
    }

    /// A sell plan that asks for more than the position can deliver.
    public struct OverSellWarning: Sendable, Hashable, Identifiable {
        public enum Scope: Sendable, Hashable {
            /// The whole position cannot cover the sale.
            case position
            /// The named pool's verified share cannot cover the sale.
            case pool(PositionPool)
        }

        public let planID: UUID
        public let symbol: SymbolID
        public let currencyCode: String
        public let scope: Scope
        /// Units the plan still wants to sell.
        public let requested: Double
        /// Units actually available within `scope`.
        public let available: Double

        public var id: String { "\(planID.uuidString)-\(symbol.description)-\(shortfall)" }

        /// How many units have no backing. Always positive.
        public var shortfall: Double { max(0, requested - available) }

        public init(
            planID: UUID,
            symbol: SymbolID,
            currencyCode: String,
            scope: Scope,
            requested: Double,
            available: Double
        ) {
            self.planID = planID
            self.symbol = symbol
            self.currencyCode = currencyCode
            self.scope = scope
            self.requested = requested
            self.available = available
        }
    }

    /// Per-currency figures. `cash` and the plan amounts are *plan-priced*;
    /// market values are *quote-priced*.
    public struct CurrencyProjection: Sendable, Hashable, Identifiable {
        public let code: String

        // Cash
        /// The caller's recorded cash balance, or nil when none was entered.
        /// nil means unknown, and must render as such — not as zero.
        public var cashBalance: Double?
        public var cashUpdatedAt: Date?

        // Plan cash flow, all at plan prices
        /// Total still to be spent by active buy plans (remaining quantity).
        public var plannedBuyAmount: Double
        /// Total that would be raised by active sell plans (remaining
        /// quantity). Reported separately and deliberately *not* added to
        /// available cash: nothing has settled, so it is not spendable.
        public var plannedSellAmount: Double

        // Budget
        /// Cash over the buy plans: balance − buys. nil when the balance is
        /// unknown, because an unknown balance has no gap.
        public var availableCash: Double?
        /// Buys beyond the balance. 0 when covered or unknown; never negative.
        public var cashShortfall: Double
        /// Buys minus the balance, floored at zero — the same number as
        /// `cashShortfall`, named for the budget column.
        public var purchaseBudgetGap: Double
        /// Whether the plan totals plus the recorded balance overflowed
        /// `Double`. When true the money columns are unusable and the caller
        /// should show an error rather than a huge number.
        public var hasOverflow: Bool

        // Holdings
        public var holdingsBefore: Double
        public var holdingsAfter: Double
        /// Quote-priced value of positions excluded because the quote was
        /// unusable. Non-zero means every holdings figure here is incomplete.
        public var unvaluableQuantity: Int

        public var pools: [PoolProjection]
        public var sectors: [SectorProjection]
        public var holdings: [HoldingProjection] = []
        public var topThreeBefore: Double = 0
        public var topThreeAfter: Double = 0

        public var id: String { code }

        public init(
            code: String,
            cashBalance: Double? = nil,
            cashUpdatedAt: Date? = nil,
            plannedBuyAmount: Double = 0,
            plannedSellAmount: Double = 0,
            availableCash: Double? = nil,
            cashShortfall: Double = 0,
            purchaseBudgetGap: Double = 0,
            hasOverflow: Bool = false,
            holdingsBefore: Double = 0,
            holdingsAfter: Double = 0,
            unvaluableQuantity: Int = 0,
            pools: [PoolProjection] = [],
            sectors: [SectorProjection] = []
        ) {
            self.code = code
            self.cashBalance = cashBalance
            self.cashUpdatedAt = cashUpdatedAt
            self.plannedBuyAmount = plannedBuyAmount
            self.plannedSellAmount = plannedSellAmount
            self.availableCash = availableCash
            self.cashShortfall = cashShortfall
            self.purchaseBudgetGap = purchaseBudgetGap
            self.hasOverflow = hasOverflow
            self.holdingsBefore = holdingsBefore
            self.holdingsAfter = holdingsAfter
            self.unvaluableQuantity = unvaluableQuantity
            self.pools = pools
            self.sectors = sectors
        }
    }

    /// One pool's held value, planned inflow, limit, and gap.
    public struct PoolProjection: Sendable, Hashable, Identifiable {
        public let pool: PositionPool
        /// Quote-priced value of the verified shares currently in this pool.
        public var heldAmount: Double
        /// Units in this pool whose quote was unusable.
        public var unvaluableQuantity: Int
        /// Plan-priced buys assigned to this pool (remaining quantity).
        public var plannedBuyAmount: Double
        /// Plan-priced sells assigned to this pool (remaining quantity).
        public var plannedSellAmount: Double
        /// The user's limit, or nil when none was set. nil is "no budget",
        /// not a zero budget.
        public var limit: Double?
        /// held + planned buys. The "after" figure for this pool.
        public var projectedAmount: Double
        /// projected − limit, floored at zero. 0 when there is no limit.
        public var overLimitAmount: Double
        /// Verified shares in this pool sum to less than the position — the
        /// allocation still needs reconciling, so `heldAmount` is a floor.
        public var needsReconciliation: Bool

        public var id: String { pool.rawValue }

        public init(
            pool: PositionPool,
            heldAmount: Double = 0,
            unvaluableQuantity: Int = 0,
            plannedBuyAmount: Double = 0,
            plannedSellAmount: Double = 0,
            limit: Double? = nil,
            projectedAmount: Double = 0,
            overLimitAmount: Double = 0,
            needsReconciliation: Bool = false
        ) {
            self.pool = pool
            self.heldAmount = heldAmount
            self.unvaluableQuantity = unvaluableQuantity
            self.plannedBuyAmount = plannedBuyAmount
            self.plannedSellAmount = plannedSellAmount
            self.limit = limit
            self.projectedAmount = projectedAmount
            self.overLimitAmount = overLimitAmount
            self.needsReconciliation = needsReconciliation
        }

        /// Whether a limit has been recorded at all.
        public var hasLimit: Bool { limit != nil }
    }

    /// One sector's held value and planned inflow.
    public struct SectorProjection: Sendable, Hashable, Identifiable {
        public let name: String
        public var holdingsBefore: Double
        public var plannedBuyAmount: Double
        public var holdingsAfter: Double
        /// Units in this sector whose quote was unusable.
        public var unvaluableQuantity: Int

        public var id: String { name }

        public init(
            name: String,
            holdingsBefore: Double = 0,
            plannedBuyAmount: Double = 0,
            holdingsAfter: Double = 0,
            unvaluableQuantity: Int = 0
        ) {
            self.name = name
            self.holdingsBefore = holdingsBefore
            self.plannedBuyAmount = plannedBuyAmount
            self.holdingsAfter = holdingsAfter
            self.unvaluableQuantity = unvaluableQuantity
        }
    }


    public struct HoldingProjection: Sendable, Hashable, Identifiable {
        public let symbol: SymbolID
        public let name: String
        public let beforeQuantity: Double
        public let afterQuantity: Double
        public let beforePercent: Double?
        public let afterPercent: Double?
        public var id: SymbolID { symbol }
    }

    /// Cash requirements use plan prices; all position projections use the
    /// same current quotes before and after. Pending sales never fund buys.
    public static func calculate(
        positions: [Position], entries: [TradePlanEntry],
        cash: [String: Double] = [:], cashUpdatedAt: [String: Date] = [:],
        poolLimits: [String: [PositionPool: Double]] = [:]
    ) -> Result {
        var result = Result()
        var unique: [SymbolID: Position] = [:]
        var overflowCodes = Set<String>()
        for position in positions where unique[position.symbol] == nil {
            guard position.quantity.isFinite, let code = currency(position.currencyCode) else {
                result.rejectedInputCount += 1
                continue
            }
            unique[position.symbol] = position
            if position.quantity < 0 { result.unsupportedShortCount += 1 }
            if let price = position.price, price.isFinite, price > 0,
               !(abs(position.quantity) * price).isFinite { overflowCodes.insert(code) }
        }
        var seenPlans = Set<UUID>()
        let pending = entries.filter { entry in
            guard seenPlans.insert(entry.id).inserted, entry.plan.status == .active else { return false }
            guard entry.plan.price.isFinite, entry.plan.price > 0,
                  entry.plan.quantity.isFinite, entry.plan.quantity > 0,
                  entry.remainingQuantity.isFinite, currency(entry.symbol.currencyCode) != nil else {
                result.rejectedEntryCount += 1
                return false
            }
            return entry.remainingQuantity > 0
        }
        var afterQuantity = unique.mapValues(\.quantity)
        var beforePools: [SymbolID: [PositionPool: Double]] = [:]
        for position in unique.values where position.quantity >= 0 {
            // A retired purpose is canonicalized before anything counts it, so a
            // legacy input's shares land in `unassigned` and the totals still
            // reconcile against the position quantity.
            let shares = position.effectivePoolQuantities
            let total = shares.values.reduce(0, +)
            let valid = shares.values.allSatisfy { $0.isFinite && $0 >= 0 }
                && total.isFinite && total <= position.quantity + PositionAllocation.quantityTolerance(total, position.quantity)
            if valid {
                beforePools[position.symbol] = shares
                if total < position.quantity - PositionAllocation.quantityTolerance(total, position.quantity) {
                    result.unresolvedPoolPositions.append(position.symbol)
                }
            } else {
                if !shares.isEmpty { result.rejectedInputCount += 1 }
                if position.quantity > 0 { result.unresolvedPoolPositions.append(position.symbol) }
                beforePools[position.symbol] = [:]
            }
        }
        var afterPools = beforePools
        var remainingActualPools = beforePools
        for entry in pending where entry.plan.kind == .buy {
            guard (unique[entry.symbol]?.quantity ?? 0) >= 0 else { continue }
            let code = entry.symbol.currencyCode
            let next = (afterQuantity[entry.symbol] ?? 0) + entry.remainingQuantity
            guard next.isFinite else { overflowCodes.insert(code); continue }
            afterQuantity[entry.symbol] = next
            let pool = (entry.plan.positionPool ?? .unassigned).effectivePurpose
            let poolQuantity = (afterPools[entry.symbol]?[pool] ?? 0) + entry.remainingQuantity
            if poolQuantity.isFinite { afterPools[entry.symbol, default: [:]][pool] = poolQuantity }
            else { overflowCodes.insert(code) }
        }
        // Validate combined sales against actual shares. A future buy is not
        // available for sale until it has really filled, regardless of order.
        let sales = Dictionary(grouping: pending.filter { $0.plan.kind == .sell }, by: \.symbol)
        for (symbol, plans) in sales {
            let held = unique[symbol]?.quantity ?? 0
            guard held >= 0 else { continue }
            let total = plans.reduce(0) { $0 + $1.remainingQuantity }
            if !total.isFinite { overflowCodes.insert(symbol.currencyCode) }
            guard total.isFinite, total <= held + PositionAllocation.quantityTolerance(total, held) else {
                for entry in plans {
                    result.overSellWarnings.append(.init(planID: entry.id, symbol: symbol,
                        currencyCode: symbol.currencyCode, scope: .position,
                        requested: total.isFinite ? total : .greatestFiniteMagnitude, available: held))
                }
                continue
            }
            // A sale limit still naming the retired observation purpose is
            // canonicalized with everything else, so a legacy sell competes for
            // the same `unassigned` shares it is displayed against rather than
            // reading an always-empty retired bucket as zero availability.
            let assigned = Dictionary(
                grouping: plans.filter { $0.plan.positionPool != nil },
                by: { $0.plan.positionPool!.effectivePurpose }
            )
            var excluded = Set<UUID>()
            for (pool, poolPlans) in assigned {
                let requested = poolPlans.reduce(0) { $0 + $1.remainingQuantity }
                let available = beforePools[symbol]?[pool] ?? 0
                if requested > available + PositionAllocation.quantityTolerance(requested, available) {
                    for entry in poolPlans {
                        excluded.insert(entry.id)
                        result.overSellWarnings.append(.init(planID: entry.id, symbol: symbol,
                            currencyCode: symbol.currencyCode, scope: .pool(pool),
                            requested: requested, available: available))
                    }
                }
            }
            // An unspecified sale changes total shares, but its pool distribution
            // needs the user to reconcile it rather than guessing an allocation.
            let ordered = plans.filter { $0.plan.positionPool != nil } + plans.filter { $0.plan.positionPool == nil }
            for entry in ordered where !excluded.contains(entry.id) {
                afterQuantity[symbol] = max(0, (afterQuantity[symbol] ?? held) - entry.remainingQuantity)
                guard let rawPool = entry.plan.positionPool else {
                    if !result.unresolvedPoolPositions.contains(symbol) { result.unresolvedPoolPositions.append(symbol) }
                    continue
                }
                let pool = rawPool.effectivePurpose
                let available = remainingActualPools[symbol]?[pool] ?? 0
                let consumed = min(available, entry.remainingQuantity)
                remainingActualPools[symbol, default: [:]][pool] = max(0, available - consumed)
                afterPools[symbol, default: [:]][pool] = max(0, (afterPools[symbol]?[pool] ?? 0) - consumed)
            }
        }
        // A plan without a holding still needs its instrument's current quote;
        // when the caller omitted it, there is deliberately no price fallback.
        for entry in pending where unique[entry.symbol] == nil {
            unique[entry.symbol] = Position(symbol: entry.symbol, name: entry.symbol.displayCode,
                quantity: 0, price: nil, currencyCode: entry.symbol.currencyCode)
        }
        let before = allocation(unique: unique, quantities: unique.mapValues(\.quantity))
        let after = allocation(unique: unique, quantities: afterQuantity)
        overflowCodes.formUnion(before.excludedUnrepresentableCurrencyCodes)
        overflowCodes.formUnion(after.excludedUnrepresentableCurrencyCodes)
        let codes = Set(unique.values.compactMap { currency($0.currencyCode) }
            + pending.map { $0.symbol.currencyCode }
            + cash.keys.compactMap(currency) + poolLimits.keys.compactMap(currency))
        for code in codes.sorted() {
            var overflow = overflowCodes.contains(code)
            func sum(_ values: [Double]) -> Double {
                let value = values.reduce(0, +)
                if !value.isFinite { overflow = true; return .greatestFiniteMagnitude }
                return value
            }
            let currencyPositions = unique.values.filter { currency($0.currencyCode) == code }
            let currencyPlans = pending.filter { $0.symbol.currencyCode == code }
            let buys = currencyPlans.filter { $0.plan.kind == .buy }
            let sells = currencyPlans.filter { $0.plan.kind == .sell }
            let buyAmount = sum(buys.map(\.remainingEstimatedAmount))
            let sellAmount = sum(sells.map(\.remainingEstimatedAmount))
            let balance = cash[code].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if cash[code] != nil && balance == nil { result.rejectedInputCount += 1 }
            let available = balance.map { $0 - buyAmount }
            if available?.isFinite == false { overflow = true }
            let beforeCurrency = before.currencies.first { $0.code == code }
            let afterCurrency = after.currencies.first { $0.code == code }
            let beforeHoldings = beforeCurrency?.holdings ?? []
            let afterHoldings = afterCurrency?.holdings ?? []
            let missing = currencyPositions.filter { position in
                guard position.quantity != 0 || (afterQuantity[position.symbol] ?? 0) != 0 else { return false }
                return usablePrice(position.price) == nil
            }.count
            result.unvaluablePriceCount += missing
            let unresolved = currencyPositions.contains { result.unresolvedPoolPositions.contains($0.symbol) }
            var pools: [PoolProjection] = []
            // Only the active purposes get a row. The retired observation
            // purpose has no bucket of its own: its shares were canonicalized
            // into `unassigned` above, where they still count.
            for pool in PositionPool.activeCases {
                let held = sum(currencyPositions.compactMap { p in
                    usablePrice(p.price).map { $0 * (beforePools[p.symbol]?[pool] ?? 0) }
                })
                let projected = sum(currencyPositions.compactMap { p in
                    usablePrice(p.price).map { $0 * (afterPools[p.symbol]?[pool] ?? 0) }
                })
                let plannedBuy = sum(buys.filter { ($0.plan.positionPool ?? .unassigned).effectivePurpose == pool }.map(\.remainingEstimatedAmount))
                let plannedSell = sum(sells.filter { ($0.plan.positionPool ?? .unassigned).effectivePurpose == pool }.map(\.remainingEstimatedAmount))
                let limit = poolLimits[code]?[pool].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                let capacity = held + plannedBuy
                if !capacity.isFinite { overflow = true }
                pools.append(.init(pool: pool, heldAmount: held,
                    unvaluableQuantity: currencyPositions.filter {
                        usablePrice($0.price) == nil && ((beforePools[$0.symbol]?[pool] ?? 0) > 0 || (afterPools[$0.symbol]?[pool] ?? 0) > 0)
                    }.count,
                    plannedBuyAmount: plannedBuy, plannedSellAmount: plannedSell, limit: limit,
                    projectedAmount: projected, overLimitAmount: limit.map { max(0, capacity - $0) } ?? 0,
                    needsReconciliation: unresolved))
            }
            let names = Set(currencyPositions.map { sector($0.sector) })
            var sectors: [SectorProjection] = []
            for name in names.sorted() {
                let symbols = Set(currencyPositions.filter { sector($0.sector) == name }.map(\.symbol))
                sectors.append(.init(name: name,
                    holdingsBefore: sum(beforeHoldings.filter { symbols.contains($0.symbol) }.map(\.exposure)),
                    plannedBuyAmount: sum(buys.filter { symbols.contains($0.symbol) }.map(\.remainingEstimatedAmount)),
                    holdingsAfter: sum(afterHoldings.filter { symbols.contains($0.symbol) }.map(\.exposure)),
                    unvaluableQuantity: currencyPositions.filter {
                        symbols.contains($0.symbol) && usablePrice($0.price) == nil && ($0.quantity != 0 || (afterQuantity[$0.symbol] ?? 0) != 0)
                    }.count))
            }
            var row = CurrencyProjection(code: code, cashBalance: balance, cashUpdatedAt: cashUpdatedAt[code],
                plannedBuyAmount: buyAmount, plannedSellAmount: sellAmount,
                availableCash: available?.isFinite == true ? available : nil,
                cashShortfall: available.map { max(0, -$0) } ?? 0,
                purchaseBudgetGap: available.map { max(0, -$0) } ?? 0,
                hasOverflow: overflow, holdingsBefore: beforeCurrency?.totalExposure ?? 0,
                holdingsAfter: afterCurrency?.totalExposure ?? 0, unvaluableQuantity: missing,
                pools: pools, sectors: sectors)
            row.holdings = currencyPositions.filter {
                $0.quantity != 0 || (afterQuantity[$0.symbol] ?? 0) != 0
            }.map { p in
                HoldingProjection(symbol: p.symbol, name: p.name, beforeQuantity: p.quantity,
                    afterQuantity: afterQuantity[p.symbol] ?? p.quantity,
                    beforePercent: beforeHoldings.first { $0.symbol == p.symbol }?.percent,
                    afterPercent: afterHoldings.first { $0.symbol == p.symbol }?.percent)
            }.sorted { $0.name < $1.name }
            row.topThreeBefore = beforeCurrency?.topThreeConcentration ?? 0
            row.topThreeAfter = afterCurrency?.topThreeConcentration ?? 0
            result.currencies.append(row)
        }
        result.unresolvedPoolPositions.sort { $0.description < $1.description }
        return result
    }

    private static func allocation(unique: [SymbolID: Position], quantities: [SymbolID: Double]) -> PortfolioAllocation.Result {
        PortfolioAllocation.calculate(positions: unique.values.map {
            .init(symbol: $0.symbol, name: $0.name, quantity: quantities[$0.symbol] ?? $0.quantity,
                price: $0.price, currencyCode: $0.currencyCode)
        })
    }

    private static func currency(_ value: String?) -> String? {
        guard let code = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !code.isEmpty else { return nil }
        return code
    }

    private static func usablePrice(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func sector(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? uncategorizedSectorName : text
    }
}
