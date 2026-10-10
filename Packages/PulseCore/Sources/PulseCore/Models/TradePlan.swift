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
    /// Intended holding bucket for the plan. This is metadata only; it never
    /// creates or changes a transaction.
    public var positionPool: PositionPool?
    /// Conditions are user-maintained; Pulse never assesses manual conditions.
    public var conditions: [TradePlanCondition]?
    /// Prior configurations, appended only by `WatchlistStore.setTradePlan`.
    public var history: [TradePlanRevision]?
    /// Which money the user *intends* to buy this plan with. Metadata only: it
    /// never creates a transaction and never overrides the funding a recorded
    /// fill actually reports. `.unmarked` is an explicit clearing.
    public var fundingSource: PositionFundingSource?
    /// The one existing position card this sell plan is tied to.
    ///
    /// `nil` is the ordinary, unbound plan — anything written before the field
    /// existed, and every plan whose size is not a claim on one specific card.
    /// A non-nil id is a *binding*, not a suggestion: the store refuses to
    /// record a fill whose source card has moved, been reduced, or vanished
    /// rather than quietly spending a sibling card, and it never invents a
    /// binding for a plan the user did not tie. Only a sell may carry one, and
    /// only against an explicitly named active pool.
    public var positionPortionID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        price: Double,
        quantity: Double,
        status: Status = .active,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        filledTransactionID: UUID? = nil,
        positionPool: PositionPool? = nil,
        conditions: [TradePlanCondition]? = nil,
        history: [TradePlanRevision]? = nil,
        fundingSource: PositionFundingSource? = nil,
        positionPortionID: UUID? = nil
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
        self.positionPool = positionPool
        self.conditions = conditions
        self.history = history
        self.fundingSource = fundingSource
        self.positionPortionID = positionPortionID
    }
}

public struct TradePlanCondition: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case logic, event, manual }
    public enum State: String, Codable, Sendable, CaseIterable { case pending, confirmed, needsReview, invalidated }

    public var id: UUID
    public var title: String
    public var kind: Kind
    public var state: State
    public var note: String?
    public var sourceURL: String?
    public var reviewDate: Date?
    /// An immutable snapshot of the one instrument event this condition is
    /// linked to, taken when the link was made. It is a copy rather than a
    /// reference because the event itself is user-editable and can be deleted:
    /// keeping the bytes the user linked to is what lets `requiresReview` tell
    /// an untouched link from one whose date, title, or kind has since moved.
    ///
    /// `nil` on conditions written before the field existed, and on conditions
    /// that simply are not linked to an event.
    public var eventReference: InstrumentEvent?

    public init(
        id: UUID = UUID(), title: String, kind: Kind, state: State = .pending,
        note: String? = nil, sourceURL: String? = nil, reviewDate: Date? = nil,
        eventReference: InstrumentEvent? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.state = state
        self.note = note
        self.sourceURL = sourceURL
        self.reviewDate = reviewDate
        self.eventReference = eventReference
    }

    func normalized() -> Self? {
        var value = self
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.note = value.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.note?.isEmpty == true { value.note = nil }
        value.sourceURL = value.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.sourceURL?.isEmpty == true { value.sourceURL = nil }
        if let linked = value.eventReference {
            guard let normalizedEvent = linked.normalized() else { return nil }
            value.eventReference = normalizedEvent
        }
        guard !value.title.isEmpty, value.title.count <= 240,
              value.note.map({ $0.count <= 4_000 }) ?? true,
              value.sourceURL.map(InstrumentEvent.isValidSourceURL) ?? true,
              value.reviewDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return nil }
        return value
    }

    /// Whether this condition still needs the user's attention at `now`.
    ///
    /// True when the user has not confirmed it, when its own review date has
    /// arrived, or when the event it was linked to is no longer the event it was
    /// linked to. The last case covers both a deleted event and an edited one:
    /// the snapshot keeps the bytes as of the link, so a changed `date`,
    /// `endDate`, `title`, or `kind` means the ground the reasoning stood on has
    /// moved. Metadata that does not change what the event *is* — its
    /// `updatedAt`, `note`, and `sourceURL` — is deliberately ignored, so
    /// tidying an event's annotation never reopens a settled condition.
    ///
    /// A linked event whose identity is absent from `currentEvents` is reported
    /// as missing rather than matched to a lookalike: guessing a replacement for
    /// a user's own event would silently confirm a link they never made. This is
    /// a read-only verdict — it never confirms, invalidates, or edits anything.
    public func requiresReview(at now: Date, currentEvents: [InstrumentEvent]) -> Bool {
        if state != .confirmed { return true }
        if let reviewDate, CalendarDay(reviewDate, in: .current) <= CalendarDay(now, in: .current) {
            return true
        }
        guard let reference = eventReference else { return false }
        guard let current = currentEvents.first(where: { $0.id == reference.id }) else { return true }
        return current.kind != reference.kind
            || current.date != reference.date
            || current.endDate != reference.endDate
            || current.title != reference.title
    }

    /// Whether this condition carries an event link a peer that understands the
    /// field would have to keep. Used by the archive and sync version gates.
    public var hasEventReference: Bool { eventReference != nil }
}

