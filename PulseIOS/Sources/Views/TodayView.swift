import SwiftUI
import PulseCore
import PulseUI

// MARK: - Portfolio valuation
//
// One place answers "what is this account worth". Two rules are non-negotiable:
//
//  - A currency whose rate the app does not know is reported on its own line and
//    is *excluded* from the combined figure, which is then labelled as partial.
//    A cross-market total is never produced by adding unlike currencies, and a
//    price we simply do not have is never treated as zero.
//  - Only the account's own ledger is read. `brokeragePortfolio(for:)` is the
//    account-scoped view, so holdings can never be mixed between books.
struct AccountValuation {
    struct CurrencyLine: Identifiable {
        var id: String { currencyCode }
        let currencyCode: String
        let marketValue: Double?
        let cost: Double?
        let holdingPnL: Double?
        let realizedPnL: Double
        let todayPnL: Double?
        /// True when at least one position in this currency has no usable quote,
        /// so the subtotal is a floor rather than the whole picture.
        let hasMissingPrices: Bool
    }

    let lines: [CurrencyLine]
    /// A conversion into CNY, present only when every non-CNY line has a rate.
    let combinedCNY: Double?
    let missingRateCurrencies: [String]
    let positionCount: Int

    var hasAnyPosition: Bool { positionCount > 0 }

    init(items: [WatchItem], quote: (SymbolID) -> Quote?) {
        var buckets: [String: [WatchItem]] = [:]
        for item in items where item.supportsPosition && item.hasPositionHistory {
            buckets[item.symbol.currencyCode, default: []].append(item)
        }

        var built: [CurrencyLine] = []
        for (code, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            var marketValue = 0.0
            var cost = 0.0
            var holdingPnL = 0.0
            var todayPnL = 0.0
            var hasMarketValue = false
            var hasToday = false
            var missing = false
            var realized = 0.0

            for item in bucket {
                realized += item.realizedPnL
                guard let quote = quote(item.symbol) else {
                    // No quote: the position's size and cost are still real, but
                    // its value is unknown. Report the gap instead of a zero.
                    missing = true
                    continue
                }
                guard let valuation = PositionValuation(item: item, quote: quote, basis: .average) else { continue }
                marketValue += valuation.marketValue
                cost += valuation.costPrice * valuation.quantity
                holdingPnL += valuation.holdingPnL
                todayPnL += valuation.todayPnL
                hasMarketValue = true
                hasToday = true
            }

            built.append(CurrencyLine(
                currencyCode: code,
                marketValue: hasMarketValue ? marketValue : nil,
                cost: hasMarketValue ? cost : nil,
                holdingPnL: hasMarketValue ? holdingPnL : nil,
                realizedPnL: realized,
                todayPnL: hasToday ? todayPnL : nil,
                hasMissingPrices: missing
            ))
        }

        lines = built
        positionCount = buckets.values.reduce(0) { $0 + $1.count }

        // Combining currencies needs a rate this build does not own. Rather than
        // invent one, the combined figure appears only for a single-currency
        // book; a multi-currency book names exactly what is not combined.
        let nonCNY = built.filter { $0.currencyCode != "CNY" }
        if nonCNY.isEmpty {
            combinedCNY = built.first?.marketValue
            missingRateCurrencies = []
        } else {
            combinedCNY = nil
            missingRateCurrencies = nonCNY.map(\.currencyCode)
        }
    }

    var totalRealized: [(currency: String, amount: Double)] {
        lines.compactMap { $0.realizedPnL == 0 ? nil : (currency: $0.currencyCode, amount: $0.realizedPnL) }
    }
}

// MARK: - Cash
//
// `BrokerageAccountSettings.cashBalances` is keyed by currency. It is read as
// stored and never merged across currencies.
struct AccountCash {
    let balances: [(currency: String, amount: Double, updatedAt: Date)]

    init(settings: BrokerageAccountSettings?) {
        balances = (settings?.cashBalances ?? [:])
            .map { (currency: $0.key, amount: $0.value.amount, updatedAt: $0.value.updatedAt) }
            .sorted { $0.currency < $1.currency }
    }

    var isEmpty: Bool { balances.isEmpty }
}

// MARK: - Today — exact Mac workbench data, phone layout only

