import AppKit
import SwiftUI
import PulseCore
import PulseUI

struct PositionPoolsView: View {
    enum Mode: String, CaseIterable { case board, symbol }

    /// The board's two mutually exclusive stances. `current` shows the ledger
    /// as it is and is the only stance that may write; `preview` recomputes the
    /// same projection over a hand-picked set of plans and greys out every
    /// mutation. The mode is deliberately not persisted — a relaunch always
    /// starts on the real book.
    enum Stance: String, CaseIterable {
        case current
        case preview

        var title: String {
            self == .current ? poolCopy("当前实仓", "Held now") : poolCopy("计划成交后", "After plans fill")
        }
    }

    struct PoolDropTarget: Hashable {
        var pool: PositionPool
        var symbol: SymbolID?
    }

    /// Only the proxy observes location; the board observes target changes.
    @Observable
    final class PositionPoolDragMotion {
        var location: CGPoint = .zero
        var target: PoolDropTarget?

        func move(to point: CGPoint, target resolved: PoolDropTarget?) {
            location = point
            if target != resolved { target = resolved }
        }
    }

    /// A lightweight replacement for the full card during a drag.
    struct DragBadge: View {
        var pool: PositionPool
        var title: String
        var code: String
        var detail: String
        var isSplit = false
        /// The funding annotation this portion carries, as a short word. It is
        /// folded into the badge's detail line rather than drawn as its own
        /// capsule: the badge is deliberately cheap, and a second view here
        /// would add per-mouse-move layout work for a label that never changes
        /// during the drag.
        var fundingTag: String?
        /// Plan drags only: which half of the detail line is 买入/卖出, so that
        /// one word can carry the side colour while the pool dot keeps the pool
        /// colour. Nil for a holding drag, whose detail has no side at all.
        var side: TradePlan.Kind?
        var sourceWidth: CGFloat = 220

        static let height: CGFloat = 40
        static let maximumWidth: CGFloat = 260

        /// Fixed height, width the source's width capped at 260pt.
        static func width(forSourceWidth sourceWidth: CGFloat) -> CGFloat {
            min(max(sourceWidth, 1), maximumWidth)
        }

        static func size(forSourceWidth sourceWidth: CGFloat) -> CGSize {
            CGSize(width: width(forSourceWidth: sourceWidth), height: height)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(pool.tint).frame(width: 6, height: 6)
                    Text(title).font(PoolType.labelMedium).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                    Text(code).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(detailText).font(PoolType.labelMedium.monospacedDigit()).lineLimit(1)
                    Spacer(minLength: 0)
                    if let fundingTag {
                        Text(fundingTag).font(PoolType.label)
                            .foregroundStyle(PoolFundingStyle.marginTint).fixedSize()
                    }
                    if isSplit {
                        Text(copy("拆分", "Split")).font(PoolType.label).foregroundStyle(.orange).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 9)
            .frame(width: Self.width(forSourceWidth: sourceWidth), height: Self.height)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(pool.tint.opacity(0.55), lineWidth: 1) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        /// The detail line with its leading 买入/卖出 word in the side colour.
        /// The rest of the line — the price, the quantity — stays neutral: those
        /// are figures, and the drag badge must not look like a P&L reading.
        private var detailText: AttributedString {
            var text = AttributedString(detail)
            guard let side else { return text }
            let word = side == .buy ? copy("买入", "Buy") : copy("卖出", "Sell")
            guard let range = text.range(of: word),
                  text[range].characters.count == word.count else { return text }
            text[range].foregroundColor = PlanSideStyle.color(for: side)
            return text
        }

        private func copy(_ chinese: String, _ english: String) -> String {
            PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
        }
    }

    /// Internal so the DEBUG harness can build card fixtures for
    /// `visiblePools`; production only ever reads it.
    struct PortionCard: Identifiable {
        var item: WatchItem
        var portion: PositionPortion
        var needsReview: Bool
        var ownerAccountID: BrokerageAccountID = .unassigned
        var accountID: BrokerageAccountID { portion.brokerageAccountID ?? ownerAccountID }
        var id: String { "\(ownerAccountID.rawValue):\(item.symbol.description):\(portion.id.uuidString)" }
        var symbol: SymbolID { item.symbol }
        /// The purpose this card is *read* as. A portion stored against the
        /// retired observation purpose has no active meaning, so it reads as
        /// unassigned through `effectivePurpose` — the stored raw value is left
        /// alone, and an untouched legacy record stays byte for byte identical.
        var pool: PositionPool { portion.pool.effectivePurpose }
        var quantity: Double { portion.quantity }
        var allocationRevision: UUID? { item.positionAllocation?.revision }
    }

    struct TransferDraft: Identifiable {
        var symbol: SymbolID
        var portionID: UUID
        var destination: PositionPool?
        var id: String { "transfer-\(symbol.description)-\(portionID)" }
    }

    /// Marks which money one portion card was bought with. It is a labelling
    /// draft like `TransferDraft`, not a transfer: no shares move, and the
    /// destination is a funding source rather than a pool.
    struct FundingDraft: Identifiable {
        var symbol: SymbolID
        var portionID: UUID
        var id: String { "funding-\(symbol.description)-\(portionID)" }
    }

    /// Opens the verification editor for one portion card. It has the same shape
    /// as `FundingDraft` because it names the same target — one portion of one
    /// symbol — and nothing else; verification is a per-card edit, not a
    /// per-pool or per-symbol one.
    struct VerificationDraft: Identifiable {
        var symbol: SymbolID
        var portionID: UUID
        var id: String { "verification-\(symbol.description)-\(portionID)" }
    }

    enum Sheet: Identifiable {
        case transfer(TransferDraft)
        case funding(FundingDraft)
        case verification(VerificationDraft)
        case reconcile(SymbolID)
        case syncConflict(String)
        case plan(SymbolID, UUID?)
        case execution(SymbolID, UUID)
        case workflow(SymbolID, UUID)
        case scenario

        var id: String {
            switch self {
            case .transfer(let draft): draft.id
            case .funding(let draft): draft.id
            case .verification(let draft): draft.id
            case .reconcile(let symbol): "reconcile-\(symbol.description)"
            case .syncConflict(let peerID): "sync-\(peerID)"
            case .plan(let symbol, let id): "plan-\(symbol.description)-\(id?.uuidString ?? "new")"
            case .execution(let symbol, let id): "execution-\(symbol.description)-\(id)"
            case .workflow(let symbol, let id): "workflow-\(symbol.description)-\(id)"
            case .scenario: "scenario"
            }
        }

        /// Whether this sheet can change the ledger, a plan, or an allocation.
        ///
        /// `.workflow` is mutating: the workflow detail view edits a plan's
        /// conditions and writes them back through the store, so classifying it
        /// read-only left a hole in the preview guard. `.funding` writes an
        /// allocation change log entry, so it is mutating too. Only the scenario
        /// sheet, which stores names and ids rather than money, is non-mutating;
        /// cash and limit editing stays allowed because that is a setting.
        /// Exposed so the DEBUG harness can assert the real policy rather
        /// than a duplicated copy of it.
        static func isMutating(_ sheet: Sheet) -> Bool { sheet.blocksPreviewWrites }

        var blocksPreviewWrites: Bool {
            switch self {
            case .scenario: false
            case .transfer, .funding, .verification, .reconcile, .syncConflict, .plan, .execution, .workflow: true
            }
        }
    }

    private struct UndoState {
        var symbol: SymbolID
        var previous: PositionAllocation
        var expectedRevision: UUID
        var accountID: BrokerageAccountID = .unassigned
    }

    private struct DragState {
        var card: PortionCard
        var sourceFrame: CGRect
        var grabOffset: CGPoint
        var shift: Bool
    }

    private struct PlanDrag {
        let entry: TradePlanEntry
        let inPool: Bool
        let source: CGRect
        let grip: CGPoint
    }

    fileprivate struct DropFrames: Equatable {
        var cards: [String: CGRect] = [:]
        var pools: [PoolDropTarget: CGRect] = [:]
        var viewport: CGRect?
    }

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    let onSelect: (SymbolID) -> Void
    var onShowPlans: () -> Void = {}

    @State private var mode: Mode = .board
    @State private var currencyFilter = "*"
    @State private var accountFilter: BrokerageAccountID?
    @State private var activeSheet: Sheet?
    @State private var undo: UndoState?
    @State private var drag: DragState?
    @State private var planDrag: PlanDrag?
    /// Hot pointer state. Only the drag badge observes `location`.
    @State private var motion = PositionPoolDragMotion()
    @State private var planFrames: [String: CGRect] = [:]
    @State private var selectedPlanID: UUID?
    @State private var showsPlanRail = true
    /// Whether the selected plan's lineage disclosure is open in the rail.
    /// Reset to `false` whenever the selection changes, so a panel opened for
    /// one plan never appears to describe the next one.
    @State private var showsPlanLineage = false
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var dropFrames: [PoolDropTarget: CGRect] = [:]
    @State private var viewportFrame: CGRect?
    @State private var errorMessage: String?
    @State private var showingError = false

    // MARK: Tactical / preview state

    /// Current or hypothetical. Nothing else on the board is stance-dependent.
    @State private var stance: Stance = .current
    /// The plans the hypothetical reckons with. Empty means "all active plans
    /// in the current currency", so switching to preview is never a dead end.
    @State private var previewPlanIDs: Set<UUID> = []
    @State private var previewExplicitSelection = false
    /// Which action chip is highlighting, if any. Highlight only — it never
    /// changes a total.
    @State private var highlightFilter: HighlightFilter?
    @State private var showsWarnings = false
    /// Narrow layout: the plan shelf folds into a bottom drawer.
    @State private var showsPlanDrawer = false
    @State private var showsManageMenu = false

    fileprivate enum HighlightFilter: Equatable {
        case reached
        case conditionsDue
        case allocationReview
        /// Highlights the real margin-funded portions. It deliberately does not
        /// match plan cards: a plan's "拟融资" is an intention, not a holding,
        /// and letting it into this population would overstate what is actually
        /// borrowed.
        case funding
        /// Carries the gap kind so selecting a chip highlights the same
        /// population the chip described, whether that was an unknown balance
        /// or a quantified shortfall.
        case cashGap(CashGap)
    }

    /// Test seam: lets the DEBUG self-test open the board in a known stance
    /// with a known selection. Production code never calls it.
    struct TacticalInitialState {
        var stance: Stance = .current
        var previewPlanIDs: Set<UUID> = []
        /// Present so the seam can express "the user deliberately unchecked
        /// everything", which an empty `previewPlanIDs` alone cannot: empty with
        /// this false means "untouched, therefore all active plans".
        var previewExplicitSelection = false
        var selectedPlanID: UUID?
        var currencyFilter = "*"
        var accountFilter: BrokerageAccountID?
        var mode: Mode = .board
        var showsPlanRail = true
        var showsPlanLineage = false
        var showsPlanDrawer = false

        /// Test seams for the debug render harness. Production always starts on
        /// `current` with no selection and a collapsed capital panel.
        static let current = TacticalInitialState()
        static let preview = TacticalInitialState(stance: .preview, showsPlanRail: false)
        /// Preview with every plan deliberately unchecked.
        static let previewEmpty = TacticalInitialState(stance: .preview,
                                                      previewExplicitSelection: true,
                                                      showsPlanRail: false)
        static func previewSubset(_ planIDs: Set<UUID>) -> TacticalInitialState {
            TacticalInitialState(stance: .preview,
                                 previewPlanIDs: planIDs,
                                 previewExplicitSelection: true,
                                 showsPlanRail: false)
        }
        static func focus(_ planID: UUID?) -> TacticalInitialState {
            TacticalInitialState(selectedPlanID: planID)
        }
    }

    private var isPreviewing: Bool { stance == .preview }
    private var isWriteBlocked: Bool { isPreviewing }

    init(onSelect: @escaping (SymbolID) -> Void, onShowPlans: @escaping () -> Void = {},
         tactical: TacticalInitialState? = nil) {
        self.onSelect = onSelect
        self.onShowPlans = onShowPlans
        guard let tactical else { return }
        _stance = State(initialValue: tactical.stance)
        _previewPlanIDs = State(initialValue: tactical.previewPlanIDs)
        _previewExplicitSelection = State(initialValue: tactical.previewExplicitSelection
                                          || !tactical.previewPlanIDs.isEmpty)
        _selectedPlanID = State(initialValue: tactical.selectedPlanID)
        _showsPlanLineage = State(initialValue: tactical.showsPlanLineage)
        _showsPlanDrawer = State(initialValue: tactical.showsPlanDrawer)
        _currencyFilter = State(initialValue: tactical.currencyFilter)
        _accountFilter = State(initialValue: tactical.accountFilter)
        _mode = State(initialValue: tactical.mode)
        _showsPlanRail = State(initialValue: tactical.showsPlanRail)
    }

    private var boardRecords: [BrokerageBoardItem] { BrokerageBoardReader.records(store: appState.watchlist) }
    private var allBoardItems: [WatchItem] { boardRecords.map(\.item) }
    private var allPlanEntries: [TradePlanEntry] {
        BrokerageBoardReader.entries(store: appState.watchlist).filter { accountFilter == nil || $0.accountID == accountFilter }
    }
    private func storedItem(_ symbol: SymbolID, in account: BrokerageAccountID) -> WatchItem? {
        let portfolio = appState.watchlist.brokeragePortfolio(for: account)
        return (portfolio.items + portfolio.retainedHistoryItems).first { $0.symbol == symbol }
    }
    private func openSheet(_ sheet: Sheet, in account: BrokerageAccountID) {
        guard !isWriteBlocked else { return }
        // Selecting the source ledger authorizes an existing draft; the board's filter stays independent.
        if account != appState.watchlist.activeBrokerageAccountID { appState.selectBrokerageAccount(account) }
        activeSheet = sheet
    }
    private func setAccount(_ account: BrokerageAccountID, on card: PortionCard) {
        guard !isWriteBlocked, !card.needsReview, let revision = card.allocationRevision,
              !conflictedSymbols.contains(card.symbol) else { return }
        do {
            let updated = try appState.watchlist.withBrokerageAccount(card.ownerAccountID) {
                try appState.watchlist.setPositionBrokerageAccount(symbol: card.symbol, portionID: card.portion.id,
                    accountID: account, expectedRevision: revision)
            }
            if updated.revision != revision, let previous = card.item.positionAllocation {
                undo = UndoState(symbol: card.symbol, previous: previous, expectedRevision: updated.revision, accountID: card.ownerAccountID)
            }
        } catch { showError(error.localizedDescription) }
    }

    private func newPlan(for item: WatchItem) {
        let account = accountFilter ?? appState.watchlist.activeBrokerageAccountID
        guard !isWriteBlocked else { return }
        appState.watchlist.withBrokerageAccount(account) {
            if appState.watchlist.item(for: item.symbol) == nil {
                appState.watchlist.add(SymbolInfo(symbol: item.symbol, name: item.resolvedDisplayName))
            }
        }
        openSheet(.plan(item.symbol, nil), in: account)
    }
    private func openScenario() {
        let accounts = Set(previewCandidates.compactMap(\.accountID))
        guard accounts.count <= 1 || accountFilter != nil else {
            showError(copy("先筛选一个账户，再保存或载入该账户的预演。", "Filter an account before saving or loading its scenario."))
            return
        }
        let account = accountFilter ?? accounts.first ?? appState.watchlist.activeBrokerageAccountID
        appState.selectBrokerageAccount(account)
        activeSheet = .scenario
    }

    // MARK: Preview plan set

    /// Every active plan the board is willing to rehearse, in the current
    /// currency filter. This mirrors `plannedEntries` but keeps plans that have
    /// nothing left to fill out of the pick list.
    private var previewCandidates: [TradePlanEntry] {
        allPlanEntries.filter {
            $0.plan.status == .active && $0.plan.price.isFinite && $0.plan.price > 0
                && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0
                && $0.remainingEstimatedAmount.isFinite
                && (currencyFilter == "*" || currencyCode(for: $0.symbol) == currencyFilter)
        }
    }

    /// The plan set the hypothetical budget actually uses. An untouched preview
    /// means "every active plan", so the first switch to preview still shows a
    /// complete budget rather than an empty one. This drives money only — never
    /// which cards exist.
    private var previewEntries: [TradePlanEntry] {
        guard isPreviewing, previewExplicitSelection else {
            return isPreviewing ? previewCandidates : plannedEntries
        }
        let chosen = previewPlanIDs
        return previewCandidates.filter { chosen.contains($0.id) }
    }

    /// The plans the board renders.
    ///
    /// In preview this deliberately stays the full candidate set rather than the
    /// selected subset: unchecking a plan must remove it from the budget without
    /// removing its card, otherwise the user cannot see what they excluded and
    /// cannot check it back in. Exclusion is shown on the card as an explicit
    /// "not in rehearsal" state, never by disappearance. The one historical
    /// exception is a completed plan kept only because it is being focused.
    private var boardEntries: [TradePlanEntry] {
        var entries = isPreviewing ? previewCandidates : plannedEntries
        if let selectedPlanID,
           !entries.contains(where: { $0.id == selectedPlanID }),
           let historical = allPlanEntries.first(where: { $0.id == selectedPlanID }),
           currencyFilter == "*" || currencyCode(for: historical.symbol) == currencyFilter {
            entries.append(historical)
        }
        return entries
    }

    private func isPlanInPreview(_ entry: TradePlanEntry) -> Bool {
        guard isPreviewing, entry.plan.status == .active, entry.remainingQuantity > 0 else { return false }
        guard previewExplicitSelection else { return true }
        return previewPlanIDs.contains(entry.id)
    }

    /// The plan ids the budget should use, or nil to mean "every active plan".
    ///
    /// This is the single place the selection is turned into a calculator
    /// argument. Preview with nothing explicitly picked passes nil so the first
    /// switch still shows a complete budget; an explicit empty selection passes
    /// an empty set, which is a real answer and must not be read as "all".
    private var selectedPlanIDs: Set<UUID>? {
        guard isPreviewing, previewExplicitSelection else { return nil }
        return previewPlanIDs
    }

    /// The one projection input for this screen, built from the live store.
    /// Every money surface on the board derives from this.
    private var boardInput: PoolBudgetInput {
        PoolBudgetInput(appState: appState, currencyFilter: currencyFilter, planIDs: selectedPlanIDs, accountFilter: accountFilter, allAccounts: true)
    }

