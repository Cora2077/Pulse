import Foundation

/// The one place that answers "which ledger does this record belong to?".
///
/// A named account carries four different jobs that share one label — ledger
/// identity, a buy's destination, a plan's source, and a display tag — and the
/// bugs this type exists to stop all come from one of them silently standing in
/// for another. The rules below are deliberately small and stated once:
///
/// - a *new* buy must name a real account, and that resolved destination must
///   permit the funding the fill actually used. Checking the caller's argument
///   for `nil` is not the rule; `nil` means "the currently selected ledger",
///   which may itself be `.unassigned`.
/// - a *plan fill* always records the plan's own ledger as `sourceAccountID`,
///   including a same-account fill, so a later classification of either side
///   cannot silently reinterpret the link. Legacy records with no source stay
///   readable and are interpreted against the ledger they are found in.
/// - *classification* is an explicit mode the caller names: the whole ledger
///   travels with its plans and metadata, or exactly the selected trades travel
///   and the source keeps everything else. Nothing infers the mode from a count.
///
/// This is a boundary, not a migration. It never rewrites stored records it was
/// not asked to move, and it never guesses that an old `nil` meant a particular
/// broker.
public enum BrokerageOwnership {
    // MARK: - New purchases

    /// The ledger a new buy is written into, resolved from the caller's choice
    /// and the store's current selection. A `nil` request means the selected
    /// ledger, which is exactly why the caller's argument cannot be the check.
    ///
    /// Single-ledger mode predates named accounts, so it has exactly one ledger:
    /// omitting the destination is the normal path and is preserved, but *naming*
    /// a named account there is refused rather than written as a label no
    /// portfolio backs.
    public static func resolveBuyDestination(
        requested: BrokerageAccountID?,
        selected: BrokerageAccountID,
        accountsEnabled: Bool
    ) throws -> BrokerageAccountID {
        guard accountsEnabled else {
            guard requested == nil || requested == .unassigned else {
                throw TradePlanExecutionError.invalidBuyAccount
            }
            return selected
        }
        let destination = requested ?? selected
        guard destination != .unassigned else { throw TradePlanExecutionError.invalidBuyAccount }
        return destination
    }

    /// Whether the resolved destination may hold this purchase. Refused rather
    /// than downgraded: silently relabelling a margin buy as an ordinary one
    /// would invent a fact about the user's money.
    public static func validateBuyFunding(
        _ destination: BrokerageAccountID,
        fundingSource: PositionFundingSource?,
        accountsEnabled: Bool
    ) throws {
        guard accountsEnabled else { return }
        guard destination.permitsBuy(fundingSource: fundingSource) else {
            throw TradePlanExecutionError.invalidBuyMethod
        }
    }

    // MARK: - Sale execution

    /// The ledger a sale's fill is actually recorded in.
    ///
    /// A sale consumes shares that exist somewhere real, so it names the ledger
    /// holding them. Omitting the name means the plan's own ledger, which is the
    /// historical behaviour and stays the default. Naming one is a genuine
    /// cross-account execution — a plan not bound to a single portion card may
    /// be worked in another account — and it is resolved, not ignored: the
    /// requested ledger has to be real, and the pending-history ledger can never
    /// be where a *new* sale's shares came from.
    ///
    /// Single-ledger mode predates named accounts and keeps working untouched.
    public static func resolveSellDestination(
        requested: BrokerageAccountID?,
        planSource: BrokerageAccountID,
        accountsEnabled: Bool
    ) throws -> BrokerageAccountID {
        guard accountsEnabled else {
            guard requested == nil || requested == planSource || requested == .unassigned else {
                throw TradePlanExecutionError.invalidBuyAccount
            }
            return planSource
        }
        let destination = requested ?? planSource
        guard destination != .unassigned else { throw TradePlanExecutionError.invalidBuyAccount }
        return destination
    }

    // MARK: - Plan source references

    /// The ledger that owns the plan a fill was recorded against.
    ///
    /// A fill that names its source is believed. A legacy fill that does not is
    /// read against the ledger it is stored in — the old behaviour, kept because
    /// those records really did mean "wherever this lives".
    public static func planSourceAccount(
        for transaction: PositionTransaction,
        enclosingAccount: BrokerageAccountID
    ) -> BrokerageAccountID {
        transaction.planExecution?.sourceAccountID ?? enclosingAccount
    }

