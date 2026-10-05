import SwiftUI
import PulseCore
import PulseUI

struct DetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pulseHost) private var host
    let symbol: SymbolID
    @Binding var route: PopoverRoute

    @State private var period: CandlePeriod = .minute1
    @State private var candles: [Candle] = []
    /// What `candles` hold, and by the same token which request they answer for.
    /// A switch leaves the previous period's bars in place for a moment; they
    /// must neither be drawn under the new period's axis nor counted as its
    /// answer. Only once this matches the request on screen does an empty
    /// `candles` mean the source had nothing.
    @State private var candlesKey: CandleCacheKey?
    @State private var isLoading = false
    @State private var isFirstLoad = true
    @State private var shareFeedback: ShareFeedback?
    /// Owned here (not in the chart) so sharing can read the zoomed candle window.
    @State private var candleViewport = CandleChartViewport()
    /// The thesis sheet. The draft lives here so abandoning an edit leaves the
    /// stored text exactly as it was.
    @State private var isEditingThesis = false
    @State private var thesisDraft = ""
    /// The account this page's thesis draft was composed against. The draft is
    /// page state, and an account switch can replace the store's ledger while it
    /// is open.
    @State private var frozenAccount: BrokerageAccountID?

    /// Non-nil only when the store still holds the ledger this draft came from.
    private var accountMatchesDraft: Bool {
        frozenAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    private static let minutePeriods: [CandlePeriod] = [
        .minute5, .minute15, .minute30, .hour1,
    ]

    // Page flow: price hero → trend chart → market stats → position →
    // trade plans → thesis. Reading top to bottom is "what it costs", "what I
    // hold", "what I mean to do", "why" — the thesis stays the closing block.
    // Source/time/delay metadata sits at the hero's top-right corner, annotating the price.
    var body: some View {
        VStack(spacing: 0) {
            heroSection
            sectionSeparator
            chartSection
            sectionSeparator
            statsSection
            positionArea
            planArea
            thesisArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .softScrollEdgeEffect(for: .all)
        // Navigation and instrument identity belong to the page, not the window.
        // Keeping this row inline also aligns it with the pinned watchlist's first
        // content row instead of squeezing a long name between the traffic lights
        // and the title-bar actions.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .toolbar {
            if host == .pinnedWindow {
                FlexibleToolbarSpacer()
                ToolbarItemGroup(placement: .primaryAction) {
                    toolbarActions
                }
            }
        }
        .onAppear {
            frozenAccount = appState.watchlist.activeBrokerageAccountID
            maybeOfferKlineTourStep()
        }
        // The thesis draft belongs to the ledger this page was opened against.
        // Abandoning it is honest: the text on screen describes an instrument
        // the newly selected account may not even hold.
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            frozenAccount = nil
            isEditingThesis = false
            thesisDraft = ""
        }
        .onDisappear {
            // Leaving with the candle bubble up counts as the step seen; the pin
            // stop then presents back on the list. An offer that never fired
            // stays pending for the next detail visit.
            if appState.onboarding.activeTourStep == .kline {
                appState.onboarding.completeStep(.kline)
            }
        }
        // Any period switch is the lesson learned, daily or not.
        .onChange(of: period) { _, _ in
            appState.onboarding.completeStep(.kline)
        }
        // Real-time push is shared across detail pages for the same symbol.
        .task(id: symbol) {
            await appState.detailMarketData.run(symbol: symbol)
        }
        .task(id: chartRequest) {
            let request = chartRequest
            let taskStart = ContinuousClock.now
            // Switching periods repaints from whatever is already cached for the
            // new one, however old, and the refresh replaces it in place — the
            // chart never has to blank out to change resolution. The first load
            // skips this: its render would land mid-push (see the clearance below).
            if !isFirstLoad,
               let cached = appState.market.cachedCandles(for: request, maxAge: .infinity),
               !cached.isEmpty {
                candles = cached
                candlesKey = request
            }
            // Show the spinner only when loading is actually slow: a sub-150ms load
            // (cache hit) swaps silently instead of flashing a progress indicator.
            let spinnerDelay = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                isLoading = true
            }
            defer {
                spinnerDelay.cancel()
                isLoading = false
            }
            let loaded = await appState.detailMarketData.loadCandles(
                symbol: request.symbol, period: request.period,
                count: candleCount(for: request.period)
            )
            if isFirstLoad {
                // The first load starts while the push transition is still running,
                // and Swift Charts' first render is expensive (up to 1440 intraday
                // points) — hold a fast (cached) result until the slide has settled.
                let clearance: Duration = .milliseconds(350)
                let elapsed = taskStart.duration(to: .now)
                if elapsed < clearance {
                    try? await Task.sleep(for: clearance - elapsed)
                }
                isFirstLoad = false
            }
            guard !Task.isCancelled, chartRequest == request else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                candles = loaded
                candlesKey = request
            }
        }
    }

    /// Symbol + period identify a chart load: the page is reused across symbols,
    /// so a reload owes itself to either changing.
    private var chartRequest: CandleCacheKey {
        CandleCacheKey(symbol: symbol, period: period)
    }

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var item: WatchItem? { appState.watchlist.item(for: symbol) }

    private var currencyCode: String? {
        quote?.currencyCode ?? symbol.currencyCode
    }

    /// K-line periods load history behind the zoomable window (the chart shows the latest
    /// ~60 bars by default). Intraday resolutions retain enough bars to pan backward while
    /// staying inside Longbridge/Binance's 1,000-candle request ceiling.
    private func candleCount(for period: CandlePeriod) -> Int {
        switch period {
        case .minute5, .minute15, .minute30, .hour1:
            guard let minutes = period.intradayMinutes else { return 240 }
            let sessionMinutes = switch symbol.market {
            case .sh, .sz: 240
            case .hk: 330
            // Providers fetch all sessions; the presentation setting filters to
            // regular hours or 04:00–20:00 ET without a second request.
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
        case .minute1:
            return IntradayTrendSnapshot.recommendedCandleCount(for: symbol.market)
        }
    }

    /// Only bars that belong to what is on screen now. Everything the chart
    /// draws goes through here, so a pending switch shows its own loading state
    /// rather than the outgoing period's data.
    private var sourceCandles: [Candle] {
        if candlesKey == chartRequest { return candles }
        // The reload task lands a frame later than the switch itself. Painting
        // the cache here rather than waiting for it closes that frame, so going
        // back to a period already loaded once never blanks at all.
        guard !isFirstLoad else { return [] }
        return appState.market.cachedCandles(for: chartRequest, maxAge: .infinity) ?? []
    }

    /// Minute K data is fetched with all US sessions so the setting can switch instantly.
    /// This also removes overnight bars: Pulse's setting promises pre/post, not 24-hour US trading.
    private var chartCandles: [Candle] {
        guard period.isMinuteK else { return sourceCandles }
        return IntradayTradingSession.filterCandles(
            sourceCandles,
            market: symbol.market,
            includesExtendedHours: appState.showsExtendedHours(for: symbol)
        )
    }

    // MARK: - Chrome

    private var backButton: some View {
        IconButton(systemName: "chevron.left", help: PulseLocalization.localizedString("action.backHelp")) {
            route = .list
        }
    }

    private var titleCluster: some View {
        HStack(spacing: 6) {
            Text(appState.displayName(for: symbol))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            MarketBadge(market: symbol.market)
                .fixedSize()
            Text(symbol.displayCode)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            backButton
            titleCluster
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if host == .menuBar {
                headerActions
            }
        }
        .overlay(alignment: .trailing) {
            if let shareFeedback {
                ShareFeedbackHUD(feedback: shareFeedback)
                    .padding(.trailing, host == .pinnedWindow ? 10 : (item?.supportsPosition == true ? 58 : 30))
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        // A standalone page header needs the panel's full inset, while the
        // pinned window already has a title bar immediately above it.
        .padding(.top, host == .pinnedWindow ? 2 : 7)
        .padding(.bottom, 7)
    }

    private var shareMenu: some View {
        ClusterMenu(
            systemName: "square.and.arrow.up",
            help: PulseLocalization.localizedString("action.share")
        ) {
            Button {
                copyShareImage()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsImage"),
                    systemImage: "photo"
                )
            }
            .disabled(quote == nil || chartCandles.isEmpty)
            Button {
                copyShareText()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsText"),
                    systemImage: "doc.text"
                )
            }
            .disabled(quote == nil)
        }
        .disabled(quote == nil)
        .opacity(quote == nil ? 0.45 : 1)
    }

    // MARK: - Onboarding tour

    /// Next on this stop performs the switch itself. The bubble goes first and
    /// the chart swaps a beat later, so the popover's dismissal never overlaps
    /// the content change — same sequencing as the list page's action steps.
    private var klineTourBubble: OnboardingTourBubble {
        OnboardingTourBubble(
            step: .kline,
            text: PulseLocalization.localizedString("onboarding.tour.kline")
        ) {
            appState.onboarding.completeStep(.kline)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                period = .day
            }
        }
    }

    /// Same election as the list page: the pinned window carries the tour while
    /// it is up, else the panel does.
    private var isTourHost: Bool {
        host == .pinnedWindow || !appState.settings.pinnedWindowVisible
    }

    private var klineTourBinding: Binding<Bool> {
        Binding(
            get: { isTourHost && appState.onboarding.activeTourStep == .kline },
            set: { presented in
                if !presented, appState.onboarding.activeTourStep == .kline {
                    appState.onboarding.pauseTour()
                }
            }
        )
    }

    /// Offers the candle stop once this page settles; the stop was queued by the
    /// detail step completing on the way in.
    private func maybeOfferKlineTourStep() {
        guard isTourHost,
              appState.onboarding.tourAvailable,
              appState.onboarding.activeTourStep == nil,
              appState.onboarding.tourResumeStep == .kline else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            guard isTourHost,
                  appState.onboarding.tourAvailable,
                  appState.onboarding.activeTourStep == nil,
                  appState.onboarding.tourResumeStep == .kline else { return }
            appState.onboarding.beginTourIfNeeded()
        }
    }

    /// Opened from search without being watched: offer the add here so a lookup can
    /// graduate into the list without going back.
    private var addButton: some View {
        ClusterIcon(
            systemName: "star",
            help: PulseLocalization.localizedString(
                "search.addToGroup",
                appState.sharedWatchlist.selectedGroup?.name ?? ""
            )
        ) {
            addToWatchlist()
        }
    }

    /// Stable membership entry: the star mirrors the iOS detail page — outline
    /// adds to the selected group, filled removes from it.
    @ViewBuilder private var watchToggleButton: some View {
        if appState.sharedWatchlist.contains(symbol) {
            ClusterIcon(
                systemName: "star.fill",
                help: PulseLocalization.localizedString(
                    "watchlist.group.removeCurrent",
                    appState.sharedWatchlist.selectedGroup?.name ?? ""
                )
            ) {
                removeFromWatchlist()
            }
        } else {
            addButton
        }
    }

    /// Positions outlive watchlist membership, so the entry stays visible for
    /// every position-eligible instrument; tapping one that has no item yet
    /// materializes it (restoring dormant history) without list membership.
    private var symbolSupportsPosition: Bool {
        switch sharedInstrumentType {
        case .index, .commodity: false
        default: true
        }
    }

    @ViewBuilder private var positionButton: some View {
        let hasPosition = item?.hasPosition == true
        ClusterIcon(
            systemName: hasPosition ? "briefcase.fill" : "briefcase",
            help: PulseLocalization.localizedString(
                hasPosition ? "action.editPosition" : "action.addPosition"
            )
        ) {
            openPositions()
        }
    }

    @ViewBuilder private var headerActions: some View {
        shareMenu
        watchToggleButton
        if symbolSupportsPosition {
            positionButton
        }
    }

    /// The pinned window's title bar carries only page-level actions. Navigation and
    /// instrument identity stay in the page header below, where long names have room.
    @ViewBuilder private var toolbarActions: some View {
        Menu {
            Button {
                copyShareImage()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsImage"),
                    systemImage: "photo"
                )
            }
            .disabled(quote == nil || chartCandles.isEmpty)
            Button {
                copyShareText()
            } label: {
                Label(
                    PulseLocalization.localizedString("action.copyAsText"),
                    systemImage: "doc.text"
                )
            }
            .disabled(quote == nil)
        } label: {
            Label(
                PulseLocalization.localizedString("action.share"),
                systemImage: "square.and.arrow.up"
            )
        }
        .menuIndicator(.hidden)
        .help(PulseLocalization.localizedString("action.share"))
        .disabled(quote == nil)

        if appState.sharedWatchlist.contains(symbol) {
            Button {
                removeFromWatchlist()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        "watchlist.group.removeCurrent",
                        appState.sharedWatchlist.selectedGroup?.name ?? ""
                    ),
                    systemImage: "star.fill"
                )
            }
            .help(PulseLocalization.localizedString(
                "watchlist.group.removeCurrent",
                appState.sharedWatchlist.selectedGroup?.name ?? ""
            ))
        } else {
            Button {
                addToWatchlist()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        "search.addToGroup",
                        appState.sharedWatchlist.selectedGroup?.name ?? ""
                    ),
                    systemImage: "star"
                )
            }
            .help(PulseLocalization.localizedString(
                "search.addToGroup",
                appState.sharedWatchlist.selectedGroup?.name ?? ""
            ))
        }

        if symbolSupportsPosition {
            Button {
                openPositions()
            } label: {
                Label(
                    PulseLocalization.localizedString(
                        (item?.hasPosition == true) ? "action.editPosition" : "action.addPosition"
                    ),
                    systemImage: (item?.hasPosition == true) ? "briefcase.fill" : "briefcase"
                )
            }
            .help(PulseLocalization.localizedString(
                (item?.hasPosition == true) ? "action.editPosition" : "action.addPosition"
            ))
        }
    }

    @MainActor
    private func addToWatchlist() {
        let info = SymbolInfo(
            symbol: symbol,
            name: appState.market.quote(for: symbol)?.name ?? appState.displayName(for: symbol)
        )
        appState.sharedWatchlist.add(info)
        appState.engine.poke()
    }

    @MainActor
    private func removeFromWatchlist() {
        appState.sharedWatchlist.remove(symbol)
    }

    /// Materializes a missing item (restoring dormant trade history) before the
    /// position hub opens: the hub and the ledger both require an item, but the
    /// instrument stays out of every list.
    @MainActor
    private func openPositions() {
        if appState.watchlist.item(for: symbol) == nil {
            appState.watchlist.materializeItem(SymbolInfo(
                symbol: symbol,
                name: appState.market.quote(for: symbol)?.name ?? appState.displayName(for: symbol)
            ))
            appState.engine.poke()
        }
        route = .position(symbol, .detail(symbol))
    }

    @MainActor
    private var sharedCandles: [Candle] {
        // K-line exports use exactly the zoomed window on screen; the intraday
        // chart keeps the full session, whose frame is its own context.
        let allCandles = chartCandles
        if period == .minute1 {
            return IntradayTrendSnapshot(
                candles: allCandles,
                market: symbol.market,
                includesExtendedHours: appState.showsExtendedHours(for: symbol)
            ).candles
        }
        return Array(allCandles[candleViewport.visibleRange(dataCount: allCandles.count)])
    }

    private var sharedInstrumentType: InstrumentType? {
        if let type = item?.resolvedInstrumentType { return type }
        if symbol.indexID != nil { return .index }
        if symbol.metalID != nil { return .commodity }
        if symbol.cryptoPair != nil { return .crypto }
        return nil
    }

    @MainActor
    private func copyShareImage() {
        do {
            let snapshot = DetailShareSnapshot(
                appState: appState,
                symbol: symbol,
                period: period,
                candles: sharedCandles
            )
            let palette = ChangePalette(redUp: snapshot.redUp)
            let card = PulseShareCard(
                ambientColor: snapshot.changeValue.map(palette.color(for:))
            ) {
                DetailShareContent(snapshot: snapshot)
            }
            let artifact = try ShareImageRenderer.render(
                card,
                configuration: .detailLandscape(
                    colorScheme: colorScheme,
                    locale: appState.settings.locale
                )
            )
            try ClipboardImageExporter.write(artifact)
            showShareFeedback(content: .image, isSuccess: true)
        } catch {
            showShareFeedback(content: .image, isSuccess: false)
        }
    }

    @MainActor
    private func copyShareText() {
        guard let quote else {
            showShareFeedback(content: .text, isSuccess: false)
            return
        }
        do {
            let snapshot = DetailTextSnapshot(
                symbol: symbol,
                name: appState.displayName(for: symbol),
                instrumentType: sharedInstrumentType,
                quote: quote,
                period: period,
                candles: sharedCandles,
                includesExtendedHours: appState.showsExtendedHours(for: symbol)
            )
            try ClipboardTextExporter.write(snapshot.renderedText())
            showShareFeedback(content: .text, isSuccess: true)
        } catch {
            showShareFeedback(content: .text, isSuccess: false)
        }
    }

    @MainActor
    private func showShareFeedback(content: ShareFeedback.Content, isSuccess: Bool) {
        let feedback = ShareFeedback(content: content, isSuccess: isSuccess)
        withAnimation(.snappy(duration: 0.2)) {
            shareFeedback = feedback
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(isSuccess ? 1.5 : 3))
            guard shareFeedback?.id == feedback.id else { return }
            withAnimation(.snappy(duration: 0.2)) {
                shareFeedback = nil
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if let quote {
                    let color = appState.palette.color(for: quote.change)
                    Text(quotePriceLabel(for: quote))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(PriceFormatter.price(quote.price, market: symbol.market))
                            .font(.system(size: 28, weight: .semibold).monospacedDigit())
                            .foregroundStyle(color)
                            // Animate the same magnitude the string prints so a third
                            // decimal the market allows stays in sync with the transition.
                            .contentTransition(
                                reduceMotion
                                    ? .opacity
                                    : .numericText(value: PriceFormatter.animatablePrice(
                                        quote.price,
                                        market: symbol.market
                                    ))
                            )
                            .animation(
                                .snappy(duration: 0.25),
                                value: PriceFormatter.animatablePrice(quote.price, market: symbol.market)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        if let currency = quote.currencyCode {
                            Text(currency)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(PriceFormatter.change(quote.change, market: symbol.market))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text(PriceFormatter.percent(quote.changePercent))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(color)
                    if let regularClose = regularCloseDisplay(for: quote) {
                        regularCloseRow(regularClose)
                            .padding(.top, 3)
                    }
                } else {
                    Text(PulseLocalization.localizedString("quote.price.current"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("—")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // The column is bottom-aligned to the price, so it grows upward:
            // the summary link goes on top, where arriving late pushes nothing
            // that was already there.
            VStack(alignment: .trailing, spacing: 6) {
                if symbol.isDescribable {
                    aboutLink
                }
                if let quote {
                    quoteMeta(for: quote)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// The way into the business summary. It lives in the hero's annotation
    /// corner rather than as a block of text on the page: the summary is long,
    /// and a page whose quote already moves under the reader can't afford a
    /// late arrival reflowing it. Nothing is fetched to show this — the link is
    /// there for anything that could have a summary, and the page it opens does
    /// the asking.
    private var aboutLink: some View {
        Button {
            route = .profile(symbol)
        } label: {
            HStack(spacing: 2) {
                Text(PulseLocalization.localizedString("detail.section.about"))
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    /// Quote provenance at the hero's top-right: freshness, source, then market-time basis.
    /// Bottom-aligns with the price block so the metadata reads as an annotation to the quote.
    private func quoteMeta(for quote: Quote) -> some View {
        let delayText = appState.quoteDelayText(for: quote)
        // A polled source is current but steps; saying so next to "realtime"
        // keeps the word honest without spending another line.
        let freshness = [delayText ?? PulseLocalization.localizedString("quote.realtime"),
                         appState.quoteCadenceText(for: quote)]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(delayText == nil ? Color.green.opacity(0.8) : .orange)
                    .frame(width: 5, height: 5)
                Text(freshness)
                    .foregroundStyle(delayText == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange.opacity(0.85)))
            }
            if let sourceName = quote.sourceName {
                Text(sourceName)
                    .foregroundStyle(.tertiary)
            }
            Text(appState.quoteMarketTimeText(for: quote))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                // Market time ticks with real-time pushes; roll the digits like the price does.
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(.snappy(duration: 0.25), value: quote.timestamp)
        }
        .font(.system(size: 9, weight: .medium))
        .multilineTextAlignment(.trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
        .frame(maxWidth: 132, alignment: .trailing)
    }

    /// The last regular session's result, shown under the live extended-session
    /// price. Pre-market labels it "昨收" (that close was yesterday's); post and
    /// overnight label it "收盘" (today's just-finished session). During regular
    /// hours there is no "yesterday" to show and the row disappears.
    private func regularCloseDisplay(for quote: Quote) -> (label: String, close: Quote.RegularSessionClose)? {
        guard let regularSession = quote.regularSession else { return nil }
        switch quote.marketState {
        case .preMarket:
            return (PulseLocalization.localizedString("quote.regularClose.previous"), regularSession)
        case .postMarket, .overnight:
            return (PulseLocalization.localizedString("quote.regularClose.today"), regularSession)
        case .regular, .closed, .none:
            return nil
        }
    }

    private func regularCloseRow(_ display: (label: String, close: Quote.RegularSessionClose)) -> some View {
        let close = display.close
        let color = close.change.map { appState.palette.color(for: $0) }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(display.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(PriceFormatter.price(close.price, market: symbol.market))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color ?? .secondary)
            if let change = close.change, let percent = close.changePercent {
                Text(PriceFormatter.change(change, market: symbol.market))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(color ?? .secondary)
                Text(PriceFormatter.percent(percent))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color ?? .secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .allowsTightening(true)
    }

    private func quotePriceLabel(for quote: Quote) -> String {
        switch quote.marketState {
        case .preMarket:
            PulseLocalization.localizedString("quote.price.preMarket")
        case .postMarket:
            PulseLocalization.localizedString("quote.price.postMarket")
        case .overnight:
            PulseLocalization.localizedString("quote.price.overnight")
        case .closed:
            PulseLocalization.localizedString("quote.price.close")
        case .regular, .none:
            PulseLocalization.localizedString("quote.price.current")
        }
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(spacing: 7) {
            chartHeader
            .padding(.horizontal, 12)
            // Leading 10 + the intraday plot's own 2pt inset lands the plot edge on the 12pt text grid;
            // trailing 12 aligns the y-axis labels with it directly.
            chart
                .padding(.leading, 10)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keeps the period control compact when its labels fit, then gives it a full row for
    /// longer localizations instead of clipping or shrinking the text beyond readability.
    private var chartHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sectionHeaderText(PulseLocalization.localizedString("detail.section.trend"))
                Spacer(minLength: 0)
                picker
                    .frame(width: 260)
            }

            VStack(alignment: .leading, spacing: 6) {
                sectionHeaderText(PulseLocalization.localizedString("detail.section.trend"))
                picker
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            periodButton(.minute1)
            minutePeriodMenu
            periodButton(.day)
                .popover(isPresented: klineTourBinding, arrowEdge: .bottom) {
                    klineTourBubble
                }
            periodButton(.week)
            periodButton(.month)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PulseLocalization.localizedString("detail.period"))
    }

    private func periodButton(_ value: CandlePeriod) -> some View {
        Button {
            period = value
        } label: {
            periodControlLabel(value.displayName, isSelected: period == value)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(value.displayName)
        .accessibilityAddTraits(period == value ? .isSelected : [])
    }

    private var minutePeriodMenu: some View {
        let selected = appState.settings.minuteCandlePeriod.isMinuteK
            ? appState.settings.minuteCandlePeriod
            : CandlePeriod.minute5
        return HStack(spacing: 0) {
            // Main segment action: return to the last chosen minute resolution.
            Button {
                period = selected
            } label: {
                Text(selected.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(selected.displayName)
            .accessibilityAddTraits(period.isMinuteK ? .isSelected : [])

            // Secondary action: only the small trailing chevron opens the resolution menu.
            Menu {
                ForEach(Self.minutePeriods, id: \.self) { value in
                    Button {
                        appState.settings.minuteCandlePeriod = value
                        period = value
                    } label: {
                        if value == selected {
                            Label(value.displayName, systemImage: "checkmark")
                        } else {
                            Text(value.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 5.5, weight: .semibold))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(selected.displayName)
        }
        .font(.system(size: 9, weight: period.isMinuteK ? .semibold : .medium))
        .foregroundStyle(period.isMinuteK ? .primary : .secondary)
        .frame(maxWidth: .infinity)
        .background {
            periodSelectionBackground(isSelected: period.isMinuteK)
        }
    }

    private func periodControlLabel(
        _ title: String,
        isSelected: Bool
    ) -> some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: true, vertical: false)
            .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .background {
                periodSelectionBackground(isSelected: isSelected)
            }
    }

    @ViewBuilder
    private func periodSelectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(.separator.opacity(0.6), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    private var chart: some View {
        ZStack {
            if chartCandles.isEmpty {
                if candlesKey == chartRequest {
                    // The load for what is on screen came back with nothing.
                    // Anything else — a switch still settling, a request in
                    // flight — is not yet an answer and must not claim to be one.
                    ContentUnavailableView {
                        Label(PulseLocalization.localizedString("chart.noData"), systemImage: "chart.xyaxis.line")
                    } description: {
                        Text(PulseLocalization.localizedString("chart.noPeriodData", period.displayName))
                    }
                    .transition(.opacity)
                } else if isLoading {
                    ChartLoadingView()
                        .transition(.opacity)
                }
                // Otherwise nothing yet: a load that answers inside the spinner's
                // 150ms grace period goes straight to the chart.
            } else if period == .minute1 {
                IntradayChartView(
                    candles: sourceCandles,
                    // Same convention as the main window: a missing previous close
                    // leaves the axis without a percentage scale instead of
                    // passing the open off as yesterday's close.
                    previousClose: quote?.previousClose ?? 0,
                    market: symbol.market,
                    palette: appState.palette,
                    showsExtendedHours: appState.showsExtendedHours(for: symbol),
                    showsPercentageAxis: true
                )
                .transition(.opacity)
            } else {
                CandlestickChartView(
                    candles: chartCandles,
                    palette: appState.palette,
                    period: period,
                    market: symbol.market,
                    highlightsExtendedHours: period.isMinuteK
                        && appState.showsExtendedHours(for: symbol),
                    transactions: period == .day
                        ? item?.materializedTransactions() ?? []
                        : [],
                    currencyCode: currencyCode,
                    viewport: candleViewport
                )
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: chartCandles.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Market stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderText(PulseLocalization.localizedString("detail.section.market"))
            HStack(spacing: 8) {
                stat(PulseLocalization.localizedString("stat.open"), quote?.open.map { PriceFormatter.price($0, market: symbol.market) })
                stat(PulseLocalization.localizedString("stat.high"), quote?.high.map { PriceFormatter.price($0, market: symbol.market) })
                stat(PulseLocalization.localizedString("stat.low"), quote?.low.map { PriceFormatter.price($0, market: symbol.market) })
            }
            HStack(spacing: 8) {
                stat(PulseLocalization.localizedString("stat.previousClose"), quote.map { PriceFormatter.price($0.previousClose, market: symbol.market) })
                stat(PulseLocalization.localizedString("stat.volume"), quote?.volume.map(PriceFormatter.compact))
                stat(PulseLocalization.localizedString("stat.amplitude"), quote?.amplitudePercent.map(PriceFormatter.percentMagnitude))
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Trade plans

    /// The user's intentions: how much, at which price. Read-only here — the
    /// editor is a pushed page (`PlanEditorView`) because this page has no
    /// ScrollView and cannot grow to hold a form. The one live signal the block
    /// carries is derived, never stored: `isReached(at:)` against the quote.
    @ViewBuilder
    private var planArea: some View {
        if symbolSupportsPosition {
            sectionSeparator
            planSection
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: PlanSection.stackSpacing) {
            planHeaderRow
            if let item, !item.plans.isEmpty {
                planRows(item)
            } else {
                planEmptyRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, PlanSection.bottomPadding)
    }

    private var planHeaderRow: some View {
        HStack(spacing: 4) {
            sectionHeaderText(PulseLocalization.localizedString("detail.section.plan"))
            Spacer(minLength: 0)
            if let reached = reachedPlan {
                // The plan in range is the thing worth knowing from this page,
                // so the header says it before any row does.
                Text(PulseLocalization.localizedString("plan.reached"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PlanSideStyle.color(for: reached.kind))
            }
            Button {
                openPlanEditor(nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .help(PulseLocalization.localizedString("plan.add"))
        }
    }

    /// The active plan whose price condition holds right now, if any.
    private var reachedPlan: TradePlan? {
        guard let quote, let item else { return nil }
        return item.reachedPlan(at: quote.price)
    }

    /// Lists at most `PlanSection.visibleRowCount` plans. The page is a fixed
    /// height, so the rest are counted rather than drawn — the same trade the
    /// position hub makes with its six most recent transactions.
    @ViewBuilder
    private func planRows(_ item: WatchItem) -> some View {
        ForEach(item.plans.prefix(PlanSection.visibleRowCount)) { plan in
            planRow(plan)
        }
        if item.plans.count > PlanSection.visibleRowCount {
            Text(PulseLocalization.localizedString(
                "plan.more",
                item.plans.count - PlanSection.visibleRowCount
            ))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private func planRow(_ plan: TradePlan) -> some View {
        let reached = quote.map { plan.isReached(at: $0.price) } ?? false
        let isWaiting = plan.status == .active
        return Button {
            openPlanEditor(plan.id)
        } label: {
            HStack(spacing: 6) {
                // A bar rather than a tinted row: a buy plan coming into range
                // means the price *fell*, and painting that in the up colour
                // reads as a gain. The bar borrows the direction the plan
                // trades in without turning the line red or green.
                Capsule()
                    .fill(reached && isWaiting ? PlanSideStyle.color(for: plan.kind) : Color.clear)
                    .frame(width: 2, height: 12)
                TradeKindBadge(
                    kind: plan.kind == .buy ? .buy : .sell,
                    palette: appState.palette
                )
                Text("\(PriceFormatter.price(plan.price, market: symbol.market)) × \(PriceFormatter.quantity(plan.quantity))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isWaiting ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .strikethrough(plan.status == .cancelled, color: .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .allowsTightening(true)
                Spacer(minLength: 4)
                planTrailingLabel(plan, reached: reached)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(plan.note ?? PulseLocalization.localizedString("plan.rowHelp"))
    }

    @ViewBuilder
    private func planTrailingLabel(_ plan: TradePlan, reached: Bool) -> some View {
        switch plan.status {
        case .done:
            planStatusLabel("plan.status.done")
        case .cancelled:
            planStatusLabel("plan.status.cancelled")
        case .active:
            HStack(spacing: 5) {
                if reached {
                    Text(PulseLocalization.localizedString("plan.reached"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(PlanSideStyle.color(for: plan.kind))
                } else if let quote {
                    Text(PulseLocalization.localizedString(
                        "plan.gap",
                        PriceFormatter.percentMagnitude(plan.gapPercent(from: quote.price))
                    ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
                // The percentage says how far the price still has to travel;
                // the money says what it is worth when it gets there. Both sit
                // on the same line because the row has no height to spare.
                if let cost = PlanCostText.string(for: plan, current: quote?.price, symbol: symbol) {
                    Text(cost)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func planStatusLabel(_ key: String) -> some View {
        Text(PulseLocalization.localizedString(key))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
    }

    private var planEmptyRow: some View {
        Text(PulseLocalization.localizedString("plan.empty"))
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { openPlanEditor(nil) }
    }

    /// Plans need a stored item, and a symbol opened from search has none.
    /// Materializing it here is the same move `openPositions()` makes, and it
    /// keeps the instrument out of every list.
    @MainActor
    private func openPlanEditor(_ id: UUID?) {
        if appState.watchlist.item(for: symbol) == nil {
            appState.watchlist.materializeItem(SymbolInfo(
                symbol: symbol,
                name: appState.market.quote(for: symbol)?.name ?? appState.displayName(for: symbol)
            ))
            appState.engine.poke()
        }
        route = .plan(symbol, id, .detail(symbol))
    }

    // MARK: - Thesis

    /// The user's own reason for holding this instrument, kept as free text.
    /// Shown last because it is the one block that exists only once someone has
    /// written it — and it is usually the thing they came back to read.
    @ViewBuilder
    private var thesisArea: some View {
        if let item {
            // The same hairline `sectionSeparator` draws, but tightened on both
            // sides. The position block above ends on a value row with no
            // bottom inset, so the stock 8pt above the divider read as a hole;
            // the 8pt below it read as a second one before the section title.
            Divider()
                .opacity(0.45)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    sectionHeaderText(PulseLocalization.localizedString("detail.section.thesis"))
                    Spacer(minLength: 0)
                    if !isEditingThesis {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                if isEditingThesis {
                    // Edited in place rather than in a sheet: this is an
                    // accessory (LSUIElement) app, and a sheet is its own
                    // window — typing into one takes key status the app cannot
                    // hold, which closes the whole thing.
                    TextEditor(text: $thesisDraft)
                        .font(.system(size: 10.5))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 96)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(PulseLocalization.localizedString("action.cancel")) {
                            isEditingThesis = false
                        }
                        Button(PulseLocalization.localizedString("action.save")) {
                            // A thesis belongs to this account's instrument. The
                            // symbol is the same in the new ledger, so it cannot
                            // authorize the write on its own.
                            if accountMatchesDraft {
                                appState.watchlist.setThesis(thesisDraft, for: symbol)
                            } else {
                                thesisDraft = ""
                            }
                            isEditingThesis = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .controlSize(.small)
                } else {
                    Group {
                        if let thesis = item.thesis, !thesis.isEmpty {
                            Text(thesis)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(PulseLocalization.localizedString("detail.thesis.empty"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        thesisDraft = item.thesis ?? ""
                        // A fresh edit is composed against the ledger open now.
                        frozenAccount = appState.watchlist.activeBrokerageAccountID
                        isEditingThesis = true
                    }
                }
            }
            // No extra top padding here. `sectionSeparator` already carries 8pt
            // above and below itself, which is the same gap every other section
            // gets — adding more only pushed this block away from its own
            // divider and made the space above it read as a hole.
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    /// Display driver for the position area: the live item when present,
    /// otherwise dormant history — an instrument removed from every list keeps
    /// its records visible here. Mutating goes through `openPositions()`, which
    /// materializes first.
    private var positionDisplayItem: WatchItem? {
        item ?? appState.watchlist.retainedHistoryItem(for: symbol)
    }

    @ViewBuilder
    private var positionArea: some View {
        if symbolSupportsPosition {
            sectionSeparator
            positionSection
        } else if let item, item.hasPosition {
            sectionSeparator
            legacyIndexPositionSection
        } else {
            // Position sections supply this inset themselves. Keep the same
            // bottom breathing room when indices intentionally omit the section.
            Color.clear
                .frame(height: 12)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var positionSection: some View {
        Group {
            if let item = positionDisplayItem, item.hasPosition {
                // The whole summary is the way into the position hub — same
                // destination as the header briefcase, but where the eye
                // already is.
                Button {
                    openPositions()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            sectionHeaderText(PulseLocalization.localizedString("detail.section.position"))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        if let quote, let valuation = PositionValuation(
                            item: item,
                            quote: quote,
                            basis: appState.settings.positionCostBasis
                        ) {
                            // Read-only here: this whole block is one button that
                            // opens the position page, so the switch lives there.
                            // The numbers still follow whichever basis is set, and
                            // the label says which one is on screen.
                            let basis = appState.settings.positionCostBasis
                            HStack(spacing: 8) {
                                pnlCell(PulseLocalization.localizedString("metric.todayPnL"), amount: valuation.todayPnL, percent: valuation.todayReturnPercent)
                                pnlCell(PulseLocalization.localizedString("metric.totalPnL"), amount: valuation.holdingPnL, percent: valuation.holdingReturnPercent)
                            }
                            HStack(spacing: 8) {
                                stat(PulseLocalization.localizedString("position.quantity"), PriceFormatter.quantity(valuation.quantity))
                                stat(PulseLocalization.localizedString(basis.labelKey), PriceFormatter.price(valuation.costPrice))
                                stat(PulseLocalization.localizedString("position.marketValue"), PriceFormatter.money(valuation.marketValue, currencyCode: currencyCode))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(PulseLocalization.localizedString("position.waitingQuote"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                let basis = appState.settings.positionCostBasis
                                let averageCost = item.averageCost ?? 0
                                let costPrice = basis == .diluted
                                    ? item.ledger?.dilutedCost ?? averageCost
                                    : averageCost
                                HStack(spacing: 8) {
                                    stat(PulseLocalization.localizedString("position.quantity"), PriceFormatter.quantity(item.positionQuantity))
                                    stat(PulseLocalization.localizedString(basis.labelKey), PriceFormatter.price(costPrice))
                                    stat(PulseLocalization.localizedString("position.marketValue"), "—")
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            } else if let item = positionDisplayItem, item.hasPositionHistory {
                // Selling out is not the same as never having held: the trade
                // log and what it realized outlive the position, and dropping
                // straight back to "no position" reads as if the record was
                // lost. Same target and same whole-block tap as an open one.
                Button {
                    openPositions()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            sectionHeaderText(PulseLocalization.localizedString("detail.section.position"))
                            Text(PulseLocalization.localizedString("position.closed"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        HStack(spacing: 8) {
                            stat(
                                PulseLocalization.localizedString("position.realizedPnL"),
                                PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
                                color: item.realizedPnL
                            )
                            stat(
                                PulseLocalization.localizedString("position.historyTrades"),
                                PulseLocalization.localizedString("position.tradeCount", item.transactions.count)
                            )
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeaderText(PulseLocalization.localizedString("detail.section.position"))
                    HStack {
                        Text(PulseLocalization.localizedString("position.notSet"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(PulseLocalization.localizedString("action.addPosition")) {
                            openPositions()
                        }
                        .buttonStyle(.pressable)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tint)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var legacyIndexPositionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderText(PulseLocalization.localizedString("detail.section.position"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(PulseLocalization.localizedString("position.indexLegacyNotice"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(PulseLocalization.localizedString("action.clearPosition"), role: .destructive) {
                    appState.watchlist.clearPosition(symbol)
                }
                .buttonStyle(.pressable)
                .font(.system(size: 10.5, weight: .medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// P&L cell: signed amount with its percent on a shared baseline, tinted by direction.
    private func pnlCell(_ label: String, amount: Double, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(PriceFormatter.signedMoney(amount, currencyCode: currencyCode))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                Text(PriceFormatter.percent(percent))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .opacity(0.9)
            }
            .foregroundStyle(appState.palette.color(for: amount))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared pieces

    private var sectionSeparator: some View {
        Divider()
            .opacity(0.45)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func sectionHeaderText(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// `color` carries a signed amount when the value should read as a gain or
    /// a loss; without it the stat stays neutral, like quantity or cost.
    private func stat(_ label: String, _ value: String?, color: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
            Text(value ?? "—")
                .font(.system(size: 10.5, weight: color == nil ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(color.map { appState.palette.color(for: $0) } ?? .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Geometry of the detail page's trade-plan block.
///
/// The detail page has no ScrollView — its height is handed to it from
/// `PopoverRootView`, which also has to budget for this block. The two live
/// apart, so the numbers live here once and both read them rather than
/// drifting into a layout that clips the section it just added.
enum PlanSection {
    /// How many plans the block lists before the rest are counted instead.
    /// Same idea as `PositionHubView.visibleTransactionCount`.
    static let visibleRowCount = 2

    static let rowHeight: CGFloat = 22
    static let moreRowHeight: CGFloat = 16
    static let emptyTextHeight: CGFloat = 15
    /// `sectionSeparator`'s 8pt above and below plus its hairline.
    static let separatorHeight: CGFloat = 17
    static let headerHeight: CGFloat = 13
    static let stackSpacing: CGFloat = 6
    static let bottomPadding: CGFloat = 12

    /// What the block costs the page. The chart above it is the flexible
    /// block, so this is how much shorter the chart gets.
    static func sectionHeight(planCount: Int) -> CGFloat {
        let content: CGFloat
        if planCount == 0 {
            content = emptyTextHeight
        } else {
            content = CGFloat(min(planCount, visibleRowCount)) * rowHeight
                + (planCount > visibleRowCount ? moreRowHeight : 0)
        }
        return separatorHeight + headerHeight + stackSpacing + content + bottomPadding
    }
}
