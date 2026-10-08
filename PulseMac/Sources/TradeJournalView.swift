import SwiftUI
import PulseCore
import PulseUI

/// Cross-symbol trade history and post-trade notes for the main window.
struct TradeJournalView: View {
    /// The raw value is the stored/round-trip key; the UI shows `title`.
    enum ReviewScope: String, CaseIterable {
        case today = "今日", pending = "待补", all = "全部"

        var title: String {
            switch self {
            case .today: PulseLocalization.localizedString("journal.scope.today")
            case .pending: PulseLocalization.localizedString("journal.scope.pending")
            case .all: PulseLocalization.localizedString("journal.scope.all")
            }
        }
    }

    /// Which ledger the journal is *showing*. A view filter only: it never
    /// changes the store's selected account, and every row keeps naming the
    /// account it actually came from.
    private enum AccountScope: Hashable, CaseIterable {
        case all
        case account(BrokerageAccountID)

        /// Menu order: the unfiltered view first, then the named ledgers, then
        /// the legacy records that no longer carry a label.
        static var allCases: [AccountScope] {
            [.all, .account(.financing), .account(.mengmeng), .account(.unassigned)]
        }

        var title: String {
            switch self {
            case .all: PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? "全部账户" : "All accounts"
            case .account(let id): AccountIdentity.title(id)
            }
        }

        func includes(_ account: BrokerageAccountID) -> Bool {
            switch self {
            case .all: true
            case .account(let id): id == account
            }
        }
    }

    private struct TradeKey: Hashable {
        let accountID: BrokerageAccountID
        let symbol: SymbolID
        let transactionID: UUID
    }

    private struct Entry: Identifiable {
        /// The ledger this fill was read out of. Two ledgers may hold the same
        /// symbol, so every row carries its owner: the key keeps them distinct,
        /// and the row, the detail caption and the save all read it.
        let accountID: BrokerageAccountID
        let item: WatchItem
        let transaction: PositionTransaction
        let replayIndex: Int
        let realizedPnL: Double?

        var id: TradeKey {
            TradeKey(accountID: accountID, symbol: item.symbol, transactionID: transaction.id)
        }
    }

    private enum PlanChoice: String, CaseIterable, Identifiable {
        case unset
        case yes
        case no

        var id: String { rawValue }
        var title: String {
            switch self {
            case .unset: PulseLocalization.localizedString("journal.plan.unset")
            case .yes: PulseLocalization.localizedString("journal.plan.yes")
            case .no: PulseLocalization.localizedString("journal.plan.no")
            }
        }
        var value: Bool? {
            switch self {
            case .unset: nil
            case .yes: true
            case .no: false
            }
        }

        init(_ value: Bool?) {
            switch value {
            case .some(true): self = .yes
            case .some(false): self = .no
            case .none: self = .unset
            }
        }
    }

    /// The plan context of one fill, reduced to plain facts. Built once from
    /// whichever source still knows the plan, then rendered — never re-read,
    /// so a plan edited or deleted after the fact cannot rewrite what this
    /// trade was actually recorded against.
    ///
    /// Two sources, in order. A transaction written by the execution sheet
    /// carries an immutable `planExecution` snapshot, which is the plan as it
    /// stood at the moment of the fill. Older trades carry only the plan's
    /// `filledTransactionID`, so the live plan is read as a fallback and
    /// marked as such: it may have moved since.
    private struct PlanContext {
        let kind: TradePlan.Kind
        let price: Double
        let quantity: Double
        let positionPool: PositionPool?
        let conditions: [TradePlanCondition]
        let note: String?
        let fundingSource: PositionFundingSource?
        let isSnapshot: Bool
        /// How many times the live plan's configuration changed after this
        /// snapshot was taken. Only meaningful when `isSnapshot` is false.
        let revisionCount: Int

        /// Which way this fill landed against the plan price, in the money
        /// the fill itself was worth. Nil when the two prices are equal or
        /// either is unusable — a zero difference has no direction.
        ///
        /// This is *not* realized P&L: a buy below its plan price does not
        /// book anything until the position is closed, and a sell above its
        /// plan price raises more cash rather than realizing more. The sign
        /// names the direction of the deviation, and the wording below says
        /// only that the fill was better or worse than written down.
        func deviation(for transaction: PositionTransaction) -> (amount: Double, isFavourable: Bool)? {
            guard price.isFinite, price > 0,
                  transaction.price.isFinite, transaction.price > 0,
                  transaction.quantity.isFinite, transaction.quantity > 0 else { return nil }
            let difference = kind == .buy
                ? price - transaction.price
                : transaction.price - price
            let signed = difference * transaction.quantity
            guard signed.isFinite, signed != 0 else { return nil }
            return (abs(signed), signed > 0)
        }
    }

