import SwiftUI
import PulseCore
import PulseUI

// MARK: - Plans list

struct PlansView: View {
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry

    @State private var filter: PlanFilter = .active
    @State private var editorTarget: PlanEditorTarget?
    @State private var newPlanContext: PlanCreationContext?
    @State private var entryPendingDeletion: TradePlanEntry?

    enum PlanFilter: String, CaseIterable, Identifiable {
        case active, settled, abandoned
        var id: String { rawValue }
        var label: String {
            switch self {
            case .active: "进行中"
            case .settled: "已结算"
            case .abandoned: "已放弃"
            }
        }
    }

    private var allEntries: [TradePlanEntry] { state.planEntries }

    private var filtered: [TradePlanEntry] {
        allEntries.filter { entry in
            switch filter {
            case .active: entry.displayState == .waiting
            case .settled: entry.displayState == .filled || entry.displayState == .stopped
            case .abandoned: entry.displayState == .abandoned
            }
        }
    }

    private var summary: TradePlanOverview.Summary {
        TradePlanOverview.summary(allEntries, currentPrice: { state.freshPrice($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkbenchHeader(title: "计划")

                ActiveAccountStrip(
                    title: "计划账户：\(state.accountName(state.accountID))"
                )

                newPlanSection
                filterBar

                if filtered.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(filtered) { entry in
                            PlanCard(
                                entry: entry,
                                onOpen: {
                                    onOpenRoute?(WorkbenchRoute(
                                        destination: .plan(entry.plan.id, entry.symbol),
                                        tab: WorkbenchRoute.planTab
                                    ))
                                },
                                onEdit: { editorTarget = .edit(entry, account: entry.accountID ?? state.accountID) },
                                onRecordFill: { presentTradeEntry(.fromPlan(entry, backfill: entry.canBackfillFill)) },
                                onTransition: { apply($0, to: entry) },
                                onDelete: { entryPendingDeletion = entry }
                            )
                        }
                    }
                }

                footer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editorTarget) { target in
            PlanEditorView(target: target)
        }
        .sheet(item: $newPlanContext) { context in
            NewTradePlanPhoneSheet(account: context.account)
        }
        .confirmationDialog(
            "删除计划",
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            presenting: entryPendingDeletion
        ) { entry in
            Button("删除这项计划", role: .destructive) {
                delete(entry)
            }
            Button("取消", role: .cancel) { entryPendingDeletion = nil }
        } message: { entry in
            Text(deletionMessage(entry))
        }
    }

    private func deletionMessage(_ entry: TradePlanEntry) -> String {
        var parts = ["删除后这项计划不再出现在任何设备上。"]
        if entry.filledQuantity > 0 {
            parts.append("它已经关联 \(WorkbenchFormat.quantity(entry.filledQuantity)) 股的成交记录；这些成交事实会保留，不会被删除。")
        }
        parts.append("如果只是想不再等待，请改用「停止」或「放弃」。")
        return parts.joined(separator: " ")
    }

