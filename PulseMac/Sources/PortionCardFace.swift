import SwiftUI
import PulseCore
import PulseUI

struct PortionCardFace: View {
    let card: PositionPoolsView.PortionCard
    let compact: Bool
    let onSelect: () -> Void
    let onWholeTransfer: (PositionPool) -> Void
    let onPartialTransfer: (PositionPool?) -> Void
    let onMarkFunding: () -> Void
    /// Opens the verification editor. Verification is a per-card state, so it is
    /// offered wherever the card already offers its other per-card edits.
    let onEditVerification: () -> Void
    /// Creates a sell plan bound to this exact card, or edits the plan that is
    /// already bound to it. Defaults are no-ops so existing fixtures compile.
    var onAddSalePlan: () -> Void = {}
    var onEditSalePlan: (UUID) -> Void = { _ in }
    var onLinkBuySource: () -> Void = {}
    let onDragChanged: (DragGesture.Value, Bool) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    let isDraggable: Bool
    let isPlaceholder: Bool
    /// Preview disables every menu, drag, and accessibility write on the card.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    private let space = "position-pools-board"

    private var quote: Quote? { appState.market.quote(for: card.symbol) }
    private var buyOrigin: PositionPortion.Origin? {
        card.item.positionAllocation?.resolvedBuyOrigins(for: card.item)[card.portion.id]
    }
    private var transaction: PositionTransaction? {
        guard let id = buyOrigin?.transactionID else { return nil }
        return card.item.transactions.first { $0.id == id }
    }
    private var strategy: String? {
        transaction?.review?.strategy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    private var thesis: String? { card.item.thesis?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private var originText: String {
        guard let buyOrigin else { return copy("关联买入成交…", "Link recorded buy…") }
        let date = buyOrigin.date?.formatted(date: .abbreviated, time: .omitted)
        let price = buyOrigin.price.map { PriceFormatter.price($0, market: card.symbol.market) }
        let details = [date, price.map { "\(copy("成交价", "Trade price")) \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        return details.isEmpty ? copy("买入来源", "Buy source") : details
    }

    private var referenceMarketValue: String? {
        guard !card.needsReview, card.quantity.isFinite, card.quantity > 0,
              let quote, quote.price.isFinite, quote.price > 0,
              quote.timestamp.timeIntervalSince1970.isFinite else { return nil }
        let value = quote.price * card.quantity
        guard value.isFinite, value >= 0 else { return nil }
        let currency = card.symbol.currencyCode
        return "≈ \(PriceFormatter.money(value, currencyCode: currency))"
    }

    private var summary: String? {
        var parts: [String] = []
        if let strategy { parts.append("\(copy("策略", "Strategy"))：\(strategy)") }
        if let thesis { parts.append("\(copy("逻辑", "Thesis"))：\(thesis)") }
        if let note = card.portion.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            parts.append("\(copy("备注", "Note"))：\(note)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// The card's verification badge, or `nil` when it carries no conditions.
    ///
    /// The events are the instrument's own, filtered to this exact symbol: a
    /// condition linked to another instrument's event must never be matched to a
    /// lookalike, or a settled condition would silently reopen against the wrong
    /// calendar. The filter is on `card.symbol` rather than the item's identity
    /// so two listings of the same instrument cannot cross-match.
    private var verificationBadge: PositionVerificationBadge? {
        guard card.portion.conditions?.isEmpty == false else { return nil }
        let events = appState.tradingEvents.entries(for: [card.item])
            .filter { $0.symbol == card.symbol }
            .map(\.event)
        return VerificationBadge.resolve(conditions: card.portion.conditions, currentEvents: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(card.pool.tint).frame(width: 6, height: 6).accessibilityHidden(true)
                Button(action: onSelect) {
                    Text(card.item.resolvedDisplayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                Text(card.symbol.displayCode)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                // A real annotation earns a tag. `nil` renders nothing, so an
                // old portion never grows a repeated "未标注" row. The account is
                // the card's own displayed one — not the active ledger, which may
                // be a different account entirely while a filter is on.
                FundingSourceTag(source: card.portion.fundingSource, account: card.accountID)
                Spacer(minLength: 0)
                Menu { menuContent } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!canWrite)
                .help(menuHelp)
                .accessibilityLabel(copy("仓位卡片操作", "Position portion actions"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(poolQuantity(card.quantity))
                    .font(.system(size: compact ? 18 : 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(copy("份额", "shares"))
                    .font(PoolType.label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if card.needsReview {
                    Text(allocationReviewDescription(item: card.item, syncConflict: !card.item.positionAllocationNeedsReconciliation))
                        .font(PoolType.labelMedium).foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(allocationReviewDescription(item: card.item, syncConflict: !card.item.positionAllocationNeedsReconciliation))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                } else {
                    if let referenceMarketValue {
                        Text(referenceMarketValue)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    if let status = quoteStatus {
                        Image(systemName: quote == nil ? "chart.line.flattrend.xaxis" : "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                            .help(status).accessibilityLabel(status)
                    }
                }
            }
            // The verification badge rides the origin/metadata line rather than
            // the name/funding row: verification is a second thing to say about
            // the card, not a third tag competing with the instrument name, and
            // an unannotated card grows no row because `verificationBadge` is
            // nil when there are no conditions.
            HStack(spacing: 5) {
                // A read-only statement of where the shares actually sit. It is
                // not a switcher: relabelling a card never moved a trade, so the
                // menu that offered it only ever produced a label that disagreed
                // with the ledger. Real re-attribution is the historical
                // classification entrance, which moves the recorded trades.
                PositionAccountTag(account: card.ownerAccountID)
                if let verificationBadge {
                    VerificationBadge(badge: verificationBadge, compact: true)
                }
                Spacer(minLength: 0)
            }
            if buyOrigin != nil {
                Text(originText)
                    .font(PoolType.label).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button(originText) { if canLinkBuySource { onLinkBuySource() } }
                    .buttonStyle(.plain).font(PoolType.label).foregroundStyle(Color.accentColor)
                    .disabled(!canLinkBuySource)
                    .help(copy("选择已录入的买入成交，显示该笔日期与成交价。", "Choose a recorded buy to show its date and trade price."))
            }
            if let summary {
                Label(summary, systemImage: "text.alignleft")
                    .font(PoolType.label).foregroundStyle(.secondary).lineLimit(1)
                    .help(summary)
            }
            // A summary of plans already bound to this card — never a new claim
            // on shares, and never a card of its own when nothing is linked.
            linkedPlanSummary
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(card.pool.tint.opacity(card.needsReview ? 0.15 : 0.26), lineWidth: 1)
        }
        .opacity(isPlaceholder ? 0.17 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PoolDropFrameKey.self,
                    value: PositionPoolsView.DropFrames(cards: [card.id: proxy.frame(in: .named(space))])
                )
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
                .onChanged { value in onDragChanged(value, NSEvent.modifierFlags.contains(.shift)) }
                .onEnded(onDragEnded),
            including: isDraggable ? .all : .none
        )
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if canLinkBuySource {
                Button(copy("关联买入成交…", "Link recorded buy…"), action: onLinkBuySource)
            }
            Button(copy("部分转移…", "Split quantity…")) { if canWrite { onPartialTransfer(nil) } }
            Button(copy("编辑验证…", "Edit verification…")) { if canWrite { onEditVerification() } }
            // The whole-transfer actions are emitted only for purposes the card
            // may actually move to, so assistive technology is never offered a
            // destination the commit path would refuse. Unassigned is
            // deliberately absent: it is a backlog state, not a holding role.
            if PositionPoolsView.holdingTransferDestinations(from: card.pool).contains(.strategic) {
                Button(copy("移动到战略底仓", "Move to Strategic")) { if canWrite { onWholeTransfer(.strategic) } }
            }
            if PositionPoolsView.holdingTransferDestinations(from: card.pool).contains(.tactical) {
                Button(copy("移动到机动仓", "Move to Tactical")) { if canWrite { onWholeTransfer(.tactical) } }
            }
            // The funding action follows the visible menu exactly: a hidden entry
            // that still answered to assistive technology would be the same control
            // under a different name.
            if offersFundingMark {
                Button(copy("标记资金来源…", "Mark funding source…")) { if canWrite { onMarkFunding() } }
            }
            // The sell-plan actions mirror the menu's write checks exactly: the
            // create entry only when a bound plan is actually writable, and one
            // edit entry per plan already bound to this card.
            if canAddSalePlan {
                Button(copy("新增卖出计划…", "Add sell plan…")) { onAddSalePlan() }
            }
            if canEditSalePlan, let plan = linkedPlanRows.first?.id {
                Button(copy("编辑卖出计划…", "Edit sell plan…")) { if canWrite { onEditSalePlan(plan) } }
            }
        }
        // The same menu the ellipsis offers, on the whole card.
        .contextMenu { menuContent.disabled(!canWrite) }
    }

    /// One shared menu for the ellipsis and the context menu, so a right-click
    /// can never offer an action the button does not, or skip a guard.
    @ViewBuilder
    private var menuContent: some View {
        Button(copy("关联买入成交…", "Link recorded buy…")) { if canLinkBuySource { onLinkBuySource() } }
            .disabled(!canLinkBuySource)
        Divider()
        // First, because a right-click on a card is most often "sell this one".
        // It stays disabled rather than hidden so the absence is legible.
        Button(copy("新增卖出计划…", "Add sell plan…")) { if canAddSalePlan { onAddSalePlan() } }
        .disabled(!canAddSalePlan)
        if canEditSalePlan {
            if linkedPlanRows.count == 1, let only = linkedPlanRows.first {
                Button(copy("编辑卖出计划…", "Edit sell plan…")) { if canWrite { onEditSalePlan(only.id) } }
            } else if linkedPlanRows.count > 1 {
                Menu(copy("编辑卖出计划…", "Edit sell plan…")) {
                    ForEach(linkedPlanRows) { row in
                        Button(row.menuTitle) { if canWrite { onEditSalePlan(row.id) } }
                    }
                }
            }
        }
        Divider()
        ForEach(PositionPoolsView.holdingTransferDestinations(from: card.pool), id: \.self) { target in
            Button(copy("全部转入\(target.title)", "Move all to \(target.title)")) { if canWrite { onWholeTransfer(target) } }
        }
        Divider()
        Button(copy("部分转移…", "Split quantity…")) { if canWrite { onPartialTransfer(nil) } }
        Divider()
        // Mengmeng buys are ordinary by construction: the account
        // admits no funding method, so there is nothing this entry
        // could label there. Every other action stays.
        if offersFundingMark {
            Button(copy("标记资金来源…", "Mark funding source…")) { if canWrite { onMarkFunding() } }
        }
        Button(copy("编辑验证…", "Edit verification…")) { if canWrite { onEditVerification() } }
    }

    private var menuHelp: String {
        if isWriteBlocked { return copy("预演模式下不能转移或标记来源", "Moves and funding marks are unavailable in preview") }
        return card.needsReview ? copy("请先核对这张份额卡", "Reconcile this portion first") : ""
    }

    /// Whether this card still has shares no other active sell plan claims.
    /// Reads the store's own answer, so the button and the save path agree.
    private var availableSalePlanQuantity: Double {
        card.item.availableSalePlanQuantity(for: card.portion.id)
    }

    private var canAddSalePlan: Bool {
        canWrite && !card.needsReview && card.item.positionQuantity > 0 && availableSalePlanQuantity > 0
    }

    private var canLinkBuySource: Bool { canWrite && !card.needsReview }

    /// The write gate for editing a bound plan: reconciliation and preview
    /// block it, but a plan whose source has moved must stay *editable* — that
    /// is the only way the user can repair or cancel it.
    private var canEditSalePlan: Bool { canWrite }

    // MARK: Linked sell plans

    /// One plan bound to this exact card, flattened for display.
    ///
    /// The row carries the plan's own `TradePlanEntry` rather than a raw
    /// `TradePlan.Status`, so the card's face and the plan pages report the same
    /// derived state through the same shared presentation. A stale `active`
    /// whose real fills already used it up therefore cannot read as live here.
    private struct LinkedPlanRow: Identifiable {
        var id: UUID
        var price: Double
        var quantity: Double
        var isReached: Bool
        var sourceChanged: Bool
        var entry: TradePlanEntry

        var displayState: TradePlanEntry.DisplayState { entry.displayState }

        var menuTitle: String
    }

    /// Only plans whose `positionPortionID` is *this* card, and only sells.
    /// A plan matched by symbol or by pool would put a sibling card's intention
    /// on this card's face.
    private var boundSellPlans: [TradePlan] {
        card.item.plans.filter { $0.kind == .sell && $0.positionPortionID == card.portion.id }
    }

    /// The bindings that still read as waiting, off the derived state rather
    /// than the raw status: a plan fully used up by its own counted fills is
    /// history even while its stored status still says active.
    private var waitingSellPlanEntries: [TradePlanEntry] {
        boundSellPlanEntries.filter { $0.displayState == .waiting }
    }

    private func boundSellPlanEntry(_ plan: TradePlan) -> TradePlanEntry {
        TradePlanEntry(symbol: card.symbol, plan: plan,
                       transactions: card.item.transactions, accountID: card.accountID)
    }

    /// `card.item.plans` is the card's own instrument's stored order, so a flat
    /// map keeps the entry order the row list has always used.
    private var boundSellPlanEntries: [TradePlanEntry] {
        boundSellPlans.map(boundSellPlanEntry)
    }

    /// The rows the card shows: up to three waiting plans, or — when none is
    /// waiting — the most recently updated settled plan, so a cancelled or
    /// filled intention leaves one trace instead of vanishing.
    ///
    /// The split follows `displayState`, so "a plan is done" is the same
    /// question here as on every other surface: a stale-active plan whose fills
    /// closed it counts as settled and never shows price arrival.
    private var linkedPlanRows: [LinkedPlanRow] {
        let waiting = waitingSellPlanEntries.sorted { $0.plan.updatedAt > $1.plan.updatedAt }
        if waiting.isEmpty {
            guard let latest = boundSellPlanEntries
                .filter({ $0.displayState != .waiting })
                .max(by: { $0.plan.updatedAt < $1.plan.updatedAt }) else { return [] }
            return [row(for: latest)]
        }
        return waiting.prefix(3).map { row(for: $0) }
    }

    private func row(for entry: TradePlanEntry) -> LinkedPlanRow {
        let plan = entry.plan
        // Only a waiting plan still claims shares, so only a waiting plan keeps
        // its remaining size; a settled one is a record of what was intended.
        let isWaiting = entry.displayState == .waiting
        let remaining = entry.remainingQuantity
        let closed = !isWaiting || !(remaining.isFinite && remaining > 0)
        let quantity = closed ? plan.quantity : remaining
        // A waiting plan must still resolve its own binding on the same card,
        // and must not claim more than the shares left after its siblings. A
        // settled plan has no live claim to make, so it is never flagged.
        let available = card.item.availableSalePlanQuantity(for: card.portion.id, excludingPlanID: plan.id)
        let overClaim = !closed && quantity.isFinite
            && quantity > available + PositionAllocation.quantityTolerance(quantity, available)
        let sourceChanged = !closed && (card.item.salePlanSource(for: plan) == nil || overClaim)
        // The linked plan's own instruments type, resolved from the card's item
        // rather than guessed: a sell plan on a fund or an ETF counts units, not
        // shares, and a crypto pair counts its base asset.
        let instrumentType = card.item.resolvedInstrumentType
        return LinkedPlanRow(
            id: plan.id,
            price: plan.price,
            quantity: quantity,
            isReached: isWaiting && isReached(plan),
            sourceChanged: sourceChanged,
            entry: entry,
            menuTitle: PlanValueText.priceQuantity(
                price: plan.price,
                quantity: quantity,
                symbol: card.symbol,
                currencyCode: quote?.currencyCode,
                instrumentType: instrumentType
            )
        )
    }

    /// Price arrival only — a reached trigger is not a fill, and this never
    /// claims the shares moved.
    private func isReached(_ plan: TradePlan) -> Bool {
        guard let quote, quote.price.isFinite, quote.price > 0,
              TradingQuoteHealth.isCurrent(quote) else { return false }
        return plan.isReached(at: quote.price)
    }

    /// The row's headline status. Price arrival and source-changed warnings stay
    /// on the waiting rows, which are the only rows that can still act on them;
    /// everything settled borrows the plan pages' own wording, so a plan the
    /// fills already closed never reads as live here.
    private func statusText(_ row: LinkedPlanRow) -> String {
        if row.displayState != .waiting { return row.entry.displayStatusTitle }
        if row.sourceChanged { return copy("源仓位已变化，请修改计划", "Position changed — edit the plan") }
        return row.isReached ? copy("已到价", "At price") : copy("等待目标价", "Waiting for price")
    }

    /// Actual partial fills remain visible even when waiting stops. A full fill
    /// already names its actual price in the headline, so only its date repeats.
    /// The fill carries its own currency and unit rather than the plan's target.
    private func detailText(_ row: LinkedPlanRow) -> String? {
        let instrumentType = card.item.resolvedInstrumentType
        let parts = row.displayState == .filled
            ? [row.entry.fillDateText]
            : [row.entry.actualFillText(currencyCode: quote?.currencyCode, instrumentType: instrumentType),
               row.entry.fillDateText]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    @ViewBuilder
    private var linkedPlanSummary: some View {
        let rows = linkedPlanRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill").font(.system(size: 8))
                    Text(copy("卖出计划", "Sell plan")).font(.system(size: 9, weight: .semibold))
                    if waitingSellPlanEntries.count > rows.count {
                        Text("+\(waitingSellPlanEntries.count - rows.count)").font(.system(size: 9))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(PlanSideStyle.color(for: TradePlan.Kind.sell))
                ForEach(rows) { row in
                    Button { if canWrite { onEditSalePlan(row.id) } } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.displayState == .filled
                                 ? row.entry.actualFillText(
                                     currencyCode: quote?.currencyCode,
                                     instrumentType: card.item.resolvedInstrumentType) ?? "—"
                                 : PlanValueText.priceQuantity(
                                     price: row.price,
                                     quantity: row.quantity,
                                     symbol: card.symbol,
                                     currencyCode: quote?.currencyCode,
                                     instrumentType: card.item.resolvedInstrumentType))
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(row.sourceChanged ? Color.orange : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(statusText(row))
                                .font(.system(size: 9))
                                .foregroundStyle(row.sourceChanged ? Color.orange : .secondary)
                            if let detail = detailText(row) {
                                Text(detail)
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(5)
                        .background(PlanSideStyle.color(for: TradePlan.Kind.sell).opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canWrite)
                    .help(copy("编辑这项绑定到该仓位份额卡的卖出计划", "Edit the sell plan bound to this position portion"))
                }
            }
            .padding(.top, 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(copy("绑定到该份额的卖出计划 \(rows.count) 项", "\(rows.count) sell plan(s) bound to this portion"))
        }
    }

    /// Whether this card offers a funding annotation at all. The account that
    /// would receive the label is the card's own displayed account — the same
    /// one the tag and the write path use — so a card whose label says Mengmeng
    /// cannot offer a choice its ledger would refuse.
    private var offersFundingMark: Bool { card.accountID != .mengmeng }

    /// Every entry point on the card — menu, drag, accessibility — reads this
    /// single gate, so preview cannot reach a single ledger write. Reconciliation
    /// and a position with no shares are refusals too: both mean the card's
    /// shares are unknown, and neither the menu nor the create callback may
    /// write against that.
    private var canWrite: Bool {
        isDraggable && !isWriteBlocked && !card.needsReview && card.item.positionQuantity > 0
    }

    private var quoteStatus: String? {
        guard let quote, quote.price.isFinite, quote.price > 0,
              quote.timestamp.timeIntervalSince1970.isFinite else { return copy("缺少有效报价", "No valid quote") }
        if !TradingQuoteHealth.isCurrent(quote) {
            return quote.marketState == .closed ? copy("最近收盘", "Last close") : copy("报价偏旧", "Quote stale")
        }
        return nil
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}
