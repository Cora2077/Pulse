import SwiftUI
import PulseCore
import PulseUI

/// The pool board's capital surfaces.
///
/// All of them read the same `PoolBudgetProjection` result, so a number in the
/// condensed pill and the same number in the expanded two-track panel cannot
/// disagree. The only writes reachable from here are the cash/limit settings in
/// `PoolBudgetEditSheet`; nothing on these screens moves a position, a plan, or
/// a trade.
///
/// The three permanently-visible notices the board used to carry (sync
/// conflict, reconciliation, budget completeness) were folded into the action
/// bar's warning chip. The underlying data — and every action those banners
/// offered — is unchanged; only the always-on screen space is gone.

// MARK: - Shared plumbing

/// Turns the live app state into the projection's inputs, once, for every
/// screen that needs it.
struct PoolBudgetInput {
    let positions: [PoolBudgetProjection.Position]
    let entries: [TradePlanEntry]
    let cash: [String: Double]
    let cashUpdatedAt: [String: Date]
    let poolLimits: [String: [PositionPool: Double]]
    let referenceQuoteCount: Int
    private var accountResults: [PoolBudgetProjection.Result]?

    @MainActor
    init(appState: AppState, currencyFilter: String, planIDs: Set<UUID>? = nil,
         accountFilter: BrokerageAccountID? = nil, allAccounts: Bool = false) {
        if allAccounts {
            self = Self.boardInput(appState: appState, currencyFilter: currencyFilter, planIDs: planIDs, accountFilter: accountFilter)
            return
        }
        let filter = PoolBudgetFilter(currencyFilter)
        let items = appState.watchlist.allItems

        var selected = appState.watchlist.tradePlanEntries.filter {
            $0.plan.status == .active && filter.includes(Self.currency(for: $0.symbol, appState: appState))
        }
        if let planIDs {
            // The preview's whole point: same quote snapshot, same positions,
            // same cash — only the plan set changes.
            selected = selected.filter { planIDs.contains($0.id) && $0.remainingQuantity > 0 }
        }
        entries = selected

        var referenceQuotes = 0
        positions = items.compactMap { item -> PoolBudgetProjection.Position? in
            let code = Self.currency(for: item.symbol, appState: appState)
            guard filter.includes(code) else { return nil }
            guard item.supportsPosition else { return nil }
            let quote = appState.market.quote(for: item.symbol)
            // Closed-market quotes remain useful as labelled reference estimates.
            let price: Double? = {
                guard let quote, quote.price.isFinite, quote.price > 0,
                      quote.timestamp.timeIntervalSince1970.isFinite,
                      quote.timestamp <= Date().addingTimeInterval(30) else { return nil }
                if !TradingQuoteHealth.isCurrent(quote), item.positionQuantity != 0 || !item.plans.isEmpty {
                    referenceQuotes += 1
                }
                return quote.price
            }()
            return PoolBudgetProjection.Position(
                symbol: item.symbol,
                name: item.resolvedDisplayName,
                quantity: item.positionQuantity,
                price: price,
                currencyCode: code,
                sector: item.tradingProfile?.sector,
                poolQuantities: Self.verifiedPoolShares(of: item),
                portions: Self.verifiedPortions(of: item)
            )
        }

        referenceQuoteCount = referenceQuotes
        cash = appState.poolBudgets.cashBalances.reduce(into: [:]) { result, pair in
            guard filter.includes(pair.key) else { return }
            result[pair.key] = pair.value.amount
        }
        cashUpdatedAt = appState.poolBudgets.cashBalances.reduce(into: [:]) { result, pair in
            guard filter.includes(pair.key) else { return }
            result[pair.key] = pair.value.updatedAt
        }
        poolLimits = appState.poolBudgets.poolLimits.reduce(into: [:]) { result, pair in
            guard filter.includes(pair.key) else { return }
            result[pair.key] = pair.value
        }
    }

    private init(positions: [PoolBudgetProjection.Position], entries: [TradePlanEntry],
                 cash: [String: Double], cashUpdatedAt: [String: Date],
                 poolLimits: [String: [PositionPool: Double]], referenceQuoteCount: Int,
                 accountResults: [PoolBudgetProjection.Result]) {
        self.positions = positions; self.entries = entries; self.cash = cash
        self.cashUpdatedAt = cashUpdatedAt; self.poolLimits = poolLimits
        self.referenceQuoteCount = referenceQuoteCount; self.accountResults = accountResults
    }

    @MainActor
    private static func boardInput(appState: AppState, currencyFilter: String, planIDs: Set<UUID>?,
                                   accountFilter: BrokerageAccountID?) -> Self {
        let filter = PoolBudgetFilter(currencyFilter)
        let records = BrokerageBoardReader.records(store: appState.watchlist)
        let candidateEntries = BrokerageBoardReader.entries(store: appState.watchlist).filter {
            $0.plan.status == .active && filter.includes($0.symbol.currencyCode)
                && (planIDs == nil || planIDs!.contains($0.id))
        }
        // Which group consumes each bound plan.
        //
        // A binding (`positionPortionID`) names one exact card. The plan's own
        // ledger is where the write lands, but the card it can *reach* is the
        // one it names — the verified card inside that same ledger. Its display
        // attribution (`brokerageAccountID ?? owner ledger`) decides which
        // projection group consumes the plan, so the row the plan is judged
        // against always contains that card.
        //
        // This is a routing decision only. It never moves a share between
        // groups and never adds one anywhere: each group still consumes a card
        // solely through that card's own display attribution below, so a
        // holding is counted exactly once, in exactly the group its label names.
        let projections = Self.projectionGroups(entries: candidateEntries, records: records)
        let entries = candidateEntries.filter { accountFilter == nil || projections[ProjectionPlanKey($0)] == accountFilter }
        let accounts = accountFilter.map { [$0] } ?? BrokerageAccountID.allCases
        var results: [PoolBudgetProjection.Result] = []
        var allPositions: [PoolBudgetProjection.Position] = []
        var referenceSymbols = Set<SymbolID>()
        for account in accounts {
            let plans = entries.filter { projections[ProjectionPlanKey($0)] == account }
            let planSymbols = Set(plans.map(\.symbol))
            // The bound cards whose plan projects into this group. A card only
            // qualifies when a selected bound plan names it *and* the plan was
            // written in the ledger that owns the card: a same-id card in
            // another ledger must never satisfy a plan whose own ledger holds
            // no such card.
            let boundCards = Set(entries.compactMap { entry -> BoundPortionKey? in
                guard projections[ProjectionPlanKey(entry)] == account, let portionID = entry.plan.positionPortionID,
                      let owner = entry.accountID else { return nil }
                return BoundPortionKey(accountID: owner, symbol: entry.symbol, portionID: portionID)
            })
            var grouped: [SymbolID: (item: WatchItem, quantity: Double, pools: [PositionPool: Double], portions: [PositionPortion])] = [:]
            for record in records {
                let item = record.item
                guard item.supportsPosition, filter.includes(item.symbol.currencyCode) else { continue }
                // Totals always use the existing attribution. Bound plans
                // only add exact source metadata; they never add/remove shares.
                let shares = item.positionAccountAttribution(enclosingAccountID: record.accountID)[account] ?? [:]
                let boundPortions = Self.verifiedPortions(of: item).filter { portion in
                    Self.projectedAccount(of: portion, in: record) == account
                        && boundCards.contains(BoundPortionKey(accountID: record.accountID,
                                                              symbol: item.symbol, portionID: portion.id))
                }
                let quantity = shares.values.reduce(0, +)
                // A plan-bearing symbol of this ledger keeps its row even when
                // its attributed shares landed in another group, so a sell plan
                // is still visible next to the cards it can reach.
                guard quantity != 0 || (record.accountID == account && planSymbols.contains(item.symbol)) else { continue }
                var old = grouped[item.symbol] ?? (item, 0, [:], [])
                old.quantity += quantity
                if !item.positionAllocationNeedsReconciliation {
                    for (pool, value) in shares { old.pools[pool, default: 0] += value }
                }
                old.portions += boundPortions
                grouped[item.symbol] = old
            }
            let positions = grouped.values.map { value in
                let quote = appState.market.quote(for: value.item.symbol)
                let price = quote.flatMap { q -> Double? in
                    guard q.price.isFinite, q.price > 0, q.timestamp.timeIntervalSince1970.isFinite,
                          q.timestamp <= Date().addingTimeInterval(30) else { return nil }
                    if !TradingQuoteHealth.isCurrent(q) { referenceSymbols.insert(value.item.symbol) }
                    return q.price
                }
                return PoolBudgetProjection.Position(symbol: value.item.symbol, name: value.item.resolvedDisplayName,
                    quantity: value.quantity, price: price, currencyCode: value.item.symbol.currencyCode,
                    sector: value.item.tradingProfile?.sector, poolQuantities: value.pools,
                    portions: value.portions)
            }
            let balances = appState.poolBudgets.cashBalances(for: account).filter { filter.includes($0.key) }
            var limits: [String: [PositionPool: Double]] = [:]
            for limit in appState.watchlist.brokerageSettings(for: account)?.poolLimits ?? [] where filter.includes(limit.currency) {
                limits[limit.currency, default: [:]][limit.pool] = limit.amount
            }
            // Empty accounts do not make another account's recorded cash unknown.
            guard !positions.isEmpty || !plans.isEmpty || !balances.isEmpty || !limits.isEmpty else { continue }
            let cash = balances.mapValues(\.amount), dates = balances.mapValues(\.updatedAt)
            results.append(PoolBudgetProjection.calculate(positions: positions, entries: plans,
                cash: cash, cashUpdatedAt: dates, poolLimits: limits))
            allPositions += positions
        }
        let combined = PoolBudgetProjection.Result.combiningAccounts(results)
        let cash = Dictionary(uniqueKeysWithValues: combined.currencies.compactMap { c in c.cashBalance.map { (c.code, $0) } })
        let dates = Dictionary(uniqueKeysWithValues: combined.currencies.compactMap { c in c.cashUpdatedAt.map { (c.code, $0) } })
        return Self(positions: allPositions, entries: entries, cash: cash, cashUpdatedAt: dates, poolLimits: [:],
            referenceQuoteCount: referenceSymbols.count, accountResults: results)
    }

