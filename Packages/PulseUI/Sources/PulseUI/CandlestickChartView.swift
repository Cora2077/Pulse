import SwiftUI
import Charts
import PulseCore
#if canImport(AppKit)
import AppKit
#endif

/// Candlestick chart (intraday/daily/weekly/monthly) with a volume strip at the bottom.
/// The X axis uses indices rather than dates to avoid gaps from weekends/trading halts; axis labels map back to dates.
/// Mark building is extracted into @ChartContentBuilder functions: clearer structure, and it avoids type-check timeouts in deeply nested branches on SDK 27.
///
/// The chart shows a zoomable window into the loaded history (TradingView-style):
/// scroll wheel / trackpad vertical scroll zooms around the cursor, trackpad horizontal
/// scroll / shift+wheel / drag pans through history, double-click resets to the latest
/// `defaultVisibleCount` bars. Hover state lives in `CandleChartViewport` and is read only
/// by the crosshair overlays, so mouse movement never re-renders the candle marks.
public struct CandlestickChartView: View {
    let candles: [Candle]
    let palette: ChangePalette
    let period: CandlePeriod
    let market: Market?
    let highlightsExtendedHours: Bool
    let transactions: [PositionTransaction]
    let currencyCode: String?
    let annotations: ChartAnnotationConfiguration?
    let indicators: ChartIndicatorConfiguration

    @State private var viewport: CandleChartViewport

    /// Pass a `viewport` to observe the zoom/pan window from outside (the detail view
    /// reads it when sharing so the card shows exactly the visible candles). The instance
    /// from the first render wins; callers must hand in a stable object.
    public init(
        candles: [Candle],
        palette: ChangePalette,
        period: CandlePeriod = .day,
        market: Market? = nil,
        highlightsExtendedHours: Bool = false,
        transactions: [PositionTransaction] = [],
        currencyCode: String? = nil,
        viewport: CandleChartViewport? = nil,
        annotations: ChartAnnotationConfiguration? = nil,
        indicators: ChartIndicatorConfiguration = .hidden
    ) {
        self.candles = candles
        self.palette = palette
        self.period = period
        self.market = market
        self.highlightsExtendedHours = highlightsExtendedHours
        self.transactions = transactions
        self.currencyCode = currencyCode
        self.annotations = annotations
        self.indicators = indicators
        _viewport = State(initialValue: viewport ?? CandleChartViewport())
    }

    public var body: some View {
        GeometryReader { geo in
            content(containerWidth: geo.size.width)
        }
    }

    /// Band sizes live in `ChartBands`; the price pane keeps whatever is left over.

