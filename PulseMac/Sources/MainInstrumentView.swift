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
    @State private var draftRouteAccount: BrokerageAccountID?
    @State private var selectedTab: MainInstrumentTab = .position
    @State private var pendingTabReturn: MainInstrumentTab?
    @State private var chartMode: MainChartMode = .intraday
    @State private var candles: [Candle] = []
    @State private var candlesKey: CandleCacheKey?
    @State private var isLoadingCandles = false
    @State private var chartRequestToken = UUID()
    @State private var candleViewport = CandleChartViewport()
    @State private var annotationController = ChartAnnotationController()
    @State private var drawingSession = MainChartDrawingSession()
    @State private var editingDrawing: ChartDrawing?
    @State private var isEditingThesis = false
    @State private var thesisDraft = ""
    @State private var thesisAccount: BrokerageAccountID?
    /// The chart drawing draft has its own source; a thesis edit must not
    /// repoint a drawing that is already open.
    @State private var frozenAccount: BrokerageAccountID?
    @State private var hostWindow: NSWindow?
    @State private var isWindowActiveVisible = false

    /// Non-nil only when the store still holds the ledger this pane's drafts
    /// came from.
    private var accountMatchesDraft: Bool {
        frozenAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    private var thesisMatchesAccount: Bool {
        thesisAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    /// Chart overlays are a viewing preference rather than instrument data, so they stay in
    /// this machine's defaults and out of the store and the sync file. The moving averages
    /// share one bitmask so the menu can toggle each window on its own.
    @AppStorage("pulse.chart.movingAverages.v2") private var movingAverageMask = MovingAveragePeriod.allMask
    @AppStorage("pulse.chart.macd.v1") private var showsMACD = false

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
    private var enabledMovingAverages: [MovingAveragePeriod] {
        MovingAveragePeriod.allCases.filter { movingAverageMask & $0.mask != 0 }
    }
    private var indicatorConfiguration: ChartIndicatorConfiguration {
        ChartIndicatorConfiguration(movingAverages: enabledMovingAverages, showsMACD: showsMACD)
    }
    /// Binds one window to its bit, so the menu toggles MA5 / MA10 / MA20 / MA60 separately.
    private func movingAverageBinding(_ period: MovingAveragePeriod) -> Binding<Bool> {
        Binding(
            get: { movingAverageMask & period.mask != 0 },
            set: { isOn in
                if isOn {
                    movingAverageMask |= period.mask
                } else {
                    movingAverageMask &= ~period.mask
                }
            }
        )
    }
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
        .onAppear {
            updateWindowVisibility()
            attachDrawingHistoryHandlers()
            if frozenAccount == nil { frozenAccount = appState.watchlist.activeBrokerageAccountID }
        }
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
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, account in
            // Keep source-scoped editors mounted; only idle account data resets.
            if !route.preservesAccountDraft {
                route = .detail(symbol)
                pendingTabReturn = nil
            }
            if editingDrawing == nil { frozenAccount = account }
            if editingDrawing == nil {
                drawingSession.clear()
                annotationController = ChartAnnotationController()
                attachDrawingHistoryHandlers()
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
            annotationController = ChartAnnotationController()
            drawingSession.clear()
            editingDrawing = nil
            attachDrawingHistoryHandlers()
        }
        .onChange(of: editingDrawing?.id) { _, id in
            if id == nil { frozenAccount = appState.watchlist.activeBrokerageAccountID }
        }
        .onChange(of: chartMode) { _, _ in
            annotationController.resetTransientState()
            editingDrawing = nil
        }
        .onChange(of: activeIntradaySessionDay) { _, _ in
            guard chartMode == .intraday else { return }
            annotationController.resetTransientState()
        }
        .onChange(of: route) { _, newRoute in
            draftRouteAccount = newRoute.preservesAccountDraft
                ? appState.watchlist.activeBrokerageAccountID : nil
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
            let chartHeight = max(240, geometry.size.height - 216 - tabHeight)

            VStack(spacing: 0) {
                quoteHeader
                    .frame(height: 76)
                periodPicker
                    .frame(height: 32)
                    .padding(.horizontal, 16)
                annotationToolbar
                    .frame(height: 32)
                    .padding(.horizontal, 16)
                chartSurface
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

    private var annotationToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                toolButtons
                snappingButton
                Toggle(PulseLocalization.localizedString("main.chart.plans"), isOn: planVisibility)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Toggle(PulseLocalization.localizedString("main.chart.drawings"), isOn: drawingVisibility)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Button {
                    clearPlanFocusOrToggleFit()
                } label: {
                    Label(PulseLocalization.localizedString("main.chart.fitPlans"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(isPlanFitActive ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(PulseLocalization.localizedString(isPlanFitActive
                    ? "main.chart.fitPlans.resetHelp"
                    : "main.chart.fitPlans.help"))
                .accessibilityAddTraits(isPlanFitActive ? .isSelected : [])
                indicatorMenu
                annotationMoreMenu
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                toolButtons
                indicatorMenu
                annotationMoreMenu
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10, weight: .medium))
    }

    private var toolButtons: some View {
        HStack(spacing: 3) {
            chartToolButton(.browse, symbolName: "cursorarrow")
            chartToolButton(.horizontal, symbolName: "line.3.horizontal")
            chartToolButton(.trend, symbolName: "chart.line.uptrend.xyaxis")
            chartToolButton(.measure, symbolName: "ruler")
        }
    }

    private var snappingButton: some View {
        Button {
            annotationController.snappingEnabled.toggle()
        } label: {
            Label(PulseLocalization.localizedString("main.chart.snap"), systemImage: "scope")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(annotationController.snappingEnabled ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 5)
                .frame(height: 24)
                .background {
                    if annotationController.snappingEnabled {
                        RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.13))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(PulseLocalization.localizedString("main.chart.snap.help"))
        .accessibilityLabel(PulseLocalization.localizedString("main.chart.snap"))
        .accessibilityAddTraits(annotationController.snappingEnabled ? .isSelected : [])
    }

    private var isPlanFitActive: Bool {
        annotationController.fitsPlans || annotationController.focusedPlanPrice != nil
    }

    private func clearPlanFocusOrToggleFit() {
        if annotationController.focusedPlanPrice != nil {
            annotationController.focusedPlanPrice = nil
            annotationController.fitsPlans = false
        } else {
            annotationController.fitsPlans.toggle()
        }
    }

    private func chartToolButton(_ tool: ChartAnnotationTool, symbolName: String) -> some View {
        let key = chartToolTitleKey(tool)
        return Button {
            annotationController.tool = tool
        } label: {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(annotationController.tool == tool ? Color.accentColor : Color.secondary)
                .frame(width: 25, height: 24)
                .background {
                    if annotationController.tool == tool {
                        RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.13))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(PulseLocalization.localizedString(key))
        .accessibilityLabel(PulseLocalization.localizedString(key))
        .accessibilityAddTraits(annotationController.tool == tool ? .isSelected : [])
    }

    private var annotationMoreMenu: some View {
        Menu {
            Toggle(PulseLocalization.localizedString("main.chart.plans"), isOn: planVisibility)
            Toggle(PulseLocalization.localizedString("main.chart.drawings"), isOn: drawingVisibility)
            Toggle(PulseLocalization.localizedString("main.chart.snap"), isOn: snappingBinding)
                .help(PulseLocalization.localizedString("main.chart.snap.help"))
            Divider()
            Toggle(PulseLocalization.localizedString("main.chart.historicalPlans"), isOn: historicalPlanVisibility)
            Button {
                clearPlanFocusOrToggleFit()
            } label: {
                Label(PulseLocalization.localizedString("main.chart.fitPlans"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(isPlanFitActive ? Color.accentColor : Color.primary)
            }
            .help(PulseLocalization.localizedString(isPlanFitActive
                ? "main.chart.fitPlans.resetHelp"
                : "main.chart.fitPlans.help"))
            Button {
                annotationController.clearMeasurement()
            } label: {
                Label(PulseLocalization.localizedString("chart.annotation.measure.clear"), systemImage: "eraser")
            }
            Divider()
            Button(PulseLocalization.localizedString("main.chart.deleteSelected"), role: .destructive) {
                _ = annotationController.deleteSelected()
            }
            .disabled(!annotationController.canDeleteSelected)
        } label: {
            Label(PulseLocalization.localizedString("main.chart.more"), systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .help(PulseLocalization.localizedString("main.chart.more"))
    }

    /// Overlays are frequent enough to deserve their own entry rather than a trip into the
    /// annotation menu, so it sits in the toolbar and survives the narrow fallback layout.
    private var indicatorMenu: some View {
        Menu {
            Section(PulseLocalization.localizedString("main.chart.indicators.movingAverages")) {
                ForEach(MovingAveragePeriod.allCases, id: \.self) { period in
                    Toggle(period.label, isOn: movingAverageBinding(period))
                }
            }
            Divider()
            Toggle(PulseLocalization.localizedString("main.chart.indicators.macd"), isOn: $showsMACD)
        } label: {
            Label(
                PulseLocalization.localizedString("main.chart.indicators"),
                systemImage: "chart.xyaxis.line"
            )
            .foregroundStyle(indicatorConfiguration.isHidden ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(PulseLocalization.localizedString("main.chart.indicators.help"))
    }

    private var planVisibility: Binding<Bool> {
        Binding(get: { annotationController.showsPlans }, set: { annotationController.showsPlans = $0 })
    }

    private var drawingVisibility: Binding<Bool> {
        Binding(get: { annotationController.showsDrawings }, set: { annotationController.showsDrawings = $0 })
    }

    private var historicalPlanVisibility: Binding<Bool> {
        Binding(get: { annotationController.showsHistoricalPlans }, set: { annotationController.showsHistoricalPlans = $0 })
    }

    private var snappingBinding: Binding<Bool> {
        Binding(get: { annotationController.snappingEnabled }, set: { annotationController.snappingEnabled = $0 })
    }

    private func chartToolTitleKey(_ tool: ChartAnnotationTool) -> String {
        switch tool {
        case .browse: "main.chart.tool.browse"
        case .horizontal: "main.chart.tool.horizontal"
        case .trend: "main.chart.tool.trend"
        case .measure: "main.chart.tool.measure"
        }
    }

    private var chartSurface: some View {
        Group {
            if let drawing = editingDrawing {
                VStack(spacing: 6) {
                    AccountDraftNotice(account: frozenAccount ?? appState.watchlist.activeBrokerageAccountID)
                    MainChartDrawingEditor(
                        drawing: drawing,
                        symbol: symbol,
                        currencyCode: currencyCode,
                        onSave: { updated in
                            let saved = commitDrawing(updated, for: symbol)
                            if saved { editingDrawing = nil }
                            return saved
                        },
                        onCancel: { editingDrawing = nil }
                    )
                }
            } else {
                chart
            }
        }
        .background {
            MainChartKeyboardMonitor(
                isEnabled: isDashboardVisible && isWindowActiveVisible,
                allowsChartFocus: editingDrawing == nil,
                onEscape: handleChartEscape,
                onDelete: handleChartDelete,
                onUndo: handleChartUndo,
                onRedo: handleChartRedo
            )
            .allowsHitTesting(false)
        }
    }

    private var chart: some View {
        let shownCandles = chartCandles
        return Group {
            if shownCandles.isEmpty {
                if isLoadingCandles || candlesKey != chartRequest {
                    ChartLoadingView()
                } else {
                    noDataWithPlans
                }
            } else if chartMode == .intraday {
                IntradayChartView(
                    candles: sourceCandles,
                    previousClose: quote?.previousClose ?? 0,
                    market: symbol.market,
                    palette: appState.palette,
                    showsExtendedHours: appState.showsExtendedHours(for: symbol),
                    showsPercentageAxis: true,
                    annotations: chartAnnotations
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
                    viewport: candleViewport,
                    annotations: chartAnnotations,
                    indicators: indicatorConfiguration
                )
            }
        }
    }

    @ViewBuilder
    private var noDataWithPlans: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContentUnavailableView {
                Label(
                    PulseLocalization.localizedString("chart.noData"),
                    systemImage: "chart.xyaxis.line"
                )
            } description: {
                Text(PulseLocalization.localizedString("chart.noPeriodData", chartMode.period.displayName))
            }
            let plans = noDataPlans
            if plans.isEmpty {
                Text(PulseLocalization.localizedString("main.chart.noDataPlans"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(plans) { plan in
                            Button {
                                route = .plan(symbol, plan.id, .detail(symbol))
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(PlanSideStyle.color(for: plan.kind))
                                        .frame(width: 6, height: 6)
                                    Text(PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"))
                                        .foregroundStyle(PlanSideStyle.color(for: plan.kind))
                                    Text("\(currencyCode ?? symbol.currencyCode) \(PriceFormatter.price(plan.price, market: symbol.market))")
                                        .foregroundStyle(.primary)
                                    Text("× \(PriceFormatter.quantity(plan.quantity))")
                                        .foregroundStyle(.secondary)
                                    if let note = plan.note, !note.isEmpty {
                                        Text(note).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 10).monospacedDigit())
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxHeight: 105)
                .scrollIndicators(.visible)
            }
        }
    }

    private var noDataPlans: [TradePlan] {
        (item?.plans ?? []).filter { $0.status == .active || annotationController.showsHistoricalPlans }
    }

    private var chartAnnotations: ChartAnnotationConfiguration {
        ChartAnnotationConfiguration(
            controller: annotationController,
            drawings: (item?.drawings ?? []).filter { !$0.isDeleted },
            plans: item?.plans ?? [],
            currentPrice: annotationReferencePrice,
            scope: chartDrawingScope,
            currencyCode: currencyCode,
            quantityUnit: symbol.cryptoPair?.baseAsset ?? PulseLocalization.localizedString("trade.unit.shares"),
            onUpsert: { drawing in _ = commitDrawing(drawing, for: symbol) },
            onDelete: { id in deleteDrawing(id, for: symbol) },
            onEditDrawing: { id in editDrawing(id, for: symbol) },
            onEditPlan: { id in route = .plan(symbol, id, .detail(symbol)) }
        )
    }

    private var annotationReferencePrice: Double? {
        if let price = quote?.price, price.isFinite, price > 0 { return price }
        return nil
    }

    private var chartDrawingScope: ChartDrawingScope {
        if chartMode == .intraday {
            return .intraday(day: activeIntradaySessionDay ?? .distantPast)
        }
        return .candles(period: chartMode.period)
    }

    /// Intraday annotations are keyed to the loaded chart session, normalized
    /// in the exchange timezone. This also keeps fixture history dates intact.
    private var activeIntradaySessionDay: Date? {
        guard chartMode == .intraday,
              let timestamp = chartCandles.last?.time ?? sourceCandles.last?.time ?? quote?.timestamp else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        let session = IntradayTradingSession(
            market: symbol.market,
            referenceDate: timestamp,
            includesExtendedHours: appState.showsExtendedHours(for: symbol)
        )
        return calendar.startOfDay(for: session.open)
    }

    private func attachDrawingHistoryHandlers() {
        annotationController.setHistoryHandlers(
            undo: {
                drawingSession.undo(
                    for: symbol,
                    upsert: { drawing, target in persistDrawing(drawing, for: target) },
                    delete: { id, target in persistDrawingDeletion(id, for: target) }
                )
            },
            redo: {
                drawingSession.redo(
                    for: symbol,
                    upsert: { drawing, target in persistDrawing(drawing, for: target) },
                    delete: { id, target in persistDrawingDeletion(id, for: target) }
                )
            }
        )
    }

    @discardableResult
    private func commitDrawing(_ drawing: ChartDrawing, for target: SymbolID) -> Bool {
        let previous = savedItem(for: target)?.drawings.first { $0.id == drawing.id && !$0.isDeleted }
        guard persistDrawing(drawing, for: target) else { return false }
        drawingSession.record(symbol: target, before: previous, after: drawing)
        return true
    }

    private func deleteDrawing(_ id: UUID, for target: SymbolID) {
        guard let previous = savedItem(for: target)?.drawings.first(where: { $0.id == id && !$0.isDeleted }),
              persistDrawingDeletion(id, for: target) else { return }
        drawingSession.recordDelete(symbol: target, drawing: previous)
    }

    @discardableResult
    private func persistDrawing(_ drawing: ChartDrawing, for target: SymbolID) -> Bool {
        guard accountMatchesDraft else { return false }
        ensureDrawingItem(for: target)
        let saved = appState.watchlist.setChartDrawing(drawing, for: target)
        if saved, target == symbol {
            annotationController.selectDrawing(drawing.id)
        }
        return saved
    }

    @discardableResult
    private func persistDrawingDeletion(_ id: UUID, for target: SymbolID) -> Bool {
        guard accountMatchesDraft else { return false }
        let deleted = appState.watchlist.deleteChartDrawing(id, for: target)
        if deleted, target == symbol, annotationController.selectedDrawingID == id {
            annotationController.selectDrawing(nil)
        }
        return deleted
    }

    private func ensureDrawingItem(for target: SymbolID) {
        guard appState.watchlist.item(for: target) == nil,
              appState.watchlist.retainedHistoryItem(for: target) == nil else { return }
        let name = target == symbol ? (quote?.name ?? appState.displayName(for: target)) : target.displayCode
        _ = appState.watchlist.materializeItem(SymbolInfo(symbol: target, name: name))
    }

    private func savedItem(for target: SymbolID) -> WatchItem? {
        appState.watchlist.item(for: target) ?? appState.watchlist.retainedHistoryItem(for: target)
    }

    private func editDrawing(_ id: UUID, for target: SymbolID) {
        guard target == symbol,
              let drawing = savedItem(for: target)?.drawings.first(where: { $0.id == id && !$0.isDeleted }) else { return }
        annotationController.selectDrawing(id)
        annotationController.tool = .browse
        editingDrawing = drawing
    }

    private func handleChartEscape() -> Bool {
        if editingDrawing != nil {
            editingDrawing = nil
            return true
        }
        guard annotationController.tool != .browse
                || annotationController.isInteracting
                || annotationController.selectedDrawingID != nil
                || annotationController.hasMeasurement
                || annotationController.isMeasurementSelected else { return false }
        annotationController.cancelInteraction()
        return true
    }

    private func handleChartDelete() -> Bool {
        guard annotationController.canDeleteSelected else { return false }
        return annotationController.deleteSelected()
    }

    private func handleChartUndo() -> Bool {
        guard drawingSession.canUndo else { return false }
        annotationController.undo()
        return true
    }

    private func handleChartRedo() -> Bool {
        guard drawingSession.canRedo else { return false }
        annotationController.redo()
        return true
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
            if appState.watchlist.brokerageAccountsEnabled, selectedTab != .thesis {
                Menu {
                    ForEach(BrokerageAccountID.allCases) { account in
                        Button {
                            _ = appState.selectBrokerageAccount(account)
                        } label: {
                            if account == appState.watchlist.activeBrokerageAccountID {
                                Label(AccountIdentity.title(account), systemImage: "checkmark")
                            } else {
                                Text(AccountIdentity.title(account))
                            }
                        }
                    }
                } label: {
                    Text(AccountIdentity.title(appState.watchlist.activeBrokerageAccountID))
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("这部分持仓、成交和计划所属的账户")
                .accessibilityLabel("持仓与交易账户：\(AccountIdentity.title(appState.watchlist.activeBrokerageAccountID))")
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
                .fill(PlanSideStyle.color(for: plan.kind))
                .frame(width: 2, height: 26)
            Button {
                route = .plan(symbol, plan.id, .detail(symbol))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PlanSideStyle.color(for: plan.kind))
                        Text("\(PriceFormatter.price(plan.price, market: symbol.market)) × \(PriceFormatter.quantity(plan.quantity))")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary)
                        if let current = quote?.price, plan.isReached(at: current), plan.status == .active {
                            Text(PulseLocalization.localizedString("plan.reached"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(PlanSideStyle.color(for: plan.kind))
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
                        thesisAccount = appState.watchlist.activeBrokerageAccountID
                        isEditingThesis = true
                    } label: {
                        Label(PulseLocalization.localizedString("main.thesis.edit"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            if isEditingThesis {
                AccountDraftNotice(account: thesisAccount ?? appState.watchlist.activeBrokerageAccountID)
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
                        guard thesisMatchesAccount else { return }
                        preparePositionItem()
                        appState.watchlist.setThesis(thesisDraft, for: symbol)
                        isEditingThesis = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!thesisMatchesAccount)
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
                    thesisAccount = appState.watchlist.activeBrokerageAccountID
                    isEditingThesis = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var routeDraftItem: WatchItem? {
        appState.watchlist.draftItem(for: symbol,
            account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID)
    }

    // MARK: - In-pane navigation

    @ViewBuilder
    private var routedPage: some View {
        switch route {
        case .position(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            PositionHubView(symbol: symbol, returnRoute: returnRoute, route: $route)
                .padding(.top, 8)
        case .trade(let routedSymbol, let side, let returnRoute) where routedSymbol == symbol:
            TradeEntryView(symbol: symbol, side: side, returnRoute: returnRoute, route: $route,
                           account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID)
        case .editTrade(let routedSymbol, let transactionID, let returnRoute) where routedSymbol == symbol:
            if let transaction = routeDraftItem?.transactions.first(where: { $0.id == transactionID }) {
                TradeEntryView(
                    symbol: symbol,
                    editing: transaction,
                    returnRoute: returnRoute,
                    route: $route,
                    account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID
                )
            } else {
                dashboard
                    .onAppear { route = .detail(symbol) }
            }
        case .transactions(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            TransactionListView(symbol: symbol, returnRoute: returnRoute, route: $route)
        case .plan(let routedSymbol, let planID, let returnRoute) where routedSymbol == symbol:
            PlanEditorView(symbol: symbol, planID: planID, returnRoute: returnRoute, route: $route,
                           account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID)
        case .calibrate(let routedSymbol, let returnRoute) where routedSymbol == symbol:
            if let item = routeDraftItem {
                // The account is captured once, when this page is built, and
                // frozen into both callbacks. Reading it again inside the closure
                // would let a switch between the two clicks land the write in the
                // ledger the numbers were not read from.
                let draftAccount = draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID
                VStack(spacing: 0) {
                    PositionPageHeader(
                        symbol: symbol,
                        title: nil,
                        onBack: { route = returnRoute.popoverRoute }
                    )
                    AccountDraftNotice(account: draftAccount).padding(.horizontal, 14)
                    ScrollView {
                        PositionEditorView(
                            item: item,
                            quote: quote,
                            palette: appState.palette,
                            onCancel: { route = returnRoute.popoverRoute },
                            onSave: { quantity, cost in
                                guard appState.watchlist.activeBrokerageAccountID == draftAccount else { return }
                                appState.watchlist.calibratePosition(symbol, quantity: quantity, averageCost: cost)
                                route = returnRoute.popoverRoute
                            },
                            onClear: {
                                guard appState.watchlist.activeBrokerageAccountID == draftAccount else { return }
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