/// A nonrecursive plan configuration shared by revisions and execution records.
public struct TradePlanConfiguration: Codable, Sendable, Hashable {
    public var kind: TradePlan.Kind
    public var price: Double
    public var quantity: Double
    public var status: TradePlan.Status
    public var note: String?
    public var positionPool: PositionPool?
    public var conditions: [TradePlanCondition]?
    public var createdAt: Date
    /// The plan's intended funding at the moment this configuration was
    /// captured. Copied from the plan so a revision and a fill's immutable
    /// snapshot both answer "what was intended then" after the plan changes.
    public var fundingSource: PositionFundingSource?
    /// The position card this configuration was tied to, captured beside the
    /// pool and funding so a revision and a fill's immutable snapshot both
    /// answer "which shares was this written against" after the plan changes.
    public var positionPortionID: UUID?

    public init(plan: TradePlan) {
        kind = plan.kind
        price = plan.price
        quantity = plan.quantity
        status = plan.status
        note = plan.note
        positionPool = plan.positionPool
        conditions = plan.conditions
        createdAt = plan.createdAt
        fundingSource = plan.fundingSource
        positionPortionID = plan.positionPortionID
    }

    public static func hasFundingMetadata(in configurations: [TradePlanConfiguration]) -> Bool {
        configurations.contains { $0.fundingSource != nil }
    }

    /// Whether any configuration in the list carries a position-card binding.
    /// Checked beside the other metadata predicates so the archive and sync
    /// version gates ask one shared question instead of each walking the tree.
    public static func hasPositionPortionMetadata(in configurations: [TradePlanConfiguration]) -> Bool {
        configurations.contains { $0.positionPortionID != nil }
    }

    /// Whether any configuration in the list carries an event link, whether on
    /// its own conditions or nested in the conditions of a revision's
    /// configuration. Checked beside `hasFundingMetadata` so the archive and
    /// sync version gates ask one shared question instead of each walking the
    /// tree itself.
    public static func hasEventReference(in configurations: [TradePlanConfiguration]) -> Bool {
        configurations.contains { $0.conditions?.contains { $0.eventReference != nil } == true }
    }
}

/// Whether a plan carries an event link anywhere it can live: on its own
/// conditions, or on the conditions a revision captured.
public extension TradePlan {
    var hasFundingMetadata: Bool {
        fundingSource != nil
            || TradePlanConfiguration.hasFundingMetadata(in: (history ?? []).map(\.configuration))
    }

    /// Whether any of the plan's own conditions is linked to an instrument
    /// event.
    var hasEventReference: Bool {
        (conditions ?? []).contains { $0.eventReference != nil }
    }

    /// Whether an event link lives anywhere under this plan: its current
    /// conditions or a revision's configuration.
    var hasEventReferenceMetadata: Bool {
        hasEventReference
            || TradePlanConfiguration.hasEventReference(in: (history ?? []).map(\.configuration))
    }

