import CryptoKit
import Foundation

/// The user's reason for holding a block of shares.
///
/// `observation` is **retired as a purpose**. Verification is a state a portion
/// carries (`TradePlanCondition`), not a pool, so nothing is ever *assigned* to
/// it again. The case survives because it is a Codable raw value: old snapshots,
/// history, and audit entries written by earlier builds must keep decoding, and
/// a build that dropped the case would fail to read the user's own records.
///
/// Everything that reads a purpose for a *calculation* goes through
/// `effectivePurpose`, which folds the retired value into `unassigned`. That is
/// deliberately a one-way read: the stored raw value is never rewritten by a
/// mere display, so an untouched legacy record round-trips byte for byte and a
/// migration that has not run yet still conserves its shares.
public enum PositionPool: String, Codable, CaseIterable, Sendable {
    case unassigned
    case strategic
    /// Retired purpose. Kept only so old payloads decode; never assigned again.
    /// Read it through `effectivePurpose`, never as an active destination.
    case observation
    case tactical

    /// The purposes a user may actually choose, in display order.
    ///
    /// The retired case is excluded on purpose: it must not appear in a picker,
    /// a projection row, or a distribution total, because none of those is a
    /// legacy *read*. Assignment paths validate against this list instead of
    /// `allCases`.
    public static let activeCases: [PositionPool] = [.unassigned, .strategic, .tactical]

    /// Whether this value may still be chosen as a destination or used as an
    /// active bucket. False only for the retired observation purpose.
    public var isActivePurpose: Bool { Self.activeCases.contains(self) }

    /// The purpose to use for calculation. The retired observation purpose has
    /// no active meaning, so it reads as `unassigned` — the record keeps its
    /// stored value, while every total, projection, and validation that asks
    /// this question treats those shares as simply unassigned rather than
    /// letting them vanish from an active-only distribution.
    public var effectivePurpose: PositionPool { isActivePurpose ? self : .unassigned }


}

/// Where the money behind a position or portion came from.
///
/// This is a user-maintained annotation, not a derived fact: nothing in the
/// ledger infers it, no price, quantity, cost, or P&L ever depends on it, and a
/// sale never repays the funding it consumed. It exists so a position can be
/// read as *own money* or *borrowed money* without that reading being smuggled
/// into the numbers.
///
/// A missing annotation and an explicit `unmarked` are deliberately different
/// states. `nil` means "this record predates the field" — an old archive, or a
/// portion nobody has classified — and a copy through a new build must carry it
/// forward unchanged rather than inventing a value. `unmarked` means the user
/// cleared the annotation on purpose, so it is a value to be preserved, not a
/// gap to be filled from history.
public enum PositionFundingSource: String, Codable, CaseIterable, Sendable {
    /// Explicitly cleared by the user. Distinct from `nil`, which is "unknown
    /// or never recorded".
    case unmarked
    /// The user's own capital.
    case own
    /// Borrowed capital (margin financing).
    case margin
}

public extension PositionFundingSource {
    /// Whether any record in `portions` carries a funding annotation.
    ///
    /// One predicate rather than one per codec: the archive and the sync wire
    /// format both have to decide "does this payload need the version that
    /// introduced the field", and a disagreement between them would let one
    /// path write a field the other silently drops on read.
    static func hasMetadata(in portions: [PositionPortion]) -> Bool {
        portions.contains { $0.fundingSource != nil }
    }
}

