import SwiftUI
import PulseCore
import PulseUI

/// Position hub: the summary, trade actions, and recent transactions for one
/// holding. Pushed from the detail page (or list); buy/sell/log/quick-set
/// pages push from here and pop back here.
struct PositionHubView: View {
    /// How many trades the summary lists before the full log takes over. The
    /// page height in `PopoverRootView` is budgeted from the same number, so
    /// the two have to move together.
    static let visibleTransactionCount = 6

    /// One `TransactionRow`: an 11pt line plus its 5pt vertical padding.
    static let transactionRowHeight: CGFloat = 24

    /// Everything above the trade rows on a held position — header, P&L cells,
    /// stats, separators, the funding composition line, the trade buttons, and
    /// the section title — measured from the shipped layout. The old fixed
    /// 420pt page left 40pt of dead space under three rows; the page height is
    /// now this plus one `transactionRowHeight` per row actually shown.
    ///
    /// The composition row is one 12pt line with an 8pt top gap, so it adds 20pt
    /// to the budget; it renders only when the holding carries a funding
    /// annotation or is awaiting review.
    static let compositionRowHeight: CGFloat = 20
    static let summaryHeightAboveTrades: CGFloat = 312 + compositionRowHeight

    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    let symbol: SymbolID
    let returnRoute: PositionReturnRoute
    @Binding var route: PopoverRoute

