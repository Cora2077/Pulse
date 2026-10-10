import Foundation
import CryptoKit

/// One plan paired with the instrument that owns it.
///
/// Everywhere else in the app a plan is reached through its item, so a plan on
/// its own has no way to say which symbol it belongs to. The overview is
/// cross-symbol, so the pair travels together.
public struct TradePlanEntry: Identifiable, Hashable, Sendable {
    /// Display-only status; recorded fills and the decision to keep waiting are distinct.
    public enum DisplayState: CaseIterable, Hashable, Sendable {
        /// Still short of its size with nothing settled against it.
        case waiting
        /// Fully filled by real trades.
        case filled
        /// The user gave it up.
        case abandoned
        /// The user called it settled.
        case stopped
    }

    public let symbol: SymbolID
    public let plan: TradePlan
    public let filledQuantity: Double
    public let remainingQuantity: Double
    /// What the linked fills actually paid per unit, and when the last one
    /// landed. Both are read-only views of the same counted trades behind
    /// `filledQuantity`; neither is the plan's target price nor a quote.
    public let averageFillPrice: Double?
    public let lastFillDate: Date?
    /// Read-only board scope. The stored plan keeps its original id.
    public let accountID: BrokerageAccountID?

    /// Complete linked fills take precedence over a stale raw status.
    public var displayState: DisplayState {
        if remainingQuantity == 0, filledQuantity > 0 { return .filled }
        switch plan.status {
        case .cancelled: return .abandoned
        case .done: return .stopped
        case .active: return .waiting
        }
    }

    /// Whether this row may have an already-happened fill recorded straight
    /// into its history.
    ///
    /// A plan the user stopped carries no promise of a future trade, so the
    /// ordinary "record fill" route — which records against a live intention —
    /// has nothing to attach to. What it can still need is the opposite: the
    /// trade already happened, and the plan was closed before anyone wrote it
    /// down. Backfill is that one direction, and it is deliberately narrow.
    ///
    /// Three conditions, each of which rules out a different mistake:
    ///
    /// - The raw status must be `.done`. `.cancelled` plans are given up on,
    ///   and reviving one to file a fill is exactly the round trip this
    ///   entrance exists to avoid; an `.active` plan is not stopped at all, so
    ///   it takes the ordinary route rather than this one.
    /// - The derived state must be `.stopped`, which is what a `.done` plan
    ///   *with size left over* reads as. A fully filled row derives `.filled`
    ///   and has nothing to backfill — its record is already complete.
    /// - The payload must be the same one every write path requires, so a
    ///   malformed plan never becomes fillable just because it is stopped.
    ///
    /// This is a question, not a permission: the store repeats the status and
    /// completeness checks on its own values, so a caller that renders this
    /// button against a stale entry still cannot write through it.
    public var canBackfillFill: Bool {
        plan.status == .done
            && displayState == .stopped
            && remainingQuantity > 0
            && plan.hasValidPayload
    }