    @MainActor
    private static func currency(for symbol: SymbolID, appState: AppState) -> String {
        symbol.currencyCode.uppercased()
    }

    // MARK: Bound-plan projection groups

    /// One bound plan's plan id, paired with the group that consumes it.
    private struct ProjectionPlanKey: Hashable {
        let accountID: BrokerageAccountID
        let symbol: SymbolID
        let planID: UUID

        init(_ entry: TradePlanEntry) {
            accountID = entry.accountID ?? .unassigned
            symbol = entry.symbol
            planID = entry.id
        }
    }
    private typealias PlanProjections = [ProjectionPlanKey: BrokerageAccountID]

    /// The card a bound plan names, together with the ledger and instrument it
    /// must be found in. The ledger is what stops a same-id card elsewhere from
    /// satisfying the binding.
    private struct BoundPortionKey: Hashable {
        let accountID: BrokerageAccountID
        let symbol: SymbolID
        let portionID: UUID
    }

    /// The group a verified card projects into: its own display label when it
    /// carries one, otherwise the ledger it was read out of. This is the *same*
    /// fallback `positionAccountAttribution` applies, so a card's group here and
    /// its contribution to the per-label totals can never disagree.
    private static func projectedAccount(of portion: PositionPortion,
                                        in record: BrokerageBoardItem) -> BrokerageAccountID {
        portion.brokerageAccountID ?? record.accountID
    }

    /// Where each bound entry's plan projects.
    ///
    /// The lookup is deliberately exact: the named card must exist among the
    /// *verified* cards of a record in the plan's own ledger carrying the same
    /// instrument. When it does, the card's group consumes the plan. When it
    /// does not — a stale binding, an unverified allocation, or a plan whose
    /// ledger holds no such card — the plan falls back to its owner ledger with
    /// no source, which the projection reports as an over-sell rather than
    /// quietly funding it from a card in another book.
    ///
    /// `entry.accountID` is never rewritten: it stays the ledger the plan was
    /// written in, which is where any fill will be recorded.
    @MainActor
    private static func projectionGroups(entries: [TradePlanEntry],
                                         records: [BrokerageBoardItem]) -> PlanProjections {
        var portionOwners: [BoundPortionKey: BrokerageAccountID] = [:]
        for record in records {
            for portion in verifiedPortions(of: record.item) {
                let key = BoundPortionKey(accountID: record.accountID, symbol: record.item.symbol,
                                          portionID: portion.id)
                portionOwners[key] = projectedAccount(of: portion, in: record)
            }
        }
        var projections: PlanProjections = [:]
        for entry in entries { projections[ProjectionPlanKey(entry)] = entry.accountID ?? .unassigned }
        for entry in entries {
            // An entry with no ledger cannot name a card in one; it keeps the
            // unassigned group, which is where such a plan is displayed.
            guard let portionID = entry.plan.positionPortionID, let ledger = entry.accountID else { continue }
            let key = BoundPortionKey(accountID: ledger, symbol: entry.symbol, portionID: portionID)
            projections[ProjectionPlanKey(entry)] = portionOwners[key] ?? ledger
        }
        return projections
    }

    /// Only a *verified* allocation yields pool shares. An allocation that
    /// still needs reconciliation contributes nothing, so the projection
    /// reports a shortfall instead of splitting the position on a guess.
    @MainActor
    private static func verifiedPoolShares(of item: WatchItem) -> [PositionPool: Double] {
        guard let allocation = verifiedAllocation(of: item) else { return [:] }
        var shares: [PositionPool: Double] = [:]
        for portion in allocation.portions {
            shares[portion.pool, default: 0] += portion.quantity
        }
        return shares
    }

    /// The exact cards a *verified* allocation holds for this item.
    ///
    /// The projection needs the cards, not just their per-pool sum, because a
    /// sell plan bound to one card can only be checked against that card. The
    /// gate is deliberately the same one `verifiedPoolShares` uses — a
    /// reconciled allocation whose sources still match — so a caller can never
    /// hand the calculator a card it would not also have counted in the pool
    /// totals. An unverified allocation yields `[]`, which reads downstream as
    /// "no live source" rather than as a fallback to a sibling card.
    @MainActor
    private static func verifiedPortions(of item: WatchItem) -> [PositionPortion] {
        verifiedAllocation(of: item)?.portions ?? []
    }

    @MainActor
    private static func verifiedAllocation(of item: WatchItem) -> PositionAllocation? {
        guard item.positionQuantity > 0,
              !item.positionAllocationNeedsReconciliation,
              let allocation = item.positionAllocation,
              allocation.isValid,
              allocation.hasMatchingSources(for: item) else { return nil }
        return allocation
    }

    func calculate() -> PoolBudgetProjection.Result {
        if let accountResults { return .combiningAccounts(accountResults) }
        return PoolBudgetProjection.calculate(
            positions: positions,
            entries: entries,
            cash: cash,
            cashUpdatedAt: cashUpdatedAt,
            poolLimits: poolLimits
        )
    }
}

/// `"ALL"`, `""`, and `"*"` all mean every currency; anything else is one code.
private struct PoolBudgetFilter {
    private let code: String?

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        code = (trimmed.isEmpty || trimmed == "ALL" || trimmed == "*") ? nil : trimmed
    }

    func includes(_ currency: String) -> Bool {
        guard let code else { return true }
        return currency.uppercased() == code
    }
}

/// A money figure that renders an unknown value as a word, never as "0".
struct BudgetMoney: View {
    let value: Double?
    let currency: String
    var placeholder: String = PulseLocalization.localizedString("poolBudget.placeholder.notSet")
    var assumed = false

    var body: some View {
        if let value, value.isFinite {
            Text(PoolAmountText.money(value, currency: currency, assumed: assumed))
                .monospacedDigit()
        } else {
            Text(placeholder).foregroundStyle(.secondary)
        }
    }
}

/// Every state of one projection that must not be silently flattened into a
/// number, in the order the reader meets them. Rendered inside the warning
/// list, never as an always-on banner.
enum PoolBudgetNotice {
    static func messages(_ result: PoolBudgetProjection.Result) -> [String] {
        var lines: [String] = []
        if result.unvaluablePriceCount > 0 {
            lines.append(PulseLocalization.localizedString("poolBudget.notice.unpriced", result.unvaluablePriceCount))
        }
        if result.rejectedInputCount > 0 || result.rejectedEntryCount > 0 {
            lines.append(PulseLocalization.localizedString("poolBudget.notice.rejected",
                            result.rejectedInputCount + result.rejectedEntryCount))
        }
        if !result.unresolvedPoolPositions.isEmpty {
            lines.append(PulseLocalization.localizedString("poolBudget.notice.unresolved", result.unresolvedPoolPositions.count))
        }
        if result.unsupportedShortCount > 0 {
            lines.append(PulseLocalization.localizedString("poolBudget.notice.short", result.unsupportedShortCount))
        }
        if !result.overSellWarnings.isEmpty {
            lines.append(PulseLocalization.localizedString("poolBudget.notice.overSell", result.overSellWarnings.count))
        }
        return lines
    }
}

// MARK: - Capital panel

