import CryptoKit
import Foundation
import PulseCore

// MARK: - Revision stamps

/// The exact revision of one stored plan, frozen when a mobile draft was opened.
///
/// The Mac editor compares `updatedAt` and refuses a save when the plan moved.
/// `updatedAt` alone is a *timestamp*, not an identity: two edits inside the
/// same clock tick, or a peer that re-wrote the same values, can leave the
/// stamp unchanged while the payload differs. A mobile form is dismissed and
/// resumed across app launches, so it needs a check that survives being read
/// off disk months later.
///
/// The stamp is therefore both facts, and the store stays authoritative:
/// `updatedAt` is what `recordTradePlanFill` itself compares through
/// `expectedPlanUpdatedAt`, while the content digest catches everything that
/// route does not. Neither value is recomputed from a quote or from the plan's
/// own intent — the plan's intent is not a promise and must never stand in for
/// a stored record.
public struct PlanRevisionStamp: Codable, Sendable, Hashable {
    /// The plan's own `updatedAt`, as read from the store.
    public let updatedAt: Date
    /// SHA-256 over the plan's complete canonical encoding. See
    /// `PlanRevisionStamp.digest(of:)`.
    public let contentDigest: String

    public init(updatedAt: Date, contentDigest: String) {
        self.updatedAt = updatedAt
        self.contentDigest = contentDigest
    }

    /// Builds the stamp for a live plan. Callers never supply the digest.
    ///
    /// A plan whose canonical encoding cannot be produced yields the sentinel
    /// digest `Self.unencodableDigest`, which never equals a real digest — so
    /// `matches` fails closed instead of the stamp silently claiming a
    /// revision it could not actually take.
    public init(of plan: TradePlan) {
        self.updatedAt = plan.updatedAt
        self.contentDigest = Self.digest(of: plan)
    }

    public func matches(_ plan: TradePlan) -> Bool {
        // Fail closed before anything else: a stamp that could not take a real
        // revision must never match, or two unencodable plans would agree on the
        // sentinel and a frozen revision that does not exist would be honoured.
        guard contentDigest != Self.unencodableDigest else { return false }
        return updatedAt == plan.updatedAt && contentDigest == Self.digest(of: plan)
    }

    /// A digest that no successfully encoded plan can produce.
    ///
    /// It is not a valid SHA-256 hex string, so it can never collide with a
    /// real digest, and a stamp built from an unencodable plan never matches
    /// anything — including an identical unencodable plan. That is the
    /// fail-closed direction: a revision this layer could not read is a
    /// revision it must not claim to have frozen.
    public static let unencodableDigest = "<unencodable-plan>"

    /// SHA-256 over a **deterministic, complete** encoding of the whole plan.
    ///
    /// Completeness is the point. The previous implementation concatenated a
    /// hand-picked subset of fields with a separator, which had three holes:
    /// a field nobody remembered to add (the whole of `history`, plus every
    /// future field) was invisible to the digest; free-text fields could forge
    /// a separator and shift a boundary; and the condition list was re-sorted
    /// by id, so two different spellings of the same set could agree while a
    /// reordering the store *did* store went unnoticed.
    ///
    /// This encodes the plan with `JSONEncoder` using `sortedKeys`, so the key
    /// order is canonical regardless of declaration order, and hashes the
    /// resulting bytes. Every stored field is covered — including `history`,
    /// `updatedAt`, `createdAt`, and every nested field of a condition and its
    /// linked `InstrumentEvent` — because nothing is excluded by hand: the day
    /// `TradePlan` gains a field, that field is in the digest automatically.
    ///
    /// `sortedKeys` is what makes condition *order* significant, which is the
    /// honest reading: the store persists the array the user saved, so moving
    /// a condition is a real edit and must move the digest. (The encoder does
    /// not reorder arrays; only object keys are sorted.)
    ///
    /// Encoding is allowed to fail only if the value is genuinely not
    /// representable. When it does, `unencodableDigest` is returned and every
    /// comparison against it fails closed.
    public static func digest(of plan: TradePlan) -> String {
        guard let data = canonicalEncoding(of: plan) else { return unencodableDigest }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The canonical byte string a digest is taken over. Exposed so a test can
    /// assert on determinism itself rather than only on the hash it feeds.
    static func canonicalEncoding(of plan: TradePlan) -> Data? {
        let encoder = JSONEncoder()
        // Canonical object-key order: two encodings of equal values agree
        // byte-for-byte no matter how the type declares or synthesizes them.
        encoder.outputFormatting = [.sortedKeys]
        // Dates are the one field type whose default encoding depends on the
        // encoder's strategy rather than on the value, so it is pinned to the
        // instant. This keeps a re-encoded plan from a future default change
        // reading as a different revision.
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(plan)
    }
}

/// The exact revision of one stored transaction, frozen when a mobile edit
/// draft was opened.
///
/// `WatchlistStore.updateTransaction` takes an `expected` value and refuses a
/// write when the live record no longer equals it. That comparison is exact
/// equality on `PositionTransaction`, so freezing the whole value *is* the
/// stamp the store wants — and it is the only stamp that satisfies both the
/// state and the clock: a review edit, an ownership correction, or a sync merge
/// all change the value, and none of them necessarily change a date.
public struct TransactionRevisionStamp: Codable, Sendable, Hashable {
    /// The whole stored transaction, byte-for-byte as read.
    public let record: PositionTransaction