    @ViewBuilder
    private func content(containerWidth: CGFloat) -> some View {
        // Derive the window once per body evaluation from live data, not from the stored
        // dataCount (which onChange only syncs after the first render).
        let range = viewport.visibleRange(dataCount: candles.count)
        let xDomain = (range.lowerBound - 1)...max(range.upperBound, 1)
        let visible = candles[safeRange: range]
        let _ = (viewport.wheelZoomAllowed = annotations.map {
            $0.controller.tool == .browse && !$0.controller.isInteracting
        } ?? true)
        let tradeMarkers = period == .day
            ? CandleTradeMarker.dailyMarkers(
                candles: candles,
                transactions: transactions,
                market: market
            )
            : []
        let visibleTradeMarkers = tradeMarkers.filter { range.contains($0.candleIndex) }
        let showsDateOnIntradayAxis = visibleSpansMultipleDays(visible)
        // Volume and MACD share the coordinate system as bottom bands (TradingView-style
        // overlay): one x scale means bars, candles and indicators align exactly, and the
        // date axis sits at the true bottom of the chart. Symbols without volume data
        // reclaim that band.
        let maxVolume = visible.compactMap(\.volume).max() ?? 0
        let bands = ChartBands(hasVolume: maxVolume > 0, hasMACD: indicators.showsMACD)
        let naturalPriceRange = ChartPriceRangePolicy.range(
            of: visible.flatMap { [$0.low, $0.high] }
        )
        let yDomain = yDomain(
            for: visible,
            hasBuyMarkers: visibleTradeMarkers.contains { $0.side == .buy },
            hasSellMarkers: visibleTradeMarkers.contains { $0.side == .sell },
            reserveVolumeBand: maxVolume > 0,
            reserveMACDBand: indicators.showsMACD,
            additionalPrices: fittedPlanPrices(naturalRange: naturalPriceRange)
        )
        let tradeMarkerPlacements = tradeMarkerPlacements(
            for: visibleTradeMarkers,
            visibleRange: range,
            yDomain: yDomain
        )
        // Indicators run over every loaded bar, but only the visible window is drawn, so
        // zooming and panning never change the shape of a curve.
        let movingAverageSeries = indicators.movingAverages.map { period in
            MovingAverageSeries(
                period: period,
                values: ChartIndicatorMath.simpleMovingAverage(
                    ChartIndicatorMath.closes(of: candles),
                    period: period.period
                )
            )
        }
        let macdSeries = indicators.showsMACD ? ChartIndicatorMath.macd(ChartIndicatorMath.closes(of: candles)) : nil
        let macdScale = macdSeries.map {
            MACDValueScale(series: $0, range: range, band: bands.macdBand(in: yDomain))
        }
        // `.ratio` widths collapse to hairlines on a continuous Int scale, which turns the
        // candles into bare wicks — size the bodies explicitly from the visible density.
        let barWidth = Self.barWidth(forVisible: range.count, containerWidth: containerWidth)
        // The legend and the OHLC readout both want the plot's top-left corner. When the
        // legend is up the readout is nudged below it so the two never overlap.
        let showsIndicatorLegend = !movingAverageSeries.isEmpty || macdSeries != nil
        let readoutTopInset = showsIndicatorLegend ? CandleIndicatorLegend.height : 0

        Chart {
            if highlightsExtendedHours, market == .us {
                extendedSessionMarks(range: range, slotWidth: barWidth / 0.62, yDomain: yDomain)
            }
            if let macdSeries, let macdScale {
                macdMarks(range: range, barWidth: barWidth, series: macdSeries, scale: macdScale)
            }
            if maxVolume > 0 {
                volumeMarks(
                    range: range,
                    barWidth: barWidth,
                    band: bands.volumeBand(in: yDomain),
                    maxVolume: maxVolume
                )
            }
            candleMarks(range: range, priceDomain: yDomain, barWidth: barWidth)
            if !movingAverageSeries.isEmpty {
                movingAverageMarks(range: range, series: movingAverageSeries)
            }
            tradeMarks(tradeMarkerPlacements)
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartXAxis {
            AxisMarks(values: axisIndices(for: range)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                if let index = value.as(Int.self), let candle = candles[safe: index] {
                    AxisValueLabel(dateLabel(for: candle, showsDate: showsDateOnIntradayAxis))
                        .font(.caption2)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                if let v = value.as(Double.self) {
                    AxisValueLabel(PriceFormatter.price(v, market: market)).font(.caption2)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    CandlePriceOverlay(viewport: viewport, candles: candles, range: range,
                                       xDomain: xDomain, palette: palette, period: period,
                                       market: market, tradeMarkers: tradeMarkers,
                                       currencyCode: currencyCode,
                                       proxy: proxy, geo: geo,
                                       readoutTopInset: readoutTopInset)
                    if let annotations {
                        let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                        let pricePane = ChartAnnotationMath.pricePane(
                            plot: plot,
                            reservingBottomFraction: bands.bottomReserved
                        )
                        let scope = candleAnnotationScope(annotations.scope)
                        ChartAnnotationOverlay(
                            configuration: annotations,
                            coordinates: candleCoordinates(
                                proxy: proxy,
                                plot: plot,
                                pricePane: pricePane,
                                visibleRange: range,
                                xDomain: xDomain,
                                yDomain: yDomain,
                                latestRealClose: candles.last?.close,
                                scope: scope,
                                movingAverages: movingAverageSeries
                            )
                        )
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if showsIndicatorLegend {
                CandleIndicatorLegend(
                    viewport: viewport,
                    series: movingAverageSeries,
                    macd: macdSeries,
                    range: range,
                    market: market
                )
                .padding(.leading, 6)
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: viewport.cursorInside = true
            case .ended: viewport.cursorInside = false
            }
        }
        // With annotations, keep the chart's own pan recognizer out of the way while
        // allowing gestures on the chart overlay's child views to handle drawing tools.
        .gesture(dragPan, including: annotations == nil ? .all : .subviews)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { viewport.reset() },
            including: annotations == nil ? .all : .subviews
        )
        .onChange(of: candles.count, initial: true) { _, count in viewport.dataCount = count }
        .onChange(of: period) { _, _ in
            viewport.reset()
            viewport.cursorInside = false
            viewport.hoveredIndex = nil
            annotations?.controller.resetTransientState()
        }
        .onChange(of: annotations?.scope) { _, _ in annotations?.controller.resetTransientState() }
        .onChange(of: candles) { _, _ in viewport.hoveredIndex = nil }
        .onAppear { viewport.startMonitoring() }
        .onDisappear { viewport.stopMonitoring() }
    }

    /// Mouse drag pans like grabbing the chart: content follows the cursor.
    private var dragPan: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                viewport.pan(byPoints: value.translation.width - viewport.lastDragWidth)
                viewport.lastDragWidth = value.translation.width
            }
            .onEnded { _ in viewport.lastDragWidth = 0 }
    }

    /// Current annotation drawings are instrument scoped, while trend lines belong to
    /// this exact candle period. A stale host scope is normalized to the visible period.
    private func candleAnnotationScope(_ proposed: ChartDrawingScope) -> ChartDrawingScope {
        if case .candles(let proposedPeriod) = proposed, proposedPeriod == period {
            return proposed
        }
        return .candles(period: period)
    }

    private func fittedPlanPrices(naturalRange: ClosedRange<Double>?) -> [Double] {
        guard let annotations, annotations.controller.showsPlans, let naturalRange else { return [] }
        let visible = ChartPriceRangePolicy.visiblePlanPrices(
            annotations.plans,
            showsHistorical: annotations.controller.showsHistoricalPlans
        )
        return ChartPriceRangePolicy.pricesToFit(
            visible,
            naturalRange: naturalRange,
            focusedPrice: annotations.controller.focusedPlanPrice,
            fitsAll: annotations.controller.fitsPlans
        )
    }

    private func candleCoordinates(
        proxy: ChartProxy,
        plot: CGRect,
        pricePane: CGRect,
        visibleRange: Range<Int>,
        xDomain: ClosedRange<Int>,
        yDomain: ClosedRange<Double>,
        latestRealClose: Double?,
        scope: ChartDrawingScope,
        movingAverages: [MovingAverageSeries]
    ) -> ChartAnnotationCoordinates {
        let times = candles.map(\.time)
        func xForIndex(_ index: Int) -> CGFloat? {
            if let position = proxy.position(forX: index) { return plot.minX + position }
            // ChartProxy may not project a loaded point outside the visible index
            // window; the chart uses a linear index scale, so extrapolate only that
            // known sample index for clipping a partially visible trend.
            return ChartAnnotationMath.xCoordinate(index: index, domain: xDomain, plot: plot)
        }
        func indexForX(_ x: CGFloat) -> Int? {
            return ChartAnnotationMath.nearestIndex(atX: x, domain: xDomain, plot: plot, count: candles.count)
        }
        func priceForY(_ y: CGFloat) -> Double? {
            if let price: Double = proxy.value(atY: y - plot.minY), price.isFinite, price > 0 { return price }
            return ChartAnnotationMath.price(atY: y, domain: yDomain, plot: plot)
        }
        func yForPrice(_ price: Double) -> CGFloat? {
            if let position = proxy.position(forY: price) { return plot.minY + position }
            // Keep known out-of-domain prices available for the pane-edge prompt.
            return ChartAnnotationMath.yCoordinate(price: price, domain: yDomain, plot: plot)
        }
        func anchorAt(_ point: CGPoint) -> ChartAnchor? {
            guard pricePane.contains(point), let index = indexForX(point.x),
                  let price = priceForY(point.y) else { return nil }
            return ChartAnchor(time: candles[index].time, price: price)
        }
        func snappedAnchorAt(_ point: CGPoint) -> ChartAnchor? {
            guard pricePane.contains(point), let index = indexForX(point.x),
                  let freeAnchor = anchorAt(point) else { return nil }
            let candle = candles[index]
            let price = ChartAnchorSnapPolicy.nearestPrice(
                atY: point.y,
                candidates: [candle.open, candle.high, candle.low, candle.close],
                yForPrice: yForPrice
            ) ?? freeAnchor.price
            return ChartAnchor(time: candle.time, price: price)
        }
        func shift(_ anchor: ChartAnchor, _ dx: CGFloat, _ dy: CGFloat) -> ChartAnchor? {
            guard let index = ChartAnnotationMath.exactIndex(for: anchor.time, sampleTimes: times),
                  let x = xForIndex(index), let y = yForPrice(anchor.price),
                  let movedIndex = indexForX(x + dx), let price = priceForY(y + dy) else { return nil }
            return ChartAnchor(time: candles[movedIndex].time, price: price)
        }
        // The plan tag column sits over the newest bars, so a tag has to know their price
        // ranges to step clear of them. Each bar contributes its own span rather than one
        // merged envelope: on a daily chart the tag column covers ~30 bars, and their union is
        // most of the pane, which would leave a tag almost nowhere to stand. Keeping the spans
        // separate lets a tag settle between two candles, where there is nothing to cover.
        func obstacleSpans() -> [ClosedRange<CGFloat>] {
            let labelWidth = min(max(plot.width * 0.36, 74), 128)
            guard visibleRange.upperBound > visibleRange.lowerBound,
                  visibleRange.lowerBound >= 0,
                  let firstIndex = ChartAnnotationMath.nearestIndex(
                      atX: plot.maxX - labelWidth, domain: xDomain, plot: plot, count: candles.count
                  ) else { return [] }
            let start = min(max(firstIndex, visibleRange.lowerBound), visibleRange.upperBound - 1)
            let end = min(visibleRange.upperBound, candles.count)
            guard start < end else { return [] }

            var spans: [ClosedRange<CGFloat>] = []
            for index in start..<end {
                var low = candles[index].low
                var high = candles[index].high
                // Average lines are thin and cross the bars, so they belong to the bar they
                // pass through instead of forming an obstacle of their own.
                for series in movingAverages {
                    if let value = series.values[safe: index] ?? nil, value.isFinite {
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
                guard low.isFinite, high.isFinite, low <= high,
                      let top = yForPrice(high), let bottom = yForPrice(low) else { continue }
                spans.append(min(top, bottom)...max(top, bottom))
            }
            // Merge only spans that genuinely touch. Adjacent candles overlap constantly, so
            // this collapses a dense run into a few blocks while leaving the real gaps open.
            return ChartAnnotationMath.mergingOverlapping(spans)
        }

        return ChartAnnotationCoordinates(
            plot: plot,
            pricePane: pricePane,
            sampleTimes: times,
            market: market,
            palette: palette,
            scopeForNewTrend: scope,
            latestRealClose: latestRealClose,
            xForTime: { time in
                guard let index = ChartAnnotationMath.exactIndex(for: time, sampleTimes: times) else { return nil }
                return xForIndex(index)
            },
            anchorAt: anchorAt,
            snappedAnchorAt: snappedAnchorAt,
            onHover: { point in
                viewport.cursorInside = point != nil
                guard let point, !visibleRange.isEmpty, plot.width > 0,
                      plot.insetBy(dx: -2, dy: -4).contains(point) else {
                    viewport.hoveredIndex = nil
                    return
                }
                let rel = (point.x - plot.origin.x) / plot.width
                let raw = Double(xDomain.lowerBound)
                    + Double(rel) * Double(xDomain.upperBound - xDomain.lowerBound)
                viewport.hoveredIndex = min(max(Int(raw.rounded()), visibleRange.lowerBound), visibleRange.upperBound - 1)
            },
            yForPrice: yForPrice,
            shiftAnchor: shift,
            pan: { viewport.pan(byPoints: $0) },
            resetView: { viewport.reset() },
            planLabelObstacles: obstacleSpans()
        )
    }

    // MARK: - Marks

    /// Extended-session candles keep their normal gain/loss color. A restrained plot
    /// tint carries the session distinction without creating a third candle palette.
    @ChartContentBuilder
    private func extendedSessionMarks(
        range: Range<Int>,
        slotWidth: CGFloat,
        yDomain: ClosedRange<Double>
    ) -> some ChartContent {
        ForEach(range, id: \.self) { index in
            let kind = IntradayTradingSession.usSessionKind(for: candles[index].time)
            if kind != .regular {
                RectangleMark(
                    x: .value("Extended Session", index),
                    yStart: .value("Session Bottom", yDomain.lowerBound),
                    yEnd: .value("Session Top", yDomain.upperBound),
                    width: .fixed(max(slotWidth, 1))
                )
                .foregroundStyle(
                    kind == .pre
                        ? Color.blue.opacity(0.045)
                        : Color.purple.opacity(0.04)
                )
            }
        }
    }

    @ChartContentBuilder
    private func candleMarks(range: Range<Int>, priceDomain: ClosedRange<Double>,
                             barWidth: CGFloat) -> some ChartContent {
        ForEach(range, id: \.self) { index in
            let candle = candles[index]
            RuleMark(x: .value("i", index),
                     yStart: .value("Low", candle.low),
                     yEnd: .value("High", candle.high))
                .foregroundStyle(palette.color(isUp: candle.isUp))
                .lineStyle(StrokeStyle(lineWidth: 1))
            RectangleMark(x: .value("i", index),
                          yStart: .value("Open", bodyLow(candle)),
                          yEnd: .value("Close", bodyHigh(candle, priceDomain: priceDomain)),
                          width: .fixed(barWidth))
                .foregroundStyle(palette.color(isUp: candle.isUp))
        }
    }

    /// Volume bars scaled into their own band of the price domain, tallest bar = full band.
    @ChartContentBuilder
    private func volumeMarks(range: Range<Int>, barWidth: CGFloat,
                             band: ChartBand, maxVolume: Double) -> some ChartContent {
        ForEach(range, id: \.self) { index in
            let candle = candles[index]
            BarMark(x: .value("i", index),
                    yStart: .value("VolumeBase", band.bottom),
                    yEnd: .value("Volume", band.bottom + band.height * (candle.volume ?? 0) / maxVolume),
                    width: .fixed(barWidth))
                .foregroundStyle(palette.color(isUp: candle.isUp).opacity(0.35))
        }
    }

    /// Moving averages as plain lines. A bar whose window is not warm yet carries no mark at
    /// all, so the warm-up leaves an honest gap at the left edge instead of a fake value.
    @ChartContentBuilder
    private func movingAverageMarks(range: Range<Int>,
                                    series: [MovingAverageSeries]) -> some ChartContent {
        let palette = ChartIndicatorPalette()
        ForEach(series, id: \.period) { entry in
            ForEach(range, id: \.self) { index in
                if let value = entry.values[safe: index] ?? nil {
                    LineMark(
                        x: .value("i", index),
                        y: .value(entry.period.label, value),
                        series: .value("Series", entry.period.label)
                    )
                    .foregroundStyle(palette.color(for: entry.period))
                    .lineStyle(StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
            }
        }
    }

    /// MACD pane: one histogram bar per candle from the zero line, plus the DIF and DEA
    /// lines. Values are mapped onto the pane's own slice of the shared price domain.
    @ChartContentBuilder
    private func macdMarks(range: Range<Int>, barWidth: CGFloat,
                           series: MACDSeries, scale: MACDValueScale) -> some ChartContent {
        let zero = scale.zeroY
        ForEach(range, id: \.self) { index in
            if let histogram = series.histogram[safe: index] ?? nil {
                BarMark(
                    x: .value("i", index),
                    yStart: .value("MACD Zero", zero),
                    yEnd: .value("MACD Histogram", scale.y(histogram)),
                    width: .fixed(barWidth)
                )
                .foregroundStyle(palette.color(isUp: histogram >= 0).opacity(0.5))
            }
        }
        ForEach(range, id: \.self) { index in
            if let dif = series.dif[safe: index] ?? nil {
                LineMark(
                    x: .value("i", index),
                    y: .value("MACD DIF", scale.y(dif)),
                    series: .value("Series", "DIF")
                )
                .foregroundStyle(ChartIndicatorPalette.dif)
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
        ForEach(range, id: \.self) { index in
            if let dea = series.dea[safe: index] ?? nil {
                LineMark(
                    x: .value("i", index),
                    y: .value("MACD DEA", scale.y(dea)),
                    series: .value("Series", "DEA")
                )
                .foregroundStyle(ChartIndicatorPalette.dea)
                .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }
        }
    }

    @ChartContentBuilder
    private func tradeMarks(_ placements: [TradeMarkerPlacement]) -> some ChartContent {
        ForEach(placements) { placement in
            let marker = placement.marker
            let color = tradeColor(for: marker)
            RuleMark(
                x: .value("Trade", marker.candleIndex),
                yStart: .value("Connector Start", placement.connectorStartPrice),
                yEnd: .value("Trade Marker", placement.anchorPrice)
            )
            .foregroundStyle(Color.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(
                lineWidth: 0.75,
                lineCap: .round,
                dash: [1.5, 2.5]
            ))
            PointMark(
                x: .value("Trade", marker.candleIndex),
                y: .value("Trade Marker", placement.anchorPrice)
            )
            .symbolSize(12)
            .foregroundStyle(color)
            .annotation(
                position: marker.side == .buy ? .bottom : .top,
                alignment: .center,
                spacing: 2
            ) {
                CandleTradeMarkerBadge(
                    text: markerLabel(marker),
                    color: color
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func markerLabel(_ marker: CandleTradeMarker) -> String {
        let side = marker.side == .buy ? "B" : "S"
        return marker.count > 1 ? "\(side)×\(marker.count)" : side
    }

    private func tradeColor(for marker: CandleTradeMarker) -> Color {
        palette.color(isUp: marker.side == .buy)
    }

    /// Candle body / volume bar width from the visible density: 62% of the per-bar slot,
    /// clamped so deep zoom-out still shows a hairline and deep zoom-in stays proportioned.
    /// The container includes the trailing y-axis strip (~48pt); the domain pads one slot
    /// on each side of the visible range.
    private static func barWidth(forVisible count: Int, containerWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 3 }
        let plotWidth = max(containerWidth - 48, 40)
        let slot = plotWidth / CGFloat(count + 2)
        return min(max(slot * 0.62, 1), 24)
    }

    // MARK: - Layout math

    /// Doji candles (open == close) still need a visible body: give them a tiny minimum height
    private func bodyLow(_ candle: Candle) -> Double {
        min(candle.open, candle.close)
    }

    private func bodyHigh(_ candle: Candle, priceDomain: ClosedRange<Double>) -> Double {
        let high = max(candle.open, candle.close)
        let minBody = (priceDomain.upperBound - priceDomain.lowerBound) * 0.002
        return high - bodyLow(candle) < minBody ? bodyLow(candle) + minBody : high
    }

    /// Price scale adapts to the visible window, so zooming in re-spreads the candles
    /// instead of leaving them squashed against the full-history extremes. When volume is
    /// present, the bottom reserves a band slightly taller than the volume overlay. Trade
    /// prices are intentionally excluded: a bad or split-unadjusted entry must not flatten
    /// the candles, and the precise execution price remains available in the hover detail.
    private func yDomain(
        for visible: ArraySlice<Candle>,
        hasBuyMarkers: Bool,
        hasSellMarkers: Bool,
        reserveVolumeBand: Bool,
        reserveMACDBand: Bool = false,
        additionalPrices: [Double] = []
    ) -> ClosedRange<Double> {
        let lo = min(visible.map(\.low).min() ?? 0, additionalPrices.min() ?? .infinity)
        let hi = max(visible.map(\.high).max() ?? 1, additionalPrices.max() ?? -.infinity)
        let span = max(hi - lo, hi * 0.001, 0.0001)
        let bottomPad: Double
        if reserveVolumeBand {
            // Leave a clean lane between the lowest wick and the volume strip for B badges.
            bottomPad = span * (hasBuyMarkers ? 0.42 : 0.28)
        } else {
            bottomPad = span * (hasBuyMarkers ? 0.16 : 0.05)
        }
        let topPad = span * (hasSellMarkers ? 0.16 : 0.05)
        // The MACD pane takes its height out of the price pane, so the domain grows by exactly
        // the share the pane needs and the candles keep the screen band they had before.
        let extraPad = reserveMACDBand ? (span + bottomPad + topPad) * ChartBands.macdDomainGrowth : 0
        return (lo - bottomPad - extraPad)...(hi + topPad)
    }

    /// Badges sit outside the local candle envelope rather than at the execution price.
    /// Looking two bars in either direction keeps a wider `B×N`/`S×N` badge away from
    /// adjacent wicks. A deliberate gap before the neutral dotted connector prevents it
    /// from reading as an extension of the candle wick. The execution price remains in hover.
    private func tradeMarkerPlacements(
        for markers: [CandleTradeMarker],
        visibleRange: Range<Int>,
        yDomain: ClosedRange<Double>
    ) -> [TradeMarkerPlacement] {
        let domainSpan = yDomain.upperBound - yDomain.lowerBound
        let markerGap = domainSpan * 0.026
        let connectorGap = domainSpan * 0.008
        return markers.compactMap { marker in
            guard candles.indices.contains(marker.candleIndex) else { return nil }
            let lowerBound = max(visibleRange.lowerBound, marker.candleIndex - 2)
            let upperBound = min(visibleRange.upperBound, marker.candleIndex + 3)
            let neighbors = candles[lowerBound..<upperBound]
            let anchorPrice: Double
            let connectorStartPrice: Double
            switch marker.side {
            case .buy:
                connectorStartPrice = candles[marker.candleIndex].low - connectorGap
                anchorPrice = (neighbors.map(\.low).min() ?? candles[marker.candleIndex].low) - markerGap
            case .sell:
                connectorStartPrice = candles[marker.candleIndex].high + connectorGap
                anchorPrice = (neighbors.map(\.high).max() ?? candles[marker.candleIndex].high) + markerGap
            }
            return TradeMarkerPlacement(
                marker: marker,
                connectorStartPrice: connectorStartPrice,
                anchorPrice: anchorPrice
            )
        }
    }

    private func axisIndices(for range: Range<Int>) -> [Int] {
        guard range.count > 1 else { return Array(range) }
        let step = max(range.count / 4, 1)
        return Array(stride(from: range.lowerBound, to: range.upperBound, by: step))
    }

    private func dateLabel(for candle: Candle, showsDate: Bool) -> String {
        switch period {
        case .minute1, .minute5, .minute15, .minute30, .hour1:
            CandleChartTimeFormatter.string(
                from: candle.time,
                market: market,
                format: showsDate ? "MM/dd H:mm" : "H:mm"
            )
        case .month, .week:
            candle.time.formatted(.dateTime.year(.twoDigits).month(.twoDigits))
        case .day:
            candle.time.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
    }

    private func visibleSpansMultipleDays(_ visible: ArraySlice<Candle>) -> Bool {
        guard period.isMinuteK, let first = visible.first, let last = visible.last else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market?.timeZone ?? .current
        return !calendar.isDate(first.time, inSameDayAs: last.time)
    }
}

/// One moving-average overlay: the window and its aligned values.
private struct MovingAverageSeries {
    var period: MovingAveragePeriod
    var values: [Double?]
}

/// Vertical split of the price domain, measured from the bottom up. The volume strip and the
/// MACD pane are carved out of the same axis the candles use, which keeps every mark on one x
/// scale and leaves the annotation layer's single plot frame untouched.
private struct ChartBands {
    /// Volume strip with and without the MACD pane competing for the same space.
    static let volumeAlone = 0.20
    static let volumeWithMACD = 0.15
    /// MACD pane as a fraction of the domain.
    static let macd = 0.22
    /// Extra domain height (as a multiple of the un-expanded domain) that buying the MACD
    /// pane costs the axis, so the price pane keeps its pixel height.
    static let macdDomainGrowth = 0.587

    let volume: Double
    let macd: Double

    init(hasVolume: Bool, hasMACD: Bool) {
        volume = hasVolume ? (hasMACD ? Self.volumeWithMACD : Self.volumeAlone) : 0
        macd = hasMACD ? Self.macd : 0
    }

    /// Everything carved out below the candles, and therefore what the annotation layer
    /// must keep clear of.
    var bottomReserved: Double { volume + macd }

    /// MACD sits lowest; the volume strip rides directly above it.
    func macdBand(in domain: ClosedRange<Double>) -> ChartBand {
        ChartBand(bottom: domain.lowerBound, height: (domain.upperBound - domain.lowerBound) * macd)
    }

    func volumeBand(in domain: ClosedRange<Double>) -> ChartBand {
        let span = domain.upperBound - domain.lowerBound
        return ChartBand(bottom: domain.lowerBound + span * macd, height: span * volume)
    }
}

/// A slice of the y-domain, expressed in domain units.
private struct ChartBand {
    var bottom: Double
    var height: Double

    var center: Double { bottom + height / 2 }
}

/// Maps MACD values onto the pane's band. The scale is symmetric about zero, so the zero line
/// stays at a fixed height and the pane does not jump around as the visible range shifts.
private struct MACDValueScale {
    let magnitude: Double
    let band: ChartBand

    init(series: MACDSeries, range: Range<Int>, band: ChartBand) {
        var peak = 0.0
        for index in range {
            let candidates = [
                series.dif[safe: index] ?? nil,
                series.dea[safe: index] ?? nil,
                series.histogram[safe: index] ?? nil
            ]
            for value in candidates {
                if let value, value.isFinite { peak = max(peak, abs(value)) }
            }
        }
        magnitude = peak > 0 ? peak : 1
        self.band = band
    }

    var zeroY: Double { band.center }

    func y(_ value: Double) -> Double {
        let normalized = min(max(value / magnitude, -1), 1)
        return band.center + normalized * band.height / 2
    }
}

private struct TradeMarkerPlacement: Identifiable {
    var marker: CandleTradeMarker
    var connectorStartPrice: Double
    var anchorPrice: Double

    var id: CandleTradeMarker.ID { marker.id }
}

// MARK: - Viewport (zoom/pan/hover state)

/// Window state plus the AppKit event plumbing behind wheel-zoom and scroll-pan.
/// `visibleCount`/`rightOffset` are observed (the chart re-renders on zoom/pan);
/// `hoveredIndex` is observed only by the crosshair overlays. Everything the event
/// handlers need between renders (data count, plot width, cursor location) is
/// intentionally unobserved.
@MainActor
@Observable
public final class CandleChartViewport {
    static let defaultVisibleCount = 60
    static let minVisibleCount = 20

    public init() {}

    var visibleCount = CandleChartViewport.defaultVisibleCount
    /// Bars hidden to the right of the window; 0 = pinned to the latest bar.
    var rightOffset = 0
    var hoveredIndex: Int?

    @ObservationIgnored var dataCount = 0
    @ObservationIgnored var plotWidth: CGFloat = 300
    @ObservationIgnored var cursorInside = false
    @ObservationIgnored var wheelZoomAllowed = true
    @ObservationIgnored var lastDragWidth: CGFloat = 0
    @ObservationIgnored private var panRemainder: Double = 0
    @ObservationIgnored private var monitor: Any?

    public func visibleRange(dataCount: Int) -> Range<Int> {
        guard dataCount > 0 else { return 0..<0 }
        let count = min(visibleCount, dataCount)
        let maxOffset = dataCount - count
        let end = dataCount - 1 - min(max(rightOffset, 0), maxOffset)
        return (end - count + 1)..<(end + 1)
    }

    func reset() {
        visibleCount = Self.defaultVisibleCount
        rightOffset = 0
        panRemainder = 0
    }

    /// factor > 1 zooms in (fewer bars). The bar under the cursor keeps its screen
    /// position, so wheel-zoom feels anchored like TradingView.
    func zoom(by factor: Double) {
        guard dataCount > 0, factor > 0 else { return }
        let range = visibleRange(dataCount: dataCount)
        let oldCount = range.count
        let newCount = min(max(Int((Double(oldCount) / factor).rounded()), Self.minVisibleCount), dataCount)
        guard newCount != oldCount else { return }
        let anchor = hoveredIndex.map { min(max($0, range.lowerBound), range.upperBound - 1) }
            ?? range.upperBound - 1
        let fraction = oldCount > 1
            ? Double(anchor - range.lowerBound) / Double(oldCount - 1)
            : 1
        let newEnd = anchor + Int((Double(newCount - 1) * (1 - fraction)).rounded())
        visibleCount = newCount
        rightOffset = min(max(dataCount - 1 - newEnd, 0), dataCount - newCount)
    }

    /// Positive points pan toward older bars (matches AppKit scroll semantics and
    /// grab-drag direction). Sub-bar remainders accumulate so slow pans stay smooth.
    func pan(byPoints points: CGFloat) {
        guard dataCount > 0 else { return }
        let count = visibleRange(dataCount: dataCount).count
        panRemainder += Double(points) * Double(count) / Double(max(plotWidth, 1))
        let whole = Int(panRemainder.rounded(.towardZero))
        guard whole != 0 else { return }
        panRemainder -= Double(whole)
        rightOffset = min(max(rightOffset + whole, 0), max(dataCount - count, 0))
    }

    #if canImport(AppKit)
    /// Local monitor instead of a gesture: SwiftUI has no scroll-wheel modifier on macOS,
    /// and taking the wheel for zoom must not fight a scrollable ancestor. `cursorInside`
    /// (maintained by onContinuousHover) gates which events belong to the chart.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            // Monitors fire on the main thread; only the Sendable Bool crosses the boundary.
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        cursorInside = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard cursorInside, wheelZoomAllowed, dataCount > 0 else { return false }
        switch event.type {
        case .magnify:
            zoom(by: 1 + event.magnification)
            return true
        case .scrollWheel:
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if event.modifierFlags.contains(.shift) {
                // Shift turns the wheel into a pan; mice report the swapped axis in dy.
                pan(byPoints: dx != 0 ? dx : dy)
            } else if abs(dx) > abs(dy) {
                pan(byPoints: dx)
            } else if dy != 0 {
                zoom(by: exp(dy * 0.006))
            }
            return true
        default:
            return false
        }
    }
    #else
    func startMonitoring() {}
    func stopMonitoring() {}
    #endif
}

// MARK: - Indicator legend

/// Legend pinned to the plot's top-left corner: one swatch per enabled overlay showing the
/// value at the hovered bar, or at the last visible bar while the cursor is away. It reads the
/// shared hover index itself, so only this strip re-renders as the cursor moves — never the
/// candle marks behind it.
private struct CandleIndicatorLegend: View {
    /// Height the strip reserves at the top of the plot, so the OHLC readout starts below it.
    static let height: CGFloat = 18

    let viewport: CandleChartViewport
    let series: [MovingAverageSeries]
    let macd: MACDSeries?
    let range: Range<Int>
    let market: Market?

    private var palette: ChartIndicatorPalette { ChartIndicatorPalette() }

    var body: some View {
        let last = max(range.upperBound - 1, range.lowerBound)
        let index = min(max(viewport.hoveredIndex ?? last, range.lowerBound), last)
        HStack(spacing: 9) {
            ForEach(series, id: \.period) { entry in
                swatch(label: entry.period.label,
                       color: palette.color(for: entry.period),
                       value: entry.values[safe: index] ?? nil)
            }
            if let macd {
                swatch(label: "DIF", color: ChartIndicatorPalette.dif,
                       value: macd.dif[safe: index] ?? nil)
                swatch(label: "DEA", color: ChartIndicatorPalette.dea,
                       value: macd.dea[safe: index] ?? nil)
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.thickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(.separator.opacity(0.5), lineWidth: 0.5))
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func swatch(label: String, color: Color, value: Double?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).foregroundStyle(color)
            Text(value.map { PriceFormatter.price($0, market: market) } ?? "—")
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Crosshair overlays

/// Price-pane crosshair, OHLC readout and axis tags. A separate view so hover-state
/// changes re-render only this overlay, never the candle marks behind it.
private struct CandlePriceOverlay: View {
    let viewport: CandleChartViewport
    let candles: [Candle]
    let range: Range<Int>
    let xDomain: ClosedRange<Int>
    let palette: ChangePalette
    let period: CandlePeriod
    let market: Market?
    let tradeMarkers: [CandleTradeMarker]
    let currencyCode: String?
    let proxy: ChartProxy
    let geo: GeometryProxy
    /// Space to leave above the readout so it clears the indicator legend.
    var readoutTopInset: CGFloat = 0

    var body: some View {
        let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
        ZStack(alignment: .topLeading) {
            CandleHoverCatcher(viewport: viewport, range: range, xDomain: xDomain, plot: plot)
            if let index = viewport.hoveredIndex, let candle = candles[safe: index],
               let xPos = proxy.position(forX: index),
               let yPos = proxy.position(forY: candle.close) {
                let px = plot.origin.x + xPos
                let py = plot.origin.y + min(max(yPos, 0), plot.height)
                ChartCrosshair.lines(px: px, py: py, in: plot)
                priceTag(for: candle, py: py)
                readout(
                    for: candle,
                    previous: candles[safe: index - 1],
                    tradeMarkers: tradeMarkers.filter { $0.candleIndex == index }
                )
                    .padding(EdgeInsets(top: 4 + readoutTopInset, leading: 4,
                                        bottom: 4, trailing: 4))
                    .frame(width: plot.width, height: plot.height,
                           alignment: px > plot.midX ? .topLeading : .topTrailing)
                    .offset(x: plot.origin.x, y: plot.origin.y)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: plot.width, initial: true) { _, width in
            // Pan sensitivity needs the plot width; unobserved, so no render feedback loop.
            viewport.plotWidth = width
        }
    }

    private func priceTag(for candle: Candle, py: CGFloat) -> some View {
        let text = PriceFormatter.price(candle.close, market: market)
        return CrosshairTag(text: text)
            .position(x: geo.size.width - ChartCrosshair.tagWidth(text) / 2, y: py)
    }

    /// OHLC + volume readout, docked to the top corner away from the cursor.
    private func readout(
        for candle: Candle,
        previous: Candle?,
        tradeMarkers: [CandleTradeMarker]
    ) -> some View {
        let base = previous?.close ?? candle.open
        let changePercent = base == 0 ? 0 : (candle.close - base) / base * 100
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(readoutDateLabel(for: candle))
                    .foregroundStyle(.secondary)
                Text(PriceFormatter.percent(changePercent))
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.color(for: changePercent))
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    readoutValue(PulseLocalization.localizedString("chart.open"), PriceFormatter.price(candle.open, market: market))
                    readoutValue(PulseLocalization.localizedString("chart.high"), PriceFormatter.price(candle.high, market: market))
                }
                GridRow {
                    readoutValue(PulseLocalization.localizedString("chart.low"), PriceFormatter.price(candle.low, market: market))
                    readoutValue(PulseLocalization.localizedString("chart.close"), PriceFormatter.price(candle.close, market: market))
                }
                if let volume = candle.volume {
                    GridRow {
                        readoutValue(PulseLocalization.localizedString("chart.volume"), PriceFormatter.compact(volume))
                    }
                }
            }
            if !tradeMarkers.isEmpty {
                Divider()
                    .padding(.vertical, 1)
                ForEach(tradeMarkers) { marker in
                    CandleTradeMarkerReadout(
                        marker: marker,
                        palette: palette,
                        currencyCode: currencyCode
                    )
                }
            }
        }
        .font(.system(size: 9).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.thickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(.separator.opacity(0.5), lineWidth: 0.5))
        .fixedSize()
    }

    private func readoutValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
    }

    private func readoutDateLabel(for candle: Candle) -> String {
        switch period {
        case .minute1, .minute5, .minute15, .minute30, .hour1:
            CandleChartTimeFormatter.string(
                from: candle.time,
                market: market,
                format: "yyyy/MM/dd H:mm"
            )
        case .month:
            candle.time.formatted(.dateTime.year().month(.twoDigits))
        case .week:
            weekRangeLabel(for: candle.time)
        case .day:
            candle.time.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        }
    }

    /// A weekly bar covers a trading week, so the readout shows the Monday–Friday range
    /// instead of the bar's raw timestamp (whichever day the provider stamps it with).
    private func weekRangeLabel(for date: Date) -> String {
        let calendar = Calendar(identifier: .iso8601)  // Monday-based weeks
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        let end = calendar.date(byAdding: .day, value: 4, to: start) ?? date
        let startLabel = start.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        let endLabel = end.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        return "\(startLabel)–\(endLabel)"
    }
}

private struct CandleTradeMarkerBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold, design: .rounded).monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, text.count > 1 ? 4 : 0)
            .frame(minWidth: 14)
            .frame(height: 14)
            .background(color, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.8), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.16), radius: 1, y: 0.5)
    }
}

private struct CandleTradeMarkerReadout: View {
    let marker: CandleTradeMarker
    let palette: ChangePalette
    let currencyCode: String?

    private var sideKey: String {
        marker.side == .buy ? "trade.buy" : "trade.sell"
    }

    private var sideText: String {
        PulseLocalization.localizedString(sideKey)
    }

    private var badgeText: String {
        let side = marker.side == .buy ? "B" : "S"
        return marker.count > 1 ? "\(side)×\(marker.count)" : side
    }

    private var color: Color {
        palette.color(isUp: marker.side == .buy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                CandleTradeMarkerBadge(text: badgeText, color: color)
                    .scaleEffect(0.86, anchor: .leading)
                    .frame(width: badgeText.count > 1 ? 23 : 14, height: 12, alignment: .leading)
                Text(sideText)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    value(
                        PulseLocalization.localizedString("trade.price"),
                        PriceFormatter.price(marker.averagePrice)
                    )
                    value(
                        PulseLocalization.localizedString("position.quantity"),
                        PriceFormatter.quantity(marker.totalQuantity)
                    )
                }
                GridRow {
                    value(
                        PulseLocalization.localizedString("trade.amount"),
                        PriceFormatter.money(marker.totalAmount, currencyCode: currencyCode)
                    )
                }
            }
        }
    }

    private func value(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.primary)
        }
    }
}

