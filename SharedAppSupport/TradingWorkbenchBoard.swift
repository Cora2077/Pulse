import Foundation
import PulseCore
import PulseUI

// Extracted without changing Mac behavior. Both targets compile the exact same
// task grouping, quote-health gates, capital/risk/sector projection and wording.
// MARK: - Board derivation

/// One immutable pass over the store for a single render. Keeping the maths in a
/// plain value type (rather than the view body) is what lets the DEBUG self-test
/// call the same grouping without a window, and keeps every count derived from
/// one snapshot instead of drifting between subviews.
struct WorkbenchBoard {
    struct CashNote: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    let tasks: [WorkbenchTask]
    let cashNotes: [CashNote]
    let capitals: [WorkbenchCapital]
    let defenses: [WorkbenchDefense]
    let sectorRows: [WorkbenchSectorRow]
    let reachedSymbolCount: Int
    let plansToReviewCount: Int
    let todayReviewCount: Int
    let historyBacklog: (count: Int, detail: String)?
    let unvaluableCount: Int
    /// Positions whose pool split still needs reconciling. Their pool rows are
    /// a floor, never a verified breakdown.
    let reconciliationCount: Int
    /// Currencies that contain at least one holding with no usable quote. Their
    /// percentages are "priced part only" and no over-limit flag is definitive.
    let sectorMissingQuoteCount: Int
    let phaseNote: String

    private let summaries: [SymbolID: WorkbenchSymbolSummary]

    func summary(for symbol: SymbolID) -> WorkbenchSymbolSummary? { summaries[symbol] }

