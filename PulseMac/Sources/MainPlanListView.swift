import SwiftUI
import PulseCore
import PulseUI

/// A sortable, filterable cross-symbol plan table for the main window.
struct MainPlanListView: View {
    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case waiting
        case done
        case dropped

        var id: String { rawValue }

        /// The `waiting` entry means "still to be executed", which is wider than
        /// the string table's "waiting to trigger": a plan whose price already
        /// arrived is still pending work. The label is worded here so the filter
        /// says what it does; the other three keep their existing translations.
        var title: String {
            switch self {
            case .all: PulseLocalization.localizedString("main.planList.filter.all")
            case .waiting: copy("待执行", "Pending")
            case .done: PulseLocalization.localizedString("main.planList.filter.done")
            case .dropped: PulseLocalization.localizedString("main.planList.filter.dropped")
            }
        }

        private func copy(_ chinese: String, _ english: String) -> String {
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
        }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case reached, symbol, target, distance, cost

        var id: String { rawValue }
        var titleKey: String { "main.planList.sort.\(rawValue)" }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var route: PopoverRoute
    /// Asks the host to show this symbol's summary beside the list instead of
    /// navigating away. When the host supplies it the list stays alive, with its
    /// search, filter, sort and scroll intact; when it does not (the routed
    /// `.planList` page renders this view too) the old push behaviour stands.
    var onInspect: ((SymbolID) -> Void)?
    @State private var query = ""
    /// The page opens on what still needs doing. A plan the user has already
    /// finished or dropped is a record, and the reason to visit this page is
    /// the open work; history stays reachable from the same control.
    @State private var statusFilter: StatusFilter = .waiting
    @State private var sortOrder: SortOrder = .reached
    @State private var reachedOnly = false
    @State private var executionEntry: TradePlanEntry?
    @State private var workflowEntry: TradePlanEntry?
    /// The editor is presented as a local sheet rather than through the window
    /// route. Routing it would replace this page and throw away the search,
    /// filter, sort and scroll position the user set up to find the plan.
    @State private var editorPresentation: PlanEditorPresentation?
    @State private var showsAlertSettings = false

    /// One editing session. `Identifiable` so it can drive `.sheet(item:)`,
    /// which keeps the identity tied to the plan being edited. Internal rather
    /// than private because the sheet host below is a separate type.
    struct PlanEditorPresentation: Identifiable {
        let symbol: SymbolID
        let planID: UUID?
        var id: String { "\(symbol.description)-\(planID?.uuidString ?? "new")" }
    }

    private var entries: [TradePlanEntry] { appState.watchlist.tradePlanEntries }

    private func currentPrice(_ symbol: SymbolID) -> Double? {
        guard let quote = appState.market.quote(for: symbol), TradingQuoteHealth.isCurrent(quote) else { return nil }
        return quote.price
    }

    private func isReached(_ entry: TradePlanEntry) -> Bool {
        entry.plan.status == .active
            && TradePlanOverview.isReached(entry, currentPrice: currentPrice)
    }

