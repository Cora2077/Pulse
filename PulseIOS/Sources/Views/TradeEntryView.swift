import SwiftUI
import PulseCore
import PulseUI

// MARK: - Trade entry
//
// Records a trade that has *already happened* at the user's broker. Nothing on
// this screen places an order, and the wording never implies one.
//
// Three facts are frozen when the sheet opens and never recomputed:
//
//  1. `sourceAccount` — the ledger the user was looking at. If the global
//     account switch moves while this form is open, the write still targets the
//     original ledger, so a half-filled draft can never land in another book.
//  2. `original` — for an edit, the exact stored record the draft was built
//     from. A peer edit makes the save fail closed rather than overwrite.
//  3. `planContext` / `planSourceAccount` — the plan whose progress this fill
//     advances, and the ledger that owned it when the form opened.
//
// The actual execution account is a separate, explicit choice. It may legally
// differ from the plan's source ledger (a plan written in one account, executed
// in another), and when it does the caller passes the plan's original ledger as
// `planSourceAccount` so the shared store can check the cross-ledger rules
// rather than being told the two are the same.
struct TradeEntryContext: Identifiable {
    enum Mode {
        case create
        case edit(original: PositionTransaction)
    }

    let id = UUID()
    var symbol: SymbolID
    var mode: Mode = .create
    /// The ledger this form was opened against. Frozen.
    var sourceAccount: BrokerageAccountID
    /// The plan this fill is recorded against, if any. Frozen.
    var plan: TradePlan?
    /// The ledger that owned `plan` when this form opened. Frozen.
    var planSourceAccount: BrokerageAccountID?
    /// Pre-selects the kind for a new trade. Ignored when editing.
    var initialKind: PositionTransaction.Kind = .buy
    /// True when the plan is stopped and this is a controlled backfill.
    var isBackfill = false

    static func global(symbol: SymbolID, account: BrokerageAccountID) -> TradeEntryContext {
        TradeEntryContext(symbol: symbol, sourceAccount: account)
    }

    static func editing(_ original: PositionTransaction, symbol: SymbolID, account: BrokerageAccountID) -> TradeEntryContext {
        TradeEntryContext(symbol: symbol, mode: .edit(original: original), sourceAccount: account)
    }

    static func fromPlan(_ entry: TradePlanEntry, backfill: Bool) -> TradeEntryContext {
        TradeEntryContext(
            symbol: entry.symbol,
            sourceAccount: entry.accountID ?? .unassigned,
            plan: entry.plan,
            planSourceAccount: entry.accountID,
            initialKind: entry.plan.kind == .buy ? .buy : .sell,
            isBackfill: backfill
        )
    }
}

struct TradeEntryView: View {
    let context: TradeEntryContext
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    // Frozen at first render. `@State` initialisation is the freeze: these
    // values are seeded once from `context` and are never re-read from the live
    // store, so a global account switch or a peer edit mid-edit cannot retarget
    // the write.
    @State private var sourceAccount: BrokerageAccountID
    @State private var original: PositionTransaction?
    @State private var plan: TradePlan?
    @State private var planSourceAccount: BrokerageAccountID?
    @State private var transactionID: UUID
    @State private var createdAt: Date

    // Draft fields.
    @State private var kind: PositionTransaction.Kind
    @State private var executionAccount: BrokerageAccountID?
    @State private var priceText: String = ""
    @State private var quantityText: String = ""
    @State private var feeText: String = ""
    @State private var date: Date = .now
    @State private var fundingSource: PositionFundingSource?
    @State private var note: String = ""
    @State private var linkedPlanID: UUID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showsPreview = false