public struct PositionPortion: Codable, Hashable, Sendable, Identifiable {
    public struct Origin: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case snapshot
            case buy
        }

        public var kind: Kind
        public var transactionID: UUID?
        public var date: Date?
        public var price: Double?
        /// Original buy size, used to detect edits to the source trade after a split.
        public var quantity: Double?

        public init(
            kind: Kind,
            transactionID: UUID? = nil,
            date: Date? = nil,
            price: Double? = nil,
            quantity: Double? = nil
        ) {
            self.kind = kind
            self.transactionID = transactionID
            self.date = date
            self.price = price
            self.quantity = quantity
        }
    }

    public var id: UUID
    public var quantity: Double
    public var pool: PositionPool
    /// Which brokerage account this card belongs to, independent of the ledger
    /// the card happens to sit in.
    ///
    /// The same symbol can be held in two pools — two accounts — at once, so an
    /// account label has to live on the card rather than on the item. `nil` is
    /// the deliberate "inherit" value, not an unknown: a portion that predates
    /// the field belongs to whatever ledger encloses it, and a copy through a
    /// new build must carry the `nil` forward instead of guessing an owner.
    /// `.unassigned` is a real catalog value only when someone chose it.
    public var brokerageAccountID: BrokerageAccountID?
    public var origin: Origin
    public var note: String?
    /// Which money this portion was bought with. `nil` on records written
    /// before the field existed; see `PositionFundingSource`.
    public var fundingSource: PositionFundingSource?
    /// Why the user believes this block of shares should be held.
    ///
    /// This reuses the plan's condition type rather than inventing a second one:
    /// an actual position reasons about its holding with the same shape a plan
    /// reasons about an intention, and one type means `requiresReview`, the
    /// archive gates, and the badge derivation all have exactly one
    /// implementation. The array is optional for the same reason it is on a
    /// plan — `nil` is "this record predates the field" and `[]` is "the user
    /// cleared them", and the two must not be collapsed.
    public var conditions: [TradePlanCondition]?

    public init(
        id: UUID = UUID(),
        quantity: Double,
        pool: PositionPool = .unassigned,
        origin: Origin,
        note: String? = nil,
        fundingSource: PositionFundingSource? = nil,
        conditions: [TradePlanCondition]? = nil,
        brokerageAccountID: BrokerageAccountID? = nil
    ) {
        self.id = id
        self.quantity = quantity
        self.pool = pool
        self.brokerageAccountID = brokerageAccountID
        self.origin = origin
        self.note = note
        self.fundingSource = fundingSource
        self.conditions = conditions
    }
}

public extension PositionPortion {
    /// Whether this portion carries a verification condition array at all.
    ///
    /// An explicit empty array counts. It is the user saying "I cleared every
    /// condition", and a version gate that only looked for a non-empty array
    /// would let that choice be dropped by a reader that stops at the declared
    /// version.
    var hasVerificationMetadata: Bool { conditions != nil }

    /// Whether this portion was explicitly assigned a brokerage account.
    ///
    /// Only a non-nil label counts: `nil` is the deliberate "inherit the
    /// enclosing ledger" value that every record written before the field
    /// carries, so it is not metadata a version gate needs to protect. An
    /// explicit `.unassigned` is a chosen value and does count.
    var hasBrokerageTag: Bool { brokerageAccountID != nil }
}

public extension BrokerageAccountID {
    /// Whether any portion in `portions` carries an explicit account label.
    ///
    /// One predicate rather than one per codec: the archive and the sync wire
    /// format both have to decide "does this payload need the version that
    /// introduced the field", and a disagreement between them would let one
    /// path write a label the other silently drops on read.
    static func hasAccountTagMetadata(in portions: [PositionPortion]) -> Bool {
        portions.contains(where: \.hasBrokerageTag)
    }
}

