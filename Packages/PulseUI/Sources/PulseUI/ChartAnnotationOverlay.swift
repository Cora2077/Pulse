import SwiftUI
import PulseCore

/// Coordinate conversions supplied by each chart. `xForTime` only resolves exact
/// loaded samples; an unloaded trend endpoint is intentionally left unprojected.
struct ChartAnnotationCoordinates {
    var plot: CGRect
    var pricePane: CGRect
    var sampleTimes: [Date]
    var market: Market?
    var palette: ChangePalette
    var scopeForNewTrend: ChartDrawingScope
    var latestRealClose: Double?
    var xForTime: (Date) -> CGFloat?
    var anchorAt: (CGPoint) -> ChartAnchor?
    var snappedAnchorAt: (CGPoint) -> ChartAnchor?
    var onHover: (CGPoint?) -> Void
    var yForPrice: (Double) -> CGFloat?
    var shiftAnchor: (ChartAnchor, CGFloat, CGFloat) -> ChartAnchor?
    var pan: (CGFloat) -> Void
    var resetView: () -> Void
}

/// Shared interaction and rendering layer for the candle and intraday chart adapters.
/// Its local state redraws only this overlay; it never changes the underlying Chart marks.
struct ChartAnnotationOverlay: View {
    let configuration: ChartAnnotationConfiguration
    let coordinates: ChartAnnotationCoordinates

    @State private var pendingStart: ChartAnchor?
    @State private var cursorAnchor: ChartAnchor?
    @State private var measurement: TemporaryMeasurement?
    @State private var interaction: PointerInteraction?
    @State private var previewDrawing: ChartDrawing?
    @State private var pendingDrawingID = UUID()
    @State private var lastPanX: CGFloat?
    @State private var measurementCardHitRect: CGRect = .zero

    private var controller: ChartAnnotationController { configuration.controller }

    private var visiblePersistentDrawingIDs: Set<UUID> {
        guard controller.showsDrawings else { return [] }
        return Set(configuration.drawings.filter {
            !$0.isDeleted && $0.isValid && drawing($0, matches: coordinates.scopeForNewTrend)
        }.map(\.id))
    }

