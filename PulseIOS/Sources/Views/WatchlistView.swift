import SwiftUI
import PulseCore
import PulseUI

// MARK: - Watchlist

/// Display-only ordering for the watchlist. Same semantics as the Mac
/// WatchlistSortResolver: pinned section first, metric descending inside each
/// section, missing metrics last, base order breaks ties. Never writes.
enum WatchlistSorting {
    enum Option: String, CaseIterable, Identifiable {
        case custom, changePercent, todayPnL, totalPnL, marketValue
        var id: Self { self }
        var title: String {
            switch self {
            case .custom: "自定义顺序"
            case .changePercent: "涨幅"
            case .todayPnL: "今日盈亏"
            case .totalPnL: "总盈亏"
            case .marketValue: "持仓市值"
            }
        }
    }

    static func ordered(_ items: [WatchItem], pinnedSymbols: [SymbolID],
                        option: Option, value: (WatchItem) -> Double?) -> [WatchItem] {
        guard option != .custom else { return pinnedFirst(items, pinnedSymbols: pinnedSymbols) }
        let pinned = Set(pinnedSymbols)
        let metrics = items.map { item -> Double? in
            guard let raw = value(item), raw.isFinite else { return nil }
            return raw
        }
        return items.enumerated().sorted { lhs, rhs in
            let lp = pinned.contains(lhs.element.symbol), rp = pinned.contains(rhs.element.symbol)
            if lp != rp { return lp }
            switch (metrics[lhs.offset], metrics[rhs.offset]) {
            case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    static func pinnedFirst(_ items: [WatchItem], pinnedSymbols: [SymbolID]) -> [WatchItem] {
        let pinned = Set(pinnedSymbols)
        return pinnedSymbols.compactMap { key in items.first { $0.symbol == key } }
            + items.filter { !pinned.contains($0.symbol) }
    }
}

struct WatchlistView: View {
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [SymbolInfo] = []
    @State private var searchError: String?
    @State private var isSearchingRemote = false
    @State private var symbolPendingRemoval: WatchItem?
    @State private var showReorderSheet = false
    @State private var sortOption: WatchlistSorting.Option = .custom

    private static let sortKey = "ios.watchlist.sortOption"
    private var pinnedSymbols: [SymbolID] {
        state.watchlist.group(for: selectedGroupID)?.pinnedSymbols ?? []
    }
    private var groups: [WatchlistGroup] { state.watchlist.groups }
    private var selectedGroupID: UUID? { state.watchlist.selectedGroupID }

    /// Local filtering first so the list answers instantly in Chinese and by
    /// full code; the remote search is what the user explicitly asks for.
    private var visibleItems: [WatchItem] {
        let scoped: [WatchItem]
        if let selectedGroupID {
            scoped = state.watchlist.items(in: selectedGroupID)
        } else {
            scoped = state.watchlist.items
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [WatchItem]
        if query.isEmpty { filtered = scoped }
        else { filtered = scoped.filter { matches($0, query: query) } }
        return WatchlistSorting.ordered(filtered, pinnedSymbols: pinnedSymbols,
            option: sortOption, value: sortValue)
    }

    /// The metric for one row, nil when it cannot be honestly computed
    /// (no quote, or a held position that cannot be valued).
    private func sortValue(_ item: WatchItem) -> Double? {
        guard let quote = state.quote(item.symbol) else { return nil }
        switch sortOption {
        case .custom: return nil
        case .changePercent:
            let change = quote.changePercent
            return change.isFinite ? change : nil
        case .todayPnL, .totalPnL, .marketValue:
            guard item.hasPosition else { return nil }
            guard let valuation = PositionValuation(item: item, quote: quote, basis: .average) else { return nil }
            let value: Double = switch sortOption {
            case .todayPnL: valuation.todayPnL
            case .totalPnL: valuation.holdingPnL
            default: valuation.marketValue
            }
            return value.isFinite ? value : nil
        }
    }

    private func matches(_ item: WatchItem, query: String) -> Bool {
        let name = state.displayName(item.symbol)
        if name.localizedStandardContains(query) { return true }
        if item.symbol.code.localizedStandardContains(query) { return true }
        if item.symbol.description.localizedStandardContains(query) { return true }
        if item.symbol.displayCode.localizedStandardContains(query) { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkbenchHeader(title: "自选")

                if groups.count > 1 {
                    groupPicker
                }

                searchField

                if !visibleItems.isEmpty {
                    sortBar
                }

                if shouldShowRemoteResults {
                    remoteResultsSection
                }

                if visibleItems.isEmpty {
                    emptyState
                } else {
                    quoteList
                }

                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await state.refresh() }
        .onAppear {
            sortOption = WatchlistSorting.Option(
                rawValue: state.defaults.string(forKey: Self.sortKey) ?? "") ?? .custom
        }
        .sheet(isPresented: $showReorderSheet) {
            ReorderWatchlistSheet(groupID: selectedGroupID)
        }
        .confirmationDialog(
            "从自选移除",
            isPresented: Binding(
                get: { symbolPendingRemoval != nil },
                set: { if !$0 { symbolPendingRemoval = nil } }
            ),
            presenting: symbolPendingRemoval
        ) { item in
            Button("移除 \(state.displayName(item.symbol))", role: .destructive) {
                state.remove(item.symbol)
                symbolPendingRemoval = nil
            }
            Button("取消", role: .cancel) { symbolPendingRemoval = nil }
        } message: { item in
            Text(removalMessage(for: item))
        }
    }

    /// Removal is a real destructive act on a record that may carry trades, so
    /// the consequence is stated before it happens.
    private func removalMessage(for item: WatchItem) -> String {
        var parts: [String] = []
        if item.hasPositionHistory {
            parts.append("这个标的有关联的持仓与成交记录，移除自选不会删除它们，但会从列表里消失。")
        }
        if !item.plans.isEmpty {
            parts.append("它还有 \(item.plans.count) 条计划。")
        }
        if parts.isEmpty {
            parts.append("只从关注列表移除，不影响其他账户。")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Groups

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups, id: \.id) { (group: WatchlistGroup) in
                    let isSelected = group.id == selectedGroupID
                    Button {
                        state.setGroup(group.id)
                    } label: {
                        Text(group.name)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? WorkbenchTheme.blue : .secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(isSelected ? WorkbenchTheme.blue.opacity(0.12) : WorkbenchTheme.chipBackground(colorScheme))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: Sorting

    private var sortBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(WatchlistSorting.Option.allCases) { option in
                    Button {
                        sortOption = option
                        state.defaults.set(option.rawValue, forKey: Self.sortKey)
                    } label: {
                        if option == sortOption {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                    .accessibilityIdentifier("watchlist.sort.\(option.rawValue)")
                }
            } label: {
                Label("排序：\(sortOption.title)", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(WorkbenchTheme.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(WorkbenchTheme.blue.opacity(0.10), in: Capsule())
            }
            .accessibilityIdentifier("watchlist.sort")
            if sortOption == .custom {
                Button("调整顺序") { showReorderSheet = true }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(sortOption == .custom ? "长按标的可置顶或移除" : "自动排序只影响展示")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 2)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("搜索中文名或完整代码", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchResults = []
                    searchError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await runSearch() }
            } label: {
                if isSearchingRemote {
                    ProgressView().controlSize(.small)
                } else {
                    Text("搜索").font(.subheadline.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkbenchTheme.blue)
            .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearchingRemote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorkbenchTheme.chipBackground(colorScheme))
        )
    }

    private var shouldShowRemoteResults: Bool {
        !searchResults.isEmpty || searchError != nil
    }

    private var remoteResultsSection: some View {
        WorkbenchSection(title: "搜索结果", actionTitle: "清除", action: {
            searchResults = []
            searchError = nil
        }) {
            VStack(spacing: 0) {
                if let searchError {
                    Text(searchError)
                        .font(.footnote)
                        .foregroundStyle(WorkbenchTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                ForEach(searchResults) { info in
                    SearchResultRow(info: info, isAlreadyWatched: isWatched(info.symbol)) {
                        state.add(info)
                        searchResults.removeAll { $0.symbol == info.symbol }
                    }
                    if info.symbol != searchResults.last?.symbol {
                        Divider()
                    }
                }
            }
        }
    }

    private func isWatched(_ symbol: SymbolID) -> Bool {
        state.watchlist.contains(symbol)
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchingRemote = true
        defer { isSearchingRemote = false }
        do {
            searchResults = try await state.search(query)
            searchError = searchResults.isEmpty ? "没有找到匹配的标的。" : nil
        } catch {
            searchResults = []
            searchError = "搜索暂不可用：\(error.localizedDescription)"
        }
    }

    // MARK: List

    private var quoteList: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 2)
                }
                WatchQuoteRow(item: item) {
                    onOpenRoute?(WorkbenchRoute(
                        destination: .symbol(item.symbol),
                        tab: WorkbenchRoute.watchlistTab
                    ))
                }
                .contentShape(Rectangle())
                // Long-press menu: swipeActions silently do nothing outside a
                // List, so the row actions live here where they actually fire.
                .contextMenu {
                    Button {
                        togglePin(item)
                    } label: {
                        Label(
                            state.watchlist.isPinned(item.symbol, in: selectedGroupID) ? "取消置顶" : "置顶",
                            systemImage: "pin"
                        )
                    }
                    Button(role: .destructive) {
                        symbolPendingRemoval = item
                    } label: {
                        Label("移除", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func togglePin(_ item: WatchItem) {
        let pinned = state.watchlist.isPinned(item.symbol, in: selectedGroupID)
        _ = state.watchlist.setPinned(item.symbol, in: selectedGroupID, pinned: !pinned)
    }

    private var emptyState: some View {
        WorkbenchEmptyState(
            icon: searchText.isEmpty ? "star" : "magnifyingglass",
            title: searchText.isEmpty ? "这个分组还是空的" : "本账户自选里没有匹配",
            message: searchText.isEmpty
                ? "在上面的搜索框里输入中文名或完整代码，关注后就能看到行情、计划与持仓。"
                : "可以点「搜索」去行情源查找并关注新的标的。"
        )
    }

    private var footer: some View {
        Text("行情为数据源最新快照；源时间在行内标注。计划与记成交不依赖行情在线。")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Custom order sheet

/// Drag-to-reorder the current group. Pinned rows stay pinned: a move that
/// would cross the pin boundary is refused, matching the store's own rule.
/// The edit commits only when the user taps 完成; cancel leaves the store
/// untouched.
struct ReorderWatchlistSheet: View {
    let groupID: UUID?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var order: [SymbolID] = []
    @State private var frozenGroup: WatchlistGroup?
    @State private var frozenAccount: BrokerageAccountID?
    @State private var frozenItems: [WatchItem] = []
    @State private var errorMessage: String?

    private var group: WatchlistGroup? { frozenGroup ?? state.watchlist.group(for: groupID) }
    private var pinnedCount: Int {
        let pinned = Set(group?.pinnedSymbols ?? [])
        return order.filter { pinned.contains($0) }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { symbol in
                        HStack(spacing: 8) {
                            Text(frozenItems.first(where: { $0.symbol == symbol })?.resolvedDisplayName ?? symbol.displayCode)
                                .font(.subheadline.weight(.medium))
                            if frozenGroup?.pinnedSymbols.contains(symbol) == true {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(WorkbenchTheme.blue)
                            }
                            Spacer()
                            Text(symbol.description)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onMove(perform: move)
                } header: {
                    Text("拖动排序，置顶标的保持在顶部；点完成才写入。")
                        .font(.caption)
                        .textCase(nil)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("自定义顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                if frozenGroup == nil, let group {
                    frozenGroup = group
                    frozenAccount = state.accountID
                    frozenItems = state.watchlist.items(in: group.id)
                    order = WatchlistSorting.pinnedFirst(
                        state.watchlist.items(in: group.id), pinnedSymbols: group.pinnedSymbols
                    ).map(\.symbol)
                }
            }
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        let pinned = pinnedCount
        for index in offsets {
            let permitted = index < pinned ? destination <= pinned : destination >= pinned
            if !permitted {
                errorMessage = "置顶标的保持在前；先取消置顶再移入下方。"
                return
            }
        }
        errorMessage = nil
        order.move(fromOffsets: offsets, toOffset: destination)
    }

    private func commit() {
        guard let group = frozenGroup, let account = frozenAccount else { return }
        do {
            try state.saveWatchlistOrder(order, expectedGroup: group, account: account)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Search result row

struct SearchResultRow: View {
    let info: SymbolInfo
    let isAlreadyWatched: Bool
    let onAdd: () -> Void

    private var typeLabel: String {
        switch info.symbol.sectorIndex != nil ? InstrumentType.index : info.type {
        case .equity: "股票"
        case .etf: "ETF"
        case .index: "指数"
        case .fund: "基金"
        case .crypto: "加密"
        case .commodity: "商品"
        case .other: "其他"
        }
    }

    private var canHold: Bool {
        info.symbol.sectorIndex == nil && info.type != .index && info.type != .commodity
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.resolvedDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    WorkbenchTag(text: typeLabel)
                    Text(info.symbol.description)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if let exchange = info.exchangeName {
                        Text(exchange)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !canHold {
                    Text("指数只作行情参考，不能记持仓。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isAlreadyWatched {
                Text("已关注")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button("关注", action: onAdd)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 52)
    }
}
