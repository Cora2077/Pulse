#if DEBUG
import Foundation
import PulseCore

/// DEBUG-only self-test for the trading workbench derivation.
///
/// It exercises `WorkbenchBoard` — the same value type the view renders — with
/// entirely synthetic watch items, plans, quotes, events, transactions, and a
/// disposable `WorkbenchCashInput`. Nothing here reads the developer's
/// defaults, keychain, quotes, watchlist, or account, and nothing writes to the
/// store: the board is a pure function of its inputs, so the fixtures below are
/// the whole world each check sees.
///
/// The checks are the ones that would otherwise be *silently* wrong on screen:
/// a plan from another market leaking into a count, a past event reading as
/// upcoming, a US fill saved at local midnight shifting a day, or an
/// unreconciled allocation rendering as a verified pool breakdown.
///
/// Callers: `WorkflowSelfTest` is expected to wire this in as
/// `WorkbenchSelfTest.run()`. It is `@MainActor` because `WorkbenchCashInput`
/// is, so it must be awaited/called from the main actor.
@MainActor
enum WorkbenchSelfTest {
    private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    // MARK: - Entry point

    static func run() -> Bool {
        failures = []
        marketScopeChecks()
        eventWindowChecks()
        recordedDateChecks()
        reviewTaskChecks()
        positionVerificationChecks()
        summaryCoverageChecks()
        allocationAndSectorChecks()
        planIdentityChecks()
        phaseOrderChecks()
        return failures.isEmpty
    }