/// The capital overview: one always-visible block per currency, in the order
/// the reader asks the questions — what is it worth, where does it sit, what
/// does the plan do to it, and what cash backs that plan.
///
/// There is no collapsed state and no second summary surface. The block is
/// drawn from the projection the board and the pool gauges already share, so
/// nothing here recomputes a total; the only writes reachable from it are the
/// cash and pool-limit settings in `PoolBudgetEditSheet`.
///
/// The holdings total is deliberately independent of pool *allocation*: a
/// position whose split still needs reconciling has a perfectly known market
/// value, and suppressing it would hide a fact that is not in doubt. What the
/// total really depends on is an unusable quote and arithmetic overflow, so
/// those are the two things that withhold a number here.
struct CapitalPanel: View {
    /// The projection this panel displays. It is owned by the caller so the
    /// board, the capital panel and the pool gauges all read one calculation of
    /// one selected plan set — the panel never recomputes over a wider set.
    let result: PoolBudgetProjection.Result
    var referenceQuoteCount = 0
    /// Preview mode: the after-state is drawn as an assumption, never as fact.
    var isAssumed = false
    var editingAccountID: BrokerageAccountID?
    /// Preview mode is reached from the gap chip, which selects plans; the
    /// panel still may edit cash and limits there (settings only).
    var onRequestGapPreview: ((String) -> Void)?
    var unassignedSellCurrencies: Set<String> = []

    @Environment(AppState.self) private var appState
    @State private var editingCurrency: EditingCurrency?