    /// Whether `transaction` belongs to `planID` owned by `source`, resolved
    /// against the ledger each record is found in.
    ///
    /// The two ways a fill can be linked are tried in the order that protects
    /// the explicit record:
    ///
    /// 1. A `planExecution` names both the plan and, once frozen, the source.
    ///    It is authoritative — its own source is never overridden by a legacy
    ///    field, and a fill whose reference names a *different* ledger cannot
    ///    be claimed by `source`.
    /// 2. Only when there is no `planExecution` at all may the owning plan's
    ///    explicit `filledTransactionID` be followed, and then the fill may sit
    ///    in any ledger: the plan's own id is what names it, not where it is
    ///    stored. A bare id links exactly one transaction, so this is a lookup,
    ///    never a second accounting rule.
    ///
    /// The two shapes are alternatives for the *same* record, never two
    /// candidates for one plan: a fill that already names a plan explicitly is
    /// never also counted through the legacy id. That is what keeps a modern
    /// fill and an old `filledTransactionID` fill from both being counted for a
    /// plan that has both, and it is also why a legacy id cannot reach a fill
    /// another plan already claims by name.
    ///
    /// No stored value is written, here or anywhere else: the plan's legacy id
    /// keeps pointing at the same trade it always did, and the fill gains no
    /// snapshot it never had.
    ///
    /// - Parameter owningPlan: the plan being counted, when the caller already
    ///   has it. `nil` asks only the `planExecution` question.
    public static func referencesPlan(
        _ transaction: PositionTransaction,
        planID: UUID,
        owningPlan: TradePlan?,
        source: BrokerageAccountID,
        enclosingAccount: BrokerageAccountID
    ) -> Bool {
        if let execution = transaction.planExecution {
            return execution.planID == planID
                && planSourceAccount(for: transaction, enclosingAccount: enclosingAccount) == source
        }
        guard let owningPlan, owningPlan.id == planID,
              owningPlan.filledTransactionID == transaction.id else { return false }
        let expectedKind: PositionTransaction.Kind = owningPlan.kind == .buy ? .buy : .sell
        return transaction.kind == expectedKind
    }

    /// Whether the plan's *own* legacy id names exactly this fill.
    ///
    /// This is the plural sibling of the second branch above, for the callers
    /// that read a whole ledger's fill pool rather than one plan: the id is
    /// followed only to a fill that carries no explicit reference of its own,
    /// and only when the plan is the one that names it. Asking the question in
    /// one place is what stops an explicit reference from being overridden by a
    /// legacy id that happens to point at the same trade.
    public static func legacyIDNames(
        _ transaction: PositionTransaction,
        owningPlan: TradePlan
    ) -> Bool {
        guard transaction.planExecution == nil,
              owningPlan.filledTransactionID == transaction.id else { return false }
        let expectedKind: PositionTransaction.Kind = owningPlan.kind == .buy ? .buy : .sell
        return transaction.kind == expectedKind
    }

    // MARK: - Classification requests

    /// How much of a ledger is being classified. The mode is stated by the
    /// caller and never guessed from how many trades happen to be left, so
    /// selecting the last remaining trade is still a selection.
    public enum ClassificationRequest: Sendable, Equatable {
        /// The instrument and everything attached to it travels, plans included.
        case wholeLedger
        /// Exactly these trades travel; the source keeps its plans and context.
        case selectedTrades(Set<UUID>)
        /// The trade ids a request moves, or `nil` when the whole ledger moves.
        public var transactionIDs: Set<UUID>? {
            switch self {
            case .wholeLedger: nil
            case .selectedTrades(let ids): ids
            }
        }
        /// Whether a whole ledger (and so its plans) is moving.
        public var movesWholeLedger: Bool {
            switch self {
            case .wholeLedger: true
            case .selectedTrades: false
            }
        }
    }

    /// Reads the legacy `transactionIDs` parameter as an explicit request.
    /// `nil` is the whole ledger and a set — even an empty one — is a selection,
    /// which keeps the old public signature behaving exactly as it did.
    public static func request(transactionIDs: Set<UUID>?) -> ClassificationRequest {
        transactionIDs.map(ClassificationRequest.selectedTrades) ?? .wholeLedger
    }

    /// A sale that is executed against a real ledger other than its plan's own.
    ///
    /// It carries the ledger whose shares are actually consumed. The plan is
    /// *not* moved and keeps its own ledger: only its progress and status are
    /// updated, and the fill records the plan's ledger as the origin of the
    /// reference. That is what makes one plan able to reduce positions in more
    /// than one account while still reading as a single plan.
    public struct SellExecution: Sendable, Equatable {
        /// The named ledger holding the shares this fill sells.
        public let account: BrokerageAccountID

