import SwiftUI
import PulseCore
import PulseUI

/// Editor for one trade plan: how much to buy or sell, at which price, and why.
///
/// Pushed as its own page rather than presented as a sheet. Pulse is an
/// accessory (`LSUIElement`) app, so a sheet — a separate NSWindow — takes key
/// status the app cannot hold and closes the panel; that is why nothing in
/// `PulseMac/Sources` opens one. It is also why the form is not inline on the
/// detail page: that page has no ScrollView and a fixed height, while this form
/// is a stack of labelled fields that needs room the detail page does not have.
///
/// With `planID` set the same form edits an existing plan, keeping its
/// `createdAt` and refreshing `updatedAt` — the field the sync merge reads when
/// both Macs changed the same plan.
struct PlanEditorView: View {
    @Environment(AppState.self) private var appState
    let symbol: SymbolID
    /// The plan being edited; nil creates a new one.
    let planID: UUID?
    let returnRoute: PositionReturnRoute
    @Binding var route: PopoverRoute

    @State private var kind: TradePlan.Kind = .buy
    @State private var priceText = ""
    @State private var quantityText = ""
    @State private var noteText = ""
    @State private var status: TradePlan.Status = .active
    /// The stored plan is read once, on appear: later edits to the draft must
    /// not be overwritten by the store the draft is being written into.
    @State private var didLoad = false
    /// Return can reach `save()` twice in one keypress (field submit plus the
    /// default action); the first write wins.
    @State private var didSave = false

    private var item: WatchItem? { appState.watchlist.item(for: symbol) }
    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var currencyCode: String? { quote?.currencyCode ?? symbol.currencyCode }

    private var existingPlan: TradePlan? {
        guard let planID else { return nil }
        return item?.plans.first { $0.id == planID }
    }

    private var sideColor: Color {
        appState.palette.color(isUp: kind == .buy)
    }

    var body: some View {
        VStack(spacing: 0) {
            PositionPageHeader(
                symbol: symbol,
                title: (PulseLocalization.localizedString(
                    planID == nil ? "plan.title.add" : "plan.title.edit"
                ), sideColor),
                onBack: { route = returnRoute.popoverRoute }
            )
            VStack(alignment: .leading, spacing: 10) {
                kindPicker
                HStack(spacing: 8) {
                    PositionInputCell(
                        label: PulseLocalization.localizedString("plan.price"),
                        text: $priceText,
                        suggestion: currentPriceSuggestion,
                        autofocus: planID == nil
                    )
                    PositionInputCell(
                        label: PulseLocalization.localizedString("position.quantity"),
                        text: $quantityText
                    )
                }
                PositionInputCell(
                    label: PulseLocalization.localizedString("plan.note"),
                    text: $noteText
                )
                statusPicker
                summaryRow
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)

            Spacer(minLength: 0)
            HStack {
                if planID != nil {
                    // `.destructive` alone doesn't color a bordered macOS
                    // button; the label carries the red itself.
                    Button(role: .destructive) {
                        deletePlan()
                    } label: {
                        Text(PulseLocalization.localizedString("plan.delete"))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(PulseLocalization.localizedString("action.cancel")) {
                    route = returnRoute.popoverRoute
                }
                confirmButton
            }
            .controlSize(.small)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onSubmit { save() }
        .task { load() }
    }

    // MARK: - Form rows

    /// Two flat buttons sharing the trade page's DNA, so "buy" reads as the up
    /// colour everywhere in the app.
    private var kindPicker: some View {
        HStack(spacing: 8) {
            kindButton(.buy, titleKey: "plan.kind.buy")
            kindButton(.sell, titleKey: "plan.kind.sell")
        }
    }

    private func kindButton(_ value: TradePlan.Kind, titleKey: String) -> some View {
        let selected = kind == value
        let color = appState.palette.color(isUp: value == .buy)
        return Button {
            kind = value
        } label: {
            Text(PulseLocalization.localizedString(titleKey))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(selected ? 0.16 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(color.opacity(selected ? 0.35 : 0.12), lineWidth: 0.5)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PulseLocalization.localizedString("plan.status"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Picker("", selection: $status) {
                ForEach(TradePlan.Status.allCases, id: \.self) { value in
                    Text(PulseLocalization.localizedString("plan.status.\(value.rawValue)"))
                        .tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    /// What the plan comes to at its own price. Reads `—` until both fields
    /// parse rather than flashing a zero, exactly like the trade preview.
    private var summaryRow: some View {
        HStack {
            Text(PulseLocalization.localizedString("plan.amount"))
                .foregroundStyle(.secondary)
            Spacer()
            Text(estimatedAmountText)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private var estimatedAmountText: String {
        guard let price = parsedPrice, let quantity = parsedQuantity else { return "—" }
        return PriceFormatter.money(price * quantity, currencyCode: currencyCode)
    }

    /// The live price as a one-click fill. What lands in the field is the price
    /// at the moment of the click and stays put — the plan price is a decision,
    /// not a number that keeps moving.
    private var currentPriceSuggestion: PositionInputCell.Suggestion? {
        guard let quote, quote.price.isFinite, quote.price > 0 else { return nil }
        let price = PriceFormatter.price(quote.price, market: symbol.market)
        return PositionInputCell.Suggestion(
            label: PulseLocalization.localizedString("trade.currentPrice", price),
            help: PulseLocalization.localizedString("plan.useCurrentPrice"),
            fill: { priceText = price }
        )
    }

    /// Solid fill, not glass — same primary-action treatment as the trade page.
    private var confirmButton: some View {
        Button {
            save()
        } label: {
            Text(PulseLocalization.localizedString("action.save"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .keyboardShortcut(.defaultAction)
        .help(PulseLocalization.localizedString("action.saveHelp"))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(sideColor.opacity(0.92))
        )
        .disabled(!isValid)
        .opacity(isValid ? 1 : 0.45)
    }

    // MARK: - Load & save

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let plan = existingPlan else { return }
        kind = plan.kind
        priceText = Self.fieldText(plan.price)
        quantityText = Self.fieldText(plan.quantity)
        noteText = plan.note ?? ""
        status = plan.status
    }

    private var parsedPrice: Double? {
        parseDecimal(priceText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private var parsedQuantity: Double? {
        parseDecimal(quantityText).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private var isValid: Bool {
        parsedPrice != nil && parsedQuantity != nil
    }

    private func save() {
        guard !didSave, let item, let price = parsedPrice, let quantity = parsedQuantity else { return }
        didSave = true
        appState.watchlist.setTradePlan(
            TradePlan(
                id: planID ?? UUID(),
                kind: kind,
                price: price,
                quantity: quantity,
                status: status,
                note: noteText,
                createdAt: existingPlan?.createdAt ?? .now
            ),
            for: item.symbol
        )
        route = returnRoute.popoverRoute
    }

    private func deletePlan() {
        guard !didSave, let planID else { return }
        didSave = true
        appState.watchlist.deleteTradePlan(planID, for: symbol)
        route = returnRoute.popoverRoute
    }

    private func parseDecimal(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    /// Field prefill that keeps full precision instead of the display rounding
    /// `PriceFormatter` applies, so editing and saving without touching a field
    /// never silently re-rounds a price.
    private static func fieldText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...10)).grouping(.never))
    }
}
