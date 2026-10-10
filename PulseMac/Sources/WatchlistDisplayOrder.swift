import Foundation
import PulseCore

/// Presentation-only watchlist order. Leaves persisted `group.symbols` /
/// `manualOrder` alone.
///
/// The automatic modes below are read-only projections: they compute a display
/// sequence from live quotes without calling `SharedWatchlist.reorder`,
/// `rememberManualOrder`, or any other writer. A live quote update therefore
/// changes what the list *shows* and never what the store *holds*, which is why
/// reordering here cannot change `manualOrder`, dirty sync state, reset the
/// shared selection, or close a menu.
enum WatchlistDisplayOrder {
    // MARK: - Items (shared watchlist)

    /// The base sequence, optionally resolved through the automatic metric
    /// order and then the existing session blocks.
    ///
    /// - `groupID` defaults to the shared selection. Callers that own their own
    ///   group surface (the main sidebar) pass it explicitly so a change to the
    ///   shared selection cannot silently move their list.
    /// - `sortValue` is the automatic metric. When absent the manual/session
    ///   behavior is unchanged, so every existing call site keeps its exact
    ///   semantics. When present, rows are ordered pinned-first and descending
    ///   by metric, and equal/missing metrics keep base-relative order.
    ///
    /// Purely a read: nothing in this path writes to the watchlist, the store,
    /// or any preference.
    @MainActor
    static func items(
        from watchlist: SharedWatchlist,
        prioritizeOpenMarkets: Bool,
        at date: Date = .now,
        bypass: Bool = false,
        groupID: UUID? = nil,
        sortValue: ((WatchItem) -> Double?)? = nil
    ) -> [WatchItem] {
        let base = watchlist.items(in: groupID ?? watchlist.selectedGroupID)
        guard !bypass else { return base }
        let pinned = Set(watchlist.group(for: groupID ?? watchlist.selectedGroupID)?.pinnedSymbols ?? [])

        guard let sortValue else {
            // Manual order: nothing is added unless the session preference is on.
            guard prioritizeOpenMarkets, !base.isEmpty else { return base }
            return WatchlistSessionOrder.orderedItems(base, pinned: pinned, at: date)
        }

        let metricOrdered = WatchlistSortResolver.sortedSymbols(
            items: base,
            pinnedSymbols: Array(pinned),
            value: sortValue
        )
        let bySymbol = Dictionary(uniqueKeysWithValues: base.map { ($0.symbol, $0) })
        let ordered = metricOrdered.compactMap { bySymbol[$0] }
        guard prioritizeOpenMarkets, !ordered.isEmpty else { return ordered }
        return WatchlistSessionOrder.orderedItems(ordered, pinned: pinned, at: date)
    }

    // MARK: - Items (store)

    /// Store-backed variant. Kept verbatim (no automatic sort): its callers
    /// export a stored list, not a live surface.
    @MainActor
    static func items(
        from watchlist: WatchlistStore,
        prioritizeOpenMarkets: Bool,
        at date: Date = .now,
        bypass: Bool = false
    ) -> [WatchItem] {
        let base = watchlist.items
        guard prioritizeOpenMarkets, !bypass, !base.isEmpty else { return base }
        let pinned = Set(watchlist.selectedGroup?.pinnedSymbols ?? [])
        return WatchlistSessionOrder.orderedItems(base, pinned: pinned, at: date)
    }

    // MARK: - Automatic metric

    /// The sortable metric for one row, or `nil` when the row has none.
    ///
    /// Inherited verbatim from the popover's `WatchlistView.sortValue`, so both
    /// surfaces agree on what "Change %" or "Today's P&L" means. A position
    /// metric sums every physical record that actually holds a position across
    /// all ledgers; if any held record cannot be valued the whole row is nil
    /// rather than a partial number. Nothing here writes.
    @MainActor
    static func value(
        for item: WatchItem,
        option: WatchlistSortOption,
        appState: AppState
    ) -> Double? {
        guard let quote = appState.market.quote(for: item.symbol) else { return nil }
        if option == .changePercent {
            let change = quote.changePercent
            return change.isFinite ? change : nil
        }
        let held = appState.sharedWatchlist.records(for: item.symbol).filter { $0.hasPosition }
        guard !held.isEmpty else { return nil }
        let valuations = held.compactMap {
            PositionValuation(item: $0, quote: quote, basis: appState.settings.positionCostBasis)
        }
        guard valuations.count == held.count else { return nil }
        let value = valuations.reduce(0) { total, position in
            switch option {
            case .changePercent: return total
            case .todayPnL: return total + position.todayPnL
            case .totalPnL: return total + position.holdingPnL
            case .marketValue: return total + position.marketValue
            }
        }
        return value.isFinite ? value : nil
    }
}

/// Which order the watchlist is showing. Persisted per surface under
/// `pulse.watchlist.orderMode.v1` so the popover and the main sidebar agree.
enum WatchlistOrderMode: String {
    case manual
    case automatic
}

/// The automatic sort keys. Titles reuse the existing localized sort keys.
enum WatchlistSortOption: String, CaseIterable, Identifiable {
    case changePercent
    case todayPnL
    case totalPnL
    case marketValue

    var id: Self { self }

    var title: String {
        switch self {
        case .changePercent: PulseLocalization.localizedString("sort.changePercent")
        case .todayPnL: PulseLocalization.localizedString("sort.todayPnL")
        case .totalPnL: PulseLocalization.localizedString("sort.totalPnL")
        case .marketValue: PulseLocalization.localizedString("sort.marketValue")
        }
    }
}

/// Turns a list into the automatic display sequence. Pure: it reads a caller
/// supplied value closure and never touches the watchlist.
enum WatchlistSortResolver {
    /// Custom order: pinned symbols first in their pinned order, then the rest
    /// in their existing relative order.
    static func pinnedFirstSymbols(
        items: [WatchItem],
        pinnedSymbols: [SymbolID]
    ) -> [SymbolID] {
        let itemsBySymbol = Dictionary(uniqueKeysWithValues: items.map { ($0.symbol, $0) })
        let pinned = Set(pinnedSymbols)
        return pinnedSymbols.filter { itemsBySymbol[$0] != nil }
            + items.filter { !pinned.contains($0.symbol) }.map(\.symbol)
    }

    /// Pinned first, then descending by metric inside each of the pinned and
    /// unpinned sections. Each item's metric is read exactly once; a
    /// non-finite value is treated as missing; equal and missing metrics fall
    /// back to the item's base position, so the order is stable and total.
    static func sortedSymbols(
        items: [WatchItem],
        pinnedSymbols: [SymbolID],
        value: (WatchItem) -> Double?
    ) -> [SymbolID] {
        let pinned = Set(pinnedSymbols)
        let metrics = items.map { item -> Double? in
            guard let raw = value(item), raw.isFinite else { return nil }
            return raw
        }
        return items.enumerated().sorted { lhs, rhs in
            let leftIsPinned = pinned.contains(lhs.element.symbol)
            let rightIsPinned = pinned.contains(rhs.element.symbol)
            if leftIsPinned != rightIsPinned { return leftIsPinned }

            let left = metrics[lhs.offset]
            let right = metrics[rhs.offset]
            switch (left, right) {
            case let (left?, right?):
                if left == right { return lhs.offset < rhs.offset }
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map { $0.element.symbol }
    }
}
