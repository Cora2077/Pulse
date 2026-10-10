import SwiftUI
import PulseCore
import PulseUI

/// Compact plans: open work and past decisions have separate surfaces.
struct PlanListView: View {
    enum Scope: String, CaseIterable { case waiting, history }
    @Environment(AppState.self) private var appState
    @Environment(\.pulseHost) private var host
    @Binding var route: PopoverRoute
    @State private var scope: Scope = .waiting
    @State private var createAccount: BrokerageAccountID?
    @State private var workflowEntry: TradePlanEntry?
    @State private var executionEntry: TradePlanEntry?
    /// The pending delete, if any. The row menu only records the request; the
    /// confirmation sheet is the sole path to `deleteTradePlan`.
    @State private var deletionRequest: PlanDeletionRequest?

    init(route: Binding<PopoverRoute>, initialScope: Scope = .waiting) {
        _route = route
        _scope = State(initialValue: initialScope)
    }

    private var entries: [TradePlanEntry] { appState.watchlist.tradePlanEntries }
    private var waiting: [TradePlanEntry] {
        TradePlanOverview.ordered(entries.filter { $0.displayState == .waiting }, currentPrice: currentPrice)
    }
    private var history: [TradePlanEntry] { entries.filter { $0.displayState != .waiting } }
    private func currentPrice(_ symbol: SymbolID) -> Double? {
        guard let quote = appState.market.quote(for: symbol), TradingQuoteHealth.isCurrent(quote) else { return nil }
        return quote.price
    }
    /// The quote's own currency when it has one, so a row and the fill sheet
    /// that edits it print the same money.
    private func currencyCode(_ symbol: SymbolID) -> String? {
        appState.market.quote(for: symbol)?.currencyCode ?? symbol.currencyCode
    }
    /// The instrument type the shared watchlist resolved, never a guess: an
    /// unknown type prints the neutral unit instead of claiming "shares".
    private func instrumentType(_ symbol: SymbolID) -> InstrumentType? {
        appState.sharedWatchlist.item(for: symbol)?.resolvedInstrumentType
    }
    private var isCompact: Bool { appState.settings.compactPlanCards }

    var body: some View {
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                emptyState("plan.list.empty")
            } else {
                Picker("", selection: $scope) {
                    Text(PulseLocalization.localizedString("plans.display.waitingCount", waiting.count)).tag(Scope.waiting)
                    Text(PulseLocalization.localizedString("plans.display.historyCount", history.count)).tag(Scope.history)
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if scope == .waiting {
                            if waiting.isEmpty { emptyState("plans.display.noWaiting") }
                            // A fill can move the same plan id between lazy sections.
                            // Refresh its content identity with the execution snapshot
                            // so a reused row cannot retain its old action or price.
                            ForEach(waiting) { row($0).id($0) }
                        } else {
                            if history.isEmpty { emptyState("plans.display.noHistory") }
                            ForEach([TradePlanEntry.DisplayState.filled, .abandoned, .stopped], id: \.self) { state in
                                let group = history.filter { $0.displayState == state }
                                    .sorted { ($0.lastFillDate ?? $0.plan.updatedAt) > ($1.lastFillDate ?? $1.plan.updatedAt) }
                                if !group.isEmpty {
                                    Text(PulseLocalization.localizedString(state.sectionTitleKey) + " · \(group.count)")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.top, 7).padding(.bottom, 2)
                                    ForEach(group) { row($0).id($0) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                .softScrollEdgeEffect(for: .all)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $createAccount) { account in
            NewTradePlanSheet(account: account, onCreated: { _ in }, onClose: { createAccount = nil })
        }
        .sheet(item: $workflowEntry) { entry in
            PlanWorkflowDetailView(symbol: entry.symbol, planID: entry.plan.id,
                account: appState.watchlist.activeBrokerageAccountID)
                .frame(width: 650, height: 600)
        }
        .sheet(item: $executionEntry) { entry in
            PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                onClose: {
                    executionEntry = nil
                    if entries.first(where: { $0.plan.id == entry.plan.id })?.displayState == .filled {
                        scope = .history
                    }
                })
        }
        // The list itself never deletes. The row menu records a request; the
        // sheet re-reads, refuses a plan that moved, and deletes on confirm.
        .modifier(PlanDeletionConfirmation(request: $deletionRequest))
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemName: "chevron.left", help: PulseLocalization.localizedString("action.backHelp")) { route = .list }
            Text(PulseLocalization.localizedString("plan.list.title"))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            compactToggle
            Button { createAccount = appState.watchlist.activeBrokerageAccountID } label: {
                Label(PulseLocalization.localizedString("plan.newPlan"), systemImage: "plus").font(.system(size: 11))
            }
            .controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 12).padding(.top, host == .pinnedWindow ? 2 : 12).padding(.bottom, 3)
    }

