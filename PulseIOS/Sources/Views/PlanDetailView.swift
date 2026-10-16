import SwiftUI
import PulseCore
import PulseUI

// MARK: - Plan detail

struct PlanDetailView: View {
    /// The symbol is a hint from the caller. When a deep link supplies only the
    /// plan id this is the unresolved marker, and the real symbol is resolved
    /// from the live plan list — never guessed from the URL.
    let symbol: SymbolID
    let planID: UUID

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workbenchPresentTradeEntry) private var presentTradeEntry

    @State private var editorTarget: PlanEditorTarget?
    @State private var confirmTransition: PlanTransitionAction?
    @State private var isConfirmingDeletion = false
    /// The ledger this detail screen was opened against. Confirming a condition
    /// writes the plan back to it, so a global account switch cannot move the
    /// write into another book.
    @State private var frozenAccount: BrokerageAccountID = .unassigned

    /// The live entry, found by plan id. The id is the identity; the caller's
    /// symbol only disambiguates in the impossible case of a shared id.
    private var entry: TradePlanEntry? {
        let matches = state.planEntries.filter { $0.plan.id == planID }
        if matches.count <= 1 { return matches.first }
        return matches.first { $0.symbol == symbol } ?? matches.first
    }

    /// Where the plan actually lives. Falls back to the caller's hint for the
    /// not-found case so the title is still meaningful.
    private var resolvedSymbol: SymbolID { entry?.symbol ?? symbol }

    var body: some View {
        ScrollView {
            if let entry {
                content(entry)
            } else {
                WorkbenchEmptyState(
                    icon: "questionmark.folder",
                    title: "找不到这项计划",
                    message: "它可能已经被删除，或属于另一个账户。列表已刷新，不会显示替代记录。"
                )
                .padding(.top, 40)
            }
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .navigationTitle(state.displayName(resolvedSymbol))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let entry {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editorTarget = .edit(entry, account: entry.accountID ?? frozenAccount) } label: { Label("编辑意图", systemImage: "pencil") }
                        if entry.displayState == .waiting {
                            Button { confirmTransition = .stop } label: { Label("停止", systemImage: "pause.circle") }
                            Button { confirmTransition = .abandon } label: { Label("放弃", systemImage: "xmark.circle") }
                        } else if entry.displayState != .filled {
                            Button { confirmTransition = .revive } label: { Label("恢复", systemImage: "arrow.uturn.backward.circle") }
                        }
                        Divider()
                        Button(role: .destructive) { isConfirmingDeletion = true } label: {
                            Label("删除计划", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { frozenAccount = state.accountID }
        .sheet(item: $editorTarget) { target in
            PlanEditorView(target: target)
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
                apply(action)
                confirmTransition = nil
            }
            Button("取消", role: .cancel) { confirmTransition = nil }
        } message: { action in
            Text(action.confirmationMessage)
        }
        .confirmationDialog(
            "删除这项计划？",
            isPresented: $isConfirmingDeletion
        ) {
            Button("删除计划", role: .destructive) { delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已记录的成交事实会保留，只有计划本身被删除。如果只是想不再等待，请改用「停止」或「放弃」。")
        }
    }

    @ViewBuilder
    private func content(_ entry: TradePlanEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCard(entry)
            conditionSection(entry)
            executionSection(entry)
            historySection(entry)
            actionButtons(entry)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    // MARK: Summary

    private func summaryCard(_ entry: TradePlanEntry) -> some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    WorkbenchTag(
                        text: entry.plan.kind == .buy ? "买入计划" : "卖出计划",
                        color: entry.plan.kind == .buy ? WorkbenchTheme.blue : WorkbenchTheme.down
                    )
                    Spacer(minLength: 6)
                    Text(PlanStatusText.label(for: entry.displayState))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PlanStatusText.color(for: entry.displayState))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("目标 \(entry.plan.kind == .buy ? "≤" : "≥") \(WorkbenchFormat.price(entry.plan.price, market: entry.symbol.market))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text("\(WorkbenchFormat.quantity(entry.plan.quantity)) 股")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let price = state.freshPrice(entry.symbol) {
                    let reached = entry.plan.isReached(at: price)
                    HStack(spacing: 8) {
                        Text("现价 \(WorkbenchFormat.price(price, market: entry.symbol.market))")
                        Text(reached ? "条件已到达" : "距目标 \(PriceFormatter.percent(entry.plan.gapPercent(from: price)))")
                            .foregroundStyle(reached ? WorkbenchTheme.warning : .secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("暂无可用行情，价格条件状态未知。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                FactRow(name: "计划账户", value: state.accountName(entry.accountID ?? .unassigned))
                FactRow(
                    name: "执行账户意向",
                    value: entry.plan.executionAccountID.map(state.accountName) ?? "未指定（记成交时选择）"
                )
                FactRow(name: "资金方式", value: PlanStatusText.label(for: entry.plan.fundingSource))
                FactRow(name: "持仓池", value: PlanStatusText.label(for: entry.plan.positionPool ?? .unassigned))
                if let note = entry.plan.note, !note.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("备注").font(.caption).foregroundStyle(.secondary)
                        Text(note).font(.subheadline)
                    }
                }
            }
        }
    }

    // MARK: Conditions

    private func conditionSection(_ entry: TradePlanEntry) -> some View {
        let conditions = entry.plan.conditions ?? []
        return WorkbenchSection(title: "手工条件") {
            WorkbenchCard(padding: 12) {
                if conditions.isEmpty {
                    Text("这项计划没有记录条件。系统不会替你判断该不该执行。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(conditions) { condition in
                            ConditionRow(condition: condition) {
                                confirm(condition, in: entry)
                            }
                            if condition.id != conditions.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    /// Confirming a manual condition is a user act, always. The system never
    /// ticks one off from a quote.
    private func confirm(_ condition: TradePlanCondition, in entry: TradePlanEntry) {
        var plan = entry.plan
        guard var conditions = plan.conditions,
              let index = conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        conditions[index].state = .confirmed
        conditions[index].reviewDate = nil
        plan.conditions = conditions
        do {
            try state.savePlan(plan, symbol: entry.symbol, expected: entry.plan, account: entry.accountID ?? frozenAccount)
        } catch let error as LocalizedError {
            state.errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    // MARK: Execution

    private func executionSection(_ entry: TradePlanEntry) -> some View {
        let fills = state.watchlist.transactionsForPlan(
            entry.symbol,
            account: entry.accountID,
            planID: entry.plan.id
        )
        return WorkbenchSection(title: "实际执行") {
            WorkbenchCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        StatCell(
                            label: "已记数量",
                            value: WorkbenchFormat.quantity(entry.filledQuantity),
                            detail: "计划 \(WorkbenchFormat.quantity(entry.plan.quantity))"
                        )
                        StatCell(
                            label: "剩余",
                            value: WorkbenchFormat.quantity(entry.remainingQuantity)
                        )
                        StatCell(
                            label: "成交均价",
                            value: WorkbenchFormat.price(entry.averageFillPrice, market: entry.symbol.market),
                            detail: entry.lastFillDate.map { WorkbenchFormat.day($0) }
                        )
                    }

                    Text("执行进度由关联成交推导，不是一个开关。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if !fills.isEmpty {
                        Divider()
                        VStack(spacing: 0) {
                            ForEach(fills) { transaction in
                                FillRow(
                                    transaction: transaction,
                                    symbol: symbol,
                                    account: entry.accountID ?? frozenAccount
                                )
                                if transaction.id != fills.last?.id { Divider() }
                            }
                        }
                    }

                    if entry.displayState == .waiting {
                        Button {
                            presentTradeEntry(.fromPlan(entry, backfill: false))
                        } label: {
                            Label("记一笔成交", systemImage: "square.and.pencil")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 40)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if entry.canBackfillFill {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                presentTradeEntry(.fromPlan(entry, backfill: true))
                            } label: {
                                Label("补录已完成但漏记的成交", systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 40)
                            }
                            .buttonStyle(.bordered)
                            Text("计划已经停止但成交漏记时走这条路：不会为了写一条历史事实先假装恢复计划。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: History

    private func historySection(_ entry: TradePlanEntry) -> some View {
        let revisions = (entry.plan.history ?? []).reversed()
        return WorkbenchSection(title: "变更历史") {
            WorkbenchCard(padding: 12) {
                if revisions.isEmpty {
                    Text("这项计划还没有修改记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(revisions)) { revision in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(revision.configuration.kind == .buy ? "买入" : "卖出") \(WorkbenchFormat.price(revision.configuration.price, market: entry.symbol.market)) × \(WorkbenchFormat.quantity(revision.configuration.quantity)) 股")
                                        .font(.subheadline.weight(.medium))
                                    Text(PlanStatusText.label(for: revision.configuration.status))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text(WorkbenchFormat.day(revision.date))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 40)
                            if revision.id != revisions.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    private func actionButtons(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 10) {
            Button("编辑意图") { editorTarget = .edit(entry, account: entry.accountID ?? frozenAccount) }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 42)
                .buttonStyle(.bordered)

            if entry.displayState == .waiting {
                Button("停止") { confirmTransition = .stop }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 42)
                    .buttonStyle(.bordered)
            } else if entry.displayState != .filled {
                Button("恢复") { confirmTransition = .revive }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 42)
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Mutations

    private func apply(_ action: PlanTransitionAction) {
        guard let entry else { return }
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

    private func delete() {
        guard let entry else { return }
        do {
            try state.deletePlan(entry)
        } catch let error as LocalizedError {
            state.errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Condition row

struct ConditionRow: View {
    let condition: TradePlanCondition
    let onConfirm: () -> Void

    @Environment(IPhoneAppState.self) private var state

    private var needsReview: Bool {
        condition.requiresReview(at: .now, currentEvents: [])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: condition.state == .confirmed && !needsReview ? "checkmark.circle.fill" : "circle")
                .font(.subheadline)
                .foregroundStyle(condition.state == .confirmed && !needsReview ? WorkbenchTheme.down : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(condition.title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    WorkbenchTag(text: PlanStatusText.label(for: condition.kind))
                    Text(PlanStatusText.label(for: condition.state))
                        .font(.caption2)
                        .foregroundStyle(needsReview ? WorkbenchTheme.warning : .secondary)
                }
                if let note = condition.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            if condition.state != .confirmed || needsReview {
                Button("确认", action: onConfirm)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }
}

// MARK: - Fill row

struct FillRow: View {
    let transaction: PositionTransaction
    let symbol: SymbolID
    let account: BrokerageAccountID

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(transaction.kind == .buy ? "买入" : (transaction.kind == .sell ? "卖出" : "校准"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(transaction.kind == .buy ? WorkbenchTheme.up : WorkbenchTheme.down)
                    Text(WorkbenchFormat.price(transaction.price, market: symbol.market))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    Text("× \(WorkbenchFormat.quantity(transaction.quantity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let fee = transaction.fee, fee > 0 {
                    Text("费用 \(WorkbenchFormat.money(fee, currencyCode: symbol.currencyCode))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(WorkbenchFormat.day(transaction.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(PlanStatusText.label(for: transaction.fundingSource))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 42)
        .padding(.vertical, 2)
    }
}
