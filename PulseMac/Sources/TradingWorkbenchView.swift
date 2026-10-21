import SwiftUI
import PulseCore
import PulseUI

/// 今日工作台：一天要看的任务、一个选中标的的摘要，以及常驻的资金与风险条。
///
/// 这一层只做**派生展示**。它读取 `AppState` 里的自选、报价、计划、成交与
/// 设置，算出「今天该关注什么」，从不写入成交、持仓、计划或账本。四条刻意的
/// 边界写在这里，因为每一条如果反过来做都会悄悄撒谎：
///
/// 1. **阶段改变工作清单，不改变账本。** 盘前准备计划与资金，盘中跟进有效信号，
///    盘后复盘实际成交。各阶段计数保持各自的真实单位，资金与持仓始终来自同一事实模型。
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
/// 市场参考时钟使用 `TradingCalendar` 与有界的 `ExchangeCalendar`；超出已核验
/// 年份回退到工作日规则。阶段是工作清单选择，不声称改变真实的开市状态。
struct TradingWorkbenchView: View {
    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    let onShowPlans: () -> Void
    let onShowJournal: () -> Void
    let onShowEvents: () -> Void
    var onShowPools: () -> Void = {}

    @State private var phase: WorkbenchPhase = .intraday
    @State private var initialPhaseApplied = false
    @State private var scope: WorkbenchScope = .all
    @State private var selectedSymbol: SymbolID?
    @State private var showRisk = false
    @State private var showSectors = false
    @State private var showCapitalDetail = false
    @State private var executionEntry: TradePlanEntry?
    @State private var workflowEntry: TradePlanEntry?
    @State private var verificationPortion: PositionPoolsView.VerificationDraft?
    @State private var showsFuyaoBoards = false
    @State private var showsFuyaoHoldings = false
    @State private var showsFuyaoSentiment = false

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
        _initialPhaseApplied = State(initialValue: true)
        _scope = State(initialValue: initial.scope)
        _selectedSymbol = State(initialValue: initial.selectedSymbol)
        _showCapitalDetail = State(initialValue: initial.showsCapitalDetail)
    }

    // MARK: - Derived inputs

    /// All items, before any market filter, in the store's display order. Kept
    /// separate from the scope filter so the capital summary can state what it
    /// deliberately narrowed.
    private var allItems: [WatchItem] { appState.watchlist.allItems }
    private var marketContext: WorkbenchMarketContext {
        WorkbenchMarketContext(items: allItems + appState.watchlist.tradeHistoryItems)
    }
    private var effectiveScope: WorkbenchScope { marketContext.resolvedScope(scope) }

    private var items: [WatchItem] {
        allItems.filter { effectiveScope.contains($0.symbol.market) }
    }

    private var historyItems: [WatchItem] {
        appState.watchlist.tradeHistoryItems.filter { effectiveScope.contains($0.symbol.market) }
    }

    // MARK: - Body

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .sheet(isPresented: $showRisk) { TradeRiskCalculatorView(initialSymbol: nil) }
        .sheet(isPresented: $showSectors) { SectorExposureView() }
        .sheet(isPresented: $showsFuyaoBoards) { FuyaoBoardsView(onSelect: onSelect) }
        .sheet(isPresented: $showsFuyaoHoldings) { FuyaoPortfolioLookThroughView() }
        .sheet(isPresented: $showsFuyaoSentiment) { FuyaoSentimentView(onSelect: onSelect) }
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
        .onAppear {
            guard !initialPhaseApplied else { return }
            phase = WorkbenchStagePresentation.suggestedPhase(markets: marketContext.clockMarkets(for: effectiveScope), at: .now)
            initialPhaseApplied = true
        }
        .onChange(of: phase) { _, _ in selectedSymbol = nil }
        .onChange(of: scope) { _, _ in selectedSymbol = nil }
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
        let stage = WorkbenchStagePresentation(board: board, phase: phase, items: items, historyItems: historyItems,
            entries: appState.watchlist.tradePlanEntries, now: now,
            name: { appState.watchlist.item(for: $0)?.resolvedDisplayName ?? $0.displayCode })
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(now: now, board: board)
                if appState.fuyaoResearchAvailable && (effectiveScope.contains(.sh) || effectiveScope.contains(.sz)) {
                    FuyaoSentimentCard { showsFuyaoSentiment = true }
                }
                stageHeader(stage)
                countBar(board, stage: stage)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        taskColumn(board, stage: stage).frame(maxWidth: .infinity, alignment: .top)
                        summaryColumn(board).frame(width: 340, alignment: .top)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        taskColumn(board, stage: stage)
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
            HStack(spacing: 10) {
                Button { showsFuyaoBoards = true } label: { Label("板块强弱", systemImage: "square.grid.3x3") }
                Button { showsFuyaoHoldings = true } label: { Label("ETF 穿透", systemImage: "square.stack.3d.up") }
                Button { showsFuyaoSentiment = true } label: { Label("市场情绪", systemImage: "waveform.path.ecg") }
            }.controlSize(.small)
        }
    }

    private var title: some View {
        Text(PulseLocalization.localizedString("workbench.title"))
            .font(.system(size: 20, weight: .semibold))
    }

    @ViewBuilder
    private var scopePicker: some View {
        if marketContext.scopes.count > 1 {
            Picker("资产市场", selection: Binding(get: { effectiveScope }, set: { scope = $0 })) {
                ForEach(marketContext.scopes, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("按实际资产市场筛选，不代表不同的券商账户。")
        } else {
            Label(marketContext.label, systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var phasePicker: some View {
        Picker(PulseLocalization.localizedString("workbench.phase.title"), selection: $phase) {
            ForEach(WorkbenchPhase.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(PulseLocalization.localizedString("workbench.phase.help"))
    }

    /// One compact metadata line. Session semantics live behind the help
    /// button: a paragraph about the absence of a holiday calendar is useful
    /// once, not on every refresh.
    private func marketDayLine(now: Date, board: WorkbenchBoard) -> some View {
        let markets = marketContext.clockMarkets(for: effectiveScope)
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
        let line = PulseLocalization.localizedString(
            "workbench.meta.line", phase.title, dayText, stateText)
            + (phaseNote.isEmpty ? "" : " · \(phaseNote)")
        Text(line)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(singleLine ? 1 : 2)
    }

    private func metadataHelp(states: [SessionState], zoneText: String) -> some View {
        Image(systemName: "info.circle")
            .font(.caption2).foregroundStyle(.tertiary)
            .help(PulseLocalization.localizedString("workbench.meta.zoneHelp", zoneText))
            .accessibilityLabel(PulseLocalization.localizedString("workbench.meta.label"))
            .accessibilityValue(states.map(Self.sessionLabel).joined(separator: "、"))
    }

    static func sessionLabel(_ state: SessionState) -> String {
        switch state {
        case .preMarket: PulseLocalization.localizedString("workbench.session.preMarket")
        case .regular: PulseLocalization.localizedString("workbench.session.regular")
        case .lunchBreak: PulseLocalization.localizedString("workbench.session.lunchBreak")
        case .postMarket: PulseLocalization.localizedString("workbench.session.postMarket")
        case .overnight: PulseLocalization.localizedString("workbench.session.overnight")
        case .closed: PulseLocalization.localizedString("workbench.session.closed")
        }
    }

    private func stageHeader(_ stage: WorkbenchStagePresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stage.title).font(.headline)
            Text(stage.subtitle).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                switch phase {
                case .preMarket:
                    Button("检查计划", action: onShowPlans)
                    Button("核对资金", action: onShowPools)
                case .intraday:
                    Button("跟进计划", action: onShowPlans)
                    Button("查看实际成交", action: onShowJournal)
                case .postMarket:
                    Button("写成交复盘", action: onShowJournal)
                    if stage.activePlanCount > 0 {
                        Button("查看后续 \(stage.activePlanCount) 条计划", action: onShowPlans)
                    }
                }
            }.controlSize(.small)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Counts
    // Stage-specific metrics keep their real units; they are never summed into
    // a fictitious total of symbols, plans, events and recorded fills.

    private func countBar(_ board: WorkbenchBoard, stage: WorkbenchStagePresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { countChips(stage); countSpacer(board) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { countChips(stage) }
                backlogLink(board)
            }
        }
        .font(.caption)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func countChips(_ stage: WorkbenchStagePresentation) -> some View {
        ForEach(stage.metrics) { metric in
            countChip(metric.text, icon: metric.icon, tint: metric.value > 0 ? .primary : .secondary)
        }
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
                Label(PulseLocalization.localizedString("workbench.backlog.link", backlog.count),
                      systemImage: "clock.arrow.circlepath")
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

    private func taskColumn(_ board: WorkbenchBoard, stage: WorkbenchStagePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(stage.taskTitle, systemImage: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(PulseLocalization.localizedString("workbench.tasks.help"))
                    .accessibilityLabel(PulseLocalization.localizedString("workbench.tasks.label"))
                Button(PulseLocalization.localizedString("workbench.tasks.openPools"), action: onShowPools)
                    .font(.caption)
            }
            if stage.tasks.isEmpty {
                singleLine(stage.emptyText, icon: "checkmark.circle")
            }
            ForEach(stage.tasks) { task in
                taskRow(task, allowsPlanFill: stage.allowsPlanFillAction)
            }
            if stage.showsCashTasks {
                ForEach(board.cashNotes) { note in
                    taskLink(note.title, detail: note.detail, action: onShowPools)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    private func taskRow(_ task: WorkbenchTask, allowsPlanFill: Bool) -> some View {
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
            .help(PulseLocalization.localizedString("workbench.tasks.selectHelp"))

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
                            Button(PulseLocalization.localizedString("workbench.task.review")) { workflowEntry = entry.entry }
                                .controlSize(.small)
                            if allowsPlanFill {
                                Button(PulseLocalization.localizedString("workbench.task.recordFill")) { executionEntry = entry.entry }
                                    .controlSize(.small)
                            }
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
                        Button(PulseLocalization.localizedString("workbench.task.reviewPosition")) {
                            verificationPortion = .init(symbol: task.symbol, portionID: row.id)
                        }.controlSize(.small)
                    }.padding(.leading, 18)
                }
                if task.plans.isEmpty == false {
                    Button(PulseLocalization.localizedString("workbench.task.allPlans")) { onShowPlans() }
                        .buttonStyle(.link).font(.caption2).padding(.leading, 18)
                }
            } else if task.plans.isEmpty == false {
                Text(task.plans.count == 1
                     ? task.plans[0].detail
                     : PulseLocalization.localizedString("workbench.task.planCount", task.plans.count))
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
            Button(PulseLocalization.localizedString("workbench.task.reviewFills", count)) {
                appState.pendingJournalTransactionID = first
                onShowJournal()
            }
            .buttonStyle(.link).font(.caption2)
            .padding(.leading, 18)
            .help(PulseLocalization.localizedString("workbench.task.reviewFills.help"))
        }
        if let checkpointID = task.checkpointID {
            Button(PulseLocalization.localizedString("workbench.task.reviewCheckpoint")) {
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
                Label(PulseLocalization.localizedString("workbench.summary.title"), systemImage: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
            }
            if let symbol = selectedSymbol, let summary = board.summary(for: symbol) {
                summaryContent(summary, verifications: board.tasks.first { $0.symbol == symbol }?.verifications ?? [])
            } else {
                singleLine(PulseLocalization.localizedString("workbench.summary.empty"), icon: "cursorarrow.click")
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
                detailBlock(PulseLocalization.localizedString("workbench.summary.plans"), rows: summary.plans.map {
                    WorkbenchDetailRow(id: $0.id.uuidString, title: $0.title, detail: $0.detail)
                })
            }
            if summary.events.isEmpty == false {
                detailBlock(PulseLocalization.localizedString("workbench.summary.events"), rows: summary.events)
            }
            if !verifications.isEmpty {
                detailBlock(PulseLocalization.localizedString("workbench.summary.verifications"), rows: verifications.map {
                    WorkbenchDetailRow(id: $0.id.uuidString, title: $0.title, detail: $0.detail)
                })
            }
            if summary.plans.isEmpty && summary.events.isEmpty && verifications.isEmpty {
                singleLine(PulseLocalization.localizedString("workbench.summary.inactive"), icon: "minus")
            }
            // One detail action only: this callback opens the summary
            // inspector, so the old duplicate "打开完整标的" pair is gone.
            HStack(spacing: 8) {
                Button(PulseLocalization.localizedString("workbench.summary.openDetail")) { onSelect(summary.symbol) }
                    .controlSize(.small)
                if let planID = summary.pendingPoolPlanID {
                    Button(PulseLocalization.localizedString("workbench.summary.locatePlan")) {
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
                    Text(PulseLocalization.localizedString("workbench.capital.subtitle"))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    capitalActions
                }
                VStack(alignment: .leading, spacing: 4) {
                    capitalTitle
                    capitalActions
                }
            }
            if board.capitals.isEmpty {
                singleLine(PulseLocalization.localizedString("workbench.capital.empty"), icon: "minus")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], alignment: .leading, spacing: 8) {
                    ForEach(board.capitals) { capital in
                        capitalRow(capital)
                    }
                }
            }
            if board.unvaluableCount > 0 {
                Text(PulseLocalization.localizedString("workbench.capital.unpriced", board.unvaluableCount))
                    .font(.caption2).foregroundStyle(.orange)
            }
            if board.reconciliationCount > 0 {
                Text(PulseLocalization.localizedString("workbench.capital.unreconciled", board.reconciliationCount))
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.07)) }
    }

    private var capitalTitle: some View {
        Label(PulseLocalization.localizedString("workbench.capital.title"), systemImage: "banknote")
            .font(.system(size: 13, weight: .semibold))
    }

    private var capitalActions: some View {
        HStack(spacing: 8) {
            Button(showCapitalDetail
                   ? PulseLocalization.localizedString("workbench.capital.collapse")
                   : PulseLocalization.localizedString("workbench.capital.expand")) { showCapitalDetail.toggle() }
                .font(.caption)
            Button(PulseLocalization.localizedString("workbench.capital.pools"), action: onShowPools).font(.caption)
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
                Text(PulseLocalization.localizedString("workbench.capital.overflow"))
                    .font(.caption2).foregroundStyle(.orange)
            }
            // A valid mini gauge is always drawn: hiding it behind the toggle
            // made the row look like it had no pool structure at all.
            if capital.hasSegments {
                PoolTrackGauge(height: 8,
                               segments: capital.segments.map { .init(pool: $0.pool, value: $0.value) },
                               scale: capital.trackScale)
                    .accessibilityLabel(PulseLocalization.localizedString("workbench.capital.shareLabel", capital.code))
                if showCapitalDetail {
                    Text(capital.segmentText).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text(PulseLocalization.localizedString("workbench.capital.pricedPart",
                             PriceFormatter.money(capital.segmentTotal, currencyCode: capital.code)))
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
                    Text(PulseLocalization.localizedString("workbench.capital.plannedBuy",
                             PriceFormatter.money(capital.plannedBuy, currencyCode: capital.code)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if capital.budgetGap > 0 {
                    Text(PulseLocalization.localizedString("workbench.capital.budgetGap",
                             PriceFormatter.money(capital.budgetGap, currencyCode: capital.code)))
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
                Label(PulseLocalization.localizedString("workbench.risk.title"), systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button(PulseLocalization.localizedString("workbench.risk.calculator")) { showRisk = true }.font(.caption)
            }
            if board.defenses.isEmpty {
                singleLine(PulseLocalization.localizedString("workbench.risk.empty"), icon: "minus")
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
                Label(PulseLocalization.localizedString("workbench.sector.title"), systemImage: "chart.pie")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Image(systemName: "questionmark.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(PulseLocalization.localizedString("workbench.sector.help"))
                    .accessibilityLabel(PulseLocalization.localizedString("workbench.sector.label"))
                Button(PulseLocalization.localizedString("workbench.sector.configure")) { showSectors = true }.font(.caption)
            }
            if board.sectorRows.isEmpty {
                singleLine(PulseLocalization.localizedString("workbench.sector.empty"), icon: "minus")
            }
            ForEach(board.sectorRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(row.name) · \(row.currencyCode)").font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f%%", row.percent)).font(.caption.monospacedDigit())
                    if row.overLimit {
                        Text(PulseLocalization.localizedString("workbench.sector.overLimit")).font(.caption2).foregroundStyle(.orange)
                    }
                    if row.hasMissingQuote {
                        Text(PulseLocalization.localizedString("workbench.sector.missingQuote")).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Text(PulseLocalization.localizedString("workbench.sector.footer")
                 + (board.sectorMissingQuoteCount > 0 ? PulseLocalization.localizedString("workbench.sector.footerMissing") : ""))
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

// Board derivation now compiles from SharedAppSupport/TradingWorkbenchBoard.swift.

extension WorkbenchCashInput {
    @MainActor
    init(_ settings: PoolBudgetSettings) {
        balances = settings.cashBalances.mapValues(\.amount)
        updatedAt = settings.cashBalances.mapValues(\.updatedAt)
        limits = settings.poolLimits
    }
}
