import SwiftUI
import PulseCore
import PulseUI

/// 今日工作台：一天要看的任务、一个选中标的的摘要，以及常驻的资金与风险条。
///
/// 这一层只做**派生展示**。它读取 `AppState` 里的自选、报价、计划、成交与
/// 设置，算出「今天该关注什么」，从不写入成交、持仓、计划或账本。四条刻意的
/// 边界写在这里，因为每一条如果反过来做都会悄悄撒谎：
///
/// 1. **视角（盘前/盘中/盘后）只改变侧重，不改变数据。** 它决定先给谁排序、
///    哪一段更靠前，而不隐藏任务、不改计数、不算出第二套数字。
/// 2. **市场范围就是一个真实的市场。** 币种不是市场：同一个 `USD` 覆盖美股与
///    贵金属/加密，所以范围用 `Market` 而不是 `currencyCode`。A 股是沪深两个
///    `Market` 的并集（交易所分开建模，界面合并呈现）。范围同时约束自选、历史
///    标的与计划：切到 A 股时不会因为一条美股计划是活跃的就在计数或任务里出现。
/// 3. **成交的「今天」是本机民用日。** `PositionTransaction.date` 是用户自己
///    录入的当地日历日（录入表单存本机午夜），不是交易所时间戳。把它按交易所
///    时区重新解释会让一笔已录入的美股成交跳到前一天或后一天，所以复盘归属
///    一律用 `Calendar.current` 的本地日相等判断。
/// 4. **交易所日历只用于参考时钟。** 页面可以按各交易所时区显示「市场本地
///    日期」与时段，但那是报价与事件的参考，不是成交归属。
///
/// 交易日**不是**节假日日历：`TradingCalendar` 目前只有周一到周五的规则，没有
/// 春节、国庆、感恩节。所以界面只说「所选市场本地日期」，不说「交易日」——把
/// 周中的休市日说成交易日就是编造一个系统并不知道的事实。
struct TradingWorkbenchView: View {
    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    let onShowPlans: () -> Void
    let onShowJournal: () -> Void
    let onShowEvents: () -> Void
    var onShowPools: () -> Void = {}

    @State private var phase: WorkbenchPhase = .intraday
    @State private var scope: WorkbenchScope = .all
    @State private var selectedSymbol: SymbolID?
    @State private var showRisk = false
    @State private var showSectors = false
    @State private var showCapitalDetail = false
    @State private var executionEntry: TradePlanEntry?
    @State private var workflowEntry: TradePlanEntry?
    @State private var verificationPortion: PositionPoolsView.VerificationDraft?

    /// Test seam: lets a DEBUG render harness open the workbench in a known
    /// phase with a known market scope and selection. Production never passes it,
    /// so the default initialiser keeps its old signature and behaviour.
    struct WorkbenchInitialState {
        var phase: WorkbenchPhase = .intraday
        var scope: WorkbenchScope = .all
        var selectedSymbol: SymbolID?
        var showsCapitalDetail = false
    }

    init(onSelect: @escaping (SymbolID) -> Void,
         onShowPlans: @escaping () -> Void,
         onShowJournal: @escaping () -> Void,
         onShowEvents: @escaping () -> Void,
         onShowPools: @escaping () -> Void = {},
         initial: WorkbenchInitialState? = nil) {
        self.onSelect = onSelect
        self.onShowPlans = onShowPlans
        self.onShowJournal = onShowJournal
        self.onShowEvents = onShowEvents
        self.onShowPools = onShowPools
        guard let initial else { return }
        _phase = State(initialValue: initial.phase)
        _scope = State(initialValue: initial.scope)
        _selectedSymbol = State(initialValue: initial.selectedSymbol)
        _showCapitalDetail = State(initialValue: initial.showsCapitalDetail)
    }

    // MARK: - Derived inputs

    /// All items, before any market filter, in the store's display order. Kept
    /// separate from the scope filter so the capital summary can state what it
    /// deliberately narrowed.
    private var allItems: [WatchItem] { appState.watchlist.allItems }

    private var items: [WatchItem] {
        allItems.filter { scope.contains($0.symbol.market) }
    }

    private var historyItems: [WatchItem] {
        appState.watchlist.tradeHistoryItems.filter { scope.contains($0.symbol.market) }
    }