    var body: some View {
        let _ = controller.attach(configuration, visibleDrawingIDs: visiblePersistentDrawingIDs)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
            drawingLayer
            missingHistoryNotice
            planLayer
            measurementLayer
        }
        .frame(width: max(coordinates.plot.maxX, coordinates.pricePane.maxX),
               height: max(coordinates.plot.maxY, coordinates.pricePane.maxY))
        .coordinateSpace(name: "chart-annotation")
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                coordinates.onHover(point)
                cursorAnchor = controller.tool == .trend || controller.tool == .measure
                    ? interactionAnchor(at: point) : nil
            case .ended:
                coordinates.onHover(nil)
                cursorAnchor = nil
            }
        }
        .simultaneousGesture(pointerGesture)
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard controller.tool == .browse,
                  coordinates.pricePane.contains(value.location),
                  drawingTarget(at: value.location) == nil,
                  measurementHandle(at: value.location) == nil,
                  !isMeasurementSelectionHit(value.location),
                  !isPlanLabelHit(value.location) else { return }
            coordinates.resetView()
        })
        .onAppear {
            controller.attach(configuration, visibleDrawingIDs: visiblePersistentDrawingIDs)
        }
        .onChange(of: configuration.drawings) { _, _ in
            controller.attach(configuration, visibleDrawingIDs: visiblePersistentDrawingIDs)
        }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in
            clearTransientState()
            controller.attach(configuration, visibleDrawingIDs: visiblePersistentDrawingIDs)
        }
        .onChange(of: controller.transientResetID) { _, _ in clearTransientState() }
        .onChange(of: controller.measurementClearID) { _, _ in clearMeasurementState() }
        .onChange(of: controller.tool) { _, _ in
            pendingStart = nil
            previewDrawing = nil
            interaction = nil
            controller.finishInteraction()
        }
        .onChange(of: coordinates.sampleTimes) { _, _ in
            // A newly loaded history range can complete a previously missing trend.
            coordinates.onHover(nil)
            cursorAnchor = nil
        }
        .onChange(of: coordinates.scopeForNewTrend) { _, _ in controller.resetTransientState() }
        .onDisappear {
            coordinates.onHover(nil)
            clearTransientState()
        }
    }

    private var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("chart-annotation"))
            .onChanged { value in
                guard coordinates.pricePane.contains(value.startLocation) else { return }
                if interaction == nil {
                    beginPointerInteraction(at: value.startLocation)
                }
                guard let interaction else { return }
                updatePointerInteraction(interaction, location: clamped(value.location))
            }
            .onEnded { value in
                defer {
                    interaction = nil
                    previewDrawing = nil
                    lastPanX = nil
                    if pendingStart != nil && controller.tool != .browse {
                        controller.beginInteraction()
                    } else {
                        controller.finishInteraction()
                    }
                }
                guard coordinates.pricePane.contains(value.startLocation) else { return }
                finishPointerInteraction(at: clamped(value.location), translation: value.translation)
            }
    }

    private func beginPointerInteraction(at point: CGPoint) {
        switch controller.tool {
        case .horizontal, .trend, .measure:
            controller.beginInteraction()
            interaction = .tool(controller.tool, origin: point)
        case .browse:
            if let measurementHandle = measurementHandle(at: point) {
                controller.selectMeasurement()
                controller.beginInteraction()
                interaction = .measureHandle(measurementHandle, origin: point)
            } else if isMeasurementSelectionHit(point) {
                controller.selectMeasurement()
                interaction = .ignore
            } else if let target = drawingTarget(at: point) {
                controller.selectDrawing(target.drawing.id)
                guard !target.drawing.isLocked else {
                    interaction = .selection(target.drawing.id, origin: point)
                    return
                }
                controller.beginInteraction()
                interaction = .moveDrawing(target, origin: point)
            } else if isPlanLabelHit(point) {
                interaction = .ignore
            } else {
                controller.selectDrawing(nil)
                controller.beginInteraction()
                interaction = .pan(origin: point)
                lastPanX = point.x
            }
        }
    }

    private func updatePointerInteraction(_ interaction: PointerInteraction, location: CGPoint) {
        switch interaction {
        case .tool(let tool, _):
            if tool == .trend || tool == .measure { cursorAnchor = interactionAnchor(at: location) }
        case .moveDrawing(let target, let origin):
            guard let updated = movedDrawing(target, from: origin, to: location) else { return }
            previewDrawing = updated
        case .measureHandle(let handle, _):
            guard let anchor = interactionAnchor(at: location), var measurement else { return }
            measurement.update(handle, to: anchor)
            self.measurement = measurement
        case .pan:
            if let lastPanX {
                coordinates.pan(location.x - lastPanX)
            }
            lastPanX = location.x
        case .selection, .ignore:
            break
        }
    }

    private func finishPointerInteraction(at point: CGPoint, translation: CGSize) {
        guard let interaction else { return }
        switch interaction {
        case .tool(let tool, let origin):
            let moved = hypot(translation.width, translation.height) > 3
            // A click creates one point; a drag may complete a trend or measurement in
            // one gesture, while the usual two-click flow remains available.
            guard let end = interactionAnchor(at: moved ? point : origin) else { return }
            finishTool(tool, at: end)
        case .moveDrawing(let target, let origin):
            let moved = hypot(translation.width, translation.height) > 3
            guard moved, let drawing = movedDrawing(target, from: origin, to: point) else { return }
            var committed = drawing
            committed.updatedAt = .now
            configuration.onUpsert(committed)
            controller.selectDrawing(committed.id)
        case .measureHandle(let handle, _):
            let moved = hypot(translation.width, translation.height) > 3
            if moved, let anchor = interactionAnchor(at: point), var measurement {
                measurement.update(handle, to: anchor)
                self.measurement = measurement
            }
        case .pan(let origin):
            _ = origin
            _ = point
            _ = translation
        case .selection, .ignore:
            break
        }
    }

    private func finishTool(_ tool: ChartAnnotationTool, at anchor: ChartAnchor) {
        switch tool {
        case .browse:
            break
        case .horizontal:
            let drawing = ChartDrawing(
                geometry: .horizontal(price: anchor.price),
                scope: .all,
                style: ChartDrawingStyle(color: .blue, lineWidth: 1.5)
            )
            configuration.onUpsert(drawing)
            controller.selectDrawing(drawing.id)
            controller.tool = .browse
        case .trend:
            if let start = pendingStart {
                let drawing = ChartDrawing(
                    geometry: .trend(start: start, end: anchor),
                    scope: coordinates.scopeForNewTrend,
                    style: ChartDrawingStyle(color: .blue, lineWidth: 1.5)
                )
                configuration.onUpsert(drawing)
                controller.selectDrawing(drawing.id)
                pendingStart = nil
                controller.tool = .browse
            } else {
                pendingStart = anchor
                controller.beginInteraction()
            }
        case .measure:
            if let start = pendingStart {
                measurement = TemporaryMeasurement(start: start, end: anchor)
                measurementCardHitRect = .zero
                controller.setMeasurementAvailable(true)
                controller.selectMeasurement()
                pendingStart = nil
                controller.tool = .browse
            } else {
                pendingStart = anchor
                controller.beginInteraction()
            }
        }
    }

    private func movedDrawing(_ target: DrawingTarget, from origin: CGPoint, to point: CGPoint) -> ChartDrawing? {
        let source = target.drawing
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        switch source.geometry {
        case .horizontal:
            guard let price = interactionAnchor(at: point)?.price else { return nil }
            var copy = source
            copy.geometry = .horizontal(price: price)
            return copy
        case .trend(let start, let end):
            var copy = source
            switch target.part {
            case .start:
                guard let updated = interactionAnchor(at: point) else { return nil }
                copy.geometry = .trend(start: updated, end: end)
            case .end:
                guard let updated = interactionAnchor(at: point) else { return nil }
                copy.geometry = .trend(start: start, end: updated)
            case .line:
                guard let movedStart = coordinates.shiftAnchor(start, dx, dy),
                      let movedEnd = coordinates.shiftAnchor(end, dx, dy) else { return nil }
                copy.geometry = .trend(start: movedStart, end: movedEnd)
            }
            return copy
        }
    }

    private var drawingLayer: some View {
        let source = controller.showsDrawings ? visibleDrawings : []
        let projected = source.compactMap { project($0) }
        return ZStack(alignment: .topLeading) {
            ForEach(projected) { projection in
                let selected = projection.drawing.id == controller.selectedDrawingID
                AnnotationSegment(start: projection.line.start, end: projection.line.end)
                    .stroke(styleColor(projection.drawing.style.color).opacity(0.96),
                            style: StrokeStyle(lineWidth: projection.drawing.style.lineWidth + (selected ? 0.5 : 0),
                                               lineCap: .round,
                                               dash: projection.isPreview ? [4, 3] : []))
                    .contentShape(AnnotationSegment(start: projection.line.start, end: projection.line.end)
                        .stroke(style: StrokeStyle(lineWidth: 13, lineCap: .round)))
                    .onTapGesture {
                        if controller.tool == .browse {
                            controller.selectDrawing(projection.drawing.id)
                        }
                    }
                    .onTapGesture(count: 2) {
                        if controller.tool == .browse {
                            configuration.onEditDrawing(projection.drawing.id)
                        }
                    }
                    .contextMenu { drawingMenu(for: projection.drawing) }
                    .allowsHitTesting(!projection.isPreview)

                if selected, !projection.drawing.isLocked, !projection.isPreview {
                    ForEach(Array(projection.handles.enumerated()), id: \.offset) { _, handle in
                        Circle()
                            .fill(.background)
                            .overlay(Circle().stroke(styleColor(projection.drawing.style.color), lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(handle)
                            .allowsHitTesting(false)
                    }
                }

                if case .horizontal(let price) = projection.drawing.geometry {
                    drawingPriceLabel(projection.drawing, price: price, y: projection.start.y)
                }
            }
        }
        .clippedTo(coordinates.pricePane)
    }

    private var missingHistoryNotice: some View {
        let missing = controller.showsDrawings && configuration.drawings.contains { drawing in
            guard !drawing.isDeleted, drawing.isValid, self.drawing(drawing, matches: coordinates.scopeForNewTrend) else { return false }
            guard case .trend = drawing.geometry else { return false }
            return project(drawing) == nil
        }
        return Group {
            if missing {
                Text(PulseLocalization.localizedString("chart.annotation.historyMissing"))
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .position(x: coordinates.pricePane.midX, y: coordinates.pricePane.minY + 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var visibleDrawings: [ChartDrawing] {
        guard controller.showsDrawings else { return [] }
        var drawings = configuration.drawings.filter {
            !$0.isDeleted && $0.isValid && drawing($0, matches: coordinates.scopeForNewTrend)
        }
        if let previewDrawing,
           let index = drawings.firstIndex(where: { $0.id == previewDrawing.id }) {
            drawings[index] = previewDrawing
        }
        if let start = pendingStart, controller.tool == .trend, let end = cursorAnchor {
                drawings.append(ChartDrawing(id: pendingDrawingID,
                                         geometry: .trend(start: start, end: end),
                                         scope: coordinates.scopeForNewTrend,
                                         style: ChartDrawingStyle(color: .blue, lineWidth: 1.5)))
        }
        return drawings
    }

    private func drawing(_ drawing: ChartDrawing, matches scope: ChartDrawingScope) -> Bool {
        switch (drawing.scope, scope) {
        case (.all, _): true
        case (.candles(let stored), .candles(let current)): stored == current
        case (.intraday(let stored), .intraday(let current)):
            sameSessionDay(stored, current, market: coordinates.market)
        default: false
        }
    }

    private func project(_ drawing: ChartDrawing) -> DrawingProjection? {
        switch drawing.geometry {
        case .horizontal(let price):
            guard let y = coordinates.yForPrice(price) else { return nil }
            let line = AnnotationSegment(start: CGPoint(x: coordinates.plot.minX, y: y),
                                         end: CGPoint(x: coordinates.plot.maxX, y: y))
            return DrawingProjection(drawing: drawing, line: line,
                                     start: CGPoint(x: coordinates.plot.minX, y: y),
                                     end: CGPoint(x: coordinates.plot.maxX, y: y), handles: [],
                                     isPreview: !configuration.drawings.contains(where: { $0.id == drawing.id }))
        case .trend(let first, let second):
            guard let x1 = coordinates.xForTime(first.time), let y1 = coordinates.yForPrice(first.price),
                  let x2 = coordinates.xForTime(second.time), let y2 = coordinates.yForPrice(second.price) else {
                return nil
            }
            let anchorStart = CGPoint(x: x1, y: y1)
            let anchorEnd = CGPoint(x: x2, y: y2)
            // A trend line reads as an infinite line through both anchors: the drawn
            // line and its hit area run to the price pane edges, while the handles and
            // the drag anchors stay on the two points the user actually placed.
            let extended = ChartAnnotationMath.extendedLine(through: anchorStart, and: anchorEnd,
                                                            within: coordinates.pricePane)
            return DrawingProjection(drawing: drawing,
                                     line: AnnotationSegment(start: extended.start, end: extended.end),
                                     start: anchorStart, end: anchorEnd,
                                     handles: [anchorStart, anchorEnd],
                                     isPreview: !configuration.drawings.contains(where: { $0.id == drawing.id }))
        }
    }

    private func drawingPriceLabel(_ drawing: ChartDrawing, price: Double, y: CGFloat) -> some View {
        let text = PriceFormatter.price(price, market: coordinates.market)
        return HStack(spacing: 4) {
            if let note = drawing.note, !note.isEmpty {
                Text(note).lineLimit(1)
            }
            Text(text).monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(styleColor(drawing.style.color).opacity(0.55), lineWidth: 0.7))
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if controller.tool == .browse { controller.selectDrawing(drawing.id) }
        })
        .onTapGesture {
            if controller.tool == .browse { controller.selectDrawing(drawing.id) }
        }
        .onTapGesture(count: 2) { configuration.onEditDrawing(drawing.id) }
        .contextMenu { drawingMenu(for: drawing) }
        .help(drawing.note ?? text)
        .position(x: coordinates.plot.maxX - 48, y: y)
    }

    @ViewBuilder
    private func drawingMenu(for drawing: ChartDrawing) -> some View {
        Button(PulseLocalization.localizedString("chart.annotation.drawing.edit")) {
            configuration.onEditDrawing(drawing.id)
        }
        Button(PulseLocalization.localizedString(drawing.isLocked
                                                 ? "chart.annotation.drawing.unlock"
                                                 : "chart.annotation.drawing.lock")) {
            var updated = drawing
            updated.isLocked.toggle()
            updated.updatedAt = .now
            configuration.onUpsert(updated)
        }
        Button(PulseLocalization.localizedString("chart.annotation.drawing.delete"), role: .destructive) {
            configuration.onDelete(drawing.id)
            if controller.selectedDrawingID == drawing.id { controller.selectDrawing(nil) }
        }
    }

    private var planLayer: some View {
        guard controller.showsPlans, !coordinates.sampleTimes.isEmpty else { return AnyView(EmptyView()) }
        let groups = visiblePlanGroups
        let placements = planLabelPlacements
        return AnyView(ZStack(alignment: .topLeading) {
            ForEach(groups) { group in
                if let y = coordinates.yForPrice(group.key.price) {
                    Path { path in
                        path.move(to: CGPoint(x: coordinates.plot.minX, y: y))
                        path.addLine(to: CGPoint(x: coordinates.plot.maxX, y: y))
                    }
                    .stroke(planColor(group.key.kind).opacity(0.72), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .allowsHitTesting(false)
                }
            }
            ForEach(placements) { placement in
                Path { path in
                    path.move(to: CGPoint(x: coordinates.plot.maxX - 6, y: placement.anchorY))
                    path.addLine(to: CGPoint(x: coordinates.plot.maxX - 2, y: placement.labelY))
                }
                .stroke(planColor(placement.group.key.kind).opacity(0.65), lineWidth: 0.8)
                .allowsHitTesting(false)
                planLabel(placement.group, beyondEdge: placement.isBeyondEdge)
                    .frame(width: min(max(coordinates.plot.width * 0.36, 74), 128), height: 19)
                    .position(x: coordinates.plot.maxX - min(max(coordinates.plot.width * 0.18, 42), 65),
                              y: placement.labelY)
            }
        }.clippedTo(coordinates.pricePane))
    }

    @ViewBuilder
    private func planLabel(_ group: PlanGroup, beyondEdge: Bool) -> some View {
        let first = group.plans[0]
        let kind = PulseLocalization.localizedString(first.kind == .buy ? "plan.kind.buy" : "plan.kind.sell")
        let price = PriceFormatter.price(first.price, market: coordinates.market)
        let quantity = group.plans.reduce(0) { $0 + $1.quantity }
        let reached = configuration.currentPrice.map { current in
            group.plans.contains { $0.status == .active && $0.isReached(at: current) }
        } ?? false
        let unit = configuration.quantityUnit ?? planQuantityUnit
        let arrow = beyondEdge ? (coordinates.yForPrice(first.price).map { $0 < coordinates.pricePane.minY } == true ? "↑ " : "↓ ") : ""
        let edgeHint = beyondEdge ? planEdgeHint(for: first.price) : nil
        if beyondEdge {
            Button {
                guard controller.tool == .browse else { return }
                controller.focusedPlanPrice = first.price
            } label: {
                planLabelContents(kind: kind, price: price, quantity: quantity, unit: unit,
                                  count: group.plans.count, reached: reached, arrow: arrow,
                                  color: planColor(first.kind), edgeHint: edgeHint?.percent)
            }
            .buttonStyle(.plain)
            .disabled(controller.tool != .browse)
            .help(planTooltip(group, reached: reached) + (edgeHint.map { "\n\($0.detail)" } ?? ""))
            .accessibilityLabel(planAccessibilityLabel(kind: kind, price: price, quantity: quantity,
                                                       unit: unit, count: group.plans.count)
                                + (edgeHint.map { " · \($0.detail)" } ?? ""))
        } else if group.plans.count == 1 {
            Button {
                guard controller.tool == .browse else { return }
                configuration.onEditPlan(first.id)
            } label: {
                planLabelContents(kind: kind, price: price, quantity: quantity, unit: unit,
                                  count: 1, reached: reached, arrow: arrow,
                                  color: planColor(first.kind), edgeHint: nil)
            }
            .buttonStyle(.plain)
            .disabled(controller.tool != .browse)
            .help(planTooltip(group, reached: reached))
            .accessibilityLabel(planAccessibilityLabel(kind: kind, price: price, quantity: quantity,
                                                       unit: unit, count: 1))
        } else {
            Menu {
                ForEach(group.plans) { plan in
                    Button {
                        configuration.onEditPlan(plan.id)
                    } label: {
                        Text("\(PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell")) · \(PriceFormatter.price(plan.price, market: coordinates.market)) · \(PriceFormatter.quantity(plan.quantity))\(unit.map { " \($0)" } ?? "") · \(PulseLocalization.localizedString("plan.status.\(plan.status.rawValue)"))")
                    }
                    .help(plan.note ?? "")
                }
            } label: {
                planLabelContents(kind: kind, price: price, quantity: quantity, unit: unit,
                                  count: group.plans.count, reached: reached, arrow: arrow,
                                  color: planColor(first.kind), edgeHint: nil)
            }
            .menuStyle(.borderlessButton)
            .disabled(controller.tool != .browse)
            .help(planTooltip(group, reached: reached))
            .accessibilityLabel(planAccessibilityLabel(kind: kind, price: price, quantity: quantity,
                                                       unit: unit, count: group.plans.count))
        }

    }

    private func planLabelContents(kind: String, price: String, quantity: Double, unit: String?,
                                   count: Int, reached: Bool, arrow: String, color: Color,
                                   edgeHint: String?) -> some View {
        HStack(spacing: 3) {
            if reached { Text("●").foregroundStyle(.green) }
            Text("\(arrow)\(kind) \(price)").lineLimit(1)
            if let edgeHint {
                Text(edgeHint).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("· \(PriceFormatter.quantity(quantity))\(unit.map { " \($0)" } ?? "")")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            if count > 1 { Text("×\(count)").foregroundStyle(.secondary) }
        }
        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.8), lineWidth: 0.8))
    }

    private func planTooltip(_ group: PlanGroup, reached: Bool) -> String {
        ([PriceFormatter.money(group.plans.reduce(0) { $0 + $1.estimatedAmount }, currencyCode: configuration.currencyCode)]
            + group.plans.compactMap(\.note).filter { !$0.isEmpty }
            + (reached ? [PulseLocalization.localizedString("plan.reached")] : [])).joined(separator: "\n")
    }

    private var visiblePlanGroups: [PlanGroup] {
        let plans = configuration.plans.filter {
            $0.price.isFinite && $0.price > 0
                && (controller.showsHistoricalPlans || $0.status == .active)
        }
        return Dictionary(grouping: plans, by: { PlanGroupKey(kind: $0.kind, price: $0.price) })
            .map { key, plans in PlanGroup(key: key, plans: TradePlan.ordered(plans)) }
            .sorted { lhs, rhs in
                if lhs.key.price != rhs.key.price { return lhs.key.price < rhs.key.price }
                return lhs.key.kind == .buy && rhs.key.kind == .sell
            }
    }

    private var planLabelPlacements: [PlanLabelPlacement] {
        let candidates = visiblePlanGroups.compactMap { group -> PlanLabelCandidate? in
            guard let y = coordinates.yForPrice(group.key.price) else { return nil }
            let clippedY = min(max(y, coordinates.pricePane.minY + 10), coordinates.pricePane.maxY - 10)
            return PlanLabelCandidate(group: group, anchorY: clippedY, desiredY: y)
        }
        return ChartAnnotationMath.placePlanLabels(candidates,
                                                   bounds: coordinates.pricePane.minY...coordinates.pricePane.maxY,
                                                   gap: 21)
    }

    private func planEdgeHint(for price: Double) -> (percent: String, detail: String)? {
        let reference = [configuration.currentPrice, coordinates.latestRealClose]
            .compactMap { $0 }
            .first(where: { $0.isFinite && $0 > 0 })
        guard let reference else { return nil }
        let percent = (price - reference) / reference * 100
        guard percent.isFinite else { return nil }
        let formattedPercent = PriceFormatter.percent(percent)
        return (formattedPercent,
                PulseLocalization.localizedString("chart.annotation.plan.edgeHint",
                                                  PriceFormatter.price(price, market: coordinates.market),
                                                  formattedPercent))
    }

    private func planAccessibilityLabel(kind: String, price: String, quantity: Double,
                                        unit: String?, count: Int) -> String {
        "\(kind) \(price) · \(PriceFormatter.quantity(quantity))\(unit.map { " \($0)" } ?? "")\(count > 1 ? " · \(count)" : "")"
    }

    private var planQuantityUnit: String? {
        guard let market = coordinates.market else { return nil }
        return switch market {
        case .us, .hk, .jp, .kr, .kq, .sh, .sz:
            PulseLocalization.localizedString("trade.unit.shares")
        default:
            nil
        }
    }

    private var measurementLayer: some View {
        Group {
            if let measurement {
                let first = projected(measurement.start)
                let second = projected(measurement.end)
                if let first, let second {
                    let rect = CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                                      width: max(1, abs(second.x - first.x)),
                                      height: max(1, abs(second.y - first.y)))
                    let selected = controller.isMeasurementSelected
                    Rectangle()
                        .fill(Color.accentColor.opacity(selected ? 0.2 : 0.1))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(selected ? 1 : 0.65),
                                                    style: StrokeStyle(lineWidth: selected ? 2 : 1,
                                                                       dash: selected ? [] : [3, 2])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                    if selected {
                        measurementHandleView(at: first)
                        measurementHandleView(at: second)
                    }
                    if let result = ChartMeasurement(start: measurement.start, end: measurement.end,
                                                     sampleTimes: coordinates.sampleTimes) {
                        measurementCard(result, at: CGPoint(x: rect.midX, y: rect.minY - 6))
                    }
                }
            } else if let start = pendingStart, controller.tool == .measure, let end = cursorAnchor,
                      let first = projected(start), let second = projected(end) {
                let rect = CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                                  width: max(1, abs(second.x - first.x)), height: max(1, abs(second.y - first.y)))
                Rectangle()
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .clippedTo(coordinates.pricePane)
    }

    private func measurementHandleView(at point: CGPoint) -> some View {
        Circle().fill(Color.accentColor.opacity(0.92))
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .position(point)
            .allowsHitTesting(false)
    }

    private func measurementCard(_ result: ChartMeasurement, at point: CGPoint) -> some View {
        let countKey: String
        if case .intraday = coordinates.scopeForNewTrend {
            countKey = "chart.annotation.measure.points"
        } else {
            countKey = "chart.annotation.measure.candles"
        }
        let count = PulseLocalization.localizedString(countKey).replacingOccurrences(of: "%d", with: "\(result.pointCount)")
        let elapsed = elapsedLabel(result.elapsedSeconds)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(PriceFormatter.change(result.priceChange, market: coordinates.market)).fontWeight(.semibold)
                Text(PriceFormatter.percent(result.priceChangePercent)).foregroundStyle(.secondary)
            }
            Text("\(count) · \(elapsed)").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.system(size: 10, design: .rounded).monospacedDigit())
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.6), lineWidth: 0.6))
        .fixedSize()
        .background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named("chart-annotation"))
                Color.clear
                    .onAppear { measurementCardHitRect = frame }
                    .onChange(of: frame) { _, updated in measurementCardHitRect = updated }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if controller.tool == .browse { controller.selectMeasurement() }
        }
        .contextMenu {
            Button(PulseLocalization.localizedString("chart.annotation.measure.clear")) {
                controller.clearMeasurement()
            }
        }
        .help(PulseLocalization.localizedString("chart.annotation.measure.clear"))
        .position(x: min(max(point.x, coordinates.pricePane.minX + 62), coordinates.pricePane.maxX - 62),
                  y: min(max(point.y, coordinates.pricePane.minY + 21), coordinates.pricePane.maxY - 21))
    }

    private func elapsedLabel(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? "0m"
    }

    private func projected(_ anchor: ChartAnchor) -> CGPoint? {
        guard let x = coordinates.xForTime(anchor.time), let y = coordinates.yForPrice(anchor.price) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func interactionAnchor(at point: CGPoint) -> ChartAnchor? {
        if controller.snappingEnabled, let snapped = coordinates.snappedAnchorAt(point) {
            return snapped
        }
        return coordinates.anchorAt(point)
    }

    private func drawingTarget(at point: CGPoint) -> DrawingTarget? {
        let projected = visibleDrawings.compactMap(project)
        for item in projected.reversed() {
            switch item.drawing.geometry {
            case .horizontal:
                if abs(point.y - item.start.y) <= 8 {
                    return DrawingTarget(drawing: item.drawing, part: .line)
                }
            case .trend:
                if distance(point, item.start) <= 10 { return DrawingTarget(drawing: item.drawing, part: .start) }
                if distance(point, item.end) <= 10 { return DrawingTarget(drawing: item.drawing, part: .end) }
                if distance(point, from: item.line.start, to: item.line.end) <= 8 {
                    return DrawingTarget(drawing: item.drawing, part: .line)
                }
            }
        }
        return nil
    }

    private func measurementHandle(at point: CGPoint) -> MeasurementHandle? {
        guard let measurement,
              let start = projected(measurement.start), let end = projected(measurement.end) else { return nil }
        if distance(point, start) <= 11 { return .start }
        if distance(point, end) <= 11 { return .end }
        return nil
    }

    private func isMeasurementSelectionHit(_ point: CGPoint) -> Bool {
        guard measurement != nil else { return false }
        if measurementCardHitRect.width > 0, measurementCardHitRect.height > 0,
           measurementCardHitRect.contains(point) {
            return true
        }
        guard let measurement,
              let first = projected(measurement.start), let second = projected(measurement.end) else {
            return false
        }
        let rect = CGRect(x: min(first.x, second.x), y: min(first.y, second.y),
                          width: max(1, abs(second.x - first.x)),
                          height: max(1, abs(second.y - first.y)))
        let tolerance: CGFloat = 8
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        return [abs(point.x - rect.minX), abs(point.x - rect.maxX),
                abs(point.y - rect.minY), abs(point.y - rect.maxY)].contains { $0 <= tolerance }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, coordinates.pricePane.minX), coordinates.pricePane.maxX),
                y: min(max(point.y, coordinates.pricePane.minY), coordinates.pricePane.maxY))
    }

    private func clearTransientState() {
        pendingStart = nil
        pendingDrawingID = UUID()
        cursorAnchor = nil
        measurement = nil
        measurementCardHitRect = .zero
        interaction = nil
        previewDrawing = nil
        controller.finishInteraction()
        controller.setMeasurementAvailable(false)
    }

    private func clearMeasurementState() {
        measurement = nil
        measurementCardHitRect = .zero
        if controller.tool == .measure { pendingStart = nil }
        if let interaction {
            switch interaction {
            case .measureHandle, .tool(.measure, _):
                self.interaction = nil
                controller.finishInteraction()
            default:
                break
            }
        }
        controller.setMeasurementAvailable(false)
    }

    private func styleColor(_ color: ChartDrawingColor) -> Color {
        switch color {
        case .blue: .blue
        case .orange: .orange
        case .purple: .purple
        case .gray: .secondary
        }
    }

    private func planColor(_ kind: TradePlan.Kind) -> Color {
        coordinates.palette.color(isUp: kind == .buy)
    }

    private func sameSessionDay(_ first: Date, _ second: Date, market: Market?) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market?.timeZone ?? .current
        return calendar.isDate(first, inSameDayAs: second)
    }

    private func isPlanLabelHit(_ point: CGPoint) -> Bool {
        guard controller.showsPlans, !coordinates.sampleTimes.isEmpty else { return false }
        let minX = coordinates.plot.maxX - min(max(coordinates.plot.width * 0.36, 74), 128)
        guard point.x >= minX, point.x <= coordinates.plot.maxX else { return false }
        return planLabelPlacements.contains { abs(point.y - $0.labelY) <= 12 }
    }

    private func distance(_ point: CGPoint, _ other: CGPoint) -> CGFloat {
        hypot(point.x - other.x, point.y - other.y)
    }

    private func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        ChartAnnotationMath.distance(point, from: start, to: end)
    }
}

