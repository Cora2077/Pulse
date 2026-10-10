import SwiftUI
import PulseCore
import PulseUI

/// The user's intent is separate from price conditions and recorded fills.
func planIntentTitle(_ entry: TradePlanEntry) -> String {
    entry.displayStatusTitle
}

// MARK: - Funding source labels

/// The one place the app names a funding annotation.
///
/// `nil` and `.unmarked` are deliberately different words: `nil` is "nobody has
/// classified this yet" (an old record, or a portion the user has not looked
/// at), while `.unmarked` is "the user cleared it on purpose". Collapsing them
/// would make the app re-ask a question the user already answered, and would
/// make "未标注" read as a value rather than a gap.
///
/// Nothing here reads a balance, a price, or a broker figure: the label
/// describes where the *shares* came from, never a debt.
func fundingSourceTitle(_ source: PositionFundingSource?, account: BrokerageAccountID = .unassigned) -> String {
    switch source {
    case .none: poolCopy("未标注", "Not annotated")
    case .some(.unmarked): poolCopy("未标注（已清除）", "Cleared")
    case .some(.own): account == .financing
        ? poolCopy("担保品", "Collateral") : poolCopy("普通买入", "Ordinary buy")
    case .some(.margin): poolCopy("融资买入", "Margin")
    }
}

/// The short form for a card's own tag row.
///
/// `nil` returns nothing at all: an old portion must not grow a repeated
/// "未标注" line on every card, which would turn a missing field into visual
/// noise the design explicitly rules out. Only an explicit selection earns a
/// tag.
func fundingSourceTagTitle(_ source: PositionFundingSource?, account: BrokerageAccountID = .unassigned) -> String? {
    guard account != .mengmeng else { return nil }
    return switch source {
    case .none: nil
    case .some(.unmarked): poolCopy("未标注", "Unmarked")
    case .some(.own): account == .financing
        ? poolCopy("担保品", "Collateral") : poolCopy("普通", "Ordinary")
    case .some(.margin): poolCopy("融资", "Margin")
    }
}

/// The options a funding picker offers, in a stable order. The empty/legacy
/// value is named by the caller's binding, not by this list, so a picker that
/// must preserve `nil` can keep it as its own row.
let fundingSourcePickerOptions: [PositionFundingSource] = [.unmarked, .own, .margin]

/// A real position's funding tag: a light caption-sized capsule. It never
/// carries a pool tint, so the pool colour language stays one signal, and it
/// adds no animation and no per-frame work.
struct FundingSourceTag: View {
    let source: PositionFundingSource?
    var account: BrokerageAccountID = .unassigned

    var body: some View {
        if let title = fundingSourceTagTitle(source, account: account) {
            Text(title)
                .font(PoolType.label)
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(tint.opacity(0.1), in: Capsule())
                .overlay { Capsule().stroke(tint.opacity(0.4), lineWidth: 1) }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(fundingSourceTitle(source, account: account))
        }
    }

    private var tint: Color {
        source == .margin ? PoolFundingStyle.marginTint : PoolFundingStyle.ownTint
    }
}

/// A plan's *intended* funding: dashed, and only ever shown for a plan that
/// actually intends margin. It reads as an intention, never as a holding, and
/// it is excluded from the real funding summary by construction — the summary
/// reads portions, not plans.
struct PlannedFundingTag: View {
    let source: PositionFundingSource?
    var account: BrokerageAccountID = .unassigned

    var body: some View {
        if account != .mengmeng, source == .margin {
            Text(poolCopy("拟融资", "Planned margin"))
                .font(PoolType.label)
                .foregroundStyle(PoolFundingStyle.marginTint)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(PoolFundingStyle.marginTint.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule().stroke(
                        PoolFundingStyle.marginTint.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: PoolMetric.assumedDash)
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
                .help(poolCopy("只是计划意向，不计入实际融资持仓汇总",
                               "An intention only; excluded from real funding totals"))
        }
    }
}

/// The two tints the funding language uses. Margin is the one state worth
/// colouring — it is the annotation the user is looking for — while own
/// capital stays neutral so a fully own-funded book does not light up.
enum PoolFundingStyle {
    static let marginTint = Color.orange
    static let ownTint = Color.secondary
}

/// A labelled funding picker, shared by the plan editor, the trade form, and
/// the execution sheet so all three offer the same words in the same order.
///
/// The binding is optional because `nil` is a real state a legacy record can
/// hold, and the "not annotated" row is always offered: a value with nowhere to
/// land would leave the picker rendering blank, which reads as a bug rather
/// than as an unset field.
struct FundingSourcePickerRow: View {
    let label: String
    @Binding var selection: PositionFundingSource?
    var help: String?
    var onChange: (() -> Void)?
    var options: [PositionFundingSource] = fundingSourcePickerOptions
    var includesUnannotated = true
    var account: BrokerageAccountID = .unassigned