    /// Whether a position-card binding lives anywhere under this plan: its own
    /// field, or a configuration a revision captured.
    ///
    /// The revisions are walked for the same reason the other metadata
    /// predicates walk them: a plan whose binding was cleared leaves the live
    /// field with nothing to detect, and a reader that stopped at the declared
    /// version would drop the record of which shares it was once written
    /// against.
    var hasPositionPortionMetadata: Bool {
        positionPortionID != nil
            || TradePlanConfiguration.hasPositionPortionMetadata(in: (history ?? []).map(\.configuration))
    }

    /// The single badge a plan card shows for its reasoning.
    ///
    /// Delegates to `PositionVerificationBadge.derived` so a plan and the
    /// portion shares it would consume read from one rule rather than two that
    /// drift. A plan has no `currentEvents` of its own: the caller passes the
    /// instrument's live events, exactly as the plan workflow surfaces do.
    func verificationBadge(
        at now: Date = .now,
        currentEvents: [InstrumentEvent] = []
    ) -> PositionVerificationBadge? {
        PositionVerificationBadge.derived(from: conditions, at: now, currentEvents: currentEvents)
    }
}

public extension TradePlanConfiguration {
    /// The same badge question asked of a captured configuration, so a fill's
    /// immutable snapshot can be read without rebuilding a `TradePlan`.
    func verificationBadge(
        at now: Date = .now,
        currentEvents: [InstrumentEvent] = []
    ) -> PositionVerificationBadge? {
        PositionVerificationBadge.derived(from: conditions, at: now, currentEvents: currentEvents)
    }
}

public extension TradePlanConfiguration {
    /// Whether this configuration's own conditions hold an event link. The
    /// fill snapshot and every revision use this one question rather than each
    /// spelling out the nested walk.
    var hasEventReferenceMetadata: Bool {
        (conditions ?? []).contains { $0.eventReference != nil }
    }

    /// Whether this configuration names a position card. Its own field only:
    /// a configuration has no history to walk.
    var hasPositionPortionMetadata: Bool { positionPortionID != nil }
}

public extension TradePlanExecution {
    /// Whether the immutable fill snapshot holds an event link in its
    /// conditions.
    var hasEventReferenceMetadata: Bool { configuration.hasEventReferenceMetadata }

    /// Whether the immutable fill snapshot names the card it consumed. A fill
    /// whose plan was later unbound still records which shares actually moved.
    var hasPositionPortionMetadata: Bool { configuration.hasPositionPortionMetadata }
}

public struct TradePlanRevision: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var date: Date
    public var configuration: TradePlanConfiguration

    public init(id: UUID = UUID(), date: Date = .now, configuration: TradePlanConfiguration) {
        self.id = id
        self.date = date
        self.configuration = configuration
    }
}

public struct TradePlanExecutionProgress: Sendable, Hashable {
    public let filledQuantity: Double
    public let remainingQuantity: Double
    public let hasLinkedTrades: Bool

    /// Quantity-weighted actual price from the same deduplicated linked fills.
    public let averageFillPrice: Double?

    /// The most recent date among the counted fills. `nil` when none was
    /// counted, and skipped for any transaction whose date is not finite —
    /// a broken date loses its claim on "latest" without dropping the trade
    /// from the quantity and price it does legitimately contribute to.
    public let lastFillDate: Date?