    @Environment(AppState.self) private var appState
    let onSelect: (SymbolID) -> Void
    @State private var query = ""
    @State private var selectedMonth: Date?
    /// Local to this page and independent of `activeBrokerageAccountID`: the
    /// journal reads every ledger at once, and the global selection is only
    /// where a write is routed. Defaults to `.all` and is never re-derived
    /// from the global account.
    @State private var accountScope: AccountScope = .all
    @State private var selection: TradeKey?
    @State private var note = ""
    @State private var followedPlan = PlanChoice.unset
    @State private var retrospective = ""
    @State private var strategy = ""
    @State private var showStrategyAnalysis = false
    @State private var saved = false
    @State private var saveError = false
    @State private var reviewScope: ReviewScope = .today
    @State private var schedulesReview = false
    @State private var nextReviewDate = Date.now
    @State private var nextReviewNote = ""
    /// The account the selected trade and this review draft belong to, captured
    /// when the transaction is opened. The store object survives an account
    /// switch with a different ledger inside it, and a fill id is not proof of
    /// which account the draft was written for.
    @State private var frozenAccount: BrokerageAccountID?
    /// How many times the pending id has been retried against a changed entry
    /// list. A pending id can arrive before this view observes the ledger that
    /// holds it, so the retry waits for entries — but only for a bounded number
    /// of them, never indefinitely.
    @State private var pendingResolutionAttempts = 0
    private static let maximumPendingResolutionAttempts = 5
    private var initialTransactionID: UUID?

    init(onSelect: @escaping (SymbolID) -> Void, initialTransactionID: UUID? = nil) {
        self.onSelect = onSelect
        self.initialTransactionID = initialTransactionID
    }

    /// Non-nil only while the exact record this draft was opened from is still
    /// resolvable: the frozen owner still names one of the entries, and the
    /// selection still points at that same entry. Used to tint the caption.
    private var accountMatchesDraft: Bool {
        guard let frozenAccount, let selection else { return false }
        return entries.contains { $0.id == selection && $0.accountID == frozenAccount }
    }

    /// Every fill in every enabled ledger. `records` returns each ledger's
    /// items, so the same symbol — or even the same transaction id — can appear
    /// once per account; the owner rides along on each entry instead of being
    /// merged away. Realized P&L is read from that record's own ledger only.
    private var entries: [Entry] {
        BrokerageBoardReader.records(store: appState.watchlist)
            .filter { !$0.item.transactions.isEmpty }
            .flatMap { record in
                let transactions = record.item.transactions
                let realized = Dictionary(uniqueKeysWithValues: (record.item.ledger?.entries ?? []).map {
                    ($0.transaction.id, $0.realizedPnL)
                })
                return transactions.enumerated().map { index, transaction in
                    Entry(
                        accountID: record.accountID,
                        item: record.item,
                        transaction: transaction,
                        replayIndex: index,
                        realizedPnL: realized[transaction.id] ?? nil
                    )
                }
            }.sorted { lhs, rhs in
                let calendar = Calendar.current
                let leftDay = calendar.startOfDay(for: lhs.transaction.date)
                let rightDay = calendar.startOfDay(for: rhs.transaction.date)
                if leftDay != rightDay { return leftDay > rightDay }
                if lhs.transaction.createdAt != rhs.transaction.createdAt {
                    return lhs.transaction.createdAt > rhs.transaction.createdAt
                }
                if lhs.item.symbol != rhs.item.symbol {
                    return lhs.item.symbol.displayCode < rhs.item.symbol.displayCode
                }
                if lhs.replayIndex != rhs.replayIndex { return lhs.replayIndex > rhs.replayIndex }
                // The same trade can sit in two ledgers, so the owner closes
                // the ordering: a stable order that never flickers between them.
                return lhs.accountID.rawValue < rhs.accountID.rawValue
            }
    }

    /// The entries the local account filter admits — the single source every
    /// other readout on this page derives from.
    private var scopedEntries: [Entry] {
        entries.filter { accountScope.includes($0.accountID) }
    }

    /// The scoped items the summaries aggregate over. Two ledgers holding the
    /// same symbol stay two entries here: no cross-account merging.
    private var scopedItems: [WatchItem] {
        BrokerageBoardReader.records(store: appState.watchlist)
            .filter { accountScope.includes($0.accountID) && !$0.item.transactions.isEmpty }
            .map(\.item)
    }