    /// `entries` is filtered here as well as by the caller: a board built with
    /// an unfiltered list must still never count another market's plan, so the
    /// scope is enforced defensively against the symbols actually present.
    init(now: Date, phase: WorkbenchPhase, items: [WatchItem], historyItems: [WatchItem],
         entries: [TradePlanEntry], events: [TradingEventEntry],
         quote: (SymbolID) -> Quote?, name: (SymbolID) -> String,
         cash: WorkbenchCashInput, sectorLimits: [String: Double] = [:]) {
        let calendar = EastmoneyTradingEvents.dateCalendar
        let today = calendar.startOfDay(for: now)
        // An inclusive seven-day window with a lower bound. Without the floor a
        // past event would read as "approaching" forever.
        let horizon = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        // Ongoing events stay in the window only while they still cover today.
        func isInWindow(_ event: InstrumentEvent) -> Bool {
            let end = event.endDate ?? event.date
            return calendar.startOfDay(for: end) >= today && calendar.startOfDay(for: event.date) <= horizon
        }
        let scopedSymbols = Set(items.map(\.symbol))
        let active = entries.filter {
            $0.plan.status == .active && $0.remainingQuantity > 0 && scopedSymbols.contains($0.symbol)
        }

        // A quote that is stale, closed, or absent is not an intraday signal. It
        // is still readable as a reference, and it never counts as "到价".
        func currentPrice(_ symbol: SymbolID) -> Double? {
            quote(symbol).flatMap { TradingQuoteHealth.isCurrent($0, now: now) ? $0.price : nil }
        }

        // MARK: Reviews. "Today" is the local recorded date, per symbol.
        //
        // `historyItems` includes instruments retained in history that are no
        // longer on the watchlist, so a backlog survives removing the symbol.
        // Records dated in the future are neither today's nor a backlog: they
        // are not something to chase.

        var todayReviewBySymbol: [SymbolID: [UUID]] = [:]
        var backlog = 0
        var backlogIsFutureFree = true
        for item in historyItems {
            for transaction in item.transactions where transaction.kind != .adjustment {
                guard Self.needsReview(transaction) else { continue }
                switch WorkbenchBoard.recordedDayRelation(transaction.date, now: now) {
                case .today:
                    todayReviewBySymbol[item.symbol, default: []].append(transaction.id)
                case .earlier:
                    backlog += 1
                case .future:
                    backlogIsFutureFree = false
                }
            }
        }
        let todayReviewCount = todayReviewBySymbol.values.reduce(0) { $0 + $1.count }
        self.todayReviewCount = todayReviewCount
        self.historyBacklog = backlog > 0
            ? (backlog, PulseLocalization.localizedString(
                backlogIsFutureFree ? "workbench.backlog.detail" : "workbench.backlog.detailFuture"))
            : nil

        // MARK: Tasks, grouped by symbol
        //
        // One row per symbol, but every plan keeps its own row inside it — one
        // plan's identity, price, condition count and actions are never merged
        // into another's. `reachedSymbolCount` counts symbols (unit: 标的) while
        // `plansToReviewCount` counts plans (unit: 条), which is why they are
        // accumulated separately here rather than derived from the task rows.

        var reachedSymbols = Set<SymbolID>()
        var reviewPlans = 0
        var plansBySymbol: [SymbolID: [WorkbenchTask.PlanRow]] = [:]
        var reasonsBySymbol: [SymbolID: [String]] = [:]
        var reachedBySymbol: [SymbolID: Bool] = [:]
        var conditionsBySymbol: [SymbolID: Int] = [:]
        var windowEventCounts: [SymbolID: Int] = [:]
        var windowEventsBySymbol: [SymbolID: [TradingEventEntry]] = [:]
        for entry in events where isInWindow(entry.event) {
            windowEventCounts[entry.symbol, default: 0] += 1
            windowEventsBySymbol[entry.symbol, default: []].append(entry)
        }
        // Counts and summaries read the live events of the symbol itself, so a
        // condition's linked event can be checked against what actually happened.
        // History items are searched too: a symbol can be off the watchlist and
        // still carry plans whose linked events must resolve.
        let liveEventsBySymbol = Dictionary(
            (items + historyItems).map { ($0.symbol, $0.events) },
            uniquingKeysWith: { first, _ in first })
        func liveEvents(_ symbol: SymbolID) -> [InstrumentEvent] {
            (liveEventsBySymbol[symbol] ?? []) + events.filter { $0.symbol == symbol }.map(\.event)
        }
        for entry in active {
            let price = currentPrice(entry.symbol)
            let reached = price.map { entry.plan.isReached(at: $0) } ?? false
            let conditions = WorkbenchBoard.conditionsToReview(
                entry, now: now, currentEvents: liveEvents(entry.symbol))
            let hasEvent = windowEventCounts[entry.symbol] ?? 0 > 0
            guard reached || conditions > 0 || hasEvent else { continue }
            if reached {
                reachedSymbols.insert(entry.symbol)
                reasonsBySymbol[entry.symbol, default: []].append(PulseLocalization.localizedString("workbench.reason.atPrice"))
            }
            if conditions > 0 {
                reviewPlans += 1
                reasonsBySymbol[entry.symbol, default: []].append(
                    PulseLocalization.localizedString("workbench.reason.conditionsToReview", conditions))
            }
            reachedBySymbol[entry.symbol] = (reachedBySymbol[entry.symbol] ?? false) || reached
            conditionsBySymbol[entry.symbol, default: 0] += conditions
            plansBySymbol[entry.symbol, default: []].append(WorkbenchTask.PlanRow(
                id: entry.id,
                detail: WorkbenchBoard.planSummary(entry, price: price, conditions: conditions),
                entry: entry
            ))
        }
        // A symbol that only has an approaching event, with no active plan, still
        // needs a row: the event is the reason.
        for symbol in windowEventCounts.keys
        where plansBySymbol[symbol] == nil && items.contains(where: { $0.symbol == symbol }) {
            reasonsBySymbol[symbol] = [PulseLocalization.localizedString("workbench.reason.eventApproaching")]
        }
        var verificationsBySymbol: [SymbolID: [WorkbenchTask.VerificationRow]] = [:]
        for item in items where item.positionQuantity > 0 && !item.positionAllocationNeedsReconciliation {
            for portion in item.positionAllocation?.portions ?? [] where portion.quantity > 0 {
                let conditions = (portion.conditions ?? []).filter {
                    $0.requiresReview(at: now, currentEvents: liveEvents(item.symbol))
                }
                guard !conditions.isEmpty else { continue }
                let stage = conditions.contains { $0.state == .invalidated }
                    ? PulseLocalization.localizedString("workbench.verification.invalidated")
                    : conditions.contains { $0.state == .needsReview || $0.state == .confirmed }
                        ? PulseLocalization.localizedString("workbench.verification.needsReview")
                        : PulseLocalization.localizedString("workbench.verification.pending")
                reasonsBySymbol[item.symbol, default: []].append(stage)
                verificationsBySymbol[item.symbol, default: []].append(.init(id: portion.id,
                    title: PulseLocalization.localizedString("workbench.verification.shares", portion.pool.effectivePurpose.title,
                                 PriceFormatter.quantity(portion.quantity)),
                    detail: stage + " · " + conditions.map(\.title).joined(
                        separator: PulseLocalization.localizedString("workbench.verification.conditionSeparator"))))            }
        }
        var tasks = Set(plansBySymbol.keys).union(reasonsBySymbol.keys).map { symbol in
            var reasons = reasonsBySymbol[symbol] ?? []
            if windowEventCounts[symbol] ?? 0 > 0 { reasons.append(PulseLocalization.localizedString("workbench.reason.eventApproaching")) }
            let reviewIDs = todayReviewBySymbol[symbol] ?? []
            if reviewIDs.isEmpty == false { reasons.append(PulseLocalization.localizedString("workbench.reason.todayReview")) }
            return WorkbenchTask(
                symbol: symbol, name: name(symbol),
                reached: reachedBySymbol[symbol] ?? false,
                conditionCount: conditionsBySymbol[symbol] ?? 0,
                eventCount: windowEventCounts[symbol] ?? 0,
                reasons: WorkbenchBoard.deduplicated(reasons),
                plans: plansBySymbol[symbol] ?? [],
                reviewTransactionIDs: reviewIDs,
                dueReviewText: WorkbenchBoard.dueReviewText(
                    symbol, items: items + historyItems, today: Calendar.current.startOfDay(for: now), calendar: .current),
                verifications: verificationsBySymbol[symbol] ?? []
            )
        }
        for symbol in todayReviewBySymbol.keys where tasks.contains(where: { $0.symbol == symbol }) == false {
            tasks.append(WorkbenchTask(
                symbol: symbol, name: name(symbol),
                reached: false, conditionCount: 0, eventCount: 0,
                reasons: [PulseLocalization.localizedString("workbench.reason.todayReview")], plans: [],
                reviewTransactionIDs: todayReviewBySymbol[symbol] ?? [],
                dueReviewText: WorkbenchBoard.dueReviewText(
                    symbol, items: items + historyItems, today: Calendar.current.startOfDay(for: now), calendar: .current)
            ))
        }
        let reviewItems = Dictionary((items + historyItems).map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
        let recordedToday = Calendar.current.startOfDay(for: now)
        for item in reviewItems.values {
            let due = item.transactions.filter {
                $0.kind != .adjustment && $0.review?.nextReviewDate.map {
                    Calendar.current.startOfDay(for: $0) <= recordedToday
                } == true
            }.sorted { ($0.review?.nextReviewDate ?? .distantFuture) < ($1.review?.nextReviewDate ?? .distantFuture) }
            guard let checkpoint = due.first else { continue }
            if let index = tasks.firstIndex(where: { $0.symbol == item.symbol }) {
                tasks[index].checkpointID = checkpoint.id
            } else {
                tasks.append(.init(symbol: item.symbol, name: name(item.symbol), reached: false,
                    conditionCount: 0, eventCount: 0, reasons: [PulseLocalization.localizedString("workbench.reason.checkpointDue")], plans: [],
                    reviewTransactionIDs: [], dueReviewText: Self.dueReviewText(item.symbol,
                        items: [item], today: recordedToday, calendar: .current), checkpointID: checkpoint.id))
            }
        }
        tasks = WorkbenchBoard.order(tasks, phase: phase)
        self.tasks = tasks
        self.reachedSymbolCount = reachedSymbols.count
        self.plansToReviewCount = reviewPlans

        // MARK: Cash buy-budget notes, per currency

        var cashNotes: [CashNote] = []
        let buyGroups = Dictionary(grouping: active.filter { $0.plan.kind == .buy }, by: { $0.symbol.currencyCode })
        for currency in buyGroups.keys.sorted() {
            let amount = (buyGroups[currency] ?? []).reduce(0) { $0 + $1.remainingEstimatedAmount }
            guard amount.isFinite else {
                cashNotes.append(CashNote(id: "\(currency)-invalid",
                                          title: PulseLocalization.localizedString("workbench.cash.planBudgetInvalid", currency),
                                          detail: PulseLocalization.localizedString("workbench.cash.planBudgetInvalidDetail")))
                continue
            }
            let balance = cash.balance(currency: currency)
            if balance == nil {
                cashNotes.append(CashNote(id: "\(currency)-missing",
                                          title: PulseLocalization.localizedString("workbench.cash.recordBalance", currency),
                                          detail: PulseLocalization.localizedString("workbench.cash.toBuy",
                                                     PriceFormatter.money(amount, currencyCode: currency))))
            } else if let balance, amount > balance {
                cashNotes.append(CashNote(id: "\(currency)-gap", title: PulseLocalization.localizedString("workbench.cash.budgetGap", currency),
                                          detail: PriceFormatter.money(amount - balance, currencyCode: currency)))
            }
        }
        self.cashNotes = cashNotes

        // MARK: Capital, risk, sectors

        let projection = PoolBudgetProjection.calculate(
            positions: items.map { item in
                .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                      price: quote(item.symbol).flatMap { WorkbenchBoard.usablePrice($0.price) },
                      currencyCode: item.symbol.currencyCode,
                      sector: item.tradingProfile?.sector,
                      poolQuantities: WorkbenchBoard.poolQuantities(for: item),
                      portions: item.positionAllocationNeedsReconciliation ? [] : (item.positionAllocation?.portions ?? []))
            },
            entries: active,
            cash: cash.balances,
            cashUpdatedAt: cash.updatedAt,
            poolLimits: cash.limits
        )
        self.capitals = projection.currencies.map {
            WorkbenchCapital($0, reconciliationSymbols: Set(projection.unresolvedPoolPositions))
        }
        self.unvaluableCount = projection.unvaluablePriceCount
        self.reconciliationCount = projection.unresolvedPoolPositions.count

        self.defenses = WorkbenchBoard.defenses(items: items, quote: quote, now: now, name: name)

        let allocation = PortfolioAllocation.calculate(positions: items.map { item in
            .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                  price: quote(item.symbol).flatMap { WorkbenchBoard.usablePrice($0.price) },
                  currencyCode: item.symbol.currencyCode, supportsPosition: item.supportsPosition)
        })
        let exposure = SectorExposure.make(allocation: allocation, sectors: Dictionary(uniqueKeysWithValues:
            items.map { ($0.symbol, $0.tradingProfile?.sector ?? "") }))
        // A currency with any unvaluable holding can only be read as a floor, so
        // its over-limit flags are suppressed rather than asserted.
        var incompleteCurrencies = Set<String>()
        for item in items {
            guard item.positionQuantity != 0 else { continue }
            guard quote(item.symbol).flatMap({ WorkbenchBoard.usablePrice($0.price) }) == nil else { continue }
            incompleteCurrencies.insert(item.symbol.currencyCode)
        }
        self.sectorMissingQuoteCount = incompleteCurrencies.count
        self.sectorRows = Array(exposure.prefix(6)).map {
            WorkbenchSectorRow($0, limits: sectorLimits, isPricedPartOnly: incompleteCurrencies.contains($0.currencyCode))
        }

