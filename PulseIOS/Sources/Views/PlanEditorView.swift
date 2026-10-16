import SwiftUI
import PulseCore
import PulseUI

// MARK: - Plan editor
//
// A plan is an *intention*. This form writes the intention only: it can never
// produce a fill, change a holding, or mark a manual condition confirmed from a
// quote.
//
// The original record is frozen when the sheet opens:
//
//   - `sourceAccount` — the ledger the plan belongs to. A global account switch
//     mid-edit cannot move a half-filled plan into another book.
//   - `original` — the exact stored plan the draft was built from, and its
//     `updatedAt`. `savePlan` compares both and fails closed on a stale draft
//     rather than overwriting a peer's edit.
//   - `planID` / `createdAt` — the plan's identity. An edit keeps them; the
//     store preserves `createdAt` and appends the prior configuration to
//     history on its own.
struct PlanEditorTarget: Identifiable {
    enum Mode {
        case create(symbol: SymbolID)
        case edit(TradePlanEntry)
    }

    let id = UUID()
    let mode: Mode
    /// The ledger this form was opened against. Carried on the target rather
    /// than read from live state at submit time, so a global account switch
    /// while the sheet is open cannot redirect the write.
    let sourceAccount: BrokerageAccountID
    var newSymbolInfo: SymbolInfo? = nil

    static func create(symbol: SymbolID, account: BrokerageAccountID) -> PlanEditorTarget {
        PlanEditorTarget(mode: .create(symbol: symbol), sourceAccount: account)
    }
    static func create(info: SymbolInfo, account: BrokerageAccountID) -> PlanEditorTarget {
        PlanEditorTarget(mode: .create(symbol: info.symbol), sourceAccount: account, newSymbolInfo: info)
    }
    static func edit(_ entry: TradePlanEntry, account: BrokerageAccountID) -> PlanEditorTarget {
        PlanEditorTarget(mode: .edit(entry), sourceAccount: account)
    }
}

struct PlanEditorView: View {
    let target: PlanEditorTarget

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    // Frozen at first render.
    @State private var symbol: SymbolID
    @State private var sourceAccount: BrokerageAccountID
    @State private var original: TradePlan?
    @State private var planID: UUID
    @State private var createdAt: Date

    // Draft.
    @State private var kind: TradePlan.Kind
    @State private var priceText: String
    @State private var quantityText: String
    @State private var note: String
    @State private var conditions: [TradePlanCondition]
    @State private var fundingSource: PositionFundingSource?
    @State private var positionPool: PositionPool
    @State private var executionAccount: BrokerageAccountID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var editingCondition: TradePlanCondition?

    init(target: PlanEditorTarget) {
        self.target = target
        switch target.mode {
        case .create(let symbol):
            _symbol = State(initialValue: symbol)
            _sourceAccount = State(initialValue: target.sourceAccount)
            _original = State(initialValue: nil)
            _planID = State(initialValue: UUID())
            _createdAt = State(initialValue: .now)
            _kind = State(initialValue: .buy)
            _priceText = State(initialValue: "")
            _quantityText = State(initialValue: "")
            _note = State(initialValue: "")
            _conditions = State(initialValue: [])
            // Same as Mac: a NEW cash-account buy carries own-funds intent.
            // Editing an old plan never rewrites missing or explicit metadata.
            _fundingSource = State(initialValue: target.sourceAccount == .mengmeng ? .own : nil)
            _positionPool = State(initialValue: .unassigned)
            _executionAccount = State(initialValue: nil)
        case .edit(let entry):
            let plan = entry.plan
            _symbol = State(initialValue: entry.symbol)
            _sourceAccount = State(initialValue: entry.accountID ?? target.sourceAccount)
            // The stored plan, by value. This is the version `savePlan` compares
            // against, so a peer edit between opening and saving is refused.
            _original = State(initialValue: plan)
            _planID = State(initialValue: plan.id)
            _createdAt = State(initialValue: plan.createdAt)
            _kind = State(initialValue: plan.kind)
            _priceText = State(initialValue: TradeEntryView.editableNumber(plan.price))
            _quantityText = State(initialValue: TradeEntryView.editableNumber(plan.quantity))
            _note = State(initialValue: plan.note ?? "")
            _conditions = State(initialValue: plan.conditions ?? [])
            _fundingSource = State(initialValue: plan.fundingSource)
            _positionPool = State(initialValue: plan.positionPool ?? .unassigned)
            _executionAccount = State(initialValue: plan.executionAccountID)
        }
    }