    var body: some View {
        if account != .mengmeng {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Picker("", selection: $selection) {
                    if includesUnannotated {
                        Text(fundingSourceTitle(nil, account: account)).tag(nil as PositionFundingSource?)
                    }
                    ForEach(options, id: \.self) { source in
                        Text(fundingSourceTitle(source, account: account)).tag(Optional(source))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: selection) { _, _ in onChange?() }
                if let help {
                    Text(help)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Records a fill that already happened against a trade plan.
///
/// This is bookkeeping, not order entry: Pulse never sends an order, so the
/// sheet asks only what the user's broker already did. Three consequences
/// shape it. The plan's own conditions never block the form — a fill that has
/// already occurred is a fact, and refusing to record it would only hide it.
/// The `transactionID` is minted once, when the sheet appears, and `didSave`
/// latches on the first accepted write, so Return plus a click cannot record
/// the same fill twice. And the plan's `updatedAt` travels with the submission
/// so a plan that changed in the meantime is refused rather than filed against
/// the wrong price.
struct PlanExecutionSheet: View {
    @Environment(AppState.self) private var appState
    let entry: TradePlanEntry
    let onClose: () -> Void

    /// The account this fill will be recorded into, frozen when the sheet is
    /// built. A popover or a second window can outlive an account switch, and a
    /// plan id that exists in both ledgers is not by itself permission to write
    /// this fill into the one that is now selected.
    @State private var draftAccount: BrokerageAccountID

    @State private var priceText: String
    @State private var quantityText: String
    @State private var feeText = ""
    @State private var date: Date
    @State private var noteText = ""
    @State private var showsCalendar = false
    /// Fixed for the life of this sheet so a retry after a store error cannot
    /// write a second transaction for the same fill.
    @State private var transactionID = UUID()
    @State private var didSave = false
    @State private var errorMessage: String?
    /// The money that actually moved, pre-selected from the plan's intention
    /// but always the user's to change. The plan's intent is a proposal; the
    /// fill is the fact, and this field is where the two are allowed to differ.
    ///
    /// For a buy it is never `nil`: the shared fields offer ordinary capital as
    /// the floor, because a fill being recorded now has no "nobody has said
    /// yet" state to preserve. A sell leaves it `nil` — a sale consumes
    /// portions and does not choose a source here.
    @State private var fundingSource: PositionFundingSource?
    /// The ledger a *buy* fill is recorded into, chosen on this sheet rather
    /// than inherited from the sheet's own account. A plan is a proposal about
    /// an instrument, not about a ledger, so the user names where the fill
    /// actually landed; `draftAccount` above stays the source plan's account
    /// and is what the stale guard checks.
    @State private var selectedBrokerageAccount: BrokerageAccountID?
    /// For a sell that spans several sources: how many shares to take from each
    /// portion card. Empty means the caller has not named a selection, which
    /// the store then only accepts when the candidates agree on one source.
    @State private var saleSelection: [UUID: String] = [:]
    /// The allocation revision the sale selection was built against. Captured
    /// when the sheet appears and sent with the fill, so a selection cannot be
    /// applied to an allocation that changed while the rows were on screen.
    @State private var loadedAllocationRevision: UUID?

    /// The account the sheet was opened for. It is frozen for the life of the
    /// sheet so the fill is either recorded into that ledger or refused.
    init(entry: TradePlanEntry, account: BrokerageAccountID, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        self._draftAccount = State(initialValue: account)
        // Backfill starts both numbers blank. The plan's own price and its
        // remaining size are *intentions*, and this sheet is recording what a
        // broker already did: pre-filling either one would put a number in
        // front of the user that the app invented, and a saved fill that was
        // never checked is worse than an empty field that has to be filled in.
        // The remaining quantity stays one click away as a suggestion, so the
        // common case of "the rest of the plan filled" is still cheap.
        //
        // Ordinary recording keeps its suggestions: the plan is live, the
        // numbers are a proposal the user is deliberately confirming, and
        // nothing is being inferred about a trade that has not been described
        // yet.
        _priceText = State(initialValue: entry.canBackfillFill ? "" : Self.fieldText(entry.plan.price))
        _quantityText = State(initialValue: entry.canBackfillFill ? "" : Self.fieldText(
            entry.remainingQuantity > 0 ? entry.remainingQuantity : entry.plan.quantity
        ))
        _date = State(initialValue: Calendar.current.startOfDay(for: .now))
        // The destination starts at the account this sheet was opened from when
        // that account is a real one. `unassigned` is a source of legacy
        // records and never a place to file a new fill, so it starts empty and
        // the user has to name a ledger.
        _selectedBrokerageAccount = State(initialValue: account == .unassigned ? nil : account)
        // Ordinary capital unless the plan itself intended margin *and* the
        // starting account can hold it. The shared fields enforce the same
        // pairing after this.
        _fundingSource = State(initialValue:
            entry.plan.kind == .buy
                && account == .financing
                && entry.plan.fundingSource == .margin
                ? .margin : .own
        )
    }

    /// Whether the store is still pointed at the ledger this fill belongs to.
    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == draftAccount
    }

    /// Whether this sheet is entering a trade that already happened against a
    /// plan that is already stopped.
    ///
    /// Derived from the entry rather than passed in, so the one question — "is
    /// this an intention being confirmed, or a fact being written down?" — has
    /// one answer that the fields, the copy, and the store call all read. The
    /// init API is unchanged: a caller that knows how to build an
    /// `TradePlanEntry` already says which mode it wants.
    private var isBackfill: Bool { entry.canBackfillFill }

    private var plan: TradePlan { entry.plan }
    private var symbol: SymbolID { entry.symbol }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    private var kind: PositionTransaction.Kind { plan.kind == .buy ? .buy : .sell }
    /// The plan's side, not a P&L reading: it must not flip with 红涨绿跌.
    private var sideColor: Color { PlanSideStyle.color(for: plan.kind) }
    /// Every fill recorded from this plan is filed under the plan's own
    /// bucket, so a buy opens pool quantity and a sell draws from it. The
    /// store does the accounting; nothing here touches a cash balance.
    private var pool: PositionPool { plan.positionPool ?? .unassigned }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Which ledger, and what money — asked first, because they
                    // are the two answers that decide whether this fill can be
                    // recorded at all. Price and quantity are meaningless if
                    // the destination refuses the combination.
                    if kind == .buy { buyAccountMethodFields }
                    HStack(spacing: 8) {
                        PositionInputCell(
                            label: PulseLocalization.localizedString(
                                "trade.priceWithCurrency",
                                currencyCode ?? symbol.currencyCode
                            ),
                            text: $priceText
                        )
                        PositionInputCell(
                            label: PulseLocalization.localizedString(
                                "trade.quantityWithUnit",
                                quantityUnit
                            ),
                            text: $quantityText,
                            suggestion: remainingSuggestion
                        )
                    }
                    PositionInputCell(
                        label: PulseLocalization.localizedString("trade.fee"),
                        text: $feeText
                    )
                    if !feeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       parsedFee == nil {
                        Text(PulseLocalization.localizedString("trade.invalidFee"))
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    dateRow
                    PositionInputCell(
                        label: PulseLocalization.localizedString("plan.execution.note"),
                        text: $noteText
                    )
                    fundingSection
                    conditionSummary
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        // The root is a suggested size only: the presenting container decides
        // the final box (the pool sheets already do this), and every child
        // below is flexible enough to take whatever it is given.
        .frame(minWidth: 360, idealWidth: 380, maxWidth: .infinity)
        .frame(minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onSubmit { submit() }
        // The revision the sale selection is built against. Freezing it here
        // means a later allocation edit on another surface cannot have this
        // sheet's card selection applied to different shares.
        .onAppear {
            loadedAllocationRevision = appState.watchlist.draftItem(for: symbol, account: draftAccount)?.positionAllocation?.revision
        }
    }

    // MARK: - Header

    /// Names the plan being filled and the two numbers that bound the entry:
    /// what was planned and what is still open after the fills already
    /// recorded. A partial fill is normal, so the remainder never reads as an
    /// error.
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isBackfill
                    ? PulseLocalization.localizedString("plans.backfill.title")
                    : PulseLocalization.localizedString("plan.execution.title"))
                    .font(.system(size: 13, weight: .semibold))
                Text(appState.displayName(for: symbol))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(symbol.displayCode)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                summaryValue(
                    PulseLocalization.localizedString("plan.execution.planned"),
                    PlanValueText.priceQuantity(price: plan.price, quantity: plan.quantity,
                        symbol: symbol, currencyCode: currencyCode,
                        instrumentType: sourceItem?.resolvedInstrumentType),
                    color: sideColor
                )
                summaryValue(
                    PulseLocalization.localizedString("plan.execution.filled"),
                    PlanValueText.quantity(entry.filledQuantity, symbol: symbol,
                        instrumentType: sourceItem?.resolvedInstrumentType)
                )
                summaryValue(
                    PulseLocalization.localizedString("plan.execution.remaining"),
                    PlanValueText.quantity(entry.remainingQuantity, symbol: symbol,
                        instrumentType: sourceItem?.resolvedInstrumentType)
                )
            }
            Text(PulseLocalization.localizedString("plan.execution.poolHelp", pool.title))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if isBackfill {
                // This sheet is reached from a plan that is already stopped, so
                // the one thing that has to be said is why the numbers are
                // blank and where the write is going.
                Text(PulseLocalization.localizedString("plans.backfill.help"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(PulseLocalization.localizedString("plan.execution.notAnOrder"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // The ledger this fill lands in. A buy names the destination the
            // user picked on this sheet, or asks for one when it is still
            // empty; a sell has no destination of its own and keeps naming the
            // account the sheet was opened for. Either way the value is not
            // read from whatever the toolbar happens to have selected now —
            // `accountMatchesDraft` is a separate guard.
            HStack(spacing: 5) {
                Circle().fill(AccountIdentity.dotColor(headerAccount)).frame(width: 5, height: 5)
                Text(headerAccountText)
                    .font(.system(size: 9))
                    .foregroundStyle(accountMatchesDraft ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    /// The account the header names. A buy names its chosen destination — the
    /// dot colour has to belong to that account, or the caption would describe
    /// a different ledger than the fill does.
    private var headerAccount: BrokerageAccountID {
        guard kind == .buy else { return draftAccount }
        return selectedBrokerageAccount ?? .unassigned
    }

    /// "记入账户：萌萌账号", or the question itself while a buy still has no
    /// destination. Asking here rather than showing a bare placeholder is what
    /// makes the missing answer visible in the chrome as well as in the form.
    private var headerAccountText: String {
        guard kind == .buy else {
            return poolCopy("记入账号：\(AccountIdentity.title(draftAccount))",
                            "Recording into: \(AccountIdentity.title(draftAccount))")
        }
        guard let account = selectedBrokerageAccount else {
            return poolCopy("记入账户：请选择账户", "Recording into: Select account")
        }
        return poolCopy("记入账户：\(AccountIdentity.title(account))",
                        "Recording into: \(AccountIdentity.title(account))")
    }

    private func summaryValue(_ label: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(color ?? .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Fields

    /// The unit this fill is counted in, resolved through the one shared rule.
    ///
    /// This used to decide for itself — the pair's base asset, else "shares" —
    /// which is why an ETF's fill form said "shares" while the card that opened
    /// it said the fund unit. `PlanValueText.quantityUnit` is the single answer
    /// every surface reads, so the form and the row that launched it cannot
    /// disagree about what is being counted.
    private var quantityUnit: String {
        PlanValueText.quantityUnit(symbol: symbol, instrumentType: sourceItem?.resolvedInstrumentType)
    }

    /// The planned instrument as this ledger stores it, which is the same
    /// resolution the plan list uses for its card.
    private var sourceItem: WatchItem? {
        appState.watchlist.draftItem(for: symbol, account: draftAccount)
    }

    private var remainingSuggestion: PositionInputCell.Suggestion? {
        guard entry.remainingQuantity.isFinite, entry.remainingQuantity > 0 else { return nil }
        let text = Self.fieldText(entry.remainingQuantity)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString(
                "plan.execution.useRemaining",
                PriceFormatter.quantity(entry.remainingQuantity)
            ),
            help: PulseLocalization.localizedString("plan.execution.useRemainingHelp"),
            fill: { quantityText = text }
        )
    }

    // MARK: - Funding

    /// A sell shows which cards the shares come out of, because a sale consumes
    /// existing portions and the store refuses to guess when they disagree
    /// about funding.
    ///
    /// A buy has nothing here any more: its account and method are asked at the
    /// top of the form by the shared fields, which is the only way those two
    /// answers stay paired with each other. The old "funding actually used"
    /// picker asked half of that question in isolation, and could offer margin
    /// in an account that would refuse it.
    ///
    /// The sell half cannot disable the record button: source ambiguity is
    /// something to review, never a reason to hide a fill that already happened.
    @ViewBuilder
    private var fundingSection: some View {
        if kind == .sell, plan.positionPortionID != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let source = saleCandidates.first {
                    Text(poolCopy("卖出这笔仓位：", "Sell this portion: ") + source.pool.title
                         + " · " + PriceFormatter.quantity(source.quantity))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(poolCopy("只扣减这张仓位卡，不影响其他仓位。", "Only this position portion will be reduced."))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if !saleSelectionIsValid {
                        Text(poolCopy("卖出数量超过这笔仓位的剩余数量。", "The sale exceeds this portion's remaining quantity."))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Text(poolCopy("源仓位已变化，请先修改卖出计划。", "The source portion changed. Edit the sell plan first."))
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        } else if kind == .sell, !saleCandidates.isEmpty {
            if hasMixedFunding {
                saleSelectionSection
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if draftAccount != .mengmeng {
                        Text(poolCopy("资金来源：", "Funding: ")
                            + fundingSourceTitle(saleCandidates.first?.fundingSource, account: draftAccount))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(plan.positionPool == nil
                         ? poolCopy("来源池未指定，记录成交后需核对分账。", "Source pool unset; reconcile the allocation after recording.")
                         : poolCopy("按计划来源池减少份额。", "Reduces shares in the plan's source pool."))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The shared account-then-method block, the same one the direct buy form
    /// uses. Sharing it is what stops these two routes from drifting into
    /// offering different combinations.
    private var buyAccountMethodFields: some View {
        BuyAccountMethodFields(
            account: $selectedBrokerageAccount,
            method: Binding(
                get: { fundingSource ?? .own },
                set: { fundingSource = $0 }
            ),
            accountAccessibilityID: "plan.fill.account",
            methodAccessibilityID: "plan.fill.method",
            onAccountChange: { errorMessage = nil },
            onMethodChange: { errorMessage = nil }
        )
    }

    /// Whether the chosen account and method are a pair the store will accept.
    ///
    /// This is the same rule the shared fields render, restated as a value so
    /// the footer can disable both record buttons and Return. A buy with no
    /// account, or a margin method outside the financing account, is not a
    /// recordable fill — and disabling is honest here, unlike the sell side,
    /// because nothing has happened yet that these fields would be hiding.
    private var isBuySelectionRecordable: Bool {
        guard kind == .buy else { return true }
        // `fundingSource ?? .own` matches the binding the shared fields write
        // through, so the button's rule and the menu's rule read one value.
        return selectedBrokerageAccount?.permitsBuy(fundingSource: fundingSource ?? .own) ?? false
    }

    /// The portion cards this sale may draw from.
    ///
    /// A plan with a pool competes only inside that pool — the plan already
    /// said which bucket it sells from. A plan with no pool competes across the
    /// whole position, which is what "整标的卖出" means. Only live, reconciled
    /// allocations qualify; an unreconciled one is refused by the store anyway.
    private var saleCandidates: [PositionPortion] {
        guard kind == .sell,
              let item = appState.watchlist.draftItem(for: symbol, account: draftAccount),
              let allocation = item.positionAllocation,
              !item.positionAllocationNeedsReconciliation else { return [] }
        if plan.positionPortionID != nil {
            return item.salePlanSource(for: plan).map { [$0] } ?? []
        }
        guard let pool = plan.positionPool else { return allocation.portions }
        return allocation.portions.filter { $0.pool == pool }
    }

    /// Whether the candidate cards disagree about their funding.
    ///
    /// `nil` counts as `.unmarked`: a legacy card and an explicitly unmarked one
    /// are the same thing to this question, and treating them as different
    /// would demand a selection that means nothing. One shared source (or a
    /// single card) is unambiguous, so the store's existing automatic
    /// deduction is allowed to run.
    private var hasMixedFunding: Bool {
        Set(saleCandidates.map { $0.fundingSource ?? .unmarked }).count > 1
    }

    private var parsedSaleSelection: [UUID: Double]? {
        if let id = plan.positionPortionID, let quantity = parsedQuantity {
            return [id: quantity]
        }
        guard hasMixedFunding else { return nil }
        var selection: [UUID: Double] = [:]
        for portion in saleCandidates {
            let text = (saleSelection[portion.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let value = Double(text.replacingOccurrences(of: ",", with: "")),
                  value.isFinite, value > 0 else { return nil }
            selection[portion.id] = value
        }
        return selection.isEmpty ? nil : selection
    }

    /// The selection's total, so the sheet can show how far it is from the
    /// quantity being recorded.
    private var saleSelectionTotal: Double {
        parsedSaleSelection?.values.reduce(0, +) ?? 0
    }

    /// A selection is only usable when it names real cards and its total equals
    /// this sale exactly. The store repeats the check; doing it here keeps the
    /// mismatch next to the fields instead of in an alert.
    private var saleSelectionIsValid: Bool {
        if plan.positionPortionID != nil {
            guard let source = saleCandidates.first, let quantity = parsedQuantity else { return false }
            return quantity <= source.quantity + PositionAllocation.quantityTolerance(quantity, source.quantity)
        }
        guard hasMixedFunding else { return true }
        guard let selection = parsedSaleSelection, let quantity = parsedQuantity else { return false }
        guard !saleCandidates.contains(where: saleRowExceedsCard) else { return false }
        let total = selection.values.reduce(0, +)
        guard total.isFinite, quantity.isFinite else { return false }
        return abs(total - quantity) <= PositionAllocation.quantityTolerance(total, quantity)
    }

    /// How many shares one row currently claims, or `nil` when the field is
    /// blank or not a number yet.
    private func saleAmount(for portion: PositionPortion) -> Double? {
        let text = (saleSelection[portion.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let value = Double(text.replacingOccurrences(of: ",", with: "")),
              value.isFinite, value > 0 else { return nil }
        return value
    }

    /// Whether one row asks for more shares than its card holds. It is not the
    /// same as the total check: the sum can be right while one card is spent
    /// twice, and the store would reject that with a less specific message.
    private func saleRowExceedsCard(_ portion: PositionPortion) -> Bool {
        guard let amount = saleAmount(for: portion) else { return false }
        let tolerance = PositionAllocation.quantityTolerance(amount, portion.quantity)
        return amount > portion.quantity + tolerance
    }

    /// The per-card quantity inputs, one row per candidate.
    ///
    /// The list scrolls inside a fixed height so a position with many cards
    /// cannot push the conditions and the footer off the sheet — the fields are
    /// important, but so is the ability to see the record button. Each row
    /// names its pool, its funding, and how much is available, because a bare
    /// number would not say which card is being spent.
    private var saleSelectionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(poolCopy("本次减少哪些份额", "Which shares this sale reduces"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let quantity = parsedQuantity {
                    Text("\(PriceFormatter.quantity(saleSelectionTotal)) / \(PriceFormatter.quantity(quantity))")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(saleSelectionIsValid ? Color.secondary : Color.orange)
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(saleCandidates) { portion in
                        HStack(spacing: 6) {
                            Circle().fill(portion.pool.tint).frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(portion.pool.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                            FundingSourceTag(source: portion.fundingSource,
                                account: draftAccount == .mengmeng ? .mengmeng : (portion.brokerageAccountID ?? draftAccount))
                            if draftAccount != .mengmeng, portion.fundingSource == nil {
                                Text(poolCopy("来源未标注", "Source unknown"))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text(poolCopy("可用 ", "Available ") + PriceFormatter.quantity(portion.quantity))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(saleRowExceedsCard(portion) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            TextField("0", text: saleBinding(portion.id))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 74)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: saleSelection[portion.id] ?? "") { _, _ in errorMessage = nil }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 132)
            if saleCandidates.contains(where: saleRowExceedsCard) {
                Text(poolCopy("某一张份额的数量超过了它的可用量，请调整。",
                              "One row asks for more shares than its card holds. Adjust it."))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !saleSelectionIsValid {
                Text(poolCopy("各份额数量合计必须等于本次卖出数量。未选择的份额不会被自动扣减。",
                              "The quantities must add up to this sale. Unselected shares are never deducted automatically."))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(poolCopy("未选择的份额保持不变；融资份额不会因为卖出被当作已偿还。",
                              "Unselected shares are unchanged; margin shares are never treated as repaid by a sale."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func saleBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { saleSelection[id] ?? "" },
            set: { saleSelection[id] = $0 }
        )
    }

    /// The key naming the date field for the current mode.
    ///
    /// In backfill the label names the date it is asking for instead of leaving
    /// the reader to assume "today" — entering a trade after the fact is the
    /// whole point of the mode. The wording comes from the string table like
    /// every other label: the two-language `poolCopy` this used to call serves
    /// the funding annotations, and it answered a Japanese or Korean build with
    /// English. Should the key ever go missing, the ordinary date label stands
    /// in rather than a raw identifier appearing in a form that records money.
    ///
    /// The label is deliberately not inferred from the plan's `updatedAt`: when
    /// the plan was last edited is not when the broker filled it, and quietly
    /// substituting one for the other would file a real trade on a fabricated
    /// date.
    private var dateLabelKey: String {
        guard isBackfill else { return PulseLocalization.localizedString("trade.date") }
        let backfill = PulseLocalization.localizedString("plans.backfill.date")
        return backfill == "plans.backfill.date"
            ? PulseLocalization.localizedString("trade.date")
            : backfill
    }

    private var dateRow: some View {
        HStack(spacing: 8) {
            Text(dateLabelKey)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showsCalendar = true
            } label: {
                Text(dateText)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 74)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                DatePicker(
                    "",
                    selection: $date,
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.graphical)
                .padding(10)
                .onChange(of: date) { _, _ in showsCalendar = false }
            }
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The plan's judgement of itself, shown for context only. A condition
    /// still pending is not a reason to refuse a fill that already happened,
    /// so nothing below is ever disabled by these.
    ///
    /// The count is of conditions that still want attention *now* — measured by
    /// the condition's own `requiresReview` against the live events, not by the
    /// stored state alone. A confirmed condition whose linked event has since
    /// moved is exactly the case this sheet must not report as settled.
    private var conditionSummary: some View {
        let conditions = plan.conditions ?? []
        let liveEvents = appState.tradingEvents.entries(for: appState.watchlist.allItems)
            .filter { $0.symbol == symbol }
            .map(\.event)
        let now = Date.now
        let settled = conditions.filter { !$0.requiresReview(at: now, currentEvents: liveEvents) }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(PulseLocalization.localizedString("plan.conditions"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(conditions.isEmpty
                    ? PulseLocalization.localizedString("plan.condition.none")
                    : PulseLocalization.localizedString(
                        "plan.condition.summary",
                        settled,
                        conditions.count
                    ))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !conditions.isEmpty {
                ForEach(conditions) { condition in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Self.stateColor(condition.state))
                            .frame(width: 5, height: 5)
                        Text(condition.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(condition.title)
                        Spacer(minLength: 0)
                        Text(PulseLocalization.localizedString("plan.condition.state.\(condition.state.rawValue)"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        let blocked = didSave || !isSubmittable || !accountMatchesDraft
        return HStack(spacing: 8) {
            Spacer()
            Button(PulseLocalization.localizedString("action.cancel")) {
                onClose()
            }
            .controlSize(.small)
            .disabled(didSave)
            Button {
                submit()
            } label: {
                Text(PulseLocalization.localizedString(
                    isBackfill ? "plans.action.backfill" : "plan.execution.record"
                ))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(blocked ? Color.secondary : Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .keyboardShortcut(.defaultAction)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(blocked ? Color.secondary.opacity(0.18) : sideColor.opacity(0.92))
            )
            .disabled(blocked)
            .opacity(blocked ? 0.45 : 1)
            // A stable handle for the backfill save button, so a UI check can
            // reach this exact control rather than the first button that
            // happens to say the same words. The ordinary record button is left
            // without one: it is an existing surface, and adding an identifier
            // to it is not this change's business.
            .accessibilityIdentifier(isBackfill ? "plan.fill.backfill" : "")
            // The second way out: same submission, same single transaction, but
            // the journal is asked to open this exact fill for its review. It is
            // a shortcut, not a different record, and `didSave` governs both
            // buttons so Return plus a click can never write two.
            Button(PulseLocalization.localizedString("plan.execution.recordAndReview")) {
                submit(openingReview: true)
            }
            .controlSize(.small)
            .disabled(blocked)
            .opacity(blocked ? 0.45 : 1)
        }
        .padding(12)
    }

    // MARK: - Parse & submit

    private var parsedPrice: Double? {
        Self.parseDecimal(priceText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private var parsedQuantity: Double? {
        Self.parseDecimal(quantityText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private var parsedFee: Double? {
        guard let value = Self.parseDecimal(feeText) else { return nil }
        return value.isFinite && value >= 0 ? value : nil
    }

    /// Any positive size is recordable: more than the plan asked for is a real
    /// thing users do, and the progress remainder floors at zero rather than
    /// turning the form into a rejection. Conditions never appear here — a fill
    /// that already happened is a fact, not a proposal.
    ///
    /// A mixed-source sale is the one addition: its selection has to name the
    /// cards and add up, because the store will refuse rather than pick a
    /// source on the user's behalf. That is an incompleteness, not a judgement
    /// about the trade, so refusing to submit here is honest.
    private var isValid: Bool {
        guard let price = parsedPrice, let quantity = parsedQuantity else { return false }
        let amount = price * quantity
        guard amount.isFinite, amount > 0,
              date.timeIntervalSince1970.isFinite else { return false }
        guard feeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedFee != nil else {
            return false
        }
        return saleSelectionIsValid
    }

    /// Everything that must hold before either record button — or Return —
    /// writes anything. The buy selection is included so a fill can never be
    /// submitted into an account/method pair the store would refuse, which
    /// would only surface as an error after the user had filled in the rest.
    private var isSubmittable: Bool {
        isValid && isBuySelectionRecordable
    }

    /// Records the fill, and optionally asks the journal to open it.
    ///
    /// The review flag changes nothing about the write: it only decides whether
    /// the new transaction's id is handed to the app as the journal's pending
    /// selection. That happens strictly after the store accepted the write, so
    /// a failed submission can never navigate anywhere, and the ordinary record
    /// button leaves the id alone — recording a fill is not a request to review
    /// it.
    private func submit(openingReview: Bool = false) {
        guard !didSave, let price = parsedPrice, let quantity = parsedQuantity else { return }
        guard isSubmittable else { return }
        // The ledger moved out from under this sheet. The fill is not filed
        // against the newly selected account; the error stays visible and
        // `didSave` stays false so nothing is silently redirected.
        guard accountMatchesDraft else {
            errorMessage = poolCopy(
                "当前账号已切换，本次成交不会记入其他账号。请关闭后重新打开。",
                "The account changed. This fill will not be recorded into another account; close and reopen."
            )
            return
        }

        didSave = true
        do {
            let transaction = try appState.watchlist.recordTradePlanFill(
                symbol: symbol,
                planID: plan.id,
                price: price,
                quantity: quantity,
                date: date,
                fee: parsedFee,
                note: Self.normalizedNote(noteText),
                transactionID: transactionID,
                expectedPlanUpdatedAt: plan.updatedAt,
                // The reported fill's funding. A buy sends what the user
                // confirmed; a sell sends nothing here, because a sale consumes
                // portions rather than choosing a source.
                fundingSource: kind == .buy ? (fundingSource ?? .own) : nil,
                // Where a buy's fill lands. The store keeps the source plan in
                // its own ledger and records the transaction in this one. A
                // sell sends nothing: a sale reduces shares where they already
                // live, which is the plan's own account.
                brokerageAccountID: kind == .buy ? selectedBrokerageAccount : nil,
                // Only a genuinely mixed sale names its cards. A single-source
                // pool keeps the existing automatic deduction, so nothing about
                // that path changes.
                salePortionQuantities: parsedSaleSelection,
                // The revision this sheet's card selection was built against,
                // frozen in `onAppear`. Only a sale that names portions needs
                // it: that selection is meaningless against an allocation that
                // changed since the rows were drawn. A buy or an automatic
                // single-source sale leaves the check off, exactly as before.
                expectedAllocationRevision: parsedSaleSelection == nil ? nil : loadedAllocationRevision,
                // Tells the store this is a fact being written down rather than
                // an intention being confirmed, so it may accept the fill on a
                // stopped plan. The store re-derives the condition from its own
                // values — a sheet that has been open while the plan changed
                // gains nothing here.
                historicalBackfill: isBackfill
            )
            if openingReview, kind == .buy, let account = selectedBrokerageAccount {
                // The journal opens a transaction in a ledger, so the app has
                // to be on the destination before the id is handed over —
                // otherwise the review would look for this fill in the source
                // plan's account and find nothing. Selecting an account clears
                // `pendingJournalTransactionID`, which is exactly why the order
                // here is select first, then set.
                _ = appState.selectBrokerageAccount(account)
            }
            if openingReview {
                appState.pendingJournalTransactionID = transaction.id
            }
            onClose()
        } catch {
            // The sheet stays open and the id is already fixed, so whatever
            // the user changes next is a correction to the same record — never
            // a second one.
            didSave = false
            errorMessage = Self.describe(error)
        }
    }

    /// `TradePlanExecutionError` already writes both languages; anything else
    /// falls back to its own description so a store error is never swallowed
    /// into a generic sentence.
    private static func describe(_ error: Error) -> String {
        if let executionError = error as? TradePlanExecutionError,
           let description = executionError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func parseDecimal(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    private static func normalizedNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func fieldText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
    }

    static func stateColor(_ state: TradePlanCondition.State) -> Color {
        switch state {
        case .pending: .secondary
        case .confirmed: .green
        case .needsReview: .orange
        case .invalidated: .red
        }
    }
}

/// Everything known about one plan: how far it has been filled, what it asked
/// for, the conditions the user maintains, and every configuration it has been
/// through.
///
/// It reads the plan and the transactions straight out of the store on every
/// render rather than holding a copy, so a fill recorded from the sheet below
/// shows up in the progress bar immediately. A plan that has been deleted
/// says so instead of rendering an empty page — the page is reachable from
/// history.
struct PlanWorkflowDetailView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    let planID: UUID
    /// The account this page was opened for. The condition dots write the plan
    /// straight back to the store, so the page must not keep writing after an
    /// account switch replaced the ledger it was reading.
    @State private var account: BrokerageAccountID

    init(symbol: SymbolID, planID: UUID, account: BrokerageAccountID) {
        self.symbol = symbol
        self.planID = planID
        self._account = State(initialValue: account)
    }

    @State private var showsExecutionSheet = false
    @State private var errorMessage: String?
    /// The account the open execution sheet was built for, captured when it was
    /// presented so a switch while it is up cannot re-point its write.
    @State private var executionSheetAccount: BrokerageAccountID?

    private var item: WatchItem? { appState.watchlist.draftItem(for: symbol, account: account) }
    private var plan: TradePlan? { item?.plans.first { $0.id == planID } }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    private var transactions: [PositionTransaction] { appState.watchlist.transactionsForPlan(symbol, account: account) }

    var body: some View {
        Group {
            if let current = plan {
                content(current)
            } else {
                ContentUnavailableView(
                    PulseLocalization.localizedString("plan.detail.missing.title"),
                    systemImage: "questionmark.folder",
                    description: Text(PulseLocalization.localizedString("plan.detail.missing.body"))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsExecutionSheet) {
            // Rebuilt from the store when the sheet opens, so the plan and the
            // fills it carries are the ones on screen now rather than whatever
            // was captured when the button was first rendered. The account is
            // taken from the value captured at presentation, so the sheet can
            // still refuse a write when the ledger has since changed.
            if let current = plan {
                PlanExecutionSheet(
                    entry: TradePlanEntry(symbol: symbol, plan: current, transactions: transactions),
                    account: executionSheetAccount ?? appState.watchlist.activeBrokerageAccountID
                ) {
                    showsExecutionSheet = false
                    executionSheetAccount = nil
                }
            }
        }
    }

    /// Whether the plan this page edits still lives in the ledger it was opened
    /// against. Condition writes re-read the plan from the store, so an id that
    /// only exists in the newly selected account must not receive them.
    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == account
    }

    private func content(_ plan: TradePlan) -> some View {
        let progress = TradePlanExecutionProgress(plan: plan, transactions: transactions)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleRow(plan)
                progressSection(plan, progress: progress)
                planSection(plan)
                conditionSection(plan)
                linkedTradesSection(plan)
                historySection(plan)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Header

    private func titleRow(_ plan: TradePlan) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.displayName(for: symbol))
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 6) {
                    Text(symbol.displayCode)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(PulseLocalization.localizedString(
                        plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"
                    ))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PlanSideStyle.color(for: plan.kind))
                    Text(planIntentTitle(TradePlanEntry(symbol: symbol, plan: plan, transactions: transactions)))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if !accountMatchesDraft {
                        Text(poolCopy("账号已切换 · 只读", "Account changed · read-only"))
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    } else {
                        Text(AccountIdentity.title(account))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 8)
            let entry = TradePlanEntry(symbol: symbol, plan: plan, transactions: transactions)
            if entry.displayState == .waiting {
                Button(PulseLocalization.localizedString("plan.execution.record")) {
                    executionSheetAccount = appState.watchlist.activeBrokerageAccountID
                    showsExecutionSheet = true
                }
                .controlSize(.small).disabled(!accountMatchesDraft)
            } else if entry.canBackfillFill {
                // The direct route. A stopped plan whose fills are incomplete is
                // exactly what backfill is for, so the header offers the fill
                // itself rather than only the revive button below — reviving a
                // plan to record a trade that already happened writes a state
                // the user never chose and makes a settled plan briefly look
                // live again. Reviving stays its own decision, one branch down,
                // for the user who really does want to keep waiting.
                Button(PulseLocalization.localizedString("plans.action.backfill")) {
                    executionSheetAccount = appState.watchlist.activeBrokerageAccountID
                    showsExecutionSheet = true
                }
                .controlSize(.small)
                .disabled(!accountMatchesDraft)
                .help(PulseLocalization.localizedString("plans.backfill.help"))
                .accessibilityIdentifier("plan.detail.backfill")
                if entry.displayState != .filled {
                    reviveButton(plan)
                }
            } else if entry.displayState != .filled {
                reviveButton(plan)
            }
        }
    }

    /// Puts a stopped or dropped plan back to `.active`, which is a decision
    /// about the plan's future and never a way to file its past. Kept as its own
    /// control so the backfill entrance above cannot be mistaken for it.
    private func reviveButton(_ plan: TradePlan) -> some View {
        Button(PulseLocalization.localizedString("plan.menu.revive")) {
            var updated = plan; updated.status = .active
            write(updated, verb: "plan.detail.conditionFailed")
        }
        .controlSize(.small).disabled(!accountMatchesDraft)
    }

    // MARK: - Progress

    private func progressSection(_ plan: TradePlan, progress: TradePlanExecutionProgress) -> some View {
        let planned = plan.quantity.isFinite && plan.quantity > 0 ? plan.quantity : 0
        let fraction = planned > 0
            ? min(1, max(0, progress.filledQuantity / planned))
            : 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(PulseLocalization.localizedString("plan.detail.progress"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if progress.isComplete {
                    Text(PulseLocalization.localizedString("plan.detail.complete"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
            HStack(spacing: 12) {
                statValue(
                    PulseLocalization.localizedString("plan.execution.filled"),
                    PriceFormatter.quantity(progress.filledQuantity)
                )
                statValue(
                    PulseLocalization.localizedString("plan.execution.remaining"),
                    PriceFormatter.quantity(progress.remainingQuantity)
                )
                statValue(
                    PulseLocalization.localizedString("plan.detail.planned"),
                    PriceFormatter.quantity(plan.quantity)
                )
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Plan facts

    private func planSection(_ plan: TradePlan) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(PulseLocalization.localizedString("plan.detail.configuration"))
                .font(.system(size: 12, weight: .semibold))
            factLine(
                PulseLocalization.localizedString("plan.price"),
                PriceFormatter.price(plan.price, market: symbol.market)
            )
            factLine(
                PulseLocalization.localizedString("position.quantity"),
                PriceFormatter.quantity(plan.quantity)
            )
            factLine(
                PulseLocalization.localizedString("plan.amount"),
                PriceFormatter.money(plan.estimatedAmount, currencyCode: currencyCode)
            )
            factLine(
                PulseLocalization.localizedString("plan.pool"),
                plan.positionPool?.title ?? PulseLocalization.localizedString("plan.pool.none")
            )
            factLine(
                PulseLocalization.localizedString("plan.detail.updated"),
                Self.timestamp(plan.updatedAt)
            )
            if let note = plan.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func factLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
    }

    // MARK: - Conditions

    /// Each dot is also the control: clicking it advances the condition to the
    /// next state and writes the plan straight back to the store, so the change
    /// is persisted the moment it is made. This is the only place Pulse lets a
    /// condition be judged, and it is always the user's judgement — no quote
    /// ever moves a condition by itself.
    private func conditionSection(_ plan: TradePlan) -> some View {
        let conditions = plan.conditions ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Text(PulseLocalization.localizedString("plan.conditions"))
                .font(.system(size: 12, weight: .semibold))
            if conditions.isEmpty {
                Text(PulseLocalization.localizedString("plan.condition.none"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(conditions) { condition in
                    conditionRow(condition)
                }
            }
            Text(PulseLocalization.localizedString("plan.condition.tapHelp"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The live events for this instrument, which is what a linked condition is
    /// judged against. Read from the same controller the events page uses, so
    /// the two surfaces can never disagree about what an event says today.
    private var liveEvents: [InstrumentEvent] {
        appState.tradingEvents.entries(for: appState.watchlist.allItems)
            .filter { $0.symbol == symbol }
            .map(\.event)
    }

    /// The current event a reference points at, or nil when the event is gone.
    private func currentEvent(for reference: InstrumentEvent) -> InstrumentEvent? {
        liveEvents.first { $0.id == reference.id }
    }

    /// Whether a linked condition's snapshot still matches the live event, and
    /// whether there is a live event to match against at all. Two different
    /// sentences, because "it moved" and "it's gone" call for different fixes.
    private enum LinkVerdict {
        case missing
        case changed
        case unchanged
    }

    private func linkVerdict(for condition: TradePlanCondition) -> LinkVerdict? {
        guard let reference = condition.eventReference else { return nil }
        guard let current = currentEvent(for: reference) else { return .missing }
        let same = current.kind == reference.kind
            && current.date == reference.date
            && current.endDate == reference.endDate
            && current.title == reference.title
        return same ? .unchanged : .changed
    }

    private func conditionRow(_ condition: TradePlanCondition) -> some View {
        let verdict = linkVerdict(for: condition)
        return HStack(alignment: .top, spacing: 7) {
            Menu {
                ForEach(TradePlanCondition.State.allCases, id: \.self) { state in
                    Button(PulseLocalization.localizedString("plan.condition.state.\(state.rawValue)")) {
                        setState(state, for: condition)
                    }
                }
            } label: {
                Circle()
                    .fill(PlanExecutionSheet.stateColor(condition.state))
                    .frame(width: 9, height: 9)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(PulseLocalization.localizedString("plan.condition.tapHelp"))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(condition.title)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(PulseLocalization.localizedString("plan.condition.kind.\(condition.kind.rawValue)"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(PulseLocalization.localizedString("plan.condition.state.\(condition.state.rawValue)"))
                        .font(.system(size: 9))
                        .foregroundStyle(PlanExecutionSheet.stateColor(condition.state))
                }
                if let reference = condition.eventReference {
                    linkedEventLine(reference, verdict: verdict)
                }
                if let note = condition.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if let source = condition.sourceURL, let url = URL(string: source) {
                        Link(source, destination: url)
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                    if let reviewDate = condition.reviewDate {
                        Text(PulseLocalization.localizedString(
                            "plan.condition.reviewOn",
                            Self.day(reviewDate)
                        ))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            eventLinkMenu(condition)
        }
    }

    /// The event a condition was linked to, as it was written down, beside what
    /// the event says now.
    ///
    /// Both are shown when they differ, because the whole point of keeping a
    /// snapshot is to make that difference visible: the user reasoned about the
    /// old window, and the newest edit may have moved the ground. The snapshot
    /// itself is never rewritten here.
    @ViewBuilder private func linkedEventLine(_ reference: InstrumentEvent, verdict: LinkVerdict?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "link").font(.system(size: 8)).foregroundStyle(.tertiary)
                Text(PulseLocalization.localizedString(
                    "plan.condition.linkedEvent",
                    reference.title,
                    Self.window(reference)
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(reference.title)
            }
            switch verdict {
            case .missing:
                Text(PulseLocalization.localizedString("plan.condition.eventMissing"))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .changed:
                Text(PulseLocalization.localizedString(
                    "plan.condition.eventChanged",
                    currentEvent(for: reference).map { "\($0.title) · \(Self.window($0))" } ?? ""
                ))
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            case .unchanged, .none:
                EmptyView()
            }
        }
    }

    /// Linking, re-linking, and unlinking are explicit menu actions on the row
    /// itself, so the plan page can create a link without a trip to the events
    /// page. Every write re-reads the plan from the store first, and linking
    /// always leaves the condition at `needsReview`: an event link can say what
    /// the user is watching, but it can never confirm a condition on its own.
    @ViewBuilder private func eventLinkMenu(_ condition: TradePlanCondition) -> some View {
        let linked = condition.eventReference
        let candidates = liveEvents.filter { $0.id != linked?.id }
        Menu {
            if linked == nil {
                if candidates.isEmpty {
                    Text(PulseLocalization.localizedString("plan.condition.noEvents"))
                } else {
                    ForEach(candidates) { event in
                        Button("\(event.title) · \(Self.window(event))") {
                            link(event.id, to: condition)
                        }
                    }
                }
            } else {
                if candidates.isEmpty {
                    Text(PulseLocalization.localizedString("plan.condition.noEvents"))
                } else {
                    Menu(PulseLocalization.localizedString("plan.condition.changeEvent")) {
                        ForEach(candidates) { event in
                            Button("\(event.title) · \(Self.window(event))") {
                                link(event.id, to: condition)
                            }
                        }
                    }
                }
                if let current = linked.flatMap(currentEvent(for:)) {
                    Button(PulseLocalization.localizedString("plan.condition.refreshSnapshot")) {
                        link(current.id, to: condition)
                    }
                }
                Button(PulseLocalization.localizedString("plan.condition.unlink"), role: .destructive) {
                    unlink(condition)
                }
            }
        } label: {
            Image(systemName: linked == nil ? "link.badge.plus" : "link")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(linked == nil
            ? PulseLocalization.localizedString("plan.condition.linkEvent")
            : PulseLocalization.localizedString("plan.condition.linkEventManage"))
    }

    /// Points a condition at a live event and leaves it waiting for the user.
    ///
    /// The event is re-read from the live list rather than taken from the menu
    /// label, and the plan is re-read from the store, so a plan edited while the
    /// menu was open is not overwritten from a stale copy. Every other
    /// condition and field rides along untouched.
    private func link(_ eventID: UUID, to condition: TradePlanCondition) {
        guard let event = liveEvents.first(where: { $0.id == eventID }) else {
            errorMessage = PulseLocalization.localizedString("plan.detail.conditionEventGone")
            return
        }
        guard var updated = plan,
              var conditions = updated.conditions,
              let index = conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        conditions[index].eventReference = event
        conditions[index].state = .needsReview
        updated.conditions = conditions
        write(updated, verb: "plan.detail.conditionFailed")
    }

    /// Removes only the event link, and leaves the condition itself alone: the
    /// title, kind, note, source, and review date are the user's own and have
    /// nothing to do with the event. The state becomes `needsReview` because a
    /// condition that was resting on an event link no longer is.
    private func unlink(_ condition: TradePlanCondition) {
        guard var updated = plan,
              var conditions = updated.conditions,
              let index = conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        conditions[index].eventReference = nil
        conditions[index].state = .needsReview
        updated.conditions = conditions
        write(updated, verb: "plan.detail.conditionFailed")
    }

    /// Sets one condition's state, writing the whole plan back.
    ///
    /// Confirming a condition that is linked to an event which has since
    /// changed is the one case that needs a second thought: the user is
    /// asserting the condition is settled, but the ground it stood on moved. The
    /// snapshot is explicitly advanced to the live event in the same write —
    /// which is the only way it is ever refreshed — so the confirmation is
    /// recorded against the event the user just looked at. When the event is
    /// gone there is nothing to advance to, so the change is refused with the
    /// two honest ways forward rather than silently confirming a link whose
    /// subject no longer exists.
    private func setState(_ state: TradePlanCondition.State, for condition: TradePlanCondition) {
        guard var updated = plan else { return }
        var conditions = updated.conditions ?? []
        guard let index = conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        let verdict = linkVerdict(for: condition)
        if state == .confirmed, let reference = conditions[index].eventReference {
            switch verdict {
            case .missing:
                errorMessage = PulseLocalization.localizedString("plan.condition.confirmMissing")
                return
            case .changed:
                guard let current = currentEvent(for: reference) else {
                    errorMessage = PulseLocalization.localizedString("plan.condition.confirmMissing")
                    return
                }
                // The explicit refresh: the user confirmed the event as it
                // stands now, so the snapshot is updated to match in the same
                // write. Nothing else about the condition changes.
                conditions[index].eventReference = current
            case .unchanged, .none:
                break
            }
        }
        conditions[index].state = state
        if state == .confirmed, let date = conditions[index].reviewDate,
           date < Calendar.current.startOfDay(for: .now) {
            conditions[index].reviewDate = nil
        }
        updated.conditions = conditions
        write(updated, verb: "plan.detail.conditionFailed")
    }

    // MARK: - Linked trades

    /// The fills that count toward this plan, read from the same derived
    /// progress the progress bar uses so the two can never disagree.
    ///
    /// A linked trade whose side is the opposite of the plan's is listed but
    /// never counted toward the bar — the progress type requires a matching
    /// kind. Its row says so, and when nothing at all counted the section adds
    /// one line explaining why, rather than leaving a list that looks like it
    /// should have moved the bar and did not.
    private func linkedTradesSection(_ plan: TradePlan) -> some View {
        let progress = TradePlanExecutionProgress(plan: plan, transactions: transactions)
        let expectedKind: PositionTransaction.Kind = plan.kind == .buy ? .buy : .sell
        let linked = transactions
            .filter { transaction in
                transaction.planExecution?.planID == plan.id
                    || (plan.filledTransactionID != nil && transaction.id == plan.filledTransactionID)
            }
            .sorted { $0.date > $1.date }
        return VStack(alignment: .leading, spacing: 5) {
            Text(PulseLocalization.localizedString("plan.detail.linkedTrades"))
                .font(.system(size: 12, weight: .semibold))
            if linked.isEmpty {
                Text(PulseLocalization.localizedString("plan.detail.noTrades"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(linked) { transaction in
                    HStack(spacing: 6) {
                        Text(Self.day(transaction.date))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(PulseLocalization.localizedString(
                            transaction.kind == .sell ? "plan.kind.sell" : "plan.kind.buy"
                        ))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(PlanSideStyle.color(for: transaction.kind))
                        Text("\(PriceFormatter.price(transaction.price, market: symbol.market)) × \(PriceFormatter.quantity(transaction.quantity))")
                            .font(.system(size: 10, design: .monospaced))
                        Text(AccountIdentity.title(transaction.brokerageAccountID ?? account))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if transaction.kind != expectedKind {
                            Text(PulseLocalization.localizedString("plan.detail.notCounted"))
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        // Hands the journal this exact fill. The id is what
                        // carries the intent: the journal resolves it against
                        // its own full entry list, so a row that a filter would
                        // have hidden still opens.
                        Button(PulseLocalization.localizedString("plan.detail.reviewTrade")) {
                            if let owner = transaction.brokerageAccountID { _ = appState.selectBrokerageAccount(owner) }
                            appState.pendingJournalTransactionID = transaction.id
                        }
                        .controlSize(.small)
                    }
                }
                if !progress.hasLinkedTrades {
                    Text(PulseLocalization.localizedString("plan.detail.tradesNotCounted"))
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - History

    /// Oldest first, then the current configuration as the last row, so
    /// reading downward is the same direction the plan moved in. Each row
    /// names only what changed against the row before it.
    private func historySection(_ plan: TradePlan) -> some View {
        let revisions = (plan.history ?? []).sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(PulseLocalization.localizedString("plan.detail.history"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if !revisions.isEmpty {
                    Text(PulseLocalization.localizedString("plan.detail.revisionCount", revisions.count))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if revisions.isEmpty {
                Text(PulseLocalization.localizedString("plan.detail.noHistory"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(revisions.enumerated()), id: \.element.id) { index, revision in
                    historyRow(
                        revision.configuration,
                        date: revision.date,
                        previous: index > 0 ? revisions[index - 1].configuration : nil,
                        isCurrent: false
                    )
                }
            }
            historyRow(
                TradePlanConfiguration(plan: plan),
                date: plan.updatedAt,
                previous: revisions.last?.configuration,
                isCurrent: true
            )
        }
    }

    private func historyRow(
        _ configuration: TradePlanConfiguration,
        date: Date,
        previous: TradePlanConfiguration?,
        isCurrent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Self.day(date))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(isCurrent
                    ? plan.map { planIntentTitle(TradePlanEntry(symbol: symbol, plan: $0, transactions: transactions)) }
                        ?? PulseLocalization.localizedString("plan.status.\(configuration.status.rawValue)")
                    : PulseLocalization.localizedString("plan.status.\(configuration.status.rawValue)"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if isCurrent {
                    Text(PulseLocalization.localizedString("plan.detail.current"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            let changes = Self.changes(from: previous, to: configuration)
            if changes.isEmpty {
                Text(PulseLocalization.localizedString("plan.detail.noChange"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(changes, id: \.self) { change in
                    Text(change)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    /// Only the differences: a revision list that reprinted every field would
    /// bury the one line the reader is looking for.
    private static func changes(
        from previous: TradePlanConfiguration?,
        to current: TradePlanConfiguration
    ) -> [String] {
        func price(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
        }
        func pool(_ value: PositionPool?) -> String {
            value?.title ?? PulseLocalization.localizedString("plan.pool.none")
        }
        func conditionCount(_ value: [TradePlanCondition]?) -> Int {
            value?.count ?? 0
        }

        guard let previous else {
            return [
                PulseLocalization.localizedString("plan.detail.change.set", price(current.price), price(current.quantity), pool(current.positionPool)),
                PulseLocalization.localizedString("plan.detail.change.conditions", conditionCount(current.conditions)),
            ]
        }
        var changes: [String] = []
        if previous.price != current.price {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.price", price(previous.price), price(current.price)
            ))
        }
        if previous.quantity != current.quantity {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.quantity", price(previous.quantity), price(current.quantity)
            ))
        }
        if previous.positionPool != current.positionPool {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.pool", pool(previous.positionPool), pool(current.positionPool)
            ))
        }
        if conditionCount(previous.conditions) != conditionCount(current.conditions) {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.conditions",
                conditionCount(current.conditions)
            ))
        }
        if conditionCount(previous.conditions) == conditionCount(current.conditions), previous.conditions != current.conditions {
            changes.append(PulseLocalization.localizedString("plan.detail.change.logic"))
        }
        if previous.note != current.note {
            changes.append(PulseLocalization.localizedString("plan.detail.change.note"))
        }
        if previous.kind != current.kind {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.kind",
                PulseLocalization.localizedString(
                    current.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"
                )
            ))
        }
        if previous.status != current.status {
            changes.append(PulseLocalization.localizedString(
                "plan.detail.change.status",
                PulseLocalization.localizedString("plan.status.\(current.status.rawValue)")
            ))
        }
        return changes
    }

    // MARK: - Writing conditions

    /// Conditions are edited on a copy of the plan the store holds, so the
    /// store's own revision bookkeeping (and its refusal to write an unchanged
    /// plan) decides what is persisted. An account switch is the one refusal
    /// made here: the plan this page holds belongs to the ledger it was opened
    /// against, and `setTradePlan` would otherwise write it into whichever
    /// account is selected now.
    private func write(_ plan: TradePlan, verb: String) {
        guard accountMatchesDraft else {
            errorMessage = poolCopy(
                "当前账号已切换，此计划不会写入其他账号。请重新打开该计划。",
                "The account changed. This plan will not be written into another account; reopen it."
            )
            return
        }
        let accepted = appState.watchlist.setTradePlan(plan, for: symbol)
        if accepted {
            errorMessage = nil
        } else {
            errorMessage = PulseLocalization.localizedString(verb)
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// An event's date, or its inclusive range, in the calendar the events page
    /// writes dates in. The two surfaces must agree, so this reads the same
    /// calendar rather than `Calendar.current`.
    private static func window(_ event: InstrumentEvent) -> String {
        let calendar = EastmoneyTradingEvents.dateCalendar
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: event.date)
        guard let end = event.endDate else { return start }
        return "\(start) — \(formatter.string(from: end))"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