        public init(account: BrokerageAccountID) {
            self.account = account
        }
    }

    // MARK: - Correcting an account label

    /// Whether two ledgers may take part in a correction of a record's real
    /// account.
    ///
    /// A correction is a *real ledger* move between two named accounts. It is
    /// refused when either end is the pending-history ledger: a new fact cannot
    /// be "this belongs to nobody", and unclassified history is not a source the
    /// user is correcting out of. The two ends also have to differ — asking to
    /// move a record to where it already is is not a correction, and silently
    /// treating it as one would bump a revision and append history for a no-op.
    public static func permitsAccountCorrection(from source: BrokerageAccountID,
                                                to destination: BrokerageAccountID) -> Bool {
        source != .unassigned && destination != .unassigned && source != destination
    }

    /// The ledger a *named* record claims for itself, or `nil` when it claims
    /// none.
    ///
    /// `transaction.brokerageAccountID` is the fill's own statement of the real
    /// account it was executed in. It is authoritative when present, which is why
    /// a named write goes to that account rather than being left as a label on a
    /// record accounted for somewhere else. `.unassigned` is not a name: it is
    /// the absence of one, so it reads as "no claim".
    public static func namedLedger(of transaction: PositionTransaction) -> BrokerageAccountID? {
        guard let account = transaction.brokerageAccountID, account != .unassigned else { return nil }
        return account
    }

    // MARK: - Classification validation

    /// Whether a destination that only supports ordinary purchases may receive
    /// these records.
    ///
    /// A record that explicitly says it was bought on margin is refused: the
    /// destination cannot represent it, and relabelling it ordinary would be a
    /// lie about the user's money. A record with no funding annotation is *not*
    /// evidence of margin, so unmarked and legacy `nil` records are allowed
    /// through untouched — refusing them would block exactly the old data this
    /// boundary exists to classify, and rewriting them would invent history.
    ///
    /// This is a rule about moving records, never a cleanup pass: nothing here
    /// changes a `nil` into `.own`.
    public static func permits(
        _ records: [PositionTransaction],
        in destination: BrokerageAccountID
    ) -> Bool {
        guard !destination.buyFundingSources.isEmpty else { return false }
        guard !destination.buyFundingSources.contains(.margin) else { return true }
        return !records.contains { $0.kind == .buy && $0.fundingSource == .margin }
    }

    /// Whether every portion card moving into `destination` is one the account
    /// can hold. A margin card needs an account that supports margin.
    public static func permits(
        _ portions: [PositionPortion],
        in destination: BrokerageAccountID
    ) -> Bool {
        guard !destination.buyFundingSources.isEmpty else { return false }
        guard !destination.buyFundingSources.contains(.margin) else { return true }
        return !portions.contains { $0.fundingSource == .margin }
    }

    // MARK: - Plan progress across a move

    /// One plan read out of a ledger: the name it is found under, the fills that
    /// ledger's copy of it currently accounts for, and the ledger it was read
    /// from.
    ///
    /// The two sides of a validation are both `ProgressRead` values, built by the
    /// same reader, so the pre-move and post-move numbers can only differ because
    /// the records differ — never because the two sides were asked differently.
    ///
    /// `account` records the ledger the reading was taken under, which is the
    /// caller's own diagnostic. It is deliberately not part of the reading's
    /// identity: a whole move is exactly a plan changing ledgers, so a reading
    /// that changed ledgers must still pair with the reading it continues. The
    /// store pairs the two sides itself, because only it knows which ledger each
    /// reading came from, and two different plans may legitimately reuse one
    /// symbol and id in two ledgers.
    ///
    /// The retired `tolerance` parameter is still accepted so callers written
    /// against it keep compiling; it is deliberately ignored. The comparison
    /// tolerance is derived from the two readings themselves, so a stored
    /// tolerance could only ever disagree with the rule it was meant to describe.
    public struct ProgressRead: Equatable, Sendable {
        /// The ledger this reading was taken under.
        public let account: BrokerageAccountID
        public let symbol: SymbolID
        public let planID: UUID
        public let filledQuantity: Double

        public init(account: BrokerageAccountID, symbol: SymbolID, planID: UUID,
                    filledQuantity: Double, tolerance: Double? = nil) {
            self.account = account
            self.symbol = symbol
            self.planID = planID
            self.filledQuantity = filledQuantity
        }