    var body: some View {
        let currencies = result.currencies.filter(Self.hasContent)
        VStack(alignment: .leading, spacing: 8) {
            header
            if currencies.isEmpty {
                Text(PulseLocalization.localizedString("poolBudget.empty.noCurrency"))
                    .font(PoolType.label).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(currencies) { currency in
                    if currency.hasOverflow {
                        Text(currency.code + " · " + PulseLocalization.localizedString("poolBudget.currency.invalidAmounts"))
                            .font(PoolType.label).foregroundStyle(.orange)
                    } else {
                        currencyBlock(currency, blockedSells: result.overSellWarnings.filter {
                            $0.currencyCode == currency.code
                        })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editingCurrency) {
            PoolBudgetEditSheet(currency: $0.code, account: editingAccountID ?? appState.poolBudgets.accountID)
        }
    }

    /// Watched instruments with no holdings or plans do not create an empty
    /// currency panel; an unknown valuation or recorded zero cash still does.
    static func hasContent(_ currency: PoolBudgetProjection.CurrencyProjection) -> Bool {
        currency.hasOverflow || currency.holdingsBefore != 0 || currency.holdingsAfter != 0
            || currency.unvaluableQuantity > 0 || currency.plannedBuyAmount > 0
            || currency.plannedSellAmount > 0 || currency.cashBalance != nil
            || currency.pools.contains { $0.limit != nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(PulseLocalization.localizedString("poolBudget.header.title"))
                .font(PoolType.labelMedium).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if referenceQuoteCount > 0 {
                Text(PulseLocalization.localizedString("poolBudget.header.referenceQuotes"))
                    .font(PoolType.label).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: One currency

    private func currencyBlock(_ currency: PoolBudgetProjection.CurrencyProjection,
                               blockedSells: [PoolBudgetProjection.OverSellWarning]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            totalRow(currency)
            distribution(currency)
            if isAssumed, afterIsReliable(currency) { afterTrack(currency) }
            legend(currency)
            cashFlow(currency, blockedSells: blockedSells)
            if let note = localNote(currency, blockedSells: blockedSells) {
                Text(note.text).font(PoolType.label)
                    .foregroundStyle(note.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            if isAssumed, !afterIsReliable(currency), currency.plannedBuyAmount > 0,
               let onRequestGapPreview {
                Button(PulseLocalization.localizedString("poolBudget.action.previewBuysOnly")) { onRequestGapPreview(currency.code) }
                    .buttonStyle(.link).font(PoolType.label)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    /// Row 1: the currency, the value it holds today, and — in preview — the
    /// value it would hold, both of which are known even while the pool split
    /// is not. Only a missing quote or an overflow withholds them.
    private func totalRow(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        let partial = currency.holdings.contains { $0.beforeQuantity != 0 && $0.beforePercent == nil }
        return HStack(spacing: 6) {
            Text(currency.code)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.primary.opacity(0.08), in: Capsule())
            Text(PulseLocalization.localizedString(partial ? "poolBudget.holdings.quotedPartValue" : "poolBudget.holdings.value",
                    PriceFormatter.money(currency.holdingsBefore, currencyCode: currency.code)))
                .font(PoolType.number).lineLimit(1).minimumScaleFactor(0.85)
            if isAssumed {
                if let projected = projectedHoldings(currency) {
                    Text("→ " + (currency.unvaluableQuantity > 0
                              ? PulseLocalization.localizedString("poolBudget.holdings.quotedPartPrefix") : "")
                         + PoolAmountText.assumed(projected))
                        .font(PoolType.assumedNumber).lineLimit(1).minimumScaleFactor(0.85)
                    let delta = currency.holdingsAfter - currency.holdingsBefore
                    if delta.isFinite, delta != 0 {
                        // Direction is stated in words and in the sign; blue only,
                        // never a profit/loss red or green.
                        Text((currency.unvaluableQuantity > 0
                             ? PulseLocalization.localizedString("poolBudget.holdings.quotedValueChange")
                             : PulseLocalization.localizedString("poolBudget.holdings.valueChange"))
                             + PriceFormatter.signedMoney(delta, currencyCode: currency.code))
                            .font(PoolType.labelMedium.monospacedDigit()).foregroundStyle(.blue)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                } else {
                    Text(PulseLocalization.localizedString("poolBudget.holdings.fullPreviewPending"))
                        .font(PoolType.label).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button {
                editingCurrency = EditingCurrency(code: currency.code)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(PulseLocalization.localizedString("poolBudget.action.editLimits"))
        }
    }

    /// Row 2: the only always-visible track — where today's priced value sits
    /// across the four pools, on one money scale. The trough's neutral blank
    /// remainder *is* the not-yet-attributed value, so no segment is invented
    /// for it; the legend names it in words.
    private func distribution(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        let segments = currency.pools.map { PoolTrackGauge.Segment(pool: $0.pool, value: $0.heldAmount) }
        let scale = isAssumed && afterIsReliable(currency)
            ? max(currency.holdingsBefore, currency.holdingsAfter, heldTotal(currency))
            : max(currency.holdingsBefore, heldTotal(currency))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(PulseLocalization.localizedString("poolBudget.distribution.current"))
                    .font(PoolType.label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isAssumed, afterIsReliable(currency) {
                    Text(PulseLocalization.localizedString("poolBudget.distribution.compare"))
                        .font(PoolType.label).foregroundStyle(.tertiary)
                        .help(PulseLocalization.localizedString("poolBudget.distribution.compareHelp"))
                }
            }
            PoolTrackGauge(height: 10, segments: segments, scale: scale)
                .accessibilityLabel(PulseLocalization.localizedString("poolBudget.distribution.currentLabel"))
        }
    }

    /// Row 3: the four pools — colour, name, and share — on four columns when
    /// they fit and two when they do not. Percentages come from the same two
    /// seams the pool columns use, so a legend figure and a column figure can
    /// never disagree.
    private func legend(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        let floor = isVerifiedFloor(currency)
        var entries: [LegendEntry] = currency.pools.filter {
            $0.pool != .unassigned || $0.heldAmount > 0
                || $0.plannedBuyAmount > 0 || $0.plannedSellAmount > 0
        }.map { pool -> LegendEntry in
            let current: Double? = PoolBudgetGauge.currentShare(pool, currency: currency)
            let preview: Double? = isAssumed ? PoolBudgetGauge.previewShare(pool, currency: currency) : nil
            let currentText: String = current.map { (fraction: Double) -> String in
                percentText(fraction, floor: floor)
            } ?? "—"
            let afterText: String? = preview.map { (fraction: Double) -> String in
                PoolAmountText.assumed(percentText(fraction, floor: false))
            }
            return LegendEntry(pool: pool.pool,
                               tint: pool.pool.tint,
                               amount: pool.heldAmount,
                               unvaluable: pool.unvaluableQuantity,
                               current: currentText,
                               after: afterText)
        }
        let rest = restAmount(currency)
        if rest != nil {
            entries.append(LegendEntry(pool: nil, tint: .gray, amount: rest ?? 0, unvaluable: 0,
                                       current: "—", after: nil))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(entries) { legendItem($0, currency: currency) }
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 3) {
                ForEach(entries) { legendItem($0, currency: currency) }
            }
        }
    }

    private func legendItem(_ entry: LegendEntry,
                            currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        HStack(spacing: 4) {
            Circle().fill(entry.tint).frame(width: 5, height: 5)
            Text(entry.title).font(PoolType.label).foregroundStyle(.secondary).lineLimit(1)
            Text(entry.current).font(PoolType.label.monospacedDigit()).lineLimit(1)
            if let after = entry.after {
                Text("→ " + after).font(PoolType.label.monospacedDigit()).foregroundStyle(.blue).lineLimit(1)
            }
            if entry.amount > 0, entry.pool == nil {
                // Money appears once per pool, and only when it still fits
                // beside the share.
                Text(PoolAmountText.money(entry.amount, currency: currency.code, assumed: false))
                    .font(PoolType.label.monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
            }
            if entry.unvaluable > 0, entry.amount == 0 {
                // Units are known, the price is not: a count, never a zero.
                Text(PulseLocalization.localizedString("poolBudget.legend.unpriced", entry.unvaluable))
                    .font(PoolType.label).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .fixedSize()
    }

    /// Row 4 (preview only): the after-trade split, on the *same* scale and the
    /// same left edge as the current track, so the two lengths are directly
    /// comparable. Drawn only where the after-state is reliable; where it is
    /// not, it is omitted and the block's one local note says why.
    private func afterTrack(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        let segments = currency.pools.map { PoolTrackGauge.Segment(pool: $0.pool, value: $0.projectedAmount) }
        let scale = max(currency.holdingsBefore, currency.holdingsAfter, heldTotal(currency))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(PulseLocalization.localizedString("poolBudget.distribution.afterTitle"))
                    .font(PoolType.label).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let projected = projectedHoldings(currency) {
                    Text(PoolAmountText.assumed(projected)).font(PoolType.assumedNumber)
                }
            }
            PoolTrackGauge(height: 8, segments: segments, scale: scale)
                .opacity(0.45)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .accessibilityLabel(PulseLocalization.localizedString("poolBudget.distribution.afterLabel"))
        }
    }

    /// Row 5: cash and the buy budget, kept visibly separate from shares. The
    /// denominator of everything above is priced holdings and never includes
    /// cash; nothing here nets an unsettled sale into spendable money.
    private func cashFlow(_ currency: PoolBudgetProjection.CurrencyProjection,
                          blockedSells: [PoolBudgetProjection.OverSellWarning]) -> some View {
        let gap = currency.cashShortfall
        let flow = ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                budgetFigure(currency); cashFigure(currency); balanceFigure(currency, gap: gap)
                if let compact = compactFlow(currency, blockedSells: blockedSells) {
                    Text(compact.text).font(PoolType.label)
                        .foregroundStyle(compact.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                budgetFigure(currency)
                cashFigure(currency)
                balanceFigure(currency, gap: gap)
                if let compact = compactFlow(currency, blockedSells: blockedSells) {
                    Text(compact.text).font(PoolType.label)
                        .foregroundStyle(compact.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 3) {
            flow
            if let onRequestGapPreview, !isAssumed, currency.cashBalance == nil, currency.plannedBuyAmount > 0 {
                Button(PulseLocalization.localizedString("poolBudget.action.previewTheseBuys")) { onRequestGapPreview(currency.code) }
                    .buttonStyle(.link).font(PoolType.label)
            }
        }
    }

    private func budgetFigure(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        PoolLabeledValue(
            label: isAssumed
                ? PulseLocalization.localizedString("poolBudget.figure.selectedBuys")
                : PulseLocalization.localizedString("poolBudget.figure.plannedBuys"),
            value: PriceFormatter.money(currency.plannedBuyAmount, currencyCode: currency.code),
            assumed: isAssumed
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cashFigure(_ currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        PoolLabeledValue(
            label: PulseLocalization.localizedString("poolBudget.figure.cash"),
            value: currency.cashBalance.map { PriceFormatter.money($0, currencyCode: currency.code) } ?? "—",
            valueColor: currency.cashBalance == nil ? .secondary : .primary
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func balanceFigure(_ currency: PoolBudgetProjection.CurrencyProjection,
                               gap: Double) -> some View {
        let unknown = currency.cashBalance == nil
        return PoolLabeledValue(
            label: gap > 0 ? PulseLocalization.localizedString("poolBudget.figure.buyGap") : PulseLocalization.localizedString("poolBudget.figure.budgetLeft"),
            value: unknown
                ? "—"
                : (gap > 0 ? PriceFormatter.money(gap, currencyCode: currency.code)
                           : currency.availableCash.map { PriceFormatter.money($0, currencyCode: currency.code) } ?? "—"),
            valueColor: unknown || gap > 0 ? .orange : .primary
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The one cash line that has to be a sentence rather than a figure. An
    /// unknown balance has no gap; an over-committed sale is not recoverable
    /// money; a clean sale is reported apart from cash, never added to it.
    private func compactFlow(_ currency: PoolBudgetProjection.CurrencyProjection,
                             blockedSells: [PoolBudgetProjection.OverSellWarning]) -> (text: String, isWarning: Bool)? {
        if currency.cashBalance == nil {
            return (PulseLocalization.localizedString("poolBudget.flow.cashUnknown"), true)
        }
        if !blockedSells.isEmpty {
            // `plannedSellAmount` totals every selected sell, including ones the
            // position cannot deliver, so no money figure is derived from it.
            return (PulseLocalization.localizedString("poolBudget.flow.blockedSells", blockedSells.count), true)
        }
        if currency.plannedSellAmount > 0 {
            return (PulseLocalization.localizedString("poolBudget.flow.estimatedProceeds")
                    + PoolAmountText.money(currency.plannedSellAmount, currency: currency.code, assumed: isAssumed)
                    + PulseLocalization.localizedString("poolBudget.flow.notCountedAsCash"), false)
        }
        return nil
    }

    /// One local note per currency, covering whichever state actually applies.
    /// The panel deliberately does not scatter a second copy of each warning.
    private func localNote(_ currency: PoolBudgetProjection.CurrencyProjection,
                           blockedSells: [PoolBudgetProjection.OverSellWarning]) -> (text: String, isWarning: Bool)? {
        let missingCurrent = currency.holdings.contains { $0.beforeQuantity != 0 && $0.beforePercent == nil }
        if currency.unvaluableQuantity > 0, isAssumed || missingCurrent {
            return (missingCurrent
                    ? PulseLocalization.localizedString("poolBudget.note.heldMissingQuote")
                    : PulseLocalization.localizedString("poolBudget.note.previewMissingQuote", currency.unvaluableQuantity),
                    true)
        }
        if isAssumed, !afterIsReliable(currency) {
            if unassignedSellCurrencies.contains(currency.code) {
                return (PulseLocalization.localizedString("poolBudget.note.unassignedSell"), true)
            }
            let text = currency.pools.contains(where: { $0.needsReconciliation })
                ? PulseLocalization.localizedString("poolBudget.note.afterNeedsReview")
                : PulseLocalization.localizedString("poolBudget.note.afterAwaitsQuotes")
            return (text, true)
        }
        if currency.cashBalance == nil {
            return (PulseLocalization.localizedString("poolBudget.note.cashUnknown"), true)
        }
        if !blockedSells.isEmpty {
            return (PulseLocalization.localizedString("poolBudget.flow.blockedSellsPeriod", blockedSells.count), true)
        }
        return nil
    }

    // MARK: Derivation (local, from the fields the projection already carries)

    /// The projected total market value, or nil when it cannot be stated. The
    /// full-portfolio total is independent of pool *allocation*, so only an
    /// unusable quote or an overflow withholds it.
    private func projectedHoldings(_ currency: PoolBudgetProjection.CurrencyProjection) -> String? {
        guard currency.holdingsAfter.isFinite, !currency.hasOverflow else { return nil }
        return PriceFormatter.money(currency.holdingsAfter, currencyCode: currency.code)
    }

    /// Whether the after-trade split can be drawn at all. This is the same
    /// condition `PoolBudgetGauge.previewShare` applies to every pool, spelled
    /// out locally so the panel can say *why* the track is missing instead of
    /// rendering an empty slot.
    private func afterIsReliable(_ currency: PoolBudgetProjection.CurrencyProjection) -> Bool {
        currency.unvaluableQuantity == 0
            && !currency.pools.contains { $0.needsReconciliation }
    }

    /// The sum of the verified pool amounts actually drawn on the track.
    private func heldTotal(_ currency: PoolBudgetProjection.CurrencyProjection) -> Double {
        let total = currency.pools.reduce(0) { $0 + ($1.heldAmount.isFinite ? $1.heldAmount : 0) }
        return total.isFinite ? total : 0
    }

    /// The known value no pool has been credited with yet, or nil when there is
    /// none to name. It is the trough's own blank remainder — never a fifth
    /// segment, and never painted in the unassigned pool's colour.
    private func restAmount(_ currency: PoolBudgetProjection.CurrencyProjection) -> Double? {
        guard currency.holdingsBefore.isFinite, currency.holdingsBefore > 0 else { return nil }
        let rest = currency.holdingsBefore - heldTotal(currency)
        let tolerance = max(1e-6, abs(currency.holdingsBefore) * 1e-9)
        return rest > tolerance ? rest : nil
    }

    /// Whether the verified shares fall short of the position, in which case
    /// every current share is a floor. Derived here from the same sum and
    /// tolerance the pool column uses; the gauge's own predicate is private.
    private func isVerifiedFloor(_ currency: PoolBudgetProjection.CurrencyProjection) -> Bool {
        guard currency.holdingsBefore.isFinite, currency.holdingsBefore > 0 else { return false }
        let tolerance = max(1e-6, abs(currency.holdingsBefore) * 1e-9)
        return heldTotal(currency) < currency.holdingsBefore - tolerance
    }

    private func percentText(_ fraction: Double, floor: Bool) -> String {
        let text = fraction.formatted(.percent.precision(.fractionLength(1)))
        return floor ? "≥" + text : text
    }

    private struct LegendEntry: Identifiable {
        let pool: PositionPool?
        let tint: Color
        let amount: Double
        let unvaluable: Int
        let current: String
        let after: String?

        var title: String {
            pool?.title ?? PulseLocalization.localizedString("poolBudget.legend.allocationReview")
        }

        var id: String { pool?.rawValue ?? "rest" }
    }
}

/// Wrapper so `sheet(item:)` can drive the editor from a currency code without
/// hanging an `Identifiable` conformance on `String` itself.
struct EditingCurrency: Identifiable {
    let code: String
    var id: String { code }
}

/// Cash and the four absolute pool limits for one currency. Writes only the
/// budget settings record.
struct PoolBudgetEditSheet: View {
    let currency: String
    /// Explicit write target; changing it reloads this account's draft without
    /// switching the surrounding workspace.
    @State private var draftAccount: BrokerageAccountID

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var cashText = ""
    @State private var limitTexts: [PositionPool: String] = [:]
    @State private var error: String?
    @State private var loadedSettings: BrokerageAccountSettings?

    init(currency: String, account: BrokerageAccountID) {
        self.currency = currency
        self._draftAccount = State(initialValue: account)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PulseLocalization.localizedString("poolBudget.editor.title", currency))
                .font(.system(size: 13, weight: .semibold))
            Picker(PulseLocalization.localizedString("poolBudget.editor.account"), selection: $draftAccount) {
                ForEach([BrokerageAccountID.financing, .mengmeng, .unassigned]) { account in
                    Text(AccountIdentity.title(account)).tag(account)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: draftAccount) { _, _ in
                load()
            }

            Form {
                TextField(PulseLocalization.localizedString("poolBudget.editor.cashBalance"), text: $cashText)
                    .help(PulseLocalization.localizedString("poolBudget.editor.cashHelp"))
                ForEach(PositionPool.activeCases, id: \.self) { pool in
                    TextField(PulseLocalization.localizedString("poolBudget.editor.poolLimit", pool.title),
                              text: Binding(
                                get: { limitTexts[pool] ?? "" },
                                set: { limitTexts[pool] = $0 }
                              ))
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error).font(PoolType.label).foregroundStyle(.red)
            }

            HStack {
                Text(PulseLocalization.localizedString("poolBudget.editor.footnote"))
                    .font(PoolType.label).foregroundStyle(.secondary)
                Spacer()
                Button(PulseLocalization.localizedString("poolBudget.editor.cancel")) { dismiss() }
                Button(PulseLocalization.localizedString("poolBudget.editor.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private func load() {
        error = nil
        loadedSettings = appState.watchlist.brokerageSettings(for: draftAccount) ?? .init()
        let balance = appState.poolBudgets.cashBalances(for: draftAccount)[currency]
        cashText = balance.map { String($0.amount) } ?? ""
        for pool in PositionPool.activeCases {
            let amount = loadedSettings?.poolLimits.first { $0.currency == currency && $0.pool == pool }?.amount
                ?? (appState.watchlist.brokerageAccountsEnabled ? nil : appState.poolBudgets.poolLimit(currency: currency, pool: pool))
            limitTexts[pool] = amount.map { String($0) } ?? ""
        }
    }

    private func save() {
        // Empty means "unset": unknown cash and no limit. Anything else must
        // parse to a finite, non-negative number, or the whole save is refused
        // rather than half applied.
        let cash = parsed(cashText)
        guard !cash.invalid else {
            error = PulseLocalization.localizedString("poolBudget.editor.error.cashInvalid")
            return
        }
        var limits: [PositionPool: ParsedAmount] = [:]
        for pool in PositionPool.activeCases {
            let value = parsed(limitTexts[pool] ?? "")
            guard !value.invalid else {
                error = PulseLocalization.localizedString("poolBudget.editor.error.limitInvalid", pool.title)
                return
            }
            limits[pool] = value
        }

        if appState.watchlist.brokerageAccountsEnabled {
            var record = appState.watchlist.brokerageSettings(for: draftAccount) ?? .init()
            let previous = loadedSettings ?? .init()
            func currencyLimits(_ settings: BrokerageAccountSettings) -> [BrokeragePoolLimit] {
                settings.poolLimits.filter { $0.currency == currency && $0.pool.isActivePurpose }
                    .sorted { $0.pool.rawValue < $1.pool.rawValue }
            }
            guard record.cashBalances[currency] == previous.cashBalances[currency],
                  currencyLimits(record) == currencyLimits(previous) else {
                error = PulseLocalization.localizedString("poolBudget.editor.error.settingsChanged")
                return
            }
            if let value = cash.value { record.cashBalances[currency] = .init(amount: value, updatedAt: .now) }
            else { record.cashBalances.removeValue(forKey: currency) }
            record.poolLimits.removeAll { $0.currency == currency && $0.pool.isActivePurpose }
            for pool in PositionPool.activeCases {
                if let value = limits[pool]?.value { record.poolLimits.append(.init(currency: currency, pool: pool, amount: value)) }
            }
            guard appState.watchlist.setBrokerageSettings(record, for: draftAccount) else {
                error = PulseLocalization.localizedString("poolBudget.editor.error.saveFailed")
                return
            }
        } else {
            guard appState.poolBudgets.setCashBalance(amount: cash.value, currency: currency) else { return }
            for pool in PositionPool.activeCases {
                guard appState.poolBudgets.setPoolLimit(amount: limits[pool]?.value, currency: currency, pool: pool) else { return }
            }
        }
        dismiss()
    }

    private func parsed(_ text: String) -> ParsedAmount {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ParsedAmount(value: nil, invalid: false) }
        guard let value = Double(trimmed), value.isFinite, value >= 0, value < .greatestFiniteMagnitude else {
            return ParsedAmount(value: nil, invalid: true)
        }
        return ParsedAmount(value: value, invalid: false)
    }

    private struct ParsedAmount {
        var value: Double?
        var invalid: Bool
    }
}

// MARK: - Pool capacity

/// A pool column's own capacity line, plus its always-visible holdings share.
///
/// Two *separate* metrics live here, and keeping them separate is the point:
///
/// * The **share row** answers "how much of this currency's holdings sits in
///   this pool". It is drawn for every pool that holds a known amount, whether
///   or not a budget cap was ever recorded — a missing cap must not make the
///   share bar disappear. Its own denominator is the currency's holdings.
/// * The **cap row** answers "how much of the recorded budget is used". It is
///   optional, appears only when a limit exists, and keeps its own denominator
///   (held + plan-price buys). A planned sell never offsets it.
///
/// The two therefore never share a scale: a 100%-of-holdings bar and a
/// 100%-of-budget bar mean different things and are never overlaid.
struct PoolBudgetGauge: View {
    let pool: PositionPool
    /// The same projection the board and capital panel show, owned by the
    /// caller. The gauge previously ignored its entry list and recalculated
    /// every active plan, so a preview subset never reached this column.
    let result: PoolBudgetProjection.Result
    /// Preview mode adds the before→after share and the projected track. The
    /// current share and its bar are drawn in both modes.
    var isPreviewing = false
    var editingAccountID: BrokerageAccountID?

    @Environment(AppState.self) private var appState
    @State private var editingCurrency: EditingCurrency?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.currencies) { currency in
                if let projection = currency.pools.first(where: { $0.pool == pool }),
                   Self.hasContent(projection, currency: currency) {
                    gaugeRow(projection, currency: currency)
                }
            }
        }
        .sheet(item: $editingCurrency) {
            PoolBudgetEditSheet(currency: $0.code, account: editingAccountID ?? appState.poolBudgets.accountID)
        }
    }

    /// Whether this pool/currency pair has anything worth a row. A currency that
    /// holds nothing here, plans nothing here, has no unpriced units here and
    /// records no cap would render one line of "0.0%, no cap" — noise that also
    /// implies the pool was considered. It is skipped instead. An overflowed
    /// currency always keeps its row: the warning is the content.
    static func hasContent(_ projection: PoolBudgetProjection.PoolProjection,
                           currency: PoolBudgetProjection.CurrencyProjection) -> Bool {
        currency.hasOverflow
            || projection.heldAmount != 0
            || projection.projectedAmount != 0
            || projection.plannedBuyAmount != 0
            || projection.plannedSellAmount != 0
            || projection.unvaluableQuantity > 0
            || projection.limit != nil
    }

    @ViewBuilder
    private func gaugeRow(_ projection: PoolBudgetProjection.PoolProjection,
                          currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        let current = Self.currentShare(projection, currency: currency)
        let preview = isPreviewing ? Self.previewShare(projection, currency: currency) : nil
        VStack(alignment: .leading, spacing: 4) {
            shareRow(projection, currency: currency, current: current, preview: preview)
            HStack(spacing: 5) {
                Button {
                    editingCurrency = EditingCurrency(code: currency.code)
                } label: {
                    Text(currency.code + " · " + (projection.limit.map {
                        PulseLocalization.localizedString("poolBudget.gauge.budgetCap",
                           PriceFormatter.money($0, currencyCode: currency.code))
                    } ?? PulseLocalization.localizedString("poolBudget.gauge.noBudgetCap")))
                }
                .buttonStyle(.borderless)
                .help(PulseLocalization.localizedString("poolBudget.gauge.editHelp"))
                Spacer(minLength: 0)
                if projection.overLimitAmount > 0 {
                    Text(PulseLocalization.localizedString("poolBudget.gauge.overBudget",
                            PriceFormatter.money(projection.overLimitAmount, currencyCode: currency.code)))
                        .foregroundStyle(.orange)
                }
                if current == nil, projection.needsReconciliation {
                    Text(PulseLocalization.localizedString("poolBudget.gauge.reviewPending")).foregroundStyle(.orange)
                } else if current == nil, projection.unvaluableQuantity > 0 || currency.hasOverflow {
                    Text(PulseLocalization.localizedString("poolBudget.legend.unpriced", projection.unvaluableQuantity))
                        .foregroundStyle(.orange)
                }
            }
            .font(PoolType.label.monospacedDigit())

            capRow(projection, currency: currency)
        }
    }

    // MARK: Share row (always visible, own denominator)

    /// The share metric: a 6pt track on the currency's own holdings, plus its
    /// label. Drawn whether or not a cap exists, because "how much of what I
    /// own is in this pool" is a different question from "how much of my
    /// budget is used".
    @ViewBuilder
    private func shareRow(_ projection: PoolBudgetProjection.PoolProjection,
                          currency: PoolBudgetProjection.CurrencyProjection,
                          current: Double?,
                          preview: Double?) -> some View {
        if let current {
            // The current track's scale is the *current* total: the bar length
            // is the share itself. The preview track gets its own scale (the
            // after total) and sits beneath, rather than being stacked on a
            // denominator it does not share.
            VStack(alignment: .leading, spacing: 3) {
                PoolTrackGauge(
                    height: 6, tint: pool.tint,
                    segments: [.init(pool: pool, value: current)],
                    scale: 1
                )
                .accessibilityLabel(PulseLocalization.localizedString("poolBudget.gauge.currentShareLabel", percentLabel(current)))
            }
        }
        if let preview {
            PoolTrackGauge(height: 3, tint: pool.tint,
                           segments: [.init(pool: pool, value: preview)], scale: 1)
                .opacity(0.55)
                .accessibilityLabel(PulseLocalization.localizedString("poolBudget.gauge.previewShareLabel", percentLabel(preview)))
        }

        if currency.hasOverflow {
            Text(PulseLocalization.localizedString("poolBudget.gauge.invalidRatio"))
                .font(PoolType.label).foregroundStyle(.orange)
        } else if let current, let preview {
            Text(currency.code + " · " + PulseLocalization.localizedString("poolBudget.gauge.ofHoldingsPrefix")
                 + percentLabel(current) + " → " + PoolAmountText.assumed(percentLabel(preview)))
                .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                .help(PulseLocalization.localizedString("poolBudget.gauge.shareHelp"))
        } else if let current {
            HStack(spacing: 6) {
                Text(shareLabel(current, projection: projection, currency: currency))
                    .font(PoolType.label.monospacedDigit())
                    .foregroundStyle(isFloor(projection, currency: currency) ? .orange : .secondary)
                if isPreviewing {
                    Text(currency.unvaluableQuantity > 0
                         ? PulseLocalization.localizedString("poolBudget.gauge.previewAwaitingQuotes")
                         : PulseLocalization.localizedString("poolBudget.gauge.previewNeedsReview"))
                        .font(PoolType.label).foregroundStyle(.orange)
                }
            }
        } else if let preview {
            Text(currency.code + " · " + PulseLocalization.localizedString("poolBudget.gauge.noHeldSharesPrefix")
                 + PoolAmountText.assumed(percentLabel(preview)))
                .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
        } else if projection.unvaluableQuantity > 0 {
            // The current bar is still drawn above when it is valid; only the
            // *preview* share is unavailable, because the after-total would be
            // missing a position. Say which one is pending.
            Text(isPreviewing
                 ? PulseLocalization.localizedString("poolBudget.gauge.missingQuote.preview")
                 : PulseLocalization.localizedString("poolBudget.gauge.missingQuote.current"))
                .font(PoolType.label).foregroundStyle(.orange)
        } else {
            // A quantity is held and nothing is missing, yet there is no
            // denominator to divide by. Never print 0% for that.
            Text(PulseLocalization.localizedString("poolBudget.gauge.noValuedHolding"))
                .font(PoolType.label).foregroundStyle(.secondary)
        }
    }

    private func shareLabel(_ current: Double,
                            projection: PoolBudgetProjection.PoolProjection,
                            currency: PoolBudgetProjection.CurrencyProjection) -> String {
        currency.code + " · " + (isFloor(projection, currency: currency)
            ? PulseLocalization.localizedString("poolBudget.gauge.verifiedFloor", percentLabel(current))
            : PulseLocalization.localizedString("poolBudget.gauge.ofHoldingsValue", percentLabel(current)))
    }

    /// Whether the current share is only a floor: the verified pool shares sum
    /// to less than the currency's holdings, so part of the position is not
    /// attributed to any pool yet.
    private func isFloor(_ projection: PoolBudgetProjection.PoolProjection,
                         currency: PoolBudgetProjection.CurrencyProjection) -> Bool {
        guard currency.holdingsBefore > 0 else { return false }
        let verifiedTotal = currency.pools.reduce(0) { $0 + ($1.heldAmount.isFinite ? $1.heldAmount : 0) }
        let tolerance = max(1e-6, abs(currency.holdingsBefore) * 1e-9)
        return verifiedTotal < currency.holdingsBefore - tolerance
    }

    // MARK: Cap row (optional, separate metric, own denominator)

    /// The budget-cap metric. Deliberately a separate row from the share: its
    /// denominator (held + plan-price buys) is not the holdings total, so the
    /// two bars are never overlaid.
    @ViewBuilder
    private func capRow(_ projection: PoolBudgetProjection.PoolProjection,
                        currency: PoolBudgetProjection.CurrencyProjection) -> some View {
        if projection.limit != nil, projection.unvaluableQuantity > 0 || currency.hasOverflow {
            Text(currency.hasOverflow
                 ? PulseLocalization.localizedString("poolBudget.gauge.invalidBudgetRatio")
                 : PulseLocalization.localizedString("poolBudget.gauge.missingQuoteBudgetRatio"))
                .font(PoolType.label).foregroundStyle(.orange)
        } else if let limit = projection.limit, limit > 0,
                  !projection.needsReconciliation {
            // One scale (the limit). The solid track is what the pool holds
            // now; the planned extension is layered in front of it. That
            // front gauge draws no background of its own — an opaque slot
            // would cover the holdings track it is meant to extend.
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .leading) {
                    PoolTrackGauge(
                        height: 6, tint: pool.tint,
                        segments: [.init(pool: pool, value: projection.heldAmount + projection.plannedBuyAmount)],
                        scale: limit
                    )
                    .opacity(0.45)
                    PoolTrackGauge(
                        height: 6, tint: pool.tint,
                        segments: [.init(pool: pool, value: projection.heldAmount)],
                        scale: limit, drawsTrack: false
                    )
                }
                .accessibilityLabel(PulseLocalization.localizedString("poolBudget.gauge.capLabel"))
                .help(PulseLocalization.localizedString("poolBudget.gauge.capHelp"))
            }
        } else if projection.needsReconciliation, projection.limit != nil {
            Text(PulseLocalization.localizedString("poolBudget.gauge.pendingBudgetShare"))
                .font(PoolType.label).foregroundStyle(.orange)
        }
    }

    // MARK: Share math (pure, static, test seams)

    /// This pool's share of the currency's *current* holdings, or nil when the
    /// question cannot be answered honestly.
    ///
    /// The denominator is `holdingsBefore` — the quote-priced total. Note what
    /// this deliberately does *not* consult:
    ///
    /// * `currency.unvaluableQuantity`, which counts any position with no
    ///   usable quote, including one that only exists *after* a planned buy.
    ///   An unquoted future buy must not hide a perfectly valid current share.
    /// * `projection.unvaluableQuantity`, for exactly the same reason: a pool's
    ///   count includes positions whose only shares here are *projected* (the
    ///   unpriced buy assigned to this pool). Guarding on it would delete the
    ///   current bar of a pool that is merely about to receive something
    ///   unquotable.
    /// * `projection.needsReconciliation` on its own: an unspecified-pool *sell*
    ///   makes the after-state indeterminate while today's verified shares are
    ///   still exactly what is held. Where those shares fall short of the
    ///   position the caller labels the figure as a floor.
    ///
    /// The one thing that really invalidates a *current* share is a position
    /// held *today* that has no usable quote, because its value is missing from
    /// the numerator and the denominator alike. `beforeQuantity != 0 &&
    /// beforePercent == nil` identifies exactly that: the symbol exists in the
    /// current book but produced no valued holding.
    ///
    /// Zero is a real answer (a pool holding nothing); nil means "no number".
    static func currentShare(_ projection: PoolBudgetProjection.PoolProjection,
                             currency: PoolBudgetProjection.CurrencyProjection) -> Double? {
        let held = projection.heldAmount
        guard held.isFinite, held >= 0 else { return nil }
        guard currency.holdingsBefore.isFinite, currency.holdingsBefore > 0 else { return nil }
        guard !currency.hasOverflow else { return nil }
        guard !currency.holdings.contains(where: { $0.beforeQuantity != 0 && $0.beforePercent == nil })
        else { return nil }
        let fraction = held / currency.holdingsBefore
        guard fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return fraction
    }

    /// This pool's share of the currency's *projected* holdings, or nil when
    /// the preview cannot be stated.
    ///
    /// Preview needs the after-state to be well defined: no reconciliation, no
    /// unvalued quantity, no overflow, finite non-negative inputs. A full
    /// liquidation (projected 0, totalAfter 0) is a real answer and returns 0.
    static func previewShare(_ projection: PoolBudgetProjection.PoolProjection,
                             currency: PoolBudgetProjection.CurrencyProjection) -> Double? {
        guard !projection.needsReconciliation else { return nil }
        guard projection.unvaluableQuantity == 0, currency.unvaluableQuantity == 0 else { return nil }
        guard !currency.hasOverflow else { return nil }
        let projected = projection.projectedAmount
        let totalAfter = currency.holdingsAfter
        guard projected.isFinite, projected >= 0, totalAfter.isFinite, totalAfter >= 0 else { return nil }
        if totalAfter == 0 { return projected == 0 ? 0 : nil }
        let fraction = projected / totalAfter
        guard fraction.isFinite, fraction >= 0, fraction <= 1 else { return nil }
        return fraction
    }

    private func percentLabel(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }
}

// MARK: - Scenario

/// The multi-plan dry run: pick plans, see what the cash and pools would look
/// like if every one of them filled. Saving stores the *selection*; the figures
/// are always recalculated from the current plans and quotes.
struct PoolScenarioView: View {
    let currencyFilter: String
    /// Lets the inline preview hand its current selection over to the sheet.
    var initialSelection: Set<UUID> = []
    /// Reports a selection back to the inline preview when the sheet closes.
    var onApply: ((Set<UUID>) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPlanIDs: Set<UUID> = []
    @State private var scenarioName = ""
    @State private var message: String?
    /// The budget account this preview was opened for. Saved previews live in
    /// that account's budget record, so an account switch must not let this
    /// sheet's name and selection be written into the newly loaded one.
    @State private var draftAccount: BrokerageAccountID?

    private var accountMatchesDraft: Bool {
        draftAccount.map { appState.poolBudgets.accountID == $0 } ?? true
    }

    var body: some View {
        let allEntries = appState.watchlist.tradePlanEntries
            .filter { $0.plan.status == .active && $0.remainingQuantity > 0 }
            .sorted { $0.plan.updatedAt > $1.plan.updatedAt }
        let input = PoolBudgetInput(appState: appState, currencyFilter: currencyFilter)
        let visibleEntries = input.entries.filter { $0.remainingQuantity > 0 }
            .sorted { $0.plan.updatedAt > $1.plan.updatedAt }
        let selected = visibleEntries.filter { selectedPlanIDs.contains($0.id) }
        let hiddenCount = selectedPlanIDs.count - selected.count
        let result = PoolBudgetInput(appState: appState, currencyFilter: currencyFilter,
                                     planIDs: selectedPlanIDs).calculate()

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(PulseLocalization.localizedString("poolBudget.scenario.title"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(PulseLocalization.localizedString("poolBudget.scenario.subtitle"))
                        .font(PoolType.label).foregroundStyle(.secondary)
                }
                Spacer()
                Button(PulseLocalization.localizedString("poolBudget.scenario.done")) { onApply?(selectedPlanIDs); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    planPicker(visibleEntries)
                    if hiddenCount > 0 {
                        Text(PulseLocalization.localizedString("poolBudget.scenario.hiddenSelections", hiddenCount))
                            .font(PoolType.label).foregroundStyle(.orange)
                    }
                    if input.referenceQuoteCount > 0 {
                        Text(PulseLocalization.localizedString("poolBudget.scenario.referenceQuotes"))
                            .font(PoolType.label).foregroundStyle(.secondary)
                    }

                    if selected.isEmpty {
                        Text(PulseLocalization.localizedString("poolBudget.scenario.selectPrompt"))
                            .font(PoolType.label).foregroundStyle(.secondary)
                    } else {
                        scenarioResult(result)
                    }

                    savedScenarios(allEntries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message {
                Text(message).font(PoolType.label).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 700, height: 650)
        .onAppear {
            selectedPlanIDs = initialSelection
            draftAccount = appState.poolBudgets.accountID
        }
    }

    @ViewBuilder
    private func planPicker(_ entries: [TradePlanEntry]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(PulseLocalization.localizedString("poolBudget.scenario.plans")).font(PoolType.chip)
                Spacer()
                Button(PulseLocalization.localizedString("poolBudget.scenario.selectAll")) { selectedPlanIDs = Set(entries.map(\.id)) }
                    .buttonStyle(.borderless).controlSize(.small)
                Button(PulseLocalization.localizedString("poolBudget.scenario.clear")) { selectedPlanIDs.removeAll() }
                    .buttonStyle(.borderless).controlSize(.small)
            }
            if entries.isEmpty {
                Text(PulseLocalization.localizedString("poolBudget.scenario.noActivePlans"))
                    .font(PoolType.label).foregroundStyle(.secondary)
            }
            ForEach(entries) { entry in
                Toggle(isOn: Binding(
                    get: { selectedPlanIDs.contains(entry.id) },
                    set: { isOn in
                        if isOn { selectedPlanIDs.insert(entry.id) } else { selectedPlanIDs.remove(entry.id) }
                    }
                )) {
                    HStack(spacing: 6) {
                        Text(entry.symbol.displayCode).font(PoolType.chip)
                        Text(PulseLocalization.localizedString(entry.plan.kind == .buy ? "poolBudget.scenario.buy" : "poolBudget.scenario.sell"))
                            .font(PoolType.label)
                            .foregroundStyle(entry.plan.kind == .buy ? Color.blue : Color.orange)
                        Text(PulseLocalization.localizedString("poolBudget.scenario.remainingPrefix")
                             + PriceFormatter.quantity(entry.remainingQuantity)
                             + " @ " + PriceFormatter.price(entry.plan.price, market: entry.symbol.market))
                            .font(PoolType.label.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(PriceFormatter.money(entry.remainingQuantity * entry.plan.price,
                                                  currencyCode: entry.symbol.currencyCode))
                            .font(PoolType.labelMedium.monospacedDigit())
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    @ViewBuilder
    private func scenarioResult(_ result: PoolBudgetProjection.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PoolBudgetNotice.messages(result), id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(PoolType.label).foregroundStyle(.secondary)
            }

            ForEach(result.currencies) { currency in
                if currency.hasOverflow {
                    Text(currency.code + " · " + PulseLocalization.localizedString("poolBudget.scenario.overflow"))
                        .font(PoolType.label).foregroundStyle(.orange)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(currency.code).font(PoolType.chip)

                        let canEstimateCash = !currency.hasOverflow && result.unsupportedShortCount == 0
                            && !result.overSellWarnings.contains { $0.currencyCode == currency.code }
                        let netCash = canEstimateCash ? currency.cashBalance.map {
                            $0 - currency.plannedBuyAmount + currency.plannedSellAmount
                        }.flatMap { $0.isFinite ? $0 : nil } : nil
                        // Same rule as the capital panel: `plannedSellAmount`
                        // includes sells the position cannot deliver, so it is
                        // only reported as proceeds when no such warning exists
                        // for this currency.
                        let hasBlockedSells = result.overSellWarnings.contains { $0.currencyCode == currency.code }
                        HStack(spacing: 14) {
                            figure(PulseLocalization.localizedString("poolBudget.scenario.cashBefore"),
                                   currency.cashBalance.map { PriceFormatter.money($0, currencyCode: currency.code) })
                            figure(PulseLocalization.localizedString("poolBudget.scenario.cashAfter"),
                                   netCash.map { PriceFormatter.money($0, currencyCode: currency.code) }, assumed: true)
                            if hasBlockedSells {
                                figure(PulseLocalization.localizedString("poolBudget.scenario.proceedsPending"), nil)
                            } else {
                                figure(PulseLocalization.localizedString("poolBudget.scenario.proceedsPlanned"),
                                       PriceFormatter.money(currency.plannedSellAmount, currencyCode: currency.code))
                            }
                        }

                        HStack(spacing: 14) {
                            figure(PulseLocalization.localizedString("poolBudget.scenario.holdingsBefore"),
                                   PriceFormatter.money(currency.holdingsBefore, currencyCode: currency.code))
                            figure(PulseLocalization.localizedString("poolBudget.scenario.holdingsAfter"),
                                   PriceFormatter.money(currency.holdingsAfter, currencyCode: currency.code),
                                   assumed: true)
                            // The purchase gap deliberately does not offset
                            // pending sales, so it answers "can I afford this
                            // today". With no recorded balance there is no gap
                            // to state.
                            figure(PulseLocalization.localizedString("poolBudget.scenario.purchaseGap"),
                                   currency.cashBalance == nil
                                   ? nil
                                   : PriceFormatter.money(currency.purchaseBudgetGap, currencyCode: currency.code))
                        }

                        figure(PulseLocalization.localizedString("poolBudget.scenario.topThree"),
                               String(format: "%.1f%% → %.1f%%", currency.topThreeBefore, currency.topThreeAfter))
                        ForEach(currency.holdings) { holding in
                            HStack(spacing: 8) {
                                Text(holding.name).font(PoolType.label).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(PriceFormatter.quantity(holding.beforeQuantity) + " → " + PriceFormatter.quantity(holding.afterQuantity))
                                Text((holding.beforePercent.map { String(format: "%.1f%%", $0) } ?? "—") + " → " + (holding.afterPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
                                    .foregroundStyle(.secondary)
                            }.font(PoolType.label.monospacedDigit())
                        }

                        if !currency.sectors.isEmpty {
                            Text(PulseLocalization.localizedString("poolBudget.scenario.sectors")).font(PoolType.labelMedium)
                            ForEach(currency.sectors) { sector in
                                HStack(spacing: 8) {
                                    Text(sector.name).font(PoolType.label)
                                    Spacer(minLength: 4)
                                    Text(PriceFormatter.money(sector.holdingsBefore, currencyCode: currency.code))
                                        .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(PriceFormatter.money(sector.holdingsAfter, currencyCode: currency.code))
                                        .font(PoolType.labelMedium.monospacedDigit())
                                }
                            }
                        }

                        if !currency.pools.isEmpty {
                            Text(PulseLocalization.localizedString("poolBudget.scenario.pools")).font(PoolType.labelMedium)
                            ForEach(currency.pools) { pool in
                                HStack(spacing: 8) {
                                    Image(systemName: pool.pool.symbolName)
                                        .font(.system(size: 10)).foregroundStyle(pool.pool.tint)
                                    Text(pool.pool.title).font(PoolType.label)
                                    Spacer(minLength: 4)
                                    Text(PriceFormatter.money(pool.heldAmount, currencyCode: currency.code))
                                        .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text("≈" + PriceFormatter.money(pool.projectedAmount, currencyCode: currency.code))
                                        .font(PoolType.assumedNumber)
                                    if let limit = pool.limit {
                                        Text("/ " + PriceFormatter.money(limit, currencyCode: currency.code))
                                            .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    if pool.overLimitAmount > 0 {
                                        Text(PulseLocalization.localizedString("poolBudget.scenario.overPrefix")
                                             + PriceFormatter.money(pool.overLimitAmount, currencyCode: currency.code))
                                            .font(PoolType.label).foregroundStyle(.orange)
                                    }
                                    if pool.needsReconciliation {
                                        Text(PulseLocalization.localizedString("poolBudget.scenario.reviewFloor"))
                                            .font(PoolType.label).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .padding(9)
                    .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Text(PulseLocalization.localizedString("poolBudget.scenario.noModify"))
                .font(PoolType.labelMedium).foregroundStyle(.secondary)
        }
    }

    private func figure(_ title: String, _ value: String?, assumed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(PoolType.label).foregroundStyle(.secondary)
            if let value {
                Text(assumed ? PoolAmountText.assumed(value) : value)
                    .font(assumed ? PoolType.assumedNumber : PoolType.number)
            } else {
                Text(PulseLocalization.localizedString("poolBudget.scenario.unknown")).font(PoolType.number).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func savedScenarios(_ entries: [TradePlanEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PulseLocalization.localizedString("poolBudget.scenario.saved")).font(PoolType.chip)

            HStack(spacing: 6) {
                TextField(PulseLocalization.localizedString("poolBudget.scenario.name"), text: $scenarioName)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                Button(PulseLocalization.localizedString("poolBudget.scenario.saveSelection")) {
                    guard accountMatchesDraft else {
                        message = PulseLocalization.localizedString("poolBudget.scenario.error.accountChanged")
                        return
                    }
                    guard let scenario = appState.poolBudgets.saveScenario(
                        name: scenarioName, planIDs: Array(selectedPlanIDs)
                    ) else {
                        message = PulseLocalization.localizedString("poolBudget.scenario.error.saveFailed")
                        return
                    }
                    scenarioName = ""
                    message = PulseLocalization.localizedString("poolBudget.scenario.savedMessage", scenario.name)
                }
                .disabled(selectedPlanIDs.isEmpty || !accountMatchesDraft)
                Spacer()
            }

            if appState.poolBudgets.scenarios.isEmpty {
                Text(PulseLocalization.localizedString("poolBudget.scenario.empty"))
                    .font(PoolType.label).foregroundStyle(.secondary)
            }

            ForEach(appState.poolBudgets.scenarios) { scenario in
                let known = Set(entries.map(\.id))
                let missing = scenario.planIDs.filter { !known.contains($0) }
                HStack(spacing: 8) {
                    Text(scenario.name).font(PoolType.chip)
                    Text(PulseLocalization.localizedString("poolBudget.scenario.planCount", scenario.planIDs.count))
                        .font(PoolType.label).foregroundStyle(.secondary)
                    if !missing.isEmpty {
                        // A saved selection can outlive the plans it names.
                        // Say how many, rather than silently loading a subset.
                        Text(PulseLocalization.localizedString("poolBudget.scenario.plansGone", missing.count))
                            .font(PoolType.label).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Button(PulseLocalization.localizedString("poolBudget.scenario.load")) {
                        selectedPlanIDs = Set(scenario.planIDs.filter { known.contains($0) })
                        message = missing.isEmpty
                            ? PulseLocalization.localizedString("poolBudget.scenario.loaded")
                            : PulseLocalization.localizedString("poolBudget.scenario.loadedPartial", missing.count)
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    Button(PulseLocalization.localizedString("poolBudget.scenario.delete")) {
                        guard accountMatchesDraft else {
                            message = PulseLocalization.localizedString("poolBudget.scenario.error.deleteAccountChanged")
                            return
                        }
                        if !appState.poolBudgets.deleteScenario(id: scenario.id) {
                            message = PulseLocalization.localizedString("poolBudget.scenario.error.deleteFailed")
                        }
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                }
            }

            if message != nil {
                Text(PulseLocalization.localizedString("poolBudget.scenario.footnote"))
                    .font(PoolType.label).foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(.primary.opacity(0.028), in: RoundedRectangle(cornerRadius: 8))
    }
}