public struct PositionAllocation: Codable, Hashable, Sendable {
    public struct Change: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case initialize
            case buy
            case transfer
            case reconcile
            case sourceInvalidated
            case restore
            /// The user annotated or cleared which money a portion came from.
            /// It moves no shares and is a separate kind from `transfer` so an
            /// undo can tell a pool move from a labelling change.
            case funding
            /// The user edited the conditions a portion is held against. Like
            /// `funding` it is metadata-only: no share, price, cost, or pool is
            /// touched, and it is a separate kind so an undo can tell it apart.
            case verification
            /// The user annotated which brokerage account a portion belongs to.
            /// Metadata only, and its own kind for the same reason `funding`
            /// has one: reclassifying a card's account is not a pool move, and
            /// an undo has to be able to tell the two apart.
            case account
        }

        public var id: UUID
        public var date: Date
        public var kind: Kind
        public var reason: String
        public var priorRevision: UUID?
        public var previousPortions: [PositionPortion]
        public var resultingPortions: [PositionPortion]

        public init(
            id: UUID = UUID(),
            date: Date = .now,
            kind: Kind,
            reason: String,
            priorRevision: UUID? = nil,
            previousPortions: [PositionPortion],
            resultingPortions: [PositionPortion]
        ) {
            self.id = id
            self.date = date
            self.kind = kind
            self.reason = reason
            self.priorRevision = priorRevision
            self.previousPortions = previousPortions
            self.resultingPortions = resultingPortions
        }
    }

    public var revision: UUID
    public var basisFingerprint: String
    public var portions: [PositionPortion]
    public var changes: [Change]

    public init(
        revision: UUID = UUID(),
        basisFingerprint: String,
        portions: [PositionPortion],
        changes: [Change] = []
    ) {
        self.revision = revision
        self.basisFingerprint = basisFingerprint
        self.portions = portions
        self.changes = changes
    }

    public var isValid: Bool {
        basisFingerprint.count == 64
            && basisFingerprint.allSatisfy { $0.isHexDigit }
            && Self.validPortions(portions)
            && changes.allSatisfy {
                $0.date.timeIntervalSince1970.isFinite
                    && !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && Self.validPortions($0.previousPortions)
                    && Self.validPortions($0.resultingPortions)
            }
    }

    /// Whether this allocation — current portions or any audit entry's before
    /// and after snapshots — carries a funding annotation.
    ///
    /// The change log is walked, not just `portions`: a portion whose
    /// annotation was cleared would leave the live array with nothing to
    /// detect, and a payload that dropped the change log's copy would rewrite
    /// history on the next merge.
    public var hasFundingMetadata: Bool {
        PositionFundingSource.hasMetadata(in: portions)
            || changes.contains {
                PositionFundingSource.hasMetadata(in: $0.previousPortions)
                    || PositionFundingSource.hasMetadata(in: $0.resultingPortions)
            }
    }

    /// Whether this allocation — current portions or any audit entry's before
    /// and after snapshots — carries a portion verification annotation.
    ///
    /// The change log is walked for the same reason `hasFundingMetadata` is: a
    /// user who clears every condition leaves the live array with nothing to
    /// detect, and dropping the change log's copy would rewrite history on the
    /// next merge or archive round trip. An explicit empty array is metadata, so
    /// it counts here even though it "contains" no conditions.
    public var hasVerificationMetadata: Bool {
        portions.contains(where: \.hasVerificationMetadata)
            || changes.contains { change in
                change.previousPortions.contains(where: \.hasVerificationMetadata)
                    || change.resultingPortions.contains(where: \.hasVerificationMetadata)
            }
    }

    /// Whether this allocation — current portions or any audit entry's before
    /// and after snapshots — carries an explicit brokerage-account label.
    ///
    /// The change log is walked for the same reason the other metadata
    /// predicates walk it: a card whose label was cleared leaves the live array
    /// with nothing to detect, and a payload that dropped the change log's copy
    /// would lose the attribution the user recorded. A `nil` label is the
    /// inherit value and is deliberately not metadata here, which is what keeps
    /// an untagged payload on its original version.
    public var hasBrokerageTagMetadata: Bool {
        BrokerageAccountID.hasAccountTagMetadata(in: portions)
            || changes.contains { change in
                change.kind == .account || BrokerageAccountID.hasAccountTagMetadata(in: change.previousPortions)
                    || BrokerageAccountID.hasAccountTagMetadata(in: change.resultingPortions)
            }
    }

    public static func basisFingerprint(for item: WatchItem) -> String {
        var value = "position-allocation-v1\n\(item.symbol.description)\n"
        for transaction in item.transactions {
            value += [
                transaction.id.uuidString,
                transaction.kind.rawValue,
                transaction.price.bitPattern.hexString,
                transaction.quantity.bitPattern.hexString,
                transaction.date.timeIntervalSinceReferenceDate.bitPattern.hexString,
                transaction.createdAt.timeIntervalSinceReferenceDate.bitPattern.hexString,
                transaction.fee?.bitPattern.hexString ?? "nil"
            ].joined(separator: "|") + "\n"
            // A correction to reported buy funding needs allocation review;
            // existing portion annotations may have been split independently.
            // Absent legacy fields leave the old fingerprint unchanged.
            if transaction.kind == .buy, let source = transaction.fundingSource {
                value += "funding|\(transaction.id.uuidString)|\(source.rawValue)\n"
            }
        }
        value += "lots\n"
        for lot in item.lots {
            value += [
                lot.id.uuidString,
                lot.price.bitPattern.hexString,
                lot.quantity.bitPattern.hexString,
                lot.date?.timeIntervalSinceReferenceDate.bitPattern.hexString ?? "nil"
            ].joined(separator: "|") + "\n"
        }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func quantityTolerance(_ values: Double...) -> Double {
        let scale = values.map(abs).max() ?? 0
        guard scale.isFinite, scale > 0 else { return 0 }
        return max(scale * 1e-12, scale.ulp * 4)
    }

    public func hasMatchingSources(for item: WatchItem) -> Bool {
        let entries = PositionLedger(transactions: item.transactions).entries
        for portion in portions {
            switch portion.origin.kind {
            case .snapshot:
                if let date = portion.origin.date,
                   entries.contains(where: { $0.transaction.kind == .adjustment && $0.transaction.createdAt > date }) {
                    return false
                }
            case .buy:
                guard let id = portion.origin.transactionID,
                      let entryIndex = entries.firstIndex(where: { $0.transaction.id == id }) else { return false }
                let entry = entries[entryIndex]
                guard entry.transaction.kind == .buy,
                      entry.transaction.price == portion.origin.price,
                      entry.transaction.quantity == portion.origin.quantity,
                      entry.transaction.date == portion.origin.date,
                      !entries.dropFirst(entryIndex + 1).contains(where: { $0.transaction.kind == .adjustment }) else {
                    return false
                }
            }
        }
        return isValid
    }

    private static func validPortions(_ portions: [PositionPortion]) -> Bool {
        var ids = Set<UUID>()
        var buyTotals: [UUID: Double] = [:]
        var buyOrigins: [UUID: PositionPortion.Origin] = [:]
        let valid = portions.allSatisfy { portion in
            guard ids.insert(portion.id).inserted,
                  Self.validConditions(portion.conditions),
                  portion.quantity.isFinite, portion.quantity > 0 else {
                return false
            }
            switch portion.origin.kind {
            case .snapshot:
                return portion.origin.transactionID == nil
                    && portion.origin.price == nil && portion.origin.quantity == nil
                    && (portion.origin.date.map { $0.timeIntervalSince1970.isFinite } ?? true)
            case .buy:
                guard let transactionID = portion.origin.transactionID,
                      let date = portion.origin.date,
                      let price = portion.origin.price,
                      let quantity = portion.origin.quantity else { return false }
                guard date.timeIntervalSince1970.isFinite && price.isFinite && price >= 0
                        && quantity.isFinite && quantity > 0 else { return false }
                if let existing = buyOrigins[transactionID], existing != portion.origin { return false }
                buyOrigins[transactionID] = portion.origin
                buyTotals[transactionID, default: 0] += portion.quantity
                return buyTotals[transactionID]?.isFinite == true
            }
        }
        guard valid else { return false }
        return buyTotals.allSatisfy { id, total in
            guard let quantity = buyOrigins[id]?.quantity else { return false }
            return total <= quantity + quantityTolerance(total, quantity)
        }
    }

    /// Whether a portion's condition array is a payload worth persisting.
    ///
    /// `nil` is a record that predates the field and is always acceptable. When
    /// an array is present every element must normalize cleanly — which is what
    /// rejects a blank title, an over-long note, or a malformed event reference
    /// — and hold a unique id. A payload that carried two conditions with one id
    /// has no well-defined edit target, so it is refused rather than repaired.
    static func validConditions(_ conditions: [TradePlanCondition]?) -> Bool {
        guard let conditions else { return true }
        var ids = Set<UUID>()
        return conditions.allSatisfy { condition in
            condition.normalized() == condition && ids.insert(condition.id).inserted
        }
    }
}

