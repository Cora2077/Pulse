import SwiftUI
import PulseCore
import PulseUI

/// The brokerage-account surfaces: the toolbar selector, its popover, and the
/// one sheet that moves legacy records into a named account.
///
/// Account identity is a *scope*, not a financial quantity. The selector sits in
/// the window toolbar so it costs no content height and is visible under every
/// page and overlay, and the popover only ever reads. The single write path in
/// this file is the classification sheet, and it writes through
/// `assignBrokerageRecords`, which owns every refusal rule.
///
/// Two visual languages share these screens and must never merge:
///
/// * The **account** is an identity: a small colour dot (`AccountIdentity`) plus
///   a neutral system icon. It never uses orange.
/// * **Margin funding** is a fact about one trade: the orange `FundingSourceTag`.
///
/// The 融资账号 account is deliberately *not* orange and does not use a credit
/// card: the financing account can hold ordinary or margin-funded purchases,
/// while Mengmeng purchases use ordinary funding. Account identity and funding
/// method keep separate visual signals.

// MARK: - Copy

private func accountCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}

// MARK: - Identity

/// The fixed identity of one account: its name, its icon, and its dot colour.
///
/// The names are the user's own words and are not translated — they identify
/// real places money is kept, and a translated account name would no longer
/// match what the user calls it. Only the surrounding UI is localized.
enum AccountIdentity {
    static func title(_ account: BrokerageAccountID) -> String {
        switch account {
        case .unassigned: PulseLocalization.localizedString("account.unassigned")
        case .financing: "融资账号"
        case .mengmeng: "萌萌账号"
        }
    }

    /// Icon first, colour second: the icons read apart at a glance and in
    /// greyscale, while the dot is a 6pt accent that never carries meaning alone.
    static func symbolName(_ account: BrokerageAccountID) -> String {
        switch account {
        case .unassigned: "tray"
        case .financing: "building.columns"
        case .mengmeng: "face.smiling"
        }
    }

    /// Never orange: that is the margin-funding annotation, a different axis.
    /// Never the pool tints either, which already own grey/blue/orange.
    static func dotColor(_ account: BrokerageAccountID) -> Color {
        switch account {
        case .unassigned: .secondary
        case .financing: .indigo
        case .mengmeng: .mint
        }
    }

    static func subtitle(_ account: BrokerageAccountID) -> String {
        switch account {
        case .unassigned:
            accountCopy("历史数据，尚未分配到具体账号", "Legacy records, not yet assigned to an account")
        case .financing:
            accountCopy("融资账号的独立账本，资金来源另行标注", "Independent account ledger; funding is annotated separately")
        case .mengmeng:
            accountCopy("萌萌账号的独立账本", "Independent Mengmeng account ledger")
        }
    }

    /// Where legacy records can be moved *to*. `unassigned` is a source, never a
    /// destination: there is no operation that un-classifies a record.
    static let destinations: [BrokerageAccountID] = [.financing, .mengmeng]
}

// MARK: - Summary

/// One account's read-only summary, computed from the store and the live quotes
/// at the moment it is asked for.
///
/// Nothing here is cached and nothing is aggregated across accounts: a portfolio
/// is opened through `withBrokerageAccount`, so the figures describe exactly the
/// account that was requested, and the snapshot is restored before returning.
struct BrokerageAccountSummary: Identifiable {
    let accountID: BrokerageAccountID
    /// Instruments carrying a position or trade history.
    let holdingCount: Int
    /// Cached valuation per currency, already formatted. Never summed across
    /// currencies — "¥" and "$" do not add.
    let currencyLines: [CurrencyLine]
    let missingQuoteCount: Int
    let staleQuoteCount: Int

    struct CurrencyLine: Identifiable {
        let currencyCode: String
        let value: Double
        var id: String { currencyCode }
        var formatted: String { PriceFormatter.money(value, currencyCode: currencyCode) }
    }

