import SwiftUI
import PulseCore
import PulseUI

// MARK: - Symbol detail
//
// Quotes and charts, both read from the live store. A chart that cannot be
// loaded says so; it never falls back to a fabricated series.
struct SymbolDetailView: View {
    let symbol: SymbolID

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry

    @State private var period: CandlePeriod = .day
    @State private var candles: [Candle] = []
    @State private var isLoadingChart = false
    @State private var chartError: String?

    private var item: WatchItem? { state.watchlist.item(for: symbol) }
    private var quote: Quote? { state.quote(symbol) }
    private var palette: ChangePalette { WorkbenchTheme.palette }

    private var plans: [TradePlan] { item?.plans ?? [] }
    private var transactions: [PositionTransaction] { item?.transactions ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                priceHeader
                chartSection
                positionSection
                plansSection
                actionRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .navigationTitle(state.displayName(symbol))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: period) { await loadCandles() }
        .refreshable { await state.refresh() }
    }

    // MARK: Header

    private var priceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(WorkbenchFormat.price(quote.price, market: symbol.market))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    if let pct = TradeEntryView.changePercent(quote) {
                        Text(WorkbenchFormat.percent(pct))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(palette.color(for: quote.price - quote.previousClose))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    Text(symbol.description)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(WorkbenchFormat.currencyName(symbol.currencyCode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let source = quote.sourceName ?? quote.sourceID {
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("源时间 \(WorkbenchFormat.time(quote.timestamp))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let label = QuoteFreshness(quote).label {
                    WorkbenchTag(text: label, color: WorkbenchTheme.warning)
                }
            } else {
                Text("暂无行情")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("数据源没有返回这个标的的报价。价格留空，不按 0 显示。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let quote {
                HStack(spacing: 14) {
                    stat("昨收", WorkbenchFormat.price(quote.previousClose, market: symbol.market))
                    stat("今开", WorkbenchFormat.price(quote.open, market: symbol.market))
                    stat("最高", WorkbenchFormat.price(quote.high, market: symbol.market))
                    stat("最低", WorkbenchFormat.price(quote.low, market: symbol.market))
                }
                .padding(.top, 4)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chart

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("周期", selection: $period) {
                Text("分时").tag(CandlePeriod.minute1)
                Text("日").tag(CandlePeriod.day)
                Text("周").tag(CandlePeriod.week)
                Text("月").tag(CandlePeriod.month)
            }
            .pickerStyle(.segmented)

            ZStack {
                if isLoadingChart, candles.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let chartError, candles.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(chartError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if candles.isEmpty {
                    Text("暂无K线数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    chart
                }
            }
            .frame(minHeight: 220)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var chart: some View {
        if period == .minute1, let quote {
            IntradayChartView(
                candles: candles,
                previousClose: quote.previousClose,
                market: symbol.market,
                palette: palette,
                showsExtendedHours: symbol.market == .us,
                showsPercentageAxis: true
            )
            .frame(height: 220)
        } else {
            CandlestickChartView(
                candles: candles,
                palette: palette,
                period: period,
                market: symbol.market,
                transactions: transactions,
                currencyCode: symbol.currencyCode
            )
            .frame(height: 240)
        }
    }

    private func loadCandles() async {
        isLoadingChart = true
        chartError = nil
        defer { isLoadingChart = false }
        do {
            candles = try await state.candles(symbol, period: period)
            if candles.isEmpty { chartError = "数据源没有返回这个周期的K线。" }
        } catch is CancellationError {
        } catch {
            if candles.isEmpty { chartError = "K线暂不可用：\(error.localizedDescription)" }
        }
    }

    // MARK: Position

    @ViewBuilder
    private var positionSection: some View {
        if let item, item.supportsPosition, item.hasPositionHistory {
            WorkbenchSection(title: "我的持仓") {
                WorkbenchCard {
                    if let quote, let valuation = PositionValuation(item: item, quote: quote, basis: .average) {
                        VStack(spacing: 10) {
                            HStack(spacing: 12) {
                                StatCell(
                                    label: "持有数量",
                                    value: WorkbenchFormat.quantity(valuation.quantity)
                                )
                                StatCell(
                                    label: "成本价",
                                    value: WorkbenchFormat.price(valuation.costPrice, market: symbol.market)
                                )
                                StatCell(
                                    label: "市值",
                                    value: WorkbenchFormat.money(valuation.marketValue, currencyCode: symbol.currencyCode)
                                )
                            }
                            Divider()
                            HStack(spacing: 12) {
                                StatCell(
                                    label: "浮动盈亏",
                                    value: WorkbenchFormat.signedMoney(valuation.holdingPnL, currencyCode: symbol.currencyCode),
                                    tone: palette.color(for: valuation.holdingPnL),
                                    detail: WorkbenchFormat.percent(valuation.holdingReturnPercent)
                                )
                                StatCell(
                                    label: "已实现盈亏",
                                    value: WorkbenchFormat.signedMoney(valuation.realizedPnL, currencyCode: symbol.currencyCode),
                                    tone: palette.color(for: valuation.realizedPnL)
                                )
                                StatCell(
                                    label: "成交笔数",
                                    value: "\(transactions.count)"
                                )
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("持有 \(WorkbenchFormat.quantity(item.positionQuantity)) 股")
                                .font(.subheadline.weight(.medium))
                            Text("暂无行情，市值与浮动盈亏留空，不按 0 计算。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        } else if let item, !item.supportsPosition {
            WorkbenchUnavailableRow(
                title: "不能记录持仓",
                reason: "指数是计算出来的基准，不是可以直接持有的证券，因此这里不提供买入或持仓记录。"
            )
        }
    }

    // MARK: Plans

    @ViewBuilder
    private var plansSection: some View {
        if !plans.isEmpty {
            WorkbenchSection(title: "相关计划") {
                VStack(spacing: 8) {
                    ForEach(plans) { plan in
                        PlanCompactRow(plan: plan, symbol: symbol)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actionRow: some View {
        VStack(spacing: 10) {
            if item?.supportsPosition ?? true {
                Button {
                    presentTradeEntry(.global(symbol: symbol, account: state.accountID))
                } label: {
                    Label("记一笔已完成的成交", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }

            if let item {
                Button {
                    state.watchlist.setPinned(item.symbol, in: state.watchlist.selectedGroupID,
                                              pinned: !state.watchlist.isPinned(item.symbol, in: state.watchlist.selectedGroupID))
                } label: {
                    Label(
                        state.watchlist.isPinned(symbol, in: state.watchlist.selectedGroupID) ? "取消置顶" : "置顶在主标的",
                        systemImage: "pin"
                    )
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 42)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Compact plan row

struct PlanCompactRow: View {
    let plan: TradePlan
    let symbol: SymbolID

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WorkbenchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    WorkbenchTag(
                        text: plan.kind == .buy ? "买入" : "卖出",
                        color: plan.kind == .buy ? WorkbenchTheme.blue : WorkbenchTheme.down
                    )
                    Spacer(minLength: 6)
                    Text(PlanStatusText.label(for: plan.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("目标 \(WorkbenchFormat.price(plan.price, market: symbol.market))")
                    Spacer(minLength: 6)
                    Text("计划 \(WorkbenchFormat.quantity(plan.quantity)) 股")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note = plan.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

enum PlanStatusText {
    static func label(for status: TradePlan.Status) -> String {
        switch status {
        case .active: "进行中"
        case .done: "已停止"
        case .cancelled: "已放弃"
        }
    }

    static func label(for state: TradePlanEntry.DisplayState) -> String {
        switch state {
        case .waiting: "进行中"
        case .filled: "数量已完成"
        case .stopped: "已停止"
        case .abandoned: "已放弃"
        }
    }

    static func color(for state: TradePlanEntry.DisplayState) -> Color {
        switch state {
        case .waiting: WorkbenchTheme.blue
        case .filled: WorkbenchTheme.down
        case .stopped, .abandoned: .secondary
        }
    }

    static func label(for pool: PositionPool) -> String {
        switch pool.effectivePurpose {
        case .strategic: "战略底仓"
        case .tactical: "机动仓"
        case .unassigned, .observation: "未分配"
        }
    }

    static func label(for funding: PositionFundingSource?) -> String {
        switch funding {
        case .own: "自有资金"
        case .margin: "融资"
        case .unmarked: "已清空标注"
        case nil: "未填写"
        }
    }

    static func label(for kind: TradePlanCondition.Kind) -> String {
        switch kind {
        case .logic: "逻辑条件"
        case .event: "事件条件"
        case .manual: "手工条件"
        }
    }

    static func label(for state: TradePlanCondition.State) -> String {
        switch state {
        case .pending: "待复核"
        case .confirmed: "已确认"
        case .needsReview: "需重新确认"
        case .invalidated: "已作废"
        }
    }
}