    public init(record: PositionTransaction) {
        self.record = record
    }

    public var id: UUID { record.id }
    public var kind: PositionTransaction.Kind { record.kind }

    public func matches(_ transaction: PositionTransaction) -> Bool {
        record == transaction
    }
}

// MARK: - Account freeze

/// The financial account a draft is allowed to write into, frozen at open time.
///
/// The store refuses a buy into an account that is not selected, but the
/// refusal arrives *after* the user has typed a price and a size, and it names
/// the wrong problem: the sheet was opened against one ledger and is being
/// submitted against another. Freezing the pair here lets the wrapper refuse
/// first, with a message about the account, and — because every refusal in this
/// module is non-throwing at the draft level — keep the user's input.
///
/// The ordering flag is part of the freeze because "brokerage accounts are
/// enabled" decides whether `.unassigned` is even a legal destination and how
/// the store reads a `nil` account. A draft opened before that setting flipped
/// must not silently acquire the new meaning.
public struct AccountFreeze: Codable, Sendable, Hashable {
    /// The ledger the draft was opened against.
    public let account: BrokerageAccountID
    /// Whether named ledgers were enabled when the draft was frozen.
    public let brokerageAccountsEnabled: Bool

    public init(account: BrokerageAccountID, brokerageAccountsEnabled: Bool) {
        self.account = account
        self.brokerageAccountsEnabled = brokerageAccountsEnabled
    }

    /// Whether this freeze still describes the store's live account state.
    ///
    /// A store that now has named ledgers cannot be written through a draft
    /// frozen when it did not, and vice versa: in both directions the stored
    /// transaction would land somewhere other than where the user was looking.
    @MainActor
    public func matches(_ store: WatchlistStore) -> Bool {
        store.activeBrokerageAccountID == account
            && store.brokerageAccountsEnabled == brokerageAccountsEnabled
    }

    /// Whether this freeze permits a write into `destination`.
    ///
    /// Without named ledgers the only lawful destination is `.unassigned`,
    /// because that is the single ledger such a store keeps. With them, a draft
    /// may name a different real ledger only when the user is explicitly
    /// choosing one — which is why `allowsNamed(_:)` exists separately and this
    /// method answers only the "is the draft still on its own ledger" question.
    public var isSelfConsistent: Bool {
        brokerageAccountsEnabled || account == .unassigned
    }