    /// Density is one remembered choice for the whole list, so it lives in the
    /// header beside the button that adds rows rather than on each card. The
    /// icon is the mode a click would switch *to*, which is what the help text
    /// names.
    private var compactToggle: some View {
        IconButton(
            systemName: isCompact ? "rectangle.grid.1x2" : "list.bullet.rectangle",
            help: PulseLocalization.localizedString(
                isCompact ? "plans.layout.showComfortable" : "plans.layout.showCompact")
        ) {
            appState.settings.compactPlanCards.toggle()
        }
        .accessibilityIdentifier("plans.compact.toggle")
        .accessibilityLabel(PulseLocalization.localizedString(
            isCompact ? "plans.layout.showComfortable" : "plans.layout.showCompact"))
    }

    /// One plan, at whichever density the user last chose.
    ///
    /// The two layouts differ in more than padding. Compact is for scanning a
    /// queue: the money and the size get the larger type, the chrome shrinks,
    /// the repetitive "waiting" badge is left to the section header, and the
    /// actions move into a trailing menu so a row is not mostly button. The
    /// comfortable layout keeps every control visible. Both print the same
    /// explicit units and quote currency, and neither ever truncates the
    /// currency or the quantity away — the numbers are the row.
    ///
    /// The region that opens the workflow, the region that opens the menu, and
    /// the region that opens the fill sheet are three *siblings*, never nested.
    /// A button inside another button's label has no way to keep its own click:
    /// the outer button swallows the press, so a click meant for "Record fill"
    /// would open the workflow sheet instead. Keeping them siblings — the
    /// details target, the trailing menu, and the footer's current/gap line
    /// beside its record button — is what lets each one do only its own thing
    /// while a click on the card's body still opens the workflow.
    private func row(_ entry: TradePlanEntry) -> some View {
        let isWaiting = entry.displayState == .waiting
        let reached = isWaiting && TradePlanOverview.isReached(entry, currentPrice: currentPrice)
        let name = appState.market.quote(for: entry.symbol)?.name ?? appState.displayName(for: entry.symbol)
        let type = instrumentType(entry.symbol)
        let currency = currencyCode(entry.symbol)
        // Only the raw UUID of the stored plan goes into an identifier: it is
        // the one address that survives the display-state changes that decide
        // which surfaces a row can offer.
        let planID = entry.plan.id.uuidString
        // A stopped record with size still open can take a real fill after the
        // fact, and that is the one action this row is *for* — leaving it only
        // in the ellipsis menu hides the reason the record is on screen. The
        // footer below opens the fill sheet directly, which is what makes this
        // a visible action rather than a second door into the workflow.
        let canBackfill = !isWaiting && entry.canBackfillFill

        return VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
            HStack(alignment: .top, spacing: isCompact ? 4 : 6) {
                Button { workflowEntry = entry } label: {
                    details(entry, isWaiting: isWaiting, reached: reached, name: name,
                            type: type, currency: currency)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("plans.row.\(planID)")
                rowActions(entry)
                    .accessibilityIdentifier("plans.row.\(planID).menu")
            }
            if isWaiting {
                waitingFooter(entry, reached: reached, currency: currency,
                              type: type, planID: planID)
            } else if canBackfill {
                backfillFooter(entry, type: type, planID: planID)
            }
        }
        .padding(isCompact ? 7 : 9)
        .background(reached ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu { menu(entry) }
    }

    /// A waiting plan's headline: the target and the size still open against it.
    ///
    /// This is the tap target that opens the workflow page, so it deliberately
    /// holds no controls of its own: anything interactive inside it would be
    /// pressed by the outer button rather than by the user. The live price line
    /// and the actions live in `waitingFooter`, a sibling below.
    private func details(_ entry: TradePlanEntry, isWaiting: Bool, reached: Bool,
                         name: String, type: InstrumentType?, currency: String?) -> some View {
        let isFilled = entry.displayState == .filled
        // A filled record reports what the fills actually paid; everything else
        // reports the target and the size still open against it. Both go
        // through `PlanValueText`, so the unit and the money are never implied.
        let primaryNumber: String = isFilled
            ? (entry.actualFillText(currencyCode: currency, instrumentType: type) ?? PlanValueText.unknown)
            : PulseLocalization.localizedString("plans.display.target",
                PlanValueText.price(entry.plan.price, symbol: entry.symbol, currencyCode: currency),
                PlanValueText.quantity(isWaiting ? entry.remainingQuantity : entry.plan.quantity,
                                       symbol: entry.symbol, instrumentType: type))
        return VStack(alignment: .leading, spacing: isCompact ? 4 : 5) {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                // The badge repeats the section header in the pending scope, so
                // compact drops it there and keeps it wherever it is the only
                // statement of what happened to the plan.
                if !isCompact || !isWaiting { PlanStatusBadge(entry: entry) }
            }
            HStack(spacing: 5) {
                Text(entry.symbol.displayCode)
                    .font(.system(size: 9.5).monospaced()).foregroundStyle(.tertiary)
                TradeKindBadge(kind: entry.plan.kind == .buy ? .buy : .sell, palette: appState.palette)
                numberText(primaryNumber)
            }
            if !isWaiting {
                if let date = entry.fillDateText {
                    Text(date + (entry.displayState != .filled
                                 ? " · " + (entry.actualFillText(currencyCode: currency, instrumentType: type) ?? "")
                                 : ""))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                } else if entry.displayState == .stopped {
                    Text(PulseLocalization.localizedString("plans.display.missingFillHelp"))
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// A waiting row's live price, and — comfortable only — the record action.
    ///
    /// This sits outside the workflow button rather than inside its label.
    /// Nested, a click on the button would resolve to the ancestor and open the
    /// workflow sheet, so the one control the row exists to offer could never
    /// fire. As a sibling region it takes its own hit test and its own click,
    /// while the card body beside it still opens the workflow.
    ///
    /// The gap text is the paragraph that grows: it is allowed to wrap to a
    /// second line rather than being clipped, because a truncated "0.31 U…"
    /// is not a price and a truncated currency is worse than a taller row.
    @ViewBuilder private func waitingFooter(_ entry: TradePlanEntry, reached: Bool,
                                            currency: String?, type: InstrumentType?,
                                            planID: String) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if let price = currentPrice(entry.symbol) {
                    Text(PulseLocalization.localizedString("plans.display.current",
                             PlanValueText.price(price, symbol: entry.symbol, currencyCode: currency))
                         + " · " + (reached ? PulseLocalization.localizedString("plan.reached")
                           : PulseLocalization.localizedString("plan.gap", PriceFormatter.percentMagnitude(entry.plan.gapPercent(from: price)))))
                        .foregroundStyle(reached ? PlanSideStyle.color(for: entry.plan.kind) : .secondary)
                } else { Text(PulseLocalization.localizedString("plans.noQuote")).foregroundStyle(.tertiary) }
                if entry.filledQuantity > 0,
                   let fill = entry.actualFillText(currencyCode: currency, instrumentType: type) {
                    Text(fill).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9.5).monospacedDigit())
            .lineLimit(isCompact ? 2 : 1)
            .fixedSize(horizontal: false, vertical: isCompact)
            .layoutPriority(1)
            Spacer(minLength: 0)
            // The comfortable layout keeps the one-click record action visible;
            // compact leaves it in the trailing menu, which is the whole reason
            // a compact card is a card and not a form.
            if !isCompact {
                Button(PulseLocalization.localizedString("plans.action.recordFill")) { executionEntry = entry }
                    .font(.system(size: 10)).controlSize(.small)
                    .accessibilityIdentifier("plans.row.\(planID).record")
            }
        }
    }

    /// The visible backfill action on a stopped record that still has size open.
    ///
    /// Shown at both densities on purpose: this is the row's only reason to be
    /// on screen, and an action that exists only in a menu is an action the
    /// acceptance criteria call hidden. It opens the fill sheet directly —
    /// `PlanExecutionSheet` reads the mode off the entry — so nothing here
    /// revives the plan or restates its status.
    @ViewBuilder private func backfillFooter(_ entry: TradePlanEntry,
                                             type: InstrumentType?, planID: String) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button(PulseLocalization.localizedString("plans.action.backfill")) { executionEntry = entry }
                .font(.system(size: 10)).controlSize(.small)
                .accessibilityIdentifier("plans.row.\(planID).backfill")
                .help(PulseLocalization.localizedString("plans.backfill.help"))
        }
    }

    /// The price × quantity cell, which is never allowed to lose its currency
    /// or its unit to truncation.
    ///
    /// `ViewThatFits` tries the one-line form first — that is what the row
    /// normally is — and falls back to a two-line wrap only when the full
    /// string genuinely does not fit. Truncating here would leave "1,234.50 U…"
    /// or "0.005 …", which is the one thing this cell exists to say.
    @ViewBuilder private func numberText(_ text: String) -> some View {
        let font = Font.system(size: isCompact ? 11.5 : 10.5,
                                weight: isCompact ? .semibold : .regular).monospacedDigit()
        ViewThatFits(in: .horizontal) {
            Text(text).font(font).lineLimit(1).foregroundStyle(.secondary)
            Text(text).font(font).lineLimit(2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The trailing action cluster: a single visible ellipsis menu.
    ///
    /// One menu rather than a row of buttons for two reasons. It is the same
    /// set of actions at both densities, so nothing becomes undiscoverable by
    /// switching layout; and it costs a fixed width, which is what lets the
    /// numbers beside it keep their currency and their unit instead of being
    /// squeezed. Record, backfill, edit, history, drop, revive and delete are
    /// all here.
    private func rowActions(_ entry: TradePlanEntry) -> some View {
        Menu {
            menu(entry)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: isCompact ? 18 : 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(PulseLocalization.localizedString("main.plans.changeStatus"))
    }

    @ViewBuilder private func menu(_ entry: TradePlanEntry) -> some View {
        if entry.displayState == .waiting {
            Button(PulseLocalization.localizedString("plans.action.recordFill")) { executionEntry = entry }
        } else if entry.canBackfillFill {
            // A stopped record with size still open. The fill sheet detects the
            // mode from the entry itself and performs the guarded backfill; the
            // row is never revived first, which would resurrect an intention
            // the user already settled.
            Button(PulseLocalization.localizedString("plans.action.backfill")) { executionEntry = entry }
        }
        Button(PulseLocalization.localizedString("plans.action.logicHistory")) { workflowEntry = entry }
        Button(PulseLocalization.localizedString("plan.menu.edit")) { route = .plan(entry.symbol, entry.plan.id, .planList) }
        if entry.displayState == .waiting {
            Button(PulseLocalization.localizedString("plan.menu.drop")) { restate(entry, as: .cancelled) }
        } else if entry.displayState != .filled {
            Button(PulseLocalization.localizedString("plan.menu.revive")) { restate(entry, as: .active) }
        }
        Divider()
        Button(PulseLocalization.localizedString("plan.delete"), role: .destructive) {
            // The row already resolved the name it is showing; the dialog names
            // the same thing rather than re-asking the market and possibly
            // printing a different label than the row the user clicked.
            let name = appState.market.quote(for: entry.symbol)?.name
                ?? appState.displayName(for: entry.symbol)
            deletionRequest = PlanDeletionRequest(
                entry: entry,
                account: appState.watchlist.activeBrokerageAccountID,
                displayName: name
            )
        }
    }

    private func restate(_ entry: TradePlanEntry, as status: TradePlan.Status) {
        var plan = entry.plan
        plan.status = status
        appState.watchlist.setTradePlan(plan, for: entry.symbol)
    }
    private func emptyState(_ key: String) -> some View {
        Text(PulseLocalization.localizedString(key)).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 10)
    }
}
