import SwiftUI
import PulseCore
import PulseUI

/// A scrollable plan draft. Reload changed plans before saving; the store owns revision history.
struct PlanEditorView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    /// The plan being edited; nil creates a new one.
    let planID: UUID?
    let returnRoute: PositionReturnRoute
    @Binding var route: PopoverRoute

    @State private var kind: TradePlan.Kind = .buy
    @State private var priceText = ""
    @State private var quantityText = ""
    @State private var noteText = ""
    @State private var status: TradePlan.Status = .active
    @State private var executionEntry: TradePlanEntry?
    /// The plan a delete is being requested for. The delete button assigns here
    /// rather than writing: nothing is removed until the confirmation sheet
    /// accepts, and `didSave` is set only by that accepted route.
    @State private var deletionRequest: PlanDeletionRequest?
    /// `nil` is "unassigned" — a plan with no intended bucket. The picker
    /// offers it explicitly; an empty tag would be indistinguishable from
    /// "nothing selected".
    @State private var positionPool: PositionPool?
    /// The money the user *intends* to use. `nil` is "never recorded" — an old
    /// plan keeps that state rather than being defaulted to a value it never
    /// had. It is metadata only: it never creates a fill, and recording a fill
    /// asks for the funding that actually moved instead of reusing this.
    @State private var fundingSource: PositionFundingSource?
    /// Always non-nil while editing. An empty array saves as `[]` (an explicit
    /// "no conditions"); `nil` is reserved for plans that never had the field.
    @State private var conditions: [TradePlanCondition] = []
    @State private var expandedConditionIDs: Set<UUID> = []

    /// The stored plan is read once, on appear: later edits to the draft must
    /// not be overwritten by the store the draft is being written into.
    @State private var didLoad = false
    /// The `updatedAt` this draft was loaded from. Saving with a different one
    /// means another device (or another window) got there first.
    @State private var loadedUpdatedAt: Date?
    /// A save the store refused or that raced a newer plan. Kept visible so the
    /// user can fix the form and retry instead of losing the draft.
    @State private var saveError: String?
    /// Where `saveError` came from: a stale plan needs a reload button, a
    /// rejected payload needs only the form fixed.
    @State private var saveErrorIsStale = false
    /// Return can reach `save()` twice in one keypress (field submit plus the
    /// default action); the first write wins.
    @State private var didSave = false
    /// The account this draft belongs to, frozen when the editor is built. A
    /// plan id alone does not authorize a write: an account switch swaps the
    /// whole ledger behind the same store object, and a plan id that also
    /// exists in the new account would otherwise be edited by a form filled in
    /// for the old one.
    @State private var draftAccount: BrokerageAccountID
    @State private var boundPortionID: UUID?
    @State private var loadedAllocationRevision: UUID?
    /// The instrument a caller picked for a brand-new plan, when the watchlist
    /// does not hold it yet. Read only while `planID == nil` and only for the
    /// symbol it names: it stands in for a missing watchlist row so the form
    /// can be filled in *before* the symbol is a member. The membership itself
    /// is written by a successful save, never by opening this form.
    private let newSymbolInfo: SymbolInfo?
    /// Reports a plan the store accepted. A caller that hosts this editor can
    /// use it to make the new record visible; with no callback the only signal
    /// remains the route change.
    private let onSaved: ((TradePlan) -> Void)?

    init(symbol: SymbolID, planID: UUID?, returnRoute: PositionReturnRoute,
         route: Binding<PopoverRoute>, account: BrokerageAccountID,
         newSymbolInfo: SymbolInfo? = nil,
         onSaved: ((TradePlan) -> Void)? = nil,
         positionPortionID: UUID? = nil) {
        self.symbol = symbol
        self.planID = planID
        self.returnRoute = returnRoute
        self._route = route
        self._draftAccount = State(initialValue: account)
        self.newSymbolInfo = newSymbolInfo
        self.onSaved = onSaved
        self._boundPortionID = State(initialValue: positionPortionID)
    }

    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == draftAccount
    }

    /// Whether the draft's account no longer matches the store: writes are
    /// refused until the user returns to the source account.
    private var showsAccountNotice: Bool { !accountMatchesDraft }

    /// The watchlist row this draft is written into, or — for a new plan whose
    /// symbol the watchlist does not hold yet — a stand-in carrying just the
    /// metadata the form needs. The stand-in never names a stored plan, so a
    /// new plan can only ever be created from it.
    private var item: WatchItem? {
        appState.watchlist.draftItem(for: symbol, account: draftAccount) ?? standInItem
    }

    /// The item the store would build if the chosen symbol were added. `nil`
    /// unless this is a new plan for exactly the symbol the caller picked.
    private var standInItem: WatchItem? {
        guard planID == nil, let newSymbolInfo, newSymbolInfo.symbol == symbol else { return nil }
        return WatchItem(
            symbol: symbol,
            displayName: newSymbolInfo.name,
            displayNameSource: newSymbolInfo.displayNameSource,
            instrumentType: newSymbolInfo.type
        )
    }

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    /// The price label's money, resolved through the one shared rule the plan
    /// row and the fill sheet already use.
    ///
    /// The editor used to say only "Price", which is the same bare number the
    /// plan row was fixed for: a crypto plan's quote is its pair's asset, not
    /// the symbol's market currency, and a label that names no money leaves the
    /// reader to guess which one the field is in. A `nil` here — a crypto pair
    /// whose quote asset did not survive sanitization — keeps the label generic
    /// rather than inventing a currency for it.
    private var priceCurrencyLabel: String? {
        PlanValueText.normalizedQuoteCurrency(currencyCode, symbol: symbol)
    }

    /// The unit the quantity field is counted in, resolved through the shared
    /// helper so the editor, the row that opened it, and the fill sheet cannot
    /// disagree. A brand-new plan whose symbol is not on the watchlist yet reads
    /// the caller's `newSymbolInfo` through `item`'s stand-in.
    private var quantityUnitLabel: String {
        PlanValueText.quantityUnit(symbol: symbol, instrumentType: item?.resolvedInstrumentType)
    }

    private var existingPlan: TradePlan? {
        guard let planID else { return nil }
        return item?.plans.first { $0.id == planID }
    }

    private var sideColor: Color {
        appState.palette.color(isUp: kind == .buy)
    }

    var body: some View {
        VStack(spacing: 0) {
            PositionPageHeader(
                symbol: symbol,
                displayName: planID == nil ? newSymbolInfo?.resolvedDisplayName : nil,
                title: (PulseLocalization.localizedString(
                    planID == nil ? "plan.title.add" : "plan.title.edit"
                ), sideColor),
                accountCaption: AccountIdentity.title(draftAccount),
                onBack: { route = returnRoute.popoverRoute }
            )
            AccountDraftNotice(account: draftAccount)
                .padding(.horizontal, 12)
                .padding(.bottom, accountMatchesDraft ? 0 : 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if boundPortionID != nil { sourcePositionRow } else { kindPicker }
                    HStack(spacing: 8) {
                        PositionInputCell(
                            label: priceLabel,
                            text: $priceText,
                            suggestion: currentPriceSuggestion,
                            autofocus: planID == nil
                        )
                        PositionInputCell(
                            label: quantityLabel,
                            text: $quantityText
                        )
                    }
                    PositionInputCell(
                        label: PulseLocalization.localizedString("plan.note"),
                        text: $noteText
                    )
                    statusPicker
                    if boundPortionID == nil {
                        poolPicker
                        fundingPicker
                    }
                    conditionSection
                    summaryRow
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }

            if accountMatchesDraft, let saveError {
                errorRow(saveError, isStale: saveErrorIsStale, allowsDismiss: true)
            }

            HStack {
                if planID != nil {
                    // `.destructive` alone doesn't color a bordered macOS
                    // button; the label carries the red itself. Pressing it
                    // only *requests* the deletion — the confirmation sheet
                    // owns the write and the route change.
                    Button(role: .destructive) {
                        requestDeletion()
                    } label: {
                        Text(PulseLocalization.localizedString("plan.delete"))
                            .foregroundStyle(.red)
                    }
                    .disabled(showsAccountNotice)
                }
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel")) {
                    route = returnRoute.popoverRoute
                }
                confirmButton
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onSubmit { save() }
        .task { load() }
        .sheet(item: $executionEntry) { entry in
            PlanExecutionSheet(entry: entry, account: draftAccount) {
                let current = existingPlan.map {
                    TradePlanEntry(symbol: symbol, plan: $0,
                        transactions: appState.watchlist.transactionsForPlan(symbol, account: draftAccount))
                }
                executionEntry = nil
                if (current?.filledQuantity ?? 0) > entry.filledQuantity {
                    route = returnRoute.popoverRoute
                }
            }
        }
        // The editor leaves the page only on a deletion the shared modifier
        // actually performed. Requesting or cancelling the confirmation keeps
        // the draft open, so a cancelled delete never looks like a saved one.
        .modifier(PlanDeletionConfirmation(request: $deletionRequest, onDeleted: {
            didSave = true
            route = returnRoute.popoverRoute
        }))
    }

    // MARK: - Form rows

    /// The price field's label: "Price (USD)", or the plain key when no usable
    /// code exists. Both are existing localizable keys, so every language keeps
    /// the wording it already shipped and only gains the currency.
    private var priceLabel: String {
        guard let priceCurrencyLabel else {
            return PulseLocalization.localizedString("plan.price")
        }
        return PulseLocalization.localizedString("trade.priceWithCurrency", priceCurrencyLabel)
    }

    /// The quantity field's label: "Quantity (shares)", "Quantity (BTC)".
    /// `PlanValueText.quantityUnit` always answers — the neutral unit is the
    /// fallback — so this is never a bare number either.
    private var quantityLabel: String {
        PulseLocalization.localizedString("trade.quantityWithUnit", quantityUnitLabel)
    }

    private var boundSource: PositionPortion? {
        guard let boundPortionID, let item, !item.positionAllocationNeedsReconciliation,
              item.positionQuantity > 0, let allocation = item.positionAllocation,
              allocation.isValid, allocation.hasMatchingSources(for: item) else { return nil }
        return allocation.portions.first { $0.id == boundPortionID && $0.quantity.isFinite && $0.quantity > 0 }
    }

    private var availableSourceQuantity: Double {
        guard let boundPortionID, let item else { return 0 }
        return item.availableSalePlanQuantity(for: boundPortionID, excludingPlanID: planID)
    }

    private var filledQuantity: Double {
        guard let existingPlan, let item else { return 0 }
        return TradePlanExecutionProgress(plan: existingPlan, transactions: item.transactions).filledQuantity
    }

    private var sourceIsValid: Bool {
        guard boundPortionID != nil, status == .active else { return true }
        guard let source = boundSource, source.pool.effectivePurpose == positionPool?.effectivePurpose,
              let quantity = parsedQuantity else { return false }
        let remaining = max(0, quantity - filledQuantity)
        return remaining <= availableSourceQuantity + PositionAllocation.quantityTolerance(remaining, availableSourceQuantity)
    }

    private var sourcePositionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(poolCopy("卖出这笔仓位", "Sell this position portion"))
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(sideColor)
            if let source = boundSource {
                Text("\(source.pool.title) · \(PlanValueText.quantity(source.quantity, symbol: symbol, instrumentType: item?.resolvedInstrumentType)) "
                     + poolCopy("份额", "units"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(poolCopy("可设置卖出：", "Available to plan: ")
                     + PlanValueText.quantity(availableSourceQuantity, symbol: symbol, instrumentType: item?.resolvedInstrumentType)
                     + (filledQuantity > 0
                        ? poolCopy(" · 已成交：", " · Filled: ")
                            + PlanValueText.quantity(filledQuantity, symbol: symbol, instrumentType: item?.resolvedInstrumentType)
                        : ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !sourceIsValid {
                    Text(poolCopy("计划剩余数量超过这笔仓位可用数量，请调整数量。", "Reduce the remaining plan quantity to fit this portion."))
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            } else {
                Text(poolCopy("源仓位已变化，无法继续卖出；可以取消这条计划。", "The source portion changed. Cancel this plan or restore its source."))
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(sideColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    /// Two flat buttons sharing the trade page's DNA, so "buy" reads as the up
    /// colour everywhere in the app.
    private var kindPicker: some View {
        HStack(spacing: 8) {
            kindButton(.buy, titleKey: "plan.kind.buy")
            kindButton(.sell, titleKey: "plan.kind.sell")
        }
    }

    private func kindButton(_ value: TradePlan.Kind, titleKey: String) -> some View {
        let selected = kind == value
        let color = appState.palette.color(isUp: value == .buy)
        return Button {
            kind = value
            clearError()
        } label: {
            Text(PulseLocalization.localizedString(titleKey))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(selected ? 0.16 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(selected ? 0.35 : 0.12), lineWidth: 0.5)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Recording executes the stored intention, not an unsaved draft. Require
    /// saving changes first so opening a fill never silently drops those edits.
    private var draftMatchesStoredPlan: Bool {
        guard didLoad, let plan = existingPlan, loadedUpdatedAt == plan.updatedAt else { return false }
        return kind == plan.kind && parsedPrice == plan.price && parsedQuantity == plan.quantity
            && status == plan.status && Self.normalizedNote(noteText) == plan.note
            && positionPool == plan.positionPool && fundingSource == plan.fundingSource
            && boundPortionID == plan.positionPortionID && conditions == (plan.conditions ?? [])
    }

    private var statusPicker: some View {
        let entry = existingPlan.map {
            TradePlanEntry(symbol: symbol, plan: $0,
                transactions: appState.watchlist.transactionsForPlan(symbol, account: draftAccount))
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(PulseLocalization.localizedString("plan.status"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if let entry, entry.displayState == .filled {
                PlanStatusBadge(entry: entry)
            } else {
                Picker("", selection: $status) {
                    ForEach(TradePlan.Status.allCases.filter { $0 != .done || status == .done }, id: \.self) { value in
                        Text(PulseLocalization.localizedString("plan.status.\(value.rawValue)")).tag(value)
                    }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .onChange(of: status) { _, _ in clearError() }
            }
            if let entry, entry.displayState == .waiting {
                Button(PulseLocalization.localizedString("plans.action.recordFill")) { executionEntry = entry }
                    .controlSize(.small)
                    .disabled(!accountMatchesDraft || !draftMatchesStoredPlan)
            } else if let entry, entry.canBackfillFill {
                // A stopped record whose real fill was never completed. The
                // button opens the same fill sheet, which performs the guarded
                // backfill; the plan itself is not revived, because the user
                // already settled it.
                Button(PulseLocalization.localizedString("plans.action.backfill")) { executionEntry = entry }
                    .controlSize(.small)
                    .disabled(!accountMatchesDraft || !draftMatchesStoredPlan)
            }
            // Both fill entrances are gated on the draft matching the stored
            // plan, so both need the same "save first" explanation. A stopped
            // record that can be backfilled is the second one.
            Text(PulseLocalization.localizedString(
                (entry?.displayState == .waiting || entry?.canBackfillFill == true) && !draftMatchesStoredPlan
                    ? "plans.display.saveBeforeFill" : "plans.display.recordHelp"))
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The intended holding bucket. `nil` is a real answer ("not assigned
    /// yet"), so it gets its own visible row rather than being the state you
    /// reach by not touching the picker.
    private var poolPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PulseLocalization.localizedString("plan.pool"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Picker("", selection: $positionPool) {
                Text(PulseLocalization.localizedString("plan.pool.none"))
                    .tag(nil as PositionPool?)
                ForEach(PositionPool.activeCases, id: \.self) { pool in
                    Text(pool.title).tag(Optional(pool))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .onChange(of: positionPool) { _, _ in clearError() }
            Text(PulseLocalization.localizedString("plan.pool.help"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The intended funding. It is a plan *intention*, so it never touches a
    /// transaction: recording the fill asks separately what money actually
    /// moved, and answers can differ without anything being inconsistent.
    ///
    /// The picker is absent on the mengmeng account, which buys with its own
    /// money by construction: there is no intention left to express, and the
    /// `.own` a new plan is saved with is written by `save()` rather than asked
    /// for here. The account still reaches the row wherever the row exists, so
    /// its wording — 担保品 inside the financing account — is the one the
    /// account actually uses.
    @ViewBuilder
    private var fundingPicker: some View {
        if draftAccount != .mengmeng {
            // Copy comes from the shared pool helpers rather than a new
            // localizable key: this batch may not touch the string catalogs, and
            // a missing key would surface as the raw identifier.
            FundingSourcePickerRow(
                label: poolCopy("拟用资金", "Intended funding"),
                selection: $fundingSource,
                help: poolCopy("计划意向，不产生成交；记录成交时会先选择账户，再确认买入方式。",
                               "An intention, not a fill. Recording the fill confirms the money that actually moved."),
                onChange: { clearError() },
                account: draftAccount
            )
        }
    }

    // MARK: - Conditions

    /// Conditions are user-maintained state, not live market checks. The one
    /// thing Pulse judges by itself is the plan's own price, and the footer
    /// below says so, because a list of condition rows otherwise reads as if
    /// the app were watching all of them.
    private var conditionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(PulseLocalization.localizedString("plan.conditions"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    addCondition()
                } label: {
                    Label(
                        PulseLocalization.localizedString("plan.condition.add"),
                        systemImage: "plus"
                    )
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.pressable)
                .controlSize(.small)
            }
            if conditions.isEmpty {
                Text(PulseLocalization.localizedString("plan.condition.empty"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach($conditions) { condition in
                    conditionRow(condition)
                }
            }
            Text(PulseLocalization.localizedString("plan.condition.priceNote"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if showsConditionError {
                Text(PulseLocalization.localizedString("plan.condition.invalid"))
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One condition: the collapsed row is a read-only summary — a title, its
    /// kind, and its state. The controls live inside the disclosure body
    /// rather than in the label, because a `DisclosureGroup` label swallows
    /// clicks for the toggle and a text field placed there cannot be reliably
    /// focused.
    private func conditionRow(_ condition: Binding<TradePlanCondition>) -> some View {
        let id = condition.wrappedValue.id
        return DisclosureGroup(isExpanded: Binding(
            get: { expandedConditionIDs.contains(id) },
            set: { expanded in
                if expanded {
                    expandedConditionIDs.insert(id)
                } else {
                    expandedConditionIDs.remove(id)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    PulseLocalization.localizedString("plan.condition.title"),
                    text: condition.title
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))

                HStack(spacing: 6) {
                    Picker("", selection: condition.kind) {
                        ForEach(TradePlanCondition.Kind.allCases, id: \.self) { value in
                            Text(PulseLocalization.localizedString("plan.condition.kind.\(value.rawValue)"))
                                .tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .fixedSize()

                    Picker("", selection: condition.state) {
                        ForEach(TradePlanCondition.State.allCases, id: \.self) { value in
                            Text(PulseLocalization.localizedString("plan.condition.state.\(value.rawValue)"))
                                .tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.mini)
                    .fixedSize()

                    Spacer(minLength: 0)
                }

                TextField(
                    PulseLocalization.localizedString("plan.condition.note"),
                    text: Binding(
                        get: { condition.wrappedValue.note ?? "" },
                        set: { condition.wrappedValue.note = $0 }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .lineLimit(1...4)

                TextField(
                    PulseLocalization.localizedString("plan.condition.source"),
                    text: Binding(
                        get: { condition.wrappedValue.sourceURL ?? "" },
                        set: { condition.wrappedValue.sourceURL = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))

                reviewDateRow(condition)

                // Delete lives in the body, not the collapsed label: a button
                // inside a `DisclosureGroup` label is consumed by the toggle.
                HStack {
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        removeCondition(condition.wrappedValue.id)
                    } label: {
                        Label(
                            PulseLocalization.localizedString("plan.condition.delete"),
                            systemImage: "trash"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.pressable)
                    .controlSize(.mini)
                }
            }
            .padding(.top, 4)
            .padding(.leading, 2)
        } label: {
            conditionSummary(condition)
        }
        .disclosureGroupStyle(.automatic)
    }

    /// The collapsed face of a condition. No controls: everything that writes
    /// to the draft is one click away in the body.
    private func conditionSummary(_ condition: Binding<TradePlanCondition>) -> some View {
        let value = condition.wrappedValue
        return HStack(spacing: 6) {
            Circle()
                .fill(PlanExecutionSheet.stateColor(value.state))
                .frame(width: 6, height: 6)
            Text(value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? PulseLocalization.localizedString("plan.condition.untitled")
                : value.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Text(PulseLocalization.localizedString("plan.condition.kind.\(value.kind.rawValue)"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(PulseLocalization.localizedString("plan.condition.state.\(value.state.rawValue)"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// A date that is genuinely optional. `Toggle` keeps "no review date" and
    /// "review today" distinguishable; a `DatePicker` bound to a non-optional
    /// date cannot say "unset".
    private func reviewDateRow(_ condition: Binding<TradePlanCondition>) -> some View {
        HStack(spacing: 6) {
            Text(PulseLocalization.localizedString("plan.condition.reviewDate"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { condition.wrappedValue.reviewDate != nil },
                set: { enabled in
                    condition.wrappedValue.reviewDate = enabled
                        ? Calendar.current.startOfDay(for: .now)
                        : nil
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            if condition.wrappedValue.reviewDate != nil {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { condition.wrappedValue.reviewDate ?? .now },
                        set: { condition.wrappedValue.reviewDate = $0 }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }

    private func addCondition() {
        let condition = TradePlanCondition(
            title: "",
            kind: .manual,
            state: .pending
        )
        conditions.append(condition)
        expandedConditionIDs.insert(condition.id)
        clearError()
    }

    private func removeCondition(_ id: UUID) {
        conditions.removeAll { $0.id == id }
        expandedConditionIDs.remove(id)
        clearError()
    }

    /// What the plan comes to at its own price. Reads `—` until both fields
    /// parse rather than flashing a zero, exactly like the trade preview.
    private var summaryRow: some View {
        HStack {
            Text(PulseLocalization.localizedString("plan.amount"))
                .foregroundStyle(.secondary)
            Spacer()
            Text(estimatedAmountText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private var estimatedAmountText: String {
        guard let price = parsedPrice, let quantity = parsedQuantity else { return "—" }
        return PriceFormatter.money(price * quantity, currencyCode: currencyCode)
    }

    /// The live price as a one-click fill. What lands in the field is the price
    /// at the moment of the click and stays put — the plan price is a decision,
    /// not a number that keeps moving.
    private var currentPriceSuggestion: PositionInputCell.Suggestion? {
        guard let quote, quote.price.isFinite, quote.price > 0 else { return nil }
        // The chip shows the market's money beside the field that will hold it.
        // The *fill text* stays a bare number: it becomes the price field's
        // contents, and a currency suffix there would not parse. Only the
        // visible label names the currency.
        let fill = PriceFormatter.price(quote.price, market: symbol.market)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString("trade.currentPrice",
                PlanValueText.price(quote.price, symbol: symbol, currencyCode: currencyCode)),
            help: PulseLocalization.localizedString("plan.useCurrentPrice"),
            fill: { priceText = fill }
        )
    }

    /// Solid fill, not glass — same primary-action treatment as the trade page.
    private var confirmButton: some View {
        Button {
            save()
        } label: {
            Text(PulseLocalization.localizedString("action.save"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .keyboardShortcut(.defaultAction)
        .help(PulseLocalization.localizedString("action.saveHelp"))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(sideColor.opacity(0.92))
        )
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.45)
    }

    private func errorRow(_ message: String, isStale: Bool, allowsDismiss: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !allowsDismiss {
                // The only way out of an account mismatch is a fresh editor
                // built against the account that is selected now.
                Button(PulseLocalization.localizedString("action.cancel")) {
                    route = returnRoute.popoverRoute
                }
                .controlSize(.small)
            } else if isStale {
                Button(PulseLocalization.localizedString("plan.stale.reload")) {
                    reloadFromStore()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Load & save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        loadedAllocationRevision = item?.positionAllocation?.revision
        if let plan = existingPlan {
            load(from: plan)
        } else if boundPortionID != nil {
            kind = .sell
            positionPool = boundSource?.pool.effectivePurpose
            quantityText = Self.fieldText(availableSourceQuantity)
        }
    }

    /// Re-reads the plan after a stale-plan refusal, throwing away the draft's
    /// plan fields but keeping the user on the page. The conditions that were
    /// just refused are gone with the draft; the message says so.
    private func reloadFromStore() {
        guard let plan = existingPlan else {
            if planID == nil, boundPortionID != nil {
                loadedAllocationRevision = item?.positionAllocation?.revision
                positionPool = boundSource?.pool.effectivePurpose
                quantityText = Self.fieldText(availableSourceQuantity)
                clearError()
                return
            }
            route = returnRoute.popoverRoute
            return
        }
        load(from: plan)
        saveError = nil
        saveErrorIsStale = false
        didSave = false
    }

    private func load(from plan: TradePlan) {
        boundPortionID = plan.positionPortionID
        loadedAllocationRevision = item?.positionAllocation?.revision
        kind = plan.kind
        priceText = Self.fieldText(plan.price)
        quantityText = Self.fieldText(plan.quantity)
        noteText = plan.note ?? ""
        status = plan.status
        // Editing explicitly reconfirms the source's current purpose. The
        // stored plan stays unchanged until Save accepts the draft.
        positionPool = boundPortionID == nil ? plan.positionPool : (boundSource?.pool.effectivePurpose ?? plan.positionPool)
        fundingSource = plan.fundingSource
        conditions = plan.conditions ?? []
        expandedConditionIDs = []
        loadedUpdatedAt = plan.updatedAt
    }

    private var parsedPrice: Double? {
        parseDecimal(priceText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private var parsedQuantity: Double? {
        parseDecimal(quantityText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Every condition needs a non-empty title and a link that is really
    /// http/https, and a review date that is a real instant. The store repeats
    /// these checks; failing here keeps the message next to the field.
    private var conditionsAreValid: Bool {
        conditions.allSatisfy { condition in
            !condition.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && condition.title.count <= 240
                && Self.isAcceptableSource(condition.sourceURL)
                && (condition.reviewDate.map { $0.timeIntervalSince1970.isFinite } ?? true)
        }
    }

    private var showsConditionError: Bool {
        saveErrorIsStale == false && saveError != nil && !conditionsAreValid
    }

    /// The product of price and size has to be a real number: two finite
    /// positives can still overflow to infinity, and an amount the app cannot
    /// print is not a plan it should store.
    private var isValid: Bool {
        guard let price = parsedPrice, let quantity = parsedQuantity else { return false }
        let amount = price * quantity
        return amount.isFinite && amount > 0 && conditionsAreValid
    }

    /// Once a save has been accepted there is nothing left to press; before
    /// that, a visible error is not a reason to block a retry. An account
    /// switch does block it: there is no version of this draft that belongs to
    /// the ledger now selected.
    private var canSave: Bool {
        !didSave && isValid && sourceIsValid && accountMatchesDraft && item?.supportsPosition == true
    }

    private func clearError() {
        saveError = nil
        saveErrorIsStale = false
    }
    private func save() {
        guard !didSave, accountMatchesDraft, let item, item.supportsPosition, let price = parsedPrice,
              let quantity = parsedQuantity else {
            return
        }
        let amount = price * quantity
        guard amount.isFinite, amount > 0 else {
            saveError = PulseLocalization.localizedString("plan.error.amount")
            saveErrorIsStale = false
            return
        }
        guard conditionsAreValid else {
            saveError = PulseLocalization.localizedString("plan.error.conditions")
            saveErrorIsStale = false
            return
        }
        guard sourceIsValid else { return }
        if boundPortionID != nil, status == .active,
           loadedAllocationRevision != item.positionAllocation?.revision {
            saveError = poolCopy("仓位已变化，请重新载入后确认数量。", "The position changed. Reload and confirm the quantity.")
            saveErrorIsStale = true
            return
        }
        // The plan this draft was opened from has moved on. Refusing before
        // anything is assembled keeps the message about the plan, not about the
        // form, and leaves `didSave` false so the user can reload and retry.
        if (planID != nil && existingPlan == nil)
            || (existingPlan != nil && loadedUpdatedAt != nil && existingPlan?.updatedAt != loadedUpdatedAt) {
            saveError = PulseLocalization.localizedString("plan.error.stale")
            saveErrorIsStale = true
            return
        }

        // Starting from the stored plan rather than a fresh one is what keeps
        // `filledTransactionID`, `history`, and the plan's own id intact across
        // an edit. `setTradePlan` re-reads `createdAt` itself and appends the
        // prior configuration to `history`; duplicating either here would
        // double-count a revision.
        var plan = existingPlan ?? TradePlan(
            id: planID ?? UUID(),
            kind: kind,
            price: price,
            quantity: quantity
        )
        plan.kind = kind
        plan.price = price
        plan.quantity = quantity
        plan.status = status
        plan.note = Self.normalizedNote(noteText)
        plan.positionPool = positionPool
        plan.positionPortionID = boundPortionID
        // `nil` means the plan never carried a funding intention; picking
        // "未标注" stores the explicit `.unmarked` that says the user cleared it.
        //
        // A new plan written into an account that does not ask the question is
        // `.own`, which is what that account buys with. It is a statement about
        // a plan being created, never about one already on disk: an edit writes
        // back the intention it loaded, so correcting a price cannot become the
        // moment a stored `.margin` (or a deliberate clearing) is rewritten.
        plan.fundingSource = fundingSource
            ?? (existingPlan == nil && kind == .buy && draftAccount == .mengmeng ? .own : nil)
        // An empty list is an explicit "no conditions"; a plan that never had
        // the field keeps `nil` so the two stay distinguishable.
        plan.conditions = conditions.isEmpty && existingPlan?.conditions == nil ? nil : conditions

        didSave = true
        // Add membership only on save, in the frozen financial account. The
        // shared-list facade could instead choose another group's owner.
        if appState.watchlist.item(for: symbol) == nil,
           let standIn = standInItem, standIn.supportsPosition, let newSymbolInfo {
            appState.watchlist.add(newSymbolInfo)
        }
        let accepted = appState.watchlist.setTradePlan(plan, for: item.symbol)
        guard accepted else {
            // The store refused the payload (an instrument that does not
            // support trades, an invalid link, a duplicate condition id). The
            // form stays open with the draft and says so, so the user can fix
            // the field rather than losing what they typed.
            didSave = false
            saveError = PulseLocalization.localizedString("plan.error.rejected")
            saveErrorIsStale = false
            return
        }
        onSaved?(plan)
        route = returnRoute.popoverRoute
    }

    /// Opens the deletion confirmation for the plan this editor loaded.
    ///
    /// Two refusals come first, and neither silently retargets newer data.
    /// An account switch means there is no version of this draft that belongs
    /// to the ledger now selected, and a plan that moved since the editor's
    /// snapshot is not the plan the user was looking at — deleting it by id
    /// would destroy a record nobody in this window ever saw. Both keep the
    /// draft open with the reason visible instead.
    private func requestDeletion() {
        guard !didSave, accountMatchesDraft, let planID else { return }
        guard let plan = existingPlan else {
            saveError = PulseLocalization.localizedString("plan.error.stale")
            saveErrorIsStale = true
            return
        }
        // The stored plan changed under this draft. Refuse before a request is
        // even built, so the sheet can never be confirmed against newer bytes.
        if loadedUpdatedAt != nil, plan.updatedAt != loadedUpdatedAt {
            saveError = PulseLocalization.localizedString("plan.error.stale")
            saveErrorIsStale = true
            return
        }
        deletionRequest = PlanDeletionRequest(
            entry: TradePlanEntry(
                symbol: symbol,
                plan: plan,
                transactions: appState.watchlist.transactionsForPlan(symbol, account: draftAccount)
            ),
            account: draftAccount,
            hasUnsavedDraft: !draftMatchesStoredPlan
        )
    }

    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    private static func normalizedNote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Mirrors `InstrumentEvent.isValidSourceURL`, which is not public: no
    /// whitespace, an http/https scheme, and a host.
    private static func isAcceptableSource(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.url != nil else { return false }
        return components.port.map { (1...65_535).contains($0) } ?? true
    }

    /// Field prefill that keeps full precision instead of the display rounding
    /// `PriceFormatter` applies, so editing and saving without touching a field
    /// never silently re-rounds a price.
    private static func fieldText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
    }
}
