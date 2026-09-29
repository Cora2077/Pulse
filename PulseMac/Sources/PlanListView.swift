import SwiftUI
import PulseCore
import PulseUI

/// Every trade plan in the watchlist, gathered on one page.
///
/// This is what the home bottom bar opens. It is deliberately not a per-symbol
/// view: the reason to write a plan down is to be told when the market gets
/// there, and that question spans the whole watchlist — walking ten detail
/// pages to answer it is the thing this page exists to avoid.
///
/// Reached plans sort to the top. That ordering, the header's counts, and the
/// badge on the home chip all come from `TradePlanOverview`, so the entry point
/// can never disagree with the page it opens.
struct PlanListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    @Binding var route: PopoverRoute

    /// Rebuilt from the store on every render, the same way the detail block
    /// derives reachability: only the user's intent is stored, never the
    /// answer to "is it there yet".
    private var entries: [TradePlanEntry] { appState.watchlist.tradePlanEntries }

    private func currentPrice(_ symbol: SymbolID) -> Double? {
        appState.market.quote(for: symbol)?.price
    }

    private var ordered: [TradePlanEntry] {
        TradePlanOverview.ordered(entries, currentPrice: currentPrice)
    }

    private var summary: TradePlanOverview.Summary {
        TradePlanOverview.summary(entries, currentPrice: currentPrice)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(ordered) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
                .softScrollEdgeEffect(for: .all)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(
                systemName: "chevron.left",
                help: PulseLocalization.localizedString("action.backHelp")
            ) {
                route = .list
            }
            HStack(spacing: 6) {
                Text(PulseLocalization.localizedString("plan.list.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                if summary.total > 0 {
                    Text(PulseLocalization.localizedString(
                        "plan.list.summary",
                        summary.total,
                        summary.reached
                    ))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.top, host == .pinnedWindow ? 2 : 12)
        .padding(.bottom, 6)
    }

    // MARK: - Rows

    /// Two lines rather than one: the panel is 340pt wide, and a row has to
    /// carry the instrument, the plan, and where the quote stands right now.
    /// Collapsing that onto one line truncated the instrument name, which is
    /// the one thing the row cannot lose.
    private func row(_ entry: TradePlanEntry) -> some View {
        let reached = TradePlanOverview.isReached(entry, currentPrice: currentPrice)
        let isWaiting = entry.plan.status == .active
        let name = appState.market.quote(for: entry.symbol)?.name
            ?? appState.displayName(for: entry.symbol)

        return Button {
            route = .detail(entry.symbol)
        } label: {
            HStack(spacing: 8) {
                // The direction colour lives on this bar and on the "in range"
                // label, never on the row as a whole: a buy plan coming into
                // range means the price *fell*, and a red row would read as a
                // gain. An aggregate surface like the home chip has no single
                // direction to borrow, so it uses the accent instead.
                Capsule()
                    .fill(reached && isWaiting
                        ? appState.palette.color(isUp: entry.plan.kind == .buy)
                        : Color.clear)
                    .frame(width: 2, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        trailingState(entry, reached: reached)
                    }
                    HStack(spacing: 5) {
                        Text(entry.symbol.displayCode)
                            .font(.system(size: 9.5).monospaced())
                            .foregroundStyle(.tertiary)
                        TradeKindBadge(
                            kind: entry.plan.kind == .buy ? .buy : .sell,
                            palette: appState.palette
                        )
                        Text("\(PriceFormatter.price(entry.plan.price, market: entry.symbol.market)) × \(PriceFormatter.quantity(entry.plan.quantity))")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(isWaiting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            .strikethrough(entry.plan.status == .cancelled, color: .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let quote = appState.market.quote(for: entry.symbol) {
                            Text(PriceFormatter.price(quote.price, market: entry.symbol.market))
                                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(reached && isWaiting ? Color.accentColor.opacity(0.07) : .clear)
        )
        .help(entry.plan.note ?? PulseLocalization.localizedString("plan.rowHelp"))
        .contextMenu { menu(entry) }
    }

    @ViewBuilder
    private func trailingState(_ entry: TradePlanEntry, reached: Bool) -> some View {
        switch entry.plan.status {
        case .done:
            statusLabel("plan.status.done")
        case .cancelled:
            statusLabel("plan.status.cancelled")
        case .active:
            if reached {
                Text(PulseLocalization.localizedString("plan.reached"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(appState.palette.color(isUp: entry.plan.kind == .buy))
                    .fixedSize()
            } else if let price = currentPrice(entry.symbol) {
                Text(PulseLocalization.localizedString(
                    "plan.gap",
                    PriceFormatter.percentMagnitude(entry.plan.gapPercent(from: price))
                ))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            }
        }
    }

    private func statusLabel(_ key: String) -> some View {
        Text(PulseLocalization.localizedString(key))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .fixedSize()
    }

    @ViewBuilder
    private func menu(_ entry: TradePlanEntry) -> some View {
        Button(PulseLocalization.localizedString("plan.menu.edit")) {
            route = .plan(entry.symbol, entry.plan.id, .planList)
        }
        if entry.plan.status == .active {
            Button(PulseLocalization.localizedString("plan.menu.drop")) {
                restate(entry, as: .cancelled)
            }
        } else {
            Button(PulseLocalization.localizedString("plan.menu.revive")) {
                restate(entry, as: .active)
            }
        }
        Divider()
        Button(PulseLocalization.localizedString("plan.delete"), role: .destructive) {
            appState.watchlist.deleteTradePlan(entry.plan.id, for: entry.symbol)
        }
    }

    /// Only the status moves, so `setTradePlan` keeps the plan's identity and
    /// its original `createdAt` — the same edit path the editor uses.
    private func restate(_ entry: TradePlanEntry, as status: TradePlan.Status) {
        var plan = entry.plan
        plan.status = status
        appState.watchlist.setTradePlan(plan, for: entry.symbol)
    }

    // MARK: - Empty state

    /// The overview can only be empty before the first plan exists, so this is
    /// the one place that has to say where plans are written.
    private var emptyState: some View {
        Text(PulseLocalization.localizedString("plan.list.empty"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 4)
    }
}
