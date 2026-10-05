import SwiftUI
import PulseCore
import PulseUI

struct PoolPlanFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }

    static func id(_ planID: UUID, inPool: Bool) -> String {
        "\(planID.uuidString):\(inPool ? "pool" : "rail")"
    }
}

/// Plan intentions are always dashed; only selected preview figures are assumed.
struct PoolPlanCardFace: View {
    let entry: TradePlanEntry
    let inPool: Bool
    let isSelected: Bool
    let isPlaceholder: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRecord: () -> Void
    let onInspect: () -> Void
    let onAssign: (PositionPool?) -> Void
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    var isDraggable = true
    var tracksFrame = true
    /// Preview only: the card's *figures* are being projected, so they carry the
    /// "≈" prefix and the badge. It does not affect the border — a plan card is
    /// dashed in every stance — and it never fades text.
    var isAssumed = false
    /// Preview only: an explicit include/exclude circle on the card face.
    var isChecked = false
    var showsSelectionCircle = false
    /// Preview only: the card is on the board but left out of the hypothetical
    /// budget. The card stays fully visible and selectable — exclusion is stated,
    /// never shown by removal.
    var isPreviewExcluded = false
    /// The oversell warning this plan produced in the current calculation, if
    /// any. It is shown on the card because a global warning list does not tell
    /// the user *which* plan cannot deliver.
    var overSell: PoolBudgetProjection.OverSellWarning?
    var onToggleCheck: (() -> Void)?
    /// Preview disables every write path on the card.
    var isWriteBlocked = false
    /// Highlight filter is active and this card is not in the filter.
    var isFilteredOut = false

    @Environment(AppState.self) private var appState