    init(context: TradeEntryContext, onOpenRoute: ((WorkbenchRoute) -> Void)? = nil) {
        self.context = context
        self.onOpenRoute = onOpenRoute
        _sourceAccount = State(initialValue: context.sourceAccount)
        _original = State(initialValue: {
            if case .edit(let original) = context.mode { return original }
            return nil
        }())
        _plan = State(initialValue: context.plan)
        _planSourceAccount = State(initialValue: context.planSourceAccount)
        // A stable id for the duration of the form. Retrying a failed save
        // reuses it, so the store's idempotency check recognises the retry as
        // the same event instead of writing a second one.
        _transactionID = State(initialValue: {
            if case .edit(let original) = context.mode { return original.id }
            return UUID()
        }())
        _createdAt = State(initialValue: {
            if case .edit(let original) = context.mode { return original.createdAt }
            return .now
        }())
        _kind = State(initialValue: {
            if case .edit(let original) = context.mode { return original.kind }
            return context.initialKind
        }())
        _executionAccount = State(initialValue: {
            if case .edit(let original) = context.mode {
                return original.brokerageAccountID ?? context.sourceAccount
            }
            // The plan's intended account is a suggestion the user must confirm,
            // never a silent default; the source ledger is preselected because
            // that is where the form was opened from.
            return context.sourceAccount
        }())
        _fundingSource = State(initialValue: {
            if case .edit(let original) = context.mode { return original.fundingSource }
            return context.plan?.fundingSource
        }())
        _date = State(initialValue: {
            if case .edit(let original) = context.mode { return original.date }
            return Self.marketTradeDay(for: context.symbol.market)
        }())
        _note = State(initialValue: {
            if case .edit(let original) = context.mode { return original.note ?? "" }
            return ""
        }())
        _feeText = State(initialValue: {
            if case .edit(let original) = context.mode, let fee = original.fee {
                return Self.editableNumber(fee)
            }
            return ""
        }())
        _priceText = State(initialValue: {
            if case .edit(let original) = context.mode { return Self.editableNumber(original.price) }
            return ""
        }())
        _quantityText = State(initialValue: {
            if case .edit(let original) = context.mode { return Self.editableNumber(original.quantity) }
            return ""
        }())
        _linkedPlanID = State(initialValue: {
            if case .edit(let original) = context.mode { return original.planExecution?.planID }
            return context.plan?.id
        }())
    }

    // MARK: Derived

    private var item: WatchItem? {
        let portfolio = state.watchlist.brokeragePortfolio(for: executionAccount ?? sourceAccount)
        return (portfolio.items + portfolio.retainedHistoryItems).first { $0.symbol == context.symbol }
    }
    private var market: Market { context.symbol.market }
    private var quote: Quote? { state.quote(context.symbol) }
    private var freshness: QuoteFreshness { QuoteFreshness(quote) }
    private var isEditing: Bool { original != nil }

    private var displayName: String { state.displayName(context.symbol) }

    private var accountOptions: [BrokerageAccountID] {
        BrokerageAccountID.allCases.filter { $0 != .unassigned }
    }

    private var parsedPrice: Double? { Self.parse(priceText) }
    private var parsedQuantity: Double? { Self.parse(quantityText) }
    private var parsedFee: Double? {
        let trimmed = feeText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Self.parse(trimmed)
    }

    private var canSubmit: Bool {
        guard let price = parsedPrice, price > 0,
              let quantity = parsedQuantity, quantity > 0,
              executionAccount != nil,
              !isSubmitting else { return false }
        if let fee = parsedFee, fee < 0 { return false }
        if !feeText.trimmingCharacters(in: .whitespaces).isEmpty, parsedFee == nil { return false }
        return true
    }