public enum PositionAllocationError: LocalizedError, Equatable {
    case itemNotFound(SymbolID)
    case notApplicable
    case missingAllocation
    case staleRevision(expected: UUID, actual: UUID)
    case needsReconciliation
    case invalidQuantity
    case quantityExceedsPortion
    case samePool
    case reasonRequired
    case unknownPortion(UUID)
    case unknownQuantity(UUID)
    case missingQuantity(UUID)
    case totalExceedsPosition
    case sourceQuantityExceeded
    case noSingleTransferToRestore
    case sameFundingSource
    case invalidConditions
    case tooManyConditions(limit: Int)
    /// A caller asked to clear a card's account label by passing the value it
    /// already inherits. `nil` and an explicit `.unassigned` are different
    /// states, so "make this card inherit again" has to be a real edit rather
    /// than silently landing on the same label.
    /// A caller asked to assign the retired observation purpose. Verification is
    /// a state a portion carries, not a pool, so the request is refused rather
    /// than silently creating a purpose the product no longer has. Folding it
    /// into `unassigned` behind the caller's back would be worse: they asked for
    /// a destination and would get a different one.
    case retiredPool

    public var errorDescription: String? {
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        return switch self {
        case .itemNotFound: chinese ? "找不到这项持仓。" : "Position not found."
        case .notApplicable: chinese ? "只有有效的多头持仓可以分账。" : "Allocation requires an open long position."
        case .missingAllocation: chinese ? "请先初始化仓位分账。" : "Initialize the position allocation first."
        case .staleRevision: chinese ? "分账已变化，请重新打开后再试。" : "The allocation changed. Reopen it and try again."
        case .needsReconciliation: chinese ? "请先核对剩余份额。" : "Reconcile the remaining shares first."
        case .invalidQuantity: chinese ? "数量必须是有限的正数，核对数量可填零。" : "Quantity must be finite and positive; reconciliation also accepts zero."
        case .quantityExceedsPortion: chinese ? "转移数量超过这张卡的份额。" : "Transfer quantity exceeds this portion."
        case .samePool: chinese ? "目标池与当前池相同。" : "Choose a different destination pool."
        case .reasonRequired: chinese ? "请填写变更原因。" : "Enter a reason for this change."
        case .unknownPortion, .unknownQuantity: chinese ? "这张份额卡已不存在，请刷新后重试。" : "This portion no longer exists. Refresh and try again."
        case .missingQuantity: chinese ? "请确认每张份额卡的数量。" : "Confirm a quantity for every portion."
        case .totalExceedsPosition: chinese ? "核对份额总数不能超过当前持仓。" : "Reconciled shares cannot exceed the current position."
        case .sourceQuantityExceeded: chinese ? "同一买入来源的核对份额不能超过原始买入数量。" : "Reconciled shares from a buy cannot exceed its original quantity."
        case .noSingleTransferToRestore: chinese ? "这笔转移已不能单独撤销。" : "This transfer can no longer be undone by itself."
        case .sameFundingSource: chinese ? "这张份额卡已经使用该资金来源。" : "This portion already uses that funding source."
        case .invalidConditions: chinese ? "持有判断无效：标题不能为空，且每条判断的编号必须唯一。" : "Invalid conditions: every condition needs a title and a unique id."
        case let .tooManyConditions(limit): chinese ? "持有判断最多 \(limit) 条。" : "At most \(limit) conditions are supported."
        case .retiredPool: chinese
            ? "「观察仓」已不再是一种用途，持有判断请写在份额的验证条件里。"
            : "The observation pool is no longer a purpose. Record conditions on the portion instead."
        }
    }
}

