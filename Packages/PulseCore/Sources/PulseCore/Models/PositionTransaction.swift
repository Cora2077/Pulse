import Foundation

/// A single position-changing event. The transaction list is the source of
/// truth for a holding; the current quantity, moving-average cost, and
/// realized P&L are all replayed from it (see `PositionLedger`).
public struct PositionTransaction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case buy
        case sell
        /// Overwrites the position with a target quantity and average cost
        /// ("I don't want to itemize — here is the result"). A negative
        /// target quantity calibrates a short. Produces no realized P&L.
        /// Quick-set edits and legacy cost lots land here.
        case adjustment
    }

    public var id: UUID
    public var kind: Kind
    /// Trade price per unit; for `.adjustment` the target average cost.
    public var price: Double
    /// Traded quantity; for `.adjustment` the target total quantity.
    public var quantity: Double
    /// User-facing trade date. Read as a calendar day in the user's own time
    /// zone everywhere (replay order, day P&L, chart markers, agent readback):
    /// the entry form records local midnight, a quick-set calibration keeps
    /// the time it was made, and an agent may send any instant — none of
    /// which may change which day the trade lands on or how it orders
    /// against other trades that day.
    public var date: Date
    /// Insertion timestamp; breaks replay-order ties between same-day entries.
    public var createdAt: Date
    /// Reserved for V1.5 (no UI yet).
    public var fee: Double?
    public var note: String?
    /// Immutable plan context captured when this user-reported fill was recorded.
    public var planExecution: TradePlanExecution?
    /// Optional post-trade notes. The transaction's `note` remains the
    /// execution reason; this records whether its plan was followed and what
    /// the user learned afterward.
    public var review: PositionTransactionReview?
    /// Which money actually bought this — the fill's own fact, not the plan's
    /// intent. A plan may have been written expecting margin and the user may
    /// have paid with their own cash; the portion this transaction creates
    /// inherits *this* value, never the plan's. `nil` on records written before
    /// the field existed; see `PositionFundingSource`.
    public var fundingSource: PositionFundingSource?

    public var hasValidFee: Bool { fee.map { $0.isFinite && $0 >= 0 } ?? true }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        price: Double,
        quantity: Double,
        date: Date = .now,
        createdAt: Date = .now,
        fee: Double? = nil,
        note: String? = nil,
        planExecution: TradePlanExecution? = nil,
        review: PositionTransactionReview? = nil,
        fundingSource: PositionFundingSource? = nil
    ) {
        self.id = id
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.date = date
        self.createdAt = createdAt
        self.fee = fee
        self.note = note
        self.planExecution = planExecution
        self.review = review
        self.fundingSource = fundingSource
    }
}

public struct TradePlanExecution: Codable, Sendable, Hashable {
    public var planID: UUID
    public var configuration: TradePlanConfiguration

    public init(planID: UUID, configuration: TradePlanConfiguration) {
        self.planID = planID
        self.configuration = configuration
    }
}

public struct PositionTransactionReview: Codable, Sendable, Hashable {
    public var followedPlan: Bool?
    public var retrospective: String?
    public var strategy: String?
    /// When the user next wants to look at this trade again, as a forward-looking
    /// checkpoint. Kept apart from `retrospective`, which records what already
    /// happened: one is a note to the future and the other a note about the
    /// past, and collapsing them would make "no plan yet" look like "reviewed".
    public var nextReviewDate: Date?
    /// What the user wants to check at `nextReviewDate`. Free text, and it may
    /// stand on its own without a date — "watch the next earnings" is a
    /// checkpoint even before a day is picked.
    public var nextReviewNote: String?

    public init(
        followedPlan: Bool? = nil,
        retrospective: String? = nil,
        strategy: String? = nil,
        nextReviewDate: Date? = nil,
        nextReviewNote: String? = nil
    ) {
        self.followedPlan = followedPlan
        self.retrospective = retrospective
        self.strategy = strategy
        self.nextReviewDate = nextReviewDate
        self.nextReviewNote = nextReviewNote
    }

