import AppKit
import SwiftUI
import PulseCore
import PulseUI

/// The primary instrument surface in the main window. The existing
/// popover detail remains its own page; this view gives the main window a
/// chart-first layout and keeps all business edits inside this pane.
struct MainInstrumentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mainRefreshGeneration) private var mainRefreshGeneration

    let symbol: SymbolID

    @State private var route: PopoverRoute
    @State private var selectedTab: MainInstrumentTab = .position
    @State private var pendingTabReturn: MainInstrumentTab?
    @State private var chartMode: MainChartMode = .intraday
    @State private var candles: [Candle] = []
    @State private var candlesKey: CandleCacheKey?
    @State private var isLoadingCandles = false
    @State private var chartRequestToken = UUID()
    @State private var candleViewport = CandleChartViewport()
    @State private var isEditingThesis = false
    @State private var thesisDraft = ""
    @State private var hostWindow: NSWindow?
    @State private var isWindowActiveVisible = false

    init(symbol: SymbolID) {
        self.symbol = symbol
        _route = State(initialValue: .detail(symbol))
    }

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var item: WatchItem? {
        appState.watchlist.item(for: symbol)
            ?? appState.watchlist.retainedHistoryItem(for: symbol)
    }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }
    private var symbolSupportsPosition: Bool {
        let type: InstrumentType?
        if let resolved = item?.resolvedInstrumentType {
            type = resolved
        } else if symbol.indexID != nil {
            type = .index
        } else if symbol.metalID != nil {
            type = .commodity
        } else if symbol.cryptoPair != nil {
            type = .crypto
        } else {
            type = nil
        }
        return switch type {
        case .index, .commodity: false
        default: true
        }
    }
    private var chartRequest: CandleCacheKey {
        CandleCacheKey(symbol: symbol, period: chartMode.period)
    }
    private var isDashboardVisible: Bool {
        if case .detail(let routedSymbol) = route { return routedSymbol == symbol }
        return false
    }

    var body: some View {
        Group {
            if case .detail(let routedSymbol) = route, routedSymbol == symbol {
                dashboard
            } else {
                routedPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            HostWindowReader { resolved in
                if let current = hostWindow, let resolved, current === resolved { return }
                hostWindow = resolved
                updateWindowVisibility()
            }
        }
        .onAppear(perform: updateWindowVisibility)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let changed = note.object as? NSWindow, changed === hostWindow else { return }
            updateWindowVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
            guard let changed = note.object as? NSWindow, changed === hostWindow else { return }
            updateWindowVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { note in
            guard let changed = note.object as? NSWindow, changed === hostWindow else { return }
            updateWindowVisibility()
        }
        .task(id: QuoteRunKey(symbol: symbol, active: isWindowActiveVisible)) {
            guard isWindowActiveVisible else { return }
            await appState.detailMarketData.run(symbol: symbol)
        }
        .task(id: ChartRefreshKey(
            symbol: symbol,
            mode: chartMode,
            active: isWindowActiveVisible && isDashboardVisible,
            generation: mainRefreshGeneration
        )) {
            guard isWindowActiveVisible, isDashboardVisible else { return }
            let request = chartRequest
            let token = UUID()
            chartRequestToken = token
            await refreshChart(request, token: token)

            let interval: Duration = request.period.isIntraday ? .seconds(61) : .seconds(610)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                let hasCachedData = appState.market.cachedCandles(for: request, maxAge: .infinity)?.isEmpty == false
                    || (candlesKey == request && !candles.isEmpty)
                if !chartMarketIsActive && hasCachedData { continue }
                await refreshChart(request, token: token)
            }
        }
        .onChange(of: symbol) { _, newSymbol in
            route = .detail(newSymbol)
            selectedTab = .position
            pendingTabReturn = nil
            chartMode = .intraday
            candles = []
            candlesKey = nil
            isLoadingCandles = false
            chartRequestToken = UUID()
            candleViewport = CandleChartViewport()
            isEditingThesis = false
            thesisDraft = ""
        }
        .onChange(of: route) { _, newRoute in
            switch newRoute {
            case .position(let routedSymbol, .detail(let returnSymbol))
                where routedSymbol == symbol && returnSymbol == symbol:
                if let pendingTabReturn {
                    selectedTab = pendingTabReturn
                    self.pendingTabReturn = nil
                    route = .detail(symbol)
                }
            case .transactions(let routedSymbol, .detail(let returnSymbol))
                where routedSymbol == symbol && returnSymbol == symbol:
                if let pendingTabReturn {
                    selectedTab = pendingTabReturn
                    self.pendingTabReturn = nil
                    route = .detail(symbol)
                }
            case .detail(let routedSymbol) where routedSymbol == symbol:
                pendingTabReturn = nil
            default:
                break
            }
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        GeometryReader { geometry in
            let tabHeight = min(245, max(200, geometry.size.height * 0.31))
            let chartHeight = max(250, geometry.size.height - 184 - tabHeight)

            VStack(spacing: 0) {
                quoteHeader
                    .frame(height: 76)
                periodPicker
                    .frame(height: 32)
                    .padding(.horizontal, 16)
                chart
                    .frame(height: chartHeight)
                    .padding(.horizontal, 12)
                ohlcvStrip
                    .frame(height: 40)
                    .padding(.horizontal, 16)
                Divider().opacity(0.45)
                tabPicker
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                tabContent
                    .frame(height: tabHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var quoteHeader: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(appState.displayName(for: symbol))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    MarketBadge(market: symbol.market)
                    Text(symbol.displayCode)
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let quote {
                    HStack(spacing: 7) {
                        Text(PriceFormatter.change(quote.change, market: symbol.market))
                        Text(PriceFormatter.percent(quote.changePercent))
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(appState.palette.color(for: quote.change))
                } else {
                    Text(PulseLocalization.localizedString("main.quote.awaiting"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let quote {
                Text(PriceFormatter.price(quote.price, market: symbol.market))
                    .font(.system(size: 29, weight: .semibold).monospacedDigit())
                    .foregroundStyle(appState.palette.color(for: quote.change))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText(value: PriceFormatter.animatablePrice(
                        quote.price,
                        market: symbol.market
                    )))
                    .animation(.snappy(duration: 0.24), value: quote.timestamp)
            } else {
                Text("—")
                    .font(.system(size: 29, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            quoteProvenance
                .frame(width: 175, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var quoteProvenance: some View {
        if let quote {
            let delay = appState.quoteDelayText(for: quote)
            let cadence = appState.quoteCadenceText(for: quote)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(delay == nil ? Color.green.opacity(0.8) : Color.orange)
                        .frame(width: 5, height: 5)
                    Text([delay ?? PulseLocalization.localizedString("quote.realtime"), cadence]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .foregroundStyle(delay == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                }
                Text(quote.sourceName ?? PulseLocalization.localizedString("main.quote.sourceUnknown"))
                    .foregroundStyle(.secondary)
                Text(appState.quoteMarketTimeText(for: quote))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                Text(PulseLocalization.localizedString("main.quote.sourceUnknown"))
                Text("—")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(MainChartMode.allCases, id: \.self) { mode in
                Button {
                    chartMode = mode
                } label: {
                    Text(PulseLocalization.localizedString(mode.titleKey))
                        .font(.system(size: 10, weight: chartMode == mode ? .semibold : .medium))
                        .foregroundStyle(chartMode == mode ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if chartMode == mode {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .stroke(.separator.opacity(0.6), lineWidth: 0.5)
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(PulseLocalization.localizedString(mode.titleKey))
                .accessibilityAddTraits(chartMode == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var chart: some View {
        let shownCandles = chartCandles
        if shownCandles.isEmpty {
            if isLoadingCandles || candlesKey != chartRequest {
                ChartLoadingView()
            } else {
                ContentUnavailableView {
                    Label(
                        PulseLocalization.localizedString("chart.noData"),
                        systemImage: "chart.xyaxis.line"
                    )
                } description: {
                    Text(PulseLocalization.localizedString("chart.noPeriodData", chartMode.period.displayName))
                }
            }
        } else if chartMode == .intraday {
            IntradayChartView(
                candles: sourceCandles,
                previousClose: quote?.previousClose ?? sourceCandles.first?.open ?? 0,
                market: symbol.market,
                palette: appState.palette,
                showsExtendedHours: appState.showsExtendedHours(for: symbol)
            )
        } else {
            CandlestickChartView(
                candles: shownCandles,
                palette: appState.palette,
                period: chartMode.period,
                market: symbol.market,
                highlightsExtendedHours: chartMode.isIntradayKline
                    && appState.showsExtendedHours(for: symbol),
                transactions: chartMode.period == .day ? item?.materializedTransactions() ?? [] : [],
                currencyCode: currencyCode,
                viewport: candleViewport
            )
        }
    }

    private var sourceCandles: [Candle] {
        if candlesKey == chartRequest { return candles }
        return appState.market.cachedCandles(for: chartRequest, maxAge: .infinity) ?? []
    }

    private var chartCandles: [Candle] {
        let raw = sourceCandles
        guard chartMode == .intraday || chartMode.isIntradayKline else { return raw }
        return IntradayTradingSession.filterCandles(
            raw,
            market: symbol.market,
            includesExtendedHours: appState.showsExtendedHours(for: symbol)
        )
    }

    private var ohlcvStrip: some View {
        let latest = chartCandles.last
        let rawValues: [(String, Double?)] = [
            ("main.ohlcv.open", latest?.open ?? quote?.open),
            ("main.ohlcv.high", latest?.high ?? quote?.high),
            ("main.ohlcv.low", latest?.low ?? quote?.low),
            ("main.ohlcv.close", latest?.close ?? quote?.price),
            ("main.ohlcv.volume", latest?.volume ?? quote?.volume)
        ]
        var values: [(String, String)] = []
        values.reserveCapacity(rawValues.count)
        for (key, rawValue) in rawValues {
            let isVolume = key == "main.ohlcv.volume"
            values.append((
                PulseLocalization.localizedString(key),
                formattedOHLCV(rawValue, isVolume: isVolume)
            ))
        }
        return HStack(spacing: 18) {
            ForEach(Array(values.enumerated()), id: \.offset) { pair in
                let entry = pair.element
                HStack(spacing: 5) {
                    Text(entry.0)
                        .foregroundStyle(.tertiary)
                    Text(entry.1)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 9.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }

    private func formattedOHLCV(_ value: Double?, isVolume: Bool) -> String {
        guard let value else { return "—" }
        if isVolume { return PriceFormatter.compact(value) }
        return PriceFormatter.price(value, market: symbol.market)
    }

    private var tabPicker: some View {
        HStack(spacing: 5) {
            ForEach(MainInstrumentTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 10, weight: .medium))
                        Text(PulseLocalization.localizedString(tab.titleKey))
                            .font(.system(size: 10.5, weight: selectedTab == tab ? .semibold : .medium))
                    }
                    .foregroundStyle(selectedTab == tab ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .frame(height: 27)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.065))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.top, 3)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .position:
            positionTab
        case .transactions:
            transactionsTab
        case .plans:
            plansTab
        case .thesis:
            thesisTab
        }
    }

    // MARK: - Position

    private var positionTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !symbolSupportsPosition {
                    Text(PulseLocalization.localizedString("main.position.unavailable"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else if let item, item.supportsPosition {
                    positionSummary(item)
                } else {
                    Text(PulseLocalization.localizedString("position.notSet"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                if symbolSupportsPosition {
                    HStack(spacing: 8) {
                        Button {
                            preparePositionItem()
                            pendingTabReturn = .position
                            route = .trade(symbol, .buy, .detail(symbol))
                        } label: {
                            Label(PulseLocalization.localizedString("trade.buy"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appState.palette.color(isUp: true))
                        Button {
                            preparePositionItem()
                            pendingTabReturn = .position
                            route = .trade(symbol, .sell, .detail(symbol))
                        } label: {
                            Label(PulseLocalization.localizedString("trade.sell"), systemImage: "minus")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            preparePositionItem()
                            route = .calibrate(symbol, .detail(symbol))
                        } label: {
                            Label(PulseLocalization.localizedString("position.quickEditTitle"), systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .softScrollEdgeEffect(for: .all)
    }

    @ViewBuilder
    private func positionSummary(_ item: WatchItem) -> some View {
        let basis = appState.settings.positionCostBasis
        let valuation = quote.flatMap { PositionValuation(item: item, quote: $0, basis: basis) }
        let averageCost = valuation?.averageCost ?? item.averageCost ?? 0
        let basisCost = basis == .diluted
            ? valuation?.costPrice ?? item.ledger?.dilutedCost ?? averageCost
            : valuation?.costPrice ?? averageCost

        VStack(alignment: .leading, spacing: 8) {
            if let valuation {
                HStack(spacing: 16) {
                    metricCell("position.quantity", PriceFormatter.quantity(valuation.quantity))
                    Button {
                        appState.settings.positionCostBasis = basis == .diluted ? .average : .diluted
                    } label: {
                        metricCell(basis.labelKey, PriceFormatter.price(basisCost))
                    }
                    .buttonStyle(.plain)
                    .help(PulseLocalization.localizedString("position.costBasisHelp"))
                    metricCell("position.marketValue", PriceFormatter.money(valuation.marketValue, currencyCode: currencyCode))
                    metricCell(
                        "position.realizedPnL",
                        PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
                        color: item.realizedPnL
                    )
                    .help(PulseLocalization.localizedString("position.realizedPnLHelp"))
                    metricCell(
                        "position.totalFees",
                        (item.ledger?.totalFees ?? 0) > 0
                            ? PriceFormatter.money(item.ledger?.totalFees ?? 0, currencyCode: currencyCode)
                            : "—"
                    )
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    metricCell(
                        "metric.totalPnL",
                        PriceFormatter.signedMoney(valuation.holdingPnL, currencyCode: currencyCode),
                        color: valuation.holdingPnL
                    )
                    metricCell(
                        "position.combinedPnL",
                        PriceFormatter.signedMoney(valuation.totalPnL, currencyCode: currencyCode),
                        color: valuation.totalPnL
                    )
                    Spacer(minLength: 0)
                }
            } else if item.hasPosition {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        metricCell("position.quantity", PriceFormatter.quantity(item.positionQuantity))
                        metricCell(basis.labelKey, PriceFormatter.price(basisCost))
                        metricCell("position.marketValue", "—")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 16) {
                        metricCell(
                            "position.realizedPnL",
                            PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
                            color: item.realizedPnL
                        )
                        .help(PulseLocalization.localizedString("position.realizedPnLHelp"))
                        metricCell("metric.totalPnL", "—")
                        metricCell("position.combinedPnL", "—")
                        metricCell("position.totalFees", (item.ledger?.totalFees ?? 0) > 0
                            ? PriceFormatter.money(item.ledger?.totalFees ?? 0, currencyCode: currencyCode)
                            : "—")
                        Spacer(minLength: 0)
                    }
                }
                Text(PulseLocalization.localizedString("position.waitingQuote"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if item.hasPositionHistory {
                HStack(spacing: 16) {
                    metricCell("position.realizedPnL", PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode), color: item.realizedPnL)
                        .help(PulseLocalization.localizedString("position.realizedPnLHelp"))
                    metricCell("position.combinedPnL", PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode), color: item.realizedPnL)
                    metricCell("position.historyTrades", PulseLocalization.localizedString("position.tradeCount", item.transactions.count))
                    metricCell("position.totalFees", (item.ledger?.totalFees ?? 0) > 0
                        ? PriceFormatter.money(item.ledger?.totalFees ?? 0, currencyCode: currencyCode)
                        : "—")
                    Spacer(minLength: 0)
                }
            } else {
                Text(PulseLocalization.localizedString("position.notSet"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func metricCell(_ key: String, _ value: String, color: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PulseLocalization.localizedString(key))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color.map { appState.palette.color(for: $0) } ?? .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: 88, alignment: .leading)
    }

    // MARK: - Transactions

    private var transactionsTab: some View {
        let entries = Array((item?.ledger?.entries ?? []).reversed())
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if symbolSupportsPosition {
                    Button {
                        preparePositionItem()
                        pendingTabReturn = .transactions
                        route = .trade(symbol, .buy, .detail(symbol))
                    } label: {
                        Label(PulseLocalization.localizedString("trade.buy"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.palette.color(isUp: true))
                    Button {
                        preparePositionItem()
                        pendingTabReturn = .transactions
                        route = .trade(symbol, .sell, .detail(symbol))
                    } label: {
                        Label(PulseLocalization.localizedString("trade.sell"), systemImage: "minus")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        preparePositionItem()
                        route = .calibrate(symbol, .detail(symbol))
                    } label: {
                        Label(PulseLocalization.localizedString("position.quickEditTitle"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Text(PulseLocalization.localizedString("position.tradeCount", entries.count))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            ScrollView {
                if entries.isEmpty {
                    Text(PulseLocalization.localizedString("main.transactions.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            TransactionRow(
                                entry: entry,
                                palette: appState.palette,
                                currencyCode: currencyCode,
                                onOpen: {
                                    pendingTabReturn = .transactions
                                    route = .editTrade(symbol, entry.transaction.id, .detail(symbol))
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .softScrollEdgeEffect(for: .all)
        }
    }

    // MARK: - Trade plans

    private var plansTab: some View {
        let plans = item?.plans ?? []
        return VStack(spacing: 0) {
            HStack {
                Text(PulseLocalization.localizedString("main.plans.caption"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if symbolSupportsPosition {
                    Button {
                        preparePositionItem()
                        route = .plan(symbol, nil, .detail(symbol))
                    } label: {
                        Label(PulseLocalization.localizedString("plan.title.add"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            ScrollView {
                if plans.isEmpty {
                    Text(PulseLocalization.localizedString("main.plans.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(plans) { plan in
                            planRow(plan)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .softScrollEdgeEffect(for: .all)
        }
    }

    private func planRow(_ plan: TradePlan) -> some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(appState.palette.color(isUp: plan.kind == .buy))
                .frame(width: 2, height: 26)
            Button {
                route = .plan(symbol, plan.id, .detail(symbol))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(appState.palette.color(isUp: plan.kind == .buy))
                        Text("\(PriceFormatter.price(plan.price, market: symbol.market)) × \(PriceFormatter.quantity(plan.quantity))")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary)
                        if let current = quote?.price, plan.isReached(at: current), plan.status == .active {
                            Text(PulseLocalization.localizedString("plan.reached"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(appState.palette.color(isUp: plan.kind == .buy))
                        }
                        Spacer(minLength: 4)
                    }
                    Text(plan.note.flatMap { $0.isEmpty ? nil : $0 } ?? PulseLocalization.localizedString("plan.note"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if symbolSupportsPosition {
                Menu {
                    ForEach(TradePlan.Status.allCases, id: \.self) { status in
                        Button {
                            var updated = plan
                            updated.status = status
                            appState.watchlist.setTradePlan(updated, for: symbol)
                        } label: {
                            if plan.status == status {
                                Label(PulseLocalization.localizedString("plan.status.\(status.rawValue)"), systemImage: "checkmark")
                            } else {
                                Text(PulseLocalization.localizedString("plan.status.\(status.rawValue)"))
                            }
                        }
                    }
                    Divider()
                    Button(PulseLocalization.localizedString("plan.delete"), role: .destructive) {
                        appState.watchlist.deleteTradePlan(plan.id, for: symbol)
                    }
                } label: {
                    Text(PulseLocalization.localizedString("plan.status.\(plan.status.rawValue)"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .help(PulseLocalization.localizedString("main.plans.changeStatus"))
            } else {
                Text(PulseLocalization.localizedString("plan.status.\(plan.status.rawValue)"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Thesis

    private var thesisTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(PulseLocalization.localizedString("detail.section.thesis"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !isEditingThesis {
                    Button {
                        thesisDraft = item?.thesis ?? ""
                        isEditingThesis = true
                    } label: {
                        Label(PulseLocalization.localizedString("main.thesis.edit"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if isEditingThesis {
                TextEditor(text: $thesisDraft)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.5), lineWidth: 0.5))
                HStack {
                    Spacer()
                    Button(PulseLocalization.localizedString("action.cancel")) {
                        thesisDraft = item?.thesis ?? ""
                        isEditingThesis = false
                    }
                    Button(PulseLocalization.localizedString("action.save")) {
                        preparePositionItem()
                        appState.watchlist.setThesis(thesisDraft, for: symbol)
                        isEditingThesis = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            } else {
                ScrollView {
                    let thesis = item?.thesis.flatMap { $0.isEmpty ? nil : $0 }
                    Text(thesis ?? PulseLocalization.localizedString("detail.thesis.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(thesis == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .softScrollEdgeEffect(for: .all)
                .contentShape(Rectangle())
                .onTapGesture {
                    thesisDraft = item?.thesis ?? ""
                    isEditingThesis = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - In-pane navigation

    @ViewBuilder
    private var routedPage: some View {
        switch route {
        case .position(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            PositionHubView(symbol: symbol, returnRoute: returnRoute, route: $route)
                .padding(.top, 8)
        case .trade(let routedSymbol, let side, let returnRoute) where routedSymbol == symbol:
            TradeEntryView(symbol: symbol, side: side, returnRoute: returnRoute, route: $route)
        case .editTrade(let routedSymbol, let transactionID, let returnRoute) where routedSymbol == symbol:
            if let transaction = item?.transactions.first(where: { $0.id == transactionID }) {
                TradeEntryView(
                    symbol: symbol,
                    editing: transaction,
                    returnRoute: returnRoute,
                    route: $route
                )
            } else {
                dashboard
                    .onAppear { route = .detail(symbol) }
            }
        case .transactions(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            TransactionListView(symbol: symbol, returnRoute: returnRoute, route: $route)
        case .plan(let routedSymbol, let planID, let returnRoute) where routedSymbol == symbol:
            PlanEditorView(symbol: symbol, planID: planID, returnRoute: returnRoute, route: $route)
        case .calibrate(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            if let item {
                VStack(spacing: 0) {
                    PositionPageHeader(
                        symbol: symbol,
                        title: nil,
                        onBack: { route = returnRoute.popoverRoute }
                    )
                    ScrollView {
                        PositionEditorView(
                            item: item,
                            quote: quote,
                            palette: appState.palette,
                            onCancel: { route = returnRoute.popoverRoute },
                            onSave: { quantity, cost in
                                appState.watchlist.calibratePosition(symbol, quantity: quantity, averageCost: cost)
                                route = returnRoute.popoverRoute
                            },
                            onClear: {
                                appState.watchlist.clearPosition(symbol)
                                route = returnRoute.popoverRoute
                            }
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }
                    .softScrollEdgeEffect(for: .all)
                }
            } else {
                dashboard
                    .onAppear { route = .detail(symbol) }
            }
        default:
            dashboard
                .onAppear { route = .detail(symbol) }
        }
    }

    // MARK: - Data and visibility

    private func refreshChart(_ request: CandleCacheKey, token: UUID) async {
        guard request.symbol == symbol, request == chartRequest else { return }
        if let cached = appState.market.cachedCandles(for: request, maxAge: .infinity) {
            candles = cached
            candlesKey = request
        }
        isLoadingCandles = (candlesKey != request || candles.isEmpty)
        let loaded = await appState.detailMarketData.loadCandles(
            symbol: request.symbol,
            period: request.period,
            count: candleCount(for: request.period)
        )
        guard !Task.isCancelled,
              token == chartRequestToken,
              request.symbol == symbol,
              request == chartRequest else { return }
        candles = loaded
        candlesKey = request
        isLoadingCandles = false
    }

    private func candleCount(for period: CandlePeriod) -> Int {
        switch period {
        case .minute5, .minute15, .minute30, .hour1:
            guard let minutes = period.intradayMinutes else { return 240 }
            let sessionMinutes = switch symbol.market {
            case .sh, .sz: 240
            case .hk: 330
            case .us: 16 * 60
            case .crypto: 24 * 60
            case .metal: 23 * 60
            case .metalCN: 780
            case .jp: 330
            case .kr, .kq: 390
            }
            let historyDays = switch symbol.market {
            case .crypto, .metal: 1
            case .us, .hk, .sh, .sz, .metalCN, .jp, .kr, .kq: 5
            }
            return min(max(sessionMinutes / minutes * historyDays, 240), 1_000)
        case .day: return 250
        case .week: return 260
        case .month: return 240
        case .minute1: return IntradayTrendSnapshot.recommendedCandleCount(for: symbol.market)
        }
    }

    private var chartMarketIsActive: Bool {
        let state = TradingCalendar.state(of: symbol.market)
        if symbol.market == .us && !appState.showsExtendedHours(for: symbol) {
            return state == .regular
        }
        return TradingCalendar.isActive(symbol.market)
    }

    private func preparePositionItem() {
        guard appState.watchlist.item(for: symbol) == nil else { return }
        appState.watchlist.materializeItem(SymbolInfo(
            symbol: symbol,
            name: quote?.name ?? appState.displayName(for: symbol)
        ))
    }

    private func updateWindowVisibility() {
        let visible = hostWindow.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
        if visible != isWindowActiveVisible {
            isWindowActiveVisible = visible
        }
    }
}

private enum MainInstrumentTab: CaseIterable {
    case position
    case transactions
    case plans
    case thesis

    var titleKey: String {
        switch self {
        case .position: "main.tab.position"
        case .transactions: "main.tab.transactions"
        case .plans: "main.tab.plans"
        case .thesis: "main.tab.thesis"
        }
    }

    var symbolName: String {
        switch self {
        case .position: "briefcase"
        case .transactions: "list.bullet.rectangle"
        case .plans: "target"
        case .thesis: "text.alignleft"
        }
    }
}

/// `minute1` is shared market data for the 1-minute K-line and the separate
/// intraday trend. Keeping the mode here leaves CandlePeriod.isMinuteK's
/// established meaning untouched.
private enum MainChartMode: CaseIterable, Hashable {
    case intraday
    case minute1
    case minute5
    case minute15
    case minute30
    case hour1
    case day
    case week
    case month

    var period: CandlePeriod {
        switch self {
        case .intraday, .minute1: .minute1
        case .minute5: .minute5
        case .minute15: .minute15
        case .minute30: .minute30
        case .hour1: .hour1
        case .day: .day
        case .week: .week
        case .month: .month
        }
    }

    var titleKey: String {
        switch self {
        case .intraday: "main.period.intraday"
        case .minute1: "main.period.minute1"
        case .minute5: "main.period.minute5"
        case .minute15: "main.period.minute15"
        case .minute30: "main.period.minute30"
        case .hour1: "main.period.hour1"
        case .day: "main.period.day"
        case .week: "main.period.week"
        case .month: "main.period.month"
        }
    }

    var isIntradayKline: Bool { self != .intraday && period.isIntraday }
}

private struct QuoteRunKey: Hashable {
    var symbol: SymbolID
    var active: Bool
}

private struct ChartRefreshKey: Hashable {
    var symbol: SymbolID
    var mode: MainChartMode
    var active: Bool
    var generation: Int
}