    // MARK: - Body

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .sheet(isPresented: $showRisk) { TradeRiskCalculatorView(initialSymbol: nil) }
        .sheet(isPresented: $showSectors) { SectorExposureView() }
        .sheet(item: $executionEntry) { entry in
            PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                               onClose: { executionEntry = nil })
        }
        .sheet(item: $workflowEntry) { entry in
            PlanWorkflowDetailView(symbol: entry.symbol, planID: entry.id,
                                   account: appState.watchlist.activeBrokerageAccountID)
                .frame(width: 650, height: 600)
        }
        .sheet(item: $verificationPortion) { draft in
            if let item = appState.watchlist.item(for: draft.symbol),
               let allocation = item.positionAllocation,
               let portion = allocation.portions.first(where: { $0.id == draft.portionID }) {
                PositionVerificationSheet(item: item, portion: portion, allocation: allocation,
                    account: appState.watchlist.activeBrokerageAccountID,
                    onCancel: { verificationPortion = nil },
                    onSuccess: { _, _ in verificationPortion = nil })
            }
        }
        .task {
            if !appState.isMainWindowDemo { await appState.tradingEvents.refresh(items: appState.watchlist.allItems) }
        }
    }

    private func content(now: Date) -> some View {
        let board = WorkbenchBoard(
            now: now,
            phase: phase,
            items: items,
            historyItems: historyItems,
            entries: appState.watchlist.tradePlanEntries,
            events: appState.tradingEvents.entries(for: items),
            quote: { appState.market.quote(for: $0) },
            name: { appState.watchlist.item(for: $0)?.resolvedDisplayName ?? $0.displayCode },
            cash: WorkbenchCashInput(appState.poolBudgets),
            sectorLimits: appState.sectorLimits.limits
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(now: now, board: board)
                countBar(board)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        taskColumn(board).frame(maxWidth: .infinity, alignment: .top)
                        summaryColumn(board).frame(width: 340, alignment: .top)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        taskColumn(board)
                        summaryColumn(board)
                    }
                }
                summaries(now: now, board: board)
            }
            .padding(20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private func header(now: Date, board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    title
                    Spacer(minLength: 8)
                    scopePicker
                    phasePicker
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    HStack(spacing: 8) {
                        scopePicker
                        phasePicker
                    }
                }
            }
            marketDayLine(now: now, board: board)
        }
    }

    private var title: some View {
        Text("今日工作台").font(.system(size: 20, weight: .semibold))
    }

    private var scopePicker: some View {
        Picker("市场范围", selection: $scope) {
            ForEach(WorkbenchScope.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("只看所选市场的自选、历史标的与计划。币种不是市场，所以范围按交易所划分。")
    }

    private var phasePicker: some View {
        Picker("今日视角", selection: $phase) {
            ForEach(WorkbenchPhase.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("只改变今天的侧重顺序；不改变数据、计数或到价判断。")
    }

    /// One compact metadata line. Session semantics live behind the help
    /// button: a paragraph about the absence of a holiday calendar is useful
    /// once, not on every refresh.
    private func marketDayLine(now: Date, board: WorkbenchBoard) -> some View {
        let markets = scope.markets
        let states = markets.map { TradingCalendar.state(of: $0, at: now) }
        let dayText = markets.map { market -> String in
            let day = TradingCalendar.tradingDay(of: market, at: now)
            return "\(market.displayName) \(String(format: "%02d-%02d", day.month, day.day))"
        }.joined(separator: " · ")
        let stateText = zip(markets, states).map { market, state in
            "\(market.displayName)：\(Self.sessionLabel(state))"
        }.joined(separator: " · ")
        let zoneText = markets.map { "\($0.displayName) \($0.timeZoneDisplayName)" }.joined(separator: " · ")
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                metadataText(dayText: dayText, stateText: stateText, phaseNote: board.phaseNote, singleLine: true)
                metadataHelp(states: states, zoneText: zoneText)
            }
            VStack(alignment: .leading, spacing: 2) {
                metadataText(dayText: dayText, stateText: stateText, phaseNote: board.phaseNote, singleLine: false)
                metadataHelp(states: states, zoneText: zoneText)
            }
        }
    }

    @ViewBuilder
    private func metadataText(dayText: String, stateText: String, phaseNote: String, singleLine: Bool) -> some View {
        let line = "\(phase.title)侧重 · 市场本地日期 \(dayText) · \(stateText)"
            + (phaseNote.isEmpty ? "" : " · \(phaseNote)")
        Text(line)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(singleLine ? 1 : 2)
    }

    private func metadataHelp(states: [SessionState], zoneText: String) -> some View {
        Image(systemName: "info.circle")
            .font(.caption2).foregroundStyle(.tertiary)
            .help("""
            市场本地日期按各交易所时区：\(zoneText)。
            时段按周一至周五的常规交易时间判断；未接入节假日日历，周中休市日仍会显示为交易时段。
            这只是报价与事件的参考时钟；成交的今天按本机记录日期。
            """)
            .accessibilityLabel("时段与日期的判断口径")
            .accessibilityValue(states.map(Self.sessionLabel).joined(separator: "、"))
    }

    static func sessionLabel(_ state: SessionState) -> String {
        switch state {
        case .preMarket: "盘前"
        case .regular: "交易时段"
        case .lunchBreak: "午间休市"
        case .postMarket: "盘后"
        case .overnight: "夜盘"
        case .closed: "休市"
        }
    }

    // MARK: - Counts
    //
    // Three different units, stated three times on purpose. They are never
    // summed into one number: a symbol, a plan and a fill are not the same thing.

    private func countBar(_ board: WorkbenchBoard) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { countChips(board); countSpacer(board) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { countChips(board) }
                backlogLink(board)
            }
        }
        .font(.caption)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func countChips(_ board: WorkbenchBoard) -> some View {
        countChip("\(board.reachedSymbolCount) 个标的到价", icon: "target", tint: board.reachedSymbolCount > 0 ? .orange : .secondary)
        countChip("\(board.plansToReviewCount) 条计划条件待核对", icon: "checklist", tint: board.plansToReviewCount > 0 ? .orange : .secondary)
        countChip("\(board.todayReviewCount) 笔今日成交待复盘", icon: "square.and.pencil", tint: board.todayReviewCount > 0 ? .orange : .secondary)
    }

    @ViewBuilder
    private func countSpacer(_ board: WorkbenchBoard) -> some View {
        Spacer(minLength: 6)
        backlogLink(board)
    }

    @ViewBuilder
    private func backlogLink(_ board: WorkbenchBoard) -> some View {
        if let backlog = board.historyBacklog {
            Button {
                onShowJournal()
            } label: {
                Label("补齐历史 \(backlog.count) 笔复盘", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help(backlog.detail)
        }
    }

    private func countChip(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
    }

    // MARK: - Task column

    private func taskColumn(_ board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("今日需要关注", systemImage: "checklist").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("到价按当前有效行情判断，不代表成交。核对条件不阻止记录已经发生的成交；计划动作只在该行展开时显示。")
                    .accessibilityLabel("任务口径说明")
                Button("打开仓位池", action: onShowPools).font(.caption)
            }
            if board.tasks.isEmpty {
                singleLine("今天没有到价、待核对条件或临近事件。", icon: "checkmark.circle")
            }
            ForEach(board.tasks) { task in
                taskRow(task)
            }
            ForEach(board.cashNotes) { note in
                taskLink(note.title, detail: note.detail, action: onShowPools)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    private func taskRow(_ task: WorkbenchTask) -> some View {
        let isSelected = selectedSymbol == task.symbol
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                selectedSymbol = task.symbol
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if task.reasons.isEmpty == false {
                            Text(task.reasons.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(task.countText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("选中后只在下方摘要显示，不会立即跳页。")

            // Only the expanded row spends vertical space on individual plans.
            // Every plan keeps its own identity and its own actions; the
            // collapsed rows stay one line each.
            if isSelected {
                if task.plans.isEmpty == false {
                    ForEach(task.plans) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.detail)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("核对") { workflowEntry = entry.entry }.controlSize(.small)
                            Button("记录成交") { executionEntry = entry.entry }.controlSize(.small)
                        }
                        .padding(.leading, 18)
                    }
                }
                reviewActions(task)
                ForEach(task.verifications) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.title + " · " + row.detail)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("核对持仓") {
                            verificationPortion = .init(symbol: task.symbol, portionID: row.id)
                        }.controlSize(.small)
                    }.padding(.leading, 18)
                }
                if task.plans.isEmpty == false {
                    Button("全部计划") { onShowPlans() }
                        .buttonStyle(.link).font(.caption2).padding(.leading, 18)
                }
            } else if task.plans.isEmpty == false {
                Text(task.plans.count == 1
                     ? task.plans[0].detail
                     : "\(task.plans.count) 条计划，展开查看每一条")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }

    /// Today's unreviewed fills for this symbol, as one action per symbol. The
    /// count is stated so a batch of three is never mistaken for one fill, and
    /// the first id is the one the journal opens on.
    @ViewBuilder
    private func reviewActions(_ task: WorkbenchTask) -> some View {
        if let count = task.reviewCount, let first = task.reviewTransactionIDs.first {
            Button("去复盘 \(count) 笔成交") {
                appState.pendingJournalTransactionID = first
                onShowJournal()
            }
            .buttonStyle(.link).font(.caption2)
            .padding(.leading, 18)
            .help("按记录日期（本机）属于今天的成交；打开交易日志逐笔补写复盘。")
        }
        if let checkpointID = task.checkpointID {
            Button("复核检查点") {
                appState.pendingJournalTransactionID = checkpointID
                onShowJournal()
            }.buttonStyle(.link).font(.caption2).padding(.leading, 18)
        }
        if let due = task.dueReviewText {
            Text(due).font(.caption2).foregroundStyle(.orange).padding(.leading, 18).lineLimit(2)
        }
    }

    // MARK: - Selected symbol summary

    @ViewBuilder
    private func summaryColumn(_ board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("选中标的摘要", systemImage: "sidebar.right").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
            }
            if let symbol = selectedSymbol, let summary = board.summary(for: symbol) {
                summaryContent(summary, verifications: board.tasks.first { $0.symbol == symbol }?.verifications ?? [])
            } else {
                singleLine("在上方选择一行标的，这里显示它的报价时点、相关计划与事件。", icon: "cursorarrow.click")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    @ViewBuilder
    private func summaryContent(_ summary: WorkbenchSymbolSummary, verifications: [WorkbenchTask.VerificationRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(summary.market.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            quoteLine(summary)
            if summary.plans.isEmpty == false {
                detailBlock("相关计划", rows: summary.plans.map {
                    WorkbenchDetailRow(id: $0.id.uuidString, title: $0.title, detail: $0.detail)
                })
            }
            if summary.events.isEmpty == false {
                detailBlock("未来 7 日事件（北京时间）", rows: summary.events)
            }
            if !verifications.isEmpty {
                detailBlock("持仓判断", rows: verifications.map {
                    WorkbenchDetailRow(id: $0.id.uuidString, title: $0.title, detail: $0.detail)
                })
            }
            if summary.plans.isEmpty && summary.events.isEmpty && verifications.isEmpty {
                singleLine("该标的没有活动计划或临近事件。", icon: "minus")
            }
            // One detail action only: this callback opens the summary
            // inspector, so the old duplicate "打开完整标的" pair is gone.
            HStack(spacing: 8) {
                Button("标的详情") { onSelect(summary.symbol) }.controlSize(.small)
                if let planID = summary.pendingPoolPlanID {
                    Button("定位池内计划") {
                        appState.pendingPoolPlanID = planID
                        onShowPools()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func quoteLine(_ summary: WorkbenchSymbolSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(summary.quoteText).font(.system(size: 12, weight: .medium).monospacedDigit())
                Spacer(minLength: 4)
                Text(summary.quoteStatusText)
                    .font(.caption2)
                    .foregroundStyle(summary.quoteIsCurrent ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
            Text(summary.quoteTimestampText).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func detailBlock(_ title: String, rows: [WorkbenchDetailRow]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.caption2).lineLimit(1)
                    if row.detail.isEmpty == false {
                        Text(row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Persistent summaries

    private func summaries(now: Date, board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            capitalSummary(board)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    riskSummary(now: now, board: board).frame(maxWidth: .infinity, alignment: .top)
                    sectorSummary(board).frame(maxWidth: .infinity, alignment: .top)
                }
                VStack(alignment: .leading, spacing: 8) {
                    riskSummary(now: now, board: board)
                    sectorSummary(board)
                }
            }
        }
    }

    /// Cash is shown per currency and stays unknown when unknown. The projection
    /// is the same one the pool board uses, so a figure here cannot disagree with
    /// the board it opens — and a missing balance renders as "未录", never 0.
    /// Cash is the account's recorded balance for that currency: recording it
    /// globally is deliberate, so it is labelled as account cash rather than as
    /// cash belonging to the selected market.
    private func capitalSummary(_ board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    capitalTitle
                    Text("按币种 · 持仓市值与待买预算按计划价").font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    capitalActions
                }
                VStack(alignment: .leading, spacing: 4) {
                    capitalTitle
                    capitalActions
                }
            }
            if board.capitals.isEmpty {
                singleLine("所选市场暂无持仓或计划；账户现金按币种独立记录。", icon: "minus")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], alignment: .leading, spacing: 8) {
                    ForEach(board.capitals) { capital in
                        capitalRow(capital)
                    }
                }
            }
            if board.unvaluableCount > 0 {
                Text("有 \(board.unvaluableCount) 项持仓缺可用报价，持仓市值只计已计价部分。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if board.reconciliationCount > 0 {
                Text("有 \(board.reconciliationCount) 项持仓分账未核对，池内份额按已核对部分计。")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    private var capitalTitle: some View {
        Label("资金摘要", systemImage: "banknote").font(.system(size: 13, weight: .semibold))
    }

    private var capitalActions: some View {
        HStack(spacing: 8) {
            Button(showCapitalDetail ? "收起用途条" : "展开用途条") { showCapitalDetail.toggle() }.font(.caption)
            Button("仓位池", action: onShowPools).font(.caption)
        }
    }

    private func capitalRow(_ capital: WorkbenchCapital) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    capitalCode(capital)
                    capitalHoldings(capital)
                    Spacer(minLength: 4)
                    capitalCash(capital)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        capitalCode(capital)
                        capitalHoldings(capital)
                    }
                    capitalCash(capital)
                }
            }
            if capital.hasOverflow {
                Text("金额超出可表示范围，暂不显示比例").font(.caption2).foregroundStyle(.orange)
            }
            // A valid mini gauge is always drawn: hiding it behind the toggle
            // made the row look like it had no pool structure at all.
            if capital.hasSegments {
                PoolTrackGauge(height: 8,
                               segments: capital.segments.map { .init(pool: $0.pool, value: $0.value) },
                               scale: capital.trackScale)
                    .accessibilityLabel("\(capital.code) 用途分布")
                if showCapitalDetail {
                    Text(capital.segmentText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("已计价部分 \(PriceFormatter.money(capital.segmentTotal, currencyCode: capital.code))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if showCapitalDetail, capital.hasUnverified {
                Text(capital.unverifiedText).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            if capital.hasMissingQuote {
                Text(capital.missingQuoteText).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(spacing: 6) {
                if capital.plannedBuy > 0 {
                    Text("待买预算 \(PriceFormatter.money(capital.plannedBuy, currencyCode: capital.code))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if capital.budgetGap > 0 {
                    Text("预算缺口 \(PriceFormatter.money(capital.budgetGap, currencyCode: capital.code))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                }
            }
        }
    }

    private func capitalCode(_ capital: WorkbenchCapital) -> some View {
        Text(capital.code)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.primary.opacity(0.08), in: Capsule())
    }

    private func capitalHoldings(_ capital: WorkbenchCapital) -> some View {
        Text(capital.holdingsText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(capital.hasMissingQuote ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
    }

    private func capitalCash(_ capital: WorkbenchCapital) -> some View {
        Text(capital.cashText).font(.caption2.monospacedDigit())
            .foregroundStyle(capital.cashIsKnown ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
    }

    private func riskSummary(now: Date, board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("风险防守", systemImage: "shield.lefthalf.filled").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button("风险计算") { showRisk = true }.font(.caption)
            }
            if board.defenses.isEmpty {
                singleLine("没有已保存的防守价与持仓组合。", icon: "minus")
            }
            ForEach(board.defenses) { item in
                Button { selectedSymbol = item.symbol } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.caption).lineLimit(1)
                            Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(item.valueText).font(.caption.monospacedDigit())
                            .foregroundStyle(item.isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    private func sectorSummary(_ board: WorkbenchBoard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("板块暴露", systemImage: "chart.pie").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help("按币种绝对市值计算，不含现金。缺可用报价的持仓不计入比例，所以百分比是「已计价部分」。某一币种只要有缺价持仓，该币种的超上限标记就不再给出。")
                    .accessibilityLabel("板块暴露口径")
                Button("分类与上限") { showSectors = true }.font(.caption)
            }
            if board.sectorRows.isEmpty {
                singleLine("所选市场暂无可计价持仓。", icon: "minus")
            }
            ForEach(board.sectorRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(row.name) · \(row.currencyCode)").font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", row.percent)).font(.caption.monospacedDigit())
                    if row.overLimit {
                        Text("超上限").font(.caption2).foregroundStyle(.orange)
                    }
                    if row.hasMissingQuote {
                        Text("有缺价").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Text("按币种绝对市值 · 不含现金 · 已计价部分\(board.sectorMissingQuoteCount > 0 ? "（有缺价持仓）" : "")")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    // MARK: - Small shared row

    /// A one-line placeholder. No card, no fixed height: an empty area should
    /// collapse rather than reserve space it does not fill.
    private func singleLine(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.secondary)
    }

    private func taskLink(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: "arrow.right.circle").font(.caption)
                Spacer(minLength: 4)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Review

    /// Whether a recorded fill still needs its retrospective. A fill whose
    /// review object exists but whose retrospective is blank counts as
    /// unreviewed: the user opened the form and wrote nothing.
    nonisolated static func needsReview(_ transaction: PositionTransaction) -> Bool {
        transaction.review?.retrospective?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

// MARK: - Board derivation

/// One immutable pass over the store for a single render. Keeping the maths in a
/// plain value type (rather than the view body) is what lets the DEBUG self-test
/// call the same grouping without a window, and keeps every count derived from
/// one snapshot instead of drifting between subviews.
struct WorkbenchBoard {
    struct CashNote: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    let tasks: [WorkbenchTask]
    let cashNotes: [CashNote]
    let capitals: [WorkbenchCapital]
    let defenses: [WorkbenchDefense]
    let sectorRows: [WorkbenchSectorRow]
    let reachedSymbolCount: Int
    let plansToReviewCount: Int
    let todayReviewCount: Int
    let historyBacklog: (count: Int, detail: String)?
    let unvaluableCount: Int
    /// Positions whose pool split still needs reconciling. Their pool rows are
    /// a floor, never a verified breakdown.
    let reconciliationCount: Int
    /// Currencies that contain at least one holding with no usable quote. Their
    /// percentages are "priced part only" and no over-limit flag is definitive.
    let sectorMissingQuoteCount: Int
    let phaseNote: String

    private let summaries: [SymbolID: WorkbenchSymbolSummary]

    func summary(for symbol: SymbolID) -> WorkbenchSymbolSummary? { summaries[symbol] }

    /// `entries` is filtered here as well as by the caller: a board built with
    /// an unfiltered list must still never count another market's plan, so the
    /// scope is enforced defensively against the symbols actually present.
    init(now: Date, phase: WorkbenchPhase, items: [WatchItem], historyItems: [WatchItem],
         entries: [TradePlanEntry], events: [TradingEventEntry],
         quote: (SymbolID) -> Quote?, name: (SymbolID) -> String,
         cash: WorkbenchCashInput, sectorLimits: [String: Double] = [:]) {
        let calendar = EastmoneyTradingEvents.dateCalendar
        let today = calendar.startOfDay(for: now)
        // An inclusive seven-day window with a lower bound. Without the floor a
        // past event would read as "approaching" forever.
        let horizon = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        // Ongoing events stay in the window only while they still cover today.
        func isInWindow(_ event: InstrumentEvent) -> Bool {
            let end = event.endDate ?? event.date
            return calendar.startOfDay(for: end) >= today && calendar.startOfDay(for: event.date) <= horizon
        }
        let scopedSymbols = Set(items.map(\.symbol))
        let active = entries.filter {
            $0.plan.status == .active && $0.remainingQuantity > 0 && scopedSymbols.contains($0.symbol)
        }

        // A quote that is stale, closed, or absent is not an intraday signal. It
        // is still readable as a reference, and it never counts as "到价".
        func currentPrice(_ symbol: SymbolID) -> Double? {
            quote(symbol).flatMap { TradingQuoteHealth.isCurrent($0, now: now) ? $0.price : nil }
        }

        // MARK: Reviews. "Today" is the local recorded date, per symbol.
        //
        // `historyItems` includes instruments retained in history that are no
        // longer on the watchlist, so a backlog survives removing the symbol.
        // Records dated in the future are neither today's nor a backlog: they
        // are not something to chase.

        var todayReviewBySymbol: [SymbolID: [UUID]] = [:]
        var backlog = 0
        var backlogIsFutureFree = true
        for item in historyItems {
            for transaction in item.transactions where transaction.kind != .adjustment {
                guard TradingWorkbenchView.needsReview(transaction) else { continue }
                switch WorkbenchBoard.recordedDayRelation(transaction.date, now: now) {
                case .today:
                    todayReviewBySymbol[item.symbol, default: []].append(transaction.id)
                case .earlier:
                    backlog += 1
                case .future:
                    backlogIsFutureFree = false
                }
            }
        }
        let todayReviewCount = todayReviewBySymbol.values.reduce(0) { $0 + $1.count }
        self.todayReviewCount = todayReviewCount
        self.historyBacklog = backlog > 0
            ? (backlog, "按本机记录日期统计的较早未补记录" + (backlogIsFutureFree ? "" : "；未来日期的记录不计入"))
            : nil

        // MARK: Tasks, grouped by symbol
        //
        // One row per symbol, but every plan keeps its own row inside it — one
        // plan's identity, price, condition count and actions are never merged
        // into another's. `reachedSymbolCount` counts symbols (unit: 标的) while
        // `plansToReviewCount` counts plans (unit: 条), which is why they are
        // accumulated separately here rather than derived from the task rows.

        var reachedSymbols = Set<SymbolID>()
        var reviewPlans = 0
        var plansBySymbol: [SymbolID: [WorkbenchTask.PlanRow]] = [:]
        var reasonsBySymbol: [SymbolID: [String]] = [:]
        var reachedBySymbol: [SymbolID: Bool] = [:]
        var conditionsBySymbol: [SymbolID: Int] = [:]
        var windowEventCounts: [SymbolID: Int] = [:]
        var windowEventsBySymbol: [SymbolID: [TradingEventEntry]] = [:]
        for entry in events where isInWindow(entry.event) {
            windowEventCounts[entry.symbol, default: 0] += 1
            windowEventsBySymbol[entry.symbol, default: []].append(entry)
        }
        // Counts and summaries read the live events of the symbol itself, so a
        // condition's linked event can be checked against what actually happened.
        // History items are searched too: a symbol can be off the watchlist and
        // still carry plans whose linked events must resolve.
        let liveEventsBySymbol = Dictionary(
            (items + historyItems).map { ($0.symbol, $0.events) },
            uniquingKeysWith: { first, _ in first })
        func liveEvents(_ symbol: SymbolID) -> [InstrumentEvent] {
            (liveEventsBySymbol[symbol] ?? []) + events.filter { $0.symbol == symbol }.map(\.event)
        }
        for entry in active {
            let price = currentPrice(entry.symbol)
            let reached = price.map { entry.plan.isReached(at: $0) } ?? false
            let conditions = WorkbenchBoard.conditionsToReview(
                entry, now: now, currentEvents: liveEvents(entry.symbol))
            let hasEvent = windowEventCounts[entry.symbol] ?? 0 > 0
            guard reached || conditions > 0 || hasEvent else { continue }
            if reached {
                reachedSymbols.insert(entry.symbol)
                reasonsBySymbol[entry.symbol, default: []].append("到价")
            }
            if conditions > 0 {
                reviewPlans += 1
                reasonsBySymbol[entry.symbol, default: []].append("\(conditions) 条条件待核对")
            }
            reachedBySymbol[entry.symbol] = (reachedBySymbol[entry.symbol] ?? false) || reached
            conditionsBySymbol[entry.symbol, default: 0] += conditions
            plansBySymbol[entry.symbol, default: []].append(WorkbenchTask.PlanRow(
                id: entry.id,
                detail: WorkbenchBoard.planSummary(entry, price: price, conditions: conditions),
                entry: entry
            ))
        }
        // A symbol that only has an approaching event, with no active plan, still
        // needs a row: the event is the reason.
        for symbol in windowEventCounts.keys
        where plansBySymbol[symbol] == nil && items.contains(where: { $0.symbol == symbol }) {
            reasonsBySymbol[symbol] = ["事件临近"]
        }
        var verificationsBySymbol: [SymbolID: [WorkbenchTask.VerificationRow]] = [:]
        for item in items where item.positionQuantity > 0 && !item.positionAllocationNeedsReconciliation {
            for portion in item.positionAllocation?.portions ?? [] where portion.quantity > 0 {
                let conditions = (portion.conditions ?? []).filter {
                    $0.requiresReview(at: now, currentEvents: liveEvents(item.symbol))
                }
                guard !conditions.isEmpty else { continue }
                let stage = conditions.contains { $0.state == .invalidated } ? "持仓判断已失效"
                    : conditions.contains { $0.state == .needsReview || $0.state == .confirmed } ? "持仓判断需复查"
                    : "持仓判断待验证"
                reasonsBySymbol[item.symbol, default: []].append(stage)
                verificationsBySymbol[item.symbol, default: []].append(.init(id: portion.id,
                    title: portion.pool.effectivePurpose.title + " · " + PriceFormatter.quantity(portion.quantity) + " 份额",
                    detail: stage + " · " + conditions.map(\.title).joined(separator: "、")))
            }
        }
        var tasks = Set(plansBySymbol.keys).union(reasonsBySymbol.keys).map { symbol in
            var reasons = reasonsBySymbol[symbol] ?? []
            if windowEventCounts[symbol] ?? 0 > 0 { reasons.append("事件临近") }
            let reviewIDs = todayReviewBySymbol[symbol] ?? []
            if reviewIDs.isEmpty == false { reasons.append("今日成交待复盘") }
            return WorkbenchTask(
                symbol: symbol, name: name(symbol),
                reached: reachedBySymbol[symbol] ?? false,
                conditionCount: conditionsBySymbol[symbol] ?? 0,
                eventCount: windowEventCounts[symbol] ?? 0,
                reasons: WorkbenchBoard.deduplicated(reasons),
                plans: plansBySymbol[symbol] ?? [],
                reviewTransactionIDs: reviewIDs,
                dueReviewText: WorkbenchBoard.dueReviewText(
                    symbol, items: items + historyItems, today: Calendar.current.startOfDay(for: now), calendar: .current),
                verifications: verificationsBySymbol[symbol] ?? []
            )
        }
        for symbol in todayReviewBySymbol.keys where tasks.contains(where: { $0.symbol == symbol }) == false {
            tasks.append(WorkbenchTask(
                symbol: symbol, name: name(symbol),
                reached: false, conditionCount: 0, eventCount: 0,
                reasons: ["今日成交待复盘"], plans: [],
                reviewTransactionIDs: todayReviewBySymbol[symbol] ?? [],
                dueReviewText: WorkbenchBoard.dueReviewText(
                    symbol, items: items + historyItems, today: Calendar.current.startOfDay(for: now), calendar: .current)
            ))
        }
        let reviewItems = Dictionary((items + historyItems).map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let recordedToday = Calendar.current.startOfDay(for: now)
        for item in reviewItems.values {
            let due = item.transactions.filter {
                $0.kind != .adjustment && $0.review?.nextReviewDate.map {
                    Calendar.current.startOfDay(for: $0) <= recordedToday
                } == true
            }.sorted { ($0.review?.nextReviewDate ?? .distantFuture) < ($1.review?.nextReviewDate ?? .distantFuture) }
            guard let checkpoint = due.first else { continue }
            if let index = tasks.firstIndex(where: { $0.symbol == item.symbol }) {
                tasks[index].checkpointID = checkpoint.id
            } else {
                tasks.append(.init(symbol: item.symbol, name: name(item.symbol), reached: false,
                    conditionCount: 0, eventCount: 0, reasons: ["检查点到期"], plans: [],
                    reviewTransactionIDs: [], dueReviewText: Self.dueReviewText(item.symbol,
                        items: [item], today: recordedToday, calendar: .current), checkpointID: checkpoint.id))
            }
        }
        tasks = WorkbenchBoard.order(tasks, phase: phase)
        self.tasks = tasks
        self.reachedSymbolCount = reachedSymbols.count
        self.plansToReviewCount = reviewPlans

        // MARK: Cash buy-budget notes, per currency

        var cashNotes: [CashNote] = []
        let buyGroups = Dictionary(grouping: active.filter { $0.plan.kind == .buy }, by: { $0.symbol.currencyCode })
        for currency in buyGroups.keys.sorted() {
            let amount = (buyGroups[currency] ?? []).reduce(0) { $0 + $1.remainingEstimatedAmount }
            guard amount.isFinite else {
                cashNotes.append(CashNote(id: "\(currency)-invalid", title: "\(currency) 计划预算无法计算", detail: "请检查计划价与数量"))
                continue
            }
            let balance = cash.balance(currency: currency)
            if balance == nil {
                cashNotes.append(CashNote(id: "\(currency)-missing", title: "补录 \(currency) 账户现金",
                                          detail: "待买入 \(PriceFormatter.money(amount, currencyCode: currency))"))
            } else if let balance, amount > balance {
                cashNotes.append(CashNote(id: "\(currency)-gap", title: "\(currency) 买入预算缺口",
                                          detail: PriceFormatter.money(amount - balance, currencyCode: currency)))
            }
        }
        self.cashNotes = cashNotes

        // MARK: Capital, risk, sectors

        let projection = PoolBudgetProjection.calculate(
            positions: items.map { item in
                .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                      price: quote(item.symbol).flatMap { WorkbenchBoard.usablePrice($0.price) },
                      currencyCode: item.symbol.currencyCode,
                      sector: item.tradingProfile?.sector,
                      poolQuantities: WorkbenchBoard.poolQuantities(for: item))
            },
            entries: active,
            cash: cash.balances,
            cashUpdatedAt: cash.updatedAt,
            poolLimits: cash.limits
        )
        self.capitals = projection.currencies.map {
            WorkbenchCapital($0, reconciliationSymbols: Set(projection.unresolvedPoolPositions))
        }
        self.unvaluableCount = projection.unvaluablePriceCount
        self.reconciliationCount = projection.unresolvedPoolPositions.count

        self.defenses = WorkbenchBoard.defenses(items: items, quote: quote, now: now, name: name)

        let allocation = PortfolioAllocation.calculate(positions: items.map { item in
            .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                  price: quote(item.symbol).flatMap { WorkbenchBoard.usablePrice($0.price) },
                  currencyCode: item.symbol.currencyCode, supportsPosition: item.supportsPosition)
        })
        let exposure = SectorExposure.make(allocation: allocation, sectors: Dictionary(uniqueKeysWithValues:
            items.map { ($0.symbol, $0.tradingProfile?.sector ?? "") }))
        // A currency with any unvaluable holding can only be read as a floor, so
        // its over-limit flags are suppressed rather than asserted.
        var incompleteCurrencies = Set<String>()
        for item in items {
            guard item.positionQuantity != 0 else { continue }
            guard quote(item.symbol).flatMap({ WorkbenchBoard.usablePrice($0.price) }) == nil else { continue }
            incompleteCurrencies.insert(item.symbol.currencyCode)
        }
        self.sectorMissingQuoteCount = incompleteCurrencies.count
        self.sectorRows = Array(exposure.prefix(6)).map {
            WorkbenchSectorRow($0, limits: sectorLimits, isPricedPartOnly: incompleteCurrencies.contains($0.currencyCode))
        }

        self.phaseNote = WorkbenchBoard.phaseNote(phase: phase,
                                                  reached: reachedSymbols.count, backlog: backlog)

        // MARK: Per-symbol summaries
        //
        // Every scoped symbol gets one, not only the symbols that became tasks:
        // the risk row can select a symbol that has no task, and an empty panel
        // there would read as a missing instrument rather than a quiet one.

        var summaries: [SymbolID: WorkbenchSymbolSummary] = [:]
        for symbol in scopedSymbols.union(historyItems.map(\.symbol)) {
            summaries[symbol] = WorkbenchBoard.summary(
                symbol: symbol, name: name(symbol), quote: quote(symbol), now: now,
                entries: active.filter { $0.symbol == symbol },
                events: (windowEventsBySymbol[symbol] ?? []).sorted { $0.event.date < $1.event.date },
                liveEvents: liveEvents(symbol),
                pendingJournalTransactionID: todayReviewBySymbol[symbol]?.first
            )
        }
        self.summaries = summaries
    }

    // MARK: Pure helpers (shared with the self-test)

    /// The market's own calendar day for an instant. This is a *reference
    /// clock* for quotes and events only — never for attributing a recorded
    /// fill, whose date is a user-entered local civil day.
    static func marketReferenceDay(for market: Market, at date: Date) -> CalendarDay {
        TradingCalendar.tradingDay(of: market, at: date)
    }

    enum RecordedDayRelation {
        case today
        case earlier
        case future
    }

    /// Which side of "today" a transaction's *recorded* date falls on, read in
    /// the machine's own calendar. Deliberately not in the exchange's time
    /// zone: `PositionTransaction.date` is stored as the user's local civil
    /// date (the entry form writes local midnight), so reinterpreting it in a
    /// market time zone would move a US record to another day. A future-dated
    /// record is neither today's work nor a backlog.
    static func recordedDayRelation(_ date: Date, now: Date, calendar: Calendar = .current) -> RecordedDayRelation {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return .today }
        return day < today ? .earlier : .future
    }

    /// Whether a transaction lands on today's recorded local day. Kept as the
    /// single definition so the "today" count and the per-symbol review tasks
    /// can never disagree.
    static func isOnRecordedDay(_ transaction: PositionTransaction, now: Date,
                                calendar: Calendar = .current) -> Bool {
        recordedDayRelation(transaction.date, now: now, calendar: calendar) == .today
    }

    /// The nearest forward-looking review checkpoint recorded on this symbol's
    /// fills, stated once per symbol. Independent of the retrospective backlog
    /// above: a checkpoint is a note to the future ("check this again on …"),
    /// and a fill can have one, the other, or both.
    static func dueReviewText(_ symbol: SymbolID, items: [WatchItem], today: Date,
                              calendar: Calendar) -> String? {
        guard let item = items.first(where: { $0.symbol == symbol }) else { return nil }
        var due: [(days: Int, note: String?)] = []
        for transaction in item.transactions {
            guard let review = transaction.review,
                  // A note without a date is still a checkpoint worth surfacing
                  // in the journal, but it has no day, so it can never be due.
                  let date = review.nextReviewDate else { continue }
            let note = review.nextReviewNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            guard days <= 0 else { continue }
            due.append((days, note))
        }
        // The nearest checkpoint wins; a date with no note is still a due
        // checkpoint, so its absence must not discard the row.
        guard let nearest = due.map(\.days).min() else { return nil }
        let note = due.first(where: { $0.days == nearest })?.note
        let when = nearest == 0 ? "今日" : "已逾期 \(-nearest) 天"
        let checkpoint = "复盘检查点\(when)"
        guard let note, note.isEmpty == false else { return checkpoint }
        return "\(checkpoint)：\(note)"
    }

    /// Condition states are preserved exactly as stored; this only counts what
    /// still needs the user's attention. The linked-event reading is delegated
    /// to core so a missing or materially changed event triggers the same
    /// pending check everywhere it is derived.
    static func conditionsToReview(_ entry: TradePlanEntry, now: Date,
                                   currentEvents: [InstrumentEvent] = []) -> Int {
        (entry.plan.conditions ?? []).filter {
            $0.requiresReview(at: now, currentEvents: currentEvents)
        }.count
    }

    /// Reasons are collected from independent signals, so the same phrase can
    /// arrive twice for one symbol; it is printed once.
    static func deduplicated(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    static func planSummary(_ entry: TradePlanEntry, price: Double?, conditions: Int) -> String {
        var parts = ["\(entry.plan.kind == .buy ? "买入" : "卖出") "
            + PriceFormatter.price(entry.plan.price, market: entry.symbol.market)
            + " × " + PriceFormatter.quantity(entry.remainingQuantity)]
        if let price {
            parts.append(entry.plan.isReached(at: price)
                ? "已到价（不代表成交）"
                : String(format: "距触发 %.1f%%", entry.plan.gapPercent(from: price)))
        } else {
            // Covers both a missing quote and a closed/stale one: neither is an
            // intraday signal, so neither may read as "waiting at a distance".
            parts.append("无有效盘中行情（不计到价）")
        }
        if conditions > 0 { parts.append("\(conditions) 条条件待核对") }
        if entry.filledQuantity > 0 {
            parts.append("已成 \(PriceFormatter.quantity(entry.filledQuantity))")
        }
        return parts.joined(separator: " · ")
    }

    /// Identity for a plan row without leaking a raw UUID at the user. The
    /// kind, price, size, pool and note tell two plans apart; the id is only a
    /// fallback for two otherwise identical rows.
    static func planIdentity(_ entry: TradePlanEntry) -> String {
        var parts = ["\(entry.plan.kind == .buy ? "买入" : "卖出") "
            + PriceFormatter.price(entry.plan.price, market: entry.symbol.market)
            + " × " + PriceFormatter.quantity(entry.plan.quantity)]
        if let pool = entry.plan.positionPool { parts.append(pool.title) }
        if let note = entry.plan.note?.trimmingCharacters(in: .whitespacesAndNewlines), note.isEmpty == false {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// Phase changes ordering and emphasis only. The set of tasks, every count
    /// and every number stays exactly the same. The final tiebreak is the symbol
    /// itself, not the display name: two instruments can share a name, and a set
    /// iteration order that leaks into the list would reshuffle rows between
    /// refreshes.
    static func order(_ tasks: [WorkbenchTask], phase: WorkbenchPhase) -> [WorkbenchTask] {
        func tiebreak(_ lhs: WorkbenchTask, _ rhs: WorkbenchTask) -> Bool {
            lhs.name == rhs.name ? lhs.symbol.description < rhs.symbol.description : lhs.name < rhs.name
        }
        func reviewPriority(_ lhs: WorkbenchTask, _ rhs: WorkbenchTask) -> Bool? {
            let left = lhs.reviewCount ?? 0 > 0 || lhs.checkpointID != nil || !lhs.verifications.isEmpty
            let right = rhs.reviewCount ?? 0 > 0 || rhs.checkpointID != nil || !rhs.verifications.isEmpty
            guard left != right else { return nil }
            return left
        }
        switch phase {
        case .preMarket:
            return tasks.sorted { lhs, rhs in
                if (lhs.eventCount > 0) != (rhs.eventCount > 0) { return lhs.eventCount > 0 }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if lhs.reached != rhs.reached { return !lhs.reached }
                return tiebreak(lhs, rhs)
            }
        case .intraday:
            return tasks.sorted { lhs, rhs in
                if lhs.reached != rhs.reached { return lhs.reached }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if let review = reviewPriority(lhs, rhs) { return review }
                return tiebreak(lhs, rhs)
            }
        case .postMarket:
            return tasks.sorted { lhs, rhs in
                if let review = reviewPriority(lhs, rhs) { return review }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if lhs.reached != rhs.reached { return lhs.reached }
                return tiebreak(lhs, rhs)
            }
        }
    }

    static func phaseNote(phase: WorkbenchPhase, reached: Int, backlog: Int) -> String {
        switch phase {
        case .preMarket:
            return "盘前侧重待观察计划、临近事件与资金准备。"
        case .intraday:
            return reached > 0 ? "盘中侧重有效行情下的到价与待核对条件。" : "当前无有效盘中行情到价。"
        case .postMarket:
            return backlog > 0 ? "盘后侧重今日成交复盘；较早记录在历史入口。" : "盘后侧重今日成交复盘。"
        }
    }

    static func summary(symbol: SymbolID, name: String, quote: Quote?, now: Date,
                        entries: [TradePlanEntry], events: [TradingEventEntry],
                        liveEvents: [InstrumentEvent] = [],
                        pendingJournalTransactionID: UUID? = nil) -> WorkbenchSymbolSummary {
        let isCurrent = quote.map { TradingQuoteHealth.isCurrent($0, now: now) } ?? false
        let price = quote.flatMap { usablePrice($0.price) }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = symbol.market.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        let quoteText: String
        if let price {
            quoteText = "\(PriceFormatter.price(price, market: symbol.market)) \(symbol.currencyCode)"
        } else {
            quoteText = "无可用报价"
        }
        let statusText = isCurrent ? "盘中有效行情" : (quote == nil ? "缺报价" : "收盘/历史参考价")
        let timestampText = quote.map {
            "报价时点 \(formatter.string(from: $0.timestamp))（\(symbol.market.timeZoneDisplayName)）"
                + (isCurrent ? "" : " · 参考价不参与到价")
        } ?? "尚未取到报价"

        let planRows = entries.map { entry -> WorkbenchSymbolSummary.PlanRow in
            let conditions = conditionsToReview(entry, now: now, currentEvents: liveEvents)
            var detail = "已成 \(PriceFormatter.quantity(entry.filledQuantity))"
                + " · 待执行 \(PriceFormatter.quantity(entry.remainingQuantity))"
            if conditions > 0 { detail += " · \(conditions) 条条件待核对" }
            return .init(id: entry.id, title: planIdentity(entry), detail: detail)
        }
        // Event dates are civil days in the calendar's zone, not quote instants.
        let eventFormatter = DateFormatter()
        eventFormatter.calendar = EastmoneyTradingEvents.dateCalendar
        eventFormatter.timeZone = EastmoneyTradingEvents.dateCalendar.timeZone
        eventFormatter.dateFormat = "MM-dd"
        let eventRows = events.map { entry -> WorkbenchDetailRow in
            let start = eventFormatter.string(from: entry.event.date)
            let period = entry.event.endDate.map { start + "–" + eventFormatter.string(from: $0) } ?? start
            return WorkbenchDetailRow(
                id: entry.id,
                title: "\(period) · \(entry.event.title)",
                detail: entry.isForecast ? "预约" : entry.sourceName
            )
        }
        return WorkbenchSymbolSummary(
            symbol: symbol, name: name, market: symbol.market,
            quoteText: quoteText, quoteStatusText: statusText, quoteTimestampText: timestampText,
            quoteIsCurrent: isCurrent, plans: planRows, events: eventRows,
            // "定位池" opens the pool board; a plan with no pool yet is the one
            // that needs placing, so it is preferred over an already-placed one.
            pendingPoolPlanID: entries.first { $0.plan.positionPool == nil }?.id ?? entries.first?.id,
            pendingJournalTransactionID: pendingJournalTransactionID
        )
    }

    static func defenses(items: [WatchItem], quote: (SymbolID) -> Quote?, now: Date,
                         name: (SymbolID) -> String) -> [WorkbenchDefense] {
        items.compactMap { item -> (WatchItem, Quote, Double)? in
            guard item.positionQuantity > 0, let stop = item.tradingProfile?.stopPrice,
                  let q = quote(item.symbol), usablePrice(q.price) != nil else { return nil }
            return (item, q, stop)
        }
        .sorted { lhs, rhs in
            let left = (lhs.1.price - lhs.2) / lhs.1.price
            let right = (rhs.1.price - rhs.2) / rhs.1.price
            return left < right
        }
        .prefix(5)
        .map { item, q, stop in
            let isCurrent = TradingQuoteHealth.isCurrent(q, now: now)
            let value = q.price <= stop
                ? "低于防守价"
                : String(format: "距防守 %.1f%%", (q.price - stop) / q.price * 100)
            return WorkbenchDefense(
                symbol: item.symbol, name: name(item.symbol),
                detail: "防守 \(PriceFormatter.price(stop, market: item.symbol.market)) · \(isCurrent ? "盘中报价" : "收盘/历史参考")",
                valueText: value, isWarning: isCurrent && q.price <= stop
            )
        }
    }

    static func usablePrice(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    /// Verified pool shares only. A position whose allocation has not been
    /// reconciled is reported with an empty split rather than a stale one: the
    /// projection then reports the shortfall, which is the honest answer, while
    /// showing the previously verified portion as if it were current would not.
    static func poolQuantities(for item: WatchItem) -> [PositionPool: Double] {
        guard !item.positionAllocationNeedsReconciliation else { return [:] }
        let portions = item.positionAllocation?.portions ?? []
        guard portions.isEmpty == false else { return [:] }
        var result: [PositionPool: Double] = [:]
        for portion in portions where portion.quantity.isFinite && portion.quantity > 0 {
            result[portion.pool, default: 0] += portion.quantity
        }
        return result
    }
}

// MARK: - Small derived value types

struct WorkbenchTask: Identifiable {
    struct PlanRow: Identifiable {
        let id: UUID
        let detail: String
        let entry: TradePlanEntry
    }
    struct VerificationRow: Identifiable {
        let id: UUID
        let title: String
        let detail: String
    }

    let symbol: SymbolID
    let name: String
    let reached: Bool
    let conditionCount: Int
    let eventCount: Int
    let reasons: [String]
    let plans: [PlanRow]
    /// Today's unreviewed fills for this symbol, aggregated before sorting so a
    /// three-fill day is one task, not three rows. The ids are kept so every
    /// underlying record stays reachable from the task.
    let reviewTransactionIDs: [UUID]
    /// A plan checkpoint that has come due, stated once per symbol.
    let dueReviewText: String?
    var checkpointID: UUID? = nil
    var verifications: [VerificationRow] = []

    var id: SymbolID { symbol }

    var reviewCount: Int? { reviewTransactionIDs.isEmpty ? nil : reviewTransactionIDs.count }

    var countText: String {
        var parts: [String] = []
        if plans.isEmpty == false { parts.append("\(plans.count) 条计划") }
        if eventCount > 0 { parts.append("\(eventCount) 个事件") }
        if let reviewCount { parts.append("\(reviewCount) 笔待复盘") }
        if !verifications.isEmpty { parts.append("\(verifications.count) 份持仓判断") }
        return parts.joined(separator: " · ")
    }
}

struct WorkbenchSymbolSummary {
    struct PlanRow: Identifiable {
        let id: UUID
        let title: String
        let detail: String
    }

    let symbol: SymbolID
    let name: String
    let market: Market
    let quoteText: String
    let quoteStatusText: String
    let quoteTimestampText: String
    let quoteIsCurrent: Bool
    let plans: [PlanRow]
    let events: [WorkbenchDetailRow]
    let pendingPoolPlanID: UUID?
    let pendingJournalTransactionID: UUID?
}

/// One label/value line in the selected-symbol panel, already formatted.
struct WorkbenchDetailRow: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct WorkbenchCapital: Identifiable {
    struct Segment {
        let pool: PositionPool
        let value: Double
    }

    let code: String
    let holdings: Double
    let cash: Double?
    let plannedBuy: Double
    let budgetGap: Double
    let hasOverflow: Bool
    let segments: [Segment]
    let trackScale: Double
    /// The projection could not price part of this currency's holdings.
    let hasMissingQuote: Bool
    /// At least one position in this currency still needs its pool split
    /// reconciled, so the pool rows below are a floor.
    let needsReconciliation: Bool

    var id: String { code }
    var cashIsKnown: Bool { cash != nil }
    var hasSegments: Bool { segments.contains { $0.value > 0 } }
    var segmentTotal: Double { segments.reduce(0) { $0 + $1.value } }
    var hasUnverified: Bool { needsReconciliation }

    /// Unknown cash is a word, never a zero. Zero is a real answer the user gave.
    /// The label names the account, because the recorded balance is global per
    /// currency and is deliberately not scoped to the selected market.
    var cashText: String {
        guard let cash else { return "账户现金 未录" }
        return "账户现金 \(PriceFormatter.money(cash, currencyCode: code))"
    }

    /// A holdings figure that could not be fully priced says so in place: it is
    /// the priced part, not the position's value.
    var holdingsText: String {
        let money = PriceFormatter.money(holdings, currencyCode: code)
        return hasMissingQuote ? "持仓 \(money)（部分缺价）" : "持仓 \(money)"
    }

    var missingQuoteText: String {
        "该币种有持仓缺可用报价，市值只计已计价部分；超上限判断不作数。"
    }

    var unverifiedText: String {
        "该币种有持仓分账未核对，池内金额只含已核对份额，不代表全部持仓。"
    }

    var segmentText: String {
        segments.filter { $0.value > 0 }
            .map { "\($0.pool.title) \(PriceFormatter.money($0.value, currencyCode: code))" }
            .joined(separator: " · ")
    }

    init(_ projection: PoolBudgetProjection.CurrencyProjection,
         reconciliationSymbols: Set<SymbolID> = []) {
        code = projection.code
        holdings = projection.holdingsBefore
        cash = projection.cashBalance
        plannedBuy = projection.plannedBuyAmount
        budgetGap = projection.purchaseBudgetGap
        hasOverflow = projection.hasOverflow
        hasMissingQuote = projection.unvaluableQuantity > 0
        needsReconciliation = reconciliationSymbols.isEmpty == false
            && projection.pools.contains { $0.needsReconciliation }
        let rows = projection.pools.map { Segment(pool: $0.pool, value: $0.heldAmount) }
            .filter { $0.value.isFinite && $0.value > 0 }
        segments = rows
        trackScale = max(rows.reduce(0) { $0 + $1.value }, projection.holdingsBefore)
    }
}

struct WorkbenchDefense: Identifiable {
    let symbol: SymbolID
    let name: String
    let detail: String
    let valueText: String
    let isWarning: Bool
    var id: SymbolID { symbol }
}

struct WorkbenchSectorRow: Identifiable {
    let name: String
    let currencyCode: String
    let percent: Double
    let overLimit: Bool
    /// The currency has unvaluable holdings, so the percentage is the priced
    /// part only and `overLimit` is suppressed rather than asserted.
    let hasMissingQuote: Bool
    var id: String { "\(currencyCode):\(name)" }

    init(_ exposure: SectorExposure, limits: [String: Double], isPricedPartOnly: Bool = false) {
        name = exposure.name
        currencyCode = exposure.currencyCode
        percent = exposure.percent
        hasMissingQuote = isPricedPartOnly
        overLimit = !isPricedPartOnly && (limits[exposure.id].map { exposure.percent > $0 } ?? false)
    }
}

// MARK: - Phase & scope

enum WorkbenchPhase: String, CaseIterable {
    case preMarket
    case intraday
    case postMarket

    var title: String {
        switch self {
        case .preMarket: "盘前"
        case .intraday: "盘中"
        case .postMarket: "盘后"
        }
    }
}

/// The market scope. Real `Market` values only: a currency is not a market, and
/// a holiday calendar is not claimed here.
enum WorkbenchScope: String, CaseIterable {
    case all
    case chinaA
    case hongKong
    case unitedStates

    var title: String {
        switch self {
        case .all: "全部"
        case .chinaA: "A股"
        case .hongKong: "港股"
        case .unitedStates: "美股"
        }
    }

    var markets: [Market] {
        switch self {
        case .all: [.sh, .sz, .hk, .us]
        case .chinaA: [.sh, .sz]
        case .hongKong: [.hk]
        case .unitedStates: [.us]
        }
    }

    func contains(_ market: Market) -> Bool {
        switch self {
        case .all: true
        case .chinaA: market.isChinaA
        case .hongKong: market == .hk
        case .unitedStates: market == .us
        }
    }
}

// MARK: - Read-only bridge into existing settings

/// A plain snapshot of the user's recorded cash and pool limits, taken once per
/// render from `PoolBudgetSettings`. The projection wants dictionaries; this is
/// the only place they are read, and it is read-only — the workbench has no path
/// that could write a balance, a limit, or a scenario.
struct WorkbenchCashInput {
    var balances: [String: Double] = [:]
    var updatedAt: [String: Date] = [:]
    var limits: [String: [PositionPool: Double]] = [:]

    init() {}

    @MainActor
    init(_ settings: PoolBudgetSettings) {
        balances = settings.cashBalances.mapValues(\.amount)
        updatedAt = settings.cashBalances.mapValues(\.updatedAt)
        limits = settings.poolLimits
    }

    /// nil means unknown — the caller must render that, never a zero.
    func balance(currency: String) -> Double? {
        balances[currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}
