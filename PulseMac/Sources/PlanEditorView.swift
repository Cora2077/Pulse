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
    @State private var accountChangedMessage: String?

    init(symbol: SymbolID, planID: UUID?, returnRoute: PositionReturnRoute,
         route: Binding<PopoverRoute>, account: BrokerageAccountID) {
        self.symbol = symbol
        self.planID = planID
        self.returnRoute = returnRoute
        self._route = route
        _draftAccount = State(initialValue: account)
    }

    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == draftAccount
    }

    /// Whether the draft's account no longer matches the store: writes are
    /// refused and the footer offers a reload instead.
    private var showsAccountNotice: Bool { accountChangedMessage != nil }

    private var item: WatchItem? { appState.watchlist.item(for: symbol) }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

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
                title: (PulseLocalization.localizedString(
                    planID == nil ? "plan.title.add" : "plan.title.edit"
                ), sideColor),
                accountCaption: AccountIdentity.title(draftAccount),
                onBack: { route = returnRoute.popoverRoute }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    kindPicker
                    HStack(spacing: 8) {
                        PositionInputCell(
                            label: PulseLocalization.localizedString("plan.price"),
                            text: $priceText,
                            suggestion: currentPriceSuggestion,
                            autofocus: planID == nil
                        )
                        PositionInputCell(
                            label: PulseLocalization.localizedString("position.quantity"),
                            text: $quantityText
                        )
                    }
                    PositionInputCell(
                        label: PulseLocalization.localizedString("plan.note"),
                        text: $noteText
                    )
                    statusPicker
                    poolPicker
                    fundingPicker
                    conditionSection
                    summaryRow
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }

            if let accountChangedMessage {
                errorRow(accountChangedMessage, isStale: false, allowsDismiss: false)
            } else if let saveError {
                errorRow(saveError, isStale: saveErrorIsStale, allowsDismiss: true)
            }

            HStack {
                if planID != nil {
                    // `.destructive` alone doesn't color a bordered macOS
                    // button; the label carries the red itself.
                    Button(role: .destructive) {
                        deletePlan()
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
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            noteAccountChange()
        }
    }

    /// One line when the ledger underneath this draft changed. The draft is not
    /// re-pointed at the new account; it is refused, and the user is told to
    /// reopen the editor.
    private func noteAccountChange() {
        guard !accountMatchesDraft else { return }
        accountChangedMessage = poolCopy(
            "当前账号已切换，本页草稿不会写入其他账号。请重新打开计划编辑。",
            "The account changed. This draft will not be written into another account; reopen the plan editor."
        )
    }

    // MARK: - Form rows

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

    private var statusPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PulseLocalization.localizedString("plan.status"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Picker("", selection: $status) {
                ForEach(TradePlan.Status.allCases, id: \.self) { value in
                    Text(PulseLocalization.localizedString("plan.status.\(value.rawValue)"))
                        .tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .onChange(of: status) { _, _ in clearError() }
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
    private var fundingPicker: some View {
        // Copy comes from the shared pool helpers rather than a new
        // localizable key: this batch may not touch the string catalogs, and a
        // missing key would surface as the raw identifier.
        FundingSourcePickerRow(
            label: poolCopy("拟用资金", "Intended funding"),
            selection: $fundingSource,
            help: poolCopy("计划意向，不产生成交；记录成交时会再确认实际资金来源。",
                           "An intention, not a fill. Recording the fill confirms the money that actually moved."),
            onChange: { clearError() }
        )
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
        let price = PriceFormatter.price(quote.price, market: symbol.market)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString("trade.currentPrice", price),
            help: PulseLocalization.localizedString("plan.useCurrentPrice"),
            fill: { priceText = price }
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
        guard let plan = existingPlan else { return }
        kind = plan.kind
        priceText = Self.fieldText(plan.price)
        quantityText = Self.fieldText(plan.quantity)
        noteText = plan.note ?? ""
        status = plan.status
        positionPool = plan.positionPool
        fundingSource = plan.fundingSource
        // A plan with no stored condition list keeps `nil` on save; only a plan
        // that already has one starts from it.
        conditions = plan.conditions ?? []
        loadedUpdatedAt = plan.updatedAt
    }

    /// Re-reads the plan after a stale-plan refusal, throwing away the draft's
    /// plan fields but keeping the user on the page. The conditions that were
    /// just refused are gone with the draft; the message says so.
    private func reloadFromStore() {
        guard let plan = existingPlan else {
            route = returnRoute.popoverRoute
            return
        }
        load(from: plan)
        saveError = nil
        saveErrorIsStale = false
        didSave = false
    }

    private func load(from plan: TradePlan) {
        kind = plan.kind
        priceText = Self.fieldText(plan.price)
        quantityText = Self.fieldText(plan.quantity)
        noteText = plan.note ?? ""
        status = plan.status
        positionPool = plan.positionPool
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
        !didSave && isValid && !showsAccountNotice
    }

    private func clearError() {
        saveError = nil
        saveErrorIsStale = false
    }
    private func save() {
        guard !didSave, accountMatchesDraft, let item, let price = parsedPrice,
              let quantity = parsedQuantity else {
            noteAccountChange()
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
        // `nil` means the plan never carried a funding intention; picking
        // "未标注" stores the explicit `.unmarked` that says the user cleared it.
        plan.fundingSource = fundingSource
        // An empty list is an explicit "no conditions"; a plan that never had
        // the field keeps `nil` so the two stay distinguishable.
        plan.conditions = conditions.isEmpty && existingPlan?.conditions == nil ? nil : conditions

        didSave = true
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
        route = returnRoute.popoverRoute
    }

    private func deletePlan() {
        guard !didSave, accountMatchesDraft, let planID else {
            noteAccountChange()
            return
        }
        didSave = true
        appState.watchlist.deleteTradePlan(planID, for: symbol)
        route = returnRoute.popoverRoute
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