    // MARK: Action tasks
    //
    // A private copy of the workbench's task derivation. It is duplicated on
    // purpose: moving it to a shared type would make the workbench a dependency
    // of this screen for four counts, and the workbench's version is keyed to
    // its own card layout. These answers feed highlight-only chips.

    private var reachedPlanCount: Int {
        boardEntries.filter { entry in
            guard entry.plan.status == .active, entry.remainingQuantity > 0,
                  let quote = appState.market.quote(for: entry.symbol),
                  quote.price.isFinite, quote.price > 0,
                  TradingQuoteHealth.isCurrent(quote) else { return false }
            return entry.plan.isReached(at: quote.price)
        }.count
    }

    private func conditionsNeedReview(_ entry: TradePlanEntry) -> Bool {
        guard entry.plan.status == .active, entry.remainingQuantity > 0 else { return false }
        let today = Calendar.current.startOfDay(for: .now)
        return (entry.plan.conditions ?? []).contains {
            $0.state != .confirmed || ($0.reviewDate.map { $0 < today } ?? false)
        }
    }

    private var conditionsDueCount: Int {
        boardEntries.filter(conditionsNeedReview).count
    }

    /// Allocations that cannot be trusted yet: a stale revision, a mismatched
    /// ledger, a conflict, or no allocation at all on a live position.
    private var allocationReviewCount: Int {
        eligibleItems.filter { item in
            guard item.positionQuantity > 0 else { return false }
            guard let allocation = item.positionAllocation else { return true }
            let total = allocation.portions.reduce(0) { $0 + $1.quantity }
            return item.positionAllocationNeedsReconciliation
                || abs(total - item.positionQuantity) > PositionAllocation.quantityTolerance(total, item.positionQuantity)
                || !allocation.hasMatchingSources(for: item)
                || conflictedSymbols.contains(item.symbol)
        }.count
    }

    /// A currency whose active buys exceed — or cannot be compared to — its
    /// recorded cash.
    ///
    /// The two states are deliberately distinct. "No balance recorded" is a data
    /// problem with no number attached; "short by ¥x" is a concrete,
    /// quantified shortfall. Collapsing them into one label told the user
    /// neither which was true nor how large the gap was.
    fileprivate enum CashGap: Equatable {
        case unknownBalance(String)
        case shortfall(String, Double)

        var currency: String {
            switch self {
            case .unknownBalance(let code), .shortfall(let code, _): code
            }
        }

        var chipText: String {
            switch self {
            case .unknownBalance(let code):
                poolCopy("\(code) 现金未录", "\(code) cash not recorded")
            case .shortfall(let code, let amount):
                poolCopy("\(code) 缺口 \(PriceFormatter.money(amount, currencyCode: code))",
                         "\(code) short \(PriceFormatter.money(amount, currencyCode: code))")
            }
        }

        var help: String {
            switch self {
            case .unknownBalance(let code):
                poolCopy("\(code) 尚未录入现金余额，无法判断买入余量。",
                         "No \(code) cash balance recorded, so the buying budget cannot be judged.")
            case .shortfall(let code, let amount):
                poolCopy("\(code) 已录现金比计划买入少 \(PriceFormatter.money(amount, currencyCode: code))。",
                         "Recorded \(code) cash is \(PriceFormatter.money(amount, currencyCode: code)) below the planned buys.")
            }
        }
    }

    /// Currencies whose active buys exceed (or cannot be compared to) their
    /// recorded cash. The unknown-balance case counts: it is exactly the state
    /// the user has to fix before any budget figure means anything.
    private var cashGaps: [CashGap] {
        let input = PoolBudgetInput(appState: appState, currencyFilter: currencyFilter,
                                    planIDs: isPreviewing && previewExplicitSelection ? previewPlanIDs : nil, accountFilter: accountFilter, allAccounts: true)
        let result = input.calculate()
        return result.currencies.compactMap { currency in
            guard currency.plannedBuyAmount > 0 else { return nil }
            if currency.cashBalance == nil {
                return .unknownBalance(currency.code)
            }
            guard currency.cashShortfall > 0 else { return nil }
            return .shortfall(currency.code, currency.cashShortfall)
        }.sorted { $0.currency < $1.currency }
    }

    private var hasAnyAction: Bool {
        reachedPlanCount + conditionsDueCount + allocationReviewCount + cashGaps.count > 0
            || marginHighlightCount > 0
    }

    /// The warning list behind the compressed chip. Each entry is one of the
    /// three banners the board used to show permanently; each carries the same
    /// action it always did.
    private var warnings: [TacticalWarning] {
        var items: [TacticalWarning] = []

        for peer in Array(Set(syncConflicts.map(\.peerID))).sorted() {
            let count = syncConflicts.filter { $0.peerID == peer }.count
            items.append(TacticalWarning(
                id: "sync-\(peer)",
                systemImage: "arrow.triangle.branch",
                text: poolCopy("同步中的仓位分账有冲突（\(count) 项）。冲突分账暂不参与池子统计和转移。",
                               "\(count) allocations conflict across devices. Conflicted allocations stay out of totals and moves."),
                actionTitle: poolCopy("查看设备 \(peer.prefix(8))", "Review \(peer.prefix(8))"),
                help: poolCopy("查看两端候选后整组选择", "Review both candidates, then choose a whole set"),
                action: { activeSheet = .syncConflict(peer) }
            ))
        }

        let staleItems = eligibleItems.filter { item in
            guard let allocation = item.positionAllocation else { return false }
            return item.positionQuantity > 0 && allocationNeedsReview(item, allocation)
        }
        for item in staleItems {
            items.append(TacticalWarning(
                id: "reconcile-\(item.symbol.description)",
                systemImage: "arrow.triangle.2.circlepath",
                text: poolCopy("\(item.symbol.displayCode) 的分账需要与账本核对。",
                               "\(item.symbol.displayCode)'s allocation needs review against the ledger."),
                actionTitle: poolCopy("核对", "Reconcile"),
                help: poolCopy("按当前账本数量重新确认各池份额", "Reconfirm each pool's shares against the ledger"),
                action: { activeSheet = .reconcile(item.symbol) }
            ))
        }
        let missing = eligibleItems.filter { $0.positionAllocation == nil && $0.positionQuantity > 0 }
        if !missing.isEmpty {
            items.append(TacticalWarning(
                id: "reconcile-missing",
                systemImage: "questionmark.circle",
                text: poolCopy("\(missing.count) 项持仓尚无分账记录；不会根据旧成交自行推断用途。",
                               "\(missing.count) positions have no allocation yet; their pool is not guessed from old trades."),
                actionTitle: nil, help: nil, action: nil
            ))
        }

        let result = PoolBudgetInput(appState: appState, currencyFilter: currencyFilter, accountFilter: accountFilter, allAccounts: true).calculate()
        for line in PoolBudgetNotice.messages(result) {
            items.append(TacticalWarning(id: "budget-\(line)", systemImage: "exclamationmark.triangle.fill",
                                         text: line, actionTitle: nil, help: nil, action: nil))
        }
        return items
    }

    private func allocationNeedsReview(_ item: WatchItem, _ allocation: PositionAllocation) -> Bool {
        let total = allocation.portions.reduce(0) { $0 + $1.quantity }
        return item.positionAllocationNeedsReconciliation
            || abs(total - item.positionQuantity) > PositionAllocation.quantityTolerance(total, item.positionQuantity)
            || !allocation.hasMatchingSources(for: item)
            || conflictedSymbols.contains(item.symbol)
    }

    struct TacticalWarning: Identifiable {
        let id: String
        let systemImage: String
        let text: String
        let actionTitle: String?
        let help: String?
        let action: (() -> Void)?
    }

    // MARK: Highlight

    private func isHighlighted(_ pool: PositionPool, symbol: SymbolID? = nil) -> Bool {
        guard let highlightFilter else { return true }
        switch highlightFilter {
        case .reached, .conditionsDue:
            guard let symbol else { return true }
            return boardEntries.contains { $0.symbol == symbol && isFilterMatched($0) }
        case .allocationReview:
            guard let symbol else { return true }
            return allocationReviewSymbols.contains(symbol)
        case .funding:
            guard let symbol else { return true }
            return fundingSymbols.contains(symbol)
        case .cashGap(let gap):
            if let symbol { return currencyCode(for: symbol) == gap.currency }
            return true
        }
    }

    private func isFilterMatched(_ entry: TradePlanEntry) -> Bool {
        // No highlight active means every plan qualifies, so nothing is dimmed.
        guard let highlightFilter else { return true }
        switch highlightFilter {
        case .reached:
            guard let quote = appState.market.quote(for: entry.symbol),
                  quote.price.isFinite, quote.price > 0,
                  TradingQuoteHealth.isCurrent(quote) else { return false }
            return entry.plan.isReached(at: quote.price)
        case .conditionsDue:
            return conditionsNeedReview(entry)
        case .allocationReview:
            return allocationReviewSymbols.contains(entry.symbol)
        case .funding:
            // A plan card never joins the funding highlight. "拟融资" is an
            // intention; highlighting it beside real margin portions would
            // read as borrowed money that does not exist yet.
            return false
        case .cashGap(let gap):
            return currencyCode(for: entry.symbol) == gap.currency
        }
    }

    /// Whether one portion card is the population the funding chip described.
    /// Only an explicit `.margin` qualifies — `nil` and `.unmarked` are exactly
    /// what the chip exists to separate out.
    private func isFundingMatched(_ card: PortionCard) -> Bool {
        card.portion.fundingSource == .margin
    }

    private var allocationReviewSymbols: Set<SymbolID> {
        Set(eligibleItems.filter { item in
            guard item.positionQuantity > 0 else { return false }
            guard let allocation = item.positionAllocation else { return true }
            return allocationNeedsReview(item, allocation)
        }.map(\.symbol))
    }

    /// Symbols with at least one real margin-annotated portion. Reads the live
    /// allocation, never a plan's intention and never a guess from a name.
    private var fundingSymbols: Set<SymbolID> {
        Set(cards.filter { isFundingMatched($0) }.map(\.symbol))
    }

    // MARK: - Funding summary

    /// One currency's real funding position, derived once per render.
    ///
    /// `marketValue` is the reference value of margin-annotated shares that
    /// have a verified, positive quote; `pricedDenominator` is the same
    /// currency total across *all* verified priced positions, so the ratio is
    /// "of what can actually be priced" rather than of an assumed whole.
    /// Shares with no quote, and positions still waiting for reconciliation,
    /// are counted separately and never folded into either figure as zero —
    /// the design forbids silently reading a missing price as full coverage.
    ///
    /// Nothing here is a broker balance. It is the market value of shares the
    /// user annotated as borrowed, which is not the same number as debt.
    struct FundingSummary: Equatable {
        var currency: String
        var marketValue: Double
        var pricedDenominator: Double
        var unpricedCount: Int
        var reviewCount: Int

        var share: Double? {
            guard pricedDenominator > 0, marketValue.isFinite, pricedDenominator.isFinite else { return nil }
            let value = marketValue / pricedDenominator
            guard value.isFinite else { return nil }
            return min(max(value, 0), 1)
        }
    }

    /// The board's funding figures, one row per currency that actually holds a
    /// margin portion.
    ///
    /// It is a plain computed property over the already-derived `cards` and the
    /// quote cache, called once from `body`. Drag handlers read only their own
    /// card; they never touch this, so a mouse move cannot trigger a currency
    /// walk.
    private var fundingSummaries: [FundingSummary] {
        Self.fundingSummaries(cards: cards) { symbol in
            guard let quote = appState.market.quote(for: symbol),
                  quote.timestamp.timeIntervalSince1970.isFinite else { return nil }
            return quote.price
        }
    }

    /// Reference quotes may value holdings even when the market is closed.
    /// Reconciliation and price coverage are reported beside the denominator.
    static func fundingSummaries(cards: [PortionCard], price: (SymbolID) -> Double?) -> [FundingSummary] {
        let marginCurrencies = Set(cards.filter { $0.portion.fundingSource == .margin }.map { $0.symbol.currencyCode })
        var totals: [String: FundingSummary] = [:]
        for card in cards where marginCurrencies.contains(card.symbol.currencyCode) {
            let code = card.symbol.currencyCode
            var total = totals[code] ?? .init(currency: code, marketValue: 0,
                pricedDenominator: 0, unpricedCount: 0, reviewCount: 0)
            if card.needsReview {
                total.reviewCount += 1
            } else if let quotePrice = price(card.symbol), quotePrice.isFinite, quotePrice > 0,
                      card.quantity.isFinite, card.quantity > 0, (quotePrice * card.quantity).isFinite {
                let value = quotePrice * card.quantity
                total.pricedDenominator += value
                if card.portion.fundingSource == .margin { total.marketValue += value }
            } else {
                total.unpricedCount += 1
            }
            totals[code] = total
        }
        return totals.values.sorted { $0.currency < $1.currency }
    }

    /// The margin portions on the board, for the one summary line's "n shares"
    /// context. Kept separate from the money so the count is exact even when no
    /// quote exists.
    private var marginHighlightCount: Int {
        cards.filter { isFundingMatched($0) }.count
    }

    private func toggleHighlight(_ filter: HighlightFilter) {
        highlightFilter = (highlightFilter == filter) ? nil : filter
    }

    /// The gap chip's whole job: enter preview with every active buy plan in
    /// that currency selected. It writes no money — only the rehearsal's
    /// selection.
    private func previewCashGap(_ gap: CashGap) {
        let buys = previewCandidates.filter {
            $0.plan.kind == .buy && currencyCode(for: $0.symbol) == gap.currency
        }
        previewPlanIDs = Set(buys.map(\.id))
        previewExplicitSelection = true
        stance = .preview
        highlightFilter = nil
        showsWarnings = false
    }

    private func applyScenarioSelection(_ ids: Set<UUID>) {
        previewPlanIDs = ids
        // A restored scenario is an explicit choice even when it matches no
        // current plan. Deriving this from `!ids.isEmpty` would silently widen
        // an empty scenario into "every plan" — the opposite of what was saved.
        previewExplicitSelection = true
    }

    // MARK: Lineage

    /// The fills a plan produced, paired with where their shares sit now.
    ///
    /// Either the plan's recorded execution id or the legacy
    /// `filledTransactionID` matches a transaction; a portion belongs to that
    /// fill only when its own `origin.transactionID` names it. A fill with no
    /// matching portion is reported as unattributed rather than assigned to the
    /// plan's intended pool.
    private func lineage(for entry: TradePlanEntry) -> (fills: [PlanFillLineage], unattributed: Double) {
        guard let item = storedItem(entry.symbol, in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID) else { return ([], 0) }
        let transactions = item.materializedTransactions()
        let matched = transactions.filter { transaction in
            transaction.planExecution?.planID == entry.plan.id
                || (entry.plan.filledTransactionID != nil && entry.plan.filledTransactionID == transaction.id)
        }.sorted { $0.date < $1.date }

        let allocation = item.positionAllocation
        let verified = allocation.map { !allocationNeedsReview(item, $0) } ?? false
        let portions = verified && !conflictedSymbols.contains(item.symbol)
            ? (allocation?.portions ?? []).filter { $0.quantity.isFinite && $0.quantity > 0 }
            : []
        // A portion whose source was edited or re-created no longer names a
        // live buy; it is still this instrument's share, and still unattributed
        // to any one fill.
        let liveTransactionIDs = Set(transactions.map(\.id))
        var usedPortionIDs = Set<UUID>()
        var fills: [PlanFillLineage] = []
        for transaction in matched {
            let owned = portions.filter { $0.origin.transactionID == transaction.id }
            usedPortionIDs.formUnion(owned.map(\.id))
            fills.append(PlanFillLineage(transaction: transaction, portions: owned))
        }
        let unattributed = portions
            .filter { portion in
                guard !usedPortionIDs.contains(portion.id) else { return false }
                guard let origin = portion.origin.transactionID else { return true }
                return !liveTransactionIDs.contains(origin)
            }
            .reduce(0) { $0 + $1.quantity }
        return (fills, unattributed.isFinite ? unattributed : 0)
    }

    /// A completed plan stays focusable even though it is no longer in
    /// `plannedEntries` (which only lists active plans). Focus reads the plan
    /// straight out of the item, so a done plan's lineage remains reachable.
    private var focusedEntry: TradePlanEntry? {
        guard let selectedPlanID else { return nil }
        return allPlanEntries.first { $0.id == selectedPlanID }
    }

    private let coordinateSpace = "position-pools-board"

    private var syncConflicts: [FolderSyncController.PositionAllocationConflictSummary] {
        appState.folderSync.positionAllocationConflicts
    }

    private var conflictedSymbols: Set<SymbolID> { Set(syncConflicts.map(\.symbol)) }

    private var eligibleItems: [WatchItem] {
        allBoardItems
            .filter { $0.supportsPosition && ($0.hasPositionHistory || $0.positionAllocation != nil) }
            .sorted {
                $0.resolvedDisplayName.localizedStandardCompare($1.resolvedDisplayName) == .orderedAscending
            }
    }

    private var currencyOptions: [String] {
        let planItems = allBoardItems.filter { $0.plans.contains { $0.status == .active } }
        return Array(Set((eligibleItems + planItems).map { currencyCode(for: $0.symbol) })).sorted()
    }

    private var filteredItems: [WatchItem] {
        guard currencyFilter != "*" else { return eligibleItems }
        return eligibleItems.filter { currencyCode(for: $0.symbol) == currencyFilter }
    }

    private var cards: [PortionCard] {
        boardRecords.flatMap { record -> [PortionCard] in
            let item = record.item
            guard currencyFilter == "*" || currencyCode(for: item.symbol) == currencyFilter,
                  item.positionQuantity > 0, let allocation = item.positionAllocation else { return [] }
            let needsReview = item.positionAllocationNeedsReconciliation || !allocation.isValid
                || !allocation.hasMatchingSources(for: item) || conflictedSymbols.contains(item.symbol)
            return allocation.portions.compactMap { portion in
                let card = PortionCard(item: item, portion: portion, needsReview: needsReview, ownerAccountID: record.accountID)
                return accountFilter == nil || card.accountID == accountFilter ? card : nil
            }
        }
    }

    private var plannedEntries: [TradePlanEntry] {
        allPlanEntries.filter {
            $0.plan.status == .active && $0.plan.price.isFinite && $0.plan.price > 0
                && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0 && $0.remainingEstimatedAmount.isFinite
                && (currencyFilter == "*" || currencyCode(for: $0.symbol) == currencyFilter)
        }
    }

