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

        var titleKey: String {
            switch self {
            case .all: "main.planList.filter.all"
            case .waiting: "main.planList.filter.waiting"
            case .done: "main.planList.filter.done"
            case .dropped: "main.planList.filter.dropped"
            }
        }
    }

    private enum SortOrder: String, CaseIterable, Identifiable {
        case reached, symbol, target, distance

        var id: String { rawValue }
        var titleKey: String { "main.planList.sort.\(rawValue)" }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var route: PopoverRoute
    @State private var query = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOrder: SortOrder = .reached
    @State private var reachedOnly = false

    private var entries: [TradePlanEntry] { appState.watchlist.tradePlanEntries }

    private func currentPrice(_ symbol: SymbolID) -> Double? {
        guard let price = appState.market.quote(for: symbol)?.price,
              price.isFinite, price > 0 else { return nil }
        return price
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
            case .waiting where entry.plan.status != .active: return false
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
                        Text(PulseLocalization.localizedString(filter.titleKey)).tag(filter)
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
            .frame(minWidth: 985, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            columnHeader("main.planList.column.symbol", width: 225, alignment: .leading)
            columnHeader("main.planList.column.kind", width: 66, alignment: .leading)
            columnHeader("main.planList.column.target", width: 108, alignment: .trailing)
            columnHeader("main.planList.column.current", width: 108, alignment: .trailing)
            columnHeader("main.planList.column.distance", width: 100, alignment: .trailing)
            columnHeader("main.planList.column.quantity", width: 88, alignment: .trailing)
            columnHeader("main.planList.column.status", width: 115, alignment: .leading)
            columnHeader("main.planList.column.note", width: 175, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func tableRow(_ entry: TradePlanEntry) -> some View {
        let current = currentPrice(entry.symbol)
        let quoteName = appState.market.quote(for: entry.symbol)?.name
        let name = quoteName ?? appState.displayName(for: entry.symbol)
        let distance = current.map { entry.plan.gapPercent(from: $0) }

        return HStack(spacing: 0) {
            HStack(spacing: 3) {
                Button {
                    route = .detail(entry.symbol)
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
                    .frame(width: 155, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                rowActions(entry)
            }
            .frame(width: 225, alignment: .leading)

            directionCell(entry.plan.kind)
            textCell(PriceFormatter.price(entry.plan.price, market: entry.symbol.market), width: 108, alignment: .trailing, monospaced: true)
            textCell(current.map { PriceFormatter.price($0, market: entry.symbol.market) } ?? "—", width: 108, alignment: .trailing, monospaced: true)
            textCell(distance.map(PriceFormatter.percentMagnitude) ?? "—", width: 100, alignment: .trailing, monospaced: true)
            textCell(PriceFormatter.quantity(entry.plan.quantity), width: 88, alignment: .trailing, monospaced: true)
            statusCell(entry, reached: isReached(entry), hasQuote: current != nil)
            textCell(entry.plan.note?.isEmpty == false ? entry.plan.note! : "—", width: 175, alignment: .leading, secondary: true)
        }
        .font(.system(size: 10.5))
        .padding(.vertical, 6)
    }

    private func columnHeader(_ key: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(PulseLocalization.localizedString(key))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }

    private func directionCell(_ kind: TradePlan.Kind) -> some View {
        let color = appState.palette.color(isUp: kind == .buy)
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
        secondary: Bool = false
    ) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .regular, design: monospaced ? .monospaced : .default))
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: alignment)
    }

    private func statusCell(_ entry: TradePlanEntry, reached: Bool, hasQuote: Bool) -> some View {
        HStack(spacing: 5) {
            Text(PulseLocalization.localizedString(statusKey(entry.plan.status)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if reached {
                Text(PulseLocalization.localizedString("plan.reached"))
                    .foregroundStyle(appState.palette.color(isUp: entry.plan.kind == .buy))
                    .lineLimit(1)
            } else if entry.plan.status == .active && !hasQuote {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 9.5, weight: reached ? .medium : .regular))
        .frame(width: 115, alignment: .leading)
    }

    private func rowActions(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 2) {
            Button {
                route = .plan(entry.symbol, entry.plan.id, .planList)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(PulseLocalization.localizedString("main.planList.action.edit"))

            Menu {
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

    private func statusKey(_ status: TradePlan.Status) -> String {
        switch status {
        case .active: "plan.status.active"
        case .done: "plan.status.done"
        case .cancelled: "plan.status.cancelled"
        }
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