/// The single verification badge a card shows for a block of shares.
///
/// One enum, one derivation, shared by plans and by actual portions, so a sell
/// card and the shares it would consume cannot disagree about whether the
/// reasoning behind them still holds. Only the most demanding state is shown:
/// a reader glancing at a badge needs "is something wrong here", not a census.
public enum PositionVerificationBadge: String, Sendable, Equatable, CaseIterable {
    /// Conditions exist and the user has not confirmed them yet.
    case pending
    /// Every condition is confirmed and still stands.
    case confirmed
    /// A confirmed condition has come due, or the event it was linked to moved.
    case needsReview
    /// The reasoning was explicitly abandoned by the user.
    case invalidated

    /// The badge to render, or `nil` when there is nothing to say.
    ///
    /// `nil`/empty conditions return `nil`, because "no reasoning recorded" is
    /// not the same as "reasoning pending" — badging every untouched portion
    /// would make the badge meaningless. `invalidated` outranks everything: a
    /// user who abandoned the thesis should see that even if a sibling condition
    /// is merely pending. `needsReview` comes next, and is what a **confirmed**
    /// condition decays into once its own review date arrives or the event it
    /// was linked to changes — the same `requiresReview` verdict the plan
    /// surfaces use. No price is consulted anywhere here: a condition is about
    /// the user's reasoning, and a moving quote is not a change in reasoning.
    public static func derived(
        from conditions: [TradePlanCondition]?,
        at now: Date = .now,
        currentEvents: [InstrumentEvent] = []
    ) -> PositionVerificationBadge? {
        guard let conditions, !conditions.isEmpty else { return nil }
        if conditions.contains(where: { $0.state == .invalidated }) { return .invalidated }
        if conditions.contains(where: {
            $0.state == .needsReview || ($0.state == .confirmed && $0.requiresReview(at: now, currentEvents: currentEvents))
        }) {
            return .needsReview
        }
        return conditions.allSatisfy { $0.state == .confirmed } ? .confirmed : .pending
    }

}