        /// The plan this reading is about: its symbol and its id. The ledger a
        /// reading was taken under is deliberately *not* part of the identity —
        /// a whole move is precisely a plan changing ledgers, so a reading that
        /// changed ledgers would otherwise never pair with the one it continues.
        /// Quantity is excluded too: two readings of the same plan differing
        /// only in fill count are exactly what the comparison is there to judge.
        public static func == (lhs: ProgressRead, rhs: ProgressRead) -> Bool {
            lhs.symbol == rhs.symbol && lhs.planID == rhs.planID
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(symbol)
            hasher.combine(planID)
        }
    }

    /// Whether `progress` is the same fill count as `reference`, for a plan the
    /// same size.
    ///
    /// The comparison is the ordinary quantity tolerance of the plan's own size,
    /// never exact equality: `TradePlanExecutionProgress` sums the same fills in
    /// a different order once they are read from another ledger, and a
    /// re-associated sum that lands a hair away from the original is the same
    /// progress, not a lost link.
    ///
    /// An infinite or negative reading is not a difference in degree and is
    /// never accepted: those are the values that would let a broken plan look
    /// complete. Whether a plan *completed* is checked by the caller against the
    /// stored plan, so this stays one question — did the linked quantity hold?
    public static func progressIsPreserved(_ progress: ProgressRead, since reference: ProgressRead) -> Bool {
        guard progress.filledQuantity.isFinite, reference.filledQuantity.isFinite,
              progress.filledQuantity >= 0, reference.filledQuantity >= 0 else { return false }
        return abs(progress.filledQuantity - reference.filledQuantity)
            <= PositionAllocation.quantityTolerance(progress.filledQuantity, reference.filledQuantity)
    }

    /// Whether a classification moved any moving plan's progress, by comparing
    /// the pre-move reading of every plan with its post-move reading.
    ///
    /// This is the semantic half of the commit check: the structural codec says
    /// the bytes are well-formed, and this says the links still *mean* what they
    /// meant. A plan that was filled before the move is filled after it, read
    /// under the ledger that should now hold it — so this catches both a fill
    /// that did not follow its plan and a plan that did not land where the
    /// ownership rules say it should.
    ///
    /// Both arrays must name the *same* set of plan placements, where a
    /// placement is the symbol, the plan id and the ledger the plan is read
    /// under. The caller states each side's placement, so a whole move is
    /// expressed as "this plan, now under the destination": the entry's ledger
    /// changes, the entry does not. Pairing on the full placement rather than on
    /// symbol + id alone is what keeps two different plans that reuse a UUID in
    /// two different ledgers from being merged into one progress figure — and a
    /// comparison that cannot tell those apart is not evidence that either one's
    /// links survived.
    ///
    /// A placement with no counterpart on the other side is answered `false`,
    /// and so is a side that carries a placement the other does not: a
    /// comparison this function cannot make is not evidence that the links
    /// survived, and accepting it would be exactly the silent break this check
    /// exists to catch.
    ///
    /// Whether every plan a classification touches kept its progress, judged
    /// from pairs the caller has already matched up.
    ///
    /// This is the form a store uses: it walks its ledgers, finds each plan, and
    /// states both readings of that one plan together — the reading before the
    /// move and the reading after it. Pairing is the caller's job because only
    /// the caller knows which ledger each reading came from, and two different
    /// plans may legitimately reuse a symbol and an id in two ledgers.
    ///
    /// Each pair is asked the same question as `planProgressIsPreserved`, so the
    /// rule about what counts as preserved lives in exactly one place.
    public static func planProgressIsPreserved(
        pairs: [(before: ProgressRead, after: ProgressRead)]
    ) -> Bool {
        pairs.allSatisfy { progressIsPreserved($0.after, since: $0.before) }
    }

    /// Two *different* plans may reuse the same symbol and id in two different
    /// ledgers; that is real data, not a mistake. A plan is therefore identified
    /// by symbol + id, and each reference entry is consumed exactly once, so two
    /// namesakes stay two separate comparisons rather than being merged into one
    /// figure. Callers that know which ledger each reading came from should
    /// prefer `planProgressIsPreserved(pairs:)`, which pairs them explicitly.
    public static func planProgressIsPreserved(
        expected: [ProgressRead],
        reference: [ProgressRead]
    ) -> Bool {
        guard expected.count == reference.count else { return false }
        var remaining = reference
        for progress in expected {
            guard let index = remaining.firstIndex(where: { $0 == progress }) else {
                return false
            }
            let before = remaining.remove(at: index)
            guard progressIsPreserved(progress, since: before) else { return false }
        }
        return remaining.isEmpty
    }
}