    var id: BrokerageAccountID { accountID }
    var isEmpty: Bool { holdingCount == 0 }

    /// "12 标的 · 3 缺价" — the counts a user needs to trust the money below.
    var holdingLine: String {
        guard holdingCount > 0 else { return accountCopy("暂无持仓", "No holdings") }
        var parts = [accountCopy("\(holdingCount) 标的", "\(holdingCount) instruments")]
        if staleQuoteCount > 0 { parts.append(accountCopy("\(staleQuoteCount) 旧价", "\(staleQuoteCount) stale")) }
        if missingQuoteCount > 0 { parts.append(accountCopy("\(missingQuoteCount) 缺价", "\(missingQuoteCount) missing")) }
        return parts.joined(separator: " · ")
    }
}

/// Reads one account's summary without disturbing the selection.
///
/// The market quotes come from the shared engine and are the same for every
/// account, so they are read outside the scope; only the portfolio is scoped.
@MainActor
enum BrokerageAccountSummaryReader {
    static func summaries(for store: WatchlistStore, market: MarketStore) -> [BrokerageAccountSummary] {
        BrokerageAccountID.allCases.map { summary(for: $0, store: store, market: market) }
    }

    static func summary(
        for account: BrokerageAccountID,
        store: WatchlistStore,
        market: MarketStore
    ) -> BrokerageAccountSummary {
        let records = BrokerageBoardReader.records(store: store)
        var quantities: [SymbolID: Double] = [:]
        for record in records {
            if let quantity = record.item.positionAccountQuantities(enclosingAccountID: record.accountID)[account] {
                quantities[record.item.symbol, default: 0] += quantity
            }
        }
        var valuation: [String: Double] = [:]
        var missing = 0, stale = 0
        for (symbol, quantity) in quantities where quantity != 0 {
            guard quantity.isFinite, let quote = market.quote(for: symbol),
                  quote.price.isFinite, quote.price > 0,
                  quote.timestamp.timeIntervalSince1970.isFinite else { missing += 1; continue }
            if !TradingQuoteHealth.isCurrent(quote) { stale += 1 }
            let value = quantity * quote.price
            let currency = symbol.currencyCode.uppercased()
            guard value.isFinite, (valuation[currency, default: 0] + value).isFinite else { missing += 1; continue }
            valuation[currency, default: 0] += value
        }

        let lines = valuation
            .filter { $0.value.isFinite && $0.value != 0 }
            .map { BrokerageAccountSummary.CurrencyLine(currencyCode: $0.key, value: $0.value) }
            .sorted { $0.currencyCode < $1.currencyCode }

        return BrokerageAccountSummary(
            accountID: account,
            holdingCount: quantities.filter { $0.value != 0 }.count,
            currencyLines: lines,
            missingQuoteCount: missing,
            staleQuoteCount: stale
        )
    }
}

// MARK: - Selector chip

/// The toolbar chip. Satisfies the "always visible, zero content height"
/// requirement by living in the toolbar's navigation slot rather than in a page
/// or a sidebar row.
///
/// While 账号总览 is on screen the chip says so instead of naming one account.
/// That is not a scope change — the concrete account underneath is still
/// selected and still remembered — but the toolbar must not claim a ledger is
/// being worked in while the user is reading all of them.
struct BrokerageAccountChip: View {
    let account: BrokerageAccountID
    let isEnabled: Bool
    var isOverviewing: Bool = false
    let action: () -> Void

    private var symbolName: String {
        isOverviewing ? "rectangle.on.rectangle" : AccountIdentity.symbolName(account)
    }

    private var title: String {
        isOverviewing ? accountCopy("全部账号", "All accounts") : AccountIdentity.title(account)
    }

    private var dotColor: Color {
        isOverviewing ? .secondary : AccountIdentity.dotColor(account)
    }

