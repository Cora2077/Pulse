import SwiftUI
import PulseCore
import PulseUI

/// The read-only cross-account overview (`全部账号总览`).
///
/// This page exists to answer one question the rest of the app deliberately
/// never answers: *across all my accounts, in one currency, where is the money
/// and what have I committed?* It is a **view**, not a ledger. Nothing here is
/// selected, nothing is blended, and no account is written through this screen
/// except the one cash field the user explicitly edits — and that write goes to
/// a frozen account id + currency pair captured when the sheet opened.
///
/// Three rules are load-bearing and must not be relaxed:
///
/// 1. **Currencies never mix.** Every figure is computed from
///    `BrokerageAccountOverviewReader.rows` for one currency; totals sum
///    same-currency rows only, and a "total" is never a sum of ¥ and $.
/// 2. **Unknown is not zero.** A cash subtotal is only printed when every
///    in-scope account has recorded cash; otherwise the subtotal is shown with a
///    named `N 账号未录现金` warning, and when nothing is recorded the block reads
///    未录 rather than 0. Cash recorded as exactly 0 is shown as 0.
/// 3. **Gross, never net.** 持仓市值 + 已录现金 is 账面记录资金. The app holds no
///    debt or credit data, so it cannot and must not claim a net asset.
///
/// Missing and stale quotes are *marked* rather than silently dropped: a stale
/// (closed-session) quote still values the holding and carries a 旧价 badge,
/// while a missing quote is excluded from the value and counted as 缺价.
struct BrokerageAccountOverviewView: View {
    @Environment(AppState.self) private var appState

    /// Which accounts the page is *showing*. A view filter only: it never
    /// changes the selected account, and every card keeps addressing its own
    /// frozen account id.
    enum AccountFilter: String, CaseIterable, Identifiable {
        case all, financing, mengmeng, unassigned

        var id: String { rawValue }

        var account: BrokerageAccountID? {
            switch self {
            case .all: nil
            case .financing: .financing
            case .mengmeng: .mengmeng
            case .unassigned: .unassigned
            }
        }

        var title: String {
            switch self {
            case .all: overviewCopy("全部", "All")
            case .financing: AccountIdentity.title(.financing)
            case .mengmeng: AccountIdentity.title(.mengmeng)
            case .unassigned: AccountIdentity.title(.unassigned)
            }
        }
    }

    let onSelect: (SymbolID) -> Void
    let onShowPage: (MainWorkspacePage) -> Void

    @State private var filter: AccountFilter = .all
    @State private var currencyCode: String?
    @State private var cashEditor: CashEditorTarget?
    @State private var showsUnassigned = false

    init(
        onSelect: @escaping (SymbolID) -> Void,
        onShowPage: @escaping (MainWorkspacePage) -> Void
    ) {
        self.onSelect = onSelect
        self.onShowPage = onShowPage
    }

    #if DEBUG
    /// Seeds the two view filters for native rendering. Only the `@State` the
    /// production path already writes is touched, so the real `init` is unchanged.
    init(
        onSelect: @escaping (SymbolID) -> Void,
        onShowPage: @escaping (MainWorkspacePage) -> Void,
        filter: AccountFilter,
        currencyCode: String?
    ) {
        self.onSelect = onSelect
        self.onShowPage = onShowPage
        _filter = State(initialValue: filter)
        _currencyCode = State(initialValue: currencyCode)
    }
    #endif

    /// Which account/currency the cash sheet is writing, frozen at open time.
    /// Storing the pair rather than reading it back from a selection is what
    /// makes it impossible for the sheet to write into whichever account happens
    /// to be active when 确认 is pressed.
    struct CashEditorTarget: Identifiable {
        let accountID: BrokerageAccountID
        let currencyCode: String
        var id: String { "\(accountID.rawValue)|\(currencyCode)" }
    }

    // MARK: - Read model