struct TodayView: View {
    var onOpenRoute: ((WorkbenchRoute) -> Void)?
    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchOpenSettings) private var openSettings
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry
    @State private var phase: WorkbenchPhase = .intraday
    @State private var scope: WorkbenchScope = .all
    @State private var selectedSymbol: SymbolID?
    @State private var showCapitalDetail = false
    @State private var reviewTarget: ReviewTargetBox?

    private var scopedItems: [WatchItem] { state.watchlist.allItems.filter { scope.contains($0.symbol.market) } }
    private func makeBoard(now: Date) -> WorkbenchBoard {
        let items = scopedItems
        let settings = state.watchlist.brokerageSettings(for: state.accountID)
        var cash = WorkbenchCashInput()
        cash.balances = (settings?.cashBalances ?? [:]).mapValues(\.amount)
        cash.updatedAt = (settings?.cashBalances ?? [:]).mapValues(\.updatedAt)
        for limit in settings?.poolLimits ?? [] { cash.limits[limit.currency, default: [:]][limit.pool] = limit.amount }
        return WorkbenchBoard(now: now, phase: phase, items: items,
            historyItems: state.historyItems.filter { scope.contains($0.symbol.market) },
            entries: state.planEntries, events: state.tradingEvents.entries(for: items),
            quote: { state.quote($0) }, name: { state.displayName($0) },
            cash: cash, sectorLimits: settings?.sectorLimits ?? [:])
    }
    private func text(_ key: String) -> String { PulseLocalization.localizedString(key) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(board: makeBoard(now: context.date), now: context.date)
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await state.refresh() }
        .task(id: state.accountID) {
            if !state.isDemo { await state.tradingEvents.refresh(items: state.watchlist.allItems) }
        }
        .onChange(of: state.accountID) { _, _ in selectedSymbol = nil }
        .sheet(item: $reviewTarget) { target in
            ReviewEditorSheet(transaction: target.transaction, symbol: target.symbol, account: target.account)
        }
    }
    private func content(board: WorkbenchBoard, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkbenchHeader(title: text("workbench.title"))
                ActiveAccountStrip(title: state.accountName(state.accountID))
                VStack(spacing: 8) {
                    Picker(text("workbench.scope.title"), selection: $scope) {
                        ForEach(WorkbenchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("today.scope")
                    Picker(text("workbench.phase.title"), selection: $phase) {
                        ForEach(WorkbenchPhase.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("today.phase")
                }
                Text(marketLine(now: now, board: board)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                counts(board)
                taskColumn(board)
                summaryColumn(board)
                capitalSummary(board)
                riskSummary(board)
                sectorSummary(board)
                Button { openSettings() } label: {
                    Label(state.activityStatus, systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                if let error = state.tradingEvents.error {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                }
            }.padding(.horizontal, 16).padding(.bottom, 28)
        }
    }
    private func marketLine(now: Date, board: WorkbenchBoard) -> String {
        let days = scope.markets.map { market -> String in
            let day = TradingCalendar.tradingDay(of: market, at: now)
            return "\(market.displayName) \(String(format: "%02d-%02d", day.month, day.day))"
        }.joined(separator: " · ")
        let states = scope.markets.map { "\($0.displayName)：\(sessionLabel(TradingCalendar.state(of: $0, at: now)))" }.joined(separator: " · ")
        return PulseLocalization.localizedString("workbench.meta.line", phase.title, days, states)
            + (board.phaseNote.isEmpty ? "" : " · " + board.phaseNote)
    }
    private func sessionLabel(_ state: SessionState) -> String {
        let key: String
        switch state {
        case .regular: key = "regular"
        case .preMarket: key = "preMarket"
        case .postMarket: key = "postMarket"
        case .overnight: key = "overnight"
        case .closed: key = "closed"
        case .lunchBreak: key = "lunchBreak"
        }
        return text("workbench.session." + key)
    }
    private func counts(_ board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { countLabels(board) }
                VStack(alignment: .leading, spacing: 5) { countLabels(board) }
            }
            if let backlog = board.historyBacklog {
                Button(PulseLocalization.localizedString("workbench.backlog.link", backlog.count)) {
                    state.requestedAccountSection = "reviews"
                    state.selectedTab = WorkbenchRoute.accountTab
                }.font(.caption).foregroundStyle(WorkbenchTheme.blue)
            }
        }
    }
    @ViewBuilder private func countLabels(_ board: WorkbenchBoard) -> some View {
        Label(PulseLocalization.localizedString("workbench.count.reachedSymbols", board.reachedSymbolCount), systemImage: "target")
            .foregroundStyle(board.reachedSymbolCount > 0 ? Color.orange : .secondary)
        Label(PulseLocalization.localizedString("workbench.count.plansToReview", board.plansToReviewCount), systemImage: "checklist")
            .foregroundStyle(board.plansToReviewCount > 0 ? Color.orange : .secondary)
        Label(PulseLocalization.localizedString("workbench.count.todayReviews", board.todayReviewCount), systemImage: "square.and.pencil")
            .foregroundStyle(board.todayReviewCount > 0 ? Color.orange : .secondary)
    }
    private func taskColumn(_ board: WorkbenchBoard) -> some View {
        WorkbenchSection(title: text("workbench.tasks.title")) {
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if board.tasks.isEmpty { Text(text("workbench.tasks.empty")).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(board.tasks) { task in taskRow(task) }
                    ForEach(board.cashNotes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title).font(.footnote)
                            Text(note.detail).font(.caption).foregroundStyle(.orange)
                            Button("账户现金与持仓") { state.selectedTab = WorkbenchRoute.accountTab }.font(.caption)
                        }
                    }
                }
            }
        }
    }
    private func taskRow(_ task: WorkbenchTask) -> some View {
        let selected = selectedSymbol == task.symbol
        return VStack(alignment: .leading, spacing: 7) {
            Button { selectedSymbol = task.symbol } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.caption2)
                        .foregroundStyle(selected ? WorkbenchTheme.blue : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(task.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(task.countText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("today.task.\(task.symbol.description)")
            if selected {
                ForEach(task.plans) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Button(text("workbench.task.review")) { openPlan(row.entry) }
                            Button(text("workbench.task.recordFill")) { presentTradeEntry(.fromPlan(row.entry, backfill: row.entry.canBackfillFill)) }
                        }.font(.caption.weight(.medium))
                    }.padding(.leading, 18)
                }
                if let count = task.reviewCount, let first = task.reviewTransactionIDs.first {
                    Button(PulseLocalization.localizedString("workbench.task.reviewFills", count)) { openReview(first, symbol: task.symbol) }
                        .font(.caption).padding(.leading, 18)
                }
                if let checkpoint = task.checkpointID {
                    Button(text("workbench.task.reviewCheckpoint")) { openReview(checkpoint, symbol: task.symbol) }
                        .font(.caption).padding(.leading, 18)
                }
                if let due = task.dueReviewText { Text(due).font(.caption2).foregroundStyle(.orange).padding(.leading, 18) }
                ForEach(task.verifications) { row in
                    Button { onOpenRoute?(WorkbenchRoute(destination: .symbol(task.symbol), tab: WorkbenchRoute.watchlistTab)) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title).font(.caption)
                            Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.leading, 18)
                }
                if !task.plans.isEmpty {
                    Button(text("workbench.task.allPlans")) { state.selectedTab = WorkbenchRoute.planTab }
                        .font(.caption2).padding(.leading, 18)
                }
            } else if !task.plans.isEmpty {
                Text(task.plans.count == 1 ? task.plans[0].detail : PulseLocalization.localizedString("workbench.task.planCount", task.plans.count))
                    .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 18)
            }
        }.padding(7)
            .background(selected ? WorkbenchTheme.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
    private func summaryColumn(_ board: WorkbenchBoard) -> some View {
        WorkbenchSection(title: text("workbench.summary.title")) {
            WorkbenchCard(padding: 12) {
                if let symbol = selectedSymbol, let summary = board.summary(for: symbol) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(summary.name).font(.subheadline.weight(.semibold)); Spacer(); Text(summary.market.displayName).font(.caption) }
                        HStack { Text(summary.quoteText).monospacedDigit(); Spacer(); Text(summary.quoteStatusText) }.font(.caption)
                        Text(summary.quoteTimestampText).font(.caption2).foregroundStyle(.secondary)
                        ForEach(summary.plans) { row in
                            VStack(alignment: .leading, spacing: 2) { Text(row.title); Text(row.detail).foregroundStyle(.secondary) }.font(.caption)
                        }
                        ForEach(summary.events) { row in
                            VStack(alignment: .leading, spacing: 2) { Text(row.title); Text(row.detail).foregroundStyle(.secondary) }.font(.caption)
                        }
                        if summary.plans.isEmpty && summary.events.isEmpty { Text(text("workbench.summary.inactive")).font(.caption).foregroundStyle(.secondary) }
                        Button(text("workbench.summary.openDetail")) {
                            onOpenRoute?(WorkbenchRoute(destination: .symbol(symbol), tab: WorkbenchRoute.watchlistTab))
                        }.font(.caption)
                    }
                } else { Text(text("workbench.summary.empty")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func capitalSummary(_ board: WorkbenchBoard) -> some View {
        WorkbenchSection(title: text("workbench.capital.title")) {
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text("workbench.capital.subtitle")).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button(text(showCapitalDetail ? "workbench.capital.collapse" : "workbench.capital.expand")) { showCapitalDetail.toggle() }
                        Spacer()
                        Button("账户现金与持仓") { state.selectedTab = WorkbenchRoute.accountTab }
                    }.font(.caption)
                    if board.capitals.isEmpty { Text(text("workbench.capital.empty")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(board.capitals) { capital in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(capital.code).font(.caption.weight(.bold))
                            Text(capital.holdingsText).font(.caption.monospacedDigit())
                            Text(capital.cashText).font(.caption.monospacedDigit()).foregroundStyle(capital.cashIsKnown ? Color.secondary : .orange)
                            if capital.hasSegments {
                                GeometryReader { geo in
                                    HStack(spacing: 0) {
                                        ForEach(Array(capital.segments.enumerated()), id: \.offset) { _, segment in
                                            Rectangle().fill(poolColor(segment.pool)).frame(width: capital.trackScale > 0 ? max(0, geo.size.width * segment.value / capital.trackScale) : 0)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }.frame(height: 8).clipShape(Capsule())
                                Text(showCapitalDetail ? capital.segmentText : PulseLocalization.localizedString("workbench.capital.pricedPart", PriceFormatter.money(capital.segmentTotal, currencyCode: capital.code)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if capital.hasOverflow { Text(text("workbench.capital.overflow")).font(.caption2).foregroundStyle(.orange) }
                            if capital.hasMissingQuote { Text(capital.missingQuoteText).font(.caption2).foregroundStyle(.orange) }
                            if showCapitalDetail && capital.hasUnverified { Text(capital.unverifiedText).font(.caption2).foregroundStyle(.orange) }
                            if capital.plannedBuy > 0 { Text(PulseLocalization.localizedString("workbench.capital.plannedBuy", PriceFormatter.money(capital.plannedBuy, currencyCode: capital.code))).font(.caption2) }
                            if capital.budgetGap > 0 { Text(PulseLocalization.localizedString("workbench.capital.budgetGap", PriceFormatter.money(capital.budgetGap, currencyCode: capital.code))).font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    if board.unvaluableCount > 0 { Text(PulseLocalization.localizedString("workbench.capital.unpriced", board.unvaluableCount)).font(.caption2).foregroundStyle(.orange) }
                    if board.reconciliationCount > 0 { Text(PulseLocalization.localizedString("workbench.capital.unreconciled", board.reconciliationCount)).font(.caption2).foregroundStyle(.orange) }
                }
            }
        }
    }
    private func poolColor(_ pool: PositionPool) -> Color { pool.tint }
    private func riskSummary(_ board: WorkbenchBoard) -> some View {
        WorkbenchSection(title: text("workbench.risk.title")) {
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if board.defenses.isEmpty { Text(text("workbench.risk.empty")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(board.defenses) { row in
                        Button { selectedSymbol = row.symbol } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(row.name); Spacer(); Text(row.valueText).foregroundStyle(row.isWarning ? Color.orange : .secondary) }
                                Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                            }.font(.caption).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private func sectorSummary(_ board: WorkbenchBoard) -> some View {
        WorkbenchSection(title: text("workbench.sector.title")) {
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if board.sectorRows.isEmpty { Text(text("workbench.sector.empty")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(board.sectorRows) { row in
                        HStack {
                            Text("\(row.name) · \(row.currencyCode)")
                            Spacer()
                            Text(String(format: "%.1f%%", row.percent)).monospacedDigit()
                            if row.overLimit { Text(text("workbench.sector.overLimit")).foregroundStyle(.orange) }
                            if row.hasMissingQuote { Text(text("workbench.sector.missingQuote")).foregroundStyle(.orange) }
                        }.font(.caption)
                    }
                    Text(text("workbench.sector.footer") + (board.sectorMissingQuoteCount > 0 ? text("workbench.sector.footerMissing") : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func openPlan(_ entry: TradePlanEntry) {
        onOpenRoute?(WorkbenchRoute(destination: .plan(entry.plan.id, entry.symbol), tab: WorkbenchRoute.planTab))
    }
    private func openReview(_ id: UUID, symbol: SymbolID) {
        guard let transaction = state.historyItems.first(where: { $0.symbol == symbol })?.transactions.first(where: { $0.id == id }) else { return }
        reviewTarget = ReviewTargetBox(transaction: transaction, symbol: symbol, account: state.accountID)
    }
}

// MARK: - A tappable quote row, shared by Today and the watchlist

struct WatchQuoteRow: View {
    let item: WatchItem
    var onTap: (() -> Void)?

    @Environment(IPhoneAppState.self) private var state

    private var quote: Quote? { state.quote(item.symbol) }
    private var palette: ChangePalette { WorkbenchTheme.palette }
    private var change: Double? { quote.map { $0.price - $0.previousClose } }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.displayName(item.symbol))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        WorkbenchTag(text: marketBadge, color: .secondary)
                        Text(item.symbol.description)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    if let quote {
                        Text(WorkbenchFormat.price(quote.price, market: item.symbol.market))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        HStack(spacing: 4) {
                            if let pct = TradeEntryView.changePercent(quote) {
                                Text(WorkbenchFormat.percent(pct))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.color(for: change ?? 0))
                            } else {
                                Text(WorkbenchFormat.missing)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if let label = QuoteFreshness(quote).label {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(WorkbenchFormat.missing)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("暂无行情")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var marketBadge: String {
        item.symbol.sectorIndex != nil ? "行业" : item.symbol.market.displayName
    }
}

// MARK: - Today's plan card

struct TodayPlanCard: View {
    let entry: TradePlanEntry
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry

    private var reached: Bool {
        TradePlanOverview.isReached(entry, currentPrice: { state.freshPrice($0) })
    }

    private var progress: Double {
        guard entry.plan.quantity > 0 else { return 0 }
        return min(1, max(0, entry.filledQuantity / entry.plan.quantity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                WorkbenchTag(
                    text: entry.plan.kind == .buy ? "买入计划" : "卖出计划",
                    color: entry.plan.kind == .buy ? WorkbenchTheme.blue : WorkbenchTheme.down
                )
                Spacer(minLength: 6)
                Text(reached ? "价格条件到达" : waitingLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(reached ? WorkbenchTheme.warning : .secondary)
            }

            Text(state.displayName(entry.symbol))
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("目标 \(targetText)")
                Spacer(minLength: 6)
                Text("计划 \(WorkbenchFormat.quantity(entry.plan.quantity)) 股")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Text("已记成交 \(WorkbenchFormat.quantity(entry.filledQuantity)) / \(WorkbenchFormat.quantity(entry.plan.quantity)) 股")
                Spacer(minLength: 6)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WorkbenchTheme.blue.opacity(0.12))
                    Capsule().fill(WorkbenchTheme.blue).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 4)

            if let badge = conditionBadge {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                    Text(badge)
                }
                .font(.caption2)
                .foregroundStyle(WorkbenchTheme.warning)
            }

            HStack(spacing: 8) {
                Button("详情 / 编辑") { open() }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(WorkbenchTheme.blue)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(WorkbenchTheme.blue.opacity(0.08), in: Capsule())

                Spacer(minLength: 4)

                Button("记成交") { recordFill() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(WorkbenchTheme.blue, in: Capsule())
            }
            .padding(.top, 2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkbenchTheme.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var targetText: String {
        let symbol = entry.plan.kind == .buy ? "≤" : "≥"
        return "\(symbol) \(WorkbenchFormat.price(entry.plan.price, market: entry.symbol.market))"
    }

    private var waitingLabel: String {
        guard let price = state.freshPrice(entry.symbol) else { return "暂无行情" }
        return "距目标 \(PriceFormatter.percent(entry.plan.gapPercent(from: price)))"
    }

    private var conditionBadge: String? {
        switch PositionVerificationBadge.derived(
            from: entry.plan.conditions,
            at: .now,
            currentEvents: state.watchlist.item(for: entry.symbol)?.events ?? []
        ) {
        case .pending: return "手工条件待复核"
        case .needsReview: return "条件需要重新确认"
        case .invalidated: return "条件已作废"
        case .confirmed: return nil
        case nil: return nil
        }
    }

    private func open() {
        onOpenRoute?(WorkbenchRoute(destination: .plan(entry.plan.id, entry.symbol), tab: WorkbenchRoute.planTab))
    }

    private func recordFill() {
        presentTradeEntry(.fromPlan(entry, backfill: entry.canBackfillFill))
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @State private var showsCloudConflict = false
    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    automaticTrackingCard
                    serviceCard
                    NavigationLink("后台行情更新服务") { PushServiceSettings(client: state.pushClient) }
                    Button("立即核对云同步") { state.synchronizeNow() }
                    if state.syncConflict != nil {
                        Button("查看并处理同步冲突") { showsCloudConflict = true }
                            .foregroundStyle(.orange)
                    }
                    dataCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showsCloudConflict) { CloudConflictView() }
    }

    /// Two separate promises, deliberately not folded into one switch:
    /// "关闭自动" is permanent until the user turns it back on, "今日暂停"
    /// expires on its own at the next day boundary.
    private var automaticTrackingCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("自动关注")
                    .font(.headline)

                WorkbenchToggleRow(
                    title: "自动关注",
                    detail: "由持仓、有效计划或置顶关注驱动。关闭后会持续保持关闭，直到你重新打开。",
                    isOn: Binding(
                        get: { state.automaticTrackingEnabled },
                        set: { state.setAutomaticTracking($0) }
                    )
                )

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("今日暂停")
                            .font(.subheadline.weight(.medium))
                        Text(state.pausedToday
                             ? "今天不再重复拉起活动，下个交易日按原授权恢复。"
                             : "只在今天停止，不会改变「自动关注」的长期开关。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if state.pausedToday {
                        Text("已暂停")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(WorkbenchTheme.warning)
                    } else {
                        Button("暂停今天") { state.pauseTrackingToday() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.bordered)
                            .disabled(!state.automaticTrackingEnabled)
                    }
                }
                if !state.automaticTrackingEnabled {
                    Text("「自动关注」关闭时无法暂停今天。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(state.activityStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The honest service state. Nothing here claims a working cloud or push
    /// path; the Lead wires the real services and this card will follow.
    private var serviceCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("云同步与后台推送")
                    .font(.headline)

                WorkbenchUnavailableRow(
                    title: "iCloud 私有库双向同步",
                    reason: "尚未配置。\(state.syncStatus)。本机记录已完整保存，服务接入前不会上传任何账本数据。"
                )
                WorkbenchUnavailableRow(
                    title: "APNs 自动启动活动",
                    reason: "尚未配置推送令牌与后台服务。当前活动只在本机发起，服务可达性由主管道接入后验证。"
                )
                WorkbenchUnavailableRow(
                    title: "锁屏 / 灵动岛 / Watch 镜像",
                    reason: "由活动模块提供；未接入前本页不显示任何模拟的活动状态。"
                )

                Text("这些能力需要有效签名、用户授权和可达的服务端。未配置时如实显示，不会假装已连接。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dataCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("数据")
                    .font(.headline)
                FactRow(name: "当前账户", value: state.accountName(state.accountID))
                Divider()
                FactRow(name: "行情源", value: "多源自动切换")
                Divider()
                FactRow(
                    name: "上次行情刷新",
                    value: state.market.lastRefresh.map(WorkbenchFormat.time) ?? WorkbenchFormat.missing
                )
                Divider()
                FactRow(name: "同步状态", value: state.syncStatus)
                if state.isDemo {
                    Divider()
                    Text("当前是隔离的验收数据模式，不读取也不写入真实账本。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