@MainActor
private enum CandleChartTimeFormatter {
    private static var cache: [String: DateFormatter] = [:]

    static func string(from date: Date, market: Market?, format: String) -> String {
        let timeZone = market?.timeZone ?? .current
        let key = "\(timeZone.identifier)|\(format)"
        let formatter: DateFormatter
        if let cached = cache[key] {
            formatter = cached
        } else {
            let created = DateFormatter()
            created.locale = Locale(identifier: "en_US_POSIX")
            created.timeZone = timeZone
            created.dateFormat = format
            cache[key] = created
            formatter = created
        }
        return formatter.string(from: date)
    }
}

/// Transparent layer that tracks the cursor and feeds the shared hovered index.
private struct CandleHoverCatcher: View {
    let viewport: CandleChartViewport
    let range: Range<Int>
    let xDomain: ClosedRange<Int>
    let plot: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    viewport.hoveredIndex = index(at: point)
                case .ended:
                    viewport.hoveredIndex = nil
                }
            }
    }

    /// Invert the linear index scale by hand: `proxy.value(atX:)` on an Int scale truncates,
    /// which would make the snap lag half a candle behind the cursor.
    private func index(at point: CGPoint) -> Int? {
        guard !range.isEmpty, plot.width > 0,
              plot.insetBy(dx: -2, dy: -4).contains(point) else { return nil }
        let rel = (point.x - plot.origin.x) / plot.width
        let raw = Double(xDomain.lowerBound) + rel * Double(xDomain.upperBound - xDomain.lowerBound)
        return min(max(Int(raw.rounded()), range.lowerBound), range.upperBound - 1)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    subscript(safeRange range: Range<Int>) -> ArraySlice<Element> {
        let clamped = range.clamped(to: indices.lowerBound..<indices.upperBound)
        return self[clamped]
    }
}