    /// Every account/currency row, read once per render. This never calls
    /// `selectBrokerageAccount`: the reader opens each portfolio in place.
    ///
    /// Everything below is derived from this one snapshot. It is deliberately a
    /// `let`-per-body value rather than a computed property that each accessor
    /// re-reads: the reader walks every portfolio and every plan, and a page
    /// whose filter, currency picker and totals each triggered their own walk
    /// would do that work several times per frame and could disagree with itself
    /// if a quote landed mid-render.
    struct Snapshot {
        let rows: [BrokerageAccountOverviewRow]
        let accounts: [BrokerageAccountID]
        let currencies: [String]
    }

    private func snapshot(currency: String?) -> Snapshot {
        let all = BrokerageAccountOverviewReader.rows(
            store: appState.watchlist,
            market: appState.market,
            budgets: appState.poolBudgets
        )
        // 未归属 is a view-only archive: it only appears when it still holds
        // something, so an empty legacy book never takes up a slot.
        let accounts = BrokerageAccountID.allCases.filter { account in
            if let forced = filter.account { return account == forced }
            return account != .unassigned || all.contains { $0.accountID == .unassigned && $0.hasActivity }
        }
        let scoped = all.filter { accounts.contains($0.accountID) }

        // CNY is always offered: it is the account currency even before anything
        // is recorded in it.
        var codes = Set(scoped.map(\.currencyCode))
        codes.remove("CNY")
        let currencies = ["CNY"] + codes.sorted()

        let effective = currency.flatMap { currencies.contains($0) ? $0 : nil } ?? currencies[0]
        return Snapshot(
            rows: scoped.filter { $0.currencyCode == effective },
            accounts: accounts,
            currencies: currencies
        )
    }

    /// The currency one snapshot is showing. Kept next to `Snapshot` so a view
    /// helper can never reach for a currency the rows were not filtered by.
    private func activeCurrency(_ snapshot: Snapshot) -> String {
        snapshot.rows.first?.currencyCode
            ?? (currencyCode.flatMap { snapshot.currencies.contains($0) ? $0 : nil } ?? snapshot.currencies[0])
    }

    private func rows(for account: BrokerageAccountID, in snapshot: Snapshot) -> [BrokerageAccountOverviewRow] {
        snapshot.rows.filter { $0.accountID == account }
    }

    // MARK: - Totals

    /// One currency's totals, summed from rows that already speak the same
    /// currency. `knownCashCount` is what separates "0" from "not recorded".
    struct CurrencyTotals {
        var accountCount = 0
        var cash: Double = 0
        var knownCashCount = 0
        var holdingValue: Double = 0
        var plannedBuy: Double = 0
        var plannedSell: Double = 0
        var missingQuotes = 0
        var staleQuotes = 0
        var hasOverflow = false

        var hasKnownCash: Bool { knownCashCount > 0 }
        var allCashKnown: Bool { accountCount > 0 && knownCashCount == accountCount }
        var unknownCashCount: Int { max(0, accountCount - knownCashCount) }
        var hasPlannedBuy: Bool { plannedBuy > 0 }
        var hasPlannedSell: Bool { plannedSell > 0 }

        /// Gross recorded capital. Only printable when every in-scope account
        /// recorded cash, no quote is missing, and nothing overflowed.
        var recordedFunds: Double? {
            guard !hasOverflow, missingQuotes == 0, allCashKnown else { return nil }
            let value = holdingValue + cash
            return value.isFinite ? value : nil
        }
    }

    /// The accounts that get a card: everything in scope except the legacy
    /// archive, which folds away underneath.
    private func cardAccounts(_ snapshot: Snapshot) -> [BrokerageAccountID] {
        snapshot.accounts.filter { $0 != .unassigned }
    }

    /// One currency's totals, from one snapshot. Every in-scope account is
    /// counted, including one that is completely empty: that is what makes the
    /// "N 账号未录现金" warning honest rather than a count of the accounts that
    /// happened to have something.
    private func totals(_ snapshot: Snapshot) -> CurrencyTotals {
        var result = CurrencyTotals()
        for account in snapshot.accounts {
            result.accountCount += 1
            for row in rows(for: account, in: snapshot) {
                if let cash = row.cash, cash.amount.isFinite {
                    result.cash += cash.amount
                    result.knownCashCount += 1
                }
                result.holdingValue += row.holdingValue
                result.plannedBuy += row.plannedBuy
                result.plannedSell += row.plannedSell
                result.missingQuotes += row.missingQuotes
                result.staleQuotes += row.staleQuotes
                if row.hasOverflow { result.hasOverflow = true }
            }
        }
        let values = [result.cash, result.holdingValue, result.plannedBuy, result.plannedSell]
        if !values.allSatisfy({ $0.isFinite }) { result.hasOverflow = true }
        return result
    }