    private var symbolItems: [WatchItem] {
        // `boardEntries`, not `plannedEntries`: in preview an unchecked plan is
        // still shown, just marked as not part of the rehearsal. Reading the
        // active-plan list here would drop exactly those cards, which is the
        // opposite of what the preview is meant to demonstrate.
        let symbols = Set((accountFilter == nil ? filteredItems.map(\.symbol) : cards.map(\.symbol)) + boardEntries.map(\.symbol))
        return Dictionary(grouping: allBoardItems.filter { symbols.contains($0.symbol) }, by: \.symbol).values.compactMap(\.first).sorted {
            $0.resolvedDisplayName.localizedStandardCompare($1.resolvedDisplayName) == .orderedAscending
        }
    }

    /// The plans a pool column owns: only plans whose `positionPool` names that
    /// pool explicitly.
    ///
    /// A plan with no pool is not filed here. It belongs to the unassigned
    /// library until the user assigns it, and showing it inside the 未分配
    /// column as well would duplicate the same complete card in two places —
    /// exactly the redundancy the plan shelf split removes. The `.unassigned`
    /// case is therefore reachable only through an explicit
    /// `positionPool == .unassigned`, which is a different statement from "the
    /// pool has not been chosen yet".
    static func plans(in pool: PositionPool, from entries: [TradePlanEntry]) -> [TradePlanEntry] {
        entries.filter { $0.plan.status == .active && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0
            && $0.plan.positionPool?.effectivePurpose == pool }
    }

    /// The plans that have no pool yet: the plan library's whole contents.
    ///
    /// Their complete cards live here and nowhere else. A nil-pool buy is
    /// pending classification; a nil-pool sell is a whole-instrument sale whose
    /// source pool the user has not named, and the projection deliberately
    /// leaves it out of every pool's distribution rather than pretending it
    /// draws on 未分配.
    static func unassignedPlans(from entries: [TradePlanEntry]) -> [TradePlanEntry] {
        entries.filter { $0.plan.status == .active && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0
            && $0.plan.positionPool == nil }
    }

    /// Which pool columns/headers to draw. The unassigned column is the only one
    /// that can disappear: it is hidden when nothing renders in it, so an
    /// untouched portfolio does not carry an always-empty "未分配" column. Every
    /// other pool is always shown, and a configured budget alone is not content.
    /// Read-only: it never filters the cards themselves.
    ///
    /// A nil-pool plan no longer keeps this column alive. Those plans are drawn
    /// by the plan library, not by a pool column, so counting them here resurected
    /// an otherwise empty 未分配 column — and, worse, implied a nil-pool sell
    /// would be deducted from 未分配 shares, which the projection never does.
    static func visiblePools(cards: [PortionCard],
                             entries: [TradePlanEntry],
                             dragSourcePool: PositionPool? = nil) -> [PositionPool] {
        let hasUnassignedContent = cards.contains { $0.pool == .unassigned }
            || entries.contains { $0.plan.status == .active && $0.plan.positionPool?.effectivePurpose == .unassigned }
            // A portion dragged out of the unassigned column must keep its source
            // visible until the drag settles, so the drag never appears to come
            // from a column that no longer exists.
            || dragSourcePool == .unassigned
        return PositionPool.activeCases.filter { $0 != .unassigned || hasUnassignedContent }
    }

    static func planTotals(_ plans: [TradePlanEntry], currency: (SymbolID) -> String) -> [(currency: String, buy: Double, sell: Double)] {
        let valid = plans.filter { $0.plan.status == .active && $0.plan.price.isFinite && $0.plan.price > 0
            && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0 && $0.remainingEstimatedAmount.isFinite }
        let grouped = Dictionary(grouping: valid, by: { currency($0.symbol) })
        return grouped.keys.sorted().compactMap { code in
            let entries = grouped[code] ?? []
            let buy = entries.filter { $0.plan.kind == .buy }.reduce(0) { $0 + $1.remainingEstimatedAmount }
            let sell = entries.filter { $0.plan.kind == .sell }.reduce(0) { $0 + $1.remainingEstimatedAmount }
            return buy.isFinite && sell.isFinite ? (code, buy, sell) : nil
        }
    }

    private func currencyCode(for symbol: SymbolID) -> String {
        // The instrument's own currency is authoritative: the calculator groups
        // by `symbol.currencyCode`, and a provider that reports a different
        // quote currency must not move a row into another currency's totals.
        symbol.currencyCode.uppercased()
    }

    private var allocationSignature: String {
        allBoardItems
            .map { "\($0.symbol.description):\($0.positionQuantity):\($0.positionAllocation?.revision.uuidString ?? "nil"):\($0.positionAllocationNeedsReconciliation)" }
            .sorted().joined(separator: "|")
    }

    /// The one definition of which pool columns/headers exist, shared by the
    /// by-pool grid, the by-symbol header row and the by-symbol row cells so they
    /// can never disagree. `boardEntries` (not `previewEntries`) is deliberate:
    /// an unchecked preview card must stay visible.
    private var visiblePools: [PositionPool] {
        Self.visiblePools(cards: cards, entries: boardEntries,
                          dragSourcePool: drag?.card.pool ?? planDrag.map { $0.entry.plan.positionPool ?? .unassigned })
    }

    /// Whether the unassigned column is currently hidden, which is what makes the
    /// fallback drop bar necessary.
    private var isUnassignedHidden: Bool {
        !visiblePools.contains(.unassigned)
    }

    private var activeTarget: PoolDropTarget? {
        guard drag != nil || planDrag != nil else { return nil }
        return motion.target
    }

    // The pre-measured unassigned destination wins when it overlaps a pool.
    private func target(at point: CGPoint, symbol: SymbolID, excluding pool: PositionPool? = nil) -> PoolDropTarget? {
        guard viewportFrame?.contains(point) == true else { return nil }
        let unassigned = PoolDropTarget(pool: .unassigned, symbol: nil)
        if pool != .unassigned, dropFrames[unassigned]?.contains(point) == true {
            return unassigned
        }
        return dropFrames.first { entry in
            entry.key.pool != pool && (entry.key.symbol == nil || entry.key.symbol == symbol) && entry.value.contains(point)
        }?.key
    }