    private var help: String {
        isOverviewing
            ? accountCopy("查看全部账号；点击账号卡片上的入口，进入对应账号操作",
                          "View all accounts; use a card's shortcuts to work in that account")
            : accountCopy("当前账号；全部持仓、仓位池、计划、复盘与事件按其过滤",
                          "Current account; all holdings, pools, plans, journal and events are scoped to it")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(.quaternary.opacity(0.55), in: Capsule())
            .overlay {
                Capsule().stroke(dotColor.opacity(0.45), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(accountCopy("当前账号：\(title)，打开账号切换",
                                        "Current account: \(title); open switcher"))
    }
}

// MARK: - Popover

/// The selector popover. Read-only, in both senses: it reports what each account
/// holds and switches between them, and its top row *navigates* to 账号总览
/// without touching the selection.
///
/// The overview row is deliberately not an account. It carries no ledger, no
/// checkmark, and no totals: it is a door to a page, while the rows below it are
/// the places money is actually kept. Its presence is why "which account am I
/// in" stays a single, remembered answer even while all of them are on screen.
struct BrokerageAccountSwitcherPopover: View {
    let activeAccount: BrokerageAccountID
    var isOverviewing: Bool = false
    let summaries: [BrokerageAccountSummary]
    var onSelectOverview: () -> Void = {}
    let onSelect: (BrokerageAccountID) -> Void
    let onManage: () -> Void

    private var unassignedHoldingCount: Int {
        summaries.first { $0.accountID == .unassigned }?.holdingCount ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(accountCopy("账号", "Account"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            overviewRow

            Divider().padding(.vertical, 4)

            ForEach(summaries) { summary in
                row(summary)
            }

            if unassignedHoldingCount > 0 {
                Divider().padding(.vertical, 4)
                Text(accountCopy("历史数据从「未归属」开始分配",
                                 "Legacy records start out unassigned; classify them when you know where they belong"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider().padding(.vertical, 4)
            Button(action: onManage) {
                Text(accountCopy("管理账户归属…", "Manage classification…"))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .frame(width: 320)
    }

    /// The one row that is a page rather than a ledger. Read-only, so it never
    /// takes the checkmark, and its subtitle says what it does not do.
    private var overviewRow: some View {
        Button(action: onSelectOverview) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOverviewing ? .primary : .secondary)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountCopy("全部账号总览", "All accounts"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(accountCopy("现金 · 持仓 · 计划",
                                     "Cash · Holdings · Plans"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if isOverviewing {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isOverviewing ? Color.accentColor.opacity(0.12) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOverviewing ? [.isSelected] : [])
    }

    private func row(_ summary: BrokerageAccountSummary) -> some View {
        let account = summary.accountID
        let isSelected = account == activeAccount
        return Button {
            onSelect(account)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(AccountIdentity.dotColor(account))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Image(systemName: AccountIdentity.symbolName(account))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AccountIdentity.title(account))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(summary.holdingLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    // One line per currency. A missing quote is named here rather
                    // than silently valued at zero; no figure is ever summed
                    // across currencies.
                    ForEach(summary.currencyLines) { line in
                        Text(line.formatted)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Classification sheet

/// Moves legacy records out of 未归属, one instrument at a time.
///
/// It is a review surface, not a form: the source is always 未归属 (the store
/// refuses every other source), and the destination is one of the two named
/// accounts. A row moves either the whole ledger — plans, events and metadata
/// travel with it — or a chosen subset of trades, which the store accepts only
/// when the split replays to a valid chronology. A refusal is reported against
/// the row and the selection is preserved, so a partially-applied batch is never
/// possible: one confirmation is one instrument's assignment or nothing.
struct BrokerageAccountClassificationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onAssigned: ([SymbolID]) -> Void
    var initialDestination: BrokerageAccountID = .financing

    /// What one row is moving. `nil` ids means the whole ledger.
    private struct RowSelection: Equatable {
        var transactionIDs: Set<UUID>?
        var wholeLedger = false
        var isExpanded = false
    }

    @State private var destination: BrokerageAccountID = .financing
    @State private var selection: [SymbolID: RowSelection] = [:]
    @State private var errorMessage: String?
    @State private var isWorking = false
    /// Set when the pre-migration backup could not be written. The sheet stays
    /// open and read-only rather than offering a confirm that cannot be honored.
    @State private var backupBlocked = false
    /// Shown once. 融资账号 is an account name, not a statement that everything
    /// inside it was bought on margin — those are separate axes, and without this
    /// sentence the indigo dot and the orange tag would read as the same idea.
    private let marginExplanation = accountCopy(
        "融资账号可以选择担保品买入或融资买入。",
        "The financing account supports collateral buys and margin buys."
    )

    /// The unassigned portfolio, including instruments kept only for their
    /// ledger, read through the store's public accessor rather than the mirrored
    /// arrays — so this list is the same whether or not 未归属 is selected.
    private var sourceItems: [WatchItem] {
        let portfolio = appState.watchlist.brokeragePortfolio(for: .unassigned)
        return (portfolio.items + portfolio.retainedHistoryItems)
            .filter { $0.supportsPosition && ($0.hasPositionHistory || !$0.plans.isEmpty || !$0.events.isEmpty || $0.thesis != nil) }
            .sorted { $0.symbol.displayCode < $1.symbol.displayCode }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if backupBlocked {
                backupWarning
                Divider()
            }
            content
            Divider()
            BrokerageClassificationFooterNote()
            footer
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            destination = initialDestination
            backupBlocked = !appState.isMainWindowDemo && !appState.localBackups.isAvailable
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(accountCopy("账户归属", "Account classification"))
                .font(.system(size: 13, weight: .semibold))
            Text(accountCopy("按标的整体账本或按成交分配；计划与事件跟随整体账本移动",
                             "Assign a whole ledger or chosen trades; plans and events follow the whole ledger"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(marginExplanation)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var backupWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(accountCopy("本地备份不可用，暂不能整理归属。请先在数据页开启备份。",
                             "Local backups are unavailable, so classification is paused. Enable backups on the Data page first."))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            destinationBar
            Divider()
            if sourceItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(accountCopy("未归属没有可整理的持仓", "Nothing left to classify"))
                        .font(.system(size: 12, weight: .medium))
                    Text(accountCopy("持仓、成交历史和尚未归属的计划会出现在这里。",
                                     "Positions, trade history and unassigned plans appear here."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sourceItems, id: \.symbol) { item in
                            row(item)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var destinationBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: AccountIdentity.symbolName(.unassigned))
                    .font(.system(size: 11))
                Text(AccountIdentity.title(.unassigned))
                    .font(.system(size: 11, weight: .medium))
                Text("\(sourceItems.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.quaternary.opacity(0.55), in: Capsule())

            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)

            Picker("", selection: $destination) {
                ForEach(AccountIdentity.destinations, id: \.self) { account in
                    Text(AccountIdentity.title(account)).tag(account)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Row

    private func row(_ item: WatchItem) -> some View {
        let state = selection[item.symbol] ?? RowSelection(transactionIDs: nil)
        let isWhole = state.wholeLedger || state.transactionIDs == nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggle(item)
                } label: {
                    Image(systemName: isChosen(item) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isChosen(item) ? AccountIdentity.dotColor(destination) : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accountCopy("选择 \(appState.displayName(for: item.symbol))",
                                                "Select \(appState.displayName(for: item.symbol))"))

                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.displayName(for: item.symbol))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(item.symbol.displayCode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Text(holdingLine(item))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                // An existing margin annotation is shown, never inferred: the
                // sheet reports what the record says, and moving an instrument
                // to 融资账号 does not itself mark anything as margin-funded.
                FundingSourceTag(source: item.positionAllocation?.portions.first?.fundingSource,
                    account: item.positionAllocation?.portions.first?.brokerageAccountID ?? .unassigned)

                Menu {
                    Button(accountCopy("整体账本", "Whole ledger")) {
                        selection = [item.symbol: RowSelection(transactionIDs: Set(item.materializedTransactions().map(\.id)),
                                                              wholeLedger: true, isExpanded: false)]
                    }
                    if item.materializedTransactions().count > 1 {
                        Button(accountCopy("选择成交…", "Choose trades…")) {
                            let selected = selection[item.symbol]?.transactionIDs ?? []
                            selection = [item.symbol: RowSelection(transactionIDs: selected, isExpanded: true)]
                        }
                    }
                } label: {
                    Text(isWhole ? accountCopy("整体账本", "Whole ledger")
                                 : accountCopy("\(state.transactionIDs?.count ?? 0) 笔成交",
                                               "\(state.transactionIDs?.count ?? 0) trades"))
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if isWhole {
                Text(accountCopy("整体移动：该标的的计划、事件与元数据一并跟随。",
                                 "Whole ledger: this instrument's plans, events and metadata move with it."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                transactionRows(item, selected: state.transactionIDs ?? [])
                Text(accountCopy("部分移动：计划与事件保留在未归属，本版本仅移动成交与对应持仓。",
                                 "Partial move: plans and events stay unassigned; only the trades and their position move."))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func transactionRows(_ item: WatchItem, selected: Set<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(item.materializedTransactions()) { transaction in
                Button {
                    toggle(transaction, in: item)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: selected.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(selected.contains(transaction.id)
                                             ? AccountIdentity.dotColor(destination) : Color.secondary)
                            .frame(width: 18)
                        Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(sideTitle(transaction.kind))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(sideColor(transaction.kind))
                        Text("\(PriceFormatter.quantity(transaction.quantity)) @ \(PriceFormatter.price(transaction.price, market: item.symbol.market))")
                            .font(.system(size: 10, design: .monospaced))
                        Spacer(minLength: 4)
                        FundingSourceTag(source: transaction.fundingSource,
                            account: transaction.brokerageAccountID ?? .unassigned)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(accountCopy("已选 \(selected.count)/\(item.materializedTransactions().count) 笔",
                             "\(selected.count)/\(item.materializedTransactions().count) selected"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 30)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(accountCopy("取消", "Cancel")) { dismiss() }
            Button(accountCopy("确认分配", "Assign")) { assign() }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
        }
        .controlSize(.small)
        .padding(12)
        .alert(accountCopy("无法完成归属", "Could not assign"), isPresented: errorBinding) {
            Button(accountCopy("好", "OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var footerSummary: String {
        let chosen = chosenSymbols
        guard !chosen.isEmpty else {
            return accountCopy("选择要移动的标的", "Pick the instruments to move")
        }
        let trades = chosen.reduce(0) { total, symbol in
            guard let ids = selection[symbol]?.transactionIDs else { return total }
            return total + ids.count
        }
        let target = AccountIdentity.title(destination)
        return trades == 0
            ? accountCopy("将移动 \(chosen.count) 个标的的整体账本 → \(target)",
                          "Move \(chosen.count) whole ledgers → \(target)")
            : accountCopy("将移动 \(chosen.count) 个标的 · \(trades) 笔成交 → \(target)",
                          "Move \(chosen.count) instruments · \(trades) trades → \(target)")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var canConfirm: Bool {
        !isWorking && !backupBlocked
            && appState.watchlist.brokerageAccountsEnabled
            && !chosenSymbols.isEmpty
    }

    private var chosenSymbols: [SymbolID] {
        sourceItems.filter(isChosen).map(\.symbol)
    }

    private func isChosen(_ item: WatchItem) -> Bool {
        guard let state = selection[item.symbol] else { return false }
        return state.wholeLedger || !(state.transactionIDs ?? []).isEmpty
    }

    private func toggle(_ item: WatchItem) {
        if isChosen(item) {
            selection[item.symbol] = RowSelection(transactionIDs: nil, isExpanded: selection[item.symbol]?.isExpanded ?? false)
        } else {
            // Whole ledger by default: it is the honest default, because the
            // store cannot reconstruct an instrument's plan/event ownership once
            // a subset of its trades has moved.
            let all = Set(item.materializedTransactions().map(\.id))
            selection = [item.symbol: RowSelection(transactionIDs: all, wholeLedger: true, isExpanded: false)]
        }
    }

    private func toggle(_ transaction: PositionTransaction, in item: WatchItem) {
        let existing = selection[item.symbol]
        selection = [:]
        var state = existing ?? RowSelection(transactionIDs: [])
        var ids = state.transactionIDs ?? []
        if ids.contains(transaction.id) { ids.remove(transaction.id) } else { ids.insert(transaction.id) }
        state.transactionIDs = ids
        state.wholeLedger = ids == Set(item.materializedTransactions().map(\.id))
        state.isExpanded = true
        selection[item.symbol] = state
    }

    // MARK: Assignment

    private func assign() {
        let targets = chosenSymbols
        guard targets.count == 1 else { return }
        isWorking = true
        defer { isWorking = false }

        // A verified manual backup first, unless the isolated render harness owns
        // this store. The sheet refuses to proceed if it cannot be written.
        if !appState.isMainWindowDemo, !appState.localBackups.createManualBackup() {
            errorMessage = accountCopy("无法写入本地备份，未做任何更改。请先在数据页检查备份后重试。",
                                       "Could not write a local backup, so nothing was changed. Check backups on the Data page and retry.")
            return
        }

        var assigned: [SymbolID] = []
        var refused: [SymbolID] = []
        // Selection is one instrument at a time; each classification is atomic.
        appState.watchlist.withBrokerageAccount(.unassigned) {
            for symbol in targets {
                let ids = selection[symbol]?.wholeLedger == true ? nil : selection[symbol]?.transactionIDs
                let ok = appState.watchlist.assignBrokerageRecords(
                    for: symbol,
                    transactionIDs: ids,
                    to: destination
                )
                if ok { assigned.append(symbol) } else { refused.append(symbol) }
            }
        }

        if !assigned.isEmpty {
            for symbol in assigned { selection[symbol] = nil }
            onAssigned(assigned)
            appState.engine.poke()
        }

        guard !refused.isEmpty else {
            errorMessage = nil
            if sourceItems.isEmpty { dismiss() }
            return
        }

        let names = refused.map(\.displayCode).joined(separator: "、")
        errorMessage = accountCopy(
            "\(names) 未能分配：该标的的成交顺序无法形成有效持仓，或目标账号已有冲突记录。选择已保留，可改用整体账本重试。",
            "\(names) could not be assigned: the trades do not replay to a valid chronology, or the destination already holds a conflicting record. Your selection was kept — try the whole ledger."
        )
    }

    // MARK: Row helpers

    private func holdingLine(_ item: WatchItem) -> String {
        let quantity = item.positionQuantity
        return quantity == 0
            ? accountCopy("无持仓", "No position")
            : PriceFormatter.quantity(quantity)
    }

    private func sideTitle(_ kind: PositionTransaction.Kind) -> String {
        switch kind {
        case .buy: accountCopy("买入", "Buy")
        case .sell: accountCopy("卖出", "Sell")
        case .adjustment: accountCopy("校准", "Adjust")
        }
    }

    /// The shared plan-side token, so 买入/卖出 reads the same here as on a plan
    /// card. `.adjustment` is neither side and stays neutral.
    private func sideColor(_ kind: PositionTransaction.Kind) -> Color {
        switch kind {
        case .buy, .sell: PlanSideStyle.color(for: kind)
        case .adjustment: .secondary
        }
    }
}

// MARK: - Footer note

/// The one sentence that stops classification from reading as a broker transfer.
/// Shown once, at the bottom of the sheet, rather than repeated per row.
struct BrokerageClassificationFooterNote: View {
    var body: some View {
        Text(accountCopy("归属整理，不代表证券转账。",
                         "Classifying records is not a securities transfer."))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityLabel(accountCopy("归属整理，不代表证券转账",
                                            "Classifying records is not a securities transfer"))
    }
}

// MARK: - Compact account tag

/// The inline account tag: a dot, the account's own name, and a hairline
/// chevron, opening a three-item menu.
///
/// It answers one question — which ledger does this row belong to — and answers
/// nothing else. There are no counts, no totals, and no management affordance:
/// a number here would turn an identity into a figure and invite reading the
/// tag as a summary, and a fourth menu entry would re-open the switcher the
/// toolbar already owns. The dot keeps the account's own colour and never the
/// orange margin-funding tint, which is a fact about a trade rather than a place
/// money is kept.
struct PositionAccountTag: View {
    let account: BrokerageAccountID
    let isEnabled: Bool
    let onSelect: (BrokerageAccountID) -> Void

    var body: some View {
        Menu {
            ForEach(BrokerageAccountID.allCases, id: \.self) { choice in
                Button {
                    onSelect(choice)
                } label: {
                    // A plain title plus a checkmark on the current choice; the
                    // menu system supplies the checkmark, so it is added here as
                    // a label rather than as a custom row.
                    if choice == account {
                        Label(AccountIdentity.title(choice), systemImage: "checkmark")
                    } else {
                        Text(AccountIdentity.title(choice))
                    }
                }
                .accessibilityLabel(accountCopy("切换到\(AccountIdentity.title(choice))",
                                                "Switch to \(AccountIdentity.title(choice))"))
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(AccountIdentity.dotColor(account))
                    .frame(width: 5, height: 5)
                Text(AccountIdentity.title(account))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AccountIdentity.dotColor(account).opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        // The label already draws its own chevron, so the native indicator would
        // be a second one saying the same thing.
        .menuIndicator(.hidden)
        .disabled(!isEnabled)
        .accessibilityLabel(accountCopy("账号：\(AccountIdentity.title(account))，打开账号选择",
                                        "Account: \(AccountIdentity.title(account)); open account choices"))
    }
}

// MARK: - Filter bar

/// A horizontal account filter for one page. It is a *view* filter, not a scope
/// change: it moves its own binding and never `appState`'s active account, so
/// filtering a list to 融资账号 cannot silently change which ledger an edit
/// lands in.
///
/// `nil` is 全部账户 — the unfiltered reading — and it stays neutral rather than
/// taking an identity colour, because "no filter" is not an account.
struct BrokerageAccountFilterBar: View {
    @Binding var selection: BrokerageAccountID?

    /// Explicit order — 全部, 融资账号, 萌萌账号, 未归属. Spelled out rather than
    /// built from `allCases` (which would put 未归属 first) so both the order and
    /// the optional element type are pinned.
    private static let choices: [BrokerageAccountID?] = [nil, .financing, .mengmeng, .unassigned]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.choices.enumerated()), id: \.offset) { _, choice in
                button(for: choice)
            }
        }
        .frame(height: 25)
    }

    private func title(for choice: BrokerageAccountID?) -> String {
        guard let choice else { return accountCopy("全部", "All") }
        return AccountIdentity.title(choice)
    }

    private func isSelected(_ choice: BrokerageAccountID?) -> Bool {
        choice == selection
    }

    /// Neutral for 全部, the account's own colour otherwise — never orange.
    private func tint(for choice: BrokerageAccountID?) -> Color {
        guard let choice else { return .secondary }
        return AccountIdentity.dotColor(choice)
    }

    private func button(for choice: BrokerageAccountID?) -> some View {
        let selected = isSelected(choice)
        let label = title(for: choice)
        return Button {
            selection = choice
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? tint(for: choice) : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(selected ? tint(for: choice).opacity(0.08) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accountCopy("筛选：\(label)", "Filter: \(label)"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