    // MARK: - Body

    var body: some View {
        // One read of every portfolio per render; every figure below is derived
        // from this single snapshot so the page cannot disagree with itself.
        let snapshot = snapshot(currency: currencyCode)
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 0) {
            header(snapshot)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    totalsStrip(snapshot)
                    distributionSection(snapshot)
                    accountGrid(snapshot, columnCount: geometry.size.width >= 660 ? 2 : 1)
                    footnote
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $cashEditor) { target in
            AccountCashEditorSheet(target: target)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(overviewCopy("全部账号总览", "All accounts overview"))
    }

    // MARK: - Header

    private func header(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(overviewCopy("账号总览", "Accounts overview"))
                    .font(.system(size: 20, weight: .semibold))
                Text(overviewCopy("现金 · 持仓 · 计划", "Cash · Holdings · Plans"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(snapshot.rows.first?.currencyCode ?? "CNY")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                accountFilterPicker
                currencyPicker(snapshot)
                Spacer(minLength: 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                accountFilterPicker
                currencyPicker(snapshot)
            }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var accountFilterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(AccountFilter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    @ViewBuilder
    private func currencyPicker(_ snapshot: Snapshot) -> some View {
        let currencies = snapshot.currencies
        if currencies.count > 1 {
            Picker("", selection: Binding(
                get: { currencies.contains(currencyCode ?? "") ? currencyCode! : currencies[0] },
                set: { currencyCode = $0 }
            )) {
                ForEach(currencies, id: \.self) { code in
                    Text(code).tag(code)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        } else {
            // A single currency is a fact, not a choice: showing a one-item
            // control would only add a target the user cannot act on.
            Text(currencies.first ?? "CNY")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }

    // MARK: - Totals strip

    private func totalsStrip(_ snapshot: Snapshot) -> some View {
        let totals = totals(snapshot)
        let currency = activeCurrency(snapshot)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                totalBlock(
                    overviewCopy("已录现金", "Recorded cash"),
                    cashTotalText(totals, currency),
                    detail: cashTotalDetail(totals, currency),
                    isWarning: totals.hasKnownCash && !totals.allCashKnown
                )
                totalBlock(
                    overviewCopy("可估持仓市值", "Priced holdings"),
                    holdingValueText(totals, currency),
                    detail: quoteDetail(totals, currency),
                    isWarning: totals.missingQuotes > 0
                )
                totalBlock(
                    overviewCopy("计划买入", "Planned buys"),
                    planText(totals.plannedBuy, present: totals.hasPlannedBuy, currency),
                    detail: totals.hasPlannedBuy
                        ? overviewCopy("剩余意向", "Remaining intent")
                        : overviewCopy("无待执行买入", "No open buys"),
                    isWarning: false, tint: PlanSideStyle.buy
                )
                totalBlock(
                    overviewCopy("计划卖出", "Planned sells"),
                    planText(totals.plannedSell, present: totals.hasPlannedSell, currency),
                    detail: totals.hasPlannedSell
                        ? overviewCopy("剩余意向", "Remaining intent")
                        : overviewCopy("无待执行卖出", "No open sells"),
                    isWarning: false, tint: PlanSideStyle.sell
                )
            }

            Text(grossCapitalNote(totals, currency))
                .font(.system(size: 10))
                .foregroundStyle(totals.recordedFunds == nil ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(overviewCopy(
                "市值与现金按同一币种分别汇总；不同币种不做换算，也不相加。",
                "Value and cash are summed per currency; currencies are never converted or added together."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func totalBlock(
        _ label: String,
        _ value: String,
        detail: String,
        isWarning: Bool,
        tint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(isWarning ? AnyShapeStyle(Color.orange) : (tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary)))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(isWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Never renders an assumed zero. A recorded 0 is printed as 0; an account
    /// with no balance recorded is excluded from the subtotal and named.
    private func cashTotalText(_ totals: CurrencyTotals, _ currency: String) -> String {
        guard totals.cash.isFinite else { return "—" }
        guard totals.hasKnownCash else { return overviewCopy("未录", "Not recorded") }
        return PriceFormatter.money(totals.cash, currencyCode: currency)
    }

    private func cashTotalDetail(_ totals: CurrencyTotals, _ currency: String) -> String {
        guard totals.hasKnownCash else {
            return overviewCopy(
                "\(totals.accountCount) 个账号都未录现金",
                "No cash recorded in \(totals.accountCount) accounts"
            )
        }
        guard totals.allCashKnown else {
            return overviewCopy(
                "小计不含未录账号 · \(totals.unknownCashCount) 账号未录现金",
                "Subtotal excludes unrecorded · \(totals.unknownCashCount) account(s) missing cash"
            )
        }
        return overviewCopy("\(totals.knownCashCount) 个账号已录", "Recorded in \(totals.knownCashCount) account(s)")
    }

    private func holdingValueText(_ totals: CurrencyTotals, _ currency: String) -> String {
        guard !totals.hasOverflow else { return "—" }
        return PriceFormatter.money(totals.holdingValue, currencyCode: currency)
    }

    private func quoteDetail(_ totals: CurrencyTotals, _ currency: String) -> String {
        if totals.hasOverflow { return overviewCopy("数值超出范围，不显示", "Out of range; not shown") }
        var parts: [String] = []
        if totals.missingQuotes > 0 {
            parts.append(overviewCopy("\(totals.missingQuotes) 缺价未计入", "\(totals.missingQuotes) missing, excluded"))
        }
        if totals.staleQuotes > 0 {
            parts.append(overviewCopy("\(totals.staleQuotes) 旧价参考", "\(totals.staleQuotes) stale, reference"))
        }
        return parts.isEmpty ? overviewCopy("全部按当前/收盘参考价", "All at current or closing reference") : parts.joined(separator: " · ")
    }

    private func planText(_ value: Double, present: Bool, _ currency: String) -> String {
        guard present, value.isFinite else { return "—" }
        return PriceFormatter.money(value, currencyCode: currency)
    }

    /// The one sentence that stops gross capital from reading as net worth.
    private func grossCapitalNote(_ totals: CurrencyTotals, _ currency: String) -> String {
        guard let recorded = totals.recordedFunds else {
            return overviewCopy(
                "账面记录资金：持仓市值 + 已录现金，不含融资负债（非净资产）。现金或市值不完整时不予合计。",
                "Recorded capital = priced holdings + recorded cash, excluding margin debt (not net worth). It is withheld while cash or values are incomplete."
            )
        }
        return overviewCopy(
            "账面记录资金 \(PriceFormatter.money(recorded, currencyCode: currency)) = 持仓市值 + 已录现金，不含融资负债（非净资产）。",
            "Recorded capital \(PriceFormatter.money(recorded, currencyCode: currency)) = priced holdings + recorded cash, excluding margin debt (not net worth)."
        )
    }

    // MARK: - Distribution

    /// Which account owns what share of the priced holding value, in one
    /// currency. It is deliberately a plain proportional bar list rather than a
    /// chart, and it reports the same missing-quote caveat the totals do.
    private func distributionSection(_ snapshot: Snapshot) -> some View {
        let totals = totals(snapshot)
        let currency = activeCurrency(snapshot)
        let shares = distributionShares(totals: totals, snapshot: snapshot)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(overviewCopy("持仓市值分布", "Holding value distribution"))
                    .font(.system(size: 11, weight: .semibold))
                Text(currency)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(overviewCopy("参考", "Reference"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if shares.isEmpty {
                Text(overviewCopy(
                    "该币种暂无可计价的持仓市值。",
                    "No priced holding value in this currency yet."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            } else {
                ForEach(shares) { share in
                    distributionRow(share, currency: currency)
                }
                if totals.missingQuotes > 0 || totals.staleQuotes > 0 {
                    Text(distributionCaveat(totals))
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    struct DistributionShare: Identifiable {
        let accountID: BrokerageAccountID
        let value: Double
        let fraction: Double
        var id: BrokerageAccountID { accountID }
    }

    private func distributionShares(totals: CurrencyTotals, snapshot: Snapshot) -> [DistributionShare] {
        let denominator = totals.holdingValue
        guard denominator.isFinite, denominator > 0 else { return [] }
        return snapshot.accounts.compactMap { account in
            let value = rows(for: account, in: snapshot)
                .reduce(0.0) { $0 + $1.holdingValue }
            guard value.isFinite, value > 0 else { return nil }
            let fraction = value / denominator
            guard fraction.isFinite else { return nil }
            return DistributionShare(
                accountID: account,
                value: value,
                fraction: min(1, max(0, fraction))
            )
        }
        .sorted { $0.value > $1.value }
    }

    private func distributionRow(_ share: DistributionShare, currency: String) -> some View {
        let percent = share.fraction.formatted(.percent.precision(.fractionLength(1)))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AccountIdentity.dotColor(share.accountID))
                    .frame(width: 6, height: 6)
                Text(AccountIdentity.title(share.accountID))
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 4)
                Text(PriceFormatter.money(share.value, currencyCode: currency))
                    .font(.system(size: 10, design: .monospaced))
                Text(percent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(AccountIdentity.dotColor(share.accountID).opacity(0.85))
                        .frame(width: max(1, geometry.size.width * share.fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    private func distributionCaveat(_ totals: CurrencyTotals) -> String {
        var parts: [String] = []
        if totals.missingQuotes > 0 {
            parts.append(overviewCopy(
                "\(totals.missingQuotes) 个持仓缺价，未计入分布",
                "\(totals.missingQuotes) holding(s) unpriced and excluded"
            ))
        }
        if totals.staleQuotes > 0 {
            parts.append(overviewCopy(
                "\(totals.staleQuotes) 个持仓为旧价参考",
                "\(totals.staleQuotes) holding(s) use a stale reference"
            ))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cards

    private func accountGrid(_ snapshot: Snapshot, columnCount: Int) -> some View {
        let currency = activeCurrency(snapshot)
        // A card is only drawn once, at the top level, for a real account. The
        // legacy archive is handled by `unassignedSection`, so an account that
        // is both unassigned and empty never gets two cards.
        let unassigned = snapshot.accounts.contains(.unassigned)
            ? rows(for: .unassigned, in: snapshot)
            : []
        return VStack(alignment: .leading, spacing: 12) {
            if cardAccounts(snapshot).isEmpty {
                emptyScopeNotice
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount),
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(cardAccounts(snapshot), id: \.self) { account in
                        AccountCard(
                            account: account,
                            currencyCode: currency,
                            rows: rows(for: account, in: snapshot),
                            onEditCash: { code in
                                cashEditor = CashEditorTarget(accountID: account, currencyCode: code)
                            },
                            onOpenPage: { page in
                                select(account)
                                onShowPage(page)
                            }
                        )
                    }
                }
            }

            if !unassigned.isEmpty {
                unassignedSection(unassigned)
            }
        }
    }

    private var emptyScopeNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(overviewCopy("该筛选下没有账号内容", "Nothing in this filter"))
                .font(.system(size: 12, weight: .medium))
            Text(overviewCopy(
                "换一个账号筛选，或在下方为账号记录现金。",
                "Pick another account filter, or record cash against an account below."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 历史未归属 is collapsed unless the user is explicitly filtering for it:
    /// it is a leftover archive, not a working account, and it must not push the
    /// two real accounts off the first screen.
    private func unassignedSection(_ rows: [BrokerageAccountOverviewRow]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { showsUnassigned || filter == .unassigned },
            set: { showsUnassigned = $0 }
        )) {
            VStack(spacing: 10) {
                ForEach(rows) { row in
                    AccountCard(
                        account: .unassigned,
                        currencyCode: row.currencyCode,
                        rows: [row],
                        onEditCash: { code in
                            cashEditor = CashEditorTarget(accountID: .unassigned, currencyCode: code)
                        },
                        onOpenPage: { page in
                            select(.unassigned)
                            onShowPage(page)
                        }
                    )
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: AccountIdentity.symbolName(.unassigned))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(overviewCopy("历史未归属", "Legacy unassigned"))
                    .font(.system(size: 11, weight: .semibold))
                Text(overviewCopy("尚未分配到具体账号", "Not yet assigned to an account"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(overviewCopy(
                "计划金额为意向总额，不从现金中预扣。",
                "Planned amounts are intended totals and are not pre-deducted from cash."
            ))
            Text(overviewCopy(
                "融资标注是单笔交易的属性，与账号归属无关。",
                "The margin tag describes one trade; it is independent of account ownership."
            ))
            Text(overviewCopy(
                "缺价持仓不计入市值；旧价（收盘/参考）计入并标注。",
                "Unpriced holdings are excluded from value; stale (closing/reference) prices are included and marked."
            ))
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    /// The only place this page moves the app's scope. Selecting an already
    /// active account is deliberately still allowed to navigate: the user asked
    /// for a page, not for a scope change, and returning `false` must not eat
    /// their click.
    private func select(_ account: BrokerageAccountID) {
        _ = appState.selectBrokerageAccount(account)
    }
}

// MARK: - Account card

/// One account's card. It shows a single currency at a time — the one the page
/// has selected — because a card that printed ¥ and $ on adjacent lines would
/// invite exactly the addition this page refuses to make.
private struct AccountCard: View {
    let account: BrokerageAccountID
    let currencyCode: String
    let rows: [BrokerageAccountOverviewRow]
    let onEditCash: (String) -> Void
    let onOpenPage: (MainWorkspacePage) -> Void

    @Environment(AppState.self) private var appState
    @State private var hovering = false
    @State private var showsBreakdown = false

    /// Mengmeng buys are ordinary by construction, so its card has no funding
    /// split to disclose: the toggle and the breakdown are both withheld, while
    /// the aggregate planned-buy figure and the cash/holding composition stay.
    /// This reads the card's own account, never a global selection.
    private var offersFundingBreakdown: Bool { account != .mengmeng }

    private enum AccountCardError: Error { case refused }

    private var row: BrokerageAccountOverviewRow {
        rows.first { $0.currencyCode == currencyCode }
            ?? BrokerageAccountOverviewRow(accountID: account, currencyCode: currencyCode)
    }

    private var holdingLine: String {
        guard row.holdingsCount > 0 else { return overviewCopy("暂无持仓", "No holdings") }
        var parts = [overviewCopy("\(row.holdingsCount) 标的", "\(row.holdingsCount) instruments")]
        if row.staleQuotes > 0 { parts.append(overviewCopy("\(row.staleQuotes) 旧价", "\(row.staleQuotes) stale")) }
        if row.missingQuotes > 0 { parts.append(overviewCopy("\(row.missingQuotes) 缺价", "\(row.missingQuotes) missing")) }
        return parts.joined(separator: " · ")
    }

    private var hasQuoteCaveat: Bool { row.missingQuotes > 0 || row.staleQuotes > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identityRow
            moneyRow
            if showsBreakdown && offersFundingBreakdown { breakdownRow }
            compositionBar
            actionRow
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(hovering ? 0.16 : 0.07), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(AccountIdentity.dotColor(account))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Image(systemName: AccountIdentity.symbolName(account))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(AccountIdentity.title(account))
                    .font(.system(size: 13, weight: .semibold))
                Text(holdingLine)
                    .font(.system(size: 10))
                    .foregroundStyle(hasQuoteCaveat ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(currencyCode)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var moneyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(overviewCopy("现金", "Cash"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(cashText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(row.cash == nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                Button {
                    onEditCash(currencyCode)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 10))
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(overviewCopy("记录或清除该账号的现金", "Record or clear this account's cash"))
                Spacer(minLength: 4)
            }

            HStack(spacing: 10) {
                moneyFact(overviewCopy("持仓市值", "Holdings"), holdingText, tint: hasQuoteCaveat ? .orange : nil)
                moneyFact(overviewCopy("计划买入", "Planned buy"), planText(row.plannedBuy), tint: row.plannedBuy > 0 ? PlanSideStyle.buy : nil)
                moneyFact(overviewCopy("计划卖出", "Planned sell"), planText(row.plannedSell), tint: row.plannedSell > 0 ? PlanSideStyle.sell : nil)
            }

            if hasQuoteCaveat {
                Text(quoteBadge)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.hasOverflow {
                Text(overviewCopy("数值超出范围，市值不予显示", "Value out of range; not shown"))
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if row.plannedBuy > 0 && offersFundingBreakdown {
                Button {
                    showsBreakdown.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsBreakdown ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(overviewCopy("买入资金来源明细", "Buy funding breakdown"))
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func moneyFact(_ label: String, _ value: String, tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// own / margin / unmarked are three different answers to "where will this
    /// money come from", and the card keeps them apart. It never guesses how
    /// much borrowing is available: these are the user's own annotations.
    ///
    /// The `.own` row is named through the same account-aware helper the rest of
    /// the funding language uses — 担保品 inside the financing account, 普通买入
    /// elsewhere — so one stored value does not acquire two vocabularies.
    private var breakdownRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if row.ownBuy > 0 {
                breakdownLine(fundingSourceTitle(.own, account: account), row.ownBuy, .secondary)
            }
            if row.marginBuy > 0 {
                breakdownLine(overviewCopy("融资", "Margin"), row.marginBuy, .orange)
            }
            if row.unmarkedBuy > 0 {
                breakdownLine(overviewCopy("未标注", "Unmarked"), row.unmarkedBuy, .secondary)
            }
            Text(overviewCopy(
                "标注来自计划，仅用于账号规划，不代表可融资额度。",
                "Annotations come from the plans; they are planning hints, not available credit."
            ))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func breakdownLine(_ label: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(tint)
            Spacer(minLength: 4)
            Text(PriceFormatter.money(value, currencyCode: currencyCode))
                .font(.system(size: 9, design: .monospaced))
        }
    }

    /// Cash vs priced holdings, in this currency, as a reference split. It is
    /// skipped — with the reason named — whenever cash is unrecorded or there is
    /// no positive gross to divide.
    @ViewBuilder
    private var compositionBar: some View {
        let gross = gross
        if let gross {
            let cashFraction = min(1, max(0, (row.cash?.amount ?? 0) / gross))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(overviewCopy("资金构成（已计价部分）", "Composition (priced portion)"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    if row.staleQuotes > 0 {
                        Text(overviewCopy("含旧价参考", "incl. stale"))
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    Text(overviewCopy("现金 ", "Cash ") + cashFraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(AccountIdentity.dotColor(account).opacity(0.55))
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: max(1, geometry.size.width * cashFraction))
                    }
                }
                .frame(height: 6)
            }
        } else {
            Text(overviewCopy(
                row.cash == nil
                    ? "未录现金，暂不显示资金构成"
                    : (row.missingQuotes > 0 ? "部分持仓缺价，暂不显示资金构成" : "暂不显示资金构成"),
                row.cash == nil
                    ? "Cash not recorded; composition hidden"
                    : (row.missingQuotes > 0 ? "Some holdings are unpriced; composition hidden" : "Composition unavailable")
            ))
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            Button(overviewCopy("仓位池", "Pools")) { onOpenPage(.positionPools) }
            Button(overviewCopy("持仓", "Holdings")) { onOpenPage(.holdings) }
            Button(overviewCopy("制定计划", "Plans")) { onOpenPage(.plans) }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.system(size: 10))
    }

    private var gross: Double? {
        guard !row.hasOverflow, row.missingQuotes == 0, let cash = row.cash, cash.amount.isFinite else { return nil }
        let value = row.holdingValue + cash.amount
        return value.isFinite && value > 0 ? value : nil
    }

    private var cashText: String {
        guard let cash = row.cash else { return overviewCopy("未录", "Not recorded") }
        return PriceFormatter.money(cash.amount, currencyCode: currencyCode)
    }

    private var holdingText: String {
        guard !row.hasOverflow else { return "—" }
        return PriceFormatter.money(row.holdingValue, currencyCode: currencyCode)
    }

    private func planText(_ value: Double) -> String {
        value > 0 ? PriceFormatter.money(value, currencyCode: currencyCode) : "—"
    }

    private var quoteBadge: String {
        var parts: [String] = []
        if row.missingQuotes > 0 {
            parts.append(overviewCopy("\(row.missingQuotes) 缺价未计入市值", "\(row.missingQuotes) missing, excluded from value"))
        }
        if row.staleQuotes > 0 {
            parts.append(overviewCopy("\(row.staleQuotes) 旧价参考（已计入）", "\(row.staleQuotes) stale reference (included)"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Cash editor

/// Records one account's cash in one currency.
///
/// The account and the currency are **frozen** when the sheet opens. The user is
/// editing a specific line on a specific card; nothing here reads the currently
/// selected account, so confirming can never land the amount in a different
/// ledger than the one whose pencil was clicked.
///
/// `internal` rather than `private` only so the debug render harness can capture
/// it standalone; nothing else in the app constructs it.
struct AccountCashEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let target: BrokerageAccountOverviewView.CashEditorTarget

    @State private var amountText = ""
    @State private var errorMessage: String?

    private var existing: CashBalance? {
        appState.poolBudgets.cashBalances(for: target.accountID)[target.currencyCode]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(overviewCopy("记录现金", "Record cash"))
                    .font(.system(size: 13, weight: .semibold))
                // The account is named here and nowhere else is it editable:
                // this sheet cannot switch accounts.
                Text("\(AccountIdentity.title(target.accountID)) · \(target.currencyCode)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(overviewCopy(
                    "只记录该账号该币种的现金余额，不改变当前所选账号。",
                    "Records this account's cash in this currency only; it does not change the selected account."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(target.currencyCode)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(overviewCopy("金额", "Amount"), text: $amountText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .onSubmit { confirm() }
                if let existing {
                    Text(overviewCopy(
                        "当前 \(PriceFormatter.money(existing.amount, currencyCode: target.currencyCode))",
                        "Now \(PriceFormatter.money(existing.amount, currencyCode: target.currencyCode))"
                    ))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text(overviewCopy("当前未录", "Not recorded"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(overviewCopy(
                "现金是可选的记录，不是必须的数字；留空并清除即可回到未录。",
                "Cash is optional; clearing it returns the line to not recorded."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(overviewCopy("清除记录", "Clear")) { clear() }
                    .disabled(existing == nil)
                Spacer(minLength: 4)
                Button(overviewCopy("取消", "Cancel")) { dismiss() }
                Button(overviewCopy("确认", "Confirm")) { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            amountText = existing.map { Self.fieldText($0.amount) } ?? ""
        }
    }

    /// Parses a plain decimal. Anything non-finite, negative, or unparseable is
    /// refused with a message instead of being coerced to a number the user did
    /// not type.
    private func parsedAmount() -> Double? {
        let cleaned = amountText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func confirm() {
        guard let amount = parsedAmount() else {
            errorMessage = overviewCopy(
                "请输入不小于 0 的有效数字。",
                "Enter a valid number that is zero or greater."
            )
            return
        }
        let ok = appState.poolBudgets.setCashBalance(
            amount: amount,
            currency: target.currencyCode,
            in: target.accountID
        )
        guard ok else {
            errorMessage = overviewCopy("无法写入该账号的现金记录。", "Could not write this account's cash record.")
            return
        }
        dismiss()
    }

    private func clear() {
        let ok = appState.poolBudgets.setCashBalance(
            amount: nil,
            currency: target.currencyCode,
            in: target.accountID
        )
        guard ok else {
            errorMessage = overviewCopy("无法清除该账号的现金记录。", "Could not clear this account's cash record.")
            return
        }
        dismiss()
    }

    private static func fieldText(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let text = String(value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

// MARK: - Copy

private func overviewCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}
