import SwiftUI
import PulseCore
import PulseUI

struct TradeRiskCalculatorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let initialSymbol: SymbolID?

    @State private var selectedSymbol: SymbolID?
    @State private var entryText = ""
    @State private var stopText = ""
    @State private var targetText = ""
    @State private var riskBudgetText = ""
    @State private var feesText = "0"
    @State private var slippageText = "0"
    @State private var quantityStepText = ""
    @State private var maximumInvestedText = ""
    @State private var message: String?
    /// The account open when this sheet loaded. Both save buttons write into
    /// whichever ledger is selected at the click, and the inputs were typed for
    /// the one on screen when the sheet opened.
    @State private var frozenAccount: BrokerageAccountID?

    /// Non-nil only when the store still holds the ledger these inputs came
    /// from.
    private var accountMatchesDraft: Bool {
        frozenAccount.map { appState.watchlist.activeBrokerageAccountID == $0 } ?? false
    }

    /// The account these inputs are destined for.
    private var draftAccount: BrokerageAccountID {
        frozenAccount ?? appState.watchlist.activeBrokerageAccountID
    }

    init(initialSymbol: SymbolID?) {
        self.initialSymbol = initialSymbol
        _selectedSymbol = State(initialValue: initialSymbol)
    }

    private var eligibleItems: [WatchItem] {
        appState.watchlist.allItems.filter(\.supportsPosition)
    }

    private var item: WatchItem? {
        guard let selectedSymbol else { return nil }
        return appState.watchlist.item(for: selectedSymbol)
    }

    private var quote: Quote? {
        guard let selectedSymbol else { return nil }
        return appState.market.quote(for: selectedSymbol)
    }

    private var currencyCode: String {
        quote?.currencyCode ?? selectedSymbol?.currencyCode ?? ""
    }

    private var isShort: Bool { (item?.positionQuantity ?? 0) < 0 }
    private var calculation: TradeRiskCalculation.Result? {
        guard !isShort,
              let entry = parsed(entryText), let stop = parsed(stopText), let target = parsed(targetText),
              let budget = parsed(riskBudgetText), let fees = parsed(feesText),
              let slippage = parsed(slippageText), let step = parsed(quantityStepText),
              maximumInvestedText.isEmpty || parsed(maximumInvestedText) != nil else { return nil }
        return TradeRiskCalculation.calculate(.init(
            entryPrice: entry,
            stopPrice: stop,
            targetPrice: target,
            riskBudget: budget,
            roundTripFees: fees,
            adverseSlippagePerUnit: slippage,
            quantityStep: step,
            maximumInvestedAmount: maximumInvestedText.isEmpty ? nil : parsed(maximumInvestedText)
        ))
    }

    private var pricesValid: Bool {
        guard let entry = parsed(entryText), let stop = parsed(stopText), let target = parsed(targetText) else { return false }
        return stop > 0 && stop < entry && entry < target
    }

    private var calculatorInputValid: Bool {
        pricesValid
            && parsed(riskBudgetText).map { $0 > 0 } == true
            && parsed(feesText).map { $0 >= 0 } == true
            && parsed(slippageText).map { $0 >= 0 } == true
            && parsed(quantityStepText).map { $0 > 0 } == true
            && (maximumInvestedText.isEmpty || parsed(maximumInvestedText).map { $0 > 0 } == true)
    }

    private var quoteDetails: String? {
        guard let selectedSymbol, let quote, quote.price.isFinite, quote.price > 0 else { return nil }
        let market = selectedSymbol.market
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = market.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let status = TradingQuoteHealth.isCurrent(quote)
            ? label("当前行情", "Current quote")
            : label("过期或参考行情", "Stale/reference quote")
        return "\(status) · \(quote.sourceName ?? quote.sourceID ?? label("行情", "Quote")) · \(formatter.string(from: quote.timestamp)) (\(market.timeZoneDisplayName), \(market.timeZone.identifier))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    symbolPicker

                    if eligibleItems.isEmpty {
                        Text(label("请先将支持持仓的标的加入自选列表。", "Add a position eligible symbol to the watchlist first."))
                            .foregroundStyle(.secondary)
                    } else {
                        priceInputs
                        sizingInputs

                        if isShort {
                            Label(label("当前持仓为净空头，暂不支持覆盖或做空风险测算。", "The current position is short. Cover and short risk calculations are not supported."), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let calculation {
                            resultCard(calculation)
                            allocationSummary(for: calculation)
                        } else if calculatorInputValid && parsed(riskBudgetText).map({ $0 <= (parsed(feesText) ?? 0) }) == true {
                            Text(label("风险预算必须高于往返费用。", "The risk budget must exceed round-trip fees."))
                                .foregroundStyle(.orange)
                        } else if calculatorInputValid {
                            Text(label("当前预算或资金上限无法容纳一个数量步长，请调整输入。", "The current limits cannot fit one quantity step. Adjust the inputs."))
                                .foregroundStyle(.orange)
                        } else {
                            Text(label("请输入有效数值，并确保止损 < 入场价 < 目标价。", "Enter valid numbers and keep stop < entry < target."))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(label(
                        "这是估算值，跳空可能使实际亏损超过估算；不保证最大亏损，也不会自动向券商下单。",
                        "These are estimates. Gaps can make actual losses larger; maximum loss is not guaranteed, and no broker order is placed."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(spacing: 10) {
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(label("关闭", "Close")) { dismiss() }
                Button(label("保存防守价格", "Save stop and target")) { saveDefensePrices() }
                    .disabled(!canSaveDefensePrices)
                Button(label("保存买入计划", "Save buy plan")) { saveBuyPlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(calculation == nil || !accountMatchesDraft)
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 600, idealWidth: 650, minHeight: 520, idealHeight: 600)
        .onAppear {
            if frozenAccount == nil { frozenAccount = appState.watchlist.activeBrokerageAccountID }
            selectInitialSymbol()
        }
        .onChange(of: selectedSymbol) { _, _ in loadSelectedSymbol() }
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            message = label("账号已切换，请重新打开计算器。", "Account changed; reopen the calculator.")
            dismiss()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label("买入风险测算", "Buy risk calculator"))
                .font(.title2.weight(.semibold))
            Text(label("现金买入 · 计划与估算，不会记录成交", "Cash long buy · planning estimate, no trade is recorded"))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Both save buttons write into one account's ledger; naming it is
            // what stops inputs read from one account being confirmed into
            // another.
            HStack(spacing: 5) {
                Circle().fill(AccountIdentity.dotColor(draftAccount)).frame(width: 5, height: 5)
                Text(label("记入账号：\(AccountIdentity.title(draftAccount))",
                           "Recording into: \(AccountIdentity.title(draftAccount))"))
                    .font(.caption)
                    .foregroundStyle(accountMatchesDraft
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            }
        }
    }

    private var symbolPicker: some View {
        Picker(label("标的", "Symbol"), selection: $selectedSymbol) {
            ForEach(eligibleItems) { item in
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode)")
                    .tag(Optional(item.symbol))
            }
        }
        .pickerStyle(.menu)
        .disabled(eligibleItems.isEmpty)
    }

    private var priceInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label("价格", "Prices")).font(.headline)
            HStack(spacing: 12) {
                input(label("入场价", "Entry price"), text: $entryText)
                input(label("止损价", "Stop price"), text: $stopText)
                input(label("目标价", "Target price"), text: $targetText)
            }
            if let quoteDetails {
                Text(label("行情参考：\(quoteDetails)。可手动修改入场价。", "Quote reference: \(quoteDetails). Entry price can be edited."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(label("没有可用报价，请手动输入入场价。", "No usable quote; enter the entry price manually."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sizingInputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label("测算条件", "Sizing inputs")).font(.headline)
            HStack(spacing: 12) {
                input(label("风险预算（\(currencyCode)）", "Risk budget (\(currencyCode))"), text: $riskBudgetText)
                input(label("往返费用（\(currencyCode)）", "Round-trip fees (\(currencyCode))"), text: $feesText)
            }
            HStack(spacing: 12) {
                input(label("单份不利滑点（\(currencyCode)/单位）", "Adverse slippage (\(currencyCode)/unit)"), text: $slippageText)
                input(label("数量步长", "Quantity step"), text: $quantityStepText)
            }
            Text(label("数量步长请按券商规则填写；最低委托数量等限制需另行核对。", "Enter the quantity step from your broker rules; verify minimum order quantities and other limits separately."))
                .font(.caption2).foregroundStyle(.secondary)
            input(label("最大投入金额（\(currencyCode)，可选，含费用）", "Maximum invested (\(currencyCode), optional, fees included)"), text: $maximumInvestedText)
        }
    }

    private func input(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            TextField("", text: text)
                .accessibilityLabel(title)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultCard(_ result: TradeRiskCalculation.Result) -> some View {
        VStack(spacing: 7) {
            metric(label("预算可容纳数量", "Budget-sized quantity"), result.quantity.formatted(.number.precision(.significantDigits(1...16))))
            metric(label("预计投入（含费用）", "Estimated invested (fees included)"), PriceFormatter.money(result.investedAmount, currencyCode: currencyCode))
            metric(label("止损估算亏损（含费用和滑点）", "Estimated stop loss (fees and slippage included)"), PriceFormatter.money(result.estimatedLoss, currencyCode: currencyCode))
            metric(label("目标估算盈利（扣费用和滑点）", "Estimated target profit (after fees and slippage)"), PriceFormatter.signedMoney(result.estimatedProfit, currencyCode: currencyCode))
            metric(label("盈亏比", "Reward / risk"), result.rewardRiskRatio.formatted(.number.precision(.fractionLength(2))) + ":1")
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func allocationSummary(for result: TradeRiskCalculation.Result) -> some View {
        if let allocation = allocationPreview(quantity: result.quantity) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label("同币种仓位占比", "Same-currency position share")).font(.caption.weight(.semibold))
                Text(label("当前 → 买入后", "Current → after planned buy"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text("\(allocation.currency): \(allocation.before.formatted(.number.precision(.fractionLength(1))))% → \(allocation.after.formatted(.number.precision(.fractionLength(1))))%")
                    .font(.caption.monospacedDigit())
                Text(label("按可用参考报价估算；不含现金，缺报价的持仓会排除。", "Based on available reference quotes; excludes cash and positions without quotes."))
                    .font(.caption2).foregroundStyle(.secondary)
                if allocation.excludedCount > 0 {
                    Text(label("已排除 \(allocation.excludedCount) 个缺少有效报价的持仓。", "Excluded \(allocation.excludedCount) positions without usable quotes."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(label("持仓占比预览需要该标的的可用报价。", "Position share preview needs a usable quote for this symbol."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func allocationPreview(quantity: Double) -> (currency: String, before: Double, after: Double, excludedCount: Int)? {
        guard let selectedSymbol, item != nil, let quote,
              quote.price.isFinite, quote.price > 0 else { return nil }
        let positions = appState.watchlist.allItems.map { item in
            let quote = appState.market.quote(for: item.symbol)
            return PortfolioAllocation.Position(
                symbol: item.symbol,
                name: item.resolvedDisplayName,
                quantity: item.positionQuantity,
                price: quote.flatMap { $0.price.isFinite && $0.price > 0 ? $0.price : nil },
                currencyCode: quote?.currencyCode ?? item.symbol.currencyCode,
                supportsPosition: item.supportsPosition
            )
        }
        let current = PortfolioAllocation.calculate(positions: positions)
        guard let after = PortfolioAllocation.previewAfterBuy(
            positions: positions,
            plannedBuy: .init(symbol: selectedSymbol, quantity: quantity)
        ) else { return nil }
        let currency = (quote.currencyCode ?? selectedSymbol.currencyCode).uppercased()
        let beforeShare = current.currencies.first { $0.code == currency }?.holdings.first { $0.symbol == selectedSymbol }?.percent ?? 0
        let afterShare = after.currencies.first { $0.code == currency }?.holdings.first { $0.symbol == selectedSymbol }?.percent ?? 0
        return (currency, beforeShare, afterShare, current.excludedMissingQuoteCount)
    }

    private var canSaveDefensePrices: Bool {
        selectedSymbol != nil && !isShort && pricesValid && item?.supportsPosition == true
    }

    private func saveDefensePrices() {
        guard canSaveDefensePrices, let selectedSymbol, let stop = parsed(stopText), let target = parsed(targetText) else { return }
        // The stop and target are written into the ledger selected now, so the
        // account the inputs were read from has to be the one still open.
        guard accountMatchesDraft else {
            message = label("当前账号已切换，不会写入其他账号。请关闭后重新打开。",
                            "The account changed. Nothing is written into another account; reopen the calculator.")
            return
        }
        let saved = appState.watchlist.setTradingProfile(
            TradingProfile(sector: item?.tradingProfile?.sector, stopPrice: stop, targetPrice: target),
            for: selectedSymbol
        )
        message = saved
            ? label("已保存防守价格。", "Stop and target saved.")
            : label("防守价格未能保存。", "Could not save stop and target.")
    }

    private func saveBuyPlan() {
        guard let selectedSymbol, let entry = parsed(entryText), let result = calculation, result.quantity > 0 else { return }
        guard accountMatchesDraft else {
            message = label("当前账号已切换，计划不会写入其他账号。请关闭后重新打开。",
                            "The account changed. The plan is not written into another account; reopen the calculator.")
            return
        }
        let saved = appState.watchlist.setTradePlan(
            TradePlan(kind: .buy, price: entry, quantity: result.quantity),
            for: selectedSymbol
        )
        if saved {
            dismiss()
        } else {
            message = label("买入计划未能保存。", "Could not save the buy plan.")
        }
    }

    private func selectInitialSymbol(clearingMessage: Bool = true) {
        if selectedSymbol == nil || !eligibleItems.contains(where: { $0.symbol == selectedSymbol }) {
            selectedSymbol = eligibleItems.first(where: { $0.symbol == initialSymbol })?.symbol ?? eligibleItems.first?.symbol
        }
        loadSelectedSymbol(clearingMessage: clearingMessage)
    }

    private func loadSelectedSymbol(clearingMessage: Bool = true) {
        quantityStepText = ""
        entryText = quote.flatMap { $0.price.isFinite && $0.price > 0 ? Self.fieldText($0.price) : nil } ?? ""
        stopText = item?.tradingProfile?.stopPrice.map(Self.fieldText) ?? ""
        targetText = item?.tradingProfile?.targetPrice.map(Self.fieldText) ?? ""
        if clearingMessage { message = nil }
    }

    private func parsed(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private static func fieldText(_ value: Double) -> String {
        String(value)
    }

    private func label(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}