    /// Whether this checkpoint carries at least one of its two fields. The
    /// empty review rule in `WatchlistStore.updateTransactionReview` reads
    /// this so a checkpoint-only edit is a real change rather than something
    /// normalized away to `nil`.
    var hasCheckpoint: Bool { nextReviewDate != nil || nextReviewNote != nil }

    /// Trims and validates the checkpoint fields, returning nil for anything
    /// unusable. A non-finite date or an over-long note is rejected whole so the
    /// caller can refuse the update instead of writing a half-applied one.
    func normalizedCheckpoint() -> Self? {
        var value = self
        if let date = value.nextReviewDate, !date.timeIntervalSince1970.isFinite { return nil }
        if let note = value.nextReviewNote {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            value.nextReviewNote = trimmed.isEmpty ? nil : trimmed
            if (value.nextReviewNote?.count ?? 0) > 4_000 { return nil }
        }
        return value
    }
}

/// Replays a transaction list into the current position using the
/// moving-weighted-average cost method. Quantity is signed: positive is a
/// long, negative a short (opened by selling first). On the long side buys
/// blend into the average cost and sells realize (price − average cost) ×
/// quantity; on the short side the roles mirror — sells blend into the
/// average short price and buys cover, realizing (average cost − price) ×
/// quantity. A trade crossing zero closes the open side first, then opens
/// the opposite side at the trade price with the remainder.
/// Which cost the position summary reports.
///
/// Both describe the same holding and agree on the total P&L — they only
/// disagree about which column the closed-out result sits in. The weighted
/// average keeps the purchase price and books a round trip as realized P&L;
/// the diluted cost nets it into the break-even price. Traders who work one
/// position intraday tend to expect the second, which is what their brokerage
/// shows.
public enum PositionCostBasis: String, Codable, CaseIterable, Sendable {
    case average
    case diluted

    /// Localization key for the picker entry and for the cost cell's own label.
    public var labelKey: String {
        switch self {
        case .average: "position.costBasis.average"
        case .diluted: "position.costBasis.diluted"
        }
    }
}

public struct PositionLedger: Sendable, Hashable {
    /// A transaction annotated with its replay outcome, in replay order.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var transaction: PositionTransaction
        /// P&L realized by this entry (sells closing a long, buys covering
        /// a short).
        public var realizedPnL: Double?
        public var resultingQuantity: Double
        public var resultingAverageCost: Double

