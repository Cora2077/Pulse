import AppKit
import Charts
import SwiftUI
import PulseCore
import PulseUI

private struct HoldingsScrollOffsetReader: NSViewRepresentable {
    let onChange: (CGPoint) -> Void

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.onChange = onChange
        DispatchQueue.main.async { view.attach() }
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.detach() }

    final class Reader: NSView {
        var onChange: ((CGPoint) -> Void)?
        private weak var clipView: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let clip = enclosingScrollView?.contentView, clip !== clipView else { return }
            detach()
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip
            )
            boundsChanged()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clipView = nil
        }

        @objc private func boundsChanged(_ notification: Notification? = nil) {
            guard let clipView else { return }
            let offset = CGPoint(x: -clipView.bounds.origin.x, y: -clipView.bounds.origin.y)
            DispatchQueue.main.async { [weak self] in self?.onChange?(offset) }
        }
    }
}

struct MainHoldingsView: View {
    private struct ActiveColumnResize {
        let field: SortField
        let initialWidth: CGFloat
    }

    private enum PositionFilter: String, CaseIterable {
        case current
        case closed

        var titleKey: String {
            switch self {
            case .current: "main.holdings.filter.current"
            case .closed: "main.holdings.filter.closed"
            }
        }
    }

    private enum SortField: String, CaseIterable {
        case name
        case quantity
        case cost
        case holdingPnL
        case totalPnL
        case price
        case todayPnL
        case realizedPnL
        case marketValue
        case fees

        var titleKey: String {
            switch self {
            case .name: "main.holdings.column.instrument"
            case .quantity: "main.holdings.column.quantity"
            case .cost: "main.holdings.column.cost"
            case .holdingPnL: "main.holdings.column.holdingPnL"
            case .totalPnL: "main.holdings.column.totalPnL"
            case .price: "main.holdings.column.price"
            case .todayPnL: "main.holdings.column.todayPnL"
            case .realizedPnL: "main.holdings.column.realizedPnL"
            case .marketValue: "main.holdings.column.marketValue"
            case .fees: "main.holdings.column.fees"
            }
        }

        func numericValue(in values: Values) -> Double? {
            let value: Double?
            switch self {
            case .name: return nil
            case .quantity: value = values.quantity
            case .cost: value = values.cost
            case .holdingPnL: value = values.holdingPnL
            case .totalPnL: value = values.totalPnL
            case .price: value = values.price
            case .todayPnL: value = values.todayPnL
            case .realizedPnL: value = values.realizedPnL
            case .marketValue: value = values.marketValue
            case .fees: value = values.fees
            }
            guard let value, value.isFinite else { return nil }
            return value
        }
    }

    private enum AllocationScenario: String, CaseIterable {
        case current
        case afterBuy
    }

    private struct Values {
        let quantity: Double
        let cost: Double?
        let price: Double?
        let marketValue: Double?
        let todayPnL: Double?
        let holdingPnL: Double?
        let realizedPnL: Double
        let totalPnL: Double?
        let fees: Double?
    }

    private struct DisplayRow: Identifiable {
        let item: WatchItem
        let values: Values
        var id: SymbolID { item.symbol }
    }

    private struct AllocationPlanChoice: Identifiable {
        let item: WatchItem
        let plan: TradePlan
        var id: UUID { plan.id }
    }

    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    @State private var query = ""
    @State private var filter: PositionFilter = .current
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    @State private var expandedSymbol: SymbolID?
    @State private var allocationExpanded = true
    @State private var selectedAllocationPlanID: UUID?
    @State private var selectedAllocationCurrencyCode: String?
    @State private var allocationScenario: AllocationScenario = .current
    @State private var hoveredChartSymbol: SymbolID?
    @State private var hoveredRankingSymbol: SymbolID?
    @State private var hoveredTableSymbol: SymbolID?
    @State private var selectedAllocationAngle: Double?
    @State private var tableScrollOffset = CGPoint.zero
    @State private var columnWidths = Self.loadColumnWidths()
    @State private var activeColumnResize: ActiveColumnResize?
    @AppStorage("holdings.hiddenColumns") private var hiddenColumnRawValues = ""

    private struct Column: Identifiable {
        let field: SortField
        let defaultWidth: CGFloat
        let minWidth: CGFloat
        let maxWidth: CGFloat
        var id: SortField { field }
    }

    private static let columns: [Column] = [
        Column(field: .name, defaultWidth: 160, minWidth: 140, maxWidth: 320),
        Column(field: .quantity, defaultWidth: 84, minWidth: 84, maxWidth: 180),
        Column(field: .cost, defaultWidth: 84, minWidth: 66, maxWidth: 220),
        Column(field: .holdingPnL, defaultWidth: 100, minWidth: 72, maxWidth: 220),
        Column(field: .totalPnL, defaultWidth: 100, minWidth: 72, maxWidth: 220),
        Column(field: .price, defaultWidth: 80, minWidth: 72, maxWidth: 240),
        Column(field: .todayPnL, defaultWidth: 90, minWidth: 72, maxWidth: 220),
        Column(field: .realizedPnL, defaultWidth: 95, minWidth: 72, maxWidth: 220),
        Column(field: .marketValue, defaultWidth: 105, minWidth: 72, maxWidth: 220),
        Column(field: .fees, defaultWidth: 70, minWidth: 60, maxWidth: 190)
    ]