// MARK: - Projection helpers shared by both chart adapters

enum ChartAnnotationMath {
    static func exactIndex(for time: Date, sampleTimes: [Date]) -> Int? {
        sampleTimes.firstIndex(where: { abs($0.timeIntervalSince(time)) <= 0.001 })
    }

    static func xCoordinate(index: Int, domain: ClosedRange<Int>, plot: CGRect) -> CGFloat? {
        guard plot.width > 0, domain.upperBound != domain.lowerBound else { return nil }
        let fraction = CGFloat(index - domain.lowerBound) / CGFloat(domain.upperBound - domain.lowerBound)
        return plot.minX + fraction * plot.width
    }

    static func nearestIndex(atX x: CGFloat, domain: ClosedRange<Int>, plot: CGRect, count: Int) -> Int? {
        guard plot.width > 0, domain.upperBound != domain.lowerBound else { return nil }
        let fraction = Double((x - plot.minX) / plot.width)
        let index = Int((Double(domain.lowerBound) + fraction * Double(domain.upperBound - domain.lowerBound)).rounded())
        return (0..<count).contains(index) ? index : nil
    }

    static func yCoordinate(price: Double, domain: ClosedRange<Double>, plot: CGRect) -> CGFloat? {
        guard price.isFinite, plot.height > 0, domain.upperBound != domain.lowerBound else { return nil }
        let fraction = (domain.upperBound - price) / (domain.upperBound - domain.lowerBound)
        return plot.minY + CGFloat(fraction) * plot.height
    }