    private var quote: Quote? { appState.market.quote(for: entry.symbol) }
    private var currencyCode: String {
        entry.symbol.currencyCode.uppercased()
    }
    private var reached: Bool {
        guard let quote, quote.price.isFinite, quote.price > 0,
              TradingQuoteHealth.isCurrent(quote) else { return false }
        return entry.plan.isReached(at: quote.price)
    }
    private var tint: Color { entry.plan.positionPool?.tint ?? PositionPool.unassigned.tint }
    /// The card's own chrome says what the plan *does* (buy or sell); the pool
    /// tint stays on the labels that name where the shares go.
    private var sideColor: Color { PlanSideStyle.color(for: entry.plan.kind) }
    private var isUnassignedPool: Bool { entry.plan.positionPool == nil }
    private var kindTitle: String {
        entry.plan.kind == .buy
            ? poolCopy("计划买入", "Planned buy")
            : poolCopy("计划卖出", "Planned sell")
    }
    /// What this card says about where the plan's shares come from or go.
    ///
    /// The two nil-pool cases are different statements and get different words.
    /// A buy with no pool is waiting to be classified — it is not "未分配". A
    /// sell with no pool is a sale of the whole instrument whose *source* pool
    /// the user has not named; the projection deliberately does not deduct it
    /// from any pool, so the label must not imply one.
    private var poolLabel: String {
        guard let pool = entry.plan.positionPool else {
            return entry.plan.kind == .buy
                ? poolCopy("待归池", "No pool yet")
                : poolCopy("整标的卖出 · 来源池未指定", "Whole-position sale · source pool unset")
        }
        return pool.title
    }
    private var planAmountTitle: String {
        entry.plan.kind == .buy ? poolCopy("待投入", "To spend") : poolCopy("拟回收", "To raise")
    }
    private var writeBlockHelp: String { poolCopy("切回当前后可操作", "Switch back to Current to act") }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if showsSelectionCircle { selectionCircle }
            VStack(alignment: .leading, spacing: 5) {
                titleRow
                if isPreviewExcluded {
                    Text(poolCopy("未参与预演", "Not in rehearsal"))
                        .font(PoolType.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                priceRow
                fundingRow
                progressRow
                if isSelected, !isPlaceholder, !isWriteBlocked { actionRow }
                if let note = entry.plan.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    Text(note).font(PoolType.label).foregroundStyle(.secondary)
                        .lineLimit(1).help(note)
                }
            }
        }
        .padding(PoolMetric.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isPlaceholder ? 0.2 : (isFilteredOut ? 0.5 : 1))
        .poolBorder(tint: sideColor, isAssumed: true, isEmphasized: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: PoolMetric.cardCorner))
        .onTapGesture(perform: onSelect)
        .contextMenu { contextMenu }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("position-pools-board"))
                .onChanged(onDragChanged)
                .onEnded(onDragEnded),
            including: (isDraggable && !isWriteBlocked) ? .all : .none
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(poolCopy("选中计划", "Select plan")), onSelect)
        .accessibilityAction(named: Text(poolCopy("编辑计划", "Edit plan"))) { if !isWriteBlocked { onEdit() } }
        .accessibilityAction(named: Text(poolCopy("记录已成交", "Record fill"))) { if !isWriteBlocked { onRecord() } }
        .accessibilityAction(named: Text(poolCopy("逻辑与修改记录", "Thesis and history"))) { if !isWriteBlocked { onInspect() } }
        .accessibilityAction(named: Text(poolCopy("清除用途关联", "Clear pool link"))) { if !isWriteBlocked { onAssign(nil) } }
        .background {
            if tracksFrame {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PoolPlanFrameKey.self,
                        value: [PoolPlanFrameKey.id(entry.id, inPool: inPool): proxy.frame(in: .named("position-pools-board"))]
                    )
                }
            }
        }
    }

    // MARK: - Rows

    private var selectionCircle: some View {
        Button {
            onToggleCheck?()
        } label: {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isChecked ? sideColor : Color.secondary)
                .frame(width: PoolMetric.minimumTarget, height: PoolMetric.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(poolCopy("纳入预演", "Include in preview"))
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            Button(action: onSelect) {
                Text(appState.displayName(for: entry.symbol))
                    .font(PoolType.cardTitle)
                    .lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            Text(entry.symbol.displayCode)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            if isAssumed { PoolAssumedBadge(tint: sideColor) }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isWriteBlocked)
            .help(isWriteBlocked ? writeBlockHelp : poolCopy("计划操作", "Plan actions"))
            .accessibilityLabel(poolCopy("计划操作", "Plan actions"))
        }
    }

    private var priceRow: some View {
        HStack(spacing: 5) {
            if let account = entry.accountID, account != .unassigned {
                Text(AccountIdentity.title(account)).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(AccountIdentity.dotColor(account))
            }
            Text(kindTitle)
                .font(PoolType.labelMedium)
                .foregroundStyle(sideColor)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(sideColor.opacity(0.1), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(entry.plan.kind == .buy
                                    ? poolCopy("计划买入", "Planned buy")
                                    : poolCopy("计划卖出", "Planned sell"))
            Text(PriceFormatter.price(entry.plan.price, market: entry.symbol.market))
                .font(PoolType.number)
            Text("× \(PriceFormatter.quantity(entry.remainingQuantity))")
                .font(PoolType.number).foregroundStyle(.secondary)
            // Dashed, so an intention never reads as a holding. It renders for
            // `.margin` only: an own-capital plan needs no tag to explain it,
            // and a legacy plan adds no row at all.
            PlannedFundingTag(source: entry.plan.fundingSource)
            Spacer(minLength: 0)
            if reached {
                PoolStatusPill(systemImage: "target", text: poolCopy("到价", "At price"), tint: .orange)
            }
        }
    }

    private var fundingRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let overSell {
                    // The plan cannot deliver this sale, so the plan-priced
                    // amount is not prospective proceeds. Say what it is.
                    Text(overSellLabel(overSell))
                        .font(PoolType.label)
                        .foregroundStyle(.orange)
                } else {
                    Text(planAmountTitle).font(PoolType.label).foregroundStyle(.secondary)
                    // The projected figure carries the plan's side colour in the
                    // rehearsal, so a row of "≈" numbers still says which are
                    // buys and which are sells without reading every badge.
                    Text(PoolAmountText.money(entry.remainingEstimatedAmount, currency: currencyCode, assumed: isAssumed))
                        .font(isAssumed ? PoolType.assumedNumber : PoolType.number)
                        .foregroundStyle(isAssumed ? sideColor : Color.primary)
                }
                Spacer(minLength: 0)
                if !inPool {
                    Text(poolLabel)
                        .font(PoolType.label)
                        .foregroundStyle(isUnassignedPool && entry.plan.kind == .sell ? .orange : .secondary)
                        .lineLimit(1)
                }
            }
            if let overSell {
                // Requested vs actually available, in shares, within the scope
                // the calculator checked. A global banner cannot say which plan
                // is short or by how much.
                Text(poolCopy("可卖 ", "Available ")
                     + PriceFormatter.quantity(overSell.available)
                     + poolCopy(" / 计划卖 ", " of ")
                     + PriceFormatter.quantity(overSell.requested)
                     + " · "
                     + (overSell.scope == .position
                        ? poolCopy("整个持仓不足", "position is short")
                        : poolCopy("该用途份额不足", "pool share is short")))
                    .font(PoolType.label.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The honest label for a sell whose backing does not exist. It never reads
    /// as recoverable proceeds.
    private func overSellLabel(_ warning: PoolBudgetProjection.OverSellWarning) -> String {
        _ = warning
        let amount = PriceFormatter.money(entry.remainingEstimatedAmount, currencyCode: currencyCode)
        return poolCopy("卖出计划额（超额，未预演） ", "Planned sale (over-committed, not rehearsed) ") + amount
    }

    /// One badge, not a row of state dots.
    ///
    /// The per-condition dot loop that used to live here is gone: a card that
    /// already shows "条件 n/m" plus a single verification badge said the same
    /// thing twice, and five coloured dots could not be read without hovering
    /// each one. The exact condition count is retained — it is the one figure the
    /// dots were standing in for — and the badge carries the state. The linked
    /// events are this instrument's own, filtered to the exact symbol so a
    /// condition is never judged against another listing's calendar.
    @ViewBuilder private var progressRow: some View {
        if entry.filledQuantity > 0 || !(entry.plan.conditions ?? []).isEmpty {
            HStack(spacing: 5) {
                if entry.filledQuantity > 0 {
                    Text(poolCopy("已成交 ", "Filled ")
                         + PriceFormatter.quantity(entry.filledQuantity)
                         + poolCopy(" · 待执行 ", " · Remaining ")
                         + PriceFormatter.quantity(entry.remainingQuantity))
                        .font(PoolType.label.monospacedDigit())
                }
                Spacer(minLength: 0)
                if let conditions = entry.plan.conditions, !conditions.isEmpty {
                    Text(poolCopy("条件 ", "Cond ") + "\(confirmedCount(conditions))/\(conditions.count)")
                        .font(PoolType.label.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let badge = verificationBadge {
                    VerificationBadge(badge: badge, compact: true)
                }
            }
        }
    }

    private var verificationBadge: PositionVerificationBadge? {
        guard entry.plan.conditions?.isEmpty == false else { return nil }
        let events = appState.tradingEvents.entries(for: appState.watchlist.allItems)
            .filter { $0.symbol == entry.symbol }
            .map(\.event)
        return VerificationBadge.resolve(conditions: entry.plan.conditions, currentEvents: events)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(poolCopy("记录成交", "Record fill"), action: onRecord)
            Button(poolCopy("逻辑 / 历史", "Thesis / history"), action: onInspect).disabled(isWriteBlocked)
        }
        .font(PoolType.label).controlSize(.mini)
    }

    @ViewBuilder private var menuItems: some View {
        Button(poolCopy("记录已成交", "Record fill"), action: onRecord)
        // The workflow sheet edits conditions and writes them back, so it is a
        // write path and is refused in preview like the others.
        Button(poolCopy("逻辑与修改记录", "Thesis and history"), action: onInspect).disabled(isWriteBlocked)
        Button(poolCopy("编辑计划", "Edit plan"), action: onEdit)
        Divider()
        ForEach(PositionPool.activeCases, id: \.self) { pool in
            Button(poolCopy("关联", "Link ") + pool.title) { onAssign(pool) }
        }
        Button(poolCopy("清除用途关联", "Clear pool link")) { onAssign(nil) }
    }

    @ViewBuilder private var contextMenu: some View {
        Button(poolCopy("记录已成交", "Record fill"), action: onRecord).disabled(isWriteBlocked)
        Button(poolCopy("逻辑与修改记录", "Thesis and history"), action: onInspect).disabled(isWriteBlocked)
        Button(poolCopy("编辑计划", "Edit plan"), action: onEdit).disabled(isWriteBlocked)
        Divider()
        ForEach(PositionPool.activeCases, id: \.self) { pool in
            Button(poolCopy("关联", "Link ") + pool.title) { onAssign(pool) }.disabled(isWriteBlocked)
        }
        Button(poolCopy("清除用途关联", "Clear pool link")) { onAssign(nil) }.disabled(isWriteBlocked)
    }

    private func confirmedCount(_ conditions: [TradePlanCondition]) -> Int {
        conditions.filter { $0.state == .confirmed }.count
    }
}

// MARK: - Lineage

/// One already-recorded fill in a plan's lineage, paired with where its shares
/// sit right now.
///
/// The distribution is read from the allocation's *portions* by their
/// `origin.transactionID`. When no portion names this fill the block says so
/// ("snapshot or unallocated") rather than guessing a pool — a share whose
/// origin was never recorded cannot be attributed backwards.
struct PlanFillLineage: Identifiable {
    let transaction: PositionTransaction
    let portions: [PositionPortion]

    var id: UUID { transaction.id }

    var poolTotals: [(pool: PositionPool, quantity: Double)] {
        var totals: [PositionPool: Double] = [:]
        // Effective purpose, so a legacy observation portion is reported under
        // unassigned rather than resurrecting a purpose the product retired.
        for portion in portions { totals[portion.pool.effectivePurpose, default: 0] += portion.quantity }
        return PositionPool.activeCases.compactMap { pool in
            let quantity = totals[pool] ?? 0
            return quantity > 0 ? (pool, quantity) : nil
        }
    }
}

/// The inline lineage block: conditions → plan → matched fills → current
/// distribution → remaining intention. Read-only; it reports what the ledger
/// and the allocation already say.
struct PoolPlanLineageView: View {
    let entry: TradePlanEntry
    let fills: [PlanFillLineage]
    /// Portions whose origin is this plan's instrument but not one of the
    /// matched fills — the "snapshot or unallocated" case.
    let unattributedQuantity: Double
    /// Preview: the remaining node is drawn dashed and prefixed with "≈".
    let isAssumed: Bool
    let reduceMotion: Bool
    let onExpand: () -> Void

    @State private var showsAllFills = false

    private var tint: Color { entry.plan.positionPool?.tint ?? PositionPool.unassigned.tint }
    /// The lineage says what the plan does on the side label; the node dots keep
    /// the pool colour, because a node is about where shares go.
    private var sideColor: Color { PlanSideStyle.color(for: entry.plan.kind) }
    private var conditions: [TradePlanCondition] { entry.plan.conditions ?? [] }
    private var confirmed: Int { conditions.filter { $0.state == .confirmed }.count }
    private var visibleFills: [PlanFillLineage] {
        showsAllFills ? fills : Array(fills.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeOne
            nodeTwo
            ForEach(visibleFills) { fill in fillNode(fill) }
            if unattributedQuantity > 0 { unattributedNode }
            if fills.count > visibleFills.count {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showsAllFills = true }
                } label: {
                    Text(poolCopy("展开其余 \(fills.count - visibleFills.count) 笔",
                                  "Show \(fills.count - visibleFills.count) more"))
                        .font(PoolType.label)
                }
                .buttonStyle(.link)
                .padding(.leading, 16).padding(.bottom, 6)
            }
            remainingNode
        }
        .padding(8)
        .background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.3), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(poolCopy("计划脉络", "Plan lineage"))
    }

    private var nodeOne: some View {
        PoolLineageNode(tint: tint) {
            HStack(spacing: 6) {
                Text(poolCopy("条件", "Conditions")).font(PoolType.labelMedium)
                if conditions.isEmpty {
                    Text(poolCopy("未设条件", "No conditions")).font(PoolType.label).foregroundStyle(.secondary)
                } else {
                    Text("\(confirmed)/\(conditions.count)").font(PoolType.label.monospacedDigit())
                    Text(poolCopy("已确认", "confirmed")).font(PoolType.label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nodeTwo: some View {
        PoolLineageNode(tint: tint) {
            HStack(spacing: 6) {
                Text(entry.plan.kind == .buy ? poolCopy("买入计划", "Buy plan") : poolCopy("卖出计划", "Sell plan"))
                    .font(PoolType.labelMedium)
                    .foregroundStyle(sideColor)
                Text(PriceFormatter.price(entry.plan.price, market: entry.symbol.market))
                    .font(PoolType.label.monospacedDigit())
                Text("× \(PriceFormatter.quantity(entry.plan.quantity))")
                    .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                if let pool = entry.plan.positionPool {
                    Text("→ \(pool.title)").font(PoolType.label).foregroundStyle(tint)
                } else {
                    Text(poolCopy("→ 未指定用途", "→ No pool")).font(PoolType.label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fillNode(_ fill: PlanFillLineage) -> some View {
        PoolLineageNode(tint: tint) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(poolCopy("已成 ", "Filled ") + PriceFormatter.quantity(fill.transaction.quantity))
                        .font(PoolType.labelMedium.monospacedDigit())
                    Text(fill.transaction.date.formatted(date: .abbreviated, time: .omitted))
                        .font(PoolType.label).foregroundStyle(.secondary)
                    Text("@ " + PriceFormatter.price(fill.transaction.price, market: entry.symbol.market))
                        .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                }
                if fill.poolTotals.isEmpty {
                    Text(poolCopy("快照或未分账", "Snapshot or unallocated"))
                        .font(PoolType.label).foregroundStyle(.secondary)
                } else {
                    Text(poolCopy("现分布 ", "Now ")
                         + fill.poolTotals.map { "\($0.pool.title) \(PriceFormatter.quantity($0.quantity))" }
                            .joined(separator: " / "))
                        .font(PoolType.label).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var unattributedNode: some View {
        PoolLineageNode(tint: tint) {
            Text(poolCopy("另有快照份额 \(PriceFormatter.quantity(unattributedQuantity)) · 来源未记录，需核对",
                          "\(PriceFormatter.quantity(unattributedQuantity)) snapshot shares with no recorded origin"))
                .font(PoolType.label).foregroundStyle(.secondary)
        }
    }

    private var remainingNode: some View {
        PoolLineageNode(tint: tint, isAssumed: isAssumed, isLast: true) {
            VStack(alignment: .leading, spacing: 2) {
                if entry.remainingQuantity > 0 {
                    // Remaining quantity is a recorded plan fact, not an
                    // estimate: in current mode it is exact and carries no "≈".
                    // The sign is added only when the node itself is
                    // hypothetical, matching the amount line below it.
                    Text(poolCopy("剩余 ", "Remaining ")
                         + (isAssumed
                            ? PoolAmountText.assumed(PriceFormatter.quantity(entry.remainingQuantity))
                            : PriceFormatter.quantity(entry.remainingQuantity))
                         + poolCopy(" → 目标 ", " → target ")
                         + (entry.plan.positionPool?.title ?? poolCopy("未指定", "unset")))
                        .font(isAssumed ? PoolType.assumedNumber : PoolType.labelMedium.monospacedDigit())
                    Text(PoolAmountText.money(entry.remainingEstimatedAmount,
                                              currency: entry.symbol.currencyCode, assumed: isAssumed))
                        .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    Text(poolCopy("计划已全部成交", "Plan fully filled"))
                        .font(PoolType.labelMedium).foregroundStyle(.secondary)
                }
            }
        }
    }
}
