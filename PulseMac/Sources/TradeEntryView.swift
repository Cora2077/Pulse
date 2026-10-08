import SwiftUI
import PulseCore
import PulseUI

/// Single-trade entry: the side is fixed by the entry point, so the form is
/// just price, quantity, and date, with a live preview of the resulting
/// position. Price and quantity share a compact two-cell row (see
/// `PositionInputCell`); the date rests in the app's own chrome and opens a
/// system calendar only on demand.
///
/// With `editing` set the same form edits an existing transaction instead of
/// recording a new one: fields arrive prefilled and saving rewrites the entry
/// in place, preserving its id, kind, and insertion timestamp. Deleting the
/// entry lives here too, bottom-left like the quick-set sheet's clear action,
/// so a recorded trade has one page for everything that can happen to it.
struct TradeEntryView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    private let recordSide: TradeSide
    /// The transaction being edited; nil in record mode.
    private let editing: PositionTransaction?
    let returnRoute: PositionReturnRoute
    @Binding var route: PopoverRoute

    @State private var priceText: String
    @State private var quantityText: String
    @State private var feeText: String
    @State private var date: Date
    @State private var showsCalendar = false
    /// Fresh buys default to ordinary funding; an edit preserves its stored
    /// annotation, including nil on older records. A new buy is never nil: the
    /// shared `BuyAccountMethodFields` offers no empty choice, because a record
    /// being created has no history to preserve.
    @State private var fundingSource: PositionFundingSource?
    /// The ledger a new buy lands in. `nil` until the user picks one; an edit
    /// keeps the transaction's own attribution.
    @State private var selectedBrokerageAccount: BrokerageAccountID?
    /// Daily candles backing the market-closed hint — whatever the detail
    /// chart already cached, or one fetch on first open.
    @State private var dailyCandles: [Candle] = []
    /// Return can reach `save()` twice in one keypress (field submit + default
    /// action); the first write wins so a trade is never recorded twice.
    @State private var didSave = false
    /// A refused write. Only the new-buy path can produce one — the store's
    /// `recordBuyTransaction` is the only call here that reports why it
    /// declined, and the sentence belongs next to the fields rather than in an
    /// alert that dismisses the form the user was filling in.
    @State private var errorMessage: String?
    /// The account this draft belongs to, frozen when the form is built: a
    /// trade is recorded against the ledger the user was filling in, and the
    /// store object survives an account switch with a different ledger inside.
    @State private var draftAccount: BrokerageAccountID

    init(
        symbol: SymbolID,
        side: TradeSide,
        returnRoute: PositionReturnRoute,
        route: Binding<PopoverRoute>,
        account: BrokerageAccountID
    ) {
        self.symbol = symbol
        self.recordSide = side
        self.editing = nil
        self.returnRoute = returnRoute
        self._route = route
        _priceText = State(initialValue: "")
        _quantityText = State(initialValue: "")
        _feeText = State(initialValue: "")
        _date = State(initialValue: Self.marketToday(for: symbol.market))
        _fundingSource = State(initialValue: side == .buy ? .own : nil)
        _selectedBrokerageAccount = State(initialValue: account == .unassigned ? nil : account)
        _draftAccount = State(initialValue: account)
    }

    init(
        symbol: SymbolID,
        editing transaction: PositionTransaction,
        returnRoute: PositionReturnRoute,
        route: Binding<PopoverRoute>,
        account: BrokerageAccountID
    ) {
        self.symbol = symbol
        self.recordSide = transaction.kind == .sell ? .sell : .buy
        self.editing = transaction
        self.returnRoute = returnRoute
        self._route = route
        _priceText = State(initialValue: Self.fieldText(transaction.price))
        _quantityText = State(initialValue: Self.fieldText(transaction.quantity))
        _feeText = State(initialValue: transaction.fee.map(Self.fieldText) ?? "")
        _date = State(initialValue: Calendar.current.startOfDay(for: transaction.date))
        _fundingSource = State(initialValue: transaction.fundingSource)
        _selectedBrokerageAccount = State(initialValue: transaction.brokerageAccountID)
        _draftAccount = State(initialValue: account)
    }

    /// Whether the store is still pointed at the ledger this draft was built
    /// against. The symbol and the transaction id travel with the form, but
    /// neither authorizes a write: an account switch replaces the ledger behind
    /// the same store object, and an id that still exists in the new ledger
    /// would otherwise be edited by a form filled in for the old one.
    private var accountMatchesDraft: Bool {
        appState.watchlist.activeBrokerageAccountID == draftAccount
    }

    /// "Today" for this form is the market's own calendar date, not the
    /// user's. A US fill recorded from China at 1 a.m. belongs to the New York
    /// session still running, which is yesterday's date locally; dating it by
    /// the local clock would put the marker on a candle that doesn't exist
    /// yet and land it one day late once it does. The value is the local
    /// start-of-day instant for that calendar date, the form the ledger
    /// stores and `CandleTradeMarker` maps back through the local calendar.
    private static func marketToday(for market: Market) -> Date {
        var marketCalendar = Calendar(identifier: .gregorian)
        marketCalendar.timeZone = market.timeZone
        let components = marketCalendar.dateComponents([.year, .month, .day], from: .now)
        return Calendar.current.date(from: components) ?? Calendar.current.startOfDay(for: .now)
    }

    private var marketToday: Date { Self.marketToday(for: symbol.market) }

    /// The ledger this form is previewing against.
    ///
    /// A new buy previews the *destination* ledger, not the one it was opened
    /// from: the numbers the user is about to commit are the destination's, and
    /// showing the source's would describe a position this trade will not
    /// touch. An edit keeps the draft account, because that is the ledger the
    /// transaction actually lives in.
    private var previewAccount: BrokerageAccountID {
        isNewBuy ? (selectedBrokerageAccount ?? draftAccount) : draftAccount
    }

    private var item: WatchItem? { appState.watchlist.draftItem(for: symbol, account: previewAccount) }

    /// The item the preview replays. When the destination ledger has never
    /// held this symbol there is nothing to read, and a brand-new buy starts
    /// from an empty ledger — not from the source account's history, which is
    /// a different account's money entirely. The empty item is built from the
    /// instrument's own identity so the preview's row styling matches, and it
    /// carries no transactions and no lots, so the replayed result is exactly
    /// this buy.
    private var previewItem: WatchItem? {
        if let item { return item }
        guard isNewBuy, selectedBrokerageAccount != nil else { return nil }
        return WatchItem(symbol: symbol, displayName: appState.displayName(for: symbol))
    }

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    private var quantityUnit: String {
        symbol.cryptoPair?.baseAsset
            ?? PulseLocalization.localizedString("trade.unit.shares")
    }

    private var priceFieldLabel: String {
        PulseLocalization.localizedString(
            "trade.priceWithCurrency",
            currencyCode ?? symbol.currencyCode
        )
    }

    private var quantityFieldLabel: String {
        PulseLocalization.localizedString("trade.quantityWithUnit", quantityUnit)
    }

    /// The effective entry kind: the form's side in record mode, the stored
    /// kind (including adjustments) in edit mode.
    private var kind: PositionTransaction.Kind {
        editing?.kind ?? (recordSide == .buy ? .buy : .sell)
    }

    private var sideColor: Color {
        switch kind {
        case .buy: appState.palette.color(isUp: true)
        case .sell: appState.palette.color(isUp: false)
        case .adjustment: .secondary
        }
    }

    private var title: String {
        PulseLocalization.localizedString(
            editing != nil
                ? "trade.editTitle"
                : (recordSide == .buy ? "trade.buy" : "trade.sell")
        )
    }

    /// Where the page dismisses to: the trade log for edits, the hub for records.
    private var dismissRoute: PopoverRoute {
        editing != nil
            ? .transactions(symbol, returnRoute)
            : .position(symbol, returnRoute)
    }

    /// Whether the draft's own account no longer matches the store. The form
    /// blocks writes until the user returns to the source account.
    private var showsAccountNotice: Bool { !accountMatchesDraft }

    var body: some View {
        VStack(spacing: 0) {
            PositionPageHeader(
                symbol: symbol,
                title: (title, sideColor),
                accountCaption: isNewBuy
                    ? selectedBrokerageAccount.map(AccountIdentity.title)
                    : AccountIdentity.title(effectiveAccount),
                onBack: { route = dismissRoute }
            )
            AccountDraftNotice(account: draftAccount)
                .padding(.horizontal, 12)
                .padding(.bottom, accountMatchesDraft ? 0 : 6)
            VStack(alignment: .leading, spacing: 10) {
                if isNewBuy { buyAccountMethodFields }
                HStack(spacing: 8) {
                    PositionInputCell(
                        label: priceFieldLabel,
                        text: $priceText,
                        suggestion: currentPriceSuggestion,
                        autofocus: true
                    )
                    .help(PulseLocalization.localizedString(
                        "trade.priceUnitHelp",
                        currencyCode ?? symbol.currencyCode
                    ))
                    PositionInputCell(
                        label: quantityFieldLabel,
                        text: $quantityText,
                        suggestion: availableToSellSuggestion
                    )
                    .help(PulseLocalization.localizedString("trade.quantityUnitHelp", quantityUnit))
                }
                PositionInputCell(
                    label: PulseLocalization.localizedString("trade.fee"),
                    text: $feeText
                )
                if showsFeeError {
                    Text(PulseLocalization.localizedString("trade.invalidFee"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                dateRow
                fundingRow
                if let closedDayHint {
                    Text(closedDayHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                preview
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .animation(.snappy(duration: 0.2), value: closedDayHint)

            Spacer(minLength: 0)
            HStack {
                if editing != nil {
                    // `.destructive` alone doesn't color a bordered macOS
                    // button; the label carries the red itself.
                    Button(role: .destructive) {
                        deleteEditedTransaction()
                    } label: {
                        Text(PulseLocalization.localizedString("action.delete"))
                            .foregroundStyle(.red)
                    }
                    .disabled(showsAccountNotice)
                }
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel")) {
                    route = dismissRoute
                }
                confirmButton
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The whole form is keyboard-first; Return from either field confirms
        // (the button's default action covers Return when no field has focus).
        .onSubmit { save() }
        // A refused write's sentence describes the values that were submitted.
        // Once the user edits any of them, keeping it on screen would be
        // commenting on fields that no longer hold those values.
        .onChange(of: priceText) { _, _ in errorMessage = nil }
        .onChange(of: quantityText) { _, _ in errorMessage = nil }
        .onChange(of: feeText) { _, _ in errorMessage = nil }
        .onChange(of: date) { _, _ in errorMessage = nil }
        .task(id: symbol) { await loadDailyCandles() }
    }

    /// Reuses the detail chart's 250-bar daily cache when it's already warm;
    /// one fetch otherwise, so the closed-day hint can name the exact trading
    /// day a marker would snap to.
    private func loadDailyCandles() async {
        let key = CandleCacheKey(symbol: symbol, period: .day)
        if let cached = appState.market.cachedCandles(for: key, maxAge: .infinity) {
            dailyCandles = cached
            return
        }
        dailyCandles = await appState.engine.loadCandles(for: symbol, period: .day, count: 250)
    }

    // MARK: - Form rows

    /// The live price as a one-click fill. The chip follows the quote, but
    /// what lands in the field is the price at the moment of the click and
    /// stays put — a limit the user chose, not a number that keeps moving.
    private var currentPriceSuggestion: PositionInputCell.Suggestion? {
        guard let quote, quote.price.isFinite, quote.price > 0 else { return nil }
        let price = PriceFormatter.price(quote.price, market: symbol.market)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString("trade.currentPrice", price),
            help: PulseLocalization.localizedString("trade.fillCurrentPriceHelp"),
            fill: { priceText = price }
        )
    }

    /// Selling against a long offers what's sellable. Shorts stay unadorned —
    /// negative quantities speak for themselves to anyone shorting. Edit mode
    /// drops the chip: the sellable count already includes the entry being
    /// edited, so offering it would double-count.
    private var availableToSellSuggestion: PositionInputCell.Suggestion? {
        guard editing == nil, kind == .sell, let item, item.positionQuantity > 0 else { return nil }
        let quantity = PriceFormatter.quantity(item.positionQuantity)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString("trade.availableToSell", quantity),
            help: PulseLocalization.localizedString("trade.fillAvailableHelp"),
            fill: { quantityText = quantity }
        )
    }

    /// A buy asks which money bought the shares; a sell does not, because a
    /// sale does not choose its own funding — it consumes existing portions,
    /// and that deduction is reconciled where the shares live rather than here.
    ///
    /// The sell side instead states what it will *not* do: this record is a
    /// fact and never an automatic source deduction. When the position really
    /// does mix own and borrowed shares, saying so here is what stops the user
    /// from assuming the app paid off the margin for them.
    ///
    /// Neither half renders for a mengmeng record. That account buys with its
    /// own money and holds no borrowed shares, so a funding picker there would
    /// be a label with one possible value — and the mixed-source warning would
    /// be describing a composition the account cannot have. The stored value is
    /// untouched either way: this view never rewrites the funding of a record
    /// the user did not ask to change, and saving an unrelated correction
    /// carries the annotation it loaded straight back.
    @ViewBuilder
    private var fundingRow: some View {
        if !isMengmengRecord {
            if kind == .buy && !isNewBuy {
                FundingSourcePickerRow(
                    label: poolCopy("资金来源", "Funding source"),
                    selection: $fundingSource,
                    help: poolCopy("记录这笔买入实际动用的资金；不填表示尚未标注。",
                                   "Which money this buy actually used. Leaving it blank means nobody has said."),
                    options: editFundingOptions,
                    account: effectiveAccount
                )
                if let editing, editing.fundingSource != fundingSource {
                    Text(poolCopy("修改买入资金来源后，请在仓位池核对现有份额标记。",
                                  "After correcting buy funding, review the existing portion labels in Position pools."))
                        .font(.caption2).foregroundStyle(.orange)
                }
            } else if let mixedSourceNote {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(mixedSourceNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The ledger this draft's record belongs to: the transaction's own
    /// attribution when editing, the account the form was opened for otherwise.
    ///
    /// Every funding question is asked about *this* account, never about the
    /// globally selected one. The two can differ — the form is frozen to the
    /// ledger it was built against while the store keeps moving — and reading
    /// the global selection would answer for a different account's money.
    private var effectiveAccount: BrokerageAccountID {
        editing?.brokerageAccountID ?? draftAccount
    }

    /// Whether this draft edits a record that belongs to the mengmeng account.
    /// Only an edit can: a new buy into mengmeng is announced by its own
    /// account picker, which is where the shared fields decide the form.
    private var isMengmengRecord: Bool {
        effectiveAccount == .mengmeng
    }

    /// What an *edit* may newly claim about a buy's funding.
    ///
    /// A margin annotation only means something in the financing account, so no
    /// other account offers one — an edit must not be the way a new invalid
    /// combination enters the book. The exception is a record that already
    /// carries margin: that value is history, and removing it from the menu
    /// would leave the picker rendering a blank row and silently rewrite the
    /// annotation the moment some unrelated field is corrected. Keeping it
    /// selectable lets the user fix a price or a date without being forced to
    /// rewrite the funding on the way through.
    private var editFundingOptions: [PositionFundingSource] {
        guard let editing else { return fundingSourcePickerOptions }
        guard effectiveAccount != .financing, editing.fundingSource != .margin else {
            return fundingSourcePickerOptions
        }
        return fundingSourcePickerOptions.filter { $0 != .margin }
    }

    private var isNewBuy: Bool { editing == nil && kind == .buy }

    /// The shared account-then-method block, so this form and the plan
    /// execution sheet cannot offer different combinations. The binding is
    /// non-optional here because a new buy always has a method; an edit never
    /// shows these fields, so the fallback is unreachable and `.own` only keeps
    /// the type honest.
    private var buyAccountMethodFields: some View {
        BuyAccountMethodFields(
            account: $selectedBrokerageAccount,
            method: Binding(
                get: { fundingSource ?? .own },
                set: { fundingSource = $0 }
            ),
            accountAccessibilityID: "trade.buy.account",
            methodAccessibilityID: "trade.buy.method",
            onAccountChange: { errorMessage = nil },
            onMethodChange: { errorMessage = nil }
        )
    }

    /// Says that this sale's share composition has to be checked by hand.
    ///
    /// It fires when the position's own portions disagree about their funding,
    /// because a sale spanning several sources cannot be attributed to one of
    /// them automatically — and attributing it would be the app quietly
    /// claiming a repayment nobody made. A single-source or unannotated
    /// position needs no warning. So does a mengmeng position, where the
    /// warning is suppressed whole (see `fundingRow`): the account holds no
    /// borrowed shares to mix in.
    private var mixedSourceNote: String? {
        guard kind == .sell, !isMengmengRecord, let item, let allocation = item.positionAllocation,
              !item.positionAllocationNeedsReconciliation else { return nil }
        let sources = Set(allocation.portions.map { $0.fundingSource ?? .unmarked })
        guard sources.count > 1 else { return nil }
        return poolCopy(
            "该持仓含多种资金来源。本记录只登记成交事实，不自动扣减某一种来源；请在仓位池中核对剩余份额构成。",
            "This position mixes funding sources. This record books the fill only; it deducts no single source. Review the remaining composition in Position pools."
        )
    }

    /// Resting state stays in the app's own chrome: arrows step ±1 day for
    /// the common "today/yesterday" records, and clicking the date opens a
    /// system calendar popover for anything older. Nothing can be dated past
    /// the market's current trading day.
    private var dateRow: some View {
        HStack(spacing: 8) {
            Text(PulseLocalization.localizedString("trade.date"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            IconButton(systemName: "chevron.left", help: "") {
                step(-1)
            }
            Button {
                showsCalendar = true
            } label: {
                Text(dateLabel)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 70)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                CalendarDatePicker(date: $date, maximumDate: marketToday)
                    .padding(10)
                    .onChange(of: date) { _, _ in
                        showsCalendar = false
                    }
            }
            IconButton(systemName: "chevron.right", help: "") {
                step(1)
            }
            .disabled(isToday)
            .opacity(isToday ? 0.35 : 1)
        }
    }

    private var isToday: Bool {
        Calendar.current.isDate(date, inSameDayAs: marketToday)
    }

    /// "Today"/"Yesterday" count from the market's trading date (see
    /// `marketToday`), so the default date always reads as today even when
    /// the local clock has already rolled past midnight.
    private var dateLabel: String {
        let calendar = Calendar.current
        if isToday {
            return PulseLocalization.localizedString("trade.dateToday")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: marketToday),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return PulseLocalization.localizedString("trade.dateYesterday")
        }
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: .now)
        formatter.dateFormat = sameYear ? "MM-dd" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func step(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: date) else { return }
        guard next <= marketToday else { return }
        date = next
    }

    /// A picked day with no session of its own — weekend, holiday, or the
    /// local day a late-session fill landed on. The record keeps the entered
    /// date; the hint only says where the chart marker will land. Adjustments
    /// never draw markers, so they never draw this hint either.
    ///
    /// Only a gap inside the loaded history counts as a closure. A day the
    /// candles don't reach — today while the session is still running and
    /// its bar isn't published, a stale cache, a future pick — tells us
    /// nothing, so it falls back to the weekend check rather than calling an
    /// open market closed.
    private var closedDayHint: String? {
        guard kind != .adjustment else { return nil }
        switch CandleTradeMarker.markerDay(for: date, candles: dailyCandles, market: symbol.market) {
        case .tradingDay:
            return nil
        case .closedDay(let candleDay):
            return PulseLocalization.localizedString(
                "trade.closedDay.snap",
                shortDayLabel(candleDay)
            )
        case .outsideHistory:
            guard isMarketWeekend(date) else { return nil }
            return PulseLocalization.localizedString("trade.closedDay")
        }
    }

    /// Saturday/Sunday in the market's own timezone. Crypto trades through
    /// weekends, so its "weekend" is never a closure.
    private func isMarketWeekend(_ day: Date) -> Bool {
        guard symbol.market != .crypto else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        let weekday = calendar.component(.weekday, from: day)
        return weekday == 1 || weekday == 7
    }

    /// The candle day in the market's timezone — the same label the chart's
    /// axis shows — in the compact form the date row uses.
    private func shortDayLabel(_ day: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = PulseLocalization.currentLocale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: .now)
        formatter.dateFormat = sameYear ? "MM-dd" : "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    // MARK: - Preview (same row styling as the quick-set editor)

    @ViewBuilder
    private var preview: some View {
        let simulated = simulatedOutcome
        let held = previewItem?.positionQuantity ?? 0
        // A trade realizes P&L when it closes against the open side (sell on
        // a long, buy on a short); it moves the average cost when it opens
        // or extends a side. Before input parses, fall back to what the
        // current position implies so rows don't pop in mid-typing.
        let showsRealized = simulated.map { $0.realized != nil }
            ?? (kind == .sell ? held > 0 : kind == .buy ? held < 0 : false)
        let showsAverageCost = simulated.map { $0.quantity != 0 }
            ?? (kind == .sell ? held <= 0 : kind == .buy ? held >= 0 : held != 0)
        VStack(spacing: 6) {
            previewRow(
                PulseLocalization.localizedString("trade.amount"),
                simulated.map { PriceFormatter.money($0.amount, currencyCode: currencyCode) } ?? "—"
            )
            if showsRealized {
                previewRow(
                    PulseLocalization.localizedString("trade.realizedPnL"),
                    simulated?.realized.map { PriceFormatter.signedMoney($0, currencyCode: currencyCode) } ?? "—",
                    color: simulated?.realized
                )
            }
            previewRow(
                PulseLocalization.localizedString("trade.resultingPosition"),
                simulated.map { PriceFormatter.quantity($0.quantity) } ?? "—"
            )
            if showsAverageCost {
                previewRow(
                    PulseLocalization.localizedString("trade.newAverageCost"),
                    simulated.map { newAverageCostText($0) } ?? "—"
                )
            }
        }
        .opacity(simulated == nil ? 0.55 : 1)
    }

    private func previewRow(_ label: String, _ value: String, color: Double? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color.map { appState.palette.color(for: $0) } ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .font(.caption)
    }

    private func newAverageCostText(_ outcome: SimulatedOutcome) -> String {
        let new = PriceFormatter.price(outcome.averageCost)
        guard let previous = previewItem?.averageCost else { return new }
        return "\(PriceFormatter.price(previous)) → \(new)"
    }

    // MARK: - Confirm

    /// Solid fill, not glass: the primary action keeps its weight through
    /// color, matching the flat component language of the position pages.
    private var confirmButton: some View {
        Button {
            save()
        } label: {
            Text(PulseLocalization.localizedString(
                editing != nil
                    ? "action.save"
                    : (recordSide == .buy ? "trade.confirmBuy" : "trade.confirmSell")
            ))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .keyboardShortcut(.defaultAction)
        .help(PulseLocalization.localizedString(
            editing != nil
                ? "action.saveHelp"
                : (recordSide == .buy ? "trade.confirmBuyHelp" : "trade.confirmSellHelp")
        ))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(sideColor.opacity(0.92))
        )
        .disabled(!isValid || showsAccountNotice)
        .opacity(isValid && !showsAccountNotice ? 1 : 0.45)
    }

    // MARK: - Parsing & simulation

    /// An adjustment writes a target state and a buy can bridge a share split
    /// (more shares, no money moved), so zero is legitimate there. Sells keep
    /// the strictly-positive contract: a zero sell would fabricate a realized
    /// loss.
    private var parsedPrice: Double? {
        parseDecimal(priceText).flatMap {
            $0.isFinite && (kind == .sell ? $0 > 0 : $0 >= 0) ? $0 : nil
        }
    }

    private var parsedQuantity: Double? {
        parseDecimal(quantityText).flatMap {
            $0.isFinite && (kind == .adjustment ? $0 >= 0 : $0 > 0) ? $0 : nil
        }
    }

    private var isValid: Bool {
        let fieldsValid = parsedPrice != nil && parsedQuantity != nil && parsedFeeIsValid
        guard isNewBuy else { return fieldsValid }
        // The account/method pairing is core's rule, not a second copy: a new
        // buy needs a named account that permits the chosen method.
        return fieldsValid
            && selectedBrokerageAccount?.permitsBuy(fundingSource: fundingSource ?? .own) == true
    }

    private struct SimulatedOutcome {
        var amount: Double
        var realized: Double?
        var quantity: Double
        var averageCost: Double
    }

    /// Replays the would-be ledger (folding legacy lots in, exactly like the
    /// store will on save) so the preview matches the post-save state. In edit
    /// mode the existing entry is replaced in the replay rather than appended.
    private var simulatedOutcome: SimulatedOutcome? {
        guard let previewItem, let price = parsedPrice, let quantity = parsedQuantity else { return nil }
        var transactions = previewItem.materializedTransactions()
        if let editing {
            guard let existing = transactions.firstIndex(where: { $0.id == editing.id }) else {
                return nil
            }
            var updated = editing
            updated.price = price
            updated.quantity = quantity
            updated.fee = parsedFee
            updated.date = date
            transactions[existing] = updated
        } else {
            transactions.append(PositionTransaction(
                kind: recordSide == .buy ? .buy : .sell,
                price: price,
                quantity: quantity,
                date: date,
                fee: parsedFee
            ))
        }
        let ledger = PositionLedger(transactions: transactions)
        let realized = editing.flatMap { target in
            ledger.entries.first { $0.transaction.id == target.id }?.realizedPnL
        } ?? ledger.entries.last?.realizedPnL
        return SimulatedOutcome(
            amount: price * quantity,
            realized: realized,
            quantity: ledger.quantity,
            averageCost: ledger.averageCost
        )
    }

    /// Fees are optional and typed by hand: an empty field means none were
    /// recorded, which is deliberately not the same as a zero the user typed.
    private var parsedFee: Double? {
        let trimmed = feeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: "")),
              value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private var parsedFeeIsValid: Bool {
        feeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedFee != nil
    }

    private var showsFeeError: Bool {
        !feeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsedFeeIsValid
    }

    private func save() {
        guard !didSave, accountMatchesDraft, let price = parsedPrice,
              let quantity = parsedQuantity, isValid else {
            return
        }
        if var updated = editing {
            // An edit writes through the draft's own ledger, unchanged. The id
            // it rewrites was read from that ledger, so it needs no item guard
            // beyond the account one the caller already passed.
            guard let item else { return }
            didSave = true
            updated.price = price
            updated.quantity = quantity
            updated.fee = parsedFee
            updated.date = date
            // An edit carries the annotation through; a sell never claims one
            // here, since its shares' funding belongs to the portions the
            // allocation already describes.
            if kind == .buy { updated.fundingSource = fundingSource }
            appState.watchlist.updateTransaction(item.symbol, updated)
            route = dismissRoute
            return
        }
        guard isNewBuy else {
            // A new sell: the existing non-throwing path, untouched. A sale
            // consumes portions and never chooses its own funding here.
            guard let item else { return }
            didSave = true
            appState.watchlist.addTransaction(item.symbol, PositionTransaction(
                kind: .sell,
                price: price,
                quantity: quantity,
                date: date,
                fee: parsedFee
            ))
            route = dismissRoute
            return
        }
        guard let account = selectedBrokerageAccount else { return }
        // A new buy is the one write with a destination of its own choosing, so
        // it goes through the throwing entry point: the store can refuse a
        // combination (a margin buy in mengmeng) and say why, and the form
        // stays open on the fields that caused it.
        didSave = true
        do {
            _ = try appState.watchlist.recordBuyTransaction(
                symbol,
                PositionTransaction(
                    kind: .buy,
                    price: price,
                    quantity: quantity,
                    date: date,
                    fee: parsedFee,
                    fundingSource: fundingSource ?? .own,
                    brokerageAccountID: account
                ),
                account: account
            )
            // The trade landed in its destination ledger, so the app follows it
            // there: the hub this form dismisses to must describe the position
            // the user just created, not the one they were looking at before.
            _ = appState.selectBrokerageAccount(account)
            route = dismissRoute
        } catch {
            // Nothing was written. Reopening the door lets the user correct the
            // price, the date, or the account and save again — the failed
            // attempt must not latch the form shut.
            didSave = false
            errorMessage = Self.describe(error)
        }
    }

    /// A store error is never swallowed into a generic sentence: a refusal the
    /// user can act on is the whole reason this path is throwing.
    private static func describe(_ error: Error) -> String {
        if let executionError = error as? TradePlanExecutionError,
           let description = executionError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    /// Removes the entry being edited and returns to the log it came from —
    /// or straight to the hub when this was the last entry, since an empty
    /// log has nothing to show.
    private func deleteEditedTransaction() {
        guard !didSave, accountMatchesDraft, let editing else {
            return
        }
        didSave = true
        appState.watchlist.deleteTransaction(symbol, id: editing.id)
        let remaining = appState.watchlist.item(for: symbol)?.transactions ?? []
        route = remaining.isEmpty ? .position(symbol, returnRoute) : dismissRoute
    }

    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    /// Field prefill that keeps full precision instead of the display rounding
    /// `PriceFormatter` applies — editing then saving without touching a field
    /// must never silently re-round a price.
    private static func fieldText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
    }
}

/// SwiftUI's graphical DatePicker wraps NSDatePicker, whose whole-calendar
/// focus ring can't be disabled from SwiftUI. Wrapping it directly lets us
/// turn the ring off while keeping the system calendar.
private struct CalendarDatePicker: NSViewRepresentable {
    @Binding var date: Date
    var maximumDate: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.focusRingType = .none
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.maxDate = maximumDate
        picker.dateValue = date
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateChanged(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.maxDate = maximumDate
        if picker.dateValue != date {
            picker.dateValue = date
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: CalendarDatePicker

        init(_ parent: CalendarDatePicker) {
            self.parent = parent
        }

        @objc func dateChanged(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
        }
    }
}