        public var id: UUID { transaction.id }
    }

    public var entries: [Entry]
    /// Signed: positive units held long, negative units sold short.
    public var quantity: Double
    /// Moving-weighted-average entry price of the open side (long cost or
    /// short sale price); always non-negative.
    public var averageCost: Double
    /// Cost basis of the open position (quantity × average cost); negative
    /// for a short, where it represents the short-sale proceeds.
    public var costBasis: Double
    /// Cumulative realized P&L across all sells, surviving a flat position.
    public var realizedPnL: Double
    /// What the trades in `entries` cost in fees, added up. A calibration is
    /// not a trade and never contributes.
    public var totalFees: Double
    /// The break-even price for what is still held: every buy and every sell
    /// that led here, netted, over the remaining quantity.
    ///
    /// This is the cost a brokerage shows (often called the diluted or holding
    /// cost). It differs from `averageCost`, which keeps the original purchase
    /// price and books the closed-out result separately, so a round trip that
    /// makes money lowers this one and leaves `averageCost` alone. Both
    /// describe the same position and both add up to the same total P&L; they
    /// only disagree about which column the result belongs in.
    public var dilutedCost: Double

    public init(transactions: [PositionTransaction]) {
        var entries: [Entry] = []
        var quantity = 0.0
        var averageCost = 0.0
        var realizedPnL = 0.0
        var totalFees = 0.0
        var buyTurnover = 0.0
        var sellTurnover = 0.0

        for transaction in Self.replayOrdered(transactions) {
            var entryRealized: Double?
            switch transaction.kind {
            case .buy:
                let bought = max(transaction.quantity, 0)
                let fee = transaction.fee ?? 0
                if quantity >= 0 {
                    let newQuantity = quantity + bought
                    if newQuantity > 0 {
                        // The fee rides in the cost basis: what the position
                        // actually cost is the turnover plus what buying it was
                        // charged, so the average cost covers both.
                        averageCost = (averageCost * quantity + transaction.price * bought + fee) / newQuantity
                    }
                    quantity = newQuantity
                } else {
                    // Buying against a short covers first, realizing
                    // (average short price − buy price) × covered less what the
                    // covering trade was charged; anything past flat flips into
                    // a long opened at the trade price.
                    let covered = min(bought, -quantity)
                    let realized = (averageCost - transaction.price) * covered - fee
                    realizedPnL += realized
                    entryRealized = realized
                    quantity += bought
                    if quantity > 0 {
                        averageCost = transaction.price
                    } else if quantity == 0 {
                        averageCost = 0
                    }
                }
                totalFees += fee
                buyTurnover += transaction.price * bought + fee
            case .sell:
                let sold = max(transaction.quantity, 0)
                let fee = transaction.fee ?? 0
                if quantity > 0 {
                    // Selling closes the long first, realizing (price −
                    // average cost) × closed less what the sale was charged;
                    // anything past flat flips into a short opened at the
                    // trade price.
                    let closed = min(sold, quantity)
                    let realized = (transaction.price - averageCost) * closed - fee
                    realizedPnL += realized
                    entryRealized = realized
                    quantity -= sold
                    if quantity < 0 {
                        averageCost = transaction.price
                    } else if quantity == 0 {
                        averageCost = 0
                    }
                } else {
                    // Selling while flat or short opens/extends the short; the
                    // average blends the short entry prices, and a fee lowers
                    // what the short actually raised.
                    let short = -quantity + sold
                    if short > 0 {
                        averageCost = (averageCost * -quantity + transaction.price * sold - fee) / short
                    }
                    quantity = -short
                }
                totalFees += fee
                sellTurnover += transaction.price * sold - fee
            case .adjustment:
                quantity = transaction.quantity
                averageCost = quantity != 0 ? max(transaction.price, 0) : 0
                // A calibration replaces the history rather than adding to it,
                // so the diluted cost restarts from the calibrated basis
                // instead of carrying turnover the user has just overridden.
                buyTurnover = averageCost * quantity
                sellTurnover = 0
            }
            entries.append(Entry(
                transaction: transaction,
                realizedPnL: entryRealized,
                resultingQuantity: quantity,
                resultingAverageCost: averageCost
            ))
        }

        self.entries = entries
        self.quantity = quantity
        self.averageCost = averageCost
        self.costBasis = averageCost * quantity
        self.realizedPnL = realizedPnL
        self.totalFees = totalFees
        self.dilutedCost = quantity != 0 ? (buyTurnover - sellTurnover) / quantity : 0
    }

    public var hasOpenPosition: Bool { quantity != 0 }

    /// Chronological replay order: trade day first, insertion order breaking
    /// same-day ties so re-sorting never shuffles what the user entered.
    ///
    /// The trade date is compared as a calendar day in the user's zone, never
    /// as an instant. Same-day entries carry different times of day — the
    /// entry form dates trades at local midnight while a quick-set calibration
    /// keeps the time it was made — and comparing instants replayed a buy
    /// dated "today" ahead of a calibration made that morning, letting the
    /// calibration wipe it out.
    ///
    /// Two trades recorded back to back share both timestamps about three times
    /// in four — `Date.now` is not fine-grained enough to separate consecutive
    /// calls — so the final tie-break decides the order far more often than it
    /// looks. It has to be the position in the stored array, which is the order
    /// the user entered them in; ordering by `id` there sorted random UUIDs and
    /// shuffled the ledger roughly half the time it was consulted.
    public static func replayOrdered(
        _ transactions: [PositionTransaction],
        timeZone: TimeZone = .current
    ) -> [PositionTransaction] {
        transactions.enumerated()
            .map { offset, transaction in
                (day: CalendarDay(transaction.date, in: timeZone), transaction: transaction, offset: offset)
            }
            .sorted { lhs, rhs in
                if lhs.day != rhs.day {
                    return lhs.day < rhs.day
                }
                if lhs.transaction.createdAt != rhs.transaction.createdAt {
                    return lhs.transaction.createdAt < rhs.transaction.createdAt
                }
                return lhs.offset < rhs.offset
            }
            .map(\.transaction)
    }
}