    private var filteredItems: [WatchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = accountItems.filter { item in
            guard item.supportsPosition, item.hasPositionHistory else { return false }
            let isOpen = item.positionQuantity != 0
            guard filter == .current ? isOpen : !isOpen else { return false }
            guard !needle.isEmpty else { return true }
            return item.resolvedDisplayName.localizedCaseInsensitiveContains(needle)
                || item.symbol.displayCode.localizedCaseInsensitiveContains(needle)
        }
        return filtered
    }

    private var displayRows: [DisplayRow] {
        let rows = filteredItems.map { DisplayRow(item: $0, values: value(for: $0)) }
        return rows.sorted(by: isOrdered)
    }

    var body: some View {
        let rows = displayRows
        VStack(alignment: .leading, spacing: 0) {
            header(itemCount: rows.count)
            if accountItems.contains(where: { $0.supportsPosition && $0.positionQuantity != 0 })
                || !allocationPlans.isEmpty {
                allocationCard
            }
            if rows.isEmpty {
                emptyState
            } else {
                holdingsTable(rows)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func holdingsTable(_ rows: [DisplayRow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("持仓明细")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 12)
                if visibleColumns.contains(where: { $0.field == .price }),
                   let summary = Self.quoteSummaryText(quotes: rows.compactMap { row in
                       guard let price = row.values.price, price.isFinite,
                             let quote = appState.market.quote(for: row.item.symbol),
                             quote.timestamp.timeIntervalSince1970.isFinite else { return nil }
                       return quote
                   }) {
                    Text(summary)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(summary) · 本机时区：\(TimeZone.current.identifier)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            Divider().opacity(0.5)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            holdingRow(row)
                            if expandedSymbol == row.item.symbol {
                                costHistory(row.item)
                            }
                            Divider().opacity(0.35).padding(.horizontal, 16)
                        }
                    }
                }
                .frame(minWidth: tableWidth, alignment: .leading)
                .padding(.bottom, 8)
                .background {
                    HoldingsScrollOffsetReader { offset in
                        if tableScrollOffset != offset { tableScrollOffset = offset }
                    }
                    .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.automatic)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var visibleColumns: [Column] {
        Self.columns.filter { $0.field == .name || !hiddenColumns.contains($0.field) }
    }

    private var tableWidth: CGFloat { visibleColumns.reduce(32) { $0 + columnWidth($1.field) } }

    private var hiddenColumns: Set<SortField> {
        Set(hiddenColumnRawValues.split(separator: ",").compactMap { SortField(rawValue: String($0)) })
    }

    private func columnWidth(_ field: SortField) -> CGFloat {
        guard let column = Self.columns.first(where: { $0.field == field }) else { return 0 }
        let value = columnWidths[field] ?? column.defaultWidth
        return min(max(value.isFinite ? value : column.defaultWidth, column.minWidth), column.maxWidth)
    }

    private static func loadColumnWidths() -> [SortField: CGFloat] {
        let stored = MainWindow.preferenceDefaults.dictionary(forKey: "holdings.columnWidths") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: columns.map { column in
            let value = stored[column.field.rawValue].map { CGFloat($0) } ?? column.defaultWidth
            return (column.field, min(max(value.isFinite ? value : column.defaultWidth, column.minWidth), column.maxWidth))
        })
    }

    static func quoteSummaryText(quotes: [Quote], timeZone: TimeZone = .current) -> String? {
        guard !quotes.isEmpty, quotes.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dates = quotes.map(\.timestamp).sorted()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let first = dates[0]
        let last = dates[dates.count - 1]
        let timeText: String
        if formatter.string(from: first) == formatter.string(from: last) {
            timeText = formatter.string(from: first)
        } else if calendar.isDate(first, inSameDayAs: last) {
            timeText = "\(formatter.string(from: first))–\(formatter.string(from: last).suffix(5))"
        } else {
            timeText = "\(formatter.string(from: first))–\(formatter.string(from: last))"
        }
        let sources = Set(quotes.map { $0.sourceName ?? $0.sourceID ?? "来源未知" }).sorted()
        return "行情时刻 \(timeText)（本机时间） · \(sources.joined(separator: "、"))"
    }

    private func setColumnWidth(_ field: SortField, to proposedWidth: CGFloat, persist: Bool) {
        guard let column = Self.columns.first(where: { $0.field == field }) else { return }
        let width = min(max(proposedWidth.isFinite ? proposedWidth : column.defaultWidth, column.minWidth), column.maxWidth)
        columnWidths[field] = width
        if persist {
            MainWindow.preferenceDefaults.set(
                Dictionary(uniqueKeysWithValues: Self.columns.map { ($0.field.rawValue, Double(columnWidth($0.field))) }),
                forKey: "holdings.columnWidths"
            )
        }
    }

    private func toggleColumn(_ field: SortField, visible: Bool) {
        var hidden = hiddenColumns
        if visible { hidden.remove(field) } else { hidden.insert(field) }
        hidden.remove(.name)
        hiddenColumnRawValues = hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func columnVisibilityBinding(_ field: SortField) -> Binding<Bool> {
        Binding(get: { !hiddenColumns.contains(field) }, set: { toggleColumn(field, visible: $0) })
    }

    private func resetTableLayout() {
        columnWidths = Dictionary(uniqueKeysWithValues: Self.columns.map { ($0.field, $0.defaultWidth) })
        hiddenColumnRawValues = ""
        MainWindow.preferenceDefaults.removeObject(forKey: "holdings.columnWidths")
    }

    private func header(itemCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(PulseLocalization.localizedString("main.holdings.title"))
                    .font(.system(size: 23, weight: .semibold))
                if appState.watchlist.brokerageAccountsEnabled {
                    holdingsAccountMenu
                }
                Text(PulseLocalization.localizedString("main.holdings.subtitle", itemCount))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                Spacer(minLength: 12)
                searchField
            }

            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(PositionFilter.allCases, id: \.self) { option in
                        Text(PulseLocalization.localizedString(option.titleKey)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Picker(PulseLocalization.localizedString("main.holdings.costBasis.title"), selection: costBasisSelection) {
                    ForEach(PositionCostBasis.allCases, id: \.self) { basis in
                        Text(PulseLocalization.localizedString(basis.labelKey)).tag(basis)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(PulseLocalization.localizedString("main.holdings.costBasis.title"))
                .help(PulseLocalization.localizedString("position.costBasisHelp"))

                Spacer(minLength: 8)

                Menu {
                    Picker(PulseLocalization.localizedString("main.holdings.sort.title"), selection: sortFieldSelection) {
                        ForEach(SortField.allCases, id: \.self) { field in
                            Text(PulseLocalization.localizedString(field.titleKey)).tag(field)
                        }
                    }
                    Button(PulseLocalization.localizedString(sortAscending
                        ? "main.holdings.sort.descending" : "main.holdings.sort.ascending")) {
                        sortAscending.toggle()
                    }
                    Divider()
                    Button(PulseLocalization.localizedString("main.holdings.sort.reset")) {
                        sortField = .name
                        sortAscending = true
                    }
                    .disabled(sortField == .name && sortAscending)
                } label: {
                    Label(PulseLocalization.localizedString(sortField.titleKey),
                          systemImage: sortAscending ? "arrow.up" : "arrow.down")
                }
                .help(PulseLocalization.localizedString("main.holdings.sort.title"))

                Menu {
                    ForEach(Self.columns.filter { $0.field != .name }) { column in
                        Toggle(PulseLocalization.localizedString(column.field.titleKey), isOn: columnVisibilityBinding(column.field))
                    }
                    Divider()
                    Button("重置列布局", action: resetTableLayout)
                } label: {
                    Label("列", systemImage: "tablecells")
                }
                .help("显示或隐藏列，并重置列宽")
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12).padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(PulseLocalization.localizedString("main.holdings.search"), text: $query)
                .textFieldStyle(.plain)
                .frame(maxWidth: 180)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var allocationPlans: [AllocationPlanChoice] {
        allocationItems.flatMap { item in
            item.plans.filter { $0.status == .active && $0.kind == .buy }
                .compactMap { plan in
                    let entry = TradePlanEntry(symbol: item.symbol, plan: plan, transactions: item.transactions)
                    return entry.remainingQuantity > 0 ? AllocationPlanChoice(item: item, plan: entry.remainingPlan) : nil
                }
        }
    }

    private var allocationItems: [WatchItem] {
        accountItems
    }

    /// Both the distribution and detail rows read the same selected book.
    /// A sync snapshot's top-level items are the legacy unassigned book, not
    /// the current account, so it must not serve as a holdings-page source.
    private var accountItems: [WatchItem] {
        let portfolio = appState.watchlist.brokeragePortfolio(for: appState.watchlist.activeBrokerageAccountID)
        return portfolio.items + portfolio.retainedHistoryItems
    }

    private var holdingsAccountMenu: some View {
        let account = appState.watchlist.activeBrokerageAccountID
        return Menu {
            ForEach(BrokerageAccountID.allCases) { choice in
                Button {
                    _ = appState.selectBrokerageAccount(choice)
                } label: {
                    if choice == account {
                        Label(AccountIdentity.title(choice), systemImage: "checkmark")
                    } else {
                        Text(AccountIdentity.title(choice))
                    }
                }
            }
        } label: {
            Label(AccountIdentity.title(account), systemImage: AccountIdentity.symbolName(account))
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(PulseLocalization.localizedString("account.menu.accessibility", AccountIdentity.title(account)))
    }

    private var selectedAllocationPlan: AllocationPlanChoice? {
        allocationPlans.first { $0.id == selectedAllocationPlanID }
    }

    private var hoveredAllocationSymbol: SymbolID? {
        hoveredTableSymbol ?? hoveredRankingSymbol ?? hoveredChartSymbol
    }

    private var allocationPositions: [PortfolioAllocation.Position] {
        allocationItems.map { item in
            let quote = appState.market.quote(for: item.symbol)
            return PortfolioAllocation.Position(
                symbol: item.symbol,
                name: item.resolvedDisplayName,
                quantity: item.positionQuantity,
                price: quote?.price,
                currencyCode: quote?.currencyCode ?? item.symbol.currencyCode,
                supportsPosition: item.supportsPosition
            )
        }
    }

    private var allocationPlannedBuy: PortfolioAllocation.PlannedBuy? {
        selectedAllocationPlan.map {
            PortfolioAllocation.PlannedBuy(symbol: $0.item.symbol, quantity: $0.plan.quantity)
        }
    }

    private var allocationCurrentResult: PortfolioAllocation.Result {
        PortfolioAllocation.calculate(positions: allocationPositions, plannedBuy: allocationPlannedBuy)
    }

    private var allocationPreviewResult: PortfolioAllocation.Result? {
        guard let allocationPlannedBuy else { return nil }
        return PortfolioAllocation.previewAfterBuy(positions: allocationPositions, plannedBuy: allocationPlannedBuy)
    }

    private var allocationDisplayedResult: PortfolioAllocation.Result? {
        allocationScenario == .current ? allocationCurrentResult : allocationPreviewResult
    }

    private var allocationCurrencyCodes: [String] {
        var codes = Set(allocationCurrentResult.currencies.map(\.code))
        codes.formUnion(allocationPreviewResult?.currencies.map(\.code) ?? [])
        if let selectedAllocationCurrencyCode, !selectedAllocationCurrencyCode.isEmpty {
            codes.insert(selectedAllocationCurrencyCode)
        }
        if let plan = selectedAllocationPlan {
            let code = (appState.market.quote(for: plan.item.symbol)?.currencyCode ?? plan.item.symbol.currencyCode)
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !code.isEmpty { codes.insert(code) }
        }
        return codes.sorted()
    }

    private var selectedAllocationCurrencyCodeResolved: String? {
        if let selectedAllocationCurrencyCode, allocationCurrencyCodes.contains(selectedAllocationCurrencyCode) {
            return selectedAllocationCurrencyCode
        }
        return allocationCurrencyCodes.first
    }

    private var allocationCard: some View {
        let current = allocationCurrentResult
        let result = allocationDisplayedResult
        let displayed = result ?? current
        let currencyCode = selectedAllocationCurrencyCodeResolved
        return DisclosureGroup(isExpanded: $allocationExpanded) {
            let content = VStack(alignment: .leading, spacing: 9) {
                if selectedAllocationPlan != nil || allocationCurrencyCodes.count > 1 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { allocationScenarioPicker; allocationCurrencyPicker }
                        VStack(alignment: .leading, spacing: 6) { allocationScenarioPicker; allocationCurrencyPicker }
                    }
                }

                if !allocationCurrencyCodes.isEmpty, let currencyCode {
                    if let currency = result?.currencies.first(where: { $0.code == currencyCode }) {
                        allocationDistribution(currency)
                    } else if allocationScenario == .afterBuy, result != nil,
                              result?.excludedUnrepresentableCurrencyCodes.contains(currencyCode) == true {
                        Text("计划后 \(currencyCode) 总敞口超出可表示范围")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else if allocationScenario == .afterBuy, result != nil,
                              allocationCurrentResult.currencies.contains(where: { $0.code == currencyCode }) {
                        Text("计划后 \(currencyCode) 无剩余持仓，总敞口为 0")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if allocationScenario == .afterBuy, result == nil {
                        Text("所选计划缺少有效现价或币种，无法预览")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else {
                        Text("此币种当前没有可计入的持仓")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if allocationScenario == .afterBuy {
                        Text("计划情景按当前行情现价估算。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("没有可用的持仓报价")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                if displayed.excludedMissingQuoteCount > 0 {
                    Text("\(displayed.excludedMissingQuoteCount) 个持仓因缺少有效报价或币种未计入；各币种分别统计，不跨币种相加")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                }
                if !displayed.excludedUnrepresentableCurrencyCodes.isEmpty {
                    Text("币种总敞口超出可表示范围，已跳过：\(displayed.excludedUnrepresentableCurrencyCodes.joined(separator: ", "))")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                }
                if !allocationPlans.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text("计划买入").font(.system(size: 11, weight: .medium))
                            allocationPlanPicker.frame(width: 220)
                            allocationPlanSummary(current, preview: allocationPreviewResult)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text("计划买入").font(.system(size: 11, weight: .medium))
                                allocationPlanPicker.frame(width: 220)
                            }
                            allocationPlanSummary(current, preview: allocationPreviewResult)
                        }
                    }
                }
                Text("不含现金 · 各币种分别统计")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("按币种分别统计持仓绝对市值，不含现金；计划仅作现价估算。")
            }

            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical) { content }
                    .scrollIndicators(.never)
            }
            .frame(maxHeight: 310, alignment: .topLeading)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 11, weight: .medium))
                Text("持仓配置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if displayed.excludedMissingQuoteCount > 0 {
                    Text("报价缺失 \(displayed.excludedMissingQuoteCount)")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: allocationCurrencyCodes) { _, codes in
            if !(selectedAllocationCurrencyCode.map { codes.contains($0) } ?? false) {
                selectedAllocationCurrencyCode = codes.first
            }
        }
        .onChange(of: selectedAllocationPlanID) { _, _ in
            clearAllocationHover()
            if let plan = selectedAllocationPlan {
                selectedAllocationCurrencyCode = (appState.market.quote(for: plan.item.symbol)?.currencyCode
                    ?? plan.item.symbol.currencyCode).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            } else {
                allocationScenario = .current
            }
        }
        .onChange(of: allocationScenario) { _, _ in clearAllocationHover() }
        .onChange(of: selectedAllocationCurrencyCode) { _, _ in clearAllocationHover() }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func allocationDistribution(_ currency: PortfolioAllocation.Currency) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 12) {
                    allocationDonut(currency)
                    allocationMetrics(currency)
                }
                .frame(width: 286, alignment: .leading)
                allocationHoldings(currency)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    allocationDonut(currency)
                    allocationMetrics(currency)
                }
                allocationHoldings(currency)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func allocationMetrics(_ currency: PortfolioAllocation.Currency) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("总敞口").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(PriceFormatter.money(currency.totalExposure, currencyCode: currency.code))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .help(PriceFormatter.money(currency.totalExposure, currencyCode: currency.code))
                    Text(currency.code).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                allocationMetric("最大", percentText(currency.holdings.first?.percent ?? 0))
                allocationMetric("前三", percentText(currency.topThreeConcentration))
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    private func allocationMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
    }

    private func clearAllocationHover() {
        hoveredChartSymbol = nil
        hoveredRankingSymbol = nil
        hoveredTableSymbol = nil
        selectedAllocationAngle = nil
    }

    private func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func signedPercentText(_ value: Double) -> String {
        String(format: "%+.1f 个百分点", value)
    }

    private var allocationCurrencySelection: Binding<String> {
        Binding(
            get: { selectedAllocationCurrencyCodeResolved ?? "" },
            set: { selectedAllocationCurrencyCode = $0 }
        )
    }

    private var allocationScenarioPicker: some View {
        Group {
            if selectedAllocationPlan != nil {
                Picker("配置情景", selection: $allocationScenario) {
                    Text("当前").tag(AllocationScenario.current)
                    Text("计划后").tag(AllocationScenario.afterBuy)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("持仓配置情景")
            }
        }
    }

    private var allocationCurrencyPicker: some View {
        Group {
            if allocationCurrencyCodes.count > 1 {
                Picker("币种", selection: allocationCurrencySelection) {
                    ForEach(allocationCurrencyCodes, id: \.self) { code in
                        Text(code).tag(code)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("持仓配置币种")
            }
        }
    }

    private var allocationPlanPicker: some View {
        Picker("计划买入情景", selection: $selectedAllocationPlanID) {
            Text("不应用计划").tag(UUID?.none)
            ForEach(allocationPlans) { choice in
                Text("\(choice.item.resolvedDisplayName) · 买入 \(PriceFormatter.quantity(choice.plan.quantity))")
                    .tag(Optional(choice.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func allocationPlanSummary(_ result: PortfolioAllocation.Result, preview: PortfolioAllocation.Result?) -> some View {
        Group {
            if let plan = selectedAllocationPlan, let planned = result.plannedBuy, let preview,
               !preview.excludedUnrepresentableCurrencyCodes.contains(planned.currencyCode) {
                let before = result.currencies.first(where: { $0.code == planned.currencyCode })?.holdings.first(where: { $0.symbol == plan.item.symbol })?.percent ?? 0
                let after = preview.currencies.first(where: { $0.code == planned.currencyCode })?.holdings.first(where: { $0.symbol == plan.item.symbol })?.percent ?? 0
                Text("\(planned.currencyCode) · \(percentText(before)) → \(percentText(after))（\(signedPercentText(after - before))）")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            } else if selectedAllocationPlan != nil {
                Text("计划预览不可用，请检查报价、币种与数量")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
    }

    private func allocationDonut(_ currency: PortfolioAllocation.Currency) -> some View {
        let colors = allocationColorMap
        return Chart(currency.holdings) { holding in
            let isHighlighted = hoveredAllocationSymbol == nil || hoveredAllocationSymbol == holding.symbol
            SectorMark(
                angle: .value("敞口", holding.exposure),
                innerRadius: .ratio(0.76),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("标的", allocationColorKey(holding.symbol)))
            .opacity(isHighlighted ? 1 : 0.3)
        }
        .chartForegroundStyleScale(
            domain: currency.holdings.map { allocationColorKey($0.symbol) },
            range: currency.holdings.map { colors[$0.symbol] ?? .blue }
        )
        .chartLegend(.hidden)
        .chartAngleSelection(value: $selectedAllocationAngle)
        .onChange(of: selectedAllocationAngle) { _, angle in
            hoveredChartSymbol = allocationSymbol(at: angle, in: currency)
        }
        .chartBackground { _ in
            VStack(spacing: 2) {
                Text(currency.code).font(.system(size: 12, weight: .semibold))
                Text("\(currency.holdings.count) 项").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 124, height: 124)
        .accessibilityLabel("\(currency.code) 持仓敞口分布，共 \(currency.holdings.count) 个持仓")
    }

    private func allocationSymbol(at angle: Double?, in currency: PortfolioAllocation.Currency) -> SymbolID? {
        guard let angle, angle.isFinite else { return nil }
        var cumulative = 0.0
        for holding in currency.holdings {
            cumulative += holding.exposure
            if angle >= 0, angle < cumulative { return holding.symbol }
        }
        return nil
    }

    private func allocationHoldings(_ currency: PortfolioAllocation.Currency) -> some View {
        let colors = allocationColorMap
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("持仓分布").font(.system(size: 11, weight: .semibold))
                Spacer()
                if currency.holdings.count > 3 {
                    Text("\(currency.holdings.count) 项 · 滚动查看")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 360), spacing: 10)], spacing: 8) {
                ForEach(currency.holdings) { holding in
                    Button { onSelect(holding.symbol) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle().fill(colors[holding.symbol] ?? .blue).frame(width: 6, height: 6)
                                Text(holding.name).lineLimit(1)
                                    .layoutPriority(1)
                                if holding.isShort {
                                    Text("空头").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
                                }
                                Spacer(minLength: 3)
                                Text(percentText(holding.percent))
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .fixedSize()
                            }
                            HStack(spacing: 8) {
                                Text(holding.symbol.displayCode)
                                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: true, vertical: false)
                                Spacer(minLength: 4)
                                Text(PriceFormatter.money(holding.exposure, currencyCode: currency.code))
                                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomLeading) {
                            Capsule().fill(colors[holding.symbol] ?? .blue)
                                .frame(width: 80 * min(max(holding.percent, 0), 100) / 100, height: 2)
                                .padding(.leading, 8).padding(.bottom, 4)
                                .accessibilityHidden(true)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(hoveredAllocationSymbol == holding.symbol ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering {
                            hoveredRankingSymbol = holding.symbol
                        } else if hoveredRankingSymbol == holding.symbol {
                            hoveredRankingSymbol = nil
                        }
                    }
                    .accessibilityLabel("\(holding.name)，\(holding.symbol.displayCode)，\(PriceFormatter.money(holding.exposure, currencyCode: currency.code))，占比 \(percentText(holding.percent))\(holding.isShort ? "，空头" : "")。打开标的")
                }
            }
                .padding(.bottom, 8)
            }
            .frame(height: 120, alignment: .topLeading)
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 210, maxWidth: .infinity, alignment: .topLeading)
    }

    private func allocationColorKey(_ symbol: SymbolID) -> String {
        stableSymbolKey(symbol)
    }

    private var allocationColorMap: [SymbolID: Color] {
        let symbols = Set(
            allocationItems.filter { $0.supportsPosition && $0.positionQuantity != 0 }.map(\.symbol)
                + allocationPlans.map { $0.item.symbol }
        ).sorted { stableSymbolKey($0) < stableSymbolKey($1) }
        let colors: [Color] = [.blue, .orange, .teal, .purple, .pink, .cyan, .green, .brown, .indigo, .mint]
        // ponytail: ten categorical colors repeat for larger portfolios; extend the palette if needed.
        return Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($0.element, colors[$0.offset % colors.count]) })
    }

    private var costBasisSelection: Binding<PositionCostBasis> {
        Binding(
            get: { appState.settings.positionCostBasis },
            set: { appState.settings.positionCostBasis = $0 }
        )
    }

    private var sortFieldSelection: Binding<SortField> {
        Binding(
            get: { sortField },
            set: { selectSortField($0) }
        )
    }

    private func selectSortField(_ field: SortField, toggleIfSelected: Bool = false) {
        if field == sortField {
            if toggleIfSelected { sortAscending.toggle() }
            return
        }
        sortField = field
        sortAscending = field == .name
    }

    private func isOrdered(_ lhs: DisplayRow, _ rhs: DisplayRow) -> Bool {
        if sortField == .name {
            let comparison = lhs.item.resolvedDisplayName.localizedStandardCompare(rhs.item.resolvedDisplayName)
            if comparison != .orderedSame {
                return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            return stableSymbolKey(lhs.item.symbol) < stableSymbolKey(rhs.item.symbol)
        }

        let left = sortField.numericValue(in: lhs.values)
        let right = sortField.numericValue(in: rhs.values)
        switch (left, right) {
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case let (.some(left), .some(right)) where left != right:
            return sortAscending ? left < right : left > right
        default:
            return stableNameAndSymbolOrder(lhs.item, rhs.item)
        }
    }

    private func stableNameAndSymbolOrder(_ lhs: WatchItem, _ rhs: WatchItem) -> Bool {
        let comparison = lhs.resolvedDisplayName.localizedStandardCompare(rhs.resolvedDisplayName)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return stableSymbolKey(lhs.symbol) < stableSymbolKey(rhs.symbol)
    }

    private func stableSymbolKey(_ symbol: SymbolID) -> String {
        "\(symbol.market.rawValue):\(symbol.description)"
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            ForEach(visibleColumns) { column in
                Button {
                    selectSortField(column.field, toggleIfSelected: true)
                } label: {
                    HStack(spacing: 3) {
                        if column.field == sortField {
                            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        Text(PulseLocalization.localizedString(column.field.titleKey))
                            .lineLimit(1)
                    }
                    .font(.system(size: 10, weight: column.field == sortField ? .semibold : .medium))
                    .foregroundStyle(column.field == sortField ? Color.accentColor : Color.secondary)
                    .frame(width: columnWidth(column.field) - (column.field == .name ? 0 : 8),
                           alignment: column.field == .name ? .leading : .trailing)
                    .padding(.trailing, column.field == .name ? 0 : 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) { columnResizeHandle(column) }
                .background(alignment: .leading) {
                    if column.field == .name {
                        Color(nsColor: .controlBackgroundColor)
                            .frame(width: columnWidth(.name) + 16)
                            .overlay(alignment: .trailing) { Color.primary.opacity(0.08).frame(width: 1) }
                            .offset(x: -16)
                    }
                }
                .offset(x: column.field == .name ? max(0, -tableScrollOffset.x) : 0)
                .zIndex(column.field == .name ? 1 : 0)
                .help(PulseLocalization.localizedString(column.field.titleKey))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
        .offset(y: max(0, -tableScrollOffset.y))
        .zIndex(20)
    }

    private func columnResizeHandle(_ column: Column) -> some View {
        let startWidth = columnWidth(column.field)
        return Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if activeColumnResize?.field != column.field {
                            activeColumnResize = ActiveColumnResize(field: column.field, initialWidth: startWidth)
                        }
                        setColumnWidth(
                            column.field,
                            to: (activeColumnResize?.initialWidth ?? startWidth) + value.translation.width,
                            persist: false
                        )
                    }
                    .onEnded { value in
                        let initialWidth = activeColumnResize?.field == column.field
                            ? (activeColumnResize?.initialWidth ?? startWidth) : startWidth
                        setColumnWidth(column.field, to: initialWidth + value.translation.width, persist: true)
                        activeColumnResize = nil
                    }
            )
            .help("拖动调整列宽")
            .accessibilityElement()
            .accessibilityLabel("调整\(PulseLocalization.localizedString(column.field.titleKey))列宽")
            .accessibilityValue("\(Int(startWidth)) 点")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat
                switch direction {
                case .increment: delta = 10
                case .decrement: delta = -10
                @unknown default: return
                }
                setColumnWidth(column.field, to: columnWidth(column.field) + delta, persist: true)
            }
    }

    private func holdingRow(_ row: DisplayRow) -> some View {
        let item = row.item
        let quote = appState.market.quote(for: item.symbol)
        let currency = quote?.currencyCode ?? item.symbol.currencyCode
        return HStack(spacing: 0) {
            ForEach(visibleColumns) { column in
                columnContent(column.field, row: row, quote: quote, currency: currency)
                    .frame(width: columnWidth(column.field), height: 42,
                           alignment: column.field == .name ? .leading : .trailing)
                    .background(alignment: .leading) {
                        if column.field == .name {
                            symbolCellBackground(item.symbol)
                                .frame(width: columnWidth(column.field) + 16, height: 42)
                                .overlay(alignment: .trailing) { Color.primary.opacity(0.06).frame(width: 1) }
                                .offset(x: -16)
                        }
                        else { Color.clear }
                    }
                    .offset(x: column.field == .name ? max(0, -tableScrollOffset.x) : 0)
                    .zIndex(column.field == .name ? 2 : 0)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .background(hoveredAllocationSymbol == item.symbol ? Color.accentColor.opacity(0.07) : Color.clear)
        .onHover { isHovering in
            if isHovering {
                hoveredTableSymbol = item.symbol
            } else if hoveredTableSymbol == item.symbol {
                hoveredTableSymbol = nil
            }
        }
    }

    @ViewBuilder
    private func columnContent(_ field: SortField, row: DisplayRow, quote: Quote?, currency: String) -> some View {
        switch field {
        case .name:
            HStack(spacing: 7) {
                Button { expandedSymbol = expandedSymbol == row.item.symbol ? nil : row.item.symbol } label: {
                    Image(systemName: expandedSymbol == row.item.symbol ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expandedSymbol == row.item.symbol ? "收起" : "展开")\(row.item.resolvedDisplayName)成本记录")
                .accessibilityHint("显示逐笔交易和成本变化")
                Button { onSelect(row.item.symbol) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.resolvedDisplayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(row.item.symbol.displayCode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .quantity:
            cell(quantity(row.values.quantity, symbol: row.item.symbol), width: columnWidth(field))
        case .cost:
            cell(row.values.cost.map { costText($0, currency: currency, symbol: row.item.symbol) } ?? "—", width: columnWidth(field))
        case .holdingPnL:
            pnlCell(row.values.holdingPnL, currency: currency, width: columnWidth(field))
        case .totalPnL:
            pnlCell(row.values.totalPnL, currency: currency, width: columnWidth(field))
        case .price:
            quoteCell(row.values.price, quote: quote, symbol: row.item.symbol, width: columnWidth(field))
        case .todayPnL:
            pnlCell(row.values.todayPnL, currency: currency, width: columnWidth(field))
        case .realizedPnL:
            pnlCell(row.values.realizedPnL, currency: currency, width: columnWidth(field))
        case .marketValue:
            cell(row.values.marketValue.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—", width: columnWidth(field))
        case .fees:
            cell(row.values.fees.map { PriceFormatter.money($0, currencyCode: currency) } ?? "—", width: columnWidth(field))
        }
    }

    private func symbolCellBackground(_ symbol: SymbolID) -> some View {
        Color(nsColor: .controlBackgroundColor)
            .overlay(hoveredAllocationSymbol == symbol ? Color.accentColor.opacity(0.07) : Color.clear)
    }

    private func quoteCell(_ price: Double?, quote: Quote?, symbol: SymbolID, width: CGFloat) -> some View {
        let priceText = price.map { PriceFormatter.price($0, market: symbol.market) } ?? "—"
        let metadata = (price?.isFinite == true ? quote : nil).map {
            "\(quoteTimestampText($0)) \($0.symbol.market.timeZoneDisplayName) · \(quoteProvenanceText($0))"
        }
        return Text(priceText)
            .font(.system(size: 12, weight: .regular).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: max(0, width - 16), alignment: .trailing)
            .padding(.horizontal, 8)
            .help(metadata ?? "")
            .accessibilityLabel(PulseLocalization.localizedString(SortField.price.titleKey))
            .accessibilityValue(([priceText] + (metadata.map { [$0] } ?? [])).joined(separator: " · "))
    }

    private func quoteTimestampText(_ quote: Quote) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = quote.symbol.market.timeZone
        return formatter.string(from: quote.timestamp)
    }

    private func quoteProvenanceText(_ quote: Quote) -> String {
        let source = quote.sourceName ?? quote.sourceID ?? "来源未知"
        let state: String? = switch quote.marketState {
        case .preMarket: PulseLocalization.localizedString("quote.price.preMarket")
        case .postMarket: PulseLocalization.localizedString("quote.price.postMarket")
        case .overnight: PulseLocalization.localizedString("quote.price.overnight")
        case .closed: PulseLocalization.localizedString("quote.price.close")
        case .regular, .none: nil
        }
        return ([source, appState.quoteDelayText(for: quote), state].compactMap { $0 }).joined(separator: " · ")
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).lineLimit(1).minimumScaleFactor(0.85)
            .frame(width: max(0, width - 16), alignment: .trailing)
            .padding(.horizontal, 8)
            .help(text)
    }

    private func pnlCell(_ amount: Double?, currency: String, width: CGFloat) -> some View {
        Text(amount.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—")
            .foregroundStyle(amount.map { appState.palette.color(for: $0) } ?? Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: max(0, width - 16), alignment: .trailing)
            .padding(.horizontal, 8)
            .help(amount.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—")
    }

    private func quantity(_ amount: Double, symbol: SymbolID) -> String {
        let unitKey = symbol.market == .crypto ? "main.holdings.unit.crypto" : "main.holdings.unit.shares"
        return "\(PriceFormatter.quantity(amount)) \(PulseLocalization.localizedString(unitKey))"
    }

    private func costText(_ amount: Double, currency: String, symbol: SymbolID) -> String {
        let price = PriceFormatter.price(amount, market: symbol.market)
        return currency == "CNY" ? price : "\(currency) \(price)"
    }

    private func value(for item: WatchItem) -> Values {
        let quote = appState.market.quote(for: item.symbol)
        let quantity = item.positionQuantity
        let averageCost = item.averageCost ?? item.ledger?.averageCost ?? 0
        let basisCost = appState.settings.positionCostBasis == .diluted
            ? (item.ledger?.dilutedCost ?? averageCost)
            : averageCost
        let realized = item.realizedPnL
        let fees = item.ledger?.totalFees
        guard quantity != 0 else {
            return Values(
                quantity: 0, cost: nil, price: nil, marketValue: nil, todayPnL: nil,
                holdingPnL: nil, realizedPnL: realized, totalPnL: realized, fees: fees
            )
        }
        guard let quote else {
            return Values(
                quantity: quantity,
                cost: item.averageCost != nil || item.ledger != nil ? basisCost : nil,
                price: nil, marketValue: nil, todayPnL: nil, holdingPnL: nil,
                realizedPnL: realized, totalPnL: quantity == 0 ? realized : nil, fees: fees
            )
        }
        guard let valuation = PositionValuation(item: item, quote: quote, basis: appState.settings.positionCostBasis) else {
            return Values(
                quantity: quantity,
                cost: item.averageCost != nil || item.ledger != nil ? basisCost : nil,
                price: quote.price, marketValue: nil, todayPnL: nil, holdingPnL: nil,
                realizedPnL: realized, totalPnL: nil, fees: fees
            )
        }
        return Values(
            quantity: valuation.quantity,
                cost: valuation.costPrice,
            price: quote.price,
            marketValue: valuation.marketValue,
            todayPnL: valuation.todayPnL,
            holdingPnL: valuation.holdingPnL,
            realizedPnL: valuation.realizedPnL,
            totalPnL: valuation.totalPnL,
            fees: valuation.totalFees
        )
    }

    @ViewBuilder private func costHistory(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PulseLocalization.localizedString("main.holdings.costHistory.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(PulseLocalization.localizedString(
                "main.holdings.costHistory.explanation",
                PulseLocalization.localizedString(PositionCostBasis.average.labelKey),
                PulseLocalization.localizedString(PositionCostBasis.diluted.labelKey)
            ))
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let ledger = item.ledger {
                let currency = appState.market.quote(for: item.symbol)?.currencyCode ?? item.symbol.currencyCode
                ForEach(ledger.entries) { entry in
                    let transaction = entry.transaction
                    HStack(spacing: 12) {
                        Text(transaction.date.formatted(date: .abbreviated, time: .omitted)).frame(width: 92, alignment: .leading)
                        Text(PulseLocalization.localizedString(transaction.kind == .adjustment
                                                               ? "main.holdings.entry.adjustment"
                                                               : transaction.kind == .buy ? "main.holdings.entry.buy" : "main.holdings.entry.sell"))
                            .frame(width: 75, alignment: .leading)
                        Text("\(quantity(transaction.quantity, symbol: item.symbol)) × \(currency) \(PriceFormatter.price(transaction.price, market: item.symbol.market))")
                            .frame(width: 180, alignment: .leading)
                        Text(PulseLocalization.localizedString("main.holdings.entry.fee", transaction.fee.map { PriceFormatter.money($0, currencyCode: currency) } ?? "—"))
                            .frame(width: 120, alignment: .leading)
                        Text(PulseLocalization.localizedString("main.holdings.entry.result", quantity(entry.resultingQuantity, symbol: item.symbol), costText(entry.resultingAverageCost, currency: currency, symbol: item.symbol)))
                            .frame(width: 260, alignment: .leading)
                        Text(entry.realizedPnL.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—")
                            .foregroundStyle(entry.realizedPnL.map { appState.palette.color(for: $0) } ?? Color.secondary)
                            .frame(width: 130, alignment: .trailing)
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(PulseLocalization.localizedString("main.holdings.costHistory.legacy"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 43).padding(.trailing, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.035))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "briefcase" : "magnifyingglass")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(PulseLocalization.localizedString(query.isEmpty
                                                   ? (filter == .current ? "main.holdings.empty.current" : "main.holdings.empty.closed")
                                                   : "main.holdings.empty.search"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if query.isEmpty, appState.watchlist.brokerageAccountsEnabled {
                Text(PulseLocalization.localizedString("main.holdings.empty.accountHint",
                     AccountIdentity.title(appState.watchlist.activeBrokerageAccountID)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
