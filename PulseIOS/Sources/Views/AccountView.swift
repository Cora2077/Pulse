import SwiftUI
import PulseCore
import PulseUI

// MARK: - Account
//
// The user's own book, in three views: holdings, flows, reviews. Every figure
// comes from the account-scoped ledger. Currencies are never summed without a
// rate, and a missing price is an em dash.
struct AccountView: View {
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    @State private var section: AccountSection = .holdings
    @State private var pendingSwitch: BrokerageAccountID?
    @State private var isPresentingCashEditor = false
    // Viewport state only: scrolling the chooser never switches the ledger.
    @State private var visibleAccount: BrokerageAccountID?

    enum AccountSection: String, CaseIterable, Identifiable {
        case holdings, flows, reviews
        var id: String { rawValue }
        var label: String {
            switch self {
            case .holdings: "持仓"
            case .flows: "流水"
            case .reviews: "复盘"
            }
        }
    }

    private var items: [WatchItem] {
        let portfolio = state.watchlist.brokeragePortfolio(for: state.accountID)
        var seen: Set<SymbolID> = []
        return (portfolio.items + portfolio.retainedHistoryItems).filter { seen.insert($0.symbol).inserted }
    }
    private var positionItems: [WatchItem] {
        items.filter { $0.supportsPosition && $0.hasPositionHistory }
    }
    private var valuation: AccountValuation {
        AccountValuation(items: positionItems) { state.quote($0) }
    }
    private var cash: AccountCash {
        AccountCash(settings: state.watchlist.brokerageSettings(for: state.accountID))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkbenchHeader(title: "账户")

                accountSwitcher

                if state.accountID == .unassigned {
                    unassignedNotice
                }

                sectionPicker

                switch section {
                case .holdings: holdingsSection
                case .flows: FlowsSection(symbol: nil, onOpenRoute: onOpenRoute).id(state.accountID)
                case .reviews: ReviewsSection(onOpenRoute: onOpenRoute).id(state.accountID)
                }

                cashSection
                settingsEntry
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(WorkbenchTheme.pageBackground(colorScheme))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: state.requestedAccountSection, initial: true) { _, value in
            guard let value, let requested = AccountSection(rawValue: value) else { return }
            section = requested
            state.requestedAccountSection = nil
        }
        .sheet(isPresented: $isPresentingCashEditor) {
            CashEditorSheet(account: state.accountID)
        }
        .confirmationDialog(
            "切换账户",
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { if !$0 { pendingSwitch = nil } }
            ),
            presenting: pendingSwitch
        ) { account in
            Button("切换到\(state.accountName(account))") {
                state.selectAccount(account)
                pendingSwitch = nil
            }
            Button("取消", role: .cancel) { pendingSwitch = nil }
        } message: { account in
            Text("切换后列表、持仓与计划都只看「\(state.accountName(account))」。已打开的草稿不会改记到新账户；若表单因账户切换被拒绝，请回到原账户继续核对。")
        }
    }

    // MARK: Switcher

    private var accountSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前账户")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BrokerageAccountID.allCases) { account in
                        let isSelected = account == state.accountID
                        Button {
                            guard !isSelected else { return }
                            pendingSwitch = account
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(state.accountName(account))
                                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                Text(accountSummary(account))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(isSelected
                                          ? WorkbenchTheme.blue.opacity(0.12)
                                          : WorkbenchTheme.chipBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(isSelected ? WorkbenchTheme.blue : .clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? WorkbenchTheme.blue : .primary)
                        .accessibilityIdentifier("account.choice.\(account.rawValue)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(account)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollPosition(id: $visibleAccount, anchor: .center)
            .onChange(of: state.accountID, initial: true) { _, account in
                visibleAccount = account
            }
        }
    }

    private func accountSummary(_ account: BrokerageAccountID) -> String {
        let portfolio = state.watchlist.brokeragePortfolio(for: account)
        let positions = (portfolio.items + portfolio.retainedHistoryItems)
            .filter { $0.supportsPosition && $0.hasPositionHistory }.count
        let plans = portfolio.items.reduce(0) { $0 + $1.plans.filter { $0.status == .active }.count }
        return "\(positions) 持仓 · \(plans) 计划"
    }

    private var unassignedNotice: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .foregroundStyle(WorkbenchTheme.warning)
                    Text("「待归属」不是真实账户")
                        .font(.subheadline.weight(.semibold))
                }
                Text("这里的记录还没有确认属于融资账户还是现金账户。可以继续查看，但新买入需要选择明确的账户。归属调整属于账本分类，不是券商转账，请在 Mac 上核对后操作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Section picker

    private var sectionPicker: some View {
        Picker("视图", selection: $section) {
            ForEach(AccountSection.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("account.sections")
    }

    // MARK: Holdings

    @ViewBuilder
    private var holdingsSection: some View {
        if positionItems.isEmpty {
            WorkbenchEmptyState(
                icon: "briefcase",
                title: "这个账户还没有持仓",
                message: "记一笔已完成的买入成交后，这里会按币种显示持仓估值与已实现盈亏。"
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(valuation.lines) { line in
                    currencyCard(line)
                }
                Text("市值与盈亏按每个币种单独计算；缺行情时留空，不按 0 计入。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func currencyCard(_ line: AccountValuation.CurrencyLine) -> some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.currencyCode)
                        .font(.headline)
                    Text(WorkbenchFormat.currencyName(line.currencyCode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if line.hasMissingPrices {
                        WorkbenchTag(text: "部分缺行情", color: WorkbenchTheme.warning)
                    }
                }

                HStack(spacing: 12) {
                    StatCell(
                        label: "市值",
                        value: WorkbenchFormat.money(line.marketValue, currencyCode: line.currencyCode)
                    )
                    StatCell(
                        label: "成本",
                        value: WorkbenchFormat.money(line.cost, currencyCode: line.currencyCode)
                    )
                    StatCell(
                        label: "浮动盈亏",
                        value: WorkbenchFormat.signedMoney(line.holdingPnL, currencyCode: line.currencyCode),
                        tone: (line.holdingPnL ?? 0) > 0 ? WorkbenchTheme.up
                            : ((line.holdingPnL ?? 0) < 0 ? WorkbenchTheme.down : .primary)
                    )
                }

                HStack(spacing: 12) {
                    StatCell(
                        label: "今日盈亏",
                        value: WorkbenchFormat.signedMoney(line.todayPnL, currencyCode: line.currencyCode),
                        tone: (line.todayPnL ?? 0) > 0 ? WorkbenchTheme.up
                            : ((line.todayPnL ?? 0) < 0 ? WorkbenchTheme.down : .primary)
                    )
                    StatCell(
                        label: "已实现盈亏",
                        value: WorkbenchFormat.signedMoney(line.realizedPnL, currencyCode: line.currencyCode),
                        tone: line.realizedPnL > 0 ? WorkbenchTheme.up
                            : (line.realizedPnL < 0 ? WorkbenchTheme.down : .primary)
                    )
                    StatCell(label: "币种", value: line.currencyCode)
                }
            }
        }
    }

    // MARK: Cash

    private var cashSection: some View {
        WorkbenchSection(
            title: "资金",
            actionTitle: "编辑",
            action: { isPresentingCashEditor = true }
        ) {
            WorkbenchCard(padding: 12) {
                if cash.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有记录现金余额。")
                            .font(.subheadline.weight(.medium))
                        Text("现金余额由你自己填写并核对，App 不会从行情或成交推断。各币种分开显示，不合并成单一总额。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(cash.balances, id: \.currency) { balance in
                            FactRow(
                                name: "现金 \(balance.currency)",
                                value: WorkbenchFormat.money(balance.amount, currencyCode: balance.currency),
                                detail: "更新于 \(WorkbenchFormat.dayTime(balance.updatedAt))"
                            )
                            if balance.currency != cash.balances.last?.currency { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: Settings

    private var settingsEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                openSettings()
            } label: {
                HStack {
                    Label("设置与自动关注", systemImage: "gearshape")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            WorkbenchUnavailableRow(
                title: "账户归属调整",
                reason: "把成交或整个账本在账户之间重新归属属于账本分类操作，手机端尚未接入受控入口。请在 Mac 上核对后操作，避免在手机上误改归属。"
            )
            WorkbenchUnavailableRow(
                title: "仓位分账与份额卡",
                reason: "份额拆分、来源卡绑定与对账需要完整的目标池上下文。手机端只读展示池归属，不提供拆分写入。"
            )
        }
    }

    @Environment(\.workbenchOpenSettings) private var openSettings
}

// MARK: - Flows

struct FlowsSection: View {
    var symbol: SymbolID?
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.colorScheme) private var colorScheme

    /// The ledger these rows were read from, captured when the section first
    /// rendered. Every edit, delete and review on this page writes back here, so
    /// a global account switch cannot move the write to another book.
    @State private var frozenAccount: BrokerageAccountID = .unassigned
    @State private var editing: PendingTransactionAction?
    @State private var pendingDeletion: PendingTransactionAction?
    @State private var reviewTarget: ReviewTargetBox?

    private var rows: [(symbol: SymbolID, transaction: PositionTransaction)] {
        let source = symbol.map { [$0] } ?? state.historyItems.map(\.symbol)
        return source.flatMap { symbol in
            (state.watchlist.item(for: symbol)?.transactions ?? [])
                .map { (symbol: symbol, transaction: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.transaction.date != rhs.transaction.date {
                return lhs.transaction.date > rhs.transaction.date
            }
            return lhs.transaction.createdAt > rhs.transaction.createdAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                WorkbenchEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "这个账户还没有成交记录",
                    message: "从「记交易」录入第一笔已经完成的成交，修改和复盘都在这里。"
                )
            } else {
                WorkbenchCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.transaction.id) { index, row in
                            if index > 0 { Divider().padding(.leading, 14) }
                            transactionRow(row.symbol, row.transaction)
                        }
                    }
                }
                Text("流水是账本的事实来源。修改和删除都会先展示影响，并且按原始记录版本校验。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $editing) { pending in
            TradeEntryView(
                context: .editing(pending.transaction, symbol: pending.symbol, account: pending.account),
                onOpenRoute: onOpenRoute
            )
        }
        .task {
            // Freeze once, on first appearance. Re-freezing on every body pass
            // would let a switch mid-flow retarget an open confirmation.
            frozenAccount = state.accountID
        }
        .sheet(item: $reviewTarget) { box in
            ReviewEditorSheet(transaction: box.transaction, symbol: box.symbol, account: box.account)
        }
        .confirmationDialog(
            "删除这笔成交？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { pending in
            Button("删除成交记录", role: .destructive) {
                delete(pending)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { pending in
            Text(deletionMessage(pending.transaction, symbol: pending.symbol))
        }
    }

    /// What deleting this record actually does to the position. Computed from
    /// the real ledger rather than described in the abstract.
    private func deletionMessage(_ transaction: PositionTransaction, symbol: SymbolID) -> String {
        guard let item = state.watchlist.item(for: symbol) else {
            return "这笔记录会从账本中移除。"
        }
        let before = item.positionQuantity
        let remaining = item.transactions.filter { $0.id != transaction.id }
        let after = PositionLedger(transactions: remaining).quantity
        var parts = ["删除后持仓数量从 \(WorkbenchFormat.quantity(before)) 变为 \(WorkbenchFormat.quantity(after))。"]
        parts.append("删除会按共享账本重放规则校验，如果会造成非法持仓，删除会被拒绝而不是半成功。")
        parts.append("如果只是想补充说明，请改用「复盘」。")
        return parts.joined(separator: " ")
    }

    private func delete(_ pending: PendingTransactionAction) {
        do {
            // The frozen account, not whatever is selected now.
            try state.deleteTrade(pending.transaction, symbol: pending.symbol, account: pending.account)
        } catch let error as LocalizedError {
            state.errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func transactionRow(_ symbol: SymbolID, _ transaction: PositionTransaction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transaction.kind == .buy ? "买入" : (transaction.kind == .sell ? "卖出" : "校准"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(transaction.kind == .buy ? WorkbenchTheme.up : WorkbenchTheme.down)
                Text(state.displayName(symbol))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(WorkbenchFormat.day(transaction.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("\(WorkbenchFormat.price(transaction.price, market: symbol.market)) × \(WorkbenchFormat.quantity(transaction.quantity))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let fee = transaction.fee, fee > 0 {
                    Text("费用 \(WorkbenchFormat.money(fee, currencyCode: symbol.currencyCode))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if transaction.planExecution != nil {
                    WorkbenchTag(text: "关联计划")
                }
                Spacer(minLength: 0)
            }

            if let note = transaction.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button("修改") {
                    editing = PendingTransactionAction(transaction: transaction, symbol: symbol, account: frozenAccount)
                }
                .font(.caption.weight(.medium))
                Button("复盘") {
                    reviewTarget = ReviewTargetBox(transaction: transaction, symbol: symbol, account: frozenAccount)
                }
                .font(.caption.weight(.medium))
                Button("删除", role: .destructive) {
                    pendingDeletion = PendingTransactionAction(transaction: transaction, symbol: symbol, account: frozenAccount)
                }
                .font(.caption.weight(.medium))
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(WorkbenchTheme.blue)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reviews

struct ReviewsSection: View {
    var onOpenRoute: ((WorkbenchRoute) -> Void)?

    @Environment(IPhoneAppState.self) private var state

    /// The ledger these reviews were read from, frozen on first appearance so a
    /// global account switch cannot write a review into another book.
    @State private var frozenAccount: BrokerageAccountID = .unassigned
    @State private var reviewTarget: ReviewTargetBox?

    private var reviewed: [(symbol: SymbolID, transaction: PositionTransaction)] {
        state.historyItems.flatMap { item in
            item.transactions
                .filter { $0.kind != .adjustment && !WorkbenchBoard.needsReview($0) }
                .map { (symbol: item.symbol, transaction: $0) }
        }
        .sorted { $0.transaction.date > $1.transaction.date }
    }

    private var unreviewed: [(symbol: SymbolID, transaction: PositionTransaction)] {
        state.historyItems.flatMap { item in
            item.transactions
                .filter { $0.kind != .adjustment && WorkbenchBoard.needsReview($0) }
                .map { (symbol: item.symbol, transaction: $0) }
        }
        .sorted { $0.transaction.date > $1.transaction.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if reviewed.isEmpty, unreviewed.isEmpty {
                WorkbenchEmptyState(
                    icon: "text.bubble",
                    title: "还没有可以复盘的成交",
                    message: "记录成交后可以在这里补一句简短复盘，不必回 Mac 才能写。"
                )
            } else {
                if !unreviewed.isEmpty {
                    WorkbenchSection(title: "待写复盘") {
                        WorkbenchCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(unreviewed.enumerated()), id: \.element.transaction.id) { index, row in
                                    if index > 0 { Divider().padding(.leading, 14) }
                                    reviewRow(row.symbol, row.transaction, isPending: true)
                                }
                            }
                        }
                    }
                }

                if !reviewed.isEmpty {
                    WorkbenchSection(title: "已写复盘") {
                        WorkbenchCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(reviewed.enumerated()), id: \.element.transaction.id) { index, row in
                                    if index > 0 { Divider().padding(.leading, 14) }
                                    reviewRow(row.symbol, row.transaction, isPending: false)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task { frozenAccount = state.accountID }
        .sheet(item: $reviewTarget) { box in
            ReviewEditorSheet(transaction: box.transaction, symbol: box.symbol, account: box.account)
        }
    }

    private func reviewRow(_ symbol: SymbolID, _ transaction: PositionTransaction, isPending: Bool) -> some View {
        Button {
            reviewTarget = ReviewTargetBox(transaction: transaction, symbol: symbol, account: frozenAccount)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.displayName(symbol))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(transaction.kind == .buy ? "买入" : "卖出")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(WorkbenchFormat.day(transaction.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let review = transaction.review, let text = review.retrospective, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else if let note = transaction.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text("还没有写复盘")
                        .font(.caption)
                        .foregroundStyle(WorkbenchTheme.blue)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.\(isPending ? "pending" : "completed").\(symbol.description).\(transaction.id.uuidString)")
    }
}

/// One recorded transaction plus the account it lives in, frozen at the moment
/// a row is built. Both travels together because neither alone identifies the
/// write: the same record id could not exist in two ledgers, but the ledger the
/// row was read from is what authorizes the edit.
struct PendingTransactionAction: Identifiable {
    let id = UUID()
    let transaction: PositionTransaction
    let symbol: SymbolID
    let account: BrokerageAccountID
}

/// `sheet(item:)` needs an identity; a transaction alone is not unique across
/// symbols, so the pair travels together with its frozen account.
struct ReviewTargetBox: Identifiable {
    let id = UUID()
    let transaction: PositionTransaction
    let symbol: SymbolID
    let account: BrokerageAccountID
}

// MARK: - Review editor

struct ReviewEditorSheet: View {
    let transaction: PositionTransaction
    let symbol: SymbolID
    /// Frozen when the sheet was opened. A global account switch while the
    /// review is being typed must not write it into another ledger.
    let account: BrokerageAccountID

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var followedPlan: Bool?
    @State private var retrospective: String
    @State private var strategy: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(transaction: PositionTransaction, symbol: SymbolID, account: BrokerageAccountID) {
        self.transaction = transaction
        self.symbol = symbol
        self.account = account
        _followedPlan = State(initialValue: transaction.review?.followedPlan)
        _retrospective = State(initialValue: transaction.review?.retrospective ?? "")
        _strategy = State(initialValue: transaction.review?.strategy ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkbenchCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(state.displayName(symbol))
                                .font(.headline)
                            Text("\(transaction.kind == .buy ? "买入" : "卖出") \(WorkbenchFormat.price(transaction.price, market: symbol.market)) × \(WorkbenchFormat.quantity(transaction.quantity)) · \(WorkbenchFormat.day(transaction.date))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    WorkbenchCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("是否按计划执行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("是否按计划执行", selection: $followedPlan) {
                                Text("未评价").tag(Bool?.none)
                                Text("按计划").tag(Bool?.some(true))
                                Text("偏离计划").tag(Bool?.some(false))
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    reviewField(title: "简短复盘", text: $retrospective, placeholder: "这笔做得怎么样", identifier: "review.retrospective")
                    reviewField(title: "策略记录", text: $strategy, placeholder: "当时的想法", identifier: "review.strategy")

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(WorkbenchTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("复盘只更新这笔记录的说明，不会改变成交价、数量、日期或持仓。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle("复盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("review.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { submit() }
                        .disabled(isSubmitting)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("review.save")
                }
            }
        }
        .workbenchError($errorMessage)
    }

    private func reviewField(title: String, text: Binding<String>, placeholder: String, identifier: String) -> some View {
        WorkbenchCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: text, axis: .vertical)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                    .lineLimit(3...8)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
            }
        }
    }

    /// The form owns only these three fields. Keep the undisplayed checkpoint
    /// and use the shared normalization for both explicit clears and saves.
    static func reviewForSaving(original: PositionTransactionReview?, followedPlan: Bool?,
                                retrospective: String, strategy: String) throws -> PositionTransactionReview? {
        var review = original ?? PositionTransactionReview()
        review.followedPlan = followedPlan
        review.retrospective = retrospective
        review.strategy = strategy
        return try review.normalizedForPersistence()
    }

    private func submit() {
        isSubmitting = true
        defer { isSubmitting = false }

        let review: PositionTransactionReview?
        do {
            review = try Self.reviewForSaving(original: transaction.review,
                followedPlan: followedPlan, retrospective: retrospective, strategy: strategy)
        } catch { errorMessage = error.localizedDescription; return }

        do {
            try state.saveReview(
                review,
                note: transaction.note,
                original: transaction,
                symbol: symbol,
                // The frozen account: the record being reviewed was read from it.
                account: account
            )
            dismiss()
        } catch let error as LocalizedError {
            errorMessage = error.errorDescription ?? error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Cash editor

struct CashEditorSheet: View {
    let account: BrokerageAccountID

    @Environment(IPhoneAppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var draft: [String: String] = [:]
    @State private var newCurrency = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var existing: [(currency: String, amount: Double, updatedAt: Date)] {
        AccountCash(settings: state.watchlist.brokerageSettings(for: account)).balances
    }

    private var currencies: [String] {
        Array(Set(existing.map(\.currency)).union(draft.keys)).sorted()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("现金余额由你自己填写。每个币种单独保存，不会自动折算或合并成单一总额。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    WorkbenchCard(padding: 12) {
                        VStack(spacing: 0) {
                            ForEach(Array(currencies.enumerated()), id: \.element) { index, currency in
                                if index > 0 { Divider() }
                                HStack {
                                    Text(currency)
                                        .font(.subheadline.weight(.medium))
                                        .frame(width: 60, alignment: .leading)
                                    TextField("金额", text: Binding(
                                        get: { draft[currency] ?? existing.first { $0.currency == currency }
                                            .map { TradeEntryView.editableNumber($0.amount) } ?? "" },
                                        set: { draft[currency] = $0 }
                                    ))
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .monospacedDigit()
                                    .textFieldStyle(.plain)
                                }
                                .frame(minHeight: 44)
                            }
                            if currencies.isEmpty {
                                Text("还没有币种。在下面添加一个。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 8)
                            }
                        }
                    }

                    WorkbenchCard(padding: 12) {
                        HStack(spacing: 8) {
                            TextField("币种代码，例如 CNY", text: $newCurrency)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .textFieldStyle(.plain)
                                .font(.subheadline)
                            Button("添加") {
                                let code = newCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                guard !code.isEmpty else { return }
                                draft[code] = ""
                                newCurrency = ""
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.bordered)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(WorkbenchTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(WorkbenchTheme.pageBackground(colorScheme))
            .navigationTitle("现金余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving)
                        .fontWeight(.semibold)
                }
            }
        }
        .workbenchError($errorMessage)
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }

        var settings = state.watchlist.brokerageSettings(for: account) ?? BrokerageAccountSettings()
        var balances = settings.cashBalances
        let now = Date.now

        for currency in currencies {
            let raw = draft[currency] ?? existing.first { $0.currency == currency }
                .map { TradeEntryView.editableNumber($0.amount) } ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // Clearing a field removes the entry rather than storing a zero.
                balances.removeValue(forKey: currency)
                continue
            }
            guard let amount = TradeEntryView.parse(trimmed), amount.isFinite else {
                errorMessage = "「\(currency)」的金额无法识别，没有保存。"
                return
            }
            balances[currency] = BrokerageCashBalance(amount: amount, updatedAt: now)
        }

        settings.cashBalances = balances
        guard state.watchlist.setBrokerageSettings(settings, for: account) else {
            errorMessage = "现金余额没有保存成功，请核对后重试。"
            return
        }
        dismiss()
    }
}