    private var monthOptions: [Date] {
        Array(Set(scopedEntries.compactMap {
            Calendar.current.dateInterval(of: .month, for: $0.transaction.date)?.start
        })).sorted(by: >)
    }

    private var filteredEntries: [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopedEntries.filter { entry in
            switch reviewScope {
            case .today where !Calendar.current.isDateInToday(entry.transaction.date): return false
            case .pending where entry.transaction.kind == .adjustment
                || (!TradingWorkbenchView.needsReview(entry.transaction) && !checkpointDue(entry.transaction)): return false
            default: break
            }
            if let selectedMonth,
               !Calendar.current.isDate(entry.transaction.date, equalTo: selectedMonth, toGranularity: .month) {
                return false
            }
            return needle.isEmpty
                || entry.item.symbol.displayCode.localizedCaseInsensitiveContains(needle)
                || entry.item.resolvedDisplayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var monthlySummaries: [TradeJournalMonthlySummary] {
        TradeJournalMonthlySummary.make(
            from: scopedItems,
            query: query,
            selectedMonth: selectedMonth
        )
    }

    /// The key to open when a pending fill id arrives. The same UUID can exist
    /// in two ledgers, so the globally active one wins a tie; otherwise the
    /// first match in a deterministic order decides.
    private func resolveEntry(transactionID: UUID) -> Entry? {
        let matches = entries.filter { $0.transaction.id == transactionID }
        guard !matches.isEmpty else { return nil }
        let active = appState.watchlist.activeBrokerageAccountID
        if let owned = matches.first(where: { $0.accountID == active }) { return owned }
        return matches.min { lhs, rhs in
            if lhs.item.symbol != rhs.item.symbol {
                return lhs.item.symbol.displayCode < rhs.item.symbol.displayCode
            }
            return lhs.accountID.rawValue < rhs.accountID.rawValue
        }
    }

    /// The key the pending-id retry observes. Plain value types only, so the
    /// observation is bounded and Equatable.
    private var entryIDs: [TradeKey] { entries.map(\.id) }

    private var selectedEntry: Entry? {
        filteredEntries.first { $0.id == selection }
    }

    /// The plan this trade was recorded against, preferring the immutable
    /// snapshot the execution sheet wrote over the live plan a legacy fill
    /// points at. The live plan is only consulted when no snapshot exists,
    /// and its revision count is measured from `history` — the list the store
    /// appends to on every configuration change.
    private var planContext: PlanContext? {
        guard let selectedEntry else { return nil }
        if let execution = selectedEntry.transaction.planExecution {
            let snapshot = execution.configuration
            return PlanContext(
                kind: snapshot.kind,
                price: snapshot.price,
                quantity: snapshot.quantity,
                positionPool: snapshot.positionPool,
                conditions: snapshot.conditions ?? [],
                note: snapshot.note,
                fundingSource: snapshot.fundingSource,
                isSnapshot: true,
                revisionCount: 0
            )
        }
        guard let plan = selectedEntry.item.plans.first(where: {
            $0.filledTransactionID == selectedEntry.transaction.id
        }) else { return nil }
        return PlanContext(
            kind: plan.kind,
            price: plan.price,
            quantity: plan.quantity,
            positionPool: plan.positionPool,
            conditions: plan.conditions ?? [],
            note: plan.note,
            fundingSource: plan.fundingSource,
            isSnapshot: false,
            revisionCount: plan.history?.count ?? 0
        )
    }

    /// Whether this entry's funding questions are suppressed whole.
    ///
    /// A mengmeng record is bought with that account's own money by
    /// construction: it holds no borrowed shares and its plans intend no
    /// funding method, so neither a transaction's funding line nor a plan's
    /// intended funding says anything the user can act on. Asking for the
    /// annotation anyway would print a label whose only possible answer is the
    /// account itself. Nothing is rewritten — the stored values stay exactly as
    /// they are, and a stored `.margin` on such a record remains readable
    /// through the ledger surfaces that own it.
    ///
    /// The owner is always the *entry's* own ledger. Reading the global
    /// selection instead would describe a different account's trade.
    private func suppressesFunding(_ entry: Entry) -> Bool {
        entry.accountID == .mengmeng
    }

    /// The account whose words a plan's intended funding is named in.
    ///
    /// A fill can land in one ledger while the plan was written in another —
    /// the execution sheet records that owner on the snapshot — and the
    /// intention belongs to the plan, so that is the account whose funding
    /// vocabulary applies. Falls back to the entry's own ledger when no
    /// snapshot recorded one, which is every legacy and same-account fill.
    private func planIntentAccount(_ entry: Entry) -> BrokerageAccountID {
        entry.transaction.planExecution?.sourceAccountID ?? entry.accountID
    }

    var body: some View {
        let summaries = monthlySummaries
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text(PulseLocalization.localizedString("journal.title"))
                        .font(.system(size: 20, weight: .semibold))
                    Spacer()
                    Button(PulseLocalization.localizedString("journal.strategy.button")) { showStrategyAnalysis = true }
                        .controlSize(.small)
                    Text(PulseLocalization.localizedString("journal.count", filteredEntries.count))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField(PulseLocalization.localizedString("journal.search.placeholder"), text: $query)
                        .textFieldStyle(.roundedBorder)
                    // Whose ledgers are shown, not where a write goes: the menu
                    // is labelled from this view's own scope.
                    Picker("", selection: Binding(get: { accountScope }, set: { scope in
                        accountScope = scope
                        selectedMonth = nil
                        frozenAccount = nil
                        selection = nil
                        saved = false
                        clearDraftFields()
                    })) {
                        ForEach(AccountScope.allCases, id: \.self) { scope in
                            scopeLabel(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(accountScope.title)
                    Picker(PulseLocalization.localizedString("journal.month"), selection: $selectedMonth) {
                        Text(PulseLocalization.localizedString("journal.month.all")).tag(nil as Date?)
                        ForEach(monthOptions, id: \.self) { month in
                            Text(PositionDateFormat.monthGroup(month)).tag(Optional(month))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                HStack(spacing: 6) {
                    Picker(PulseLocalization.localizedString("journal.scope"), selection: $reviewScope) {
                        ForEach(ReviewScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Text(PulseLocalization.localizedString("journal.dateBasis")).font(.caption2).foregroundStyle(.secondary)
                if !summaries.isEmpty {
                    Text(PulseLocalization.localizedString("journal.summary.heading"))
                        .font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(summaries) { summary in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(PositionDateFormat.monthGroup(summary.month))
                                        Text(summary.currencyCode).fontWeight(.semibold)
                                        Spacer(minLength: 4)
                                    }
                                    Text(PulseLocalization.localizedString(
                                        "journal.summary.realized",
                                        summary.realizedPnL.map { PriceFormatter.signedMoney($0, currencyCode: summary.currencyCode) } ?? "—"
                                    ))
                                        .foregroundStyle(summary.realizedPnL.map { appState.palette.color(isUp: $0 >= 0) } ?? Color.secondary)
                                    HStack(spacing: 8) {
                                        Text(PulseLocalization.localizedString(
                                            "journal.summary.fees",
                                            summary.fees.map { PriceFormatter.money($0, currencyCode: summary.currencyCode) } ?? "—"
                                        ))
                                        Text(PulseLocalization.localizedString("journal.summary.unknownFees", summary.missingFeeCount))
                                    }
                                    Text(summary.followedPlanPercent.map {
                                        PulseLocalization.localizedString(
                                            "journal.summary.onPlan",
                                            summary.followedPlanYesCount,
                                            summary.reviewedCount,
                                            Int($0.rounded())
                                        )
                                    } ?? PulseLocalization.localizedString("journal.summary.onPlanUnset"))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(size: 10, design: .monospaced))
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: summaries.count > 1 ? 168 : 90)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel(PulseLocalization.localizedString("journal.summary.title"))
                    .help(PulseLocalization.localizedString("journal.summary.help"))
                }
                List(selection: $selection) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                            .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if filteredEntries.isEmpty {
                        ContentUnavailableView(PulseLocalization.localizedString("journal.empty.entries"), systemImage: "book.closed")
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Divider()

            detail
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !entries.contains(where: { Calendar.current.isDateInToday($0.transaction.date) }) { reviewScope = .all }
            openReview(appState.pendingJournalTransactionID ?? initialTransactionID)
        }
        .onChange(of: appState.pendingJournalTransactionID) { _, id in
            pendingResolutionAttempts = 0
            openReview(id)
        }
        // A pending id can arrive before the observations have this view's
        // entries. Retry when entries change, and only while the id is still
        // unresolved and the attempt budget is unspent.
        .onChange(of: entryIDs) { _, _ in
            guard let id = appState.pendingJournalTransactionID else { return }
            guard pendingResolutionAttempts < Self.maximumPendingResolutionAttempts else { return }
            pendingResolutionAttempts += 1
            openReview(id)
        }
        .onChange(of: selection) { _, _ in loadDraft() }
        // The global ledger changed. The selection and the review fields still
        // describe the row that was open, so clear them rather than let stale
        // text look like it belongs to whatever is shown now. The local account
        // filter is deliberately untouched: it is this page's own scope, and
        // every row keeps naming the ledger it actually came from.
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            frozenAccount = nil
            selection = nil
            saved = false
            clearDraftFields()
        }
        .onChange(of: note) { _, _ in saved = false }
        .onChange(of: followedPlan) { _, _ in saved = false }
        .onChange(of: retrospective) { _, _ in saved = false }
        .onChange(of: strategy) { _, _ in saved = false }
        .onChange(of: schedulesReview) { _, _ in saved = false }
        .onChange(of: nextReviewDate) { _, _ in saved = false }
        .onChange(of: nextReviewNote) { _, _ in saved = false }
        .sheet(isPresented: $showStrategyAnalysis) {
            // The sheet reads exactly the items the current scope, query and
            // month select, so two ledgers' copies of a symbol stay separate.
            TradeStrategySummaryView(items: scopedItems, query: query, selectedMonth: selectedMonth)
        }
        .alert(PulseLocalization.localizedString("journal.error.missing.title"), isPresented: $saveError) {
            Button(PulseLocalization.localizedString("journal.error.ok"), role: .cancel) { }
        }
    }

    /// One account-filter menu row. The dot is added only where the menu style
    /// renders content, so `.all` (which has no account) stays plain text.
    @ViewBuilder private func scopeLabel(_ scope: AccountScope) -> some View {
        switch scope {
        case .all:
            Text(scope.title).tag(scope)
        case .account(let id):
            HStack(spacing: 5) {
                Circle().fill(AccountIdentity.dotColor(id)).frame(width: 6, height: 6)
                Text(scope.title)
            }
            .tag(scope)
        }
    }

    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(entry.item.symbol.displayCode)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(entry.item.resolvedDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(kindName(entry.transaction.kind))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.transaction.kind == .buy
                        ? appState.palette.color(isUp: true)
                        : appState.palette.color(isUp: false))
            }
            HStack(spacing: 6) {
                Text(PositionDateFormat.monthDay(entry.transaction.date))
                Text(PriceFormatter.price(entry.transaction.price, market: entry.item.symbol.market))
                Text("×")
                Text(PriceFormatter.quantity(entry.transaction.quantity))
                Spacer()
                if let realizedPnL = entry.realizedPnL {
                    Text(PriceFormatter.signedMoney(realizedPnL, currencyCode: entry.item.symbol.currencyCode))
                        .foregroundStyle(appState.palette.color(isUp: realizedPnL >= 0))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            if let reason = entry.transaction.note, !reason.isEmpty {
                Text(reason).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            // The owning ledger, so two rows for the same symbol read apart.
            HStack(spacing: 4) {
                Circle().fill(AccountIdentity.dotColor(entry.accountID)).frame(width: 5, height: 5)
                Text(AccountIdentity.title(entry.accountID))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            if checkpointDue(entry.transaction) {
                Label(PulseLocalization.localizedString("journal.checkpoint.due"), systemImage: "calendar.badge.clock").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.item.resolvedDisplayName)
                                .font(.system(size: 20, weight: .semibold))
                            Text(entry.item.symbol.displayCode)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Navigation only: this view's account filter is local,
                        // so opening the instrument must not silently reselect
                        // the global ledger (and with it the pool and sector
                        // scopes that follow it).
                        Button(PulseLocalization.localizedString("journal.detail.openSymbol")) {
                            onSelect(entry.item.symbol)
                        }
                        // Named from the account the draft was loaded under —
                        // the entry's own ledger, never the global selection —
                        // so the ledger this review lands in is unambiguous.
                        let captionAccount = frozenAccount ?? entry.accountID
                        HStack(spacing: 5) {
                            Circle().fill(AccountIdentity.dotColor(captionAccount)).frame(width: 5, height: 5)
                            Text(PulseLocalization.localizedString(
                                "journal.detail.accountCaption",
                                AccountIdentity.title(captionAccount)
                            ))
                                .font(.system(size: 10))
                                .foregroundStyle(accountMatchesDraft
                                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        detailLine(PulseLocalization.localizedString("journal.detail.trade"),
                                   PulseLocalization.localizedString("journal.detail.tradeValue", kindName(entry.transaction.kind), fullDate(entry.transaction.date)))
                        detailLine(PulseLocalization.localizedString("journal.detail.price"), PriceFormatter.price(entry.transaction.price, market: entry.item.symbol.market))
                        detailLine(PulseLocalization.localizedString("journal.detail.quantity"), PriceFormatter.quantity(entry.transaction.quantity))
                        if entry.transaction.kind == .buy, !suppressesFunding(entry) {
                            detailLine(PulseLocalization.localizedString("journal.detail.funding"), fundingSourceTitle(entry.transaction.fundingSource, account: entry.accountID))
                        }
                        if let fee = entry.transaction.fee {
                            detailLine(PulseLocalization.localizedString("journal.detail.fee"), PriceFormatter.money(fee, currencyCode: entry.item.symbol.currencyCode))
                        }
                        if let realizedPnL = entry.realizedPnL {
                            detailLine(PulseLocalization.localizedString("journal.detail.realized"), PriceFormatter.signedMoney(realizedPnL, currencyCode: entry.item.symbol.currencyCode))
                        }
                    }

                    if let context = planContext {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(PulseLocalization.localizedString("journal.plan.title")).font(.system(size: 12, weight: .semibold))
                                Spacer(minLength: 0)
                                Text(PulseLocalization.localizedString(context.isSnapshot ? "journal.plan.snapshot" : "journal.plan.current"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(PulseLocalization.localizedString(
                                "journal.plan.line",
                                PulseLocalization.localizedString(context.kind == .buy ? "journal.kind.buy" : "journal.kind.sell"),
                                PriceFormatter.price(context.price, market: entry.item.symbol.market),
                                PriceFormatter.quantity(context.quantity)
                            ))
                                .font(.system(size: 11))
                            Text(PulseLocalization.localizedString(
                                "journal.plan.pool",
                                context.positionPool?.title ?? PulseLocalization.localizedString("journal.plan.poolUnassigned")
                            ))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            if context.kind == .buy, !suppressesFunding(entry) {
                                Text(PulseLocalization.localizedString("journal.plan.plannedFunding", fundingSourceTitle(context.fundingSource, account: planIntentAccount(entry))))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if let note = context.note, !note.isEmpty {
                                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if context.conditions.isEmpty {
                                Text(PulseLocalization.localizedString("journal.plan.noConditions")).font(.system(size: 11)).foregroundStyle(.secondary)
                            } else {
                                ForEach(context.conditions) { condition in
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(PlanExecutionSheet.stateColor(condition.state))
                                            .frame(width: 5, height: 5)
                                        Text(condition.title).font(.system(size: 11))
                                        Text(condition.stateTitle).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            if !context.isSnapshot {
                                Text(context.revisionCount > 0
                                    ? PulseLocalization.localizedString("journal.plan.revised", context.revisionCount)
                                    : PulseLocalization.localizedString("journal.plan.unrevised"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(PulseLocalization.localizedString("journal.plan.snapshotNote"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }

                    executionDeviationCard

                    VStack(alignment: .leading, spacing: 6) {
                        Text(PulseLocalization.localizedString("journal.note.title")).font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $note)
                            .font(.system(size: 12))
                            .accessibilityLabel(PulseLocalization.localizedString("journal.note.title"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 55, maxHeight: 85)
                            .padding(5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }

                    HStack {
                        Text(PulseLocalization.localizedString("journal.followedPlan.title")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Picker(PulseLocalization.localizedString("journal.followedPlan.title"), selection: $followedPlan) {
                            ForEach(PlanChoice.allCases) { choice in
                                Text(choice.title).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(PulseLocalization.localizedString("journal.strategy.title")).font(.system(size: 12, weight: .semibold))
                        HStack {
                            TextField(PulseLocalization.localizedString("journal.strategy.placeholder"), text: $strategy)
                                .textFieldStyle(.roundedBorder)
                            Menu(PulseLocalization.localizedString("journal.strategy.presets")) {
                                ForEach(Self.strategyPresets, id: \.self) { label in
                                    Button(Self.strategyPresetTitle(label)) { strategy = label }
                                }
                            }.fixedSize()
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(PulseLocalization.localizedString("journal.retrospective.title")).font(.system(size: 12, weight: .semibold))
                        TextEditor(text: $retrospective)
                            .font(.system(size: 12))
                            .accessibilityLabel(PulseLocalization.localizedString("journal.retrospective.title"))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90, maxHeight: 220)
                            .padding(5)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(PulseLocalization.localizedString("journal.checkpoint.schedule"), isOn: $schedulesReview).toggleStyle(.checkbox)
                        if schedulesReview {
                            DatePicker(PulseLocalization.localizedString("journal.checkpoint.date"), selection: $nextReviewDate, displayedComponents: .date)
                        }
                        TextField(PulseLocalization.localizedString("journal.checkpoint.notePlaceholder"), text: $nextReviewNote, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...3)
                    }

                    HStack {
                        if saved {
                            Label(PulseLocalization.localizedString("journal.saved"), systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(PulseLocalization.localizedString("journal.save"), action: saveReview)
                            .buttonStyle(.borderedProminent)
                            .disabled(nextReviewNote.count > 4_000)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView(PulseLocalization.localizedString("journal.empty.selection"), systemImage: "text.book.closed")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailLine(_ title: String, _ value: String) -> some View {        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, design: .monospaced))
            Spacer()
        }
        .font(.system(size: 11))
    }

    /// The preset menu offers localized labels; picking one still writes the
    /// original preset text into the stored review, so existing records and the
    /// strategy summary keep reading the same values.
    private static let strategyPresets = ["突破", "回踩", "做 T", "趋势", "事件"]

    private static func strategyPresetTitle(_ preset: String) -> String {
        let keys = ["突破": "journal.strategy.breakout", "回踩": "journal.strategy.pullback",
                    "做 T": "journal.strategy.intraday", "趋势": "journal.strategy.trend",
                    "事件": "journal.strategy.event"]
        return keys[preset].map { PulseLocalization.localizedString($0) } ?? preset
    }

    // MARK: - Execution deviation

    /// Two facts, stated as facts: how this fill's own price compared with the
    /// plan's, in money sized by the quantity actually filled, and how far the
    /// live plan has since moved from its earliest recorded configuration.
    ///
    /// The card deliberately stops there. It does not call the difference a
    /// gain or a loss — a buy below its plan price has realized nothing until
    /// the position is sold — and it does not speculate about why the user
    /// paid up. A partial fill is a size fact, not a discipline failure, so
    /// the fill's quantity is never compared against the planned quantity
    /// here. The plan card above already shows both numbers.
    @ViewBuilder private var executionDeviationCard: some View {
        let entry = selectedEntry
        VStack(alignment: .leading, spacing: 5) {
            Text(PulseLocalization.localizedString("journal.deviation.title")).font(.system(size: 12, weight: .semibold))
            if let entry {
                deviationLine(
                    context: planContext,
                    transaction: entry.transaction,
                    currency: entry.item.symbol.currencyCode
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func deviationLine(
        context: PlanContext?,
        transaction: PositionTransaction,
        currency: String?
    ) -> some View {
        if let context, let deviation = context.deviation(for: transaction) {
            let money = PriceFormatter.money(deviation.amount, currencyCode: currency)
            let key = deviation.isFavourable
                ? (context.kind == .buy ? "journal.deviation.buyLower" : "journal.deviation.sellHigher")
                : (context.kind == .buy ? "journal.deviation.buyHigher" : "journal.deviation.sellLower")
            HStack(alignment: .firstTextBaseline) {
                Text(PulseLocalization.localizedString(key)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(money)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(appState.palette.color(isUp: deviation.isFavourable))
            }
            .font(.system(size: 11))
            Text(PulseLocalization.localizedString("journal.deviation.amountNote"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let context {
            Text(PulseLocalization.localizedString("journal.deviation.equal"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(PulseLocalization.localizedString(
                "journal.deviation.basis",
                PulseLocalization.localizedString(context.isSnapshot ? "journal.deviation.basis.snapshot" : "journal.deviation.basis.current")
            ))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        } else {
            Text(PulseLocalization.localizedString("journal.deviation.noPlan"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let context, !context.isSnapshot {
            Text(context.revisionCount > 0
                ? PulseLocalization.localizedString("journal.deviation.revised", context.revisionCount)
                : PulseLocalization.localizedString("journal.deviation.unrevised"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clearDraftFields() {
        note = ""
        followedPlan = .unset
        retrospective = ""
        strategy = ""
        schedulesReview = false
        nextReviewDate = .now
        nextReviewNote = ""
        saveError = false
    }

    private func loadDraft() {
        guard let entry = selectedEntry else {
            frozenAccount = nil
            return
        }
        // The entry's own ledger, never the global selection: the id alone does
        // not say which account the draft was opened from.
        frozenAccount = entry.accountID
        note = entry.transaction.note ?? ""
        followedPlan = PlanChoice(entry.transaction.review?.followedPlan)
        retrospective = entry.transaction.review?.retrospective ?? ""
        strategy = entry.transaction.review?.strategy ?? ""
        schedulesReview = entry.transaction.review?.nextReviewDate != nil
        nextReviewDate = entry.transaction.review?.nextReviewDate ?? .now
        nextReviewNote = entry.transaction.review?.nextReviewNote ?? ""
        saved = false
    }

    private func checkpointDue(_ transaction: PositionTransaction) -> Bool {
        guard let date = transaction.review?.nextReviewDate else { return false }
        return Calendar.current.startOfDay(for: date) <= Calendar.current.startOfDay(for: .now)
    }

    private func openReview(_ id: UUID?) {
        guard let id, let entry = resolveEntry(transactionID: id) else { return }
        query = ""
        selectedMonth = nil
        reviewScope = .all
        // The target must be inside the local scope, or the selection would be
        // matched against a list that cannot show it. Narrow to the resolved
        // owner's own ledger: `.all` would also satisfy visibility, but it
        // would silently discard a filter the user had set.
        accountScope = .account(entry.accountID)
        selection = entry.id
        loadDraft()
        // The id resolved, so the retry budget is unspent again for the next one.
        pendingResolutionAttempts = 0
        // Cleared only once the selection actually took.
        if appState.pendingJournalTransactionID == id { appState.pendingJournalTransactionID = nil }
    }

    // MARK: - Review persistence

    private static func nonemptyText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The transaction as the given ledger currently stores it, in the two
    /// places the store can hold it. Nil when the record is not there at all.
    private func persistedTransaction(
        symbol: SymbolID,
        id: UUID,
        owner: BrokerageAccountID
    ) -> PositionTransaction? {
        let portfolio = appState.watchlist.brokeragePortfolio(for: owner)
        for item in portfolio.items + portfolio.retainedHistoryItems where item.symbol == symbol {
            if let transaction = item.transactions.first(where: { $0.id == id }) {
                return transaction
            }
        }
        return nil
    }

    private func saveReview() {
        // 1. The draft, the frozen owner and the open selection must all still
        //    agree before anything is written.
        guard let entry = selectedEntry, let owner = frozenAccount,
              entry.accountID == owner, entry.id == selection else {
            saveError = true
            return
        }
        // 2. The record must still exist in the exact owner's ledger, whatever
        //    the global selection has since become. A missing record is never
        //    reported as saved.
        guard persistedTransaction(
            symbol: entry.item.symbol,
            id: entry.transaction.id,
            owner: owner
        ) != nil else {
            saveError = true
            return
        }
        let review: PositionTransactionReview?
        do {
            review = try PositionTransactionReview(
                followedPlan: followedPlan.value, retrospective: retrospective, strategy: strategy,
                nextReviewDate: schedulesReview ? Calendar.current.startOfDay(for: nextReviewDate) : nil,
                nextReviewNote: nextReviewNote
            ).normalizedForPersistence()
        } catch {
            saveError = true
            return
        }
        let normalizedNote = Self.nonemptyText(note)

        guard appState.watchlist.brokerageAccountsEnabled || owner == .unassigned else {
            saveError = true
            return
        }
        let accepted = appState.watchlist.withBrokerageAccount(owner) {
            appState.watchlist.updateTransactionReview(
                entry.item.symbol, id: entry.transaction.id, note: normalizedNote, review: review
            )
        }

        // 4. Re-read after the call. `false` is ambiguous — the record was
        //    missing, or the write was a no-op because the stored values
        //    already match — so only the persisted state decides.
        let persisted = persistedTransaction(
            symbol: entry.item.symbol,
            id: entry.transaction.id,
            owner: owner
        )
        let matchesDraft = persisted?.note == normalizedNote && persisted?.review == review
        if accepted || matchesDraft {
            saved = true
            saveError = false
        } else {
            saved = false
            saveError = true
        }
    }

    private func kindName(_ kind: PositionTransaction.Kind) -> String {
        switch kind {
        case .buy: PulseLocalization.localizedString("journal.kind.buy")
        case .sell: PulseLocalization.localizedString("journal.kind.sell")
        case .adjustment: PulseLocalization.localizedString("journal.kind.adjustment")
        }
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: date)
    }
}

extension TradePlanCondition {
    /// The state in the language the rest of this page is written in. Local to
    /// the journal so the two-word vocabulary stays with the surface that
    /// shows it.
    var stateTitle: String {
        PulseLocalization.localizedString("journal.condition.state.\(state.rawValue)")
    }
}
