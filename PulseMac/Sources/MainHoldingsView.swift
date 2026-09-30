import AppKit
import SwiftUI
import PulseCore
import PulseUI

struct MainHoldingsView: View {
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

    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    @State private var query = ""
    @State private var filter: PositionFilter = .current
    @State private var sortField: SortField = .name
    @State private var sortAscending = true
    @State private var expandedSymbol: SymbolID?

    private struct Column: Identifiable {
        let field: SortField
        let width: CGFloat
        var id: SortField { field }
    }

    private static let columns: [Column] = [
        Column(field: .name, width: 155),
        Column(field: .quantity, width: 74),
        Column(field: .cost, width: 103),
        Column(field: .holdingPnL, width: 113),
        Column(field: .totalPnL, width: 113),
        Column(field: .price, width: 95),
        Column(field: .todayPnL, width: 100),
        Column(field: .realizedPnL, width: 100),
        Column(field: .marketValue, width: 100),
        Column(field: .fees, width: 85)
    ]

    private var filteredItems: [WatchItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = appState.watchlist.allItems.filter { item in
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
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        columnHeader
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                holdingRow(row)
                                if expandedSymbol == row.item.symbol {
                                    costHistory(row.item)
                                }
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .frame(minWidth: tableWidth, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tableWidth: CGFloat { Self.columns.reduce(0) { $0 + $1.width } }

    private func header(itemCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PulseLocalization.localizedString("main.holdings.title"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(PulseLocalization.localizedString("main.holdings.subtitle", itemCount))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                searchField
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
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
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(PulseLocalization.localizedString("main.holdings.costBasis.title"))
                    .help(PulseLocalization.localizedString("position.costBasisHelp"))
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Picker(PulseLocalization.localizedString("main.holdings.sort.title"), selection: sortFieldSelection) {
                        ForEach(SortField.allCases, id: \.self) { field in
                            Text(PulseLocalization.localizedString(field.titleKey)).tag(field)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel(PulseLocalization.localizedString("main.holdings.sort.title"))

                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(PulseLocalization.localizedString(sortAscending
                                                            ? "main.holdings.sort.ascending"
                                                            : "main.holdings.sort.descending"))
                    .accessibilityLabel(PulseLocalization.localizedString(sortAscending
                                                                           ? "main.holdings.sort.ascending"
                                                                           : "main.holdings.sort.descending"))

                    Button(PulseLocalization.localizedString("main.holdings.sort.reset")) {
                        sortField = .name
                        sortAscending = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sortField == .name && sortAscending)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
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
            ForEach(Self.columns) { column in
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
                    .frame(width: column.width, alignment: column.field == .name ? .leading : .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(PulseLocalization.localizedString(column.field.titleKey))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func holdingRow(_ row: DisplayRow) -> some View {
        let item = row.item
        let values = row.values
        let quote = appState.market.quote(for: item.symbol)
        let currency = quote?.currencyCode ?? item.symbol.currencyCode
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { expandedSymbol = expandedSymbol == item.symbol ? nil : item.symbol } label: {
                    Image(systemName: expandedSymbol == item.symbol ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Button { onSelect(item.symbol) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.resolvedDisplayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(item.symbol.displayCode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: Self.columns[0].width, alignment: .leading)
            cell(quantity(values.quantity, symbol: item.symbol), width: Self.columns[1].width)
            cell(values.cost.map { costText($0, currency: currency, symbol: item.symbol) } ?? "—", width: Self.columns[2].width)
            pnlCell(values.holdingPnL, currency: currency, width: Self.columns[3].width)
            pnlCell(values.totalPnL, currency: currency, width: Self.columns[4].width)
            cell(values.price.map { PriceFormatter.price($0, market: item.symbol.market) } ?? "—", width: Self.columns[5].width)
            pnlCell(values.todayPnL, currency: currency, width: Self.columns[6].width)
            pnlCell(values.realizedPnL, currency: currency, width: Self.columns[7].width)
            cell(values.marketValue.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—", width: Self.columns[8].width)
            cell(values.fees.map { PriceFormatter.money($0, currencyCode: currency) } ?? "—", width: Self.columns[9].width)
        }
        .font(.system(size: 11).monospacedDigit())
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).lineLimit(1).frame(width: width, alignment: .trailing)
    }

    private func pnlCell(_ amount: Double?, currency: String, width: CGFloat) -> some View {
        Text(amount.map { PriceFormatter.signedMoney($0, currencyCode: currency) } ?? "—")
            .foregroundStyle(amount.map { appState.palette.color(for: $0) } ?? Color.primary)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
