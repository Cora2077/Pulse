import SwiftUI
import PulseCore
import PulseUI

struct TradingEventsView: View {
    private enum Scope: Hashable {
        case holdings
        case focus
    }

    private struct EditorState: Identifiable {
        let id = UUID()
        let symbol: SymbolID
        let event: InstrumentEvent?
        var date: Date = .now
        /// The account open when this draft was built. The editor sheet's own
        /// state can outlive the view that presented it, and the entry it names
        /// may exist in the newly selected account too.
        var account: BrokerageAccountID
    }

    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void

    @State private var scope: Scope = .holdings
    @State private var editor: EditorState?
    @State private var pendingDelete: TradingEventEntry?
    /// The account the pending manual-event delete was requested under. The
    /// confirmation dialog is part of this view, so it survives any identity
    /// rebuild; the id alone would not say which ledger the entry came from.
    @State private var pendingDeleteAccount: BrokerageAccountID?
    @State private var actionError: String?
    @State private var showsTimeline = true
    @State private var selectedEvent: TradingEventEntry?
    @State private var pendingEditor: EditorState?
    @State private var pendingDetailDelete: TradingEventEntry?

    /// Opens this page with one event's detail already showing.
    ///
    /// Synthetic render capture needs a deterministic event instead of a click,
    /// and the store it reads is the fixture the capture already built. The
    /// production path leaves it nil: nothing opens by itself, and the initial
    /// value is never written back to any user data.
    init(onSelect: @escaping (SymbolID) -> Void, selectedEventID: UUID? = nil) {
        self.onSelect = onSelect
        _initialEventID = State(initialValue: selectedEventID)
    }

    @State private var initialEventID: UUID?
    /// Whether the synthetic initial selection has already been resolved, so a
    /// later re-render (or the user closing the sheet) cannot reopen it.
    @State private var didResolveInitialEvent = false