    private var item: WatchItem? { appState.watchlist.item(for: symbol) }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }
    /// The ledger this page is describing, used only to pick the right words for
    /// a funding state — never to change a quantity or a total.
    private var activeAccount: BrokerageAccountID { appState.watchlist.activeBrokerageAccountID }

    var body: some View {
        VStack(spacing: 0) {
            PositionPageHeader(
                symbol: symbol,
                title: nil,
                accountCaption: AccountIdentity.title(appState.watchlist.activeBrokerageAccountID),
                onBack: { route = returnRoute.popoverRoute },
                // In the menu-bar panel the action remains in the page row. The
                // pinned window promotes it to the title bar below.
                onEdit: host == .menuBar && item?.hasPosition == true
                    ? { route = .calibrate(symbol, returnRoute) }
                    : nil
            )
            if let item {
                if item.hasPosition {
                    openPositionBody(item)
                } else {
                    emptyBody(item)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar {
            if host == .pinnedWindow, item?.hasPosition == true {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        route = .calibrate(symbol, returnRoute)
                    } label: {
                        Label(
                            PulseLocalization.localizedString("position.quickEditTitle"),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .help(PulseLocalization.localizedString("position.quickEditTitle"))
                }
            }
        }
    }

    // MARK: - Open position

    @ViewBuilder
    private func openPositionBody(_ item: WatchItem) -> some View {
        let basis = appState.settings.positionCostBasis
        let quote = self.quote
        let valuation = quote.flatMap { PositionValuation(item: item, quote: $0, basis: basis) }
        let combinedPnL = valuation?.totalPnL
        VStack(alignment: .leading, spacing: 0) {
            if let valuation {
                // Two columns, not three: the combined figure sits beside the
                // realized one it is made of, and a third cell here squeezes
                // all of them until the amounts truncate.
                HStack(spacing: 8) {
                    pnlCell(PulseLocalization.localizedString("metric.todayPnL"),
                            amount: valuation.todayPnL, percent: valuation.todayReturnPercent)
                    pnlCell(PulseLocalization.localizedString("metric.totalPnL"),
                            amount: valuation.holdingPnL, percent: valuation.holdingReturnPercent)
                }
                HStack(spacing: 8) {
                    stat(PulseLocalization.localizedString("position.quantity"), PriceFormatter.quantity(valuation.quantity))
                    costBasisStat(value: valuation.costPrice, basis: basis)
                    stat(PulseLocalization.localizedString("position.marketValue"), PriceFormatter.money(valuation.marketValue, currencyCode: currencyCode))
                }
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(PulseLocalization.localizedString("position.waitingQuote"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        stat(PulseLocalization.localizedString("position.quantity"), PriceFormatter.quantity(item.positionQuantity))
                        let averageCost = item.averageCost ?? 0
                        let costPrice = basis == .diluted ? item.ledger?.dilutedCost ?? averageCost : averageCost
                        costBasisStat(value: costPrice, basis: basis)
                        stat(PulseLocalization.localizedString("position.marketValue"), "—")
                    }
                }
                .padding(.vertical, 6)
            }
            HStack(spacing: 8) {
                realizedStat(item, basis: basis)
                combinedPnLStat(combinedPnL)
                totalFeesStat(item)
            }
            .padding(.top, 10)

            // Mengmeng has no funding axis at all: its buys are ordinary by
            // construction, so a composition line there would report a choice
            // the account never made. The calculation itself is untouched.
            if activeAccount != .mengmeng, let composition = fundingComposition(item) {
                fundingCompositionRow(composition)
                    .padding(.top, 8)
            }

            separator

            tradeButtons(recordStyle: false)

            separator

            recentTransactions(item)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Funding composition

    /// The per-source share counts for one holding, or `nil` when there is
    /// nothing to say.
    ///
    /// It reads the live allocation rather than any trade's annotation, because
    /// the allocation is what the pools actually show; summing transactions
    /// would report a composition that does not match the cards. A `nil` source
    /// is counted under "not annotated" — an old portion is unknown, never a
    /// guess at margin.
    struct FundingComposition {
        var own: Double = 0
        var margin: Double = 0
        var unmarked: Double = 0
        var needsReview: Bool

        var isEmpty: Bool { own == 0 && margin == 0 && unmarked == 0 && !needsReview }
    }

    private func fundingComposition(_ item: WatchItem) -> FundingComposition? {
        guard item.positionQuantity > 0 else { return nil }
        let needsReview = item.positionAllocationNeedsReconciliation
        guard let allocation = item.positionAllocation, !needsReview else {
            // Nothing to break down, but the holding still has a funding state
            // worth stating: "awaiting review" is a real answer and must not be
            // rendered as an all-zero composition, which would read as "no
            // margin".
            return needsReview ? FundingComposition(needsReview: true) : nil
        }
        var composition = FundingComposition(needsReview: false)
        for portion in allocation.portions {
            switch portion.fundingSource {
            case .some(.own): composition.own += portion.quantity
            case .some(.margin): composition.margin += portion.quantity
            case .some(.unmarked), .none: composition.unmarked += portion.quantity
            }
        }
        return composition.isEmpty ? nil : composition
    }

    @ViewBuilder
    private func fundingCompositionRow(_ composition: FundingComposition) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(composition.margin > 0 ? PoolFundingStyle.marginTint : .secondary)
            Text(poolCopy("来源构成", "Funding"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if composition.needsReview {
                Text(poolCopy("分账待核对，来源构成未确认", "Allocation needs review; composition unconfirmed"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                // Compact, in a fixed order, so the three numbers are
                // comparable between holdings at a glance. Only non-zero parts
                // are printed; a zero would be noise, and "not annotated" is
                // itself the meaningful absence.
                Text(compositionParts(composition, account: activeAccount))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .help(poolCopy("按份额卡的资金来源汇总；不是融资余额或净资产。",
                       "Summed from portion funding annotations. Not a broker balance or net worth."))
    }

    private func compositionParts(_ composition: FundingComposition,
                                  account: BrokerageAccountID) -> String {
        var parts: [String] = []
        if composition.own > 0 {
            // "Ordinary" and "collateral" name the same stored `.own` value. In
            // the financing account the shares are the collateral the account
            // holds; everywhere else they are simply ordinary buys.
            parts.append(fundingSourceTitle(.own, account: account)
                         + " " + PriceFormatter.quantity(composition.own))
        }
        if composition.margin > 0 {
            parts.append(poolCopy("融资 ", "Margin ") + PriceFormatter.quantity(composition.margin))
        }
        if composition.unmarked > 0 {
            parts.append(poolCopy("未标注 ", "Unannotated ") + PriceFormatter.quantity(composition.unmarked))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func recentTransactions(_ item: WatchItem) -> some View {
        let entries = Array((item.ledger?.entries ?? []).reversed())
        VStack(alignment: .leading, spacing: 0) {
            // The header row is the way into the full log: a trailing chevron
            // instead of a separate link line under the rows.
            if entries.isEmpty {
                sectionHeader(disclosing: false)
                Text(PulseLocalization.localizedString("position.noTransactions"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                Button {
                    route = .transactions(symbol, returnRoute)
                } label: {
                    sectionHeader(disclosing: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                ForEach(entries.prefix(Self.visibleTransactionCount)) { entry in
                    TransactionRow(
                        entry: entry,
                        palette: appState.palette,
                        currencyCode: currencyCode,
                        onOpen: { route = .editTrade(symbol, entry.transaction.id, returnRoute) }
                    )
                }
            }
        }
    }

    private func sectionHeader(disclosing: Bool) -> some View {
        HStack(spacing: 4) {
            Text(PulseLocalization.localizedString("position.recentTransactions"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if disclosing {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 3)
    }

    // MARK: - No open position

    /// Never held and sold out are different situations. Only the first one
    /// needs the pitch for recording trades; the second one has trades to show,
    /// and gets the same shape as an open position minus the market numbers.
    @ViewBuilder
    private func emptyBody(_ item: WatchItem) -> some View {
        if item.transactions.isEmpty {
            onboardingBody()
        } else {
            closedBody(item)
        }
    }

    @ViewBuilder
    private func closedBody(_ item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(PulseLocalization.localizedString("position.closed"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                stat(
                    PulseLocalization.localizedString("position.realizedPnL"),
                    PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
                    color: item.realizedPnL
                )
                .help(PulseLocalization.localizedString("position.realizedPnLHelp"))
                stat(
                    PulseLocalization.localizedString("position.historyTrades"),
                    PulseLocalization.localizedString("position.tradeCount", item.transactions.count)
                )
                totalFeesStat(item)
            }
            .padding(.top, 8)

            separator

            tradeButtons(recordStyle: true)

            separator

            recentTransactions(item)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func onboardingBody() -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "briefcase")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.quaternary)
                    .padding(.bottom, 2)
                Text(PulseLocalization.localizedString("position.empty.title"))
                    .font(.system(size: 12, weight: .semibold))
                Text(PulseLocalization.localizedString("position.empty.subtitle"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 14)
            .padding(.bottom, 14)

            tradeButtons(recordStyle: true)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Trade actions

    /// Buy/sell as flat tinted buttons sharing the input cells' DNA (fill +
    /// hairline stroke on continuous corners) — glass here read as a heavier
    /// material than the rest of this quiet page. The tint follows the user's
    /// up/down palette so "buy" always reads as the up color. Both sides show
    /// even with no position — selling first opens a short.
    private func tradeButtons(recordStyle: Bool) -> some View {
        HStack(spacing: 8) {
            tradeButton(
                PulseLocalization.localizedString(recordStyle ? "trade.recordBuy" : "trade.buy"),
                color: appState.palette.color(isUp: true)
            ) {
                route = .trade(symbol, .buy, returnRoute)
            }
            tradeButton(
                PulseLocalization.localizedString(recordStyle ? "trade.recordSell" : "trade.sell"),
                color: appState.palette.color(isUp: false)
            ) {
                route = .trade(symbol, .sell, returnRoute)
            }
        }
    }

    private func tradeButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - Cells (mirrors the detail page's stat styling)

    private var separator: some View {
        Rectangle()
            .fill(.separator.opacity(0.55))
            .frame(height: 0.5)
            .padding(.vertical, 12)
    }

    private func pnlCell(_ label: String, amount: Double, percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(PriceFormatter.signedMoney(amount, currencyCode: currencyCode))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                Text(PriceFormatter.percent(percent))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .opacity(0.9)
            }
            .foregroundStyle(appState.palette.color(for: amount))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cost cell doubles as the switch between the two bases: the moment
    /// someone wants the other number is the moment they are looking at this
    /// one. There are only two, so a click flips straight to the other instead
    /// of opening a menu — a Menu measures its label to fit and clipped the
    /// value away entirely.
    private func costBasisStat(value: Double, basis: PositionCostBasis) -> some View {
        Button {
            appState.settings.positionCostBasis = basis == .average ? .diluted : .average
        } label: {
            stat(PulseLocalization.localizedString(basis.labelKey), PriceFormatter.price(value))
        }
        .buttonStyle(.plain)
        .help(PulseLocalization.localizedString("position.costBasisHelp"))
    }

    private func realizedStat(_ item: WatchItem, basis _: PositionCostBasis) -> some View {
        return stat(
            PulseLocalization.localizedString("position.realizedPnL"),
            PriceFormatter.signedMoney(item.realizedPnL, currencyCode: currencyCode),
            color: item.transactions.isEmpty ? nil : item.realizedPnL
        )
        .help(PulseLocalization.localizedString("position.realizedPnLHelp"))
    }

    private func combinedPnLStat(_ value: Double?) -> some View {
        guard let value else {
            return stat(PulseLocalization.localizedString("position.combinedPnL"), "—")
        }
        return stat(
            PulseLocalization.localizedString("position.combinedPnL"),
            PriceFormatter.signedMoney(value, currencyCode: currencyCode),
            color: value
        )
    }

    /// Fees are optional, so an account that has never recorded one shows a
    /// dash rather than a zero that reads like a measured value.
    private func totalFeesStat(_ item: WatchItem) -> some View {
        let fees = item.ledger?.totalFees ?? 0
        return stat(
            PulseLocalization.localizedString("position.totalFees"),
            fees > 0 ? PriceFormatter.money(fees, currencyCode: currencyCode) : "—"
        )
    }

    private func stat(_ label: String, _ value: String, color: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10.5, weight: color == nil ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(color.map { appState.palette.color(for: $0) } ?? .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared position-page chrome

/// Back chevron + instrument identity, matching the detail page's header row.
struct PositionPageHeader: View {
    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    let symbol: SymbolID
    /// Search drafts may not have a persisted instrument name yet.
    var displayName: String? = nil
    /// Optional leading emphasis ("买入"/"卖出"), tinted by the caller.
    var title: (text: String, color: Color)?
    /// The account this page is writing into, named in the chrome.
    ///
    /// A plan or a trade is written into whichever ledger is *currently*
    /// selected, and the account can only change from the toolbar — which
    /// resets the draft. Naming it here is what stops a form from being filled
    /// in for one account and confirmed into another.
    var accountCaption: String?
    let onBack: () -> Void
    /// Optional trailing edit affordance (the hub's quick-set entry).
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left", help: PulseLocalization.localizedString("action.backHelp")) {
                onBack()
            }
            HStack(spacing: 6) {
                if let title {
                    Text(title.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(title.color)
                        .fixedSize()
                }
                Text(displayName ?? appState.displayName(for: symbol))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                MarketBadge(market: symbol.market)
                    .fixedSize()
                Text(symbol.displayCode)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let accountCaption {
                // Fixed and secondary: an account is identity, not an alert, so
                // it never competes with the instrument name or the side colour.
                Text(accountCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(accountCaption)
            }
            if let onEdit {
                ClusterIcon(
                    systemName: "square.and.pencil",
                    help: PulseLocalization.localizedString("position.quickEditTitle")
                ) {
                    onEdit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, host == .pinnedWindow ? 2 : 12)
        .padding(.bottom, host == .pinnedWindow ? 7 : 10)
    }
}

/// One transaction line: date, kind badge, quantity @ price (sells append
/// their realized P&L), and the trade amount. With `onOpen` set the whole
/// row is a button that opens the entry's edit page, which is also where it
/// gets deleted — one path for both, no hidden context menu to discover.
struct TransactionRow: View {
    let entry: PositionLedger.Entry
    let palette: ChangePalette
    let currencyCode: String?
    var onOpen: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        if let onOpen {
            Button(action: onOpen) {
                row
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                            .padding(.horizontal, -6)
                    )
            }
            .buttonStyle(.pressable)
            .onHover { hovering = $0 }
            .help(editHelp)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(PositionDateFormat.monthDay(entry.transaction.date))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            TradeKindBadge(kind: entry.transaction.kind, palette: palette)
            (Text("\(PriceFormatter.quantity(entry.transaction.quantity)) @ \(PriceFormatter.price(entry.transaction.price))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.primary)
             + realizedSuffix)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var realizedSuffix: Text {
        guard let realized = entry.realizedPnL else { return Text("") }
        return Text("  \(PriceFormatter.signedMoney(realized, currencyCode: currencyCode))")
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(palette.color(for: realized))
    }

    /// The row is a single line at the panel's width and has no room left for
    /// a fee column, so a recorded fee is reported on hover instead.
    private var editHelp: String {
        let edit = PulseLocalization.localizedString("trade.editTitle")
        guard let fee = entry.transaction.fee, fee > 0 else { return edit }
        return edit + "\n" + PulseLocalization.localizedString(
            "trade.feeAmount",
            PriceFormatter.money(fee, currencyCode: currencyCode)
        )
    }

    @ViewBuilder
    private var trailing: some View {
        if entry.transaction.kind == .adjustment {
            Text(PulseLocalization.localizedString("transaction.overwrite"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Text(PriceFormatter.money(
                entry.transaction.price * entry.transaction.quantity,
                currencyCode: currencyCode
            ))
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

struct TradeKindBadge: View {
    let kind: PositionTransaction.Kind
    let palette: ChangePalette

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(kind == .adjustment ? 0.12 : 0.15))
            )
    }

    private var label: String {
        switch kind {
        case .buy: PulseLocalization.localizedString("transaction.kind.buy")
        case .sell: PulseLocalization.localizedString("transaction.kind.sell")
        case .adjustment: PulseLocalization.localizedString("transaction.kind.adjustment")
        }
    }

    private var color: Color {
        switch kind {
        case .buy: palette.color(isUp: true)
        case .sell: palette.color(isUp: false)
        case .adjustment: .secondary
        }
    }
}

/// Compact numeric input cell shared by the trade form and quick-set editor:
/// label above, monospaced input below — same DNA as the hub's stat cells,
/// sized for a short number rather than a full-width system form row.
struct PositionInputCell: View {
    /// A value the user would otherwise retype, offered as a chip beside the
    /// label. One click drops it into the field and gives focus back, so
    /// Return or the confirm button records the trade without another step.
    /// The chip shows exactly the text the field will receive.
    struct Suggestion {
        var label: String
        var help: String
        var fill: () -> Void
    }

    @Environment(\.colorScheme) private var colorScheme
    let label: String
    @Binding var text: String
    /// Small trailing note beside the label (e.g. a warning).
    var hint: String?
    var hintIsWarning = false
    var suggestion: Suggestion?
    var autofocus = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let hint {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(hintIsWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
                if let suggestion {
                    SuggestionChip(suggestion: suggestion) { isFocused = false }
                }
            }
            // A chip stands taller than the 9pt label; a fixed row height keeps
            // the two side-by-side cells' fields level whether or not each has one.
            .frame(height: 14)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .focused($isFocused)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isFocused
                        ? AnyShapeStyle(Color.accentColor.opacity(0.6))
                        : AnyShapeStyle(.separator.opacity(0.5)),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .task {
            // Grabbing focus mid-push fails while the panel is still
            // animating; land it just after the 0.28s route transition.
            guard autofocus else { return }
            try? await Task.sleep(for: .milliseconds(360))
            isFocused = true
        }
    }
}

/// The one-click fill beside a `PositionInputCell` label. Plain caption text
/// gave no sign it could be clicked; a tinted capsule reads as a button and
/// brightens under the pointer.
private struct SuggestionChip: View {
    let suggestion: PositionInputCell.Suggestion
    let afterFill: () -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            suggestion.fill()
            afterFill()
        } label: {
            Text(suggestion.label)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(hovering ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help(suggestion.help)
    }
}

enum PositionDateFormat {
    /// "07-28" — fixed numeric layout matching the app's monospaced columns.
    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }

    /// Localized month group header, e.g. "2026年7月" / "July 2026".
    static func monthGroup(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }
}