    // MARK: Filter bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(PlanFilter.allCases) { option in
                let count = count(for: option)
                let isSelected = option == filter
                Button {
                    filter = option
                } label: {
                    HStack(spacing: 4) {
                        Text(option.label)
                        Text("\(count)")
                            .font(.caption2.weight(.semibold))
                            .opacity(0.75)
                    }
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? WorkbenchTheme.blue : .secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(isSelected ? WorkbenchTheme.blue.opacity(0.12) : WorkbenchTheme.chipBackground(colorScheme))
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func count(for option: PlanFilter) -> Int {
        switch option {
        case .active: summary.live
        case .settled: allEntries.filter { $0.displayState == .filled || $0.displayState == .stopped }.count
        case .abandoned: allEntries.filter { $0.displayState == .abandoned }.count
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if allEntries.isEmpty {
            WorkbenchEmptyState(
                icon: "list.bullet.clipboard",
                title: "还没有计划",
                message: "搜索名称或代码即可新建，不需要先加入自选。",
                actionTitle: "新建计划",
                action: { newPlanContext = PlanCreationContext(account: state.accountID) }
            )
        } else {
            WorkbenchEmptyState(
                icon: "checkmark.circle",
                title: "这个分组里没有计划",
                message: "换个筛选条件看看，或新建一项计划。"
            )
        }
    }

    // MARK: New plan

    private var newPlanSection: some View {
        Button { newPlanContext = PlanCreationContext(account: state.accountID) } label: {
            Label(PulseLocalization.localizedString("plan.newPlan"), systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
        }.buttonStyle(.bordered).accessibilityIdentifier("plan.new")
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text("价格到达只提醒；执行进度由真实成交记录计算。手工条件由你自己复核，系统不会自动勾选。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    // MARK: Mutations

    private func apply(_ action: PlanTransitionAction, to entry: TradePlanEntry) {
        // The store's checked boundary takes the entry and the target status;
        // it re-reads the stored plan and refuses a stale row.
        let status: TradePlan.Status
        switch action {
        case .stop: status = .done
        case .abandon: status = .cancelled
        case .revive: status = .active
        }
        do {
            try state.transitionPlan(entry, to: status)
        } catch let error as LocalizedError {
            state.errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func delete(_ entry: TradePlanEntry) {
        do {
            try state.deletePlan(entry)
            entryPendingDeletion = nil
        } catch let error as LocalizedError {
            state.errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - New-plan symbol chooser

/// Mirrors the Mac PlanSymbolChooser: local watched items first, remote search
/// for anything else (280ms debounce), any position-supporting symbol allowed.
/// Picking a symbol opens the plan editor; it does not add it to the watchlist.
struct NewPlanSymbolChooser: View {
    let onSelect: (SymbolInfo) -> Void
    var account: BrokerageAccountID? = nil

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var remoteResults: [SymbolInfo] = []
    @State private var remoteQuery = ""
    @State private var searchError: String?
    @State private var isSearching = false
    @State private var retryToken = 0

    private var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var rows: [SymbolInfo] {
        let needle = normalizedQuery
        var seen = Set<SymbolID>()
        let local = state.watchlist.items.filter { item in
            item.supportsPosition && (needle.isEmpty
                || item.resolvedDisplayName.localizedCaseInsensitiveContains(needle)
                || item.symbol.displayCode.localizedCaseInsensitiveContains(needle))
        }.map { item in
            SymbolInfo(symbol: item.symbol, name: item.resolvedDisplayName,
                       type: item.resolvedInstrumentType ?? .equity,
                       displayNameSource: item.displayNameSource)
        }
        let remote = !needle.isEmpty && remoteQuery == needle ? remoteResults : []
        return (local + remote).filter { info in
            WatchItem(symbol: info.symbol, displayName: info.name,
                      instrumentType: info.type).supportsPosition && seen.insert(info.symbol).inserted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(PulseLocalization.localizedString("main.search.placeholder"), text: $query)
                    .accessibilityIdentifier("plan.search")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if isSearching { ProgressView().controlSize(.small) }
            }
            .font(.subheadline)
            .padding(9)
            .background(WorkbenchTheme.chipBackground(colorScheme), in: RoundedRectangle(cornerRadius: 8))

            if rows.isEmpty {
                Text(normalizedQuery.isEmpty ? "输入名称或代码；也可以从下方已关注的标的直接选。" : "没有匹配的标的。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.symbol) { index, info in
                        if index > 0 { Divider() }
                        Button { onSelect(info) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle").foregroundStyle(WorkbenchTheme.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.resolvedDisplayName).font(.subheadline).foregroundStyle(.primary)
                                    Text("\(info.symbol.displayCode) · \(info.symbol.market.rawValue.uppercased())")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(account.map { $0 != state.accountID } ?? false)
                        .accessibilityIdentifier("plan.choose.\(info.symbol.description)")
                    }
                }
            }
            if let searchError {
                HStack(spacing: 8) {
                    Text("搜索暂不可用：\(searchError)").foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("重试") { retryToken += 1 }
                }
                .font(.caption)
            }
        }
        .task(id: normalizedQuery + "#\(retryToken)") { await search() }
    }

    private func search() async {
        let needle = normalizedQuery
        remoteResults = []
        remoteQuery = ""
        searchError = nil
        isSearching = !needle.isEmpty
        guard !needle.isEmpty else { return }
        defer { if !Task.isCancelled, needle == normalizedQuery { isSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(280))
            try Task.checkCancellation()
            let results = try await state.search(needle)
            try Task.checkCancellation()
            guard needle == normalizedQuery else { return }
            remoteResults = results
            remoteQuery = needle
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, needle == normalizedQuery else { return }
            searchError = error.localizedDescription
        }
    }
}

// MARK: - Transition actions

enum PlanTransitionAction: Hashable, Identifiable {
    case stop, abandon, revive
    var id: Self { self }

    var label: String {
        switch self {
        case .stop: "停止"
        case .abandon: "放弃"
        case .revive: "恢复"
        }
    }

    var icon: String {
        switch self {
        case .stop: "pause.circle"
        case .abandon: "xmark.circle"
        case .revive: "arrow.uturn.backward.circle"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .stop: "停止这项计划？"
        case .abandon: "放弃这项计划？"
        case .revive: "恢复这项计划？"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .stop: "停止只是不再等待价格。它不会生成任何成交，持仓和数量都不会因此改变。已记录的成交事实保留。"
        case .abandon: "放弃表示你不再打算执行它。同样不会生成成交，已记录的成交事实保留。"
        case .revive: "恢复后会重新按价格条件评估，但不会追认任何过去的成交。"
        }
    }
}

// MARK: - Plan card

struct PlanCard: View {
    let entry: TradePlanEntry
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onRecordFill: () -> Void
    let onTransition: (PlanTransitionAction) -> Void
    let onDelete: () -> Void

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    @State private var confirmTransition: PlanTransitionAction?

    private var reached: Bool {
        TradePlanOverview.isReached(entry, currentPrice: { state.freshPrice($0) })
    }

    private var progress: Double {
        guard entry.plan.quantity > 0 else { return 0 }
        return min(1, max(0, entry.filledQuantity / entry.plan.quantity))
    }

    private var isWaiting: Bool { entry.displayState == .waiting }

    var body: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 9) {
                header
                title
                conditionLine
                progressBlock
                if let badge = conditionBadge {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist")
                        Text(badge)
                    }
                    .font(.caption2)
                    .foregroundStyle(WorkbenchTheme.warning)
                }
                actionRow
            }
        }
        .confirmationDialog(
            confirmTransition?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { confirmTransition != nil },
                set: { if !$0 { confirmTransition = nil } }
            ),
            presenting: confirmTransition
        ) { action in
            Button(action.label, role: action == .abandon ? .destructive : nil) {
                onTransition(action)
                confirmTransition = nil
            }
            Button("取消", role: .cancel) { confirmTransition = nil }
        } message: { action in
            Text(action.confirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            WorkbenchTag(
                text: entry.plan.kind == .buy ? "买入计划" : "卖出计划",
                color: entry.plan.kind == .buy ? WorkbenchTheme.blue : WorkbenchTheme.down
            )
            Spacer(minLength: 6)
            if isWaiting {
                Text(reached ? "价格条件到达" : waitingLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(reached ? WorkbenchTheme.warning : .secondary)
            } else {
                Text(PlanStatusText.label(for: entry.displayState))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(PlanStatusText.color(for: entry.displayState))
            }
        }
    }

    private var title: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(state.displayName(entry.symbol))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let note = entry.plan.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var waitingLabel: String {
        guard let price = state.freshPrice(entry.symbol) else { return "暂无行情" }
        return "距目标 \(PriceFormatter.percent(entry.plan.gapPercent(from: price)))"
    }

    private var conditionLine: some View {
        HStack {
            Text("目标 \(entry.plan.kind == .buy ? "≤" : "≥") \(WorkbenchFormat.price(entry.plan.price, market: entry.symbol.market))")
            Spacer(minLength: 6)
            Text("计划 \(WorkbenchFormat.quantity(entry.plan.quantity)) 股")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("已记成交 \(WorkbenchFormat.quantity(entry.filledQuantity)) / \(WorkbenchFormat.quantity(entry.plan.quantity)) 股")
                Spacer(minLength: 6)
                if let average = entry.averageFillPrice {
                    Text("均价 \(WorkbenchFormat.price(average, market: entry.symbol.market))")
                } else {
                    Text("尚无成交价")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(WorkbenchTheme.blue.opacity(0.12))
                    Capsule().fill(WorkbenchTheme.blue).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 4)
        }
    }

    private var conditionBadge: String? {
        guard let badge = PositionVerificationBadge.derived(
            from: entry.plan.conditions,
            at: .now,
            currentEvents: state.watchlist.item(for: entry.symbol)?.events ?? []
        ) else { return nil }
        switch badge {
        case .pending: return "手工条件待复核"
        case .needsReview: return "条件需要重新确认"
        case .invalidated: return "条件已作废"
        case .confirmed: return nil
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("详情 / 编辑", action: onOpen)
                .font(.caption.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(WorkbenchTheme.blue)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(WorkbenchTheme.blue.opacity(0.08), in: Capsule())

            if entry.displayState == .waiting || entry.canBackfillFill {
                Button(entry.canBackfillFill ? "补记成交" : "记成交", action: onRecordFill)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(WorkbenchTheme.blue, in: Capsule())
            }

            Spacer(minLength: 0)

            Menu {
                Button { onEdit() } label: { Label("编辑意图", systemImage: "pencil") }
                if isWaiting {
                    Button { confirmTransition = .stop } label: { Label("停止计划", systemImage: "pause.circle") }
                    Button { confirmTransition = .abandon } label: { Label("放弃计划", systemImage: "xmark.circle") }
                } else if entry.displayState != .filled {
                    Button { confirmTransition = .revive } label: { Label("恢复计划", systemImage: "arrow.uturn.backward.circle") }
                }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Label("删除计划", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(WorkbenchTheme.blue)
                    .frame(width: 32, height: 30)
            }
        }
        .padding(.top, 2)
    }
}