    static func price(atY y: CGFloat, domain: ClosedRange<Double>, plot: CGRect) -> Double? {
        guard plot.height > 0 else { return nil }
        let fraction = Double((y - plot.minY) / plot.height)
        let price = domain.upperBound - fraction * (domain.upperBound - domain.lowerBound)
        return price.isFinite && price > 0 ? price : nil
    }

    static func distance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    /// Extends the line through two screen-space points to the boundary of `rect`,
    /// so a trend line reads as an infinite line instead of a two-point segment.
    /// The two anchors stay the line's identity — this only widens what is drawn
    /// and hit-tested. A degenerate line, or one entirely outside `rect`, comes
    /// back unchanged so callers never lose the user's points.
    static func extendedLine(
        through first: CGPoint,
        and second: CGPoint,
        within rect: CGRect
    ) -> (start: CGPoint, end: CGPoint) {
        let dx = second.x - first.x
        let dy = second.y - first.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) > 0.001,
              rect.width > 0, rect.height > 0 else {
            return (first, second)
        }

        // Liang-Barsky: intersect the infinite line with the four half-planes of
        // the rect and keep the widest parameter interval that stays inside.
        var lower = -CGFloat.infinity
        var upper = CGFloat.infinity
        let edges: [(slope: CGFloat, offset: CGFloat)] = [
            (-dx, first.x - rect.minX),
            (dx, rect.maxX - first.x),
            (-dy, first.y - rect.minY),
            (dy, rect.maxY - first.y)
        ]
        for edge in edges {
            if abs(edge.slope) < 0.0001 {
                // Parallel to this edge: outside it means nothing is visible.
                if edge.offset < 0 { return (first, second) }
                continue
            }
            let ratio = edge.offset / edge.slope
            if edge.slope < 0 {
                lower = max(lower, ratio)
            } else {
                upper = min(upper, ratio)
            }
        }
        guard lower.isFinite, upper.isFinite, lower <= upper else { return (first, second) }