    private var isEditing: Bool { original != nil }
    private var market: Market { symbol.market }
    private var item: WatchItem? { state.watchlist.item(for: symbol) }
    private var reachesQuantity: Double? { TradeEntryView.parse(quantityText) }
    private var reachesPrice: Double? { TradeEntryView.parse(priceText) }

    private var canSubmit: Bool {
        guard let price = reachesPrice, price > 0,
              let quantity = reachesQuantity, quantity > 0,
              !isSubmitting else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intentNotice
                    instrumentCard
                    valueCard
                    conditionsSection
                    metadataSection
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle(isEditing ? "编辑计划" : "新建计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { submit() }
                        .accessibilityIdentifier("plan.save")
                        .disabled(!canSubmit)
                        .fontWeight(.semibold)
                }
            }
            .sheet(item: $editingCondition) { condition in
                ConditionEditorView(condition: condition) { updated in
                    apply(updated)
                } onDelete: {
                    conditions.removeAll { $0.id == condition.id }
                }
            }
        }
        .workbenchError($errorMessage)
    }

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Sections

    private var intentNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "target")
                .font(.footnote)
                .foregroundStyle(WorkbenchTheme.blue)
            Text("计划记录的是意图。到价不是成交，手工条件也需要你自己复核。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var instrumentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(target.newSymbolInfo?.resolvedDisplayName ?? state.displayName(symbol))
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(symbol.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let price = state.freshPrice(symbol) {
                    Text("现价 \(WorkbenchFormat.price(price, market: market))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("方向", selection: $kind) {
                Text("买入计划").tag(TradePlan.Kind.buy)
                Text("卖出计划").tag(TradePlan.Kind.sell)
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)

            if kind == .sell, isEditing {
                Text("卖出计划绑定到具体份额卡时，共享规则会在记录成交时复核来源卡是否仍然匹配。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var valueCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                editorField(title: "目标价格（\(market.currencyCode)）", text: $priceText, id: "plan.price")
                editorField(title: "计划数量（股）", text: $quantityText, id: "plan.quantity")
            }
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("这个方向的含义")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(kind == .buy
                         ? "买入：报价跌到目标价或更低时条件到达。"
                         : "卖出：报价涨到目标价或更高时条件到达。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    if let price = reachesPrice, let quantity = reachesQuantity {
                        Text("预计金额 \(WorkbenchFormat.money(price * quantity, currencyCode: market.currencyCode))（按计划价，不是成交价）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func editorField(title: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            TextField("必填", text: text)
                .accessibilityIdentifier(id)
                .keyboardType(.decimalPad)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .textFieldStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorkbenchTheme.cardBackground(colorScheme))
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: Conditions

    private var conditionsSection: some View {
        WorkbenchSection(
            title: "手工条件",
            actionTitle: "添加",
            action: {
                editingCondition = TradePlanCondition(title: "", kind: .manual)
            }
        ) {
            WorkbenchCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    if conditions.isEmpty {
                        Text("可以加一条只有在你自己确认后才算完成的条件，例如「看完财报再决定」。系统不会自动勾选。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(conditions) { condition in
                                Button {
                                    editingCondition = condition
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(condition.title.isEmpty ? "未命名条件" : condition.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                            HStack(spacing: 5) {
                                                WorkbenchTag(text: PlanStatusText.label(for: condition.kind))
                                                Text(PlanStatusText.label(for: condition.state))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 6)
                                        Image(systemName: "chevron.right")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if condition.id != conditions.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func apply(_ updated: TradePlanCondition) {
        if let index = conditions.firstIndex(where: { $0.id == updated.id }) {
            conditions[index] = updated
        } else {
            conditions.append(updated)
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        WorkbenchCard(padding: 12) {
            VStack(spacing: 0) {
                HStack {
                    Text("资金方式意向")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("资金方式意向", selection: $fundingSource) {
                        Text("未填写").tag(PositionFundingSource?.none)
                        Text("自有资金").tag(PositionFundingSource?.some(.own))
                        Text("融资").tag(PositionFundingSource?.some(.margin))
                        Text("清空标注").tag(PositionFundingSource?.some(.unmarked))
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 42)
                Divider()

                HStack {
                    Text("持仓池")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("持仓池", selection: $positionPool) {
                        ForEach(PositionPool.activeCases, id: \.self) { pool in
                            Text(PlanStatusText.label(for: pool)).tag(pool)
                        }
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 42)
                Divider()

                HStack {
                    Text("预期执行账户")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("预期执行账户", selection: $executionAccount) {
                        Text("未指定").tag(BrokerageAccountID?.none)
                        ForEach(BrokerageAccountID.allCases.filter { $0 != .unassigned }) { account in
                            Text(state.accountName(account)).tag(BrokerageAccountID?.some(account))
                        }
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 42)
                Text("这只是意向。记成交时会再明确选择实际成交账户，两者可以不同。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("备注")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("为什么是这个价格和数量", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .padding(.vertical, 8)

                Divider()

                FactRow(name: "计划账户", value: state.accountName(sourceAccount))
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkbenchTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("没有保存，草稿仍然保留")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(WorkbenchTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Submit

    private func submit() {
        guard canSubmit, let price = reachesPrice, let quantity = reachesQuantity else {
            errorMessage = "请填写有效的目标价格和数量。"
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        var plan = original ?? TradePlan(
            id: planID,
            kind: kind,
            price: price,
            quantity: quantity,
            createdAt: createdAt
        )
        // Identity and origin are never rewritten by an edit.
        plan.id = planID
        plan.createdAt = createdAt
        plan.kind = kind
        plan.price = price
        plan.quantity = quantity
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        plan.note = trimmedNote.isEmpty ? nil : trimmedNote
        plan.conditions = conditions.isEmpty ? nil : conditions
        plan.fundingSource = fundingSource
        plan.positionPool = positionPool == .unassigned ? nil : positionPool
        plan.executionAccountID = executionAccount
        // `status`, `history` and `filledTransactionID` belong to the store:
        // a plan edit must not reset the user's own stop decision, must not
        // rewrite the recorded revisions, and must not orphan a captured fill.

        do {
            try state.savePlan(
                plan,
                symbol: symbol,
                expected: original,
                // The plan's owning ledger, frozen when the form opened. A
                // global switch to another account cannot redirect this write.
                account: sourceAccount,
                newSymbolInfo: target.newSymbolInfo
            )
            dismiss()
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Condition editor

struct ConditionEditorView: View {
    let condition: TradePlanCondition
    let onSave: (TradePlanCondition) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var kind: TradePlanCondition.Kind
    @State private var conditionState: TradePlanCondition.State
    @State private var note: String
    @State private var errorMessage: String?

    init(
        condition: TradePlanCondition,
        onSave: @escaping (TradePlanCondition) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.condition = condition
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: condition.title)
        _kind = State(initialValue: condition.kind)
                _note = State(initialValue: condition.note ?? "")
        _conditionState = State(initialValue: condition.state)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkbenchCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("条件内容")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("例如：看完财报再决定", text: $title, axis: .vertical)
                                .lineLimit(1...3)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                    }

                    WorkbenchCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("类型", selection: $kind) {
                                ForEach(TradePlanCondition.Kind.allCases, id: \.self) { kind in
                                    Text(PlanStatusText.label(for: kind)).tag(kind)
                                }
                            }
                            Divider()
                            Picker("状态", selection: $conditionState) {
                                ForEach(TradePlanCondition.State.allCases, id: \.self) { state in
                                    Text(PlanStatusText.label(for: state)).tag(state)
                                }
                            }
                        }
                    }

                    WorkbenchCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("说明")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("补充判断标准", text: $note, axis: .vertical)
                                .lineLimit(2...5)
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                        }
                    }

                    Text("手工条件的状态只有你能改。行情到达不会自动确认任何条件。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Text("删除这条条件")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 42)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("手工条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            errorMessage = "请填写条件内容。"
                            return
                        }
                        var updated = condition
                        updated.title = trimmed
                        updated.kind = kind
                        updated.state = conditionState
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.note = trimmedNote.isEmpty ? nil : trimmedNote
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .workbenchError($errorMessage)
    }
}
