import AppKit
import SwiftUI
import PulseCore
import PulseUI

struct MainWatchlistSidebar: View {
    enum Filter: String, CaseIterable {
        case all, positions, plans

        var titleKey: String {
            switch self {
            case .all: "main.filter.all"
            case .positions: "main.filter.positions"
            case .plans: "main.filter.plans"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Binding var selectedSymbol: SymbolID?
    /// The global page actually on screen, or `nil` while an instrument is
    /// shown. The sidebar marks this one entry and nothing else, so a position
    /// opened from 资金 cannot leave 资金 lit.
    let currentPage: MainWorkspacePage?
    let onShowPage: (MainWorkspacePage) -> Void
    @State private var selectedGroupID: UUID?
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var searchResults: [SymbolInfo] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var sidebarWidth: CGFloat = 280
    @State private var dragStartWidth: CGFloat?

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentGroup: WatchlistGroup? { appState.sharedWatchlist.group(for: selectedGroupID) }
    /// The summary is computed against quotes that are actually usable for an
    /// intraday attention signal, so a closed or stale feed cannot make the
    /// sidebar claim a plan is in range when the plan page would disagree.
    /// `now` is captured once per render rather than read per plan — the
    /// freshness window is a property of the moment, not of each row.
    private var planSummary: TradePlanOverview.Summary {
        let now = Date.now
        return TradePlanOverview.summary(
            appState.watchlist.tradePlanEntries,
            currentPrice: { symbol in
                guard let quote = appState.market.quote(for: symbol),
                      TradingQuoteHealth.isCurrent(quote, now: now) else { return nil }
                return quote.price
            }
        )
    }
    private var groupItems: [WatchItem] {
        guard let currentGroup else { return [] }
        return appState.sharedWatchlist.items(in: currentGroup.id).filter { item in
            switch filter {
            case .all: true
            case .positions: appState.sharedWatchlist.hasPosition(for: item.symbol)
            case .plans: appState.sharedWatchlist.hasActivePlan(for: item.symbol)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                if normalizedQuery.isEmpty {
                    groupPicker
                    filterPicker
                    watchlistContent
                        // The entries below are fixed chrome; the watchlist is
                        // the part that gives way, but never below a usable
                        // handful of rows.
                        .frame(minHeight: 120)
                } else {
                    searchContent
                        .frame(minHeight: 120)
                }
                overviewButtons
                    .layoutPriority(1)
            }
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.8))
                .frame(width: 1)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(.clear).frame(width: 5)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let base = dragStartWidth ?? sidebarWidth
                            dragStartWidth = base
                            sidebarWidth = min(360, max(260, base + value.translation.width))
                        }.onEnded { _ in dragStartWidth = nil })
                        .overlay { ResizeCursorHint().allowsHitTesting(false) }
                }
        }
        .onAppear {
            if selectedGroupID == nil { selectedGroupID = appState.sharedWatchlist.selectedGroup?.id }
        }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: appState.sharedWatchlist.groups) { _, groups in
            if !groups.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = groups.first?.id
            }
        }
        .onChange(of: appState.sharedWatchlist.quoteSymbols) { _, _ in
            appState.watchlistSymbolsChanged()
        }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(PulseLocalization.localizedString("main.search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(PulseLocalization.localizedString("main.search.placeholder"))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(PulseLocalization.localizedString("main.search.clear"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(appState.sharedWatchlist.groups) { group in
                    Button(group.name) { selectedGroupID = group.id }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: selectedGroupID == group.id ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(selectedGroupID == group.id ? Color.accentColor.opacity(0.17) : .clear, in: Capsule())
                        .foregroundStyle(selectedGroupID == group.id ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .frame(height: 32)
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(Filter.allCases, id: \.self) { option in
                Text(PulseLocalization.localizedString(option.titleKey)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The global entries, in stable purpose groups: 今日 is the one page that
    /// answers "what needs me now", 资金 is where the money is, 计划与事件 is
    /// intent and observation windows, 复盘 is what actually happened. Grouping
    /// is by purpose rather than by pre/regular/post session, because the
    /// session is a view *inside* 今日 and must not rearrange navigation.
    private var overviewButtons: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(MainWorkspacePage.SidebarGroup.allCases) { group in
                groupHeader(group)
                ForEach(group.pages) { page in
                    pageButton(page)
                }
            }
        }
        .padding(.bottom, 8)
        .background(alignment: .top) { Divider() }
    }

    private func groupHeader(_ group: MainWorkspacePage.SidebarGroup) -> some View {
        Text(group.title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pageButton(_ page: MainWorkspacePage) -> some View {
        let isCurrent = currentPage == page
        return Button {
            onShowPage(page)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    if let detail = pageDetail(page) {
                        Text(detail)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isCurrent {
                    // A live accent bar in addition to the wash below: the
                    // filled background alone is easy to miss against the
                    // sidebar's own window colour.
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 15)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(
                isCurrent ? Color.accentColor.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityLabel(page.title)
    }

    /// The secondary count line. A zero count is hidden rather than printed as
    /// "0", so an empty page reads as empty instead of as a measured nothing.
    private func pageDetail(_ page: MainWorkspacePage) -> String? {
        switch page {
        case .holdings:
            let count = holdingCount
            return count > 0 ? PulseLocalization.localizedString("main.holdings.count", count) : nil
        case .plans:
            guard planSummary.total > 0 else { return nil }
            return PulseLocalization.localizedString(
                "plan.list.summary", planSummary.total, planSummary.reached
            )
        case .accounts:
            // The overview is a reading of every account, so its subtitle names
            // how many are being read rather than counting anything of its own.
            return PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                ? "融资账号 · 萌萌账号"
                : "Financing · Mengmeng"
        case .workbench, .positionPools, .events, .journal:
            return nil
        }
    }

    private var holdingCount: Int {
        appState.watchlist.allItems.filter { $0.supportsPosition && $0.hasPositionHistory }.count
    }

    @ViewBuilder private var watchlistContent: some View {
        if appState.sharedWatchlist.groups.isEmpty {
            emptyState("main.empty.noGroups", symbol: "folder")
        } else if groupItems.isEmpty {
            emptyState(filter == .all ? "main.empty.watchlist" : "main.empty.filter", symbol: "line.3.horizontal.decrease.circle")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(groupItems) { item in
                        MainWatchRow(symbol: item.symbol, name: item.resolvedDisplayName, selected: selectedSymbol == item.symbol) {
                            // A watchlist row means 盯盘: it opens the instrument
                            // itself and drops any global page, so the sidebar
                            // cannot keep showing a page the user has left.
                            selectedSymbol = item.symbol
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder private var searchContent: some View {
        if isSearching && searchResults.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.secondary)
                Text(PulseLocalization.localizedString("main.search.failed"))
                    .font(.system(size: 12, weight: .medium))
                Text(searchError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(PulseLocalization.localizedString("main.search.retry")) { scheduleSearch(immediately: true) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !isSearching && searchResults.isEmpty {
            emptyState("main.search.noResults", symbol: "magnifyingglass")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(searchResults) { info in
                        SearchRow(info: info,
                                  isAdded: currentGroup?.symbols.contains(info.symbol) == true,
                                  selected: selectedSymbol == info.symbol,
                                  // Search is an external entry point, so it
                                  // lands on the instrument like a watchlist
                                  // row rather than on whatever page was open.
                                  onSelect: { selectedSymbol = info.symbol },
                                  onAdd: { add(info) })
                    }
                }
                .padding(.horizontal, 7).padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emptyState(_ key: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(PulseLocalization.localizedString(key))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        let searchQuery = normalizedQuery
        guard !searchQuery.isEmpty else {
            isSearching = false; searchError = nil; searchResults = []
            return
        }
        isSearching = true
        searchError = nil
        searchResults = []
        searchTask = Task { @MainActor in
            if !immediately { try? await Task.sleep(for: .milliseconds(280)) }
            guard !Task.isCancelled, searchQuery == normalizedQuery else { return }
            do {
                let results = try await appState.search(searchQuery)
                guard !Task.isCancelled, searchQuery == normalizedQuery else { return }
                searchResults = results
                searchError = nil
            } catch {
                guard !Task.isCancelled, searchQuery == normalizedQuery else { return }
                searchError = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func add(_ info: SymbolInfo) {
        guard let selectedGroupID else { return }
        appState.settings.recordRecentSearch(normalizedQuery)
        appState.sharedWatchlist.add(info, to: selectedGroupID)
        appState.engine.poke()
    }
}

private struct ResizeCursorHint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeCursorNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

private struct MainWatchRow: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let name: String
    let selected: Bool
    let action: () -> Void

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var tint: Color { appState.palette.color(for: quote?.change ?? 0) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(symbol.displayCode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 1)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(quote.map { PriceFormatter.price($0.price, market: symbol.market) } ?? "—")
                        .font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.primary)
                    Text(quote.map { PriceFormatter.percent($0.changePercent) } ?? "—")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(tint)
                }
                IntradaySparklineView(candles: appState.market.sparklines[symbol] ?? [],
                                      previousClose: quote?.previousClose, market: symbol.market, tint: tint)
                    .frame(width: 48, height: 25)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct SearchRow: View {
    let info: SymbolInfo
    let isAdded: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.resolvedDisplayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(info.symbol.displayCode).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(isAdded ? .secondary : Color.accentColor)
                    .frame(width: 25, height: 27)
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
            .help(PulseLocalization.localizedString("main.search.add"))
        }
    }
}