        let start = CGPoint(x: first.x + lower * dx, y: first.y + lower * dy)
        let end = CGPoint(x: first.x + upper * dx, y: first.y + upper * dy)
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else {
            return (first, second)
        }
        return (start, end)
    }

    static func pricePane(plot: CGRect, reservesVolume: Bool, volumeFraction: CGFloat) -> CGRect {
        let fraction = reservesVolume ? min(max(volumeFraction, 0), 0.8) : 0
        return CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height * (1 - fraction))
    }

    static func placePlanLabels(_ candidates: [PlanLabelCandidate], bounds: ClosedRange<CGFloat>, gap: CGFloat) -> [PlanLabelPlacement] {
        let sorted = candidates.sorted {
            if $0.anchorY != $1.anchorY { return $0.anchorY < $1.anchorY }
            return $0.group.id < $1.group.id
        }
        guard !sorted.isEmpty else { return [] }
        let inset = min(8, max(bounds.upperBound - bounds.lowerBound, 0) / 2)
        let low = bounds.lowerBound + inset
        let high = bounds.upperBound - inset
        var positions = sorted.map { min(max($0.anchorY, low), high) }
        if positions.count > 1 {
            for index in 1..<positions.count {
                positions[index] = max(positions[index], positions[index - 1] + gap)
            }
            if positions.last.map({ $0 > high }) == true {
                if CGFloat(positions.count - 1) * gap <= high - low {
                    positions[positions.count - 1] = high
                    for index in stride(from: positions.count - 2, through: 0, by: -1) {
                        positions[index] = min(positions[index], positions[index + 1] - gap)
                    }
                } else {
                    let compressedGap = (high - low) / CGFloat(positions.count - 1)
                    for index in positions.indices {
                        positions[index] = low + CGFloat(index) * compressedGap
                    }
                }
            }
        }
        return sorted.indices.map { index in
            let candidate = sorted[index]
            return PlanLabelPlacement(group: candidate.group, anchorY: min(max(candidate.anchorY, low), high),
                                      labelY: positions[index], isBeyondEdge: candidate.desiredY < bounds.lowerBound
                                        || candidate.desiredY > bounds.upperBound)
        }
    }
}