    private var focusedItems: [WatchItem] { appState.watchlist.items }
    private var heldItems: [WatchItem] { appState.watchlist.allItems.filter(\.hasPosition) }
    private var itemsToRefresh: [WatchItem] {
        Dictionary((heldItems + focusedItems).map { ($0.symbol, $0) }, uniquingKeysWith: { _, focus in focus })
            .values.sorted { $0.symbol.description < $1.symbol.description }
    }
    private var visibleItems: [WatchItem] {
        scope == .holdings ? heldItems : focusedItems
    }
    private var entries: [TradingEventEntry] { appState.tradingEvents.entries(for: visibleItems) }
    private var dateGroups: [(Date, [TradingEventEntry])] {
        let grouped = Dictionary(grouping: entries) { dateCalendar.startOfDay(for: $0.event.date) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
    private var dateCalendar: Calendar {
        EastmoneyTradingEvents.dateCalendar
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = actionError ?? appState.tradingEvents.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            if appState.tradingEvents.isRefreshing {
                ProgressView().controlSize(.small).padding(.bottom, 8)
            }
            if showsTimeline, !visibleItems.isEmpty {
                TradingEventTimeline(
                    items: visibleItems, entries: entries, onSelect: onSelect,
                    onOpen: { selectedEvent = $0 },
                    onAdd: { symbol, date in editor = currentEditorState(symbol: symbol, date: date) }
                )
            } else {
              ScrollView {
                if visibleItems.isEmpty {
                    emptyState("当前关注范围内没有持仓标的", detail: "切换到“当前关注”查看关注列表事件。")
                } else if entries.isEmpty {
                    emptyState("无可用自动事件，仍可手动添加", detail: "自动事件目前覆盖沪深 A 股；可以手动记录其他市场的日期。")
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(dateGroups, id: \.0) { date, dayEntries in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(dateTitle(date))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                ForEach(dayEntries) { entry in eventCard(entry) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: resolveInitialEvent)
        // A pending delete holds an id read from the previous account's events.
        // Nothing here is re-pointed: the request is dropped, and the user asks
        // again against the entries on screen now.
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            pendingDelete = nil
            pendingDeleteAccount = nil
            actionError = nil
        }
        .task(id: itemsToRefresh.map(\.symbol)) {
            guard !appState.isMainWindowDemo else { return }
            await appState.tradingEvents.refresh(items: itemsToRefresh)
        }
        .sheet(item: $editor) { state in
            TradingEventEditor(
                items: appState.watchlist.allItems,
                initialSymbol: state.symbol,
                event: state.event,
                initialDate: state.date,
                account: state.account
            )
            .environment(appState)
        }
        .sheet(item: $selectedEvent, onDismiss: {
            if let pendingEditor {
                editor = pendingEditor
                self.pendingEditor = nil
            } else if let pendingDetailDelete {
                pendingDelete = pendingDetailDelete
                self.pendingDetailDelete = nil
            }
        }) { entry in
            TradingEventDetailSheet(
                entry: entry,
                account: appState.watchlist.activeBrokerageAccountID,
                onEdit: { editEvent(entry) },
                onDelete: { requestDelete(entry) },
                onSelectSymbol: onSelect
            )
            .environment(appState)
        }
        .confirmationDialog(
            "删除这条手动事件？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deletePendingEvent() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("事件日历").font(.title2.weight(.semibold))
                HStack(spacing: 5) {
                    Text("东方财富 · 预约日期标为预告 · 日期按北京时间")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let symbol = (visibleItems.first ?? appState.watchlist.allItems.first)?.symbol else { return }
                editor = currentEditorState(symbol: symbol)
            } label: {
                Label("添加事件", systemImage: "plus")
            }
            .disabled(appState.watchlist.allItems.isEmpty)
        }
        HStack(spacing: 12) {
            Picker("显示", selection: $showsTimeline) {
                Text("时间轴").tag(true)
                Text("列表").tag(false)
            }.pickerStyle(.segmented).frame(width: 150)
            Picker("范围", selection: $scope) {
                Text("持仓").tag(Scope.holdings)
                Text("当前关注").tag(Scope.focus)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            Button {
                Task { await appState.tradingEvents.refresh(items: itemsToRefresh, force: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(appState.tradingEvents.isRefreshing || appState.isMainWindowDemo)
            Spacer()
            Text("单日节点 · 多日横条 · 点击查看详情")
                .font(.caption).foregroundStyle(.secondary)
        }
      }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func eventCard(_ entry: TradingEventEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        onSelect(entry.symbol)
                    } label: {
                        Text("\(entry.symbol.displayCode) · \(appState.watchlist.item(for: entry.symbol)?.resolvedDisplayName ?? entry.symbol.displayCode)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    Text(kindTitle(entry.event.kind))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    if entry.isForecast {
                        Text("预约 · 预告")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text(entry.event.title).font(.body)
                if entry.event.endDate != nil {
                    Text(eventPeriod(entry.event)).font(.caption).foregroundStyle(.secondary)
                }
                if let note = entry.event.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("来源：\(entry.sourceName)").font(.caption).foregroundStyle(.secondary)
                    if entry.isAutomatic {
                        Text("获取于 \(entry.event.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                        if Date.now.timeIntervalSince(entry.event.updatedAt) >= 6 * 60 * 60 {
                            Text("旧缓存 · 待更新").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if let rawURL = entry.event.sourceURL, let url = URL(string: rawURL) {
                        Link("打开来源", destination: url).font(.caption)
                    }
                }
            }
            Spacer(minLength: 4)
            if !entry.isAutomatic {
                Menu {
                    Button("编辑") { editEvent(entry) }
                    Button("删除", role: .destructive) { requestDelete(entry) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Resolves the synthetic initial event exactly once.
    ///
    /// The event is looked up across every instrument the page knows about, not
    /// just the visible scope, so a capture that named an event does not depend
    /// on which scope happens to be selected. It matches on the exact id and
    /// never falls back to "the first event": a capture that named nothing
    /// usable must show the ordinary page rather than an unrelated event.
    private func resolveInitialEvent() {
        guard !didResolveInitialEvent else { return }
        didResolveInitialEvent = true
        guard let initialEventID else { return }
        let all = appState.tradingEvents.entries(for: appState.watchlist.allItems)
        guard let match = all.first(where: { $0.event.id == initialEventID }) else { return }
        selectedEvent = match
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock").font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            if appState.watchlist.allItems.isEmpty {
                Text("请先添加标的到关注列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("手动添加事件") {
                    if let symbol = appState.watchlist.allItems.first?.symbol {
                        editor = currentEditorState(symbol: symbol)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
    }

    private func kindTitle(_ kind: InstrumentEvent.Kind) -> String {
        switch kind {
        case .earnings: "财报"
        case .dividend: "分红"
        case .unlock: "解禁"
        case .other: "其他"
        }
    }

    private func dateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = dateCalendar
        formatter.timeZone = dateCalendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func eventPeriod(_ event: InstrumentEvent) -> String {
        guard let end = event.endDate else { return dateTitle(event.date) }
        return "\(dateTitle(event.date)) — \(dateTitle(end))"
    }

    private func deletePendingEvent() {
        guard pendingDeleteAccount == appState.watchlist.activeBrokerageAccountID,
              let entry = pendingDelete,
              appState.watchlist.deleteInstrumentEvent(entry.event.id, for: entry.symbol) else {
            actionError = "事件删除失败，请重试。"
            pendingDelete = nil
            pendingDeleteAccount = nil
            return
        }
        actionError = nil
        pendingDelete = nil
        pendingDeleteAccount = nil
    }

    /// Builds an editor draft bound to the account selected right now.
    private func currentEditorState(symbol: SymbolID, date: Date = .now) -> EditorState {
        EditorState(
            symbol: symbol,
            event: nil,
            date: date,
            account: appState.watchlist.activeBrokerageAccountID
        )
    }

    private func editEvent(_ entry: TradingEventEntry) {
        let state = EditorState(
            symbol: entry.symbol,
            event: entry.event,
            date: entry.event.date,
            account: appState.watchlist.activeBrokerageAccountID
        )
        if selectedEvent != nil {
            pendingEditor = state
            selectedEvent = nil
        } else {
            editor = state
        }
    }

    private func requestDelete(_ entry: TradingEventEntry) {
        if selectedEvent != nil {
            pendingDetailDelete = entry
            selectedEvent = nil
        } else {
            pendingDelete = entry
            pendingDeleteAccount = appState.watchlist.activeBrokerageAccountID
        }
    }
}

/// One event, its own facts, and the plans that lean on it.
///
/// The link runs one way at write time and both ways at read time: this sheet
/// writes a copy of the event into a chosen condition's `eventReference`, and
/// then finds its own links by asking every plan which condition holds that
/// exact id. Nothing here creates a plan, confirms a condition, prices
/// anything, or sends an order — the strongest thing it does is set a linked
/// condition to `needsReview`, which is a request for the user's attention and
/// never a verdict about the trade.
struct TradingEventDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let entry: TradingEventEntry
    /// The account this sheet was opened against, captured by the presenter at
    /// presentation. Its state can outlive the page that showed it, and the plan
    /// id it writes into may also exist in whichever account is selected later.
    @State var account: BrokerageAccountID
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSelectSymbol: (SymbolID) -> Void

    init(entry: TradingEventEntry, account: BrokerageAccountID, onEdit: @escaping () -> Void,
         onDelete: @escaping () -> Void, onSelectSymbol: @escaping (SymbolID) -> Void) {
        self.entry = entry
        self._account = State(initialValue: account)
        self.onEdit = onEdit; self.onDelete = onDelete; self.onSelectSymbol = onSelectSymbol
    }

    /// Which condition is being linked, chosen from the plans below. A new one
    /// with no condition picked yet carries a nil condition id.
    @State private var selectedPlanID: UUID?
    @State private var selectedConditionID: UUID?
    @State private var newConditionTitle = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var linkedPlanDetail: TradePlan?

    /// The live plan behind the picker, re-read from the store on every render
    /// so a plan edited elsewhere is never written back from a stale copy.
    private var plansOnSymbol: [TradePlan] {
        appState.watchlist.item(for: entry.symbol)?.plans ?? []
    }

    /// Active plans only. A finished or cancelled plan is history: adding a
    /// fresh event link to it would claim reasoning about a decision already
    /// made, and the plan detail page is where its old snapshots are read.
    private var activePlans: [TradePlan] {
        plansOnSymbol.filter {
            $0.status == .active && TradePlanExecutionProgress(plan: $0,
                transactions: appState.watchlist.item(for: entry.symbol)?.transactions ?? []).remainingQuantity > 0
        }
    }

    private var selectedPlan: TradePlan? {
        guard let selectedPlanID else { return nil }
        return plansOnSymbol.first { $0.id == selectedPlanID }
    }

    /// Every condition that currently points at this event, with the plan it
    /// lives on. A condition whose snapshot id matches is a link regardless of
    /// whether its bytes still agree with the event — a changed date is exactly
    /// what the reader needs to see here.
    private var links: [(plan: TradePlan, condition: TradePlanCondition)] {
        plansOnSymbol.flatMap { plan in
            (plan.conditions ?? [])
                .filter { $0.eventReference?.id == entry.event.id }
                .map { (plan, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("事件详情").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    facts
                    linkedPlansSection
                    if !entry.isAutomatic {
                        HStack(spacing: 8) {
                            Button("编辑事件", action: onEdit)
                            Button("删除", role: .destructive, action: onDelete)
                            Spacer()
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(22)
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: primeSelection)
        .sheet(item: $linkedPlanDetail) { plan in
            VStack(spacing: 0) {
                HStack {
                    Text("关联计划").font(.headline)
                    Spacer()
                    Button("关闭") { linkedPlanDetail = nil }.keyboardShortcut(.cancelAction)
                }.padding()
                Divider()
                PlanWorkflowDetailView(symbol: entry.symbol, planID: plan.id,
                                       account: appState.watchlist.activeBrokerageAccountID)
            }.frame(width: 650, height: 680)
        }
        .onChange(of: selectedPlanID) { _, _ in
            selectedConditionID = nil
            statusMessage = nil
            errorMessage = nil
        }
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eventPeriod).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Text(entry.event.title).font(.body.weight(.medium))
                Text(kindTitle)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                if entry.isForecast {
                    Text("预约 · 预告").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 8) {
                Button {
                    onSelectSymbol(entry.symbol)
                } label: {
                    Text("\(entry.symbol.displayCode) · \(appState.displayName(for: entry.symbol))")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                Text("来源：\(entry.sourceName)").font(.caption).foregroundStyle(.secondary)
            }
            if let note = entry.event.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Links

    /// The link list plus the one control that adds a link.
    ///
    /// The picker offers the plans and conditions that already exist, because
    /// this page must not invent a plan to hang an event on. When the symbol
    /// has no active plan the section says so in one line and stops; the plan
    /// editor is where a plan is created, and this sheet deliberately has no
    /// copy of it.
    private var linkedPlansSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("关联事件与计划").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(links.count) 条")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if links.isEmpty {
                Text("这条事件还没有关联任何计划条件。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(links, id: \.condition.id) { link in
                    linkedRow(plan: link.plan, condition: link.condition)
                }
            }

            if activePlans.isEmpty {
                Text("该标的当前没有进行中的计划，无法关联。请先在计划中新建一条。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Divider()
                linkEditor
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One existing link, named by the conditions it lives on.
    ///
    /// A link whose event has since been edited says so here, and the only
    /// action is to write the event as it stands now. That is an explicit
    /// choice by the user: this page never quietly refreshes a snapshot, which
    /// would erase the difference between what was reasoned about and what the
    /// event says today.
    private func linkedRow(plan: TradePlan, condition: TradePlanCondition) -> some View {
        let changed = condition.eventReference.map { Self.hasMoved($0, from: entry.event) } ?? false
        return HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(PlanExecutionSheet.stateColor(condition.state))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(condition.title).font(.system(size: 11.5, weight: .medium))
                    Text(PulseLocalization.localizedString("plan.condition.kind.\(condition.kind.rawValue)"))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(PulseLocalization.localizedString("plan.condition.state.\(condition.state.rawValue)"))
                        .font(.system(size: 9)).foregroundStyle(PlanExecutionSheet.stateColor(condition.state))
                    Spacer(minLength: 4)
                }
                Text(planSummary(plan))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if changed {
                    Text("条件中记录的事件已与本事件不同（标题、日期或类型），待核对。")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button("打开计划") {
                linkedPlanDetail = plan
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private func planSummary(_ plan: TradePlan) -> String {
        let side = PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell")
        return "\(side) · \(PriceFormatter.price(plan.price, market: entry.symbol.market)) × \(PriceFormatter.quantity(plan.quantity))"
    }

    // MARK: - Link editor

    @ViewBuilder private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关联到计划条件")
                .font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                Picker("计划", selection: $selectedPlanID) {
                    Text("选择计划").tag(nil as UUID?)
                    ForEach(activePlans) { plan in
                        Text(planSummary(plan)).tag(Optional(plan.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer(minLength: 0)
            }

            if let plan = selectedPlan {
                let conditions = plan.conditions ?? []
                HStack(spacing: 8) {
                    Picker("条件", selection: $selectedConditionID) {
                        ForEach(conditions) { condition in
                            Text("\(condition.title) · \(PulseLocalization.localizedString("plan.condition.state.\(condition.state.rawValue)"))")
                                .tag(Optional(condition.id))
                        }
                        Text("新建事件条件").tag(nil as UUID?)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: selectedConditionID) { _, value in
                        statusMessage = nil
                        errorMessage = nil
                    }
                    Spacer(minLength: 0)
                }
                if selectedConditionID == nil {
                    TextField("新条件的名称", text: $newConditionTitle)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button("保存关联", action: saveLink)
                        .controlSize(.small)
                        .disabled(!canSaveLink)
                    Text("关联后条件状态标为“待复核”，不会自动确认，也不会产生成交。")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var canSaveLink: Bool {
        guard let plan = selectedPlan else { return false }
        if selectedConditionID == nil {
            return !newConditionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return selectedConditionID != nil
    }

    /// Writes this event into the chosen condition and marks it `needsReview`.
    ///
    /// The plan is re-read from the store at this moment and only the one
    /// condition changes, so every other field — funding intention, pool,
    /// price, quantity, and the rest of the conditions — is carried over
    /// untouched. The store decides whether that counts as a change and
    /// whether a revision is recorded; this code never assumes either.
    private func saveLink() {
        // The plan id alone does not authorize this write: an account switch
        // swaps the whole ledger behind the same store object, and a plan that
        // exists in the new account too would otherwise take a copy of this
        // event recorded for the old one.
        guard appState.watchlist.activeBrokerageAccountID == account else {
            errorMessage = "当前账号已切换，关联不会写入其他账号。请关闭后重新打开。"
            statusMessage = nil
            return
        }
        guard let symbol = appState.watchlist.item(for: entry.symbol)?.symbol,
              let selectedPlanID,
              var plan = appState.watchlist.item(for: symbol)?.plans.first(where: { $0.id == selectedPlanID }),
              activePlans.contains(where: { $0.id == plan.id }) else {
            errorMessage = "找不到这条计划，可能已被删除。请重新选择。"
            statusMessage = nil
            return
        }
        var conditions = plan.conditions ?? []
        let linkage: (title: String, note: String)?
        if let selectedConditionID {
            guard let index = conditions.firstIndex(where: { $0.id == selectedConditionID }) else {
                errorMessage = "这条条件已被删除，请重新选择。"
                statusMessage = nil
                return
            }
            conditions[index].eventReference = entry.event
            conditions[index].state = .needsReview
            linkage = (conditions[index].title, "已关联事件，待核对。")
        } else {
            let title = newConditionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 240 else {
                errorMessage = "请填写不超过 240 个字的条件名称。"
                statusMessage = nil
                return
            }
            conditions.append(TradePlanCondition(
                title: title, kind: .event, state: .needsReview, eventReference: entry.event
            ))
            linkage = (title, "已新建事件条件并关联，待核对。")
        }
        guard let linkage else { return }
        plan.conditions = conditions
        guard appState.watchlist.setTradePlan(plan, for: symbol) else {
            errorMessage = "关联保存失败，请重试。"
            statusMessage = nil
            return
        }
        // Confirm against the store rather than the copy that was submitted: a
        // refused write leaves the old plan in place, and reporting success
        // over it would tell the user a link exists that does not.
        let persisted = appState.watchlist.item(for: symbol)?
            .plans.first { $0.id == selectedPlanID }?
            .conditions?.contains { $0.eventReference?.id == entry.event.id && $0.title == linkage.title } ?? false
        guard persisted else {
            errorMessage = "关联未保存，请重试。"
            statusMessage = nil
            return
        }
        statusMessage = "“\(linkage.title)”\(linkage.note)"
        errorMessage = nil
        newConditionTitle = ""
        selectedConditionID = nil
    }

    private func primeSelection() {
        guard selectedPlanID == nil, let first = activePlans.first else { return }
        selectedPlanID = first.id
    }

    // MARK: - Formatting

    private var eventPeriod: String {
        guard let end = entry.event.endDate else { return dateTitle(entry.event.date) }
        return "\(dateTitle(entry.event.date)) — \(dateTitle(end))"
    }

    private func dateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = EastmoneyTradingEvents.dateCalendar
        formatter.timeZone = EastmoneyTradingEvents.dateCalendar.timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private var kindTitle: String {
        switch entry.event.kind {
        case .earnings: "财报"
        case .dividend: "分红"
        case .unlock: "解禁"
        case .other: "其他"
        }
    }

    /// The four fields the store treats as the event's identity when deciding
    /// whether a link has moved. `updatedAt`, `note`, and `sourceURL` are left
    /// out on purpose: annotating an event must not reopen a settled link.
    private static func hasMoved(_ reference: InstrumentEvent, from current: InstrumentEvent) -> Bool {
        reference.kind != current.kind
            || reference.date != current.date
            || reference.endDate != current.endDate
            || reference.title != current.title
    }
}

private struct TradingEventEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let items: [WatchItem]
    let existing: InstrumentEvent?
    /// The account this draft belongs to, frozen when it was built. It is named
    /// in the header and required at save, so a draft typed for one account's
    /// instrument cannot land in another account's entry of the same symbol.
    @State var account: BrokerageAccountID

    @State private var symbol: SymbolID
    @State private var kind: InstrumentEvent.Kind
    @State private var date: Date
    @State private var isRange: Bool
    @State private var endDate: Date
    @State private var title: String
    @State private var sourceURL: String
    @State private var note: String
    @State private var error: String?

    init(
        items: [WatchItem],
        initialSymbol: SymbolID,
        event: InstrumentEvent?,
        initialDate: Date = .now,
        account: BrokerageAccountID
    ) {
        self.items = items
        self.existing = event
        self._account = State(initialValue: account)
        _symbol = State(initialValue: items.contains(where: { $0.symbol == initialSymbol }) ? initialSymbol : (items.first?.symbol ?? initialSymbol))
        _kind = State(initialValue: event?.kind ?? .other)
        _date = State(initialValue: event?.date ?? initialDate)
        _isRange = State(initialValue: event?.endDate != nil)
        _endDate = State(initialValue: event?.endDate ?? event?.date ?? initialDate)
        _title = State(initialValue: event?.title ?? "")
        _sourceURL = State(initialValue: event?.sourceURL ?? "")
        _note = State(initialValue: event?.note ?? "")
    }

    /// Whether the store is still pointed at the ledger this draft was built
    /// against. A symbol and an event id travel with the form, but neither
    /// authorizes a write.
    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == account
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existing == nil ? "添加日历事件" : "编辑日历事件").font(.title2.weight(.semibold))
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(items.isEmpty || !accountMatchesDraft)
            }
            .padding()
            // The account this event is written into. It turns orange once the
            // ledger underneath has changed, matching the refusal at save.
            HStack(spacing: 5) {
                Circle().fill(AccountIdentity.dotColor(account)).frame(width: 5, height: 5)
                Text("事件记入：\(AccountIdentity.title(account))")
                    .font(.caption)
                    .foregroundStyle(accountMatchesDraft
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
            Form {
                Picker("标的", selection: $symbol) {
                    ForEach(items) { item in
                        Text("\(item.symbol.displayCode) · \(item.resolvedDisplayName)").tag(item.symbol)
                    }
                }
                .disabled(existing != nil)
                Picker("类型", selection: $kind) {
                    Text("财报").tag(InstrumentEvent.Kind.earnings)
                    Text("分红").tag(InstrumentEvent.Kind.dividend)
                    Text("解禁").tag(InstrumentEvent.Kind.unlock)
                    Text("其他").tag(InstrumentEvent.Kind.other)
                }
                DatePicker("日期（北京时间）", selection: $date, displayedComponents: .date)
                    .environment(\.timeZone, EastmoneyTradingEvents.dateCalendar.timeZone)
                    .environment(\.calendar, EastmoneyTradingEvents.dateCalendar)
                Toggle("持续多天", isOn: $isRange)
                if isRange {
                    DatePicker("结束日期", selection: $endDate, displayedComponents: .date)
                        .environment(\.timeZone, EastmoneyTradingEvents.dateCalendar.timeZone)
                        .environment(\.calendar, EastmoneyTradingEvents.dateCalendar)
                }
                TextField("标题", text: $title)
                TextField("来源链接（可选）", text: $sourceURL)
                TextField("备注（可选）", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
        }
        .frame(minWidth: 460, minHeight: 500)
    }

    private func save() {
        guard accountMatchesDraft else {
            error = "当前账号已切换，事件不会写入其他账号。请重新打开后再保存。"
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 120 else {
            error = "请填写不超过 120 个字的标题。"
            return
        }
        guard cleanNote.count <= 1_000 else {
            error = "备注不能超过 1000 个字。"
            return
        }
        let calendar = EastmoneyTradingEvents.dateCalendar
        let start = calendar.startOfDay(for: date)
        let end = isRange ? calendar.startOfDay(for: endDate) : nil
        guard end.map({ $0 >= start }) ?? true else {
            error = "结束日期不能早于开始日期。"
            return
        }
        if !cleanURL.isEmpty {
            guard let components = URLComponents(string: cleanURL),
                  let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  let host = components.host, !host.isEmpty, components.url != nil,
                  components.port.map({ (1...65_535).contains($0) }) ?? true else {
                error = "来源链接需要是有效的 HTTP 或 HTTPS 地址。"
                return
            }
        }
        let event = InstrumentEvent(
            id: existing?.id ?? UUID(), kind: kind,
            date: start, title: cleanTitle, endDate: end,
            sourceURL: cleanURL.isEmpty ? nil : cleanURL,
            note: cleanNote.isEmpty ? nil : cleanNote,
            updatedAt: .now
        )
        guard appState.watchlist.setInstrumentEvent(event, for: symbol) else {
            error = "事件保存失败，请重试。"
            return
        }
        dismiss()
    }
}
