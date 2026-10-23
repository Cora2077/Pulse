import Foundation
import PulseCore

/// Read-only quote projection for the current account's holdings (or its watchlist).
/// It preserves supplied order: ticking prices must not move a row underneath the pointer.
struct HoldingQuoteBoard {
    enum ReferenceState: Equatable {
        case current, delayed, reference, stale, missing
    }

    enum PlanSignal: Equatable {
        case none
        case waiting(Int)
        case reached(Int)
    }

    struct Row: Identifiable {
        let symbol: SymbolID
        let name: String
        let quote: Quote?
        let change: Double?
        let changePercent: Double?
        let referenceState: ReferenceState
        let planSignal: PlanSignal
        var id: SymbolID { symbol }
    }

    let rows: [Row]
    var reachedSymbolCount: Int {
        rows.filter { if case .reached = $0.planSignal { return true }; return false }.count
    }

    init(items: [WatchItem], entries: [TradePlanEntry], holdingsOnly: Bool,
         now: Date, quote: (SymbolID) -> Quote?) {
        var seen: Set<SymbolID> = []
        rows = items.filter { item in
            (!holdingsOnly || (item.supportsPosition && item.positionQuantity != 0))
                && seen.insert(item.symbol).inserted
        }.map { item in
            let supplied = quote(item.symbol)
            let valid = supplied.flatMap { value -> Quote? in
                guard value.symbol == item.symbol, value.price.isFinite, value.price > 0 else { return nil }
                return value
            }
            let sessionActive = TradingCalendar.isActive(item.symbol.market, at: now)
            let state: ReferenceState
            if let valid {
                if !sessionActive || valid.marketState == .closed {
                    state = .reference
                } else if !TradingQuoteHealth.isCurrent(valid, now: now) {
                    state = .stale
                } else {
                    state = (valid.sourceDelay ?? 0) > 0 ? .delayed : .current
                }
            } else {
                state = .missing
            }
            // The primary percentage is the quote's daily change, never holding P&L.
            // Quote.changePercent returns zero for a missing base; this surface must show unknown.
            let change = valid.flatMap { value -> Double? in
                guard value.previousClose.isFinite, value.previousClose > 0 else { return nil }
                let result = value.price - value.previousClose
                return result.isFinite ? result : nil
            }
            let percent = valid.flatMap { value -> Double? in
                guard let change else { return nil }
                let result = change / value.previousClose * 100
                return result.isFinite ? result : nil
            }
            let waiting = entries.filter {
                $0.symbol == item.symbol && $0.displayState == .waiting
                    && $0.plan.status == .active && $0.plan.price.isFinite && $0.plan.price > 0
                    && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0
            }
            // Use the same quote-health gate as the existing workbench. Closed, stale,
            // absent and future quotes remain readable, but cannot produce a reached badge.
            let reached: Int
            if sessionActive, let valid, TradingQuoteHealth.isCurrent(valid, now: now) {
                reached = waiting.filter { $0.plan.isReached(at: valid.price) }.count
            } else {
                reached = 0
            }
            let signal: PlanSignal = reached > 0 ? .reached(reached)
                : waiting.isEmpty ? .none : .waiting(waiting.count)
            return Row(symbol: item.symbol, name: item.resolvedDisplayName, quote: valid,
                       change: change, changePercent: percent, referenceState: state, planSignal: signal)
        }
    }
}