    private var remainingPlanQuantity: Double? {
        guard let plan else { return nil }
        let transactions = state.watchlist.transactionsForPlan(context.symbol, account: planSourceAccount ?? sourceAccount, planID: plan.id)
        let progress = TradePlanExecutionProgress(plan: plan, transactions: transactions)
        return progress.remainingQuantity
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    disclaimer
                    accountCard
                    instrumentCard
                    valueCard
                    detailCard
                    planLinkCard
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    previewCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle(isEditing ? "修改成交记录" : "记成交")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { showsPreview = true }
                        .accessibilityIdentifier("trade.save")
                        .disabled(!canSubmit)
                        .fontWeight(.semibold)
                }
            }
        }
        .workbenchError($errorMessage)
        .confirmationDialog("核对真实成交记录", isPresented: $showsPreview, titleVisibility: .visible) {
            Button("确认保存记录") { submit() }
            Button("继续核对", role: .cancel) {}
        } message: {
            Text("\(state.accountName(executionAccount ?? sourceAccount)) · \(displayName)\n实际价格 \(priceText) \(market.currencyCode)，数量 \(quantityText)\n只记账，不向券商下单。")
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    // MARK: Sections

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.footnote)
                .foregroundStyle(WorkbenchTheme.blue)
            Text(isEditing
                 ? "修改已经发生的成交事实。保存前会展示对资金与持仓的影响。"
                 : "记录一笔已经完成的交易，不会向券商下单，也不会自动交易。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("实际成交账户")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(WorkbenchTheme.blue)
                    Text(state.accountName(executionAccount ?? sourceAccount))
                        .font(.headline)
                    Spacer(minLength: 8)
                    if accountOptions.count > 1 && !isEditing {
                        Menu {
                            ForEach(accountOptions) { account in
                                Button {
                                    executionAccount = account
                                } label: {
                                    if account == executionAccount {
                                        Label(state.accountName(account), systemImage: "checkmark")
                                    } else {
                                        Text(state.accountName(account))
                                    }
                                }
                            }
                        } label: {
                            Text("更改").font(.subheadline.weight(.medium))
                        }
                    }
                }
                Text("写入账户在打开表单时已固定，全局切换账户不会把这份草稿写到别的账本。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if executionAccount != sourceAccount {
                    WorkbenchTag(text: "与打开时账户不同", color: WorkbenchTheme.warning)
                }
            }
        }
    }

    private var instrumentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 8)
                WorkbenchTag(text: kindLabel, color: kind == .buy ? WorkbenchTheme.blue : WorkbenchTheme.down)
            }
            Text("\(context.symbol.description) · \(WorkbenchFormat.currencyName(market.currencyCode)) / 股")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let quote {
                HStack(spacing: 8) {
                    Text(WorkbenchFormat.price(quote.price, market: market))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    Text(WorkbenchFormat.percent(Self.changePercent(quote)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.color(for: quote.price - quote.previousClose))
                    if let label = freshness.label {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("参考价").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("参考价只是行情，不会自动填成实际成交价。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无行情参考价。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isEditing {
                Picker("方向", selection: $kind) {
                    Text("买入").tag(PositionTransaction.Kind.buy)
                    Text("卖出").tag(PositionTransaction.Kind.sell)
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)
                .disabled(context.plan != nil)
                if context.plan != nil {
                    Text("本次成交方向由关联计划决定，不能在这里改变。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var kindLabel: String {
        switch kind {
        case .buy: "记录买入"
        case .sell: "记录卖出"
        case .adjustment: "记录校准"
        }
    }

    private var valueCard: some View {
        HStack(spacing: 10) {
            numberField(
                title: "实际成交价（\(market.currencyCode)）",
                text: $priceText
            )
            numberField(
                title: "本次成交数量（股）",
                text: $quantityText
            )
        }
    }

    private func numberField(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            TextField("必填", text: text)
                .accessibilityLabel(title)
                .accessibilityIdentifier(title.hasPrefix("实际成交价") ? "trade.price" : "trade.quantity")
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

    private var detailCard: some View {
        WorkbenchCard(padding: 12) {
            VStack(spacing: 0) {
                DatePicker("成交日期", selection: $date, displayedComponents: .date)
                    .font(.subheadline)
                Divider()

                HStack {
                    Text("费用（\(market.currencyCode)）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    TextField("可选", text: $feeText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(maxWidth: 120)
                }
                .frame(minHeight: 40)
                Divider()

                HStack {
                    Text("资金方式")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("资金方式", selection: $fundingSource) {
                        Text("未填写").tag(PositionFundingSource?.none)
                        if isEditing { Text("明确清除标记").tag(PositionFundingSource?.some(.unmarked)) }
                        Text("自有资金").tag(PositionFundingSource?.some(.own))
                        if permitsMargin {
                            Text("融资").tag(PositionFundingSource?.some(.margin))
                        }
                    }
                    .labelsHidden()
                }
                .frame(minHeight: 40)
                if !permitsMargin {
                    Text("只有融资账户可以记录融资买入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("执行原因（可选）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("为什么做这笔", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var permitsMargin: Bool {
        guard let executionAccount else { return false }
        return executionAccount.buyFundingSources.contains(.margin)
    }

    private var planLinkCard: some View {
        WorkbenchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("关联计划")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let plan {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(planSummary(plan))
                                .font(.subheadline.weight(.medium))
                            if let banner = planSourceBanner {
                                Text(banner)
                                    .font(.caption2)
                                    .foregroundStyle(WorkbenchTheme.warning)
                            }
                        }
                        Spacer(minLength: 8)
                        if !isEditing, context.isBackfill {
                            WorkbenchTag(text: "受控补录", color: WorkbenchTheme.warning)
                        }
                    }
                } else {
                    Text("这笔成交不关联任何计划。计划进度只从真实成交计算。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var planSourceBanner: String? {
        guard let planSourceAccount, planSourceAccount != executionAccount else { return nil }
        return "计划记录在「\(state.accountName(planSourceAccount))」，本次成交写入「\(state.accountName(executionAccount ?? sourceAccount))」。两个账本都会按共享规则复核。"
    }

    private func planSummary(_ plan: TradePlan) -> String {
        let kindText = plan.kind == .buy ? "买入" : "卖出"
        let target = WorkbenchFormat.price(plan.price, market: market)
        let planned = WorkbenchFormat.quantity(plan.quantity)
        var text = "\(kindText)计划 · 目标 \(target) · 计划 \(planned) 股"
        if let remaining = remainingPlanQuantity {
            text += " · 剩余 \(WorkbenchFormat.quantity(remaining)) 股"
        }
        return text
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(WorkbenchTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("没有写入，草稿仍然保留")
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

    /// The pre-save impact check. Quantities come from the real ledger; a value
    /// we cannot compute is shown as an em dash rather than guessed.
    private var previewCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("保存前核对")
                    .font(.subheadline.weight(.semibold))

                if let plan, let remaining = remainingPlanQuantity {
                    let filled = plan.quantity - remaining
                    let thisFill = parsedQuantity ?? 0
                    let after = max(0, remaining - thisFill)
                    Text("计划已记：\(WorkbenchFormat.quantity(filled)) → \(WorkbenchFormat.quantity(min(plan.quantity, filled + thisFill))) / \(WorkbenchFormat.quantity(plan.quantity)) 股")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(after > 0
                         ? "记录后剩余 \(WorkbenchFormat.quantity(after)) 股，计划不会自动标记完成。"
                         : "记录后计划数量将记满，执行进度由这笔成交推导。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let price = parsedPrice, let quantity = parsedQuantity {
                    let amount = price * quantity
                    Text("金额影响：\(WorkbenchFormat.money(amount, currencyCode: market.currencyCode))（\(WorkbenchFormat.currencyName(market.currencyCode))，未含费用）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("金额影响：\(WorkbenchFormat.missing)（填写实际成交价与数量后显示）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("成交金额用于核对；此操作不自动改写手工维护的现金余额。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let quantity = parsedQuantity, let item, item.supportsPosition, kind != .adjustment {
                    let newDelta = kind == .buy ? quantity : -quantity
                    let priorDelta = original.map { $0.kind == .buy ? $0.quantity : -$0.quantity } ?? 0
                    let projected = item.positionQuantity + newDelta - priorDelta
                    Text("持仓数量：\(WorkbenchFormat.quantity(item.positionQuantity)) → \(WorkbenchFormat.quantity(projected)) 股")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if kind == .sell {
                        Text("卖出来源卡与超额卖出仍按共享账本规则校验；被拒绝时不会写入半笔。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isEditing, let original {
                    Text("这是修改：原记录 \(WorkbenchFormat.price(original.price, market: market)) × \(WorkbenchFormat.quantity(original.quantity)) 股，\(WorkbenchFormat.day(original.date))。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 红涨绿跌 by default, matching the Chinese convention the product uses.
    /// There is one palette for the whole workbench; a second preference store
    /// would let two screens disagree about the same quote.
    private var palette: ChangePalette { WorkbenchTheme.palette }

    // MARK: Submit

    private func submit() {
        guard canSubmit, let executionAccount else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        guard let price = parsedPrice, let quantity = parsedQuantity else {
            errorMessage = WorkbenchError.invalidValues.errorDescription
            return
        }

        var transaction = original ?? PositionTransaction(
            id: transactionID,
            kind: kind,
            price: price,
            quantity: quantity,
            date: date,
            createdAt: createdAt
        )
        // The id and creation stamp are the event's identity and never move.
        transaction.id = transactionID
        transaction.createdAt = createdAt
        transaction.kind = kind
        transaction.price = price
        transaction.quantity = quantity
        transaction.date = date
        transaction.fee = parsedFee
        transaction.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : note.trimmingCharacters(in: .whitespacesAndNewlines)
        transaction.fundingSource = isEditing && fundingSource == nil && original?.fundingSource != nil
            ? .unmarked : fundingSource
        // The store preserves the original ownership and plan context; carrying
        // them here keeps the draft a faithful copy of the record it edits.
        transaction.brokerageAccountID = original?.brokerageAccountID
        transaction.planExecution = original?.planExecution

        do {
            if let original {
                // Editing the recorded *facts* of a fill goes through the same
                // checked boundary as recording one: the store compares the
                // stored record to `original` and refuses a stale draft.
                _ = try state.recordTrade(
                    transaction,
                    symbol: context.symbol,
                    account: executionAccount,
                    plan: nil,
                    original: original,
                    sourceAccount: sourceAccount
                )
            } else {
                let planForFill = linkedPlan ?? context.plan
                _ = try state.recordTrade(
                    transaction,
                    symbol: context.symbol,
                    account: executionAccount,
                    plan: planForFill,
                    original: nil,
                    // The plan's owning ledger travels separately from the
                    // actual execution account, so a cross-ledger fill is
                    // checked by the shared rules instead of being waved through.
                    planSourceAccount: planSourceAccount,
                    sourceAccount: sourceAccount
                )
            }
            dismiss()
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var linkedPlan: TradePlan? {
        guard let linkedPlanID else { return nil }
        if plan?.id == linkedPlanID { return plan }
        return item?.plans.first { $0.id == linkedPlanID }
    }

    /// Persist the market's calendar day in the local-day representation used
    /// by the shared ledger. A US fill at 1am in China belongs to New York's
    /// preceding date, not to a nonexistent next-day candle.
    static func marketTradeDay(for market: Market, now: Date = .now,
                               localTimeZone: TimeZone = .current) -> Date {
        var exchange = Calendar(identifier: .gregorian)
        exchange.timeZone = market.timeZone
        var local = Calendar(identifier: .gregorian)
        local.timeZone = localTimeZone
        let day = exchange.dateComponents([.year, .month, .day], from: now)
        return local.date(from: day) ?? now
    }

    // MARK: Parsing

    /// Accepts the separators a phone keyboard and a paste both produce.
    static func parse(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else { return nil }
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    static func editableNumber(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    static func changePercent(_ quote: Quote) -> Double? {
        guard quote.previousClose != 0 else { return nil }
        return (quote.price - quote.previousClose) / quote.previousClose * 100
    }
}