    /// Whether an explicitly named destination ledger is reachable at all.
    ///
    /// `.unassigned` is never a valid buy destination once named ledgers exist:
    /// it is the pending-history ledger, not an account a purchase can be filed
    /// into. `BrokerageOwnership.resolveBuyDestination` enforces the same rule;
    /// asking it here keeps the mobile form from offering the choice at all.
    public func allowsNamed(_ destination: BrokerageAccountID) -> Bool {
        brokerageAccountsEnabled && destination != .unassigned
    }
}

// MARK: - Kind bridging

/// The one text normalization this module applies wherever a draft's note is
/// compared with or written to the store: trimmed, empty collapses to `nil`.
/// Shared so a retry comparison can never disagree with the value a submit
/// would have written.
enum MobileDraftNormalization {
    static func note(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// A plan's side and a transaction's kind are separate enums in PulseCore —
/// a plan can only ever be a buy or a sell, while a transaction may also be an
/// adjustment. The mapping is written out rather than derived from matching raw
/// values: a raw-value cast would silently produce a nonsense kind the day
/// either enum gains a case.
public extension TradePlan.Kind {
    var transactionKind: PositionTransaction.Kind {
        switch self {
        case .buy: return .buy
        case .sell: return .sell
        }
    }
}

public extension PositionTransaction.Kind {
    /// The plan side this transaction kind corresponds to, or `nil` for an
    /// adjustment, which is a calibration and not a trade side at all.
    var planKind: TradePlan.Kind? {
        switch self {
        case .buy: return .buy
        case .sell: return .sell
        case .adjustment: return nil
        }
    }
}

// MARK: - Plan draft

/// A mobile plan form's frozen state.
///
/// This is the value a SwiftUI sheet holds across dismissal, app backgrounding,
/// and relaunch. It is deliberately *not* a `TradePlan`: assembling the stored
/// record is the wrapper's job, so a form cannot accidentally write a field it
/// never displayed, and the store's own migration and validation stay the only
/// authors of a stored plan.
public struct PlanDraft: Codable, Sendable, Hashable {
    /// The plan being edited, or `nil` for a new one.
    public let planID: UUID?
    public var symbol: SymbolID
    public var kind: TradePlan.Kind
    /// Trigger price. Never pre-filled from a quote — see `TradePlanDraftRules`.
    public var price: Double
    /// Always positive, in the instrument's own trading unit.
    public var quantity: Double
    public var note: String?
    public var conditions: [TradePlanCondition]
    /// `nil` means the plan never carried a pool; the form must preserve that
    /// rather than invent one from the instrument's position.
    public var positionPool: PositionPool?
    /// A sell plan's binding to one card. Never guessed.
    public var positionPortionID: UUID?
    /// The funding the user *intends*. Metadata only, and never substituted for
    /// a recorded fill's actual funding.
    public var fundingSource: PositionFundingSource?
    /// The ledger the user intends to execute in. A default, never a constraint.
    public var executionAccountID: BrokerageAccountID?
    /// The account/ordering context this draft was opened in.
    public let accountFreeze: AccountFreeze
    /// The stored plan this draft was opened from, when editing.
    public let revision: PlanRevisionStamp?
    /// The allocation revision a bound sell draft was built against.
    ///
    /// Only a bound sell reads the allocation, and only a bound sell can be
    /// invalidated by another sheet re-splitting the position. A draft that
    /// carries `nil` makes no allocation claim, exactly like an unbound plan.
    public let allocationRevision: UUID?
    /// The identity a *new* plan keeps across retries of the same draft.
    ///
    /// `planID` is `nil` for a new plan, so without this field every `save`
    /// would mint a fresh UUID — and a genuine retry of a create that already
    /// landed (the client crashed before seeing the answer) would file a
    /// second plan. `newPlan(symbol:in:)` mints it once; the draft carries it
    /// from then on, and `PlanWorkflow.save` writes the plan under it and
    /// adopts the landed plan on a retry instead of minting again.
    ///
    /// Editing drafts never use it: their identity is the stored plan's id and
    /// their guard is the frozen revision, which this idempotency must not
    /// bypass. Optional so drafts persisted by an older build still decode.
    public let newPlanID: UUID?

    public init(
        planID: UUID? = nil,
        symbol: SymbolID,
        kind: TradePlan.Kind,
        price: Double,
        quantity: Double,
        note: String? = nil,
        conditions: [TradePlanCondition] = [],
        positionPool: PositionPool? = nil,
        positionPortionID: UUID? = nil,
        fundingSource: PositionFundingSource? = nil,
        executionAccountID: BrokerageAccountID? = nil,
        accountFreeze: AccountFreeze,
        revision: PlanRevisionStamp? = nil,
        allocationRevision: UUID? = nil,
        newPlanID: UUID? = nil
    ) {
        self.planID = planID
        self.symbol = symbol
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.note = note
        self.conditions = conditions
        self.positionPool = positionPool
        self.positionPortionID = positionPortionID
        self.fundingSource = fundingSource
        self.executionAccountID = executionAccountID
        self.accountFreeze = accountFreeze
        self.revision = revision
        self.allocationRevision = allocationRevision
        self.newPlanID = newPlanID
    }

    public var isNew: Bool { planID == nil }

    /// Opens a new-plan draft against the store's live account state.
    ///
    /// The new plan's identity is minted here, once: every `save` of this draft
    /// writes — or, on a retry, adopts — the same plan, rather than minting a
    /// fresh UUID per attempt.
    @MainActor
    public static func newPlan(symbol: SymbolID, in store: WatchlistStore) -> PlanDraft {
        PlanDraft(
            symbol: symbol,
            kind: .buy,
            price: .nan,
            quantity: .nan,
            accountFreeze: AccountFreeze(account: store.activeBrokerageAccountID,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled),
            newPlanID: UUID()
        )
    }

    /// Opens an edit draft from the exact stored plan and the entry that
    /// describes it. Returns `nil` when the entry does not name an account,
    /// because an edit without a ledger has nothing to freeze and no route the
    /// store would accept.
    @MainActor
    public static func editing(_ entry: TradePlanEntry, in store: WatchlistStore) -> PlanDraft? {
        guard let account = entry.accountID else { return nil }
        let item = store.item(for: entry.symbol)
            ?? store.retainedHistoryItem(for: entry.symbol)
        return PlanDraft(
            planID: entry.plan.id,
            symbol: entry.symbol,
            kind: entry.plan.kind,
            price: entry.plan.price,
            quantity: entry.plan.quantity,
            note: entry.plan.note,
            conditions: entry.plan.conditions ?? [],
            positionPool: entry.plan.positionPool,
            positionPortionID: entry.plan.positionPortionID,
            fundingSource: entry.plan.fundingSource,
            executionAccountID: entry.plan.executionAccountID,
            accountFreeze: AccountFreeze(account: account,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled),
            revision: PlanRevisionStamp(of: entry.plan),
            allocationRevision: entry.plan.positionPortionID == nil ? nil : item?.positionAllocation?.revision
        )
    }
}

// MARK: - Fill draft

/// Which write route a fill draft takes.
///
/// These are not cosmetic labels. `recordFill` and `backfill` reach the same
/// store entry point with `historicalBackfill` flipped, but only `backfill` may
/// be submitted against a stopped plan; `unlinked` reaches a different entry
/// point entirely and can never create or move a plan link.
public enum FillIntent: String, Codable, Sendable, CaseIterable {
    /// An ordinary fill recorded against a live plan.
    case planFill
    /// A fact written down after the plan was already stopped.
    case planBackfill
    /// A standalone buy or sell with no plan behind it.
    case unlinked

    var historicalBackfill: Bool { self == .planBackfill }
}

/// A mobile fill form's frozen state.
///
/// The single most important property here is negative: `price` is never
/// derived. It is `nil` until the user types it, and no wrapper in this module
/// ever reads a quote, a plan's trigger, or a last-known price into it. The
/// store cannot enforce that — it only sees the number it is handed — so the
/// rule lives here, at the only place a mobile fill is assembled.
public struct FillDraft: Codable, Sendable, Hashable {
    public var symbol: SymbolID
    public var intent: FillIntent
    /// The plan this fill is filed against, for the two plan intents. `nil` for
    /// `.unlinked`, and required to be non-nil for the others.
    public let planID: UUID?
    public var kind: PositionTransaction.Kind
    /// `nil` until the user enters a real executed price. Never auto-filled.
    public var price: Double?
    /// `nil` until the user enters a real executed size. Never auto-filled.
    public var quantity: Double?
    public var date: Date
    public var fee: Double?
    public var note: String?
    /// The money that actually moved. Sent for a buy; a sale consumes portions
    /// instead of choosing a source, so it stays `nil` there.
    public var fundingSource: PositionFundingSource?
    /// The ledger the fill lands in, when the user named one explicitly.
    ///
    /// A buy names its destination; a sell names the ledger whose shares it
    /// consumed. Sending an explicit value is what keeps the form and the write
    /// agreeing after an account switch — `nil` means "whichever is selected",
    /// which is exactly the silent redirect this draft exists to prevent.
    public var destinationAccount: BrokerageAccountID?
    /// Only a genuinely mixed sale names its cards.
    public var salePortionQuantities: [UUID: Double]?
    /// The allocation the sale rows were drawn from, when portions are named.
    public var saleAllocationRevision: UUID?
    /// The plan revision this fill was checked against.
    public let planRevision: PlanRevisionStamp?
    /// The account/ordering context this fill was opened in.
    public let accountFreeze: AccountFreeze
    /// The transaction id this draft will submit under.
    ///
    /// Stable across retries: the wrapper mints it when the draft is created
    /// and reuses it on every submission, so a retry after a refusal re-uses the
    /// same id rather than minting a second one. Two genuinely independent
    /// same-price/same-size fills are two drafts and therefore two ids.
    public var transactionID: UUID

    public init(
        symbol: SymbolID,
        intent: FillIntent,
        planID: UUID? = nil,
        kind: PositionTransaction.Kind,
        price: Double? = nil,
        quantity: Double? = nil,
        date: Date = .now,
        fee: Double? = nil,
        note: String? = nil,
        fundingSource: PositionFundingSource? = nil,
        destinationAccount: BrokerageAccountID? = nil,
        salePortionQuantities: [UUID: Double]? = nil,
        saleAllocationRevision: UUID? = nil,
        planRevision: PlanRevisionStamp? = nil,
        accountFreeze: AccountFreeze,
        transactionID: UUID = UUID()
    ) {
        self.symbol = symbol
        self.intent = intent
        self.planID = planID
        self.kind = kind
        self.price = price
        self.quantity = quantity
        self.date = date
        self.fee = fee
        self.note = note
        self.fundingSource = fundingSource
        self.destinationAccount = destinationAccount
        self.salePortionQuantities = salePortionQuantities
        self.saleAllocationRevision = saleAllocationRevision
        self.planRevision = planRevision
        self.accountFreeze = accountFreeze
        self.transactionID = transactionID
    }

    /// Opens a fill draft from the entry the user tapped.
    ///
    /// `backfill` is *offered*, never decided: the draft carries the intent the
    /// caller chose, and the wrapper still re-derives whether the store would
    /// accept it. `price` is left empty on purpose.
    @MainActor
    public static func recording(
        _ entry: TradePlanEntry,
        in store: WatchlistStore,
        backfill: Bool = false,
        transactionID: UUID = UUID()
    ) -> FillDraft? {
        guard let account = entry.accountID else { return nil }
        // The funding default is the plan's stated *intention*, and only for a
        // buy. It is a starting value the user can change, never a validation
        // gate: the store's own comment is explicit that a plan's intent cannot
        // refuse a real trade. A sell never picks a source here.
        let funding = entry.plan.kind == .buy ? (entry.plan.fundingSource ?? .own) : nil
        return FillDraft(
            symbol: entry.symbol,
            intent: backfill ? .planBackfill : .planFill,
            planID: entry.plan.id,
            kind: entry.plan.kind.transactionKind,
            fundingSource: funding,
            destinationAccount: entry.plan.executionAccountID ?? account,
            planRevision: PlanRevisionStamp(of: entry.plan),
            accountFreeze: AccountFreeze(account: account,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled),
            transactionID: transactionID
        )
    }

    /// Opens a standalone fill draft with no plan behind it.
    @MainActor
    public static func unlinked(
        symbol: SymbolID,
        kind: PositionTransaction.Kind,
        in store: WatchlistStore,
        transactionID: UUID = UUID()
    ) -> FillDraft {
        FillDraft(
            symbol: symbol,
            intent: .unlinked,
            kind: kind,
            fundingSource: kind == .buy ? .own : nil,
            destinationAccount: kind == .buy ? nil : store.activeBrokerageAccountID,
            accountFreeze: AccountFreeze(account: store.activeBrokerageAccountID,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled),
            transactionID: transactionID
        )
    }

    /// Whether a stored record is *the event this draft already describes*.
    ///
    /// This is the idempotency question, and it is deliberately asked only
    /// after the id matched: a retry under the same `transactionID` is the same
    /// event, but "same id" alone proves nothing — an id can collide with a
    /// different trade. Every fact the fill actually states is compared, so the
    /// answer is "this exact event is already stored" rather than "some record
    /// reuses this id".
    ///
    /// It is never a price/quantity lookup. Two independent fills at the same
    /// price and size carry different ids and are never merged; a record that
    /// matches on price and size but not on the rest is a *different* event and
    /// is refused rather than adopted.
    ///
    /// Fields the draft does not own (`createdAt`, `review`) are not compared,
    /// because the caller never supplied them and the store is their author.
    /// The sale-portion selection is not stored on the record at all, so it is
    /// proven separately against the allocation history the sale produced —
    /// see `saleSelectionProven(by:)`, which the workflow consults alongside.
    public func describes(_ record: PositionTransaction) -> Bool {
        guard record.id == transactionID, record.kind == kind else { return false }
        guard let price, let quantity else { return false }
        guard record.price == price, record.quantity == quantity,
              record.date == date,
              record.fee == fee else { return false }
        // A buy states the money that moved; a sale states no source of its own
        // beyond the ledger it consumed, so the funding compared is exactly the
        // one this route would have written.
        guard record.fundingSource == submittedFundingSource else { return false }
        // The destination is a fact this draft states, and the store writes it
        // onto the record. A retry that names a different ledger is a different
        // event, so it must not be adopted. `.unassigned` and `nil` are one
        // value here: the store stores `nil` when named ledgers are off.
        guard storedDestination(record.brokerageAccountID) == storedDestination(submittedDestination)
        else { return false }
        // The note is a fact this draft states and the store writes, in its
        // normalized form; a stored record carrying a different one is not
        // this event.
        guard record.note == MobileDraftNormalization.note(note) else { return false }
        // The plan link is part of the event's identity. A standalone fill can
        // never adopt a plan-linked record, and a plan fill can never adopt a
        // record filed against a different plan or a different source ledger.
        switch intent {
        case .unlinked:
            guard record.planExecution == nil else { return false }
        case .planFill, .planBackfill:
            guard let planID, record.planExecution?.planID == planID else { return false }
            if let source = record.planExecution?.sourceAccountID {
                guard source == accountFreeze.account else { return false }
            }
        }
        return true
    }

    /// Whether the record's plan source agrees with the ledger this draft
    /// froze, resolved the store's own way: a record that names its source is
    /// believed, and one silent about it inherits the ledger it was found in.
    ///
    /// Called by the workflow's retry path, which knows the ledger the record
    /// was found in; `describes` alone cannot, because a record carries no
    /// symbol and may not carry a source.
    func sourceMatches(_ record: PositionTransaction,
                       enclosingAccount: BrokerageAccountID) -> Bool {
        guard intent != .unlinked, record.planExecution != nil else { return true }
        return BrokerageOwnership.planSourceAccount(for: record,
                                                    enclosingAccount: enclosingAccount)
            == accountFreeze.account
    }

    /// Whether the sale portions this draft names are provably the ones the
    /// stored sale consumed.
    ///
    /// The selection is not stored on the transaction itself, so the only
    /// honest proof is the allocation change the sale produced: the entry whose
    /// `priorRevision` is the frozen revision, read as a per-portion diff of
    /// the shares it moved. A draft that names no portions makes no claim and
    /// is always consistent with the record. A claim that cannot be
    /// demonstrated — the history entry is gone, or its diff disagrees — is
    /// treated as *not* the same event: adopting it would swear to an
    /// allocation nobody checked, which is worse than refusing a genuine retry.
    func saleSelectionProven(by item: WatchItem) -> Bool {
        guard let selection = salePortionQuantities else { return true }
        guard let revision = saleAllocationRevision,
              let allocation = item.positionAllocation,
              let change = allocation.changes.last(where: { $0.priorRevision == revision })
        else { return false }
        let resulting = Dictionary(change.resultingPortions.map { ($0.id, $0.quantity) },
                                   uniquingKeysWith: { first, _ in first })
        var consumed: [UUID: Double] = [:]
        for portion in change.previousPortions {
            let used = portion.quantity - (resulting[portion.id] ?? 0)
            if abs(used) > PositionAllocation.quantityTolerance(used, portion.quantity) {
                consumed[portion.id] = used
            }
        }
        guard consumed.count == selection.count else { return false }
        for (id, amount) in selection {
            guard let used = consumed[id],
                  abs(used - amount) <= PositionAllocation.quantityTolerance(used, amount)
            else { return false }
        }
        return true
    }

    /// The ledger a submission writes into, mirroring what `FillWorkflow.submit`
    /// passes down for each route.
    var submittedDestination: BrokerageAccountID {
        destinationAccount ?? accountFreeze.account
    }

    /// The record-side spelling of a destination: the store leaves the label
    /// `nil` in single-ledger mode and for `.unassigned`, and writes the real
    /// account otherwise.
    private func storedDestination(_ account: BrokerageAccountID?) -> BrokerageAccountID? {
        guard let account, account != .unassigned else { return nil }
        return account
    }

    /// The funding a submission writes, mirroring what `FillWorkflow.submit`
    /// passes down: a buy always states one, a sale states `nil`.
    var submittedFundingSource: PositionFundingSource? {
        guard kind == .buy else { return nil }
        return fundingSource ?? .own
    }
}

// MARK: - Transaction edit draft

/// A mobile transaction-edit form's frozen state.
///
/// The stored original travels inside the draft rather than being re-read at
/// submit time. That is what makes the store's own `expected` check meaningful:
/// a review edit made on another device between open and submit changes the
/// live record, the store sees a mismatch, and refuses — instead of the form
/// quietly overwriting review text the user never saw.
///
/// Fields the store refuses to change through this route — `kind` on a
/// plan-linked trade, `planExecution`, `createdAt`, `brokerageAccountID` — are
/// still carried, because the store compares them and the comparison must be
/// against the real values.
public struct TransactionEditDraft: Codable, Sendable, Hashable {
    /// The record as it was read, used as the store's `expected` stamp.
    public let original: TransactionRevisionStamp
    public var price: Double
    public var quantity: Double
    public var date: Date
    public var fee: Double?
    public var note: String?
    public var fundingSource: PositionFundingSource?
    public var review: PositionTransactionReview?
    public var symbol: SymbolID
    public let accountFreeze: AccountFreeze

    public init(
        original: TransactionRevisionStamp,
        symbol: SymbolID,
        price: Double,
        quantity: Double,
        date: Date,
        fee: Double? = nil,
        note: String? = nil,
        fundingSource: PositionFundingSource? = nil,
        review: PositionTransactionReview? = nil,
        accountFreeze: AccountFreeze
    ) {
        self.original = original
        self.symbol = symbol
        self.price = price
        self.quantity = quantity
        self.date = date
        self.fee = fee
        self.note = note
        self.fundingSource = fundingSource
        self.review = review
        self.accountFreeze = accountFreeze
    }

    /// Opens an edit draft from a live transaction.
    @MainActor
    public static func editing(
        _ transaction: PositionTransaction,
        symbol: SymbolID,
        account: BrokerageAccountID,
        in store: WatchlistStore
    ) -> TransactionEditDraft {
        TransactionEditDraft(
            original: TransactionRevisionStamp(record: transaction),
            symbol: symbol,
            price: transaction.price,
            quantity: transaction.quantity,
            date: transaction.date,
            fee: transaction.fee,
            note: transaction.note,
            fundingSource: transaction.fundingSource,
            review: transaction.review,
            accountFreeze: AccountFreeze(account: account,
                                         brokerageAccountsEnabled: store.brokerageAccountsEnabled)
        )
    }

    /// The candidate record to hand the store, rebuilt from the frozen original
    /// so that every field this form does not own is carried through unchanged.
    ///
    /// The metadata fields are the form's own statements: this draft is opened
    /// from the stored record with every one of them, so a `nil` here is the
    /// user *clearing* a value, not the form failing to carry one — which is
    /// why `save` passes `replaceOptionalMetadata: true` rather than letting
    /// the store refill cleared fields from the original. Funding is the one
    /// exception with a dedicated spelling: clearing it stores `.unmarked`
    /// ("the user says this is unclassified"), because `nil` reads as "nobody
    /// has said anything" and must not be passed off as a new fact.
    public var candidate: PositionTransaction {
        var record = original.record
        record.price = price
        record.quantity = quantity
        record.date = date
        record.fee = fee
        record.note = note
        if let fundingSource {
            record.fundingSource = fundingSource
        } else if original.record.fundingSource != nil {
            record.fundingSource = .unmarked
        } else {
            record.fundingSource = nil
        }
        record.review = review
        return record
    }
}

// MARK: - Review draft

/// A post-trade review edit, kept apart from ledger values.
///
/// `WatchlistStore.updateTransactionReview` writes only the note and the
/// review, and it answers `Bool` rather than throwing. Splitting it from the
/// value edit is deliberate: correcting a price and writing down what you
/// learned are different acts, and a store that conflated them would let a
/// review save rewrite a trade's numbers.
///
/// The draft freezes the exact record it was opened from, because the store's
/// own review route addresses the record by *id alone* — it re-reads whatever
/// is stored now and overwrites its note and review. Without an expected value
/// a form that sat in the background would silently overwrite a review another
/// device wrote in the meantime, which is the same stale-write hazard the value
/// edit route already refuses. The frozen record is what lets `saveReview`
/// refuse instead, and hand the user's text back.
public struct ReviewDraft: Codable, Sendable, Hashable {
    public var symbol: SymbolID
    public var transactionID: UUID
    public var note: String?
    public var review: PositionTransactionReview?
    /// The stored record as it was read, used as the staleness stamp.
    ///
    /// Optional so a caller that genuinely does not have the record can still
    /// build a draft; `saveReview` refuses such a draft rather than writing
    /// blind (see `TransactionWorkflow.saveReview`).
    public var expected: TransactionRevisionStamp?

    public init(symbol: SymbolID, transactionID: UUID,
                note: String? = nil, review: PositionTransactionReview? = nil,
                expected: TransactionRevisionStamp? = nil) {
        self.symbol = symbol
        self.transactionID = transactionID
        self.note = note
        self.review = review
        self.expected = expected
    }

    /// Opens a review draft from the exact record it will write back to.
    @MainActor
    public static func editing(
        _ transaction: PositionTransaction,
        symbol: SymbolID
    ) -> ReviewDraft {
        ReviewDraft(
            symbol: symbol,
            transactionID: transaction.id,
            note: transaction.note,
            review: transaction.review,
            expected: TransactionRevisionStamp(record: transaction)
        )
    }
}

// MARK: - Refusals

/// Every way a mobile workflow can refuse without writing.
///
/// Two families live here and they are kept apart on purpose:
///
/// * `.unsupported*` is an honest "this build does not wrap that path yet".
///   The task that produced this module requires that an unwrappable route
///   return a specific error rather than approximating the store's rules.
/// * everything else is a real refusal the user can act on.
public enum MobileWorkflowError: LocalizedError, Equatable, Sendable {
    /// The store does not track this instrument, or does not consider it
    /// position-bearing.
    case itemNotFound(SymbolID)
    /// The plan is gone from the store.
    case planNotFound(UUID)
    /// The draft's frozen plan revision no longer matches the stored plan.
    case stalePlanRevision(UUID)
    /// The draft's frozen transaction no longer matches the stored record.
    case staleTransactionRecord(UUID)
    /// A submission reused a stored record's id but describes a *different*
    /// event. The id is not evidence that this is a retry, so the write is
    /// refused rather than adopting somebody else's record or minting a
    /// colliding one.
    case conflictingRetry(UUID)
    /// The draft was opened in one account/ordering state and the store is in
    /// another.
    case accountChanged(expected: BrokerageAccountID, actual: BrokerageAccountID)
    /// Named ledgers were enabled or disabled after the draft was opened.
    case accountModeChanged
    /// The draft's frozen account cannot write at all (e.g. `.unassigned` while
    /// named ledgers are on).
    case accountUnavailable(BrokerageAccountID)
    /// The named destination ledger is not one a buy may be filed into.
    case destinationNotAllowed(BrokerageAccountID)
    /// The funding this draft reports is not one the destination accepts. The
    /// store would refuse it too; refusing here keeps the message about the
    /// field the user can change.
    case fundingNotAllowed(account: BrokerageAccountID, funding: PositionFundingSource)
    /// The user has not entered a real executed price, and this module will not
    /// invent one from the plan or a quote.
    case fillPriceRequired
    /// The user has not entered a real executed size.
    case fillQuantityRequired
    /// A price, size, fee, or date that no ledger can accept.
    case invalidFillValues
    /// A plan-scoped intent arrived without a plan.
    case planRequired(FillIntent)
    /// A standalone intent arrived with a plan attached.
    case planNotAllowed(FillIntent)
    /// The draft's own kind does not match the plan it names.
    case kindMismatch(plan: TradePlan.Kind, draft: PositionTransaction.Kind)
    /// The plan is not in a state that accepts this intent.
    case planNotRecordable(status: TradePlan.Status, intent: FillIntent)
    /// A sale named cards that the draft did not also pin a revision for, or
    /// named a partial selection that cannot cover the fill.
    case saleSelectionIncomplete
    /// The allocation revision a sale draft was built against has moved.
    case staleAllocationRevision
    /// The record cannot be edited or deleted through a checked route.
    case transactionNotFound(UUID)
    /// A plan-linked trade may not change side through an edit.
    case immutablePlanContext
    /// An edit would create or worsen a negative historical position.
    case negativePosition
    /// The store refused for a reason this module does not translate, and the
    /// underlying description is carried through rather than flattened.
    case storeRejected(String)
    /// A route this build does not wrap. The associated value names it
    /// precisely so a caller can tell "not built yet" from "refused".
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .itemNotFound(symbol):
            return "The store does not track \(symbol.code) as a position-bearing instrument."
        case let .planNotFound(id):
            return "Plan \(id.uuidString) is no longer in the store."
        case .stalePlanRevision:
            return "This plan changed after the form was opened. Nothing was written; reopen it to see the current plan."
        case .staleTransactionRecord:
            return "This trade changed after the form was opened. Nothing was written; reopen it to see the current record."
        case let .conflictingRetry(id):
            return "Trade \(id.uuidString) is already stored with different values, so this is not a retry of it. Nothing was written; review the stored trade or start a new entry."
        case let .accountChanged(expected, actual):
            return "The form was opened in \(expected.rawValue) but the store is now on \(actual.rawValue). Nothing was written."
        case .accountModeChanged:
            return "Named brokerage accounts were enabled or disabled after the form was opened. Nothing was written."
        case let .accountUnavailable(account):
            return "\(account.rawValue) cannot accept a new trade in the store's current account state."
        case let .destinationNotAllowed(account):
            return "\(account.rawValue) is not an account a purchase can be filed into."
        case let .fundingNotAllowed(account, funding):
            return "\(account.rawValue) does not accept \(funding.rawValue) funding for a purchase."
        case .fillPriceRequired:
            return "Enter the price this fill actually executed at. It is never taken from the plan or a quote."
        case .fillQuantityRequired:
            return "Enter the quantity this fill actually executed."
        case .invalidFillValues:
            return "The fill price, quantity, fee, or date is not valid."
        case let .planRequired(intent):
            return "A \(intent.rawValue) fill must name the plan it belongs to."
        case let .planNotAllowed(intent):
            return "A \(intent.rawValue) fill cannot carry a plan."
        case let .kindMismatch(plan, draft):
            return "This plan is a \(plan.rawValue) but the draft would record a \(draft.rawValue)."
        case let .planNotRecordable(status, intent):
            return "A \(status.rawValue) plan cannot accept a \(intent.rawValue) fill."
        case .saleSelectionIncomplete:
            return "Choose the sale portions and the fill size together, or leave the selection empty."
        case .staleAllocationRevision:
            return "The position allocation changed after the sale rows were drawn. Nothing was written; reopen the form."
        case let .transactionNotFound(id):
            return "Trade \(id.uuidString) is no longer in this account's ledger."
        case .immutablePlanContext:
            return "A plan-linked trade cannot change between buy and sell. Keep its original side."
        case .negativePosition:
            return "This change would create or worsen a negative historical position. Check the related trades and dates."
        case let .storeRejected(message):
            return message
        case let .unsupported(route):
            return "This build does not support the \(route) route yet. Nothing was written."
        }
    }
}

// MARK: - Outcomes

/// The result of a workflow attempt.
///
/// A refusal returns the draft that was submitted, so a caller can restore the
/// form with the user's input intact. That is why this is not a `Result`: the
/// failure case carries a value the success case does not.
public enum MobileWorkflowOutcome<Draft: Sendable, Value: Sendable>: Sendable {
    case written(Value)
    case refused(MobileWorkflowError, draft: Draft)

    public var value: Value? {
        if case let .written(value) = self { return value }
        return nil
    }

    public var error: MobileWorkflowError? {
        if case let .refused(error, _) = self { return error }
        return nil
    }

    public var draft: Draft? {
        if case let .refused(_, draft) = self { return draft }
        return nil
    }

    public var didWrite: Bool { value != nil }
}