    /// The plan's own id, which is unique across the whole watchlist — the
    /// store refuses to persist a duplicate. Safe to use as a list identity.
    public var id: UUID {
        guard let accountID, accountID != .unassigned else { return plan.id }
        let bytes = Array(SHA256.hash(data: Data("\(accountID.rawValue)|\(plan.id.uuidString)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    public var remainingEstimatedAmount: Double { plan.price * remainingQuantity }
    public var remainingPlan: TradePlan {
        var remainder = plan
        remainder.quantity = remainingQuantity
        return remainder
    }

    public func remainingCostDelta(from price: Double) -> TradePlan.CostDelta? {
        var remainder = plan
        remainder.quantity = remainingQuantity
        return remainder.costDelta(from: price)
    }

    public init(symbol: SymbolID, plan: TradePlan, transactions: [PositionTransaction] = [], accountID: BrokerageAccountID? = nil) {
        self.symbol = symbol
        self.plan = plan
        self.accountID = accountID
        let progress = TradePlanExecutionProgress(plan: plan, transactions: transactions)
        self.filledQuantity = progress.filledQuantity
        self.remainingQuantity = progress.remainingQuantity
        self.averageFillPrice = progress.averageFillPrice
        self.lastFillDate = progress.lastFillDate
    }
}

/// Collects every plan in the watchlist into one ordered list, and counts them
/// for the entry point on the home page.
///
/// The current price arrives as a closure rather than a `Quote` so ordering and
/// counting stay testable without a market — the same reason
/// `TradePlan.isReached` takes a price instead of reading one. It also keeps the
/// two callers honest: the home chip and the overview page both ask the same
/// function for their numbers, so the badge can never disagree with the page it
/// opens.
///
/// Nothing here is persisted. The order is display-only: it is derived on every
/// render from the live quotes, so it can never feed back into storage and
/// trigger a sync round.
public enum TradePlanOverview {
    /// Which band a row sorts into. Reached first because that is the whole
    /// point of writing a plan down; settled last because it is a record, not
    /// something to act on.
    private enum Tier: Int, Comparable {
        case reached = 0
        case waiting = 1
        case settled = 2

        /// A raw-value enum does not pick up `<` on its own, and the ordering
        /// is the whole meaning of these cases, so it is spelled out.
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Every plan, in group order then storage order. Duplicated membership
    /// (one instrument tagged into two groups) contributes its plans once.
    public static func entries(from items: [WatchItem]) -> [TradePlanEntry] {
        items.flatMap { item in
            item.plans.map { TradePlanEntry(symbol: item.symbol, plan: $0, transactions: item.transactions) }
        }
    }

    /// Reached plans first, then the live ones closest to triggering, then
    /// settled ones.
    ///
    /// A symbol with no cached quote sorts with the waiting plans at the far
    /// end rather than with the reached ones: an unknown price is not the same
    /// as a price that got there. Ties keep input order, so a symbol's own
    /// plans stay in `TradePlan.ordered` order and the list does not reshuffle
    /// between refreshes.
    public static func ordered(
        _ entries: [TradePlanEntry],
        currentPrice: (SymbolID) -> Double?
    ) -> [TradePlanEntry] {
        entries
            .enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element, currentPrice: currentPrice)
                let right = rank(rhs.element, currentPrice: currentPrice)
                if left.tier != right.tier { return left.tier < right.tier }
                if left.gap != right.gap { return left.gap < right.gap }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Whether this row's price condition holds right now.
    ///
    /// Two questions, asked in the order that matters: the row must still be
    /// live, *and* the price must be there. A plan whose raw status is `active`
    /// but which real fills have already closed is not live, so it is never
    /// reported as reached — a finished plan sitting inside its band reads as a
    /// buy signal for a trade that no longer exists.
    public static func isReached(
        _ entry: TradePlanEntry,
        currentPrice: (SymbolID) -> Double?
    ) -> Bool {
        guard entry.displayState == .waiting else { return false }
        guard let price = currentPrice(entry.symbol) else { return false }
        return entry.plan.isReached(at: price)
    }

    /// What the home chip and the overview header both report.
    public struct Summary: Equatable, Sendable {
        /// Plans still waiting on a price condition, reached or not.
        public var live: Int
        /// The subset of `live` that already got there.
        public var reached: Int
        /// Plans marked done or cancelled.
        public var settled: Int

        public var total: Int { live + settled }

        public init(live: Int = 0, reached: Int = 0, settled: Int = 0) {
            self.live = live
            self.reached = reached
            self.settled = settled
        }
    }

    public static func summary(
        _ entries: [TradePlanEntry],
        currentPrice: (SymbolID) -> Double?
    ) -> Summary {
        var summary = Summary()
        for entry in entries {
            // Counted off `displayState` rather than the raw status, so the
            // header and the rows below it are the same list: an entry whose
            // status is stale counts as settled here exactly where the order
            // sorts it, and `reached` stays a subset of `live`.
            guard entry.displayState == .waiting else {
                summary.settled += 1
                continue
            }
            summary.live += 1
            if isReached(entry, currentPrice: currentPrice) {
                summary.reached += 1
            }
        }
        return summary
    }

    private static func rank(
        _ entry: TradePlanEntry,
        currentPrice: (SymbolID) -> Double?
    ) -> (tier: Tier, gap: Double) {
        // The live question is asked of the derived state, not `plan.status`:
        // otherwise a fully filled entry left `active` sorts into the reached
        // band and sits at the very top of the list, which is the one place a
        // reader is least likely to check whether the trade is still open.
        // Status is the fallback, not the answer: the derived state preserves
        // its verdict for every entry whose fills do not close it.
        guard entry.displayState == .waiting else { return (.settled, 0) }
        guard let price = currentPrice(entry.symbol) else { return (.waiting, .infinity) }
        if entry.plan.isReached(at: price) { return (.reached, 0) }
        return (.waiting, entry.plan.gapPercent(from: price))
    }
}