extension WatchItem {
    public var positionAllocationNeedsReconciliation: Bool {
        let quantity = positionQuantity
        guard supportsPosition, quantity.isFinite, quantity > 0 else { return false }
        guard let positionAllocation else { return true }
        guard positionAllocation.isValid else { return true }
        guard positionAllocation.basisFingerprint == PositionAllocation.basisFingerprint(for: self) else {
            return true
        }
        guard positionAllocation.hasMatchingSources(for: self) else { return true }
        guard positionAllocation.portions.allSatisfy({ $0.quantity.isFinite && $0.quantity > 0 }) else {
            return true
        }
        let allocated = positionAllocation.portions.reduce(0) { $0 + $1.quantity }
        return !allocated.isFinite
            || abs(allocated - quantity) > PositionAllocation.quantityTolerance(allocated, quantity)
    }
}

/// How many shares of one position belong to one brokerage account, split by
/// the purpose pools the user already uses. `unassigned` is the ordinary
/// definition of that purpose in the pool quantities the rest of the app
/// carries (see `PoolBudgetProjection.Position`), not a statement about
/// account identity: strategic, tactical, and unassigned are the three values the
/// `PositionPool` catalog exposes after the retired observation purpose folds
/// into `unassigned`.
public typealias PositionPoolQuantities = [PositionPool: Double]

extension WatchItem {
    /// Attributes this position's shares to brokerage accounts.
    ///
    /// A portion's `brokerageAccountID` is the only source of a label; a `nil`
    /// one inherits `enclosingAccountID`, the ledger the item came out of. The
    /// derivation refuses to guess: unless the whole allocation is valid,
    /// matches this item's transaction digest, still points at its sources, and
    /// sums to the live position, the *entire* position is reported under
    /// `enclosingAccountID` with its real quantity. That keeps a stale or
    /// half-reconciled allocation from minting quantities for an account it
    /// cannot prove, while every share still appears exactly once.
    ///
    /// Returns an empty map for flat positions. Shorts retain their signed
    /// quantity under the enclosing account; positive allocations are not guessed.
    public func positionAccountAttribution(
        enclosingAccountID: BrokerageAccountID
    ) -> [BrokerageAccountID: PositionPoolQuantities] {
        let quantity = positionQuantity
        guard supportsPosition, quantity.isFinite, quantity != 0 else { return [:] }
        guard quantity > 0 else { return [enclosingAccountID: [.unassigned: quantity]] }
        guard !positionAllocationNeedsReconciliation,
              let allocation = positionAllocation,
              allocation.isValid,
              allocation.basisFingerprint == PositionAllocation.basisFingerprint(for: self),
              allocation.hasMatchingSources(for: self) else {
            return [enclosingAccountID: [.unassigned: quantity]]
        }

        var result: [BrokerageAccountID: PositionPoolQuantities] = [:]
        for portion in allocation.portions {
            let account = portion.brokerageAccountID ?? enclosingAccountID
            // A legacy card stored under the retired observation purpose reads
            // as `unassigned`, the same fold every other pool total uses.
            let pool = portion.pool.effectivePurpose
            result[account, default: [:]][pool, default: 0] += portion.quantity
        }
        return result
    }

    /// The same attribution with its pool splits flattened into one quantity per
    /// account, for a surface that only needs "how much is in this account".
    public func positionAccountQuantities(
        enclosingAccountID: BrokerageAccountID
    ) -> [BrokerageAccountID: Double] {
        positionAccountAttribution(enclosingAccountID: enclosingAccountID)
            .reduce(into: [:]) { totals, entry in
                totals[entry.key] = entry.value.values.reduce(0, +)
            }
    }
}

private extension UInt64 {
    var hexString: String { String(self, radix: 16) }
}