    var body: some View {
        GeometryReader { geometry in
            let isNarrow = geometry.size.width < 1180
            let railWidth = min(250, max(200, geometry.size.width * 0.18))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    if isNarrow { narrowHeader } else { wideHeader }
                    BrokerageAccountFilterBar(selection: $accountFilter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.bottom, 6)
                    actionBar(isNarrow: isNarrow)
                    VStack(alignment: .leading, spacing: 6) {
                        CapitalPanel(
                            result: boardInput.calculate(),
                            referenceQuoteCount: boardInput.referenceQuoteCount,
                            isAssumed: isPreviewing,
                            editingAccountID: accountFilter,
                            onRequestGapPreview: { code in
                                // The capital panel only knows the currency;
                                // re-derive the gap kind so the highlight and
                                // the label stay in agreement.
                                if let gap = cashGaps.first(where: { $0.currency == code }) {
                                    previewCashGap(gap)
                                } else {
                                    previewCashGap(.unknownBalance(code))
                                }
                            },
                            unassignedSellCurrencies: Set(boardInput.entries.filter {
                                $0.plan.kind == .sell && $0.plan.positionPool == nil
                                    && $0.remainingQuantity.isFinite && $0.remainingQuantity > 0
                                    && $0.plan.price.isFinite && $0.plan.price > 0
                            }.map { $0.symbol.currencyCode })
                        )
                        .padding(.horizontal, 18).padding(.bottom, 6)
                        // Derived once here, at the root, and passed down. The
                        // drag handlers below never recompute it, so moving a
                        // card cannot walk every currency on every mouse event.
                        fundingSummaryBar(fundingSummaries)
                            .padding(.horizontal, 18).padding(.bottom, 6)
                    }
                    if allBoardItems.allSatisfy({ !$0.supportsPosition }) {
                        emptyState
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            GeometryReader { board in
                                Group {
                                    if mode == .board {
                                        // One board, one scroller. The reader lives
                                        // out here so a selected plan below a long
                                        // inventory is still reachable; the columns
                                        // themselves no longer scroll.
                                        ScrollViewReader { boardReader in
                                            ScrollView(.vertical) {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    poolBoard(availableWidth: board.size.width - 36,
                                                              isNarrow: isNarrow)
                                                    quoteProvenance
                                                }.padding(18)
                                            }
                                            // A drag owns the board's scroll position, and a
                                            // library-only plan has no pool card to land on, so
                                            // neither may pull the board. The predicate mirrors
                                            // `Self.plans(in:from:)`: only a plan a column
                                            // actually draws, in a column that is drawn, is
                                            // worth scrolling to.
                                            .onChange(of: selectedPlanID, initial: true) { _, id in
                                                guard planDrag == nil, let id,
                                                      let entry = boardEntries.first(where: { $0.id == id }),
                                                      entry.plan.status == .active,
                                                      entry.remainingQuantity.isFinite, entry.remainingQuantity > 0,
                                                      let pool = entry.plan.positionPool?.effectivePurpose,
                                                      visiblePools.contains(pool) else { return }
                                                boardReader.scrollTo(id, anchor: .center)
                                            }
                                            // A plan can change pool, so the board
                                            // is re-read whenever the entries it
                                            // draws change.
                                            .onChange(of: boardEntries, initial: true) { _, _ in
                                                guard planDrag == nil, let id = selectedPlanID,
                                                      let entry = boardEntries.first(where: { $0.id == id }),
                                                      entry.plan.status == .active,
                                                      entry.remainingQuantity.isFinite, entry.remainingQuantity > 0,
                                                      let pool = entry.plan.positionPool?.effectivePurpose,
                                                      visiblePools.contains(pool) else { return }
                                                boardReader.scrollTo(id, anchor: .center)
                                            }
                                        }
                                    } else { symbolBoard }
                                }
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: PoolDropFrameKey.self,
                                            value: DropFrames(viewport: proxy.frame(in: .named(coordinateSpace))))
                                    }
                                }
                                // Measure the hidden destination before pickup so a
                                // fast mouse-up can resolve it without a layout race.
                                .overlay(alignment: .bottom) {
                                    if isUnassignedHidden, !isPreviewing {
                                        unassignedDropBar
                                            .opacity(drag != nil || planDrag != nil ? 1 : 0)
                                            .accessibilityHidden(drag == nil && planDrag == nil)
                                    }
                                }
                            }
                            if showsPlanRail && !isNarrow {
                                planRail().frame(width: railWidth)
                            }
                        }
                        if isNarrow { planDrawer }
                    }
                }
                .poolAssumedBoardFrame(isPreviewing)
                portionDragProxy(in: geometry)
                planDragProxy(in: geometry)
            }
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(PoolDropFrameKey.self) {
                cardFrames = $0.cards
                dropFrames = $0.pools
                viewportFrame = $0.viewport
            }
            .onPreferenceChange(PoolPlanFrameKey.self) { planFrames = $0 }
            .onChange(of: plannedEntries) { _, entries in
                // A plan that leaves the active set must not silently drop the
                // focus: a completed plan stays inspectable, so only forget the
                // selection when the plan is gone from the watchlist entirely.
                if let selectedPlanID,
                   !entries.contains(where: { $0.id == selectedPlanID }),
                   !allPlanEntries.contains(where: { $0.id == selectedPlanID }) {
                    self.selectedPlanID = nil
                }
                planDrag = nil
            }
            .onChange(of: showsPlanRail) { _, _ in
                planDrag = nil
                if let drag { returnDragToSource(drag) }
            }
            .onChange(of: allocationSignature) { _, _ in
                if let drag { returnDragToSource(drag) }
                if let undo,
                   storedItem(undo.symbol, in: undo.accountID)?.positionAllocation?.revision != undo.expectedRevision {
                    self.undo = nil
                }
            }
            .onChange(of: conflictedSymbols) { _, symbols in
                if let drag, symbols.contains(drag.card.symbol) { returnDragToSource(drag) }
                if let undo, symbols.contains(undo.symbol) { self.undo = nil }
                if let activeSheet {
                    switch activeSheet {
                    case .transfer(let draft):
                        if symbols.contains(draft.symbol) { self.activeSheet = nil }
                    case .funding(let draft):
                        if symbols.contains(draft.symbol) { self.activeSheet = nil }
                    case .verification(let draft):
                        if symbols.contains(draft.symbol) { self.activeSheet = nil }
                    case .reconcile(let symbol):
                        if symbols.contains(symbol) { self.activeSheet = nil }
                    case .syncConflict, .plan, .workflow, .scenario:
                        break
                    case .execution(let symbol, _):
                        if symbols.contains(symbol) { self.activeSheet = nil }
                    }
                }
            }
            .onChange(of: mode) { _, _ in planDrag = nil; if let drag { returnDragToSource(drag) } }
            // The rail's lineage disclosure follows the *current* selection, so
            // it collapses the moment that selection changes. Otherwise a panel
            // opened for one plan would still be open under the next.
            .onChange(of: selectedPlanID) { _, _ in showsPlanLineage = false }
            .onChange(of: currencyFilter) { _, _ in planDrag = nil; if let drag { returnDragToSource(drag) } }
            .onChange(of: accountFilter) { _, _ in
                planDrag = nil; if let drag { returnDragToSource(drag) }
                selectedPlanID = nil; highlightFilter = nil
            }
            .onChange(of: appState.pendingPoolPlanID, initial: true) { _, id in
                guard let id, let entry = allPlanEntries.first(where: { $0.plan.id == id && $0.accountID == appState.watchlist.activeBrokerageAccountID }) else { return }
                currencyFilter = "*"
                selectedPlanID = entry.id
                showsPlanRail = true
                appState.pendingPoolPlanID = nil
            }
            .onExitCommand { planDrag = nil; if let drag { returnDragToSource(drag) } }
            .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
            .alert(copy("操作未完成", "Could not complete the action"), isPresented: $showingError) {
                Button(copy("好", "OK"), role: .cancel) { }
            } message: { Text(errorMessage ?? "") }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var wideHeader: some View {
        HStack(spacing: 12) {
            titleBlock
            Spacer(minLength: 12)
            stancePicker
            undoButton
            viewModePicker
            railToggle
            currencyPicker.frame(width: 118)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Narrow (≈1000px) header: two rows, never truncated. The view picker and
    /// undo fold into the overflow menu so the second row cannot run out of
    /// space.
    private var narrowHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                titleBlock
                Spacer(minLength: 8)
                stancePicker
                railToggle
                overflowMenu
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { chips() }
                }
                .scrollIndicators(.hidden)
                Spacer(minLength: 4)
                currencyPicker.frame(width: 110)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(copy("仓位池", "Position pools"))
                .font(PoolType.title)
                .lineLimit(1)
            Text(copy("资金去向 · 实仓分配 · 计划意向", "Capital · Position roles · Planned moves"))
                .font(PoolType.label).foregroundStyle(.secondary).lineLimit(1)
        }
        .layoutPriority(1)
    }

    private var stancePicker: some View {
        Picker(copy("模式", "Mode"), selection: stanceBinding) {
            Text(Stance.current.title).tag(Stance.current)
            Text(Stance.preview.title).tag(Stance.preview)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 140)
        .help(copy("预演只做估算，不改动真实持仓", "The rehearsal only estimates; it never changes real positions"))
    }

    /// Switching back to current always drops the payload the rehearsal
    /// carried, so a stale highlight or a half-open write sheet cannot leak a
    /// write into the real book.
    private var stanceBinding: Binding<Stance> {
        Binding(
            get: { stance },
            set: { next in
                guard next != stance else { return }
                stance = next
                planDrag = nil
                if let drag { returnDragToSource(drag) }
                if next == .preview {
                    // Entering the rehearsal never keeps a write sheet open.
                    switch activeSheet {
                    case .transfer, .funding, .execution, .workflow, .plan, .syncConflict:
                        activeSheet = nil
                    default: break
                    }
                } else {
                    previewPlanIDs.removeAll()
                    previewExplicitSelection = false
                    highlightFilter = nil
                    if case .scenario = activeSheet { activeSheet = nil }
                }
            }
        )
    }

    @ViewBuilder
    private var undoButton: some View {
        if let undo {
            Button {
                restore(undo)
            } label: {
                Label(copy("撤销上次操作", "Undo last change"), systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
                    .frame(width: PoolMetric.minimumTarget, height: PoolMetric.minimumTarget)
                    .contentShape(Rectangle())
            }
            .disabled(isWriteBlocked
                      || storedItem(undo.symbol, in: undo.accountID)?.positionAllocation?.revision != undo.expectedRevision)
            .help(isWriteBlocked
                  ? copy("切回当前后可操作", "Switch back to Current to act")
                  : copy("仅撤销最近一次且未被后续更改的分账操作",
                         "Available until this allocation changes again"))
        }
    }

    private var viewModePicker: some View {
        Picker(copy("查看方式", "View"), selection: $mode) {
            Text(copy("按用途", "By pool")).tag(Mode.board)
            Text(copy("按标的", "By symbol")).tag(Mode.symbol)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
    }

    private var railToggle: some View {
        Button {
            showsPlanRail.toggle()
        } label: {
            Label(planRailTitle, systemImage: "sidebar.right")
                .font(PoolType.chip)
                .lineLimit(1)
                .frame(height: PoolMetric.minimumTarget)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.primary.opacity(showsPlanRail ? 0.1 : 0.05), in: Capsule())
        .help(copy("展开或收起待归池计划库与选中详情；池内计划卡始终保留",
                   "Toggle the unassigned plan library and the selected detail; planned cards remain in the pools"))
    }

    /// The library: plans that have not been filed into a pool yet. These are
    /// the only plans whose complete card lives in the rail — an assigned plan's
    /// card belongs to its pool column, and drawing it here too is the duplicate
    /// the split removes.
    private var libraryEntries: [TradePlanEntry] {
        Self.unassignedPlans(from: boardEntries)
    }

    /// Whether the rail shows the library or one plan's compact detail.
    ///
    /// A selection is enough — the plan may have been assigned while its card is
    /// still the one the user is looking at. The one exception is a drag that
    /// started in the library: the card being dragged is the drag's own visual
    /// anchor, so the library must stay put until the gesture ends rather than
    /// swapping to a detail pane mid-flight.
    private var railShowsDetail: Bool {
        guard selectedPlanID != nil else { return false }
        if let planDrag, !planDrag.inPool { return false }
        return true
    }

    /// The plan whose detail the rail describes, whether it is in the library or
    /// in a pool.
    private var railDetailEntry: TradePlanEntry? {
        guard selectedPlanID != nil else { return nil }
        return focusedEntry
    }

    private var planRailTitle: String {
        if railShowsDetail {
            return copy("计划详情", "Plan detail")
        }
        let count = libraryEntries.count
        if isPreviewing {
            return copy("待归池 \(count) · 已选 \(previewEntries.count)",
                        "Library \(count) · \(previewEntries.count) picked")
        }
        return copy("待归池库 \(count)", "Plan library \(count)")
    }

    private var currencyPicker: some View {
        Picker(copy("币种", "Currency"), selection: $currencyFilter) {
            Text(copy("全部", "All")).tag("*")
            ForEach(currencyOptions, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
    }

    private var overflowMenu: some View {
        Menu {
            Picker(copy("查看方式", "View"), selection: $mode) {
                Text(copy("按用途", "By pool")).tag(Mode.board)
                Text(copy("按标的", "By symbol")).tag(Mode.symbol)
            }
            if let undo {
                Button(copy("撤销上次操作", "Undo last change")) { restore(undo) }
                    .disabled(isWriteBlocked)
            }
            Divider()
            Button(copy("管理全部计划…", "Manage all plans…"), action: onShowPlans)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .frame(width: PoolMetric.minimumTarget, height: PoolMetric.minimumTarget)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(copy("更多操作", "More actions"))
    }

    // MARK: - Action bar

    /// One 32pt row holding the compressed warnings, the action chips, and the
    /// preview label. The three banners this replaces each had their own row.
    /// The rehearsal banner is a full-width strip above the action row, not a
    /// leading pill. At the left of the chip row it read as simply the first
    /// chip in the list; spanning the width makes it read as the board's mode,
    /// which is what it is. Its tint is the only accent wash in the header, so
    /// current vs. preview is unmistakable, and the dashed board frame repeats
    /// the same signal.
    @ViewBuilder
    private var previewBanner: some View {
        if isPreviewing {
            // A rehearsal containing a sell the position cannot deliver is not
            // "every fill assumed" — its result is bounded by what is available,
            // so the banner must say so rather than overstate the scenario.
            let result = boardInput.calculate()
            let limited = !result.overSellWarnings.isEmpty
            HStack(spacing: 6) {
                Image(systemName: limited ? "exclamationmark.triangle" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                Text(limited
                     ? copy("预演 · 含超额卖出，结果受限，不改动真实持仓",
                            "What if · contains over-committed sells; result is limited, changes nothing real")
                     : copy("预演 · 假设所选计划成交，不改动真实持仓",
                            "What if · assumes the selected plans fill, changes nothing real"))
                    .font(PoolType.chip)
                    .lineLimit(1)
                Text(copy("已选 \(previewEntries.count) 项", "\(previewEntries.count) selected"))
                    .font(PoolType.labelMedium.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(limited ? Color.orange : Color.accentColor)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 24)
            .background((limited ? Color.orange : Color.accentColor).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke((limited ? Color.orange : Color.accentColor).opacity(0.35), lineWidth: 1)
            }
            // The banner is one fixed 24pt strip: at narrow widths the tail
            // figures truncate rather than wrapping the strip to two lines.
            .lineLimit(1)
            .help(copy("预演只读取当前计划与行情，不改动持仓、成交或预算记录。",
                       "The preview only reads current plans and quotes; it changes no position, fill, or budget record."))
            .accessibilityLabel(limited
                                ? copy("预演模式，含超额卖出", "Preview mode, with over-committed sells")
                                : copy("预演模式", "Preview mode"))
        }
    }

    private func actionBar(isNarrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            previewBanner
            HStack(spacing: 8) {
                // On narrow layouts the header's second row already carries the
                // action chips, so the bar must not render them a second time —
                // the duplicate row was visible at 1000pt. Only the rehearsal
                // banner and the warning affordance belong here in that case;
                // both stay exactly as they are.
                if !isNarrow { chips() }
                Spacer(minLength: 4)
                if !warnings.isEmpty {
                    PoolWarningChip(count: warnings.count, isOpen: showsWarnings) {
                        showsWarnings.toggle()
                    }
                    .popover(isPresented: $showsWarnings, arrowEdge: .bottom) { warningList }
                }
            }
            .frame(minHeight: 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func chips() -> some View {
        if hasAnyAction {
            if reachedPlanCount > 0 {
                PoolActionChip(systemImage: "target", title: copy("到价", "At price"),
                               count: reachedPlanCount,
                               // A reached plan is good news, not a warning, so
                               // it takes the positive tint instead of orange.
                               tint: .green,
                               isSelected: highlightFilter == .reached,
                               help: copy("高亮已到价的计划；不改动任何金额", "Highlight reached plans; changes no totals")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { toggleHighlight(.reached) }
                }
            }
            if conditionsDueCount > 0 {
                PoolActionChip(systemImage: "checklist", title: copy("条件待核对", "Conditions due"),
                               count: conditionsDueCount,
                               // Neutral review prompt: it is a to-do, not an alert.
                               tint: .secondary,
                               isSelected: highlightFilter == .conditionsDue,
                               help: copy("高亮条件到期或待核对的计划；不改动任何金额",
                                          "Highlight plans whose conditions are due; changes no totals")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { toggleHighlight(.conditionsDue) }
                }
            }
            if allocationReviewCount > 0 {
                PoolActionChip(systemImage: "arrow.triangle.2.circlepath", title: copy("分账待核对", "Review allocation"),
                               count: allocationReviewCount,
                               // Same neutral tier: housekeeping, not a warning.
                               tint: .secondary,
                               isSelected: highlightFilter == .allocationReview,
                               help: copy("高亮需要核对的持仓；不改动任何金额",
                                          "Highlight positions needing review; changes no totals")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { toggleHighlight(.allocationReview) }
                }
            }
            // Real margin portions only. A plan's intended margin is excluded,
            // so the chip's count is money that was actually borrowed rather
            // than money the user is considering borrowing.
            if marginHighlightCount > 0 {
                PoolActionChip(systemImage: "creditcard", title: copy("融资标记", "Margin marked"),
                               count: marginHighlightCount,
                               tint: PoolFundingStyle.marginTint,
                               isSelected: highlightFilter == .funding,
                               help: copy("高亮融资标注的份额；不改动任何金额，也不代表实际融资余额",
                                          "Highlight margin-annotated shares; changes no totals and is not a broker balance")) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { toggleHighlight(.funding) }
                }
            }
            ForEach(cashGaps, id: \.currency) { gap in
                if highlightFilter == .cashGap(gap) {
                    PoolActionChip(systemImage: "banknote", title: gap.chipText,
                                   count: 1,
                                   isSelected: true,
                                   help: copy("取消高亮；不改动现金记录",
                                              "Clears the highlight; changes no cash")) {
                        toggleHighlight(.cashGap(gap))
                    }
                } else {
                    Button {
                        previewCashGap(gap)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "banknote").font(.system(size: 11, weight: .semibold))
                            Text(gap.chipText).font(PoolType.chip)
                        }
                        // Cash is the one actionable money gap, so it keeps the
                        // warning tint; the quantifiable state is stated in the
                        // label rather than implied by colour alone.
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .frame(height: PoolMetric.chipHeight)
                        .background(.primary.opacity(0.05), in: Capsule())
                        .overlay { Capsule().stroke(Color.orange.opacity(0.28), lineWidth: 1) }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(gap.help)
                }
            }
        } else {
            Text(copy("暂无待办", "Nothing to do"))
                .font(PoolType.label).foregroundStyle(.secondary)
        }
    }

    private var warningList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy("警示与待办", "Warnings and to-dos"))
                    .font(PoolType.chip).padding(.bottom, 4)
                ForEach(warnings) { warning in
                    PoolWarningRow(systemImage: warning.systemImage, text: warning.text,
                                   actionTitle: warning.actionTitle, help: warning.help) {
                        warning.action?()
                        showsWarnings = false
                    }
                }
            }
            .padding(12)
            .frame(width: 380, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    // MARK: - Plan drawer (narrow)

    private var planDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { showsPlanDrawer.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showsPlanDrawer ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .semibold))
                        // The narrow title names both stances: the library count
                        // while it is the library, and "详情" once one plan is
                        // selected. Either way the entry never disappears.
                        Text(planDrawerTitle).font(PoolType.chip).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .frame(minHeight: PoolMetric.minimumTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if railShowsDetail {
                    Button(copy("返回计划库", "Back to library")) { selectedPlanID = nil }
                        .buttonStyle(.link).font(PoolType.label)
                        .frame(minHeight: PoolMetric.minimumTarget)
                }
                if isPreviewing {
                    Button(copy("管理预演…", "Manage picks…")) { openScenario() }
                        .buttonStyle(.link).font(PoolType.label)
                        .frame(minHeight: PoolMetric.minimumTarget)
                }
            }
            .padding(.horizontal, 18)
            if showsPlanDrawer {
                planRail(isDrawer: true).frame(height: 240)
            }
        }
        .background(.primary.opacity(0.025))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    /// "待归池 N / 详情" once a plan is selected, "待归池 N" otherwise, so the
    /// drawer header states which stance it will open into.
    private var planDrawerTitle: String {
        let library = copy("待归池 \(libraryEntries.count)", "Library \(libraryEntries.count)")
        guard railShowsDetail else { return library }
        return library + " / " + copy("详情", "Detail")
    }

    // MARK: - Drag proxies

    private func planDragProxy(in geometry: GeometryProxy) -> some View {
        DragBadgeProxy(motion: motion, content: planDrag.map(badge(for:)), viewport: geometry.size)
    }

    /// The proxy is a separate view so the pointer read happens in its body, not
    /// in the board's: a move re-renders two text runs and nothing else.
    private struct DragBadgeProxy: View {
        let motion: PositionPoolDragMotion
        let content: Badge?
        let viewport: CGSize

        struct Badge {
            var pool: PositionPool
            var title: String
            var code: String
            var detail: String
            var isSplit: Bool
            /// Real card only: the funding annotation's short word, if any.
            var fundingTag: String?
            /// Plan drags only: which side the detail line's 买入/卖出 word names.
            var side: TradePlan.Kind?
            var source: CGRect
            /// Grip normalised against the source card, so shrinking to the
            /// badge keeps the hold.
            var grip: CGPoint
        }

        var body: some View {
            if let content {
                let size = PositionPoolsView.DragBadge.size(forSourceWidth: content.source.width)
                PositionPoolsView.DragBadge(
                    pool: content.pool, title: content.title, code: content.code,
                    detail: content.detail, isSplit: content.isSplit,
                    fundingTag: content.fundingTag, side: content.side,
                    sourceWidth: content.source.width)
                    .position(PositionPoolDragGeometry.proxyPosition(
                        pointer: motion.location,
                        grabOffset: PositionPoolDragGeometry.badgeGrip(content.grip, badgeSize: size),
                        badgeSize: size,
                        viewport: CGRect(origin: .zero, size: viewport)))
                    .allowsHitTesting(false)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    .zIndex(10)
            }
        }
    }

    private func portionDragProxy(in geometry: GeometryProxy) -> some View {
        DragBadgeProxy(motion: motion, content: drag.map(badge(for:)), viewport: geometry.size)
    }

    /// Badge content is derived once per pickup, shift change, or target change —
    /// never from the pointer.
    private func badge(for state: DragState) -> DragBadgeProxy.Badge {
        let card = state.card
        return DragBadgeProxy.Badge(
            pool: card.pool,
            title: card.item.resolvedDisplayName,
            code: card.symbol.displayCode,
            detail: "\(poolQuantity(card.quantity)) \(copy("份额", "shares"))",
            isSplit: state.shift,
            fundingTag: fundingSourceTagTitle(card.portion.fundingSource),
            source: state.sourceFrame,
            grip: PositionPoolDragGeometry.normalizedGrip(state.grabOffset, sourceSize: state.sourceFrame.size))
    }

    private func badge(for moving: PlanDrag) -> DragBadgeProxy.Badge {
        let entry = moving.entry
        return DragBadgeProxy.Badge(
            pool: entry.plan.positionPool ?? .unassigned,
            title: appState.displayName(for: entry.symbol),
            code: entry.symbol.displayCode,
            detail: "\(entry.plan.kind == .buy ? copy("买入", "Buy") : copy("卖出", "Sell")) \(PriceFormatter.price(entry.plan.price, market: entry.symbol.market)) × \(poolQuantity(entry.remainingQuantity))",
            isSplit: false,
            fundingTag: entry.plan.fundingSource == .margin ? poolCopy("拟融资", "Planned margin") : nil,
            side: entry.plan.kind,
            source: moving.source,
            grip: PositionPoolDragGeometry.normalizedGrip(moving.grip, sourceSize: moving.source.size))
    }
    /// One currency's projection for one pool.
    private struct PoolValueLine: Identifiable {
        let currency: String
        let held: Double
        let projected: Double
        let needsReconciliation: Bool
        let currentIsPartial: Bool
        let missingPriceCount: Int
        let hasOverflow: Bool
        var id: String { currency }
    }

    /// The projection lines for one pool, one per currency, or empty when
    /// nothing can be said about it.
    ///
    /// A pool can hold instruments in more than one currency, and those figures
    /// can never be added together — "¥" and "$" do not sum. Each currency is
    /// therefore returned as its own line; a mixed pool shows several rows
    /// instead of silently collapsing to a single meaningless number, and
    /// instead of the old "—" that hid real holdings.
    private func poolProjection(_ pool: PositionPool,
                                in result: PoolBudgetProjection.Result) -> [PoolValueLine] {
        // Currencies present in this pool: from the held portions, plus any plan
        // assigned here (a plan can exist before its first fill). Board cards are
        // used, not the budget subset, so a pool never loses a currency row just
        // because its plan is excluded from the rehearsal.
        var codes = Set(cards.filter { $0.pool == pool }.map { currencyCode(for: $0.symbol) })
        for entry in Self.plans(in: pool, from: boardEntries) {
            codes.insert(currencyCode(for: entry.symbol))
        }
        guard !codes.isEmpty else { return [] }

        return codes.sorted().compactMap { code in
            guard let currency = result.currency(code),
                  let projection = currency.pools.first(where: { $0.pool == pool }) else { return nil }
            // A currency carries information for this pool when it holds
            // something, intends something (a planned buy or sell, even one
            // whose amount is zero because its instrument has no quote), has
            // unpriced units here, or still needs its allocation reconciled.
            // Anything else is a row with no content: "reference value —,
            // no limit, no priceable share" repeated for a currency that has
            // nothing to do with this pool.
            let hasIntent = projection.plannedBuyAmount != 0 || projection.plannedSellAmount != 0
            guard projection.heldAmount != 0
                    || projection.projectedAmount != 0
                    || projection.unvaluableQuantity > 0
                    || projection.needsReconciliation
                    || hasIntent else { return nil }
            return PoolValueLine(currency: code,
                                 held: projection.heldAmount,
                                 projected: projection.projectedAmount,
                                 needsReconciliation: projection.needsReconciliation,
                                 currentIsPartial: currency.pools.reduce(0) { $0 + $1.heldAmount }
                                    < currency.holdingsBefore - max(1e-6, currency.holdingsBefore * 1e-9)
                                    || currency.holdings.contains { $0.beforeQuantity != 0 && $0.beforePercent == nil },
                                 missingPriceCount: projection.unvaluableQuantity,
                                 hasOverflow: currency.hasOverflow)
        }
    }

    /// Held value today, and — in preview only — what it would become. The two
    /// are on one line so the comparison is a glance, not a scroll. One line per
    /// currency; never a sum across currencies.
    @ViewBuilder
    private func poolValueRow(pool: PositionPool, poolCards: [PortionCard],
                              projection: [PoolValueLine]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if !projection.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(projection) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                if projection.count > 1 {
                                    // With several currencies the code is
                                    // required reading, not decoration.
                                    Text(line.currency)
                                        .font(PoolType.labelMedium)
                                        .foregroundStyle(.secondary)
                                }
                                if line.hasOverflow {
                                    Text(copy("金额异常，请核对", "Invalid amount; review needed"))
                                        .font(PoolType.label).foregroundStyle(.orange)
                                } else {
                                    Text(PriceFormatter.money(line.held, currencyCode: line.currency))
                                        .font(PoolType.number)
                                }
                                if isPreviewing, !line.needsReconciliation,
                                   line.missingPriceCount == 0, !line.hasOverflow {
                                    Text("→").font(PoolType.label).foregroundStyle(.secondary)
                                    Text(PoolAmountText.assumed(
                                        PriceFormatter.money(line.projected, currencyCode: line.currency)))
                                        .font(PoolType.assumedNumber)
                                        .foregroundStyle(.primary)
                                } else if isPreviewing {
                                    // The verified figure is incomplete, so a
                                    // projected total would look exact when it
                                    // is not. Say what is still outstanding.
                                    Text(line.missingPriceCount > 0
                                         ? copy("· 缺价，预演市值待定", "· missing quote; projected value unknown")
                                         : copy("· 预演待核对", "· rehearsal pending review"))
                                        .font(PoolType.label).foregroundStyle(.orange)
                                }
                            }
                            // The before→after movement, stated in words. Blue,
                            // never a profit/loss colour: this is a hypothetical
                            // reallocation, not a gain or a loss.
                            if isPreviewing, !line.needsReconciliation,
                               line.missingPriceCount == 0, !line.hasOverflow {
                                let delta = line.projected - line.held
                                if delta.isFinite, delta != 0 {
                                    Text(copy("市值变化 ", "Value change ")
                                         + PriceFormatter.signedMoney(delta, currencyCode: line.currency))
                                        .font(PoolType.label.monospacedDigit())
                                        .foregroundStyle(.blue)
                                }
                            }
                            if line.currentIsPartial {
                                // The verified shares fall short of the position,
                                // so this figure covers only the reconciled part
                                // and must not read as the whole pool's value.
                                Text(copy("已核对部分（未含待核对份额）",
                                          "Verified part only (excludes pending shares)"))
                                    .font(PoolType.label).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .help(copy("实仓为已核对份额；预演为假设全部成交。不同币种不合并计算。",
                           "Held covers verified shares; the projection assumes every fill. Currencies are never summed."))
            } else {
                Text(copy("参考市值 —", "Reference value —"))
                    .font(PoolType.label).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            let staleCount = poolCards.filter { quoteState(for: $0.item.symbol) == .stale }.count
            let missingCount = poolCards.filter { quoteState(for: $0.item.symbol) == .missing }.count
            if staleCount + missingCount > 0 {
                Text([staleCount > 0 ? copy("旧价 \(staleCount)", "Stale \(staleCount)") : nil,
                      missingCount > 0 ? copy("缺价 \(missingCount)", "Missing \(missingCount)") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(PoolType.label).foregroundStyle(.orange)
            }
        }
    }

    /// The oversell warning for this plan, if the selected budget produced one.
    /// Matching on `planID` keeps the card's claim tied to the same calculation
    /// the totals came from, rather than to a separate guess.
    private func overSellWarning(for entry: TradePlanEntry,
                                 in result: PoolBudgetProjection.Result? = nil) -> PoolBudgetProjection.OverSellWarning? {
        let warnings = result?.overSellWarnings ?? boardInput.calculate().overSellWarnings
        return warnings.first { $0.planID == entry.id }
    }

    private func poolBoard(availableWidth: CGFloat, isNarrow: Bool) -> some View {
        // One column per visible pool whenever there is room; two columns when
        // narrow. Two or three active purposes are visible at once, so a hidden
        // unassigned column simply widens the remaining ones. Columns are as
        // tall as their own contents: the board's single scroller, not a
        // per-column height, decides how far the page travels.
        //
        // Every row is built eagerly. A pool card is a scroll target, and a
        // deferred grid row would not exist yet when the board is first asked
        // to scroll to one of its plans, leaving the board on row one. With at
        // most three pools the board is at most two rows, so building them all
        // up front costs nothing and keeps each pool's id addressable from the
        // first appearance.
        let pools = visiblePools
        let count = (isNarrow || availableWidth < 860) ? min(2, pools.count) : pools.count
        let columnCount = max(count, 1)
        let rowCount = (pools.count + columnCount - 1) / columnCount
        return VStack(alignment: .leading, spacing: PoolMetric.columnSpacing) {
            ForEach(0..<rowCount, id: \.self) { rowIndex in
                // Native HStacks stretch their flexible children equally, which
                // is what the grid's flexible columns did.
                HStack(alignment: .top, spacing: PoolMetric.columnSpacing) {
                    ForEach(0..<columnCount, id: \.self) { columnIndex in
                        let poolIndex = rowIndex * columnCount + columnIndex
                        if pools.indices.contains(poolIndex) {
                            poolColumn(pools[poolIndex])
                        } else {
                            // An incomplete last row keeps the empty cell's width
                            // so the final pool stays at column width instead of
                            // stretching across the row.
                            Color.clear
                                .frame(height: 0)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// Separates actual holdings from pending plans inside each column.
    private func sectionHeader(icon: String, title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title).font(PoolType.labelMedium)
            Text("\(count)").font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func poolColumn(_ pool: PositionPool) -> some View {
        let poolCards = cards.filter { $0.pool == pool }
        let poolPlans = Self.plans(in: pool, from: boardEntries)
        let receiving = activeTarget?.pool == pool
        // One calculation for this column: the value row, the limit config, the
        // gauge and the sell warnings all read this same result, so the selected
        // preview subset reaches every money surface instead of only some.
        let poolInput = boardInput
        let poolResult = poolInput.calculate()
        let projection = poolProjection(pool, in: poolResult)
        // A pool with no verified card or plan has nothing
        // to summarise. Its per-currency "reference value —", "no limit" and
        // "no priceable share" lines would repeat the single 44pt placeholder
        // below, so the summary block is reduced to the header. Anything with
        // content — including every warning, stale/missing price, reconciliation
        // and configured-limit state — keeps the full summary: a pool that does
        // have a limit keeps showing its capacity.
        let hasConfiguredLimit = poolResult.currencies.contains {
            $0.pools.first { $0.pool == pool }?.hasLimit ?? false
        }
        let isTrulyEmpty = poolCards.isEmpty && poolPlans.isEmpty && !hasConfiguredLimit
        // A highlight is active but this pool holds nothing that matches, so the
        // column recedes instead of reading as an equally relevant result.
        let dimmed = highlightFilter != nil
            && poolCards.isEmpty
            && !poolPlans.contains { isFilterMatched($0) }
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: pool.symbolName)
                        .foregroundStyle(pool.tint)
                        .font(.system(size: 12, weight: .semibold))
                    Text(pool.title).font(PoolType.poolTitle).help(pool.subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(copy("实仓 \(poolCards.count) · 待执行 \(poolPlans.count)",
                              "Held \(poolCards.count) · Pending \(poolPlans.count)"))
                        .font(PoolType.labelMedium.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).frame(height: 20)
                        .background(.primary.opacity(0.06), in: Capsule())
                        .lineLimit(1)
                }
                if !isTrulyEmpty {
                    poolValueRow(pool: pool, poolCards: poolCards, projection: projection)
                    // The header summary must describe the same plan set the
                    // projection totals describe. `poolPlans` comes from
                    // `boardEntries`, which deliberately keeps every eligible
                    // card visible in preview so unchecking never removes it —
                    // so in preview the summary must read the budget-selected
                    // set instead, or a tactical-only rehearsal would still
                    // announce the unselected HKD/unquoted/sell plans. The cards
                    // below keep using `boardEntries`.
                    plannedMoney(isPreviewing
                                 ? Self.plans(in: pool, from: poolInput.entries)
                                 : poolPlans,
                                 in: poolResult)
                    PoolBudgetGauge(pool: pool, result: poolResult, isPreviewing: isPreviewing, editingAccountID: accountFilter)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pool.tint.opacity(receiving ? 0.16 : PoolMetric.poolWash(scheme)), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(pool.tint.opacity(receiving ? 0.75 : 0.19), lineWidth: receiving ? 2 : 1)
            }
            // Contents sit directly in the board's single scroller. The stack is
            // eager so every plan card's `.id` is a stable descendant of the
            // outer reader even below a long held inventory; headers are plain
            // section rows and scroll with their own column, which keeps two
            // side-by-side columns from fighting over one pinned header band.
            VStack(alignment: .leading, spacing: PoolMetric.cardSpacing) {
                if !poolCards.isEmpty {
                    sectionHeader(icon: "tray.full.fill",
                                  title: copy("实际持仓", "Held"),
                                  count: poolCards.count,
                                  tint: pool.tint)
                    ForEach(poolCards) { card in portionCard(card) }
                }
                if !poolPlans.isEmpty {
                    sectionHeader(icon: "circle.dashed",
                                  title: copy("待执行计划", "Pending plans"),
                                  count: poolPlans.count,
                                  tint: pool.tint)
                    ForEach(poolPlans) { entry in
                        planCard(entry, inPool: true).id(entry.id)
                    }
                }
                if poolCards.isEmpty && poolPlans.isEmpty {
                    // A configured limit alone is not scroll content.
                    Text(copy("拖入实仓或计划卡", "Drop a holding or a plan here"))
                        .font(PoolType.label).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: PoolMetric.emptyHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 15))
        .opacity(dimmed ? 0.55 : 1)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PoolDropFrameKey.self,
                    value: DropFrames(pools: [PoolDropTarget(pool: pool, symbol: nil): proxy.frame(in: .named(coordinateSpace))])
                )
            }
        }
    }

    private var symbolBoard: some View {
        // Header row and body rows read the same pool list, so they stay aligned
        // when the empty unassigned column is hidden. Cells keep their fixed
        // 220pt width and 8pt padding; only the scroll extent shrinks.
        let pools = visiblePools
        return ScrollViewReader { reader in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Text(copy("标的", "Symbol")).frame(width: 210, alignment: .leading)
                        ForEach(pools, id: \.self) { pool in
                            Text(pool.title).frame(width: 236, alignment: .leading)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    LazyVStack(spacing: 10) {
                        ForEach(symbolItems, id: \.symbol) { item in symbolRow(item).id(item.symbol) }
                    }
                    quoteProvenance
                }
                .padding(18)
            }
            .scrollIndicators(.visible)
            .onChange(of: selectedPlanID, initial: true) { _, id in
                if planDrag == nil, let entry = boardEntries.first(where: { $0.id == id }) {
                    reader.scrollTo(PoolDropTarget(pool: entry.plan.positionPool ?? .unassigned, symbol: entry.symbol), anchor: .center)
                }
            }
        }
    }

    private func symbolRow(_ item: WatchItem) -> some View {
        let rowCards = cards.filter { $0.symbol == item.symbol }
        let allocated = item.positionAllocation?.portions.reduce(0) { $0 + $1.quantity } ?? 0
        let consistent = item.positionAllocation != nil && item.positionQuantity > 0
            && abs(allocated - item.positionQuantity) <= PositionAllocation.quantityTolerance(allocated, item.positionQuantity)
        let needsReview = item.positionAllocationNeedsReconciliation || !consistent
            || item.positionAllocation.map { !$0.hasMatchingSources(for: item) } == true
            || conflictedSymbols.contains(item.symbol)
        return HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    if let owner = rowCards.first?.ownerAccountID { appState.selectBrokerageAccount(owner) }
                    onSelect(item.symbol)
                } label: {
                    Text(item.resolvedDisplayName).font(PoolType.cardTitle).lineLimit(1)
                }
                .buttonStyle(.plain)
                Text(item.symbol.displayCode).font(PoolType.label.monospaced()).foregroundStyle(.secondary)
                Text(copy("当前份额  \(poolQuantity(rowCards.reduce(0) { $0 + $1.quantity }))", "Shares  \(poolQuantity(rowCards.reduce(0) { $0 + $1.quantity }))"))
                    .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
                if !item.hasPositionHistory {
                    Text(copy("尚无实仓", "No holding yet")).font(PoolType.label).foregroundStyle(.secondary)
                } else if needsReview {
                    Text(item.positionQuantity <= 0
                         ? copy("空头或已平仓 · 暂不可转移", "Short or closed · moves unavailable")
                         : copy("需要核对 · 已分配 \(poolQuantity(allocated))", "Review · allocated \(poolQuantity(allocated))"))
                        .font(PoolType.labelMedium).foregroundStyle(.orange)
                    if item.positionQuantity > 0, item.positionAllocation != nil {
                        Button(copy("核对分配…", "Reconcile…")) { openSheet(.reconcile(item.symbol), in: rowCards.first?.ownerAccountID ?? appState.watchlist.activeBrokerageAccountID) }
                            .controlSize(.small)
                            .disabled(isWriteBlocked)
                            .help(isWriteBlocked ? copy("切回当前后可操作", "Switch back to Current to act") : "")
                    }
                }
            }
            .frame(width: 210, alignment: .leading)
            // Same visible pool list as the header row above, so the columns
            // stay aligned when unassigned is hidden.
            ForEach(visiblePools, id: \.self) { pool in
                let bucket = rowCards.filter { $0.pool == pool }
                let poolPlans = Self.plans(in: pool, from: boardEntries.filter { $0.symbol == item.symbol })
                let receiving = activeTarget == PoolDropTarget(pool: pool, symbol: item.symbol)
                VStack(alignment: .leading, spacing: 8) {
                    // An empty cell keeps its size while it is receiving, so the
                    // border and wash are the only thing that changes on hover.
                    if bucket.isEmpty && poolPlans.isEmpty {
                        Text("—").font(PoolType.label).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: PoolMetric.emptyHeight)
                    }
                    // Use the same grouping in the by-symbol cells.
                    if !bucket.isEmpty {
                        sectionHeader(icon: "tray.full.fill",
                                      title: copy("实际持仓", "Held"),
                                      count: bucket.count,
                                      tint: pool.tint)
                        ForEach(bucket) { card in portionCard(card, compact: true) }
                    }
                    if !poolPlans.isEmpty {
                        sectionHeader(icon: "circle.dashed",
                                      title: copy("待执行计划", "Pending plans"),
                                      count: poolPlans.count,
                                      tint: pool.tint)
                        ForEach(poolPlans) { entry in planCard(entry, inPool: true) }
                    }
                }
                .id(PoolDropTarget(pool: pool, symbol: item.symbol))
                .frame(width: 220, alignment: .topLeading)
                .padding(8)
                .background(pool.tint.opacity(receiving ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11).stroke(pool.tint.opacity(receiving ? 0.7 : 0.08), lineWidth: receiving ? 2 : 1)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PoolDropFrameKey.self,
                            value: DropFrames(pools: [PoolDropTarget(pool: pool, symbol: item.symbol): proxy.frame(in: .named(coordinateSpace))])
                        )
                    }
                }
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 13))
    }

    private func portionCard(_ card: PortionCard, compact: Bool = false) -> some View {
        PortionCardFace(
            card: card,
            compact: compact,
            onSelect: { appState.selectBrokerageAccount(card.ownerAccountID); onSelect(card.symbol) },
            onWholeTransfer: { target in requestWholeTransfer(card, to: target) },
            onPartialTransfer: { target in openSheet(.transfer(TransferDraft(symbol: card.symbol, portionID: card.portion.id, destination: target)), in: card.ownerAccountID) },
            onMarkFunding: { openSheet(.funding(FundingDraft(symbol: card.symbol, portionID: card.portion.id)), in: card.ownerAccountID) },
            onEditVerification: { openSheet(.verification(VerificationDraft(symbol: card.symbol, portionID: card.portion.id)), in: card.ownerAccountID) },
            onSetAccount: { setAccount($0, on: card) },
            onDragChanged: { value, shift in updateDrag(card, value: value, shift: shift) },
            onDragEnded: { value in endDrag(card, value: value) },
            isDraggable: !isWriteBlocked && !card.needsReview && card.item.positionQuantity > 0,
            isPlaceholder: drag?.card.id == card.id,
            isWriteBlocked: isWriteBlocked
        )
    }

    private func planCard(_ entry: TradePlanEntry, inPool: Bool) -> some View {
        PoolPlanCardFace(entry: entry, inPool: inPool, isSelected: selectedPlanID == entry.id,
            isPlaceholder: planDrag?.entry.id == entry.id && planDrag?.inPool == inPool,
            onSelect: { selectedPlanID = entry.id },
            onEdit: { selectedPlanID = entry.id; openSheet(.plan(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID) },
            onRecord: { selectedPlanID = entry.id; openSheet(.execution(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID) },
            onInspect: { selectedPlanID = entry.id; openSheet(.workflow(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID) },
            onAssign: { assignPlan(entry, to: $0) },
            onDragChanged: { updatePlanDrag(entry, inPool: inPool, value: $0) },
            onDragEnded: { endPlanDrag($0) },
            isDraggable: true,
            isAssumed: isPreviewing && isPlanInPreview(entry),
            isChecked: isPlanInPreview(entry),
            showsSelectionCircle: isPreviewing && entry.plan.status == .active && entry.remainingQuantity > 0,
            isPreviewExcluded: isPreviewing && !isPlanInPreview(entry),
            overSell: overSellWarning(for: entry),
            onToggleCheck: { togglePreviewPlan(entry) },
            isWriteBlocked: isWriteBlocked,
            isFilteredOut: highlightFilter != nil && !isFilterMatched(entry))
    }

    /// Preview only: include or exclude one plan from the rehearsal. It writes
    /// nothing but the rehearsal's own selection.
    private func togglePreviewPlan(_ entry: TradePlanEntry) {
        guard isPreviewing else { return }
        if !previewExplicitSelection {
            previewPlanIDs = Set(previewCandidates.map(\.id))
            previewExplicitSelection = true
        }
        if previewPlanIDs.contains(entry.id) {
            previewPlanIDs.remove(entry.id)
        } else {
            previewPlanIDs.insert(entry.id)
        }
    }

    /// The lineage panel for one plan: conditions → plan → matched fills →
    /// current distribution → remaining intention. It reads the ledger and the
    /// allocation; it never invents a sold-lot mapping.
    @ViewBuilder
    private func lineageBlock(for entry: TradePlanEntry) -> some View {
        let (fills, unattributed) = lineage(for: entry)
        PoolPlanLineageView(
            entry: entry,
            fills: fills,
            unattributedQuantity: unattributed,
            isAssumed: isPreviewing && isPlanInPreview(entry),
            reduceMotion: reduceMotion,
            onExpand: {}
        )
    }

    /// History is opt-in and stays outside the pool inventory.
    private func planLineageDisclosure(for entry: TradePlanEntry) -> some View {
        DisclosureGroup(isExpanded: $showsPlanLineage) {
            lineageBlock(for: entry)
        } label: {
            Text(copy("成交与去向", "Fills and allocation"))
                .font(PoolType.labelMedium)
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
        .padding(.horizontal, 2)
    }

    /// The rail's two stances. The default is the **plan library**: the plans
    /// that still have no pool, each with its complete card — the one place
    /// those cards appear. Selecting any plan (library or pool) swaps the rail
    /// for a compact **detail**, so the same full card is never rendered twice
    /// on screen at once, and a pool plan can be inspected from here without a
    /// second copy living in the rail.
    @ViewBuilder
    private func planRail(isDrawer: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            railHeader(isDrawer: isDrawer)
            // Both the pane and the header read the one `railShowsDetail`, so a
            // library drag cannot leave the header saying "library" while the
            // body renders a detail.
            if railShowsDetail, let entry = railDetailEntry {
                railPlanDetail(entry, isDrawer: isDrawer)
            } else {
                railLibrary(isDrawer: isDrawer)
            }
            railFooter(isDrawer: isDrawer)
        }
        .padding(12)
        .background(.primary.opacity(0.025))
        .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.06)).frame(width: 1) }
    }

    /// New plan stays reachable from either stance, and from the drawer, so the
    /// entry does not depend on the library having rows or on the unassigned
    /// column being visible.
    private func railHeader(isDrawer: Bool) -> some View {
        HStack(spacing: 6) {
            if isDrawer {
                planRailHint
            } else {
                Label(railShowsDetail
                      ? copy("计划详情", "Plan detail")
                      : copy("待归池库", "Plan library"),
                      systemImage: railShowsDetail
                      ? "doc.text.magnifyingglass"
                      : "tray.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(railShowsDetail ? 1 : libraryEntries.count)")
                    .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(Dictionary(grouping: allBoardItems.filter(\.supportsPosition), by: \.symbol).values.compactMap(\.first).sorted { $0.resolvedDisplayName < $1.resolvedDisplayName }, id: \.symbol) { item in
                    Button(item.resolvedDisplayName) { newPlan(for: item) }
                        .disabled(isWriteBlocked)
                }
            } label: { Image(systemName: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            .disabled(isWriteBlocked)
            .help(isWriteBlocked ? copy("切回当前后可操作", "Switch back to Current to act")
                                 : copy("新建计划", "New plan"))
            .accessibilityLabel(copy("新建计划", "New plan"))
        }
    }

    /// The library stance: only unassigned plans, and a compact empty state that
    /// keeps both actions — new plan, and manage all plans — on screen.
    @ViewBuilder
    private func railLibrary(isDrawer: Bool) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: PoolMetric.cardSpacing) {
                    ForEach(libraryEntries) { entry in
                        planCard(entry, inPool: false).id(entry.id)
                    }
                    if libraryEntries.isEmpty {
                        railEmptyLibrary(isDrawer: isDrawer)
                    }
                }.padding(2)
            }
            // `initial: true` makes a card that is already selected when the
            // board first appears — a deep link, or the DEBUG focus render —
            // reachable without the user scrolling to find it.
            .onChange(of: selectedPlanID, initial: true) { _, id in
                if planDrag == nil, let id, libraryEntries.contains(where: { $0.id == id }) {
                    reader.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// A one-line empty state rather than an empty frame. It stays actionable:
    /// the menu creates a plan, and the footer's "manage all plans" is still
    /// there when the user does not want to create one.
    private func railEmptyLibrary(isDrawer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy("无待归池计划", "No plans waiting for a pool"))
                .font(PoolType.labelMedium)
            Text(isDrawer
                 ? copy("计划都已归入用途池，可在池内查看，或新建计划。",
                        "Every plan has a pool. Open its column, or create a new one.")
                 : copy("计划都已归入用途池，可在左侧池内查看，或新建计划。",
                        "Every plan has a pool. Open its column on the left, or create a new one."))
                .font(PoolType.label).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(copy("新建计划…", "New plan…")) {
                if let first = allBoardItems.first(where: \.supportsPosition) {
                    newPlan(for: first)
                }
            }
            .buttonStyle(.link).font(PoolType.label)
            .disabled(isWriteBlocked)
            .frame(minHeight: PoolMetric.minimumTarget, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .help(isWriteBlocked ? copy("切回当前后可操作", "Switch back to Current to act") : "")
    }

    /// The detail stance: one plan's identity, progress, conditions, and the
    /// actions that already exist elsewhere. It is deliberately not the full
    /// card again — no duplicate price/amount block, no duplicate menu — so the
    /// rail never renders the same card twice.
    @ViewBuilder
    private func railPlanDetail(_ entry: TradePlanEntry, isDrawer: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(entry.plan.positionPool?.tint ?? PositionPool.unassigned.tint)
                        .frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(appState.displayName(for: entry.symbol))
                        .font(PoolType.cardTitle).lineLimit(1).layoutPriority(1)
                    Text(entry.symbol.displayCode)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).fixedSize()
                    Spacer(minLength: 0)
                    if isPreviewing, entry.plan.status == .active, entry.remainingQuantity > 0 {
                        selectionCircle(for: entry)
                    }
                }
                Text(entry.plan.kind == .buy
                     ? copy("计划买入", "Planned buy")
                     : copy("计划卖出", "Planned sell"))
                    .font(PoolType.labelMedium)
                    .foregroundStyle(PlanSideStyle.color(for: entry.plan.kind))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(PlanSideStyle.color(for: entry.plan.kind).opacity(0.1), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 5) {
                    Text(PriceFormatter.price(entry.plan.price, market: entry.symbol.market))
                        .font(PoolType.number)
                    Text("× \(PriceFormatter.quantity(entry.remainingQuantity))")
                        .font(PoolType.number).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if railDetailIsReached(entry) {
                        PoolStatusPill(systemImage: "target", text: copy("到价", "At price"), tint: .orange)
                    }
                }
                railDetailIntent(entry)
                railDetailProgress(entry)
                railDetailConditions(entry)
                if railDetailIsExcluded(entry) {
                    Text(copy("未参与预演", "Not in rehearsal"))
                        .font(PoolType.badge).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(.primary.opacity(0.08), in: Capsule())
                }
                if let note = entry.plan.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    Text(note).font(PoolType.label).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).help(note)
                }
                railDetailActions(entry)
                // The drawer is only 240pt tall; the lineage disclosure would
                // open into a pane too short to read. It stays available in the
                // wide rail, and the pool card's own disclosure is unchanged.
                if !isDrawer {
                    planLineageDisclosure(for: entry)
                }
            }
            .padding(2)
        }
        .id(entry.id)
    }

    /// The plan's own intent, worded by the shared helper so the board, the plan
    /// list and the workbench cannot drift apart. The destination column uses
    /// the same nil-pool wording as the card: a nil-pool buy is 待归池, and a
    /// nil-pool sell is a whole-instrument sale whose source pool is unset —
    /// never "未分配", which would imply a deduction the projection does not make.
    private func railDetailIntent(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 5) {
            Text(copy("计划意图", "Intent"))
                .font(PoolType.label).foregroundStyle(.secondary)
            Text(planIntentTitle(entry)).font(PoolType.labelMedium)
            PlannedFundingTag(source: entry.plan.fundingSource)
            Spacer(minLength: 0)
            Text(railDestinationLabel(entry))
                .font(PoolType.label)
                .foregroundStyle(entry.plan.positionPool?.tint
                                 ?? (entry.plan.kind == .sell ? .orange : .secondary))
                .lineLimit(1)
        }
    }

    private func railDestinationLabel(_ entry: TradePlanEntry) -> String {
        guard let pool = entry.plan.positionPool else {
            return entry.plan.kind == .buy
                ? copy("待归池", "No pool yet")
                : copy("整标的卖出 · 来源池未指定", "Whole-position sale · source pool unset")
        }
        return pool.title
    }

    @ViewBuilder
    private func railDetailProgress(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 5) {
            if entry.filledQuantity > 0 {
                Text(copy("已成交 ", "Filled ") + PriceFormatter.quantity(entry.filledQuantity))
                    .font(PoolType.label.monospacedDigit())
                Text("·").foregroundStyle(.secondary)
            }
            Text(copy("待执行 ", "Remaining ") + PriceFormatter.quantity(entry.remainingQuantity))
                .font(PoolType.label.monospacedDigit())
            Spacer(minLength: 0)
            Text(PoolAmountText.money(entry.remainingEstimatedAmount,
                                      currency: entry.symbol.currencyCode.uppercased(),
                                      assumed: isPreviewing && isPlanInPreview(entry)))
                .font(PoolType.label.monospacedDigit())
                .foregroundStyle(isPreviewing && isPlanInPreview(entry)
                                 ? PlanSideStyle.color(for: entry.plan.kind) : Color.secondary)
        }
        .help(copy("已成交为已记录事实；待执行为计划剩余数量。",
                   "Filled is a recorded fact; remaining is what the plan still intends."))
    }

    /// A condition summary, not a second editable surface: the count, the state
    /// dots, and the next review date. Confirming stays in the plan's own sheets.
    @ViewBuilder
    private func railDetailConditions(_ entry: TradePlanEntry) -> some View {
        let conditions = entry.plan.conditions ?? []
        HStack(spacing: 5) {
            Text(copy("条件", "Conditions")).font(PoolType.label).foregroundStyle(.secondary)
            if conditions.isEmpty {
                Text(copy("未设条件", "None")).font(PoolType.label).foregroundStyle(.secondary)
            } else {
                Text("\(conditions.filter { $0.state == .confirmed }.count)/\(conditions.count)")
                    .font(PoolType.label.monospacedDigit())
                Text(conditionsNeedReview(entry)
                     ? copy("待核对", "Review due")
                     : copy("已核对", "Checked"))
                    .font(PoolType.label)
                    .foregroundStyle(conditionsNeedReview(entry) ? .orange : .secondary)
                ForEach(Array(conditions.prefix(5))) { condition in
                    Circle().fill(railConditionColor(condition)).frame(width: 5, height: 5)
                        .help(condition.title)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func railConditionColor(_ condition: TradePlanCondition) -> Color {
        if let date = condition.reviewDate, date < Calendar.current.startOfDay(for: .now),
           condition.state != .invalidated {
            return .orange
        }
        switch condition.state {
        case .pending: return .secondary
        case .confirmed: return .green
        case .needsReview: return .orange
        case .invalidated: return .red
        }
    }

    /// The actions already defined for a plan: record a fill, edit, and open the
    /// workflow. They route through `activeSheet`, the same sheet the pool card
    /// and the plan list open — no second mode, and nothing writes in preview.
    private func railDetailActions(_ entry: TradePlanEntry) -> some View {
        HStack(spacing: 8) {
            Button(copy("记录成交", "Record fill")) {
                openSheet(.execution(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID)
            }
            .disabled(isWriteBlocked)
            Button(copy("编辑计划", "Edit")) {
                openSheet(.plan(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID)
            }
            .disabled(isWriteBlocked)
            Button(copy("逻辑 / 历史", "Thesis / history")) {
                openSheet(.workflow(entry.symbol, entry.plan.id), in: entry.accountID ?? appState.watchlist.activeBrokerageAccountID)
            }
            .disabled(isWriteBlocked)
            Spacer(minLength: 0)
        }
        .font(PoolType.label).controlSize(.mini)
        .help(isWriteBlocked ? copy("预演模式下不可操作", "Unavailable in preview") : "")
    }

    private func railDetailIsReached(_ entry: TradePlanEntry) -> Bool {
        guard let quote = appState.market.quote(for: entry.symbol),
              quote.price.isFinite, quote.price > 0,
              TradingQuoteHealth.isCurrent(quote) else { return false }
        return entry.plan.isReached(at: quote.price)
    }

    private func railDetailIsExcluded(_ entry: TradePlanEntry) -> Bool {
        isPreviewing && entry.plan.status == .active && entry.remainingQuantity > 0
            && !isPlanInPreview(entry)
    }

    /// The shared include/exclude circle, so the detail pane keeps the same
    /// preview control the card carries instead of inventing a second one.
    private func selectionCircle(for entry: TradePlanEntry) -> some View {
        Button {
            togglePreviewPlan(entry)
        } label: {
            Image(systemName: isPlanInPreview(entry) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isPlanInPreview(entry)
                                 ? PlanSideStyle.color(for: entry.plan.kind)
                                 : Color.secondary)
                .frame(width: PoolMetric.minimumTarget, height: PoolMetric.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy("纳入预演", "Include in preview"))
        .accessibilityAddTraits(isPlanInPreview(entry) ? [.isSelected] : [])
    }

    /// The footer keeps both actions in every stance: back to the library when a
    /// detail is open, and the permanent route to the full plan list.
    @ViewBuilder
    private func railFooter(isDrawer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if railShowsDetail {
                Button {
                    selectedPlanID = nil
                } label: {
                    Label(copy("返回计划库", "Back to library"), systemImage: "chevron.left")
                }
                .buttonStyle(.link).font(PoolType.label)
                .frame(minHeight: PoolMetric.minimumTarget, alignment: .leading)
                .help(copy("清除当前选择，回到待归池计划库", "Clear the selection and return to the plan library"))
            } else if !isDrawer {
                Text(copy("虚线卡代表意向，金额按计划价估算。", "Dashed cards show intentions, valued at planned prices."))
                    .font(PoolType.label).foregroundStyle(.secondary)
            }
            Button(copy("管理全部计划…", "Manage all plans…"), action: onShowPlans)
                .buttonStyle(.link).font(PoolType.label)
                .frame(minHeight: PoolMetric.minimumTarget, alignment: .leading)
        }
    }

    private var planRailHint: some View {
        Text(railShowsDetail
             ? copy("选中计划的简洁详情", "Compact detail for the selected plan")
             : (isPreviewing
                ? copy("待归池计划 · 勾选参与预演", "Unassigned plans · pick who rehearses")
                : copy("待归池计划 · 拖入用途池归池", "Unassigned plans · drop into a pool")))
            .font(PoolType.label).foregroundStyle(.secondary)
    }

    /// The pool header's pending-plan summary, built from the same plan set the
    /// column projected. Callers pass the budget-selected entries in preview and
    /// the pool's active plans in current mode, so this never re-derives a
    /// selection of its own. An explicit empty preview therefore draws no lines
    /// at all rather than falling back to the board.
    @ViewBuilder private func plannedMoney(_ entries: [TradePlanEntry], in result: PoolBudgetProjection.Result) -> some View {
        // A sell the position cannot deliver is not recoverable proceeds, so it
        // is kept out of the "拟回收" figure and reported by count instead. This
        // is a labelling rule about deliverability, not a second selection: the
        // entry set itself always comes from the caller.
        let overSellIDs = Set(result.overSellWarnings.map(\.planID))
        let deliverable = entries.filter { !overSellIDs.contains($0.id) }
        let blockedSellCount = entries.filter { overSellIDs.contains($0.id) && $0.plan.kind == .sell }.count
        let groups = Self.planTotals(deliverable, currency: { currencyCode(for: $0) })
        ForEach(groups, id: \.currency) { group in
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                if group.buy > 0 {
                    Text(copy("待投", "Buy"))
                    Text(PoolAmountText.money(group.buy, currency: group.currency, assumed: isPreviewing))
                        .foregroundStyle(PlanSideStyle.buy)
                }
                if group.sell > 0 {
                    Text(copy("拟回收", "Sell"))
                    Text(PoolAmountText.money(group.sell, currency: group.currency, assumed: isPreviewing))
                        .foregroundStyle(PlanSideStyle.sell)
                }
                Spacer(minLength: 0)
            }
            .font(PoolType.label.monospacedDigit()).foregroundStyle(.secondary)
            .help(copy("待执行计划金额，未计入已持仓市值；不含超出可卖数量的卖出计划。",
                       "Active plan amounts, excluded from held position value; excludes sells beyond the sellable quantity."))
        }
        if blockedSellCount > 0 {
            Text(copy("另有 \(blockedSellCount) 笔卖出计划超出可卖数量，未计入拟回收",
                      "\(blockedSellCount) sell plan(s) exceed the sellable quantity; not counted as proceeds"))
                .font(PoolType.label).foregroundStyle(.orange)
        }
        if groups.count < Set(deliverable.map { currencyCode(for: $0.symbol) }).count {
            Text(copy("部分计划金额超出可计算范围", "Some plan totals exceed the supported range"))
                .font(PoolType.label).foregroundStyle(.orange)
        }
    }

    /// Fallback destination for the unassigned column while it is hidden.
    ///
    /// It registers the same `PoolDropTarget(pool: .unassigned, symbol: nil)` key
    /// the real column would use, so `target(at:)` needs no special case. It is
    /// purely a destination and draws no receiver, so it never covers the drag's
    /// own source or its placeholder.
    private var unassignedDropBar: some View {
        let target = PoolDropTarget(pool: .unassigned, symbol: nil)
        let targetPool = PositionPool.unassigned
        let receiving = activeTarget == target
        return Label(copy("放入未分配", "Drop into Unassigned"), systemImage: targetPool.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(targetPool.tint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 36)
            .background(targetPool.tint.opacity(receiving ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(targetPool.tint.opacity(receiving ? 0.8 : 0.45),
                            style: StrokeStyle(lineWidth: receiving ? 2 : 1, dash: [5, 3]))
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: PoolDropFrameKey.self,
                        value: DropFrames(pools: [target: proxy.frame(in: .named(coordinateSpace))]))
                }
            }
            .accessibilityLabel(copy("放入未分配", "Drop into Unassigned"))
            .allowsHitTesting(false)
    }

    private func updatePlanDrag(_ entry: TradePlanEntry, inPool: Bool, value: DragGesture.Value) {
        // Belt and braces: the card's gesture is already disabled in preview,
        // but the drag state itself must refuse to start.
        guard !isWriteBlocked else { return }
        guard drag == nil else { return }
        if planDrag == nil {
            guard let source = planFrames[PoolPlanFrameKey.id(entry.id, inPool: inPool)],
                  !source.isEmpty, !source.isNull else { return }
            planDrag = PlanDrag(entry: entry, inPool: inPool, source: source,
                grip: PositionPoolDragGeometry.grabOffset(pointer: value.startLocation, sourceFrame: source))
        } else if planDrag?.entry.id != entry.id {
            return
        }
        motion.move(to: value.location, target: target(at: value.location, symbol: entry.symbol))
    }

    private func endPlanDrag(_ value: DragGesture.Value) {
        guard !isWriteBlocked, let moving = planDrag else { return }
        let destination = target(at: value.location, symbol: moving.entry.symbol)
        planDrag = nil
        motion.target = nil
        if let destination { assignPlan(moving.entry, to: destination.pool) }
    }

    private func assignPlan(_ entry: TradePlanEntry, to pool: PositionPool?) {
        // No plan edit reaches the store while the board is rehearsing.
        guard !isWriteBlocked else { return }
        let owner = entry.accountID ?? appState.watchlist.activeBrokerageAccountID
        guard var latest = storedItem(entry.symbol, in: owner)?.plans.first(where: { $0.id == entry.plan.id }),
              latest.status == .active else { return }
        guard latest.positionPool != pool else { return }
        latest.positionPool = pool
        if appState.watchlist.withBrokerageAccount(owner, { appState.watchlist.setTradePlan(latest, for: entry.symbol) }) {
            // Ownership changes do not open the inspector. Keep the library
            // ready for the next drag; explicit card selection opens details.
            if pool == nil && selectedPlanID == entry.id { selectedPlanID = nil }
        } else {
            showError(copy("计划已变化，请重新打开。", "The plan changed. Reopen it."))
        }
    }

    /// The one compact line per currency that describes the board's real
    /// funding composition. It is deliberately not a debt figure: it never
    /// says "融资余额" or "净资产", because the annotation it is derived from
    /// cannot produce either number. Shares that cannot be priced, and
    /// positions still waiting for reconciliation, are called out on their own
    /// line instead of being counted as zero.
    @ViewBuilder
    private func fundingSummaryBar(_ summaries: [FundingSummary]) -> some View {
        if !summaries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(summaries, id: \.currency) { summary in
                    HStack(spacing: 6) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(PoolFundingStyle.marginTint)
                        if let share = summary.share {
                            Text(copy(
                                "已计价融资标记市值 ≈\(PriceFormatter.money(summary.marketValue, currencyCode: summary.currency)) · 占已核对有报价持仓 \(share.formatted(.percent.precision(.fractionLength(1))))",
                                "Priced margin-marked value ≈\(PriceFormatter.money(summary.marketValue, currencyCode: summary.currency)) · \(share.formatted(.percent.precision(.fractionLength(1)))) of reconciled, priced holdings"
                            ))
                        } else {
                            // No verified price in this currency: the value is
                            // unknown, not zero, and the line says so rather
                            // than printing an exact-looking small number.
                            Text(copy(
                                "融资标记持仓市值待定 · 暂无已核对报价",
                                "Margin-marked value pending · no verified quote"
                            ))
                        }
                        Spacer(minLength: 0)
                        if summary.unpricedCount > 0 || summary.reviewCount > 0 {
                            Text([
                                summary.unpricedCount > 0
                                    ? copy("\(summary.unpricedCount) 张缺价未计入", "\(summary.unpricedCount) unpriced, excluded")
                                    : nil,
                                summary.reviewCount > 0
                                    ? copy("\(summary.reviewCount) 张待核对未计入", "\(summary.reviewCount) awaiting review, excluded")
                                    : nil
                            ].compactMap { $0 }.joined(separator: " · "))
                                .font(PoolType.label)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(PoolType.label)
                    // The whole line reads as annotation, not as a headline.
                    .foregroundStyle(.secondary)
                }
            }
            .help(copy(
                "描述持仓里已标注为融资买入的份额市值，不等于实际融资本金或融资余额；只计入已核对且有正报价的份额。",
                "Market value of shares annotated as margin-funded. Not borrowed principal or a broker balance; only reconciled shares with a positive quote are counted."
            ))
        }
    }

    private var quoteProvenance: some View {
        let quotes = eligibleItems.compactMap { appState.market.quote(for: $0.symbol) }
            .filter { $0.price.isFinite && $0.price > 0 && $0.timestamp.timeIntervalSince1970.isFinite }
        let newest = quotes.max { $0.timestamp < $1.timestamp }
        let sources = Array(Set(quotes.map { $0.sourceName ?? $0.sourceID ?? copy("来源未知", "Unknown source") })).sorted()
        return HStack(spacing: 7) {
            Image(systemName: "waveform.path")
            if quotes.isEmpty {
                Text(copy("行情来源与时刻：暂无可用报价", "Quote source and time: no available quotes"))
            } else {
                Text(copy("行情来源：\(sources.joined(separator: "、"))", "Quote sources: \(sources.joined(separator: ", "))"))
                if let newest {
                    Text("·")
                    Text(copy("最近时刻 \(appState.quoteMarketTimeText(for: newest))", "Latest \(appState.quoteMarketTimeText(for: newest))"))
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "square.grid.3x1.folder.badge.plus").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(copy("还没有可分配的持仓", "No positions to allocate yet")).font(.system(size: 14, weight: .semibold))
            Text(copy("记录持仓后，仓位份额会显示在对应用途池中。", "Once a position is recorded, its portions will appear in the pools."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func sheetContent(_ sheet: Sheet) -> some View {
        // A write sheet must never be reachable in preview, even if a stale
        // `activeSheet` survived a mode switch. Each branch refuses on its own
        // rather than relying on the caller having cleared it.
        if isWriteBlocked, sheet.blocksPreviewWrites {
            unavailableSheet(copy("预演模式下不能执行该操作。请先切回「当前」。",
                                  "This action is unavailable in preview. Switch back to Current first."))
        } else {
            switch sheet {
            case .transfer(let draft):
                if let item = appState.watchlist.item(for: draft.symbol),
                   let allocation = item.positionAllocation,
                   let portion = allocation.portions.first(where: { $0.id == draft.portionID }) {
                    PoolTransferSheet(
                        item: item,
                        portion: portion,
                        allocation: allocation,
                        initialDestination: draft.destination,
                        onCancel: { activeSheet = nil },
                        onSuccess: { previous, updated in
                            undo = UndoState(symbol: draft.symbol, previous: previous, expectedRevision: updated.revision, accountID: appState.watchlist.activeBrokerageAccountID)
                            activeSheet = nil
                        },
                        isWriteBlocked: isWriteBlocked
                    )
                } else {
                    unavailableSheet(copy("这份份额已变化，请重新打开操作。", "This portion changed. Reopen the action."))
                }
            case .funding(let draft):
                if let item = appState.watchlist.item(for: draft.symbol),
                   let allocation = item.positionAllocation,
                   !item.positionAllocationNeedsReconciliation,
                   let portion = allocation.portions.first(where: { $0.id == draft.portionID }) {
                    FundingSourceSheet(
                        item: item,
                        portion: portion,
                        allocation: allocation,
                        onCancel: { activeSheet = nil },
                        onSuccess: { previous, updated in
                            // Same undo shape a transfer uses: the funding
                            // change is a single allocation step, so "撤销上次
                            // 分配" can roll it back without special-casing.
                            undo = UndoState(symbol: draft.symbol, previous: previous, expectedRevision: updated.revision, accountID: appState.watchlist.activeBrokerageAccountID)
                            activeSheet = nil
                        },
                        isWriteBlocked: isWriteBlocked
                    )
                } else {
                    // A portion that still needs reconciliation, or has already
                    // disappeared, is not something this sheet may annotate.
                    unavailableSheet(copy("这份份额待核对或已变化，请先核对仓位分账。",
                                          "This portion needs reconciliation or has changed. Reconcile the allocation first."))
                }
            case .verification(let draft):
                // Same refusals the funding sheet makes, for the same reasons: a
                // portion that has disappeared, needs reconciliation, or sits
                // behind an unresolved sync conflict is not a target this sheet
                // may write conditions onto. The sheet itself refuses again on
                // submit, so a conflict landing while it is open is caught too.
                if let item = appState.watchlist.item(for: draft.symbol),
                   let allocation = item.positionAllocation,
                   !item.positionAllocationNeedsReconciliation,
                   !conflictedSymbols.contains(item.symbol),
                   let portion = allocation.portions.first(where: { $0.id == draft.portionID }) {
                    PositionVerificationSheet(
                        item: item,
                        portion: portion,
                        allocation: allocation,
                        account: appState.watchlist.activeBrokerageAccountID,
                        onCancel: { activeSheet = nil },
                        onSuccess: { previous, updated in
                            // The same undo shape funding uses: verification is
                            // one allocation step, so "撤销上次分配" rolls it
                            // back without a verification-specific path.
                            undo = UndoState(symbol: draft.symbol, previous: previous, expectedRevision: updated.revision, accountID: appState.watchlist.activeBrokerageAccountID)
                            activeSheet = nil
                        },
                        isWriteBlocked: isWriteBlocked
                    )
                } else {
                    unavailableSheet(copy("这份份额待核对、存在冲突或已变化，请先核对仓位分账。",
                                          "This portion needs reconciliation, has a conflict, or changed. Reconcile the allocation first."))
                }
            case .reconcile(let symbol):
                if let item = appState.watchlist.item(for: symbol),
                   let allocation = item.positionAllocation, item.positionQuantity > 0 {
                    PoolReconciliationSheet(
                        item: item,
                        allocation: allocation,
                        onCancel: { activeSheet = nil },
                        onSuccess: { activeSheet = nil; undo = nil },
                        isWriteBlocked: isWriteBlocked
                    )
                } else {
                    unavailableSheet(copy("当前状态不支持核对操作。", "This position cannot be reconciled in its current state."))
                }
            case .plan(let symbol, let planID):
                PoolPlanEditorSheet(symbol: symbol, planID: planID, onClose: { activeSheet = nil })
            case .execution(let symbol, let planID):
                if let entry = appState.watchlist.tradePlanEntries.first(where: { $0.symbol == symbol && $0.id == planID }) {
                    PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                                       onClose: { activeSheet = nil })
                } else { unavailableSheet(copy("这项计划已变化，请重新打开。", "This plan changed. Reopen it.")) }
            case .workflow(let symbol, let planID):
                PlanWorkflowDetailView(symbol: symbol, planID: planID,
                                       account: appState.watchlist.activeBrokerageAccountID)
                    .frame(width: 650, height: 600)
            case .scenario:
                PoolScenarioView(currencyFilter: currencyFilter,
                                 initialSelection: Set(previewCandidates.filter { !previewExplicitSelection || previewPlanIDs.contains($0.id) }.map(\.plan.id)),
                                 onApply: { realIDs in
                                     applyScenarioSelection(Set(allPlanEntries.filter {
                                         $0.accountID == appState.watchlist.activeBrokerageAccountID && realIDs.contains($0.plan.id)
                                     }.map(\.id)))
                                 })
            case .syncConflict(let peerID):
                let conflicts = syncConflicts.filter { $0.peerID == peerID }
                PoolSyncConflictSheet(peerID: peerID, conflicts: conflicts) { choosingRemote in
                    appState.folderSync.resolveConflicts(peerID: peerID, choosingRemote: choosingRemote)
                    activeSheet = nil
                    undo = nil
                } onCancel: { activeSheet = nil }
            }
        }
    }

    private func unavailableSheet(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).font(.system(size: 13))
            Button(copy("关闭", "Close")) { activeSheet = nil }.keyboardShortcut(.defaultAction)
        }
        .padding(24).frame(width: 360, height: 130)
    }

    private func percent(_ value: Double, of total: Double) -> String {
        (total > 0 ? min(1, max(0, value / total)) : 0).formatted(.percent.precision(.fractionLength(1)))
    }

    private func quantity(for symbol: SymbolID, in pool: PositionPool) -> Double {
        cards.filter { $0.symbol == symbol && $0.pool == pool }.reduce(0) { $0 + $1.quantity }
    }

    private enum QuoteState: Equatable { case ready, stale, missing }

    private func quoteState(for symbol: SymbolID) -> QuoteState {
        guard let quote = appState.market.quote(for: symbol), quote.price.isFinite, quote.price > 0,
              quote.timestamp.timeIntervalSince1970.isFinite else { return .missing }
        return TradingQuoteHealth.isCurrent(quote) ? .ready : .stale
    }

    private func requestWholeTransfer(_ card: PortionCard, to destination: PositionPool) {
        guard !isWriteBlocked else { return }
        guard !card.needsReview, card.item.positionQuantity > 0 else { return }
        commitTransfer(card, quantity: card.quantity, to: destination, reason: "")
    }

    private func commitTransfer(_ card: PortionCard, quantity: Double, to destination: PositionPool, reason: String) {
        guard !isWriteBlocked else { return }
        guard let allocation = storedItem(card.symbol, in: card.ownerAccountID)?.positionAllocation,
              allocation.revision == card.allocationRevision,
              !conflictedSymbols.contains(card.symbol),
              destination != card.pool, !card.needsReview, quantity.isFinite, quantity > 0 else { return }
        do {
            let updated = try appState.watchlist.withBrokerageAccount(card.ownerAccountID) {
                try appState.watchlist.transferPositionPortion(
                symbol: card.symbol,
                portionID: card.portion.id,
                quantity: quantity,
                to: destination,
                reason: reason,
                expectedRevision: allocation.revision
                )
            }
            undo = UndoState(symbol: card.symbol, previous: allocation, expectedRevision: updated.revision, accountID: card.ownerAccountID)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func restore(_ undo: UndoState) {
        // Undo is a write. A rehearsal must not be able to roll anything back.
        guard !isWriteBlocked else { return }
        guard !conflictedSymbols.contains(undo.symbol),
              storedItem(undo.symbol, in: undo.accountID)?.positionAllocation?.revision == undo.expectedRevision else {
            self.undo = nil
            return
        }
        do {
            _ = try appState.watchlist.withBrokerageAccount(undo.accountID) {
                try appState.watchlist.restorePositionAllocation(
                symbol: undo.symbol,
                previous: undo.previous,
                expectedRevision: undo.expectedRevision
                )
            }
            self.undo = nil
        } catch {
            self.undo = nil
            showError(error.localizedDescription)
        }
    }

    private func updateDrag(_ card: PortionCard, value: DragGesture.Value, shift: Bool) {
        guard !isWriteBlocked else { return }
        guard planDrag == nil, !card.needsReview, card.item.positionQuantity > 0 else { return }
        if let current = drag, current.card.id != card.id { return }
        guard let state = drag ?? startDrag(card, value: value) else { return }
        // Only a modifier change writes board state; the pointer goes to `motion`.
        if drag?.shift != shift {
            var shifted = state
            shifted.shift = shift
            drag = shifted
        }
        motion.move(to: value.location,
                    target: target(at: value.location, symbol: card.symbol, excluding: card.pool))
    }

    private func startDrag(_ card: PortionCard, value: DragGesture.Value) -> DragState? {
        guard let sourceFrame = cardFrames[card.id], !sourceFrame.isNull, !sourceFrame.isEmpty else { return nil }
        let state = DragState(
            card: card,
            sourceFrame: sourceFrame,
            grabOffset: PositionPoolDragGeometry.grabOffset(pointer: value.startLocation, sourceFrame: sourceFrame),
            shift: NSEvent.modifierFlags.contains(.shift)
        )
        drag = state
        return state
    }

    private func endDrag(_ card: PortionCard, value: DragGesture.Value) {
        guard !isWriteBlocked else { return }
        guard drag?.card.id == card.id else { return }
        let partial = NSEvent.modifierFlags.contains(.shift)
        // Resolve the final position, then leave the drag path in this same call.
        // Every guard runs before anything is cleared or committed.
        let destination = target(at: value.location, symbol: card.symbol, excluding: card.pool)
        let current = storedItem(card.symbol, in: card.ownerAccountID)
        let isCurrent = current?.positionAllocation?.revision == card.allocationRevision
            && !conflictedSymbols.contains(card.symbol)
        drag = nil
        motion.target = nil
        guard isCurrent, let destination else { return }
        completeDrop(card, target: destination, partial: partial)
    }

    private func completeDrop(_ card: PortionCard, target: PoolDropTarget, partial: Bool) {
        guard !conflictedSymbols.contains(card.symbol),
              storedItem(card.symbol, in: card.ownerAccountID)?.positionAllocation?.revision == card.allocationRevision else { return }
        if partial {
            openSheet(.transfer(TransferDraft(symbol: card.symbol, portionID: card.portion.id, destination: target.pool)), in: card.ownerAccountID)
        } else {
            commitTransfer(card, quantity: card.quantity, to: target.pool, reason: "")
        }
    }

    /// Cancels any drag in flight. Without the settle animation there is nothing
    /// to return: clearing the matching drag restores the placeholder at once.
    private func returnDragToSource(_ state: DragState) {
        guard drag?.card.id == state.card.id else { return }
        drag = nil
        motion.target = nil
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

enum PositionPoolDragGeometry {
    static func grabOffset(pointer: CGPoint, sourceFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - sourceFrame.minX, y: pointer.y - sourceFrame.minY)
    }

    static func proxyCenter(pointer: CGPoint, grabOffset: CGPoint, cardSize: CGSize) -> CGPoint {
        CGPoint(
            x: pointer.x - grabOffset.x + cardSize.width / 2,
            y: pointer.y - grabOffset.y + cardSize.height / 2
        )
    }

    /// The grip, expressed as a fraction of the source card. The badge keeps the
    /// same relative hold after the card shrinks to a badge, so the badge does
    /// not jump under the cursor at pickup.
    static func normalizedGrip(_ grabOffset: CGPoint, sourceSize: CGSize) -> CGPoint {
        CGPoint(x: sourceSize.width > 0 ? grabOffset.x / sourceSize.width : 0,
                y: sourceSize.height > 0 ? grabOffset.y / sourceSize.height : 0)
    }

    static func badgeGrip(_ grip: CGPoint, badgeSize: CGSize) -> CGPoint {
        CGPoint(x: grip.x * badgeSize.width, y: grip.y * badgeSize.height)
    }

    /// Where the badge sits for a pointer position: the pointer keeps the grip
    /// it took on the source. A pointer outside the board clamps the badge back
    /// inside instead of reading as a drop.
    static func proxyPosition(pointer: CGPoint, grabOffset: CGPoint, badgeSize: CGSize,
                              viewport: CGRect) -> CGPoint {
        let point = proxyCenter(pointer: pointer, grabOffset: grabOffset, cardSize: badgeSize)
        return viewport.contains(pointer) ? point : clamp(point, cardSize: badgeSize, in: viewport)
    }

    static func clamp(_ point: CGPoint, cardSize: CGSize, in bounds: CGRect) -> CGPoint {
        let halfWidth = min(cardSize.width / 2, max(0, bounds.width / 2))
        let halfHeight = min(cardSize.height / 2, max(0, bounds.height / 2))
        return CGPoint(
            x: min(bounds.maxX - halfWidth, max(bounds.minX + halfWidth, point.x)),
            y: min(bounds.maxY - halfHeight, max(bounds.minY + halfHeight, point.y))
        )
    }
}

private struct PoolDropFrameKey: PreferenceKey {
    static let defaultValue: PositionPoolsView.DropFrames = .init()
    static func reduce(value: inout PositionPoolsView.DropFrames, nextValue: () -> PositionPoolsView.DropFrames) {
        let next = nextValue()
        value.cards.merge(next.cards, uniquingKeysWith: { _, new in new })
        value.pools.merge(next.pools, uniquingKeysWith: { _, new in new })
        if let viewport = next.viewport { value.viewport = viewport }
    }
}

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
    var onSetAccount: (BrokerageAccountID) -> Void = { _ in }
    let onDragChanged: (DragGesture.Value, Bool) -> Void
    let onDragEnded: (DragGesture.Value) -> Void
    let isDraggable: Bool
    let isPlaceholder: Bool
    /// Preview disables every menu, drag, and accessibility write on the card.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    private let space = "position-pools-board"

    private var quote: Quote? { appState.market.quote(for: card.symbol) }
    private var transaction: PositionTransaction? {
        guard let id = card.portion.origin.transactionID else { return nil }
        return card.item.transactions.first { $0.id == id }
    }
    private var strategy: String? {
        transaction?.review?.strategy?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    private var thesis: String? { card.item.thesis?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private var originText: String {
        if card.portion.origin.kind == .snapshot {
            return copy("现有持仓快照", "Existing position snapshot")
        }
        let date = card.portion.origin.date?.formatted(date: .abbreviated, time: .omitted)
        let price = card.portion.origin.price.map { PriceFormatter.price($0, market: card.symbol.market) }
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
                // old portion never grows a repeated "未标注" row.
                FundingSourceTag(source: card.portion.fundingSource)
                Spacer(minLength: 0)
                Menu {
                    ForEach(PositionPool.activeCases.filter { $0 != card.pool }, id: \.self) { target in
                        Button(copy("全部转入\(target.title)", "Move all to \(target.title)")) { onWholeTransfer(target) }
                    }
                    Divider()
                    Button(copy("部分转移…", "Split quantity…")) { onPartialTransfer(nil) }
                    Divider()
                    Button(copy("标记资金来源…", "Mark funding source…")) { onMarkFunding() }
                    Button(copy("编辑验证…", "Edit verification…")) { onEditVerification() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isWriteBlocked || card.needsReview || card.item.positionQuantity <= 0)
                .help(isWriteBlocked
                      ? copy("预演模式下不能转移或标记来源", "Moves and funding marks are unavailable in preview")
                      : (card.needsReview ? copy("请先核对这张份额卡", "Reconcile this portion first") : ""))
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
                    Text(card.item.positionAllocationNeedsReconciliation
                         ? copy("待核对", "Review") : copy("同步冲突", "Sync conflict"))
                        .font(PoolType.labelMedium).foregroundStyle(.orange)
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
                PositionAccountTag(account: card.accountID, isEnabled: !isWriteBlocked && !card.needsReview, onSelect: onSetAccount)
                Text(originText)
                    .font(PoolType.label).foregroundStyle(.secondary).lineLimit(1)
                if let verificationBadge {
                    VerificationBadge(badge: verificationBadge, compact: true)
                }
                Spacer(minLength: 0)
            }
            if let summary {
                Label(summary, systemImage: "text.alignleft")
                    .font(PoolType.label).foregroundStyle(.secondary).lineLimit(1)
                    .help(summary)
            }
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
        .accessibilityAction(named: Text(copy("部分转移…", "Split quantity…"))) { if canWrite { onPartialTransfer(nil) } }
        .accessibilityAction(named: Text(copy("标记资金来源…", "Mark funding source…"))) { if canWrite { onMarkFunding() } }
        .accessibilityAction(named: Text(copy("编辑验证…", "Edit verification…"))) { if canWrite { onEditVerification() } }
        .accessibilityAction(named: Text(copy("移动到未分配", "Move to Unassigned"))) { if canWrite { onWholeTransfer(.unassigned) } }
        .accessibilityAction(named: Text(copy("移动到战略底仓", "Move to Strategic"))) { if canWrite { onWholeTransfer(.strategic) } }
        .accessibilityAction(named: Text(copy("移动到机动仓", "Move to Tactical"))) { if canWrite { onWholeTransfer(.tactical) } }
    }

    /// Every entry point on the card — menu, drag, accessibility — reads this
    /// single gate, so preview cannot reach a single ledger write.
    private var canWrite: Bool { isDraggable && !isWriteBlocked }

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

private struct PoolPlanEditorSheet: View {
    let symbol: SymbolID
    let planID: UUID?
    let onClose: () -> Void
    @Environment(AppState.self) private var appState
    @State private var route: PopoverRoute = .planList

    var body: some View {
        PlanEditorView(symbol: symbol, planID: planID, returnRoute: .planList, route: $route,
                       account: appState.watchlist.activeBrokerageAccountID)
            .frame(width: 520, height: 420)
            .onAppear { route = .plan(symbol, planID, .planList) }
            .onChange(of: route) { _, value in if value == .planList { onClose() } }
    }
}

private struct PoolTransferSheet: View {
    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let initialDestination: PositionPool?
    let onCancel: () -> Void
    let onSuccess: (PositionAllocation, PositionAllocation) -> Void
    /// Preview withholds this sheet; the flag is the last line of defence.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    @State private var destination: PositionPool
    @State private var amount = ""
    @State private var reason = ""
    @State private var errorMessage: String?

    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         initialDestination: PositionPool?,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping (PositionAllocation, PositionAllocation) -> Void,
         isWriteBlocked: Bool = false) {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self.initialDestination = initialDestination
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _destination = State(initialValue: initialDestination ?? PositionPool.activeCases.first { $0 != portion.pool.effectivePurpose } ?? .unassigned)
    }

    private var parsedAmount: Double? { Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canSubmit: Bool {
        guard let parsedAmount, parsedAmount.isFinite, parsedAmount > 0,
              parsedAmount <= portion.quantity,
              destination != portion.pool else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("拆分并转移", "Split and move"))
                    .font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(copy("当前", "Current")) \(poolQuantity(portion.quantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            TextField(copy("转移数量", "Quantity to move"), text: $amount)
                .textFieldStyle(.roundedBorder)
                .onChange(of: amount) { _, _ in errorMessage = nil }
            Picker(copy("目标用途", "Destination"), selection: $destination) {
                ForEach(PositionPool.activeCases.filter { $0 != portion.pool.effectivePurpose }, id: \.self) { pool in Text(pool.title).tag(pool) }
            }
            TextField(copy("转移原因（选填）", "Reason (optional)"), text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            if let errorMessage { Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认转移", "Move portion"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        // The sheet is already withheld in preview; this is the last line of
        // defence if a stale presentation ever survives a mode switch.
        guard !isWriteBlocked else { return }
        guard let amount = parsedAmount, canSubmit else { return }
        guard !appState.folderSync.positionAllocationConflicts.contains(where: { $0.symbol == item.symbol }) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            let updated = try appState.watchlist.transferPositionPortion(
                symbol: item.symbol,
                portionID: portion.id,
                quantity: amount,
                to: destination,
                reason: reason,
                expectedRevision: allocation.revision
            )
            onSuccess(allocation, updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

/// Marks which money one portion card was bought with.
///
/// This is a labelling sheet, not a money form: it changes no price, no
/// quantity, and no cost. Marking part of a card leaves the remainder in the
/// original card — the split is the store's job, and this sheet only says how
/// many shares and what they are. The whole card is the default so the common
/// case is one click, and a partial amount is what creates a second card.
struct FundingSourceSheet: View {
    let item: WatchItem
    let portion: PositionPortion
    let allocation: PositionAllocation
    let onCancel: () -> Void
    let onSuccess: (PositionAllocation, PositionAllocation) -> Void
    /// Preview withholds this sheet; the flag is the last line of defence.
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    /// Starts on the card's current annotation, so reopening the sheet to
    /// correct a mistake is a deliberate change rather than a reset. A `nil`
    /// card seeds `.unmarked` — the picker needs a concrete tag, and saving it
    /// without touching anything is blocked as "same source" by the store.
    ///
    /// The selection is optional so a legacy card's default is its real `nil`
    /// state rather than a fabricated `.unmarked`; choosing `.unmarked` then
    /// reads as the explicit clearing it is.
    @State private var source: PositionFundingSource?
    @State private var amount: String
    @State private var reason = ""
    @State private var errorMessage: String?

    init(item: WatchItem, portion: PositionPortion, allocation: PositionAllocation,
         onCancel: @escaping () -> Void,
         onSuccess: @escaping (PositionAllocation, PositionAllocation) -> Void,
         isWriteBlocked: Bool = false) {
        self.item = item
        self.portion = portion
        self.allocation = allocation
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _source = State(initialValue: portion.fundingSource)
        // The whole card by default: "this entire lot was bought on margin" is
        // the answer most of the time, and a partial amount is the deliberate
        // case that splits the card.
        _amount = State(initialValue: poolQuantityInput(portion.quantity))
    }

    private var parsedAmount: Double? {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty, let value = Double(text) else { return nil }
        return value
    }

    /// A partial annotation must be a real, positive number of shares that
    /// fits inside this card. Zero and negatives are refused rather than
    /// silently clamped, and the tolerance mirrors the store's own comparison
    /// so "the whole card" cannot be rejected by a floating-point hair.
    private var canSubmit: Bool {
        guard !isWriteBlocked, let source else { return false }
        guard let parsedAmount, parsedAmount.isFinite, parsedAmount > 0 else { return false }
        let tolerance = PositionAllocation.quantityTolerance(parsedAmount, portion.quantity)
        guard parsedAmount <= portion.quantity + tolerance else { return false }
        // The store compares against the raw stored value, where `nil` and
        // `.unmarked` are different states. Matching that exactly keeps the app
        // from blocking a change the store would accept — explicitly clearing a
        // legacy card to `.unmarked` is a real edit.
        return portion.fundingSource != source
    }

    private var isPartial: Bool {
        guard let parsedAmount, parsedAmount.isFinite else { return false }
        return parsedAmount < portion.quantity - PositionAllocation.quantityTolerance(parsedAmount, portion.quantity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("标记资金来源", "Mark funding source"))
                    .font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(item.symbol.displayCode) · \(copy("当前", "Current")) \(poolQuantity(portion.quantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Picker(copy("资金来源", "Funding source"), selection: $source) {
                Text(fundingSourceTitle(nil)).tag(nil as PositionFundingSource?)
                ForEach(fundingSourcePickerOptions, id: \.self) { value in
                    Text(fundingSourceTitle(value)).tag(Optional(value))
                }
            }
            .onChange(of: source) { _, _ in errorMessage = nil }
            HStack {
                Text(copy("标记数量", "Quantity to mark"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(copy("标记数量", "Quantity to mark"), text: $amount)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: amount) { _, _ in errorMessage = nil }
            }
            if isPartial {
                // Say what the split will do before it happens, so a second
                // card appearing is expected rather than surprising.
                Text(copy("将拆出 \(poolQuantity(parsedAmount ?? 0)) 股单独标记，其余保持不变。",
                          "Splits \(poolQuantity(parsedAmount ?? 0)) shares into their own card; the rest is unchanged."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(copy("备注（选填）", "Note (optional)"), text: $reason, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Text(copy("标记只记录份额的资金来源，不改动价格、数量、成本或成交记录，也不代表已还款。",
                      "This records which money bought the shares. It changes no price, quantity, cost, or fill, and repays nothing."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("确认标记", "Mark source"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 410)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func submit() {
        guard !isWriteBlocked else { return }
        guard let parsedAmount, let source, canSubmit else { return }
        // A conflict that landed while the sheet was open makes the revision
        // below stale; refuse here so the message is about the conflict rather
        // than a generic stale-revision error.
        guard !appState.folderSync.positionAllocationConflicts.contains(where: { $0.symbol == item.symbol }) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            let updated = try appState.watchlist.markPositionFundingSource(
                symbol: item.symbol,
                portionID: portion.id,
                quantity: parsedAmount,
                source: source,
                reason: reason,
                expectedRevision: allocation.revision
            )
            onSuccess(allocation, updated)
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

private struct PoolReconciliationSheet: View {
    let item: WatchItem
    let allocation: PositionAllocation
    let onCancel: () -> Void
    let onSuccess: () -> Void
    var isWriteBlocked = false

    @Environment(AppState.self) private var appState
    @State private var values: [UUID: String]
    @State private var reason = ""
    @State private var errorMessage: String?

    init(item: WatchItem, allocation: PositionAllocation, onCancel: @escaping () -> Void,
         onSuccess: @escaping () -> Void, isWriteBlocked: Bool = false) {
        self.item = item
        self.allocation = allocation
        self.onCancel = onCancel
        self.onSuccess = onSuccess
        self.isWriteBlocked = isWriteBlocked
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: allocation.portions.map { ($0.id, poolQuantityInput($0.quantity)) }))
    }

    private var parsed: [UUID: Double]? {
        var result: [UUID: Double] = [:]
        for portion in allocation.portions {
            let text = (values[portion.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let number = text.isEmpty ? 0 : (Double(text) ?? .nan)
            guard number.isFinite, number >= 0 else { return nil }
            result[portion.id] = number
        }
        return result
    }

    private var enteredTotal: Double { parsed?.values.reduce(0, +) ?? .nan }
    private var residual: Double { max(0, item.positionQuantity - enteredTotal) }
    private var hasInvalidSources: Bool {
        !allocation.hasMatchingSources(for: item)
    }
    private var canSubmit: Bool {
        guard let parsed, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return parsed.values.reduce(0, +) <= item.positionQuantity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("核对仓位分配", "Reconcile allocation")).font(.system(size: 18, weight: .semibold))
                Text("\(item.resolvedDisplayName) · \(copy("当前账本总量", "Ledger total")) \(poolQuantity(item.positionQuantity))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if hasInvalidSources {
                Label(
                    copy("买入来源与当前账本不一致。保存会保留你确认的数量、用途、备注与历史；来源将更新为当前账本快照，旧成交价不再作为精确来源展示。", "A buy source no longer matches the ledger. Saving preserves your confirmed quantities, pools, notes, and history; sources become a current ledger snapshot, so old trade prices are no longer shown as exact origins."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(allocation.portions) { portion in
                        HStack {
                            // The funding annotation is part of what the user
                            // is confirming: reconciliation fixes quantities,
                            // and if it also rebuilds sources the row must say
                            // what it is starting from rather than letting the
                            // composition change invisibly.
                            Text("\(portion.pool.title) · \(originLabel(portion)) · \(fundingSourceTitle(portion.fundingSource))")
                                .font(.system(size: 10)).lineLimit(1)
                            Spacer(minLength: 8)
                            TextField("0", text: valueBinding(portion.id))
                                .textFieldStyle(.roundedBorder).frame(width: 110)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            HStack {
                Text(copy("录入份额", "Entered portions"))
                Spacer()
                Text(poolQuantity(enteredTotal)).monospacedDigit()
            }
            HStack {
                Text(copy("剩余记入未分配快照", "Residual to unassigned snapshot"))
                Spacer()
                Text(poolQuantity(residual)).monospacedDigit().foregroundStyle(.secondary)
            }
            TextField(copy("核对原因", "Reason for reconciliation"), text: $reason)
                .textFieldStyle(.roundedBorder)
            if let errorMessage { Text(errorMessage).font(.system(size: 10)).foregroundStyle(.red) }
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("保存并核对", "Save reconciliation"), action: submit)
                    .keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(22).frame(width: 500, height: 470)
    }

    private func valueBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { values[id] ?? "" }, set: { values[id] = $0; errorMessage = nil })
    }

    private func originLabel(_ portion: PositionPortion) -> String {
        guard portion.origin.kind == .buy else { return copy("持仓快照", "Position snapshot") }
        return portion.origin.date?.formatted(date: .abbreviated, time: .omitted) ?? copy("买入来源", "Buy source")
    }

    private func submit() {
        guard !isWriteBlocked else { return }
        guard canSubmit else { return }
        guard !appState.folderSync.positionAllocationConflicts.contains(where: { $0.symbol == item.symbol }) else {
            errorMessage = copy("该标的刚出现同步冲突，请先核对两个版本。", "This symbol now has a sync conflict. Review both candidates first.")
            return
        }
        do {
            _ = try appState.watchlist.reconcilePositionAllocation(
                symbol: item.symbol,
                quantities: parsed ?? [:],
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                expectedRevision: allocation.revision
            )
            onSuccess()
        } catch { errorMessage = error.localizedDescription }
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

private struct PoolSyncConflictSheet: View {
    let peerID: String
    let conflicts: [FolderSyncController.PositionAllocationConflictSummary]
    let onResolve: (Bool) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy("仓位分账同步冲突", "Position allocation sync conflict"))
                    .font(.system(size: 18, weight: .semibold))
                Text(copy("设备 \(peerID.prefix(8)) · \(conflicts.count) 个标的", "Device \(peerID.prefix(8)) · \(conflicts.count) symbols"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(conflict.symbol.displayCode).font(.system(size: 11, weight: .semibold))
                            HStack(alignment: .top, spacing: 12) {
                                candidate(copy("此设备", "This device"), conflict.local)
                                candidate(copy("对端设备", "Other device"), conflict.remote)
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .frame(maxHeight: 260)
            Text(copy("选择会解决该设备的全部同步冲突；系统会先保存冲突备份。", "Your choice resolves all sync conflicts with this device; a conflict backup is saved first."))
                .font(.system(size: 10)).foregroundStyle(.orange)
            HStack {
                Button(copy("取消", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(copy("采用此设备全部分配", "Keep all from this device")) { onResolve(false) }
                Button(copy("采用对端设备全部分配", "Use all from other device")) { onResolve(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 620, height: 480)
    }

    private func candidate(_ title: String, _ allocation: PositionAllocation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PoolType.labelMedium).foregroundStyle(.secondary)
            if let allocation {
                // Grouped by effective purpose: a legacy observation portion is
                // read as unassigned here, exactly as it is on the board, so a
                // conflict candidate never shows a purpose the product retired.
                ForEach(PositionPool.activeCases, id: \.self) { pool in
                    let quantity = allocation.portions
                        .filter { $0.pool.effectivePurpose == pool }
                        .reduce(0) { $0 + $1.quantity }
                    if quantity > 0 {
                        Text("\(pool.title) \(poolQuantity(quantity))")
                            .font(PoolType.label.monospacedDigit())
                    }
                }
            } else {
                Text(copy("无分配", "No allocation")).font(PoolType.label).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }
}

extension PositionPool {
    /// The label for a purpose. The retired observation case is never an active
    /// destination, so the only place it can still reach a label is a legacy
    /// record being read back — and there it must read as what the product now
    /// means by that value: unassigned shares whose conditions carry the
    /// verification. The parenthetical keeps the origin honest without offering
    /// a purpose that no longer exists.
    var title: String {
        switch self {
        case .unassigned: positionPoolCopy("未分配", "Unassigned")
        case .strategic: positionPoolCopy("战略底仓", "Strategic")
        case .observation: positionPoolCopy("未分配（原观察仓）", "Unassigned (was Observation)")
        case .tactical: positionPoolCopy("机动仓", "Tactical")
        }
    }

    var subtitle: String {
        switch self {
        case .unassigned: positionPoolCopy("等待你确认用途", "Awaiting your classification")
        case .strategic: positionPoolCopy("长期参与", "Long-term participation")
        case .observation: positionPoolCopy("持有判断写在份额的验证条件里", "Conditions live on the portion now")
        case .tactical: positionPoolCopy("按策略灵活管理", "Managed by a trading strategy")
        }
    }

    var symbolName: String {
        switch self {
        case .unassigned: "tray.full"
        case .strategic: "anchor"
        case .observation: "tray.full"
        case .tactical: "arrow.left.arrow.right"
        }
    }

    /// The money-purpose tint. Observation wears the neutral unassigned gray:
    /// it is not an active purpose, and a purple column would imply one.
    /// Purple belongs to verification alone.
    var tint: Color {
        switch self {
        case .unassigned, .observation: Color.gray
        case .strategic: Color.blue
        case .tactical: Color.orange
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func positionPoolCopy(_ chinese: String, _ english: String) -> String {
    PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
}

private func poolQuantity(_ value: Double) -> String {
    if value.isFinite, value != 0, abs(value) < 1e-12 { return value.description }
    return value.formatted(.number.precision(.fractionLength(0...12)))
}


private func poolQuantityInput(_ value: Double) -> String { String(value) }