    private var filteredEntries: [TradePlanEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch statusFilter {
            case .all: break
            // 待执行 is not just "active": a plan the user already filled out
            // completely has nothing left to act on, so it belongs with the
            // history rather than in the default work list.
            case .waiting where !isPending(entry): return false
            case .done where entry.plan.status != .done: return false
            case .dropped where entry.plan.status != .cancelled: return false
            default: break
            }
            if reachedOnly && !isReached(entry) { return false }
            guard !needle.isEmpty else { return true }
            let name = appState.market.quote(for: entry.symbol)?.name
                ?? appState.displayName(for: entry.symbol)
            return entry.symbol.displayCode.localizedCaseInsensitiveContains(needle)
                || name.localizedCaseInsensitiveContains(needle)
                || (entry.plan.note ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    /// A plan still waiting on the user: it is live and it has quantity left.
    private func isPending(_ entry: TradePlanEntry) -> Bool {
        entry.plan.status == .active && entry.remainingQuantity > 0
    }

    private var orderedEntries: [TradePlanEntry] {
        guard sortOrder != .reached else {
            let ordered = TradePlanOverview.ordered(filteredEntries, currentPrice: currentPrice)
            return ordered.filter { currentPrice($0.symbol) != nil }
                + ordered.filter { currentPrice($0.symbol) == nil }
        }
        return filteredEntries.sorted { lhs, rhs in
            let leftPrice = currentPrice(lhs.symbol)
            let rightPrice = currentPrice(rhs.symbol)
            if (leftPrice == nil) != (rightPrice == nil) { return leftPrice != nil }

            switch sortOrder {
            case .reached: break
            case .symbol:
                let leftName = appState.displayName(for: lhs.symbol)
                let rightName = appState.displayName(for: rhs.symbol)
                let nameOrder = leftName.localizedStandardCompare(rightName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                let codeOrder = lhs.symbol.displayCode.localizedStandardCompare(rhs.symbol.displayCode)
                if codeOrder != .orderedSame { return codeOrder == .orderedAscending }
            case .target:
                if lhs.plan.price != rhs.plan.price { return lhs.plan.price < rhs.plan.price }
            case .distance:
                let leftGap = leftPrice.map { lhs.plan.gapPercent(from: $0) } ?? .infinity
                let rightGap = rightPrice.map { rhs.plan.gapPercent(from: $0) } ?? .infinity
                if leftGap != rightGap { return leftGap < rightGap }
            case .cost:
                // Biggest money first: the whole reason to look at this column
                // is to find the plan whose price difference costs the most.
                // Rows with no size or no quote have no amount to rank on and
                // sink to the bottom.
                let leftCost = PulseUI.PlanCostText.summary(for: lhs.remainingPlan, current: leftPrice)?.amount ?? -Double.infinity
                let rightCost = PulseUI.PlanCostText.summary(for: rhs.remainingPlan, current: rightPrice)?.amount ?? -Double.infinity
                if leftCost != rightCost { return leftCost > rightCost }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var overallSummary: TradePlanOverview.Summary {
        TradePlanOverview.summary(entries, currentPrice: currentPrice)
    }

    private var filteredReachedCount: Int { filteredEntries.filter(isReached).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            alertSummaryBar
            filters
            if entries.isEmpty {
                emptyState("main.planList.empty")
            } else if orderedEntries.isEmpty {
                emptyState("main.planList.noMatches")
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $executionEntry) { entry in
            PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                               onClose: { executionEntry = nil })
        }
        .sheet(item: $workflowEntry) { entry in
            PlanWorkflowDetailView(symbol: entry.symbol, planID: entry.id,
                                   account: appState.watchlist.activeBrokerageAccountID)
                .frame(width: 650, height: 600)
        }
        .sheet(item: $editorPresentation) { presentation in
            PlanEditorSheet(presentation: presentation) { editorPresentation = nil }
        }
    }

    /// The reminder controls folded into one line. The trigger rules and their
    /// caveats are help text, not something to read on every visit, so they move
    /// into the popover with the same `PlanAlertSettingsView` the page used to
    /// show inline. No alert field changes meaning here.
    private var alertSummaryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: appState.planAlerts.enabled ? "bell.badge" : "bell.slash")
                .font(.system(size: 11))
                .foregroundStyle(appState.planAlerts.enabled ? Color.accentColor : Color.secondary)
            Text(copy(
                "到价提醒 \(onOff(appState.planAlerts.enabled)) · 板块提醒 \(onOff(appState.planAlerts.sectorEnabled))",
                "Price alerts \(onOff(appState.planAlerts.enabled)) · Sector alerts \(onOff(appState.planAlerts.sectorEnabled))"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Spacer(minLength: 4)
            Button(copy("设置", "Settings")) {
                showsAlertSettings = true
            }
            .controlSize(.small)
            .popover(isPresented: $showsAlertSettings, arrowEdge: .bottom) {
                PlanAlertSettingsView()
                    .padding(14)
                    .frame(width: 380)
            }
            if let error = appState.planAlerts.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .frame(height: 32)
        .padding(.horizontal, 18)
    }

    private func onOff(_ enabled: Bool) -> String {
        copy(enabled ? "开" : "关", enabled ? "on" : "off")
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(PulseLocalization.localizedString("plan.list.title"))
                .font(.system(size: 17, weight: .semibold))
            HStack(spacing: 12) {
                Text(PulseLocalization.localizedString(
                    "main.planList.summary.all",
                    entries.count,
                    overallSummary.live,
                    overallSummary.reached
                ))
                Text(PulseLocalization.localizedString(
                    "main.planList.summary.filtered",
                    filteredEntries.count,
                    filteredReachedCount
                ))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(PulseLocalization.localizedString("main.planList.search"), text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(PulseLocalization.localizedString("main.planList.search"))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(PulseLocalization.localizedString("main.search.clear"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Picker(PulseLocalization.localizedString("main.planList.filter.status"), selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Toggle(PulseLocalization.localizedString("main.planList.filter.reached"), isOn: $reachedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                Picker(PulseLocalization.localizedString("main.planList.sort.label"), selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(PulseLocalization.localizedString(order.titleKey)).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var table: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                tableHeader
                Rectangle().fill(.separator).frame(height: 0.5)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(orderedEntries) { entry in
                            tableRow(entry)
                            Rectangle().fill(.separator.opacity(0.45)).frame(height: 0.5)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
            .frame(minWidth: Self.tableMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
    }

    /// Column spacing is shared by the header and the rows, and the widths below
    /// are the same numbers in both. That is the whole reason the two use one
    /// constant: a header that drifts from its rows mislabels every column.
    ///
    /// The quantity and status columns were widened to stop numbers and status
    /// words colliding, and the spacing was added between all nine columns. The
    /// symbol and note columns gave up the difference so the table's minimum
    /// width does not grow and narrow windows do not start scrolling sideways.
    private static let columnSpacing: CGFloat = 12
    private static let symbolColumnWidth: CGFloat = 177
    /// The name/code label plus the 3pt gap and the 48pt action cluster fill the
    /// symbol column exactly, so the actions cannot be pushed out of it.
    private static let symbolLabelWidth: CGFloat = 126
    private static let noteColumnWidth: CGFloat = 96
    private static let quantityColumnWidth: CGFloat = 104
    private static let statusColumnWidth: CGFloat = 130
    /// The row's own minimum, so the horizontal scroll view and the header
    /// agree on how wide the table really is.
    private static let tableMinWidth: CGFloat = 1_115

    private var tableHeader: some View {
        HStack(spacing: Self.columnSpacing) {
            columnHeader("main.planList.column.symbol", width: Self.symbolColumnWidth, alignment: .leading)
            columnHeader("main.planList.column.kind", width: 66, alignment: .leading)
            columnHeader("main.planList.column.target", width: 108, alignment: .trailing)
            columnHeader("main.planList.column.current", width: 108, alignment: .trailing)
            columnHeader("main.planList.column.distance", width: 100, alignment: .trailing)
            columnHeader("main.planList.column.cost", width: 130, alignment: .trailing)
            columnHeader("main.planList.column.quantity", width: Self.quantityColumnWidth, alignment: .trailing)
            columnHeader("main.planList.column.status", width: Self.statusColumnWidth, alignment: .leading)
            columnHeader("main.planList.column.note", width: Self.noteColumnWidth, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func tableRow(_ entry: TradePlanEntry) -> some View {
        let current = currentPrice(entry.symbol)
        let quoteName = appState.market.quote(for: entry.symbol)?.name
        let name = quoteName ?? appState.displayName(for: entry.symbol)
        let distance = current.map { entry.plan.gapPercent(from: $0) }

        return HStack(spacing: Self.columnSpacing) {
            HStack(spacing: 3) {
                Button {
                    if let onInspect {
                        onInspect(entry.symbol)
                    } else {
                        route = .detail(entry.symbol)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(entry.symbol.displayCode)
                            Text(entry.symbol.currencyCode)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    }
                    .frame(width: Self.symbolLabelWidth, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                rowActions(entry)
            }
            .frame(width: Self.symbolColumnWidth, alignment: .leading)

            directionCell(entry.plan.kind)
            textCell(PriceFormatter.price(entry.plan.price, market: entry.symbol.market), width: 108, alignment: .trailing, monospaced: true)
            textCell(current.map { PriceFormatter.price($0, market: entry.symbol.market) } ?? "—", width: 108, alignment: .trailing, monospaced: true)
            textCell(distance.map(PriceFormatter.percentMagnitude) ?? "—", width: 100, alignment: .trailing, monospaced: true)
            textCell(costText(entry, current: current), width: 130, alignment: .trailing,
                     secondary: true, shrink: true)
            quantityCell(entry)
            statusCell(entry, reached: isReached(entry), hasQuote: current != nil)
            textCell(entry.plan.note?.isEmpty == false ? entry.plan.note! : "—", width: Self.noteColumnWidth, alignment: .leading, secondary: true)
        }
        .font(.system(size: 10.5))
        .padding(.vertical, 7)
    }

    /// How much is still open, named so it cannot be read as the planned size.
    /// Fill progress is shown once in the adjacent status column.
    private func quantityCell(_ entry: TradePlanEntry) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(PriceFormatter.quantity(isPending(entry)
                ? entry.remainingQuantity
                : entry.plan.quantity))
                .lineLimit(1)
        }
        .monospacedDigit()
        .frame(width: Self.quantityColumnWidth, alignment: .trailing)
        .help(copy(
            "待执行 \(PriceFormatter.quantity(entry.remainingQuantity)) · 计划 \(PriceFormatter.quantity(entry.plan.quantity)) · 已成 \(PriceFormatter.quantity(entry.filledQuantity))",
            "Open \(PriceFormatter.quantity(entry.remainingQuantity)) · planned \(PriceFormatter.quantity(entry.plan.quantity)) · filled \(PriceFormatter.quantity(entry.filledQuantity))"
        ))
    }

    /// The money the quote is worth against the plan's own price. The label
    /// already says which way it cuts, so the cell carries no sign of its own;
    /// the em dash stands in wherever there is nothing to compare.
    private func costText(_ entry: TradePlanEntry, current: Double?) -> String {
        PlanCostText.string(for: entry.remainingPlan, current: current, symbol: entry.symbol) ?? "—"
    }

    private func columnHeader(_ key: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(PulseLocalization.localizedString(key))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func directionCell(_ kind: TradePlan.Kind) -> some View {
        let color = PlanSideStyle.color(for: kind)
        let backgroundOpacity = colorScheme == .dark ? 0.22 : 0.10
        let borderOpacity = colorScheme == .dark ? 0.46 : 0.30
        return Text(PulseLocalization.localizedString(kind == .buy ? "plan.kind.buy" : "plan.kind.sell"))
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(backgroundOpacity), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(borderOpacity), lineWidth: 0.75))
            .frame(width: 66, alignment: .leading)
    }

    private func textCell(
        _ text: String,
        width: CGFloat,
        alignment: Alignment,
        monospaced: Bool = false,
        secondary: Bool = false,
        shrink: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .regular, design: monospaced ? .monospaced : .default))
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            // Only the cost cell asks for this: naming the action at the live
            // quote makes it the one cell that can outgrow its column, and the
            // amount matters more than the point size it is set in.
            .minimumScaleFactor(shrink ? 0.8 : 1)
            .frame(width: width, alignment: alignment)
    }

    /// Three independent facts, deliberately not collapsed into one word:
    /// whether the user still means to act on the plan, how much of it has been
    /// filled, and whether the price condition holds right now. A price that
    /// arrived is not a completed trade, and ending a plan by hand without
    /// filling it all is not called complete either.
    ///
    /// The price hint sits in a trailing sub-row rather than overlaid on the
    /// intent, so a long intent such as "已结束，未全部成交" can never be
    /// overwritten by the hint.
    private func statusCell(_ entry: TradePlanEntry, reached: Bool, hasQuote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(planIntentTitle(entry))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            HStack(spacing: 4) {
                if entry.filledQuantity > 0 {
                    Text(copy(
                        "已成 \(PriceFormatter.quantity(entry.filledQuantity))/待执行 \(PriceFormatter.quantity(entry.remainingQuantity))",
                        "Filled \(PriceFormatter.quantity(entry.filledQuantity))/open \(PriceFormatter.quantity(entry.remainingQuantity))"
                    ))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if reached {
                    Text(PulseLocalization.localizedString("plan.reached"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PlanSideStyle.color(for: entry.plan.kind))
                        .lineLimit(1)
                } else if entry.plan.status == .active && !hasQuote {
                    Text(copy("无有效报价", "No live quote"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .font(.system(size: 9.5, weight: reached ? .medium : .regular))
        .frame(width: Self.statusColumnWidth, alignment: .leading)
    }

    private func rowActions(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 2) {
            Button {
                editorPresentation = PlanEditorPresentation(symbol: entry.symbol, planID: entry.plan.id)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(PulseLocalization.localizedString("main.planList.action.edit"))

            Menu {
                if entry.plan.status == .active, entry.remainingQuantity > 0 {
                    Button("记录已成交") { executionEntry = entry }
                }
                Button("逻辑与修改记录") { workflowEntry = entry }
                Divider()
                if entry.plan.status == .active {
                    Button("暂缓到价提醒 15 分钟") { appState.planAlerts.snooze(entry.plan) }
                    Divider()
                }
                Button(PulseLocalization.localizedString("main.planList.action.markWaiting")) {
                    restate(entry, as: .active)
                }
                .disabled(entry.plan.status == .active)
                Button(PulseLocalization.localizedString("main.planList.action.markDone")) {
                    restate(entry, as: .done)
                }
                .disabled(entry.plan.status == .done)
                Button(PulseLocalization.localizedString("main.planList.action.markDropped")) {
                    restate(entry, as: .cancelled)
                }
                .disabled(entry.plan.status == .cancelled)
                Divider()
                Button(PulseLocalization.localizedString("main.planList.action.delete"), role: .destructive) {
                    appState.watchlist.deleteTradePlan(entry.plan.id, for: entry.symbol)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help(PulseLocalization.localizedString("main.planList.action.changeStatus"))
        }
        .frame(width: 48, alignment: .leading)
    }

    private func restate(_ entry: TradePlanEntry, as status: TradePlan.Status) {
        var updated = entry.plan
        updated.status = status
        appState.watchlist.setTradePlan(updated, for: entry.symbol)
    }

    private func emptyState(_ key: String) -> some View {
        Text(PulseLocalization.localizedString(key))
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 20)
    }
}

/// Hosts `PlanEditorView` inside a sheet so editing a plan never tears down the
/// list behind it.
///
/// `PlanEditorView` reports "done" by writing its `route` back to the value it
/// was given as `returnRoute`, so the sheet owns a private route and closes when
/// that value comes back. This is the same hosting pattern the position-pool
/// editor already uses, reused rather than re-invented; the editor itself is
/// unchanged, and the window-level `.plan` route still works for every other
/// caller.
private struct PlanEditorSheet: View {
    let presentation: MainPlanListView.PlanEditorPresentation
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    @State private var route: PopoverRoute = .planList

    init(presentation: MainPlanListView.PlanEditorPresentation, onClose: @escaping () -> Void) {
        self.presentation = presentation
        self.onClose = onClose
        _route = State(initialValue: .plan(presentation.symbol, presentation.planID, .planList))
    }

    var body: some View {
        PlanEditorView(
            symbol: presentation.symbol,
            planID: presentation.planID,
            returnRoute: .planList,
            route: $route,
            account: appState.watchlist.activeBrokerageAccountID
        )
        .frame(width: 520, height: 460)
        .onChange(of: route) { _, value in
            if value == .planList { onClose() }
        }
    }
}
