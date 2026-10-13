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

    /// What one ledger *is*, in the user's words. The pending-assignment ledger
    /// is described as where old records wait, never as a place money is kept:
    /// it accepts no new buy, so a sentence that read
    /// like the other two accounts would re-open the misunderstanding this
    /// ledger's name was changed to close.
    static func subtitle(_ account: BrokerageAccountID) -> String {
        switch account {
        case .unassigned:
            accountCopy("旧数据待归类；不能记录新的成交",
                        "Legacy records awaiting classification; no new trades")
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
                Text(accountCopy("历史数据先进入「待确认记录」，确认归属后再归类",
                                 "Legacy records wait in “Pending assignment”; classify them once you know where they belong"))
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
    var sourceAccountID: BrokerageAccountID = .unassigned
    var initialSymbol: SymbolID?
    var initialTransactionIDs: Set<UUID>?

    /// What one row is moving, said outright rather than inferred.
    ///
    /// `wholeLedger` is the mode, and `transactionIDs` only has a meaning
    /// inside the trade mode. A set that happens to hold every remaining trade
    /// is still a *selection*: the whole point of the mode is that the user
    /// chose one, and the store moves a selection without its plans. Deriving
    /// the mode from `ids == allIDs` would silently rewrite that choice into
    /// the one operation that can be refused for a pre-existing target record.
    private struct RowSelection: Equatable {
        var transactionIDs: Set<UUID>
        var wholeLedger = false
        static let whole = RowSelection(transactionIDs: [], wholeLedger: true)
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
        let portfolio = appState.watchlist.brokeragePortfolio(for: sourceAccountID)
        return (portfolio.items + portfolio.retainedHistoryItems)
            .filter { $0.supportsPosition && $0.hasPositionHistory && (initialSymbol == nil || $0.symbol == initialSymbol) }
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
            destination = initialDestination == sourceAccountID
                ? AccountIdentity.destinations.first { $0 != sourceAccountID } ?? .financing
                : initialDestination
            if selection.isEmpty, let symbol = initialSymbol, let ids = initialTransactionIDs {
                selection[symbol] = RowSelection(transactionIDs: ids)
            }
            backupBlocked = !appState.isMainWindowDemo && !appState.localBackups.isAvailable
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(accountCopy("账户归属", "Account classification"))
                .font(.system(size: 13, weight: .semibold))
            Text(accountCopy("「整体账本」连同该标的的计划、事件等上下文一起移动；「选择成交」只整理成交，计划留在原账本。",
                             "Whole ledger moves the instrument's plans, events and other context with it; choosing trades moves only those trades and leaves the plans behind."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(accountCopy("持仓账户由成交记录确定；旧卡片标签保留在历史中，不影响账户统计。",
                             "Holdings follow their recorded trades. Legacy card labels remain in history and do not affect account totals."))
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
                    Text(accountCopy("「待确认记录」没有可整理的持仓", "Nothing left to classify"))
                        .font(.system(size: 12, weight: .medium))
                    Text(accountCopy("缺少可靠账户信息的历史成交会出现在这里。计划的执行账户在计划中单独设置。",
                                     "Historical trades without reliable account ownership appear here. A plan's execution default is set on the plan."))
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
                Image(systemName: AccountIdentity.symbolName(sourceAccountID))
                    .font(.system(size: 11))
                Text(AccountIdentity.title(sourceAccountID))
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
                ForEach(AccountIdentity.destinations.filter { $0 != sourceAccountID }, id: \.self) { account in
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
        let state = selection[item.symbol] ?? RowSelection(transactionIDs: [])
        let isWhole = state.wholeLedger
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
                // The tag is tested against the ledger this sheet lists — the
                // old per-portion label is historical evidence, not a scope.
                FundingSourceTag(source: item.positionAllocation?.portions.first?.fundingSource,
                    account: sourceAccountID)

                Menu {
                    Button(accountCopy("整体账本", "Whole ledger")) {
                        selection = [item.symbol: .whole]
                    }
                    // Offered whenever there is anything to select — one trade
                    // included. Hiding it below two trades is what made the last
                    // remaining trade impossible to move as a selection, and it
                    // is exactly the case where the whole-ledger path is the one
                    // the destination tends to refuse.
                    if !item.materializedTransactions().isEmpty {
                        Button(accountCopy("选择成交…", "Choose trades…")) {
                            let previous = selection[item.symbol]
                            let selected = previous.map { previous in
                                previous.wholeLedger ? [] : previous.transactionIDs
                            } ?? []
                            selection = [item.symbol: RowSelection(transactionIDs: selected)]
                        }
                    }
                } label: {
                    Text(isWhole ? accountCopy("整体账本", "Whole ledger")
                                 : accountCopy("已选 \(state.transactionIDs.count) 笔",
                                               "\(state.transactionIDs.count) selected"))
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
                transactionRows(item, selected: state.transactionIDs)
                Text(accountCopy("部分移动：只移动所选成交与对应持仓，计划、事件与元数据保留在原账本。",
                                 "Partial move: only the chosen trades and their position move; plans, events and metadata stay in the original ledger."))
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
                            account: sourceAccountID)
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
            guard let state = selection[symbol], !state.wholeLedger else { return total }
            return total + state.transactionIDs.count
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
            && destination != sourceAccountID
            && !chosenSymbols.isEmpty
    }

    private var chosenSymbols: [SymbolID] {
        sourceItems.filter(isChosen).map(\.symbol)
    }

    private func isChosen(_ item: WatchItem) -> Bool {
        guard let state = selection[item.symbol] else { return false }
        return state.wholeLedger || !state.transactionIDs.isEmpty
    }

    private func toggle(_ item: WatchItem) {
        if isChosen(item) {
            selection[item.symbol] = nil
        } else {
            // Whole ledger by default: it is the honest default, because
            // 待确认记录 holds context — plans, events, the thesis — that only
            // a whole-ledger move carries. The trade mode stays one menu click
            // away, and entering it is never undone by counting the trades.
            selection = [item.symbol: .whole]
        }
    }

    private func toggle(_ transaction: PositionTransaction, in item: WatchItem) {
        let existing = selection[item.symbol]
        selection = [:]
        var state = existing ?? RowSelection(transactionIDs: [])
        if state.transactionIDs.contains(transaction.id) {
            state.transactionIDs.remove(transaction.id)
        } else {
            state.transactionIDs.insert(transaction.id)
        }
        // Toggling inside the trade list is a statement about the *mode*: the
        // row keeps moving selected trades even when the user happens to tick
        // every remaining one. "All of them" is not the same operation as
        // "the ledger", and only the menu can ask for the latter.
        state.wholeLedger = false
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
        // One refusal reason, kept in the order the rows were submitted, so the
        // sentence the user reads names *why* rather than restating the guess.
        var refusal: String?
        // Selection is one instrument at a time; each classification is atomic.
        appState.watchlist.withBrokerageAccount(sourceAccountID) {
            for symbol in targets {
                // The mode is taken from the row and handed over as a request:
                // a whole ledger, or these exact trades. An empty selection is
                // never submitted — there is nothing to move, and asking the
                // store for it would only be answered with a refusal.
                guard let state = selection[symbol],
                      state.wholeLedger || !state.transactionIDs.isEmpty else { continue }
                let request: BrokerageOwnership.ClassificationRequest = state.wholeLedger
                    ? .wholeLedger
                    : .selectedTrades(state.transactionIDs)
                do {
                    // The explicit source and destination are the ones the sheet
                    // shows; the mode was never inferred from a count.
                    try appState.watchlist.assignBrokerageRecordsChecked(
                        for: symbol,
                        request: request,
                        from: sourceAccountID,
                        to: destination
                    )
                    assigned.append(symbol)
                } catch {
                    refusal = refusal ?? Self.describe(error)
                }
            }
        }

        if !assigned.isEmpty {
            for symbol in assigned { selection[symbol] = nil }
            onAssigned(assigned)
            appState.engine.poke()
        }

        guard !assigned.isEmpty else {
            // Nothing moved. The selection is kept exactly as it was and the
            // store's own reason is shown, so the user can correct the cause
            // instead of guessing which of several rules refused.
            errorMessage = refusal ?? accountCopy(
                "未能归类：请核对是否遗漏了相关买卖成交、份额是否需要核对，以及资金方式是否符合目标账户。选择已保留，数据未改变。",
                "Could not classify. Check related buys and sells, allocation reconciliation, and the destination's permitted funding. Your selection was kept and the data was unchanged."
            )
            return
        }
        errorMessage = nil
        if sourceItems.isEmpty { dismiss() }
    }

    /// The store's own sentence about the refusal. A generic restatement of the
    /// possible rules tells the user nothing they can act on; the thrown reason
    /// names the one gate that actually closed.
    private static func describe(_ error: Error) -> String {
        if let mutationError = error as? TradeMutationError,
           let description = mutationError.errorDescription {
            return description
        }
        let localized = error.localizedDescription
        return localized.isEmpty ? String(describing: error) : localized
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

/// The inline account tag: a dot and the account's own name.
///
/// It answers one question — which ledger does this row belong to — and answers
/// nothing else. There are no counts, no totals, and no management affordance:
/// a number here would turn an identity into a figure and invite reading the
/// tag as a summary. The dot keeps the account's own colour and never the
/// orange margin-funding tint, which is a fact about a trade rather than a place
/// money is kept.
///
/// It is deliberately *not* a control. It used to open a switcher that wrote
/// the legacy per-portion label, which never moved a trade and could only make
/// the label disagree with the ledger underneath it; the tag now only states
/// where the shares are. Moving a holding is the historical classification
/// entrance, not a relabel.
struct PositionAccountTag: View {
    let account: BrokerageAccountID

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(AccountIdentity.dotColor(account))
                .frame(width: 5, height: 5)
            Text(AccountIdentity.title(account))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(AccountIdentity.dotColor(account).opacity(0.07))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accountCopy("账号：\(AccountIdentity.title(account))",
                                        "Account: \(AccountIdentity.title(account))"))
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