private struct DrawingProjection: Identifiable {
    var drawing: ChartDrawing
    var line: AnnotationSegment
    var start: CGPoint
    var end: CGPoint
    var handles: [CGPoint]
    var isPreview: Bool
    var id: UUID { drawing.id }
}

private struct DrawingTarget {
    var drawing: ChartDrawing
    var part: DrawingPart
}

private enum DrawingPart { case start, end, line }
private enum MeasurementHandle { case start, end }

private enum PointerInteraction {
    case tool(ChartAnnotationTool, origin: CGPoint)
    case moveDrawing(DrawingTarget, origin: CGPoint)
    case measureHandle(MeasurementHandle, origin: CGPoint)
    case pan(origin: CGPoint)
    case selection(UUID, origin: CGPoint)
    case ignore
}

private struct TemporaryMeasurement {
    var start: ChartAnchor
    var end: ChartAnchor

    mutating func update(_ handle: MeasurementHandle, to anchor: ChartAnchor) {
        switch handle {
        case .start: start = anchor
        case .end: end = anchor
        }
    }
}

private struct AnnotationSegment: Shape {
    var start: CGPoint
    var end: CGPoint

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
    }
}

struct PlanGroupKey: Hashable {
    var kind: TradePlan.Kind
    var price: Double
}

struct PlanGroup: Identifiable {
    var key: PlanGroupKey
    var plans: [TradePlan]
    var id: String { "\(key.kind.rawValue)-\(key.price.bitPattern)" }
}

struct PlanLabelCandidate {
    var group: PlanGroup
    var anchorY: CGFloat
    var desiredY: CGFloat
}

struct PlanLabelPlacement: Identifiable {
    var group: PlanGroup
    var anchorY: CGFloat
    var labelY: CGFloat
    var isBeyondEdge: Bool
    var id: String { group.id }
}

private extension View {
    func clippedTo(_ rect: CGRect) -> some View {
        mask(alignment: .topLeading) {
            Rectangle()
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}
