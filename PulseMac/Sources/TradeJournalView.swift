import SwiftUI
import PulseCore
import PulseUI

/// Cross-symbol trade history and post-trade notes for the main window.
struct TradeJournalView: View {
    enum ReviewScope: String, CaseIterable { case today = "今日", pending = "待补", all = "全部" }
    private struct TradeKey: Hashable {
        let symbol: SymbolID
        let transactionID: UUID
    }

    private struct Entry: Identifiable {
        let item: WatchItem
        let transaction: PositionTransaction
        let replayIndex: Int
        let realizedPnL: Double?

        var id: TradeKey { TradeKey(symbol: item.symbol, transactionID: transaction.id) }
    }

    private enum PlanChoice: String, CaseIterable, Identifiable {
        case unset
        case yes
        case no

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unset: "未记录"
            case .yes: "是"
            case .no: "否"
            }
        }
        var value: Bool? {
            switch self {
            case .unset: nil
            case .yes: true
            case .no: false
            }
        }

        init(_ value: Bool?) {
            switch value {
            case .some(true): self = .yes
            case .some(false): self = .no
            case .none: self = .unset
            }
        }
    }

    /// The plan context of one fill, reduced to plain facts. Built once from
    /// whichever source still knows the plan, then rendered — never re-read,
    /// so a plan edited or deleted after the fact cannot rewrite what this
    /// trade was actually recorded against.
    ///
    /// Two sources, in order. A transaction written by the execution sheet
    /// carries an immutable `planExecution` snapshot, which is the plan as it
    /// stood at the moment of the fill. Older trades carry only the plan's
    /// `filledTransactionID`, so the live plan is read as a fallback and
    /// marked as such: it may have moved since.
    private struct PlanContext {
        let kind: TradePlan.Kind
        let price: Double
        let quantity: Double
        let positionPool: PositionPool?
        let conditions: [TradePlanCondition]
        let note: String?
        let fundingSource: PositionFundingSource?
        let isSnapshot: Bool
        /// How many times the live plan's configuration changed after this
        /// snapshot was taken. Only meaningful when `isSnapshot` is false.
        let revisionCount: Int

        /// Which way this fill landed against the plan price, in the money
        /// the fill itself was worth. Nil when the two prices are equal or
        /// either is unusable — a zero difference has no direction.
        ///
        /// This is *not* realized P&L: a buy below its plan price does not
        /// book anything until the position is closed, and a sell above its
        /// plan price raises more cash rather than realizing more. The sign
        /// names the direction of the deviation, and the wording below says
        /// only that the fill was better or worse than written down.
        func deviation(for transaction: PositionTransaction) -> (amount: Double, isFavourable: Bool)? {
            guard price.isFinite, price > 0,
                  transaction.price.isFinite, transaction.price > 0,
                  transaction.quantity.isFinite, transaction.quantity > 0 else { return nil }
            let difference = kind == .buy
                ? price - transaction.price
                : transaction.price - price
            let signed = difference * transaction.quantity
            guard signed.isFinite, signed != 0 else { return nil }
            return (abs(signed), signed > 0)
        }
    }

    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    @State private var query = ""
    @State private var selectedMonth: Date?
    @State private var selection: TradeKey?
    @State private var note = ""
    @State private var followedPlan = PlanChoice.unset
    @State private var retrospective = ""
    @State private var strategy = ""
    @State private var showStrategyAnalysis = false
    @State private var saved = false
    @State private var saveError = false
    @State private var reviewScope: ReviewScope = .today
    @State private var schedulesReview = false
    @State private var nextReviewDate = Date.now
    @State private var nextReviewNote = ""
    /// The account the selected trade and this review draft belong to, captured
    /// when the transaction is opened. The store object survives an account
    /// switch with a different ledger inside it, and a fill id is not proof of
    /// which account the draft was written for.
    @State private var frozenAccount: BrokerageAccountID?
    private var initialTransactionID: UUID?

    init(onSelect: @escaping (SymbolID) -> Void, initialTransactionID: UUID? = nil) {
        self.onSelect = onSelect
        self.initialTransactionID = initialTransactionID
    }

    /// Non-nil only when the store still holds the ledger this draft came from.
    private var accountMatchesDraft: Bool {
        frozenAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    private var entries: [Entry] {
        appState.watchlist.tradeHistoryItems.flatMap { item in
            let realized = Dictionary(uniqueKeysWithValues: (item.ledger?.entries ?? []).map {
                ($0.transaction.id, $0.realizedPnL)
            })
            return item.transactions.enumerated().map { index, transaction in
                Entry(
                    item: item,
                    transaction: transaction,
                    replayIndex: index,
                    realizedPnL: realized[transaction.id] ?? nil
                )
            }
        }.sorted { lhs, rhs in
            let calendar = Calendar.current
            let leftDay = calendar.startOfDay(for: lhs.transaction.date)
            let rightDay = calendar.startOfDay(for: rhs.transaction.date)
            if leftDay != rightDay { return leftDay > rightDay }
            if lhs.transaction.createdAt != rhs.transaction.createdAt {
                return lhs.transaction.createdAt > rhs.transaction.createdAt
            }
            if lhs.item.symbol != rhs.item.symbol {
                return lhs.item.symbol.displayCode < rhs.item.symbol.displayCode
            }
            return lhs.replayIndex > rhs.replayIndex
        }
    }

    private var monthOptions: [Date] {
        Array(Set(entries.compactMap {
            Calendar.current.dateInterval(of: .month, for: $0.transaction.date)?.start
        })).sorted(by: >)
    }

    private var filteredEntries: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch reviewScope {
            case .today where !Calendar.current.isDateInToday(entry.transaction.date): return false
            case .pending where entry.transaction.kind == .adjustment
                || (!TradingWorkbenchView.needsReview(entry.transaction) && !checkpointDue(entry.transaction)): return false
            default: break
            }
            if let selectedMonth,
               !Calendar.current.isDate(entry.transaction.date, equalTo: selectedMonth, toGranularity: .month) {
                return false
            }
            return needle.isEmpty
                || entry.item.symbol.displayCode.localizedCaseInsensitiveContains(needle)
                || entry.item.resolvedDisplayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var monthlySummaries: [TradeJournalMonthlySummary] {
        TradeJournalMonthlySummary.make(
            from: appState.watchlist.tradeHistoryItems,
            query: query,
            selectedMonth: selectedMonth
        )
    }

    private var selectedEntry: Entry? {
        filteredEntries.first { $0.id == selection }
    }

    /// The plan this trade was recorded against, preferring the immutable
    /// snapshot the execution sheet wrote over the live plan a legacy fill
    /// points at. The live plan is only consulted when no snapshot exists,
    /// and its revision count is measured from `history` — the list the store
    /// appends to on every configuration change.
    private var planContext: PlanContext? {
        guard let selectedEntry else { return nil }
        if let execution = selectedEntry.transaction.planExecution {
            let snapshot = execution.configuration
            return PlanContext(
                kind: snapshot.kind,
                price: snapshot.price,
                quantity: snapshot.quantity,
                positionPool: snapshot.positionPool,
                conditions: snapshot.conditions ?? [],
                note: snapshot.note,
                fundingSource: snapshot.fundingSource,
                isSnapshot: true,
                revisionCount: 0
            )
        }
        guard let plan = selectedEntry.item.plans.first(where: {
            $0.filledTransactionID == selectedEntry.transaction.id
        }) else { return nil }
        return PlanContext(
            kind: plan.kind,
            price: plan.price,
            quantity: plan.quantity,
            positionPool: plan.positionPool,
            conditions: plan.conditions ?? [],
            note: plan.note,
            fundingSource: plan.fundingSource,
            isSnapshot: false,
            revisionCount: plan.history?.count ?? 0
        )
    }

    var body: some View {
        let summaries = monthlySummaries
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("交易复盘")
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button("策略分析") { showStrategyAnalysis = true }
                        .controlSize(.small)
                    Text("\(filteredEntries.count) 笔")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("搜索代码或名称", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Picker("月份", selection: $selectedMonth) {
                        Text("全部月份").tag(nil as Date?)
                        ForEach(monthOptions, id: \.self) { month in
                            Text(PositionDateFormat.monthGroup(month)).tag(Optional(month))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Picker("记录范围", selection: $reviewScope) {
                        ForEach(ReviewScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Text("按记录日期（本机）").font(.caption2).foregroundStyle(.secondary)
                if !summaries.isEmpty {
                    Text("月度汇总 · 按月份筛选的完整流水")
                        .font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(summaries) { summary in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(PositionDateFormat.monthGroup(summary.month))
                                        Text(summary.currencyCode).fontWeight(.semibold)
                                        Spacer(minLength: 4)
                                    }
                                    Text("\(summaryLabel("已实现", "Realized")) \(summary.realizedPnL.map { PriceFormatter.signedMoney($0, currencyCode: summary.currencyCode) } ?? "—")")
                                        .foregroundStyle(summary.realizedPnL.map { appState.palette.color(isUp: $0 >= 0) } ?? Color.secondary)
                                    HStack(spacing: 8) {
                                        Text("\(summaryLabel("已记费用", "Recorded fees")) \(summary.fees.map { PriceFormatter.money($0, currencyCode: summary.currencyCode) } ?? "—")")
                                        Text(summaryLabel("未记/无效", "Unknown/invalid") + " \(summary.missingFeeCount)")
                                    }
                                    Text(summary.followedPlanPercent.map {
                                        "\(summaryLabel("按计划", "On plan")) \(summary.followedPlanYesCount)/\(summary.reviewedCount) (\(Int($0.rounded()))%)"
                                    } ?? summaryLabel("按计划：未填写", "On plan: not reviewed"))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: summaries.count > 1 ? 168 : 90)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(summaryLabel("月度汇总", "Monthly summaries"))
                    .help(summaryLabel(
                        "已实现盈亏按完整交易流水计算，包含已记录交易费用。执行率仅计明确填写是/否的交易；校准不产生已实现盈亏，也不计入费用或执行率。",
                        "Realized P&L uses the full ledger and recorded fees. On-plan rate counts explicit yes/no answers. Adjustments realize no P&L and do not count toward fees or reviews."
                    ))
                }
                List(selection: $selection) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView("没有交易记录", systemImage: "book.closed")
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Divider()

            detail
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !entries.contains(where: { Calendar.current.isDateInToday($0.transaction.date) }) { reviewScope = .all }
            openReview(appState.pendingJournalTransactionID ?? initialTransactionID)
        }
        .onChange(of: appState.pendingJournalTransactionID) { _, id in openReview(id) }
        .onChange(of: selection) { _, _ in loadDraft() }
        // The selected fill and the review fields describe the previous
        // account's ledger. Clearing the selection is honest: the fields are
        // reloaded from whatever the user opens next.
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            frozenAccount = nil
            selection = nil
            saved = false
        }
        .onChange(of: note) { _, _ in saved = false }
        .onChange(of: followedPlan) { _, _ in saved = false }
        .onChange(of: retrospective) { _, _ in saved = false }
        .onChange(of: strategy) { _, _ in saved = false }
        .onChange(of: schedulesReview) { _, _ in saved = false }
        .onChange(of: nextReviewDate) { _, _ in saved = false }
        .onChange(of: nextReviewNote) { _, _ in saved = false }
        .sheet(isPresented: $showStrategyAnalysis) {
            TradeStrategySummaryView(query: query, selectedMonth: selectedMonth)
        }
        .alert("这笔交易已不存在", isPresented: $saveError) {
            Button("好", role: .cancel) { }
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(entry.item.symbol.displayCode)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(entry.item.resolvedDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(kindName(entry.transaction.kind))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.transaction.kind == .buy
                        ? appState.palette.color(isUp: true)
                        : appState.palette.color(isUp: false))
            }
            HStack(spacing: 6) {
                Text(PositionDateFormat.monthDay(entry.transaction.date))
                Text(PriceFormatter.price(entry.transaction.price, market: entry.item.symbol.market))
                Text("×")
                Text(PriceFormatter.quantity(entry.transaction.quantity))
                Spacer()
                if let realizedPnL = entry.realizedPnL {
                    Text(PriceFormatter.signedMoney(realizedPnL, currencyCode: entry.item.symbol.currencyCode))
                        .foregroundStyle(appState.palette.color(isUp: realizedPnL >= 0))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            if let reason = entry.transaction.note, !reason.isEmpty {
                Text(reason).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if checkpointDue(entry.transaction) {
                Label("检查点到期", systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.item.resolvedDisplayName)
                                .font(.system(size: 20, weight: .semibold))
                            Text(entry.item.symbol.displayCode)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("打开标的") { onSelect(entry.item.symbol) }
                        // Named from the account the draft was loaded under, so
                        // the ledger this review lands in is never ambiguous.
                        let captionAccount = frozenAccount ?? appState.watchlist.activeBrokerageAccountID
                        HStack(spacing: 5) {
                            Circle().fill(AccountIdentity.dotColor(captionAccount)).frame(width: 5, height: 5)
                            Text("复盘记入：\(AccountIdentity.title(captionAccount))")
                                .font(.system(size: 10))
                                .foregroundStyle(accountMatchesDraft
                                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        detailLine("成交", "\(kindName(entry.transaction.kind)) · \(fullDate(entry.transaction.date))")
                        detailLine("价格", PriceFormatter.price(entry.transaction.price, market: entry.item.symbol.market))
                        detailLine("数量", PriceFormatter.quantity(entry.transaction.quantity))
                        if entry.transaction.kind == .buy {
                            detailLine("实际资金", fundingSourceTitle(entry.transaction.fundingSource))
                        }
                        if let fee = entry.transaction.fee {
                            detailLine("费用", PriceFormatter.money(fee, currencyCode: entry.item.symbol.currencyCode))
                        }
                        if let realizedPnL = entry.realizedPnL {
                            detailLine("已实现盈亏", PriceFormatter.signedMoney(realizedPnL, currencyCode: entry.item.symbol.currencyCode))
                        }
                    }

                    if let context = planContext {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text("关联计划").font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 0)
                                Text(context.isSnapshot ? "成交时快照" : "当前计划")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(context.kind == .buy ? "买入" : "卖出") · \(PriceFormatter.price(context.price, market: entry.item.symbol.market)) × \(PriceFormatter.quantity(context.quantity))")
                                .font(.system(size: 11))
                            Text("用途 \(context.positionPool?.title ?? "未分配")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if context.kind == .buy {
                                Text("拟用资金 \(fundingSourceTitle(context.fundingSource))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let note = context.note, !note.isEmpty {
                                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if context.conditions.isEmpty {
                                Text("计划条件：无").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else {
                                ForEach(context.conditions) { condition in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(PlanExecutionSheet.stateColor(condition.state))
                                            .frame(width: 5, height: 5)
                                        Text(condition.title).font(.system(size: 11))
                                        Text(condition.stateTitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            if !context.isSnapshot {
                                Text(context.revisionCount > 0
                                    ? "原计划此后已修改 \(context.revisionCount) 次，以上为其当前配置。"
                                    : "以上为原计划的当前配置。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("按成交时记录的计划快照显示；计划即使已删除，这里仍然可见。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    executionDeviationCard

                    VStack(alignment: .leading, spacing: 6) {
                        Text("执行理由").font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $note)
                            .font(.system(size: 12))
                            .accessibilityLabel("执行理由")
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 55, maxHeight: 85)
                            .padding(5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }

                    HStack {
                        Text("是否按计划执行").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker("是否按计划执行", selection: $followedPlan) {
                            ForEach(PlanChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("策略标签").font(.system(size: 12, weight: .semibold))
                        HStack {
                            TextField("例如：突破、回踩、做 T", text: $strategy)
                                .textFieldStyle(.roundedBorder)
                            Menu("常用") {
                                ForEach(["突破", "回踩", "做 T", "趋势", "事件"], id: \.self) { label in
                                    Button(label) { strategy = label }
                                }
                            }.fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("复盘记录").font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $retrospective)
                            .font(.system(size: 12))
                            .accessibilityLabel("复盘记录")
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90, maxHeight: 220)
                            .padding(5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("设置下一次检查点", isOn: $schedulesReview).toggleStyle(.checkbox)
                        if schedulesReview {
                            DatePicker("检查日期", selection: $nextReviewDate, displayedComponents: .date)
                        }
                        TextField("下次要核对什么（选填）", text: $nextReviewNote, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    }

                    HStack {
                        if saved {
                            Label("已保存", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("保存复盘", action: saveReview)
                            .buttonStyle(.borderedProminent)
                            .disabled(nextReviewNote.count > 4_000)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView("选择一笔交易", systemImage: "text.book.closed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
            Spacer()
        }
        .font(.system(size: 11))
    }

    private func summaryLabel(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }

    // MARK: - Execution deviation

    /// Two facts, stated as facts: how this fill's own price compared with the
    /// plan's, in money sized by the quantity actually filled, and how far the
    /// live plan has since moved from its earliest recorded configuration.
    ///
    /// The card deliberately stops there. It does not call the difference a
    /// gain or a loss — a buy below its plan price has realized nothing until
    /// the position is sold — and it does not speculate about why the user
    /// paid up. A partial fill is a size fact, not a discipline failure, so
    /// the fill's quantity is never compared against the planned quantity
    /// here. The plan card above already shows both numbers.
    @ViewBuilder private var executionDeviationCard: some View {
        let entry = selectedEntry
        VStack(alignment: .leading, spacing: 5) {
            Text("执行偏差").font(.system(size: 12, weight: .semibold))
            if let entry {
                deviationLine(
                    context: planContext,
                    transaction: entry.transaction,
                    currency: entry.item.symbol.currencyCode
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func deviationLine(
        context: PlanContext?,
        transaction: PositionTransaction,
        currency: String?
    ) -> some View {
        if let context, let deviation = context.deviation(for: transaction) {
            let money = PriceFormatter.money(deviation.amount, currencyCode: currency)
            let label = deviation.isFavourable
                ? (context.kind == .buy ? "本笔买入价低于原计划" : "本笔卖出价高于原计划")
                : (context.kind == .buy ? "本笔买入价高于原计划" : "本笔卖出价低于原计划")
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(money)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(appState.palette.color(isUp: deviation.isFavourable))
            }
            .font(.system(size: 11))
            Text("按本笔成交数量计算的价差金额，不是已实现盈亏。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let context {
            Text("本笔成交价与原计划一致。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("比较基准是\(context.isSnapshot ? "成交时记录的计划快照" : "原计划的当前配置")。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            Text("这笔成交没有关联计划，无法比较执行价格。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let context, !context.isSnapshot {
            Text(context.revisionCount > 0
                ? "当前计划相对最早配置已修改 \(context.revisionCount) 次。"
                : "当前计划自创建以来未再修改。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadDraft() {
        guard let entry = selectedEntry else {
            frozenAccount = nil
            return
        }
        frozenAccount = appState.watchlist.activeBrokerageAccountID
        note = entry.transaction.note ?? ""
        followedPlan = PlanChoice(entry.transaction.review?.followedPlan)
        retrospective = entry.transaction.review?.retrospective ?? ""
        strategy = entry.transaction.review?.strategy ?? ""
        schedulesReview = entry.transaction.review?.nextReviewDate != nil
        nextReviewDate = entry.transaction.review?.nextReviewDate ?? .now
        nextReviewNote = entry.transaction.review?.nextReviewNote ?? ""
        saved = false
    }

    private func checkpointDue(_ transaction: PositionTransaction) -> Bool {
        guard let date = transaction.review?.nextReviewDate else { return false }
        return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: .now)
    }

    private func openReview(_ id: UUID?) {
        guard let id, let entry = entries.first(where: { $0.transaction.id == id }) else { return }
        query = ""
        selectedMonth = nil
        reviewScope = .all
        selection = entry.id
        loadDraft()
        if appState.pendingJournalTransactionID == id { appState.pendingJournalTransactionID = nil }
    }

    private func saveReview() {
        // A review is written into whichever ledger is selected now, so the
        // account the fields were filled in for has to be the one still open.
        guard accountMatchesDraft else {
            saveError = true
            return
        }
        guard let entry = selectedEntry else { return }
        guard appState.watchlist.tradeHistoryItems.first(where: { $0.symbol == entry.item.symbol })?
            .transactions.contains(where: { $0.id == entry.transaction.id }) == true else {
            saveError = true
            return
        }
        _ = appState.watchlist.updateTransactionReview(
            entry.item.symbol,
            id: entry.transaction.id,
            note: note,
            review: PositionTransactionReview(
                followedPlan: followedPlan.value,
                retrospective: retrospective,
                strategy: strategy,
                nextReviewDate: schedulesReview ? Calendar.current.startOfDay(for: nextReviewDate) : nil,
                nextReviewNote: nextReviewNote
            )
        )
        saved = true
    }

    private func kindName(_ kind: PositionTransaction.Kind) -> String {
        switch kind {
        case .buy: "买入"
        case .sell: "卖出"
        case .adjustment: "校准"
        }
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}

extension TradePlanCondition {
    /// The state in the language the rest of this page is written in. Local to
    /// the journal so the two-word vocabulary stays with the surface that
    /// shows it.
    var stateTitle: String {
        switch state {
        case .pending: "待确认"
        case .confirmed: "已确认"
        case .needsReview: "需复核"
        case .invalidated: "已失效"
        }
    }
}