        self.phaseNote = WorkbenchBoard.phaseNote(phase: phase,
                                                  reached: reachedSymbols.count, backlog: backlog)

        // MARK: Per-symbol summaries
        //
        // Every scoped symbol gets one, not only the symbols that became tasks:
        // the risk row can select a symbol that has no task, and an empty panel
        // there would read as a missing instrument rather than a quiet one.

        var summaries: [SymbolID: WorkbenchSymbolSummary] = [:]
        for symbol in scopedSymbols.union(historyItems.map(\.symbol)) {
            summaries[symbol] = WorkbenchBoard.summary(
                symbol: symbol, name: name(symbol), quote: quote(symbol), now: now,
                entries: active.filter { $0.symbol == symbol },
                events: (windowEventsBySymbol[symbol] ?? []).sorted { $0.event.date < $1.event.date },
                liveEvents: liveEvents(symbol),
                pendingJournalTransactionID: todayReviewBySymbol[symbol]?.first
            )
        }
        self.summaries = summaries
    }

    static func needsReview(_ transaction: PositionTransaction) -> Bool {
        transaction.review?.retrospective?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    // MARK: Pure helpers (shared with the self-test)

    /// The market's own calendar day for an instant. This is a *reference
    /// clock* for quotes and events only — never for attributing a recorded
    /// fill, whose date is a user-entered local civil day.
    static func marketReferenceDay(for market: Market, at date: Date) -> CalendarDay {
        TradingCalendar.tradingDay(of: market, at: date)
    }

    enum RecordedDayRelation {
        case today
        case earlier
        case future
    }

    /// Which side of "today" a transaction's *recorded* date falls on, read in
    /// the machine's own calendar. Deliberately not in the exchange's time
    /// zone: `PositionTransaction.date` is stored as the user's local civil
    /// date (the entry form writes local midnight), so reinterpreting it in a
    /// market time zone would move a US record to another day. A future-dated
    /// record is neither today's work nor a backlog.
    static func recordedDayRelation(_ date: Date, now: Date, calendar: Calendar = .current) -> RecordedDayRelation {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return .today }
        return day < today ? .earlier : .future
    }

    /// Whether a transaction lands on today's recorded local day. Kept as the
    /// single definition so the "today" count and the per-symbol review tasks
    /// can never disagree.
    static func isOnRecordedDay(_ transaction: PositionTransaction, now: Date,
                                calendar: Calendar = .current) -> Bool {
        recordedDayRelation(transaction.date, now: now, calendar: calendar) == .today
    }

    /// The nearest forward-looking review checkpoint recorded on this symbol's
    /// fills, stated once per symbol. Independent of the retrospective backlog
    /// above: a checkpoint is a note to the future ("check this again on …"),
    /// and a fill can have one, the other, or both.
    static func dueReviewText(_ symbol: SymbolID, items: [WatchItem], today: Date,
                              calendar: Calendar) -> String? {
        guard let item = items.first(where: { $0.symbol == symbol }) else { return nil }
        var due: [(days: Int, note: String?)] = []
        for transaction in item.transactions {
            guard let review = transaction.review,
                  // A note without a date is still a checkpoint worth surfacing
                  // in the journal, but it has no day, so it can never be due.
                  let date = review.nextReviewDate else { continue }
            let note = review.nextReviewNote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
            guard days <= 0 else { continue }
            due.append((days, note))
        }
        // The nearest checkpoint wins; a date with no note is still a due
        // checkpoint, so its absence must not discard the row.
        guard let nearest = due.map(\.days).min() else { return nil }
        let note = due.first(where: { $0.days == nearest })?.note
        let when = nearest == 0
            ? PulseLocalization.localizedString("workbench.review.today")
            : PulseLocalization.localizedString("workbench.review.overdue", -nearest)
        let checkpoint = PulseLocalization.localizedString("workbench.review.checkpoint", when)
        guard let note, note.isEmpty == false else { return checkpoint }
        return PulseLocalization.localizedString("workbench.review.checkpointWithNote", checkpoint, note)
    }

    /// Condition states are preserved exactly as stored; this only counts what
    /// still needs the user's attention. The linked-event reading is delegated
    /// to core so a missing or materially changed event triggers the same
    /// pending check everywhere it is derived.
    static func conditionsToReview(_ entry: TradePlanEntry, now: Date,
                                   currentEvents: [InstrumentEvent] = []) -> Int {
        (entry.plan.conditions ?? []).filter {
            $0.requiresReview(at: now, currentEvents: currentEvents)
        }.count
    }

    /// Reasons are collected from independent signals, so the same phrase can
    /// arrive twice for one symbol; it is printed once.
    static func deduplicated(_ reasons: [String]) -> [String] {
        var seen = Set<String>()
        return reasons.filter { seen.insert($0).inserted }
    }

    static func planSummary(_ entry: TradePlanEntry, price: Double?, conditions: Int) -> String {
        let side = entry.plan.kind == .buy
            ? PulseLocalization.localizedString("plan.kind.buy")
            : PulseLocalization.localizedString("plan.kind.sell")
        var parts = [PulseLocalization.localizedString("workbench.plan.summary", side,
                        PriceFormatter.price(entry.plan.price, market: entry.symbol.market),
                        PriceFormatter.quantity(entry.remainingQuantity))]
        if let price {
            parts.append(entry.plan.isReached(at: price)
                ? PulseLocalization.localizedString("workbench.plan.reached")
                : PulseLocalization.localizedString("workbench.plan.gapToTrigger", entry.plan.gapPercent(from: price)))
        } else {
            // Covers both a missing quote and a closed/stale one: neither is an
            // intraday signal, so neither may read as "waiting at a distance".
            parts.append(PulseLocalization.localizedString("workbench.plan.noIntraday"))
        }
        if conditions > 0 { parts.append(PulseLocalization.localizedString("workbench.plan.conditionsToReview", conditions)) }
        if entry.filledQuantity > 0 {
            parts.append(PulseLocalization.localizedString("workbench.plan.filled", PriceFormatter.quantity(entry.filledQuantity)))
        }
        return parts.joined(separator: " · ")
    }

    /// Identity for a plan row without leaking a raw UUID at the user. The
    /// kind, price, size, pool and note tell two plans apart; the id is only a
    /// fallback for two otherwise identical rows.
    static func planIdentity(_ entry: TradePlanEntry) -> String {
        let side = entry.plan.kind == .buy
            ? PulseLocalization.localizedString("plan.kind.buy")
            : PulseLocalization.localizedString("plan.kind.sell")
        var parts = [PulseLocalization.localizedString("workbench.plan.summary", side,
                        PriceFormatter.price(entry.plan.price, market: entry.symbol.market),
                        PriceFormatter.quantity(entry.plan.quantity))]
        if let pool = entry.plan.positionPool { parts.append(pool.title) }
        if let note = entry.plan.note?.trimmingCharacters(in: .whitespacesAndNewlines), note.isEmpty == false {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// Phase changes ordering and emphasis only. The set of tasks, every count
    /// and every number stays exactly the same. The final tiebreak is the symbol
    /// itself, not the display name: two instruments can share a name, and a set
    /// iteration order that leaks into the list would reshuffle rows between
    /// refreshes.
    static func order(_ tasks: [WorkbenchTask], phase: WorkbenchPhase) -> [WorkbenchTask] {
        func tiebreak(_ lhs: WorkbenchTask, _ rhs: WorkbenchTask) -> Bool {
            lhs.name == rhs.name ? lhs.symbol.description < rhs.symbol.description : lhs.name < rhs.name
        }
        func reviewPriority(_ lhs: WorkbenchTask, _ rhs: WorkbenchTask) -> Bool? {
            let left = lhs.reviewCount ?? 0 > 0 || lhs.checkpointID != nil || !lhs.verifications.isEmpty
            let right = rhs.reviewCount ?? 0 > 0 || rhs.checkpointID != nil || !rhs.verifications.isEmpty
            guard left != right else { return nil }
            return left
        }
        switch phase {
        case .preMarket:
            return tasks.sorted { lhs, rhs in
                if (lhs.eventCount > 0) != (rhs.eventCount > 0) { return lhs.eventCount > 0 }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if lhs.reached != rhs.reached { return !lhs.reached }
                return tiebreak(lhs, rhs)
            }
        case .intraday:
            return tasks.sorted { lhs, rhs in
                if lhs.reached != rhs.reached { return lhs.reached }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if let review = reviewPriority(lhs, rhs) { return review }
                return tiebreak(lhs, rhs)
            }
        case .postMarket:
            return tasks.sorted { lhs, rhs in
                if let review = reviewPriority(lhs, rhs) { return review }
                if (lhs.conditionCount > 0) != (rhs.conditionCount > 0) { return lhs.conditionCount > 0 }
                if lhs.reached != rhs.reached { return lhs.reached }
                return tiebreak(lhs, rhs)
            }
        }
    }

    static func phaseNote(phase: WorkbenchPhase, reached: Int, backlog: Int) -> String {
        switch phase {
        case .preMarket:
            return PulseLocalization.localizedString("workbench.phaseNote.preMarket")
        case .intraday:
            return reached > 0
                ? PulseLocalization.localizedString("workbench.phaseNote.intradayReached")
                : PulseLocalization.localizedString("workbench.phaseNote.intradayQuiet")
        case .postMarket:
            return backlog > 0
                ? PulseLocalization.localizedString("workbench.phaseNote.postMarketBacklog")
                : PulseLocalization.localizedString("workbench.phaseNote.postMarket")
        }
    }

    static func summary(symbol: SymbolID, name: String, quote: Quote?, now: Date,
                        entries: [TradePlanEntry], events: [TradingEventEntry],
                        liveEvents: [InstrumentEvent] = [],
                        pendingJournalTransactionID: UUID? = nil) -> WorkbenchSymbolSummary {
        let isCurrent = quote.map { TradingQuoteHealth.isCurrent($0, now: now) } ?? false
        let price = quote.flatMap { usablePrice($0.price) }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = symbol.market.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        let quoteText: String
        if let price {
            quoteText = "\(PriceFormatter.price(price, market: symbol.market)) \(symbol.currencyCode)"
        } else {
            quoteText = PulseLocalization.localizedString("workbench.quote.unavailable")
        }
        let statusText = isCurrent
            ? PulseLocalization.localizedString("workbench.quote.statusCurrent")
            : (quote == nil ? PulseLocalization.localizedString("workbench.quote.statusMissing") : PulseLocalization.localizedString("workbench.quote.statusReference"))
        let timestampText = quote.map {
            PulseLocalization.localizedString("workbench.quote.timestamp", formatter.string(from: $0.timestamp),
               symbol.market.timeZoneDisplayName)
                + (isCurrent ? "" : PulseLocalization.localizedString("workbench.quote.referenceNotTrigger"))
        } ?? PulseLocalization.localizedString("workbench.quote.none")

        let planRows = entries.map { entry -> WorkbenchSymbolSummary.PlanRow in
            let conditions = conditionsToReview(entry, now: now, currentEvents: liveEvents)
            var detail = PulseLocalization.localizedString("workbench.plan.progress",
                            PriceFormatter.quantity(entry.filledQuantity),
                            PriceFormatter.quantity(entry.remainingQuantity))
            if conditions > 0 { detail += " · " + PulseLocalization.localizedString("workbench.plan.conditionsToReview", conditions) }
            return .init(id: entry.id, title: planIdentity(entry), detail: detail)
        }
        // Event dates are civil days in the calendar's zone, not quote instants.
        let eventFormatter = DateFormatter()
        eventFormatter.calendar = EastmoneyTradingEvents.dateCalendar
        eventFormatter.timeZone = EastmoneyTradingEvents.dateCalendar.timeZone
        eventFormatter.dateFormat = "MM-dd"
        let eventRows = events.map { entry -> WorkbenchDetailRow in
            let start = eventFormatter.string(from: entry.event.date)
            let period = entry.event.endDate.map { start + "–" + eventFormatter.string(from: $0) } ?? start
            return WorkbenchDetailRow(
                id: entry.id,
                title: "\(period) · \(entry.event.title)",
                detail: entry.isForecast ? PulseLocalization.localizedString("workbench.plan.eventForecast") : entry.sourceName
            )
        }
        return WorkbenchSymbolSummary(
            symbol: symbol, name: name, market: symbol.market,
            quoteText: quoteText, quoteStatusText: statusText, quoteTimestampText: timestampText,
            quoteIsCurrent: isCurrent, plans: planRows, events: eventRows,
            // "定位池" opens the pool board; a plan with no pool yet is the one
            // that needs placing, so it is preferred over an already-placed one.
            pendingPoolPlanID: entries.first { $0.plan.positionPool == nil }?.id ?? entries.first?.id,
            pendingJournalTransactionID: pendingJournalTransactionID
        )
    }

    static func defenses(items: [WatchItem], quote: (SymbolID) -> Quote?, now: Date,
                         name: (SymbolID) -> String) -> [WorkbenchDefense] {
        items.compactMap { item -> (WatchItem, Quote, Double)? in
            guard item.positionQuantity > 0, let stop = item.tradingProfile?.stopPrice,
                  let q = quote(item.symbol), usablePrice(q.price) != nil else { return nil }
            return (item, q, stop)
        }
        .sorted { lhs, rhs in
            let left = (lhs.1.price - lhs.2) / lhs.1.price
            let right = (rhs.1.price - rhs.2) / rhs.1.price
            return left < right
        }
        .prefix(5)
        .map { item, q, stop in
            let isCurrent = TradingQuoteHealth.isCurrent(q, now: now)
            let value = q.price <= stop
                ? PulseLocalization.localizedString("workbench.defense.belowStop")
                : PulseLocalization.localizedString("workbench.defense.distance", (q.price - stop) / q.price * 100)
            return WorkbenchDefense(
                symbol: item.symbol, name: name(item.symbol),
                detail: PulseLocalization.localizedString("workbench.defense.detail",
                            PriceFormatter.price(stop, market: item.symbol.market),
                            isCurrent ? PulseLocalization.localizedString("workbench.defense.currentQuote")
                                      : PulseLocalization.localizedString("workbench.defense.referenceQuote")),
                valueText: value, isWarning: isCurrent && q.price <= stop
            )
        }
    }

    static func usablePrice(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    /// Verified pool shares only. A position whose allocation has not been
    /// reconciled is reported with an empty split rather than a stale one: the
    /// projection then reports the shortfall, which is the honest answer, while
    /// showing the previously verified portion as if it were current would not.
    static func poolQuantities(for item: WatchItem) -> [PositionPool: Double] {
        guard !item.positionAllocationNeedsReconciliation else { return [:] }
        let portions = item.positionAllocation?.portions ?? []
        guard portions.isEmpty == false else { return [:] }
        var result: [PositionPool: Double] = [:]
        for portion in portions where portion.quantity.isFinite && portion.quantity > 0 {
            result[portion.pool, default: 0] += portion.quantity
        }
        return result
    }
}

// MARK: - Small derived value types

struct WorkbenchTask: Identifiable {
    struct PlanRow: Identifiable {
        let id: UUID
        let detail: String
        let entry: TradePlanEntry
    }
    struct VerificationRow: Identifiable {
        let id: UUID
        let title: String
        let detail: String
    }

    let symbol: SymbolID
    let name: String
    let reached: Bool
    let conditionCount: Int
    let eventCount: Int
    let reasons: [String]
    let plans: [PlanRow]
    /// Today's unreviewed fills for this symbol, aggregated before sorting so a
    /// three-fill day is one task, not three rows. The ids are kept so every
    /// underlying record stays reachable from the task.
    let reviewTransactionIDs: [UUID]
    /// A plan checkpoint that has come due, stated once per symbol.
    let dueReviewText: String?
    var checkpointID: UUID? = nil
    var verifications: [VerificationRow] = []

    var id: SymbolID { symbol }

    var reviewCount: Int? { reviewTransactionIDs.isEmpty ? nil : reviewTransactionIDs.count }

    var countText: String {
        var parts: [String] = []
        if plans.isEmpty == false { parts.append(PulseLocalization.localizedString("workbench.count.plans", plans.count)) }
        if eventCount > 0 { parts.append(PulseLocalization.localizedString("workbench.count.events", eventCount)) }
        if let reviewCount { parts.append(PulseLocalization.localizedString("workbench.count.reviews", reviewCount)) }
        if !verifications.isEmpty {
            parts.append(PulseLocalization.localizedString("workbench.count.verifications", verifications.count))
        }
        return parts.joined(separator: " · ")
    }
}

struct WorkbenchSymbolSummary {
    struct PlanRow: Identifiable {
        let id: UUID
        let title: String
        let detail: String
    }

    let symbol: SymbolID
    let name: String
    let market: Market
    let quoteText: String
    let quoteStatusText: String
    let quoteTimestampText: String
    let quoteIsCurrent: Bool
    let plans: [PlanRow]
    let events: [WorkbenchDetailRow]
    let pendingPoolPlanID: UUID?
    let pendingJournalTransactionID: UUID?
}

/// One label/value line in the selected-symbol panel, already formatted.
struct WorkbenchDetailRow: Identifiable {
    let id: String
    let title: String
    let detail: String
}

struct WorkbenchCapital: Identifiable {
    struct Segment {
        let pool: PositionPool
        let value: Double
    }

    let code: String
    let holdings: Double
    let cash: Double?
    let plannedBuy: Double
    let budgetGap: Double
    let hasOverflow: Bool
    let segments: [Segment]
    let trackScale: Double
    /// The projection could not price part of this currency's holdings.
    let hasMissingQuote: Bool
    /// At least one position in this currency still needs its pool split
    /// reconciled, so the pool rows below are a floor.
    let needsReconciliation: Bool

    var id: String { code }
    var cashIsKnown: Bool { cash != nil }
    var hasSegments: Bool { segments.contains { $0.value > 0 } }
    var segmentTotal: Double { segments.reduce(0) { $0 + $1.value } }
    var hasUnverified: Bool { needsReconciliation }

    /// Unknown cash is a word, never a zero. Zero is a real answer the user gave.
    /// The label names the account, because the recorded balance is global per
    /// currency and is deliberately not scoped to the selected market.
    var cashText: String {
        guard let cash else { return PulseLocalization.localizedString("workbench.cash.unrecorded") }
        return PulseLocalization.localizedString("workbench.cash.cash") + " "
            + PriceFormatter.money(cash, currencyCode: code)
    }

    /// A holdings figure that could not be fully priced says so in place: it is
    /// the priced part, not the position's value.
    var holdingsText: String {
        let money = PriceFormatter.money(holdings, currencyCode: code)
        return PulseLocalization.localizedString(hasMissingQuote ? "workbench.cash.holdingsPartial" : "workbench.cash.holdings",
                  money)
    }

    var missingQuoteText: String {
        PulseLocalization.localizedString("workbench.cash.missingQuoteNote")
    }

    var unverifiedText: String {
        PulseLocalization.localizedString("workbench.cash.unverifiedNote")
    }

    var segmentText: String {
        segments.filter { $0.value > 0 }
            .map { "\($0.pool.title) \(PriceFormatter.money($0.value, currencyCode: code))" }
            .joined(separator: " · ")
    }

    init(_ projection: PoolBudgetProjection.CurrencyProjection,
         reconciliationSymbols: Set<SymbolID> = []) {
        code = projection.code
        holdings = projection.holdingsBefore
        cash = projection.cashBalance
        plannedBuy = projection.plannedBuyAmount
        budgetGap = projection.purchaseBudgetGap
        hasOverflow = projection.hasOverflow
        hasMissingQuote = projection.unvaluableQuantity > 0
        needsReconciliation = reconciliationSymbols.isEmpty == false
            && projection.pools.contains { $0.needsReconciliation }
        let rows = projection.pools.map { Segment(pool: $0.pool, value: $0.heldAmount) }
            .filter { $0.value.isFinite && $0.value > 0 }
        segments = rows
        trackScale = max(rows.reduce(0) { $0 + $1.value }, projection.holdingsBefore)
    }
}

struct WorkbenchDefense: Identifiable {
    let symbol: SymbolID
    let name: String
    let detail: String
    let valueText: String
    let isWarning: Bool
    var id: SymbolID { symbol }
}

struct WorkbenchSectorRow: Identifiable {
    let name: String
    let currencyCode: String
    let percent: Double
    let overLimit: Bool
    /// The currency has unvaluable holdings, so the percentage is the priced
    /// part only and `overLimit` is suppressed rather than asserted.
    let hasMissingQuote: Bool
    var id: String { "\(currencyCode):\(name)" }

    init(_ exposure: SectorExposure, limits: [String: Double], isPricedPartOnly: Bool = false) {
        name = exposure.name
        currencyCode = exposure.currencyCode
        percent = exposure.percent
        hasMissingQuote = isPricedPartOnly
        overLimit = !isPricedPartOnly && (limits[exposure.id].map { exposure.percent > $0 } ?? false)
    }
}

// MARK: - Phase & scope

enum WorkbenchPhase: String, CaseIterable {
    case preMarket
    case intraday
    case postMarket

    var title: String {
        switch self {
        case .preMarket: PulseLocalization.localizedString("workbench.phase.preMarket")
        case .intraday: PulseLocalization.localizedString("workbench.phase.intraday")
        case .postMarket: PulseLocalization.localizedString("workbench.phase.postMarket")
        }
    }
}

/// The market scope. Real `Market` values only: a currency is not a market, and
/// a holiday calendar is not claimed here.
enum WorkbenchScope: String, CaseIterable {
    case all
    case chinaA
    case hongKong
    case unitedStates

    var title: String {
        switch self {
        case .all: PulseLocalization.localizedString("workbench.scope.all")
        case .chinaA: PulseLocalization.localizedString("workbench.scope.chinaA")
        case .hongKong: PulseLocalization.localizedString("workbench.scope.hongKong")
        case .unitedStates: PulseLocalization.localizedString("workbench.scope.unitedStates")
        }
    }

    var markets: [Market] {
        switch self {
        case .all: [.sh, .sz, .hk, .us]
        case .chinaA: [.sh, .sz]
        case .hongKong: [.hk]
        case .unitedStates: [.us]
        }
    }

    func contains(_ market: Market) -> Bool {
        switch self {
        case .all: true
        case .chinaA: market.isChinaA
        case .hongKong: market == .hk
        case .unitedStates: market == .us
        }
    }
}

// MARK: - Read-only bridge into existing settings

/// A plain snapshot of the user's recorded cash and pool limits, taken once per
/// render from `PoolBudgetSettings`. The projection wants dictionaries; this is
/// the only place they are read, and it is read-only — the workbench has no path
/// that could write a balance, a limit, or a scenario.
struct WorkbenchCashInput {
    var balances: [String: Double] = [:]
    var updatedAt: [String: Date] = [:]
    var limits: [String: [PositionPool: Double]] = [:]

    init() {}


    /// nil means unknown — the caller must render that, never a zero.
    func balance(currency: String) -> Double? {
        balances[currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()]
    }
}