    public init(plan: TradePlan, transactions: [PositionTransaction]) {
        let expectedKind: PositionTransaction.Kind = plan.kind == .buy ? .buy : .sell
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counted = Set<UUID>()
        var total = 0.0
        var mean = 0.0
        var weightScale = 0.0
        var scaledWeight = 0.0
        var latestDate: Date?
        func add(_ transaction: PositionTransaction) {
            guard transaction.kind == expectedKind, transaction.quantity.isFinite, transaction.quantity > 0,
                  transaction.price.isFinite, transaction.price > 0,
                  counted.insert(transaction.id).inserted else { return }
            let next = total + transaction.quantity
            total = next.isFinite ? next : .greatestFiniteMagnitude
            // Normalize weights before adding them; price × quantity and even
            // the total quantity can overflow while their weighted mean is valid.
            if transaction.quantity > weightScale {
                scaledWeight *= weightScale / transaction.quantity
                weightScale = transaction.quantity
            }
            let weight = transaction.quantity / weightScale
            let combinedWeight = scaledWeight + weight
            let fraction = weight / combinedWeight
            if mean == 0 { mean = transaction.price }
            else if transaction.price >= mean {
                let updated = mean + (transaction.price - mean) * fraction
                mean = updated.isFinite ? updated : max(mean, transaction.price)
            } else { mean -= (mean - transaction.price) * fraction }
            scaledWeight = combinedWeight
            if transaction.date.timeIntervalSince1970.isFinite,
               latestDate.map({ transaction.date > $0 }) ?? true {
                latestDate = transaction.date
            }
        }

        for transaction in transactions where transaction.planExecution?.planID == plan.id {
            add(transaction)
        }
        if let legacyID = plan.filledTransactionID, !counted.contains(legacyID),
           let transaction = byID[legacyID] {
            add(transaction)
        }
        filledQuantity = total
        averageFillPrice = counted.isEmpty ? nil : mean
        lastFillDate = latestDate
        if plan.quantity.isFinite, plan.quantity > 0 {
            let remaining = max(0, plan.quantity - total)
            remainingQuantity = remaining <= PositionAllocation.quantityTolerance(plan.quantity, total) ? 0 : remaining
        } else {
            remainingQuantity = 0
        }
        hasLinkedTrades = !counted.isEmpty
    }

    public var isComplete: Bool { remainingQuantity == 0 && hasLinkedTrades }
}

public enum TradePlanExecutionError: LocalizedError, Equatable {
    case itemNotFound
    case planNotFound
    case unsupportedInstrument
    case invalidFill
    case invalidBuyAccount
    case invalidBuyMethod
    case duplicateTransactionID
    case stalePlan
    case staleAllocation
    case allocationNeedsReconciliation
    case historicalPoolSale
    case insufficientPoolQuantity(pool: PositionPool, requested: Double, available: Double)
    /// The sale could consume more than one funding source and the caller did
    /// not say which portions to reduce. Picking one would silently spend
    /// someone else's money, so the store refuses instead of guessing.
    case fundingSelectionRequired(available: [PositionFundingSource: Double])
    case invalidFundingSelection

    public var errorDescription: String? {
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        switch self {
        case .itemNotFound: return chinese ? "找不到这项持仓。" : "Position not found."
        case .planNotFound: return chinese ? "这项计划已不存在，请刷新后重试。" : "Trade plan no longer exists. Refresh and try again."
        case .unsupportedInstrument: return chinese ? "此品种不支持持仓交易。" : "This instrument does not support position trades."
        case .invalidFill: return chinese ? "成交价格、数量、费用或日期无效。" : "Fill price, quantity, fee, or date is invalid."
        case .invalidBuyAccount: return chinese ? "请先选择融资账户或萌萌账户。" : "Choose a financing or Mengmeng account first."
        case .invalidBuyMethod: return chinese ? "该账户不支持此买入方式；只有融资账户可以融资买入。" : "This buy method is unavailable for the account; margin buys require the financing account."
        case .duplicateTransactionID: return chinese ? "成交编号已被其他交易使用。" : "Transaction ID is already in use."
        case .stalePlan: return chinese ? "计划已变化，请刷新后重新记录成交。" : "Trade plan changed. Refresh before recording this fill."
        case .staleAllocation: return chinese ? "仓位用途或资金来源已变化，请重新选择卖出份额。" : "Position allocation or funding changed. Select the sale portions again."
        case .historicalPoolSale: return chinese ? "历史卖出无法直接扣减当前池份额，请从普通交易记录补录，再核对仓位分账。" : "A historical sale cannot consume today's pool shares. Record it as a regular trade, then reconcile the allocation."
        case .allocationNeedsReconciliation: return chinese ? "请先核对剩余份额，再记录这笔卖出。" : "Reconcile the position allocation before recording this sale."
        case let .insufficientPoolQuantity(pool, requested, available):
            if chinese {
                // The retired observation purpose has no active title: it has
                // already been folded into unassigned everywhere it is read, and
                // naming it here would resurrect a destination the product no
                // longer offers.
                let title: String
                switch pool.effectivePurpose {
                case .strategic: title = "战略底仓"
                case .tactical: title = "机动仓"
                case .unassigned, .observation: title = "未分配"
                }
                return "\(title)可用数量仅为 \(available)，不足以卖出 \(requested)。"
            }
            return "The \(pool.effectivePurpose.rawValue) pool has \(available) units; \(requested) were requested."
        case .fundingSelectionRequired:
            return chinese
                ? "这笔卖出会动用多种资金来源，请指定各份额的卖出数量。"
                : "This sale spans more than one funding source. Choose which portions to sell."
        case .invalidFundingSelection:
            return chinese
                ? "指定的卖出份额无效：数量必须为正数且不超过各份额，合计需等于成交数量。"
                : "The chosen sale portions are invalid: quantities must be positive, within each portion, and add up to the fill."
        }
    }
}