    /// Names of the checks that failed, for a caller that wants to print them.
    static var failureReport: String { failures.joined(separator: "; ") }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_770_000_000)

    private static func day(_ offset: Int) -> Date {
        EastmoneyTradingEvents.dateCalendar.date(byAdding: .day, value: offset, to: now) ?? now
    }

    /// Local midnight on the calendar day `offset` days from today, which is
    /// exactly how the trade-entry form stores a user-entered date.
    private static func localMidnight(_ offset: Int, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offset, to: today) ?? today
    }

    private static func quote(_ symbol: SymbolID, price: Double, age: TimeInterval = 0) -> Quote {
        Quote(symbol: symbol, price: price, previousClose: price, timestamp: now.addingTimeInterval(-age))
    }

    private static func plan(
        _ symbol: SymbolID, kind: TradePlan.Kind = .buy, price: Double, quantity: Double,
        status: TradePlan.Status = .active, pool: PositionPool? = nil, note: String? = nil,
        conditions: [TradePlanCondition]? = nil
    ) -> TradePlan {
        TradePlan(kind: kind, price: price, quantity: quantity, status: status, note: note,
                  positionPool: pool, conditions: conditions)
    }

    private static func entry(_ symbol: SymbolID, _ plan: TradePlan,
                              transactions: [PositionTransaction] = []) -> TradePlanEntry {
        TradePlanEntry(symbol: symbol, plan: plan, transactions: transactions)
    }

    private static func eventEntry(_ symbol: SymbolID, _ event: InstrumentEvent) -> TradingEventEntry {
        TradingEventEntry(symbol: symbol, event: event, sourceName: "fixture",
                          isForecast: false, isAutomatic: false)
    }

    private static func board(
        items: [WatchItem], historyItems: [WatchItem] = [], entries: [TradePlanEntry],
        events: [TradingEventEntry] = [], quotes: [SymbolID: Quote] = [:],
        phase: WorkbenchPhase = .intraday, cash: WorkbenchCashInput = WorkbenchCashInput()
    ) -> WorkbenchBoard {
        WorkbenchBoard(
            now: now, phase: phase, items: items, historyItems: historyItems,
            entries: entries, events: events,
            quote: { quotes[$0] },
            name: { symbol in items.first { $0.symbol == symbol }?.resolvedDisplayName ?? symbol.displayCode },
            cash: cash, sectorLimits: [:]
        )
    }

    /// A transaction dated at local midnight, the shape the entry form writes.
    private static func transaction(
        _ id: UUID = UUID(), kind: PositionTransaction.Kind = .buy, price: Double = 10,
        quantity: Double = 1, localDayOffset: Int, reviewed: Bool = false,
        nextReviewDays: Int? = nil, nextReviewNote: String? = nil
    ) -> PositionTransaction {
        let review = (reviewed || nextReviewDays != nil || nextReviewNote != nil)
            ? PositionTransactionReview(
                followedPlan: nil,
                retrospective: reviewed ? "已复盘" : nil,
                strategy: nil,
                nextReviewDate: nextReviewDays.map { localMidnight($0) },
                nextReviewNote: nextReviewNote)
            : nil
        return PositionTransaction(
            id: id, kind: kind, price: price, quantity: quantity,
            date: localMidnight(localDayOffset), createdAt: localMidnight(localDayOffset),
            review: review)
    }

    // MARK: - Market scope

    /// Scope must filter plans, not only items, and the board must hold that
    /// line even when handed an unfiltered entry list.
    private static func marketScopeChecks() {
        let aShare = SymbolID(market: .sh, code: "600000")
        let usShare = SymbolID(market: .us, code: "AAPL")
        let cnItem = WatchItem(symbol: aShare, displayName: "浦发银行")
        let usItem = WatchItem(symbol: usShare, displayName: "Apple")
        let cnPlan = entry(aShare, plan(aShare, price: 8, quantity: 100))
        let usPlan = entry(usShare, plan(usShare, price: 200, quantity: 5))

        // Both plans are reached, so an unfiltered board would count two symbols.
        let scoped = board(
            items: [cnItem], entries: [cnPlan, usPlan],
            quotes: [aShare: quote(aShare, price: 7), usShare: quote(usShare, price: 100)])

        expect(scoped.tasks.count == 1, "scope: foreign-market plan produced a task")
        expect(scoped.tasks.first?.symbol == aShare, "scope: wrong symbol kept")
        expect(scoped.reachedSymbolCount == 1, "scope: reached count leaked another market")
        expect(scoped.plansToReviewCount == 0, "scope: plan-review count leaked another market")

        // A plan whose symbol is only in history is out of scope for tasks.
        let historyOnly = board(
            items: [], historyItems: [usItem], entries: [usPlan],
            quotes: [usShare: quote(usShare, price: 100)])
        expect(historyOnly.tasks.isEmpty, "scope: history-only symbol produced a task")
        expect(historyOnly.reachedSymbolCount == 0, "scope: history-only symbol counted as reached")
    }

    // MARK: - Event window

    /// The window is [today, today + 7], inclusive, and an ongoing event is
    /// included only while it still covers today.
    private static func eventWindowChecks() {
        let symbol = SymbolID(market: .us, code: "WINDOW")
        let item = WatchItem(symbol: symbol, displayName: "Window")

        func eventCount(_ event: InstrumentEvent) -> Int {
            board(items: [item], entries: [], events: [eventEntry(symbol, event)]).tasks.first?.eventCount ?? 0
        }

        // A past event is not upcoming, however recently it passed.
        let past = InstrumentEvent(kind: .earnings, date: day(-1), title: "Past")
        expect(eventCount(past) == 0, "events: past event counted as upcoming")
        expect(board(items: [item], entries: [], events: [eventEntry(symbol, past)]).tasks.isEmpty,
               "events: past event created a task")

        // Today and the horizon boundary are both inside.
        expect(eventCount(InstrumentEvent(kind: .earnings, date: day(0), title: "Today")) == 1,
               "events: today's event was excluded")
        expect(eventCount(InstrumentEvent(kind: .earnings, date: day(7), title: "Edge")) == 1,
               "events: horizon day was excluded")

        // One day past the horizon is outside.
        expect(eventCount(InstrumentEvent(kind: .earnings, date: day(8), title: "Beyond")) == 0,
               "events: event past the horizon was counted")

        // An ongoing event that started before today but runs through today is
        // still in the window; one that already ended is not.
        let ongoing = InstrumentEvent(kind: .other, date: day(-3), title: "Ongoing", endDate: day(2))
        expect(eventCount(ongoing) == 1, "events: ongoing event covering today was dropped")
        let closed = InstrumentEvent(kind: .other, date: day(-5), title: "Closed", endDate: day(-2))
        expect(eventCount(closed) == 0, "events: ended event still counted")
        let stale = InstrumentEvent(kind: .other, date: day(-9), title: "Stale", endDate: day(-8))
        expect(eventCount(stale) == 0, "events: stale range still counted")

        // Summaries use the same window as the counts.
        let summary = board(items: [item], entries: [], events: [eventEntry(symbol, ongoing)])
            .summary(for: symbol)
        expect(summary?.events.count == 1, "events: summary window disagreed with the task count")
    }

    // MARK: - Recorded dates (the critical one)

    /// `PositionTransaction.date` is a user-entered local civil date. A US
    /// record stored at local midnight must stay on that local day and must not
    /// be reinterpreted in the exchange's time zone.
    private static func recordedDateChecks() {
        let usShare = SymbolID(market: .us, code: "MSFT")

        // Stored local midnight, yesterday: an earlier recorded day.
        let stored = transaction(localDayOffset: -1)
        expect(WorkbenchBoard.recordedDayRelation(stored.date, now: now) == .earlier,
               "dates: stored local midnight was not read as an earlier local day")
        expect(WorkbenchBoard.isOnRecordedDay(stored, now: now) == false,
               "dates: yesterday's record counted as today")
        // The same instant is emphatically *not* judged in the market's zone.
        // A US symbol's reference day for a local-midnight instant is usually a
        // different calendar day, which is exactly why attribution never uses it.
        let marketDay = WorkbenchBoard.marketReferenceDay(for: usShare.market, at: stored.date)
        let localDay = CalendarDay(stored.date, in: .current)
        let shifted = marketDay != localDay
        expect(!shifted || WorkbenchBoard.recordedDayRelation(stored.date, now: now) != .today,
               "dates: the market reference clock was allowed to drive attribution")

        // Stored local midnight today: today's work.
        let todayRecord = transaction(localDayOffset: 0)
        expect(WorkbenchBoard.isOnRecordedDay(todayRecord, now: now),
               "dates: today's record was not counted as today")

        // A future-dated record is neither today's nor a backlog entry.
        let futureRecord = transaction(localDayOffset: 3)
        expect(WorkbenchBoard.recordedDayRelation(futureRecord.date, now: now) == .future,
               "dates: future record was not classified as future")

        // End to end: one earlier record is a backlog, one future record is
        // ignored, and neither becomes a today count.
        let historyItem = WatchItem(
            symbol: usShare, displayName: "Microsoft",
            transactions: [stored, todayRecord, futureRecord])
        let boardValue = board(items: [], historyItems: [historyItem], entries: [])
        expect(boardValue.todayReviewCount == 1, "dates: today's review count was wrong")
        expect(boardValue.historyBacklog?.count == 1, "dates: backlog counted today or the future")

        // A reviewed record is never counted again.
        let reviewed = WatchItem(
            symbol: usShare, displayName: "Microsoft",
            transactions: [transaction(localDayOffset: 0, reviewed: true)])
        expect(board(items: [], historyItems: [reviewed], entries: []).todayReviewCount == 0,
               "dates: an already-reviewed fill was counted as pending")
    }

    // MARK: - Review tasks

    /// Today's unreviewed fills are aggregated per symbol before sorting, and
    /// every underlying id stays reachable.
    private static func reviewTaskChecks() {
        let symbol = SymbolID(market: .sh, code: "600519")
        let first = UUID()
        let second = UUID()
        let historyItem = WatchItem(
            symbol: symbol, displayName: "贵州茅台",
            transactions: [
                transaction(first, localDayOffset: 0),
                transaction(second, localDayOffset: 0),
                transaction(localDayOffset: -1)
            ])

        let boardValue = board(items: [], historyItems: [historyItem], entries: [])
        expect(boardValue.todayReviewCount == 2, "review: today's count was wrong")
        expect(boardValue.historyBacklog?.count == 1, "review: backlog count was wrong")
        expect(boardValue.tasks.count == 1, "review: today's fills did not aggregate into one task")

        let task = boardValue.tasks.first
        expect(task?.symbol == symbol, "review: task carried the wrong symbol")
        expect(task?.reviewCount == 2, "review: task review count was wrong")
        expect(Set(task?.reviewTransactionIDs ?? []) == Set([first, second]),
               "review: not every underlying record is reachable from the task")
        expect(task?.reasons.contains("今日成交待复盘") == true, "review: task reason missing")
        expect(task?.countText.contains("2 笔待复盘") == true, "review: count text omitted the review")

        // Post-market prioritizes today's review work over a merely reached plan.
        let other = SymbolID(market: .sz, code: "000001")
        let otherItem = WatchItem(symbol: other, displayName: "平安银行")
        let reached = entry(other, plan(other, price: 10, quantity: 1))
        let postMarket = board(
            items: [otherItem], historyItems: [historyItem], entries: [reached],
            quotes: [other: quote(other, price: 5)], phase: .postMarket)
        expect(postMarket.tasks.first?.symbol == symbol,
               "review: post-market did not prioritize today's review task")

        // A due checkpoint is surfaced without being folded into the backlog.
        let checkpoint = WatchItem(
            symbol: symbol, displayName: "贵州茅台",
            transactions: [transaction(localDayOffset: -4, nextReviewDays: 0, nextReviewNote: "看财报")])
        let dueText = WorkbenchBoard.dueReviewText(
            symbol, items: [checkpoint], today: EastmoneyTradingEvents.dateCalendar.startOfDay(for: now),
            calendar: EastmoneyTradingEvents.dateCalendar)
        expect(dueText?.contains("今日") == true, "review: due checkpoint was not reported as due")
        expect(dueText?.contains("看财报") == true, "review: due checkpoint note was dropped")
        var reviewedCheckpoint = checkpoint
        reviewedCheckpoint.transactions[0].review?.retrospective = "已复盘"
        let dueBoard = board(items: [reviewedCheckpoint], historyItems: [reviewedCheckpoint], entries: [])
        expect(dueBoard.tasks.first?.checkpointID == reviewedCheckpoint.transactions[0].id
               && dueBoard.todayReviewCount == 0 && dueBoard.historyBacklog == nil,
               "review: a due checkpoint must be reachable without becoming a new unreviewed trade")
        let futureCheckpoint = WatchItem(
            symbol: symbol, displayName: "贵州茅台",
            transactions: [transaction(localDayOffset: -4, nextReviewDays: 5)])
        expect(WorkbenchBoard.dueReviewText(
            symbol, items: [futureCheckpoint], today: EastmoneyTradingEvents.dateCalendar.startOfDay(for: now),
            calendar: EastmoneyTradingEvents.dateCalendar) == nil,
            "review: a future checkpoint was reported as due")
    }

    private static func positionVerificationChecks() {
        let symbol = SymbolID(market: .sh, code: "600VER")
        var item = WatchItem(symbol: symbol, displayName: "虚构验证", lots: [CostLot(price: 10, quantity: 50)])
        let event = InstrumentEvent(kind: .earnings, date: day(2), title: "虚构业绩窗口")
        let conditions: [[TradePlanCondition]?] = [
            [TradePlanCondition(title: "待核对订单", kind: .manual)],
            [TradePlanCondition(title: "到期检查", kind: .manual, state: .confirmed, reviewDate: localMidnight(0))],
            [TradePlanCondition(title: "事件依据", kind: .event, state: .confirmed, eventReference: event)],
            [TradePlanCondition(title: "未来复查", kind: .manual, state: .confirmed, reviewDate: localMidnight(5))],
            nil,
        ]
        let portions = conditions.enumerated().map { index, conditions in
            PositionPortion(quantity: 10, pool: index % 2 == 0 ? .strategic : .tactical,
                origin: .init(kind: .snapshot), conditions: conditions)
        }
        item.positionAllocation = PositionAllocation(basisFingerprint: PositionAllocation.basisFingerprint(for: item), portions: portions)
        let missingEvent = board(items: [item], entries: []).tasks.first
        expect(missingEvent?.verifications.map(\.id) == Array(portions.prefix(3)).map(\.id),
               "verification: missing event, pending, and due conditions must reach their exact portion")
        expect(missingEvent?.plans.isEmpty == true, "verification: a holding task must not invent a plan")
        let pendingTitle = PulseLocalization.localizedString("workbench.verification.pending")
        let dueTitle = PulseLocalization.localizedString("workbench.verification.needsReview")
        expect(pendingTitle != dueTitle && missingEvent?.reasons.contains(pendingTitle) == true
            && missingEvent?.reasons.contains(dueTitle) == true,
            "verification: pending and due states must remain distinct")
        let liveEvent = board(items: [item], entries: [], events: [eventEntry(symbol, event)]).tasks.first
        expect(liveEvent?.verifications.count == 2, "verification: an unchanged future event must remain verified")
        item.positionAllocation?.basisFingerprint = String(repeating: "0", count: 64)
        expect(board(items: [item], entries: []).tasks.isEmpty,
               "verification: an unreconciled allocation must not generate verified portion actions")
    }

    // MARK: - Summary coverage

    /// Every scoped symbol gets a summary, including one that has no task at
    /// all — the risk row can select exactly such a symbol.
    private static func summaryCoverageChecks() {
        let taskSymbol = SymbolID(market: .sh, code: "600036")
        let quietSymbol = SymbolID(market: .sz, code: "000002")
        let items = [
            WatchItem(symbol: taskSymbol, displayName: "招商银行"),
            WatchItem(symbol: quietSymbol, displayName: "万科A")
        ]
        let reached = entry(taskSymbol, plan(taskSymbol, price: 10, quantity: 1))
        let boardValue = board(
            items: items, entries: [reached], quotes: [taskSymbol: quote(taskSymbol, price: 5)])

        expect(boardValue.tasks.count == 1, "summary: expected exactly one task")
        expect(boardValue.summary(for: taskSymbol) != nil, "summary: task symbol has no summary")
        expect(boardValue.summary(for: quietSymbol) != nil,
               "summary: a scoped symbol without a task has no summary")

        // History-only symbols are scoped too, so their panel resolves.
        let history = WatchItem(
            symbol: quietSymbol, displayName: "万科A",
            transactions: [transaction(localDayOffset: -2)])
        let withHistory = board(items: [items[0]], historyItems: [history], entries: [])
        expect(withHistory.summary(for: quietSymbol) != nil,
               "summary: history-only symbol has no summary")
        let calendar = EastmoneyTradingEvents.dateCalendar
        let start = calendar.date(from: .init(year: 2026, month: 10, day: 4))!
        let end = calendar.date(from: .init(year: 2026, month: 10, day: 6))!
        let us = SymbolID(market: .us, code: "MSFT")
        let event = InstrumentEvent(kind: .earnings, date: start, title: "fixture", endDate: end)
        let summary = WorkbenchBoard.summary(symbol: us, name: "fixture", quote: nil, now: now,
            entries: [], events: [eventEntry(us, event)])
        expect(summary.events.first?.title.hasPrefix("10-04–10-06") == true,
               "summary: a US event's civil dates shifted to the quote's market timezone")
    }

    // MARK: - Allocation and sectors

    /// An unreconciled allocation must not render as a verified pool split, and
    /// a currency with an unvaluable holding must not assert an over-limit flag.
    private static func allocationAndSectorChecks() {
        let symbol = SymbolID(market: .sh, code: "601318")
        var item = WatchItem(symbol: symbol, displayName: "中国平安")
        item.transactions = [transaction(price: 40, quantity: 100, localDayOffset: -10)]
        // A portion that covers only part of the position: the allocation is
        // stale, so `positionAllocationNeedsReconciliation` is true.
        item.positionAllocation = PositionAllocation(
            basisFingerprint: PositionAllocation.basisFingerprint(for: item),
            portions: [PositionPortion(
                quantity: 40, pool: .strategic,
                origin: .init(kind: .snapshot, date: localMidnight(-10)))])
        expect(item.positionAllocationNeedsReconciliation,
               "allocation: fixture was unexpectedly considered reconciled")
        expect(WorkbenchBoard.poolQuantities(for: item).isEmpty,
               "allocation: stale pool shares were reported as verified")

        let boardValue = board(
            items: [item], entries: [], quotes: [symbol: quote(symbol, price: 50)])
        expect(boardValue.reconciliationCount == 1,
               "allocation: an unreconciled position was not counted")
        expect(boardValue.capitals.count == 1, "allocation: expected one currency row")
        if let capital = boardValue.capitals.first {
            expect(capital.hasSegments == false,
                   "allocation: stale pool shares were drawn as a verified split")
            expect(capital.needsReconciliation, "allocation: reconciliation caveat was not set")
            expect(capital.unverifiedText.isEmpty == false,
                   "allocation: missing reconciliation wording")
        }

        // A missing quote makes the sector percentage a priced-part-only figure
        // and suppresses any over-limit claim for that currency.
        let priced = SectorExposure.make(
            allocation: PortfolioAllocation.calculate(positions: [
                .init(symbol: symbol, name: "中国平安", quantity: 100, price: 50,
                      currencyCode: "CNY", supportsPosition: true)
            ]),
            sectors: [symbol: "金融"])
        expect(priced.isEmpty == false, "sector: fixture produced no exposure row")
        if let exposure = priced.first {
            let limited = WorkbenchSectorRow(exposure, limits: ["CNY:金融": 0.0],
                                             isPricedPartOnly: false)
            expect(limited.overLimit, "sector: over-limit was not detected on a priced row")
            let incomplete = WorkbenchSectorRow(exposure, limits: ["CNY:金融": 0.0],
                                                isPricedPartOnly: true)
            expect(incomplete.overLimit == false, "sector: over-limit asserted despite missing quotes")
            expect(incomplete.hasMissingQuote, "sector: missing-quote flag was not set")
        }

        // The board computes the same suppression from an unvaluable holding, so
        // the missing quote reaches the row without the caller declaring it.
        let unvaluable = WatchItem(symbol: symbol, displayName: "中国平安", lots: [
            CostLot(price: 40, quantity: 100)
        ])
        let boardRow = board(items: [unvaluable], entries: [], quotes: [:])
        expect(boardRow.sectorRows.allSatisfy { $0.hasMissingQuote },
               "sector: board did not mark the currency as priced-part-only")
        expect(boardRow.sectorRows.allSatisfy { $0.overLimit == false },
               "sector: board asserted an over-limit flag with a missing quote")
        expect(boardRow.sectorMissingQuoteCount == 1,
               "sector: board did not count the incomplete currency")
    }

    // MARK: - Plan identity

    /// The user never sees a raw UUID, and two plans keep distinct identities.
    private static func planIdentityChecks() {
        let symbol = SymbolID(market: .us, code: "NVDA")
        let buy = entry(symbol, plan(symbol, kind: .buy, price: 100, quantity: 10,
                                     pool: .strategic, note: "回调加仓"))
        let sell = entry(symbol, plan(symbol, kind: .sell, price: 150, quantity: 5, pool: .tactical))
        let identity = WorkbenchBoard.planIdentity(buy)
        expect(identity.contains("买入"), "identity: buy kind missing")
        expect(identity.contains("战略底仓"), "identity: pool title missing")
        expect(identity.contains("回调加仓"), "identity: note missing")
        expect(identity.contains(buy.id.uuidString) == false, "identity: raw UUID leaked to the user")
        expect(WorkbenchBoard.planIdentity(sell) != identity, "identity: two plans collapsed into one")

        let summary = WorkbenchBoard.summary(
            symbol: symbol, name: "NVIDIA", quote: quote(symbol, price: 120), now: now,
            entries: [buy, sell], events: [], liveEvents: [])
        expect(summary.plans.count == 2, "identity: summary dropped a plan")
        expect(summary.plans.allSatisfy { $0.title.contains($0.id.uuidString) == false },
               "identity: summary title leaked a raw UUID")
        expect(summary.plans.map(\.id) == [buy.id, sell.id], "identity: plan ids were not preserved")
    }

    // MARK: - Phase ordering

    /// Phase reorders rows and nothing else: same task set, same counts.
    private static func phaseOrderChecks() {
        let reachedSymbol = SymbolID(market: .us, code: "AAA")
        let reviewSymbol = SymbolID(market: .us, code: "BBB")
        let reachedItem = WatchItem(symbol: reachedSymbol, displayName: "Reached")
        let history = WatchItem(
            symbol: reviewSymbol, displayName: "Review",
            transactions: [transaction(localDayOffset: 0)])

        func build(_ phase: WorkbenchPhase) -> WorkbenchBoard {
            board(items: [reachedItem], historyItems: [history],
                  entries: [entry(reachedSymbol, plan(reachedSymbol, price: 10, quantity: 1))],
                  quotes: [reachedSymbol: quote(reachedSymbol, price: 5)], phase: phase)
        }

        let pre = build(.preMarket)
        let intraday = build(.intraday)
        let post = build(.postMarket)

        let preIDs = Set(pre.tasks.map(\.symbol))
        let intradayIDs = Set(intraday.tasks.map(\.symbol))
        let postIDs = Set(post.tasks.map(\.symbol))
        expect(preIDs == intradayIDs && intradayIDs == postIDs,
               "phase: reordering changed the set of tasks")
        expect(pre.tasks.count == intraday.tasks.count && intraday.tasks.count == post.tasks.count,
               "phase: reordering changed the task count")
        expect(pre.reachedSymbolCount == intraday.reachedSymbolCount
                && intraday.reachedSymbolCount == post.reachedSymbolCount,
               "phase: reordering changed the reached count")
        expect(pre.todayReviewCount == intraday.todayReviewCount
                && intraday.todayReviewCount == post.todayReviewCount,
               "phase: reordering changed the review count")
        expect(pre.plansToReviewCount == intraday.plansToReviewCount
                && intraday.plansToReviewCount == post.plansToReviewCount,
               "phase: reordering changed the plan-review count")

        // The ordering itself still differs, which is the only thing phase does.
        expect(post.tasks.first?.symbol == reviewSymbol,
               "phase: post-market did not lead with today's review")
        expect(intraday.tasks.first?.symbol != nil, "phase: intraday ordering lost its rows")
    }
}
#endif
