import Foundation

/// One trade plan: how much to buy or sell at a given price.
///
/// A plan records an *intention*, never a fill. Whether its price condition
/// holds is derived from the live quote every time it is read (`isReached(at:)`)
/// and is deliberately not persisted: two Macs would otherwise each latch a
/// `triggered` flag on their own first sight of the price, writing a sync round
/// trip for something that is not a user edit at all.
///
/// Plans live inside `WatchItem`, next to `transactions`, so the three-way merge
/// that already reconciles trades reconciles these too.
public struct TradePlan: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case buy
        case sell
    }

    /// What the user decided about this plan. The market's opinion lives in
    /// `isReached(at:)`, not here.
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Still waiting for the price.
        case active
        /// The user acted on it.
        case done
        /// The user gave up on it.
        case cancelled
    }

    public var id: UUID
    public var kind: Kind
    /// Trigger price. A buy holds once the quote is at or below this; a sell
    /// holds once it is at or above.
    public var price: Double
    /// Always positive, in the instrument's own trading unit (shares/units).
    public var quantity: Double
    public var status: Status
    /// Why this price and this size. Free text, like `thesis`: nothing parses it.
    public var note: String?
    public var createdAt: Date
    /// Refreshed on every edit. The merge uses it as the last-write-wins
    /// tiebreak when both devices changed the same plan.
    public var updatedAt: Date
    /// The trade this plan produced, once one was recorded from it. Used only
    /// to pair the two up for display — a dangling id is treated as unfilled
    /// rather than cascading a deletion into the plan.
    public var filledTransactionID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        price: Double,
        quantity: Double,
        status: Status = .active,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        filledTransactionID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filledTransactionID = filledTransactionID
    }
}

public extension TradePlan {
    /// Whether the price condition holds at `current`. A buy is reached by
    /// falling to the plan price, a sell by rising to it. Equality counts as
    /// reached on both sides.
    func isReached(at current: Double) -> Bool {
        guard current > 0 else { return false }
        switch kind {
        case .buy: return current <= price
        case .sell: return current >= price
        }
    }

    /// How far the quote still has to move, in percent of the current price.
    /// Zero once the plan is reached — never negative, so "already there" and
    /// "overshot" read the same.
    func gapPercent(from current: Double) -> Double {
        guard current > 0 else { return 0 }
        let raw = switch kind {
        case .buy: (current - price) / current * 100
        case .sell: (price - current) / current * 100
        }
        return max(0, raw)
    }

    /// What the plan would cost (buy) or raise (sell) at its own price.
    var estimatedAmount: Double { price * quantity }

    /// Which way the live quote cuts against the plan's own price.
    ///
    /// Four cases rather than a sign, because "more money" is the wrong thing
    /// for a sell and the right thing for a buy. Spelling all four out here
    /// keeps the three surfaces that render this from each inventing their own
    /// rule — the whole point of a money figure is that it is comparable
    /// wherever you read it.
    enum CostTone: Sendable, Equatable, CaseIterable {
        /// A buy whose quote sits above the plan price.
        case paysMore
        /// A buy whose quote sits below the plan price.
        case paysLess
        /// A sell whose quote sits below the plan price.
        case earnsLess
        /// A sell whose quote sits above the plan price.
        case earnsMore

        /// The wording for this direction, kept beside the cases so a new tone
        /// cannot be added without one. Both the list surfaces and the chart tag
        /// read from here rather than each running its own four-way switch.
        public var localizationKey: String {
            switch self {
            case .paysMore: "plan.cost.paysMore"
            case .paysLess: "plan.cost.paysLess"
            case .earnsLess: "plan.cost.earnsLess"
            case .earnsMore: "plan.cost.earnsMore"
            }
        }

        /// The action the reader would take at the live quote, set in front of
        /// the sentence for the two directions that warn.
        ///
        /// A warning that only says "多花 ¥2,696" leaves the reader to work out
        /// which side of the trade it applies to; naming the action turns it
        /// into the decision itself. Only the adverse directions carry one,
        /// which is why this is optional rather than a fifth key on every tone:
        /// the good news reads fine without being told what to do. Kept beside
        /// the cases for the same reason as `localizationKey` — a new tone has
        /// to decide here whether it warns, rather than leaving it to a call
        /// site to remember.
        public var actionKey: String? {
            switch self {
            case .paysMore: "plan.cost.buyNow"
            case .earnsLess: "plan.cost.sellNow"
            case .paysLess, .earnsMore: nil
            }
        }

        /// Whether the quote has moved against the plan: the buy that now costs
        /// more, or the sell that now raises less. These are the two a reader
        /// wants to be told about, so they are also the two worth colouring.
        public var isAdverse: Bool {
            switch self {
            case .paysMore, .earnsLess: true
            case .paysLess, .earnsMore: false
            }
        }
    }

    /// The money between the live quote and the plan price, sized by the plan's
    /// own quantity. `gapPercent` answers the same question in percent; this
    /// answers it in the unit the decision is actually made in.
    struct CostDelta: Sendable, Equatable {
        /// How much money the difference is worth. Never negative — `tone`
        /// carries the direction so a caller can format the number and pick a
        /// label without re-deriving which way is which.
        public let amount: Double
        public let tone: CostTone

        public init(amount: Double, tone: CostTone) {
            self.amount = amount
            self.tone = tone
        }
    }

    /// How much more (or less) acting at the current quote costs versus acting
    /// at the plan price. Negative amounts are folded into `tone`, so the
    /// caller never has to know that a buy below its price is good news and a
    /// sell below its price is not.
    ///
    /// Returns nil when there is nothing to compare: no usable quote, a plan
    /// with no size attached, or a quote sitting exactly on the plan price —
    /// a zero difference has no tone and no money in it, so the caller falls
    /// back to the percentage alone rather than printing "0".
    func costDelta(from current: Double) -> CostDelta? {
        guard current.isFinite, current > 0,
              price.isFinite, price > 0,
              quantity.isFinite, quantity > 0 else { return nil }

        let difference = switch kind {
        case .buy: current - price
        case .sell: price - current
        }
        let signed = difference * quantity
        guard signed.isFinite, signed != 0 else { return nil }

        let tone: CostTone = switch (kind, signed > 0) {
        case (.buy, true): .paysMore
        case (.buy, false): .paysLess
        case (.sell, true): .earnsLess
        case (.sell, false): .earnsMore
        }
        return CostDelta(amount: abs(signed), tone: tone)
    }

    /// The one ordering the array is stored, rendered, and merged in.
    ///
    /// All three have to agree. Storing entry order while merging by id makes
    /// `applySyncSnapshot` see a difference on every pass and write the file
    /// again for nothing — the same fan-out the derived lot identity exists to
    /// avoid. Buys lead (they are the common case and read as a ladder from the
    /// nearest price down), then price descending, then id purely to break ties
    /// deterministically.
    static func ordered(_ plans: [TradePlan]) -> [TradePlan] {
        plans.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .buy }
            if lhs.price != rhs.price { return lhs.price > rhs.price }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