extension TradePlan {
    /// The one payload contract every write path shares: a plan whose price,
    /// size, timestamps, note, conditions, revisions, or position-card binding
    /// could not have been written is not a plan to act on either.
    var hasValidPayload: Bool {
        guard price.isFinite, price > 0, quantity.isFinite, quantity > 0,
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              (note.map { $0.count <= 4_000 } ?? true),
              Self.validConditions(conditions),
              (history.map(Self.validHistory) ?? true),
              Self.hasValidPositionPortionBinding(
                  kind: kind, positionPool: positionPool, positionPortionID: positionPortionID
              ) else { return false }
        return true
    }

    /// Whether a plan's position-card binding describes something the product
    /// can actually act on.
    ///
    /// A binding is a claim on one card of one pool, so it only makes sense on
    /// a sell whose pool is named *and* still an active destination: a plan
    /// tied to a card while claiming the retired observation purpose, or no
    /// pool at all, names no bucket the card could be read out of. A legacy
    /// plan without the field is untouched — the answer is asked only when a
    /// binding exists, so nothing old is ever defaulted to a card.
    static func hasValidPositionPortionBinding(kind: Kind, positionPool: PositionPool?, positionPortionID: UUID?) -> Bool {
        guard positionPortionID != nil else { return true }
        guard kind == .sell, let positionPool, positionPool.isActivePurpose else { return false }
        return true
    }

    /// Condition validity is asked through the allocation's one implementation:
    /// a portion's conditions and a plan's conditions are the same payload, and
    /// two validators would eventually disagree about one of them.
    private static func validConditions(_ conditions: [TradePlanCondition]?) -> Bool {
        PositionAllocation.validConditions(conditions)
    }

    private static func validHistory(_ history: [TradePlanRevision]) -> Bool {
        var ids = Set<UUID>()
        return history.allSatisfy { validRevision($0) && ids.insert($0.id).inserted }
    }

    private static func validRevision(_ revision: TradePlanRevision) -> Bool {
        let value = revision.configuration
        return revision.date.timeIntervalSince1970.isFinite
            && value.price.isFinite && value.price > 0
            && value.quantity.isFinite && value.quantity > 0
            && value.createdAt.timeIntervalSince1970.isFinite
            && (value.note.map { $0.count <= 4_000 } ?? true)
            && validConditions(value.conditions)
            // A revision is a configuration of this same plan, so the binding
            // it captured has to have been a legal one: a captured card on a
            // buy, or on a sell with no active pool, is not a plan the store
            // ever wrote.
            && hasValidPositionPortionBinding(
                kind: value.kind, positionPool: value.positionPool,
                positionPortionID: value.positionPortionID
            )
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
