#if DEBUG
import Foundation
import Observation
import os
import PulseCore

/// Runs inside the signed app, using disposable defaults and files only.
@MainActor
enum WorkflowSelfTest {
    static func run() -> Bool {
        guard WorkbenchSelfTest.run() else {
            print("WORKBENCH_SELFTEST_FAILED \(WorkbenchSelfTest.failureReport)")
            return false
        }
        guard dragGeometryChecks(), dragObservationCheck() else { return false }
        let calendar = EastmoneyTradingEvents.dateCalendar
        let rangeStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        guard let before = calendar.date(byAdding: .day, value: -2, to: rangeStart),
              let after = calendar.date(byAdding: .day, value: 2, to: rangeStart),
              let outside = calendar.date(byAdding: .day, value: 8, to: rangeStart),
              TradingEventTimelineLayout.span(event: .init(kind: .other, date: before, title: "Range", endDate: after), start: rangeStart, dayCount: 7, calendar: calendar) == 0..<3,
              TradingEventTimelineLayout.span(event: .init(kind: .other, date: after, title: "Day"), start: rangeStart, dayCount: 7, calendar: calendar) == 2..<3,
              TradingEventTimelineLayout.span(event: .init(kind: .other, date: outside, title: "Outside"), start: rangeStart, dayCount: 7, calendar: calendar) == nil else { return false }
        let fixtureSymbol = SymbolID(market: .us, code: "QUOTE-FIXTURE")
        let fixtureTime = Date(timeIntervalSince1970: 1_704_067_200)
        let quoteA = Quote(symbol: fixtureSymbol, price: 10, previousClose: 9, sourceName: "Alpha", timestamp: fixtureTime)
        let quoteB = Quote(symbol: fixtureSymbol, price: 11, previousClose: 9, sourceName: "Alpha", timestamp: fixtureTime.addingTimeInterval(20))
        let quoteSameDay = Quote(symbol: fixtureSymbol, price: 11, previousClose: 9, sourceName: "Alpha", timestamp: fixtureTime.addingTimeInterval(120))
        let quoteC = Quote(symbol: fixtureSymbol, price: 12, previousClose: 9, sourceName: "Tencent", timestamp: fixtureTime.addingTimeInterval(86_520))
        guard MainHoldingsView.quoteSummaryText(quotes: []) == nil,
              MainHoldingsView.quoteSummaryText(quotes: [quoteA, quoteB], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                == "行情时刻 2024-01-01 08:00（本机时间） · Alpha",
              MainHoldingsView.quoteSummaryText(quotes: [quoteA, quoteSameDay], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                == "行情时刻 2024-01-01 08:00–08:02（本机时间） · Alpha",
              MainHoldingsView.quoteSummaryText(quotes: [quoteA, quoteB, quoteC], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
                == "行情时刻 2024-01-01 08:00–2024-01-02 08:02（本机时间） · Alpha、Tencent" else { return false }

        func plan(
            _ symbol: SymbolID,
            kind: TradePlan.Kind,
            price: Double,
            quantity: Double,
            status: TradePlan.Status = .active,
            pool: PositionPool? = nil
        ) -> TradePlanEntry {
            TradePlanEntry(
                symbol: symbol,
                plan: TradePlan(kind: kind, price: price, quantity: quantity, status: status, positionPool: pool)
            )
        }

        let usdSymbol = SymbolID(market: .us, code: "PLAN-USD")
        let hkdSymbol = SymbolID(market: .hk, code: "PLAN-HKD")
        let unassignedPlan = plan(usdSymbol, kind: .buy, price: 10, quantity: 2)
        let explicitUnassigned = plan(usdSymbol, kind: .buy, price: 10, quantity: 2, pool: .unassigned)
        let strategicPlan = plan(usdSymbol, kind: .sell, price: 15, quantity: 3, pool: .strategic)
        let tacticalPlan = plan(hkdSymbol, kind: .buy, price: 100, quantity: 1, pool: .tactical)
        let donePlan = plan(usdSymbol, kind: .buy, price: 999, quantity: 1, status: .done, pool: .strategic)
        let routeFixtures = [unassignedPlan, explicitUnassigned, strategicPlan, tacticalPlan, donePlan]
        let unassignedPlans = PositionPoolsView.plans(in: .unassigned, from: routeFixtures)
        let strategicPlans = PositionPoolsView.plans(in: .strategic, from: routeFixtures)
        let tacticalPlans = PositionPoolsView.plans(in: .tactical, from: routeFixtures)
        guard unassignedPlans.map(\.id) == [explicitUnassigned.id],
              strategicPlans.map(\.id) == [strategicPlan.id],
              tacticalPlans.map(\.id) == [tacticalPlan.id],
              !PositionPool.activeCases.flatMap({ PositionPoolsView.plans(in: $0, from: routeFixtures) })
                .contains(where: { $0.id == donePlan.id }) else { return false }
        let titleSymbol = SymbolID(market: .us, code: "INTENT-FIXTURE")
        var ended = TradePlan(kind: .buy, price: 10, quantity: 10, status: .done)
        let titleBefore = planIntentTitle(.init(symbol: titleSymbol, plan: ended))
        ended.status = .active
        let filled = PositionTransaction(kind: .buy, price: 10, quantity: 10,
            planExecution: .init(planID: ended.id, configuration: .init(plan: ended)))
        guard titleBefore != planIntentTitle(.init(symbol: titleSymbol, plan: ended, transactions: [filled])),
              titleBefore.contains("未全部成交") || titleBefore.contains("not fully") else { return false }

        let usdBuy = plan(usdSymbol, kind: .buy, price: 10, quantity: 2)
        let usdSell = plan(usdSymbol, kind: .sell, price: 15, quantity: 3)
        let hkdBuy = plan(hkdSymbol, kind: .buy, price: 100, quantity: 1)
        let hkdSell = plan(hkdSymbol, kind: .sell, price: 90, quantity: 2)
        let invalidInfinite = plan(usdSymbol, kind: .buy, price: .infinity, quantity: 1)
        let invalidZeroSize = plan(hkdSymbol, kind: .sell, price: 90, quantity: 0)
        let cancelledPlan = plan(usdSymbol, kind: .sell, price: 500, quantity: 1, status: .cancelled)
        let planTotals = PositionPoolsView.planTotals(
            [usdBuy, usdSell, hkdBuy, hkdSell, invalidInfinite, invalidZeroSize, donePlan, cancelledPlan],
            currency: { $0.market == .us ? "USD" : "HKD" }
        )
        guard planTotals.count == 2,
              planTotals[0].currency == "HKD", planTotals[0].buy == 100, planTotals[0].sell == 180,
              planTotals[1].currency == "USD", planTotals[1].buy == 20, planTotals[1].sell == 45 else { return false }
        let hugePlan = plan(usdSymbol, kind: .buy, price: Double.greatestFiniteMagnitude, quantity: 1)
        guard PositionPoolsView.planTotals([hugePlan, hugePlan], currency: { _ in "USD" }).isEmpty else { return false }

        let suite = "pulse.workflow-selftest.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(false, forKey: "pulse.localBackups.enabled.v1")
        do {
            let budgets = PoolBudgetSettings(defaults: defaults)
            guard budgets.cashBalance(currency: "USD") == nil,
                  budgets.setCashBalance(amount: 0, currency: " usd "),
                  budgets.cashBalance(currency: "USD")?.amount == 0,
                  !budgets.setCashBalance(amount: .infinity, currency: "USD"),
                  !budgets.setPoolLimit(amount: -1, currency: "USD", pool: .strategic),
                  budgets.setPoolLimit(amount: 0, currency: "USD", pool: .strategic),
                  budgets.saveScenario(name: "Fixture", planIDs: [unassignedPlan.id]) != nil,
                  budgets.saveScenario(name: "", planIDs: [unassignedPlan.id]) == nil else { return false }
            let reloadedBudgets = PoolBudgetSettings(defaults: defaults)
            guard reloadedBudgets.cashBalance(currency: "USD")?.amount == 0,
                  reloadedBudgets.poolLimit(currency: "USD", pool: .strategic) == 0,
                  reloadedBudgets.scenarios.first?.planIDs == [unassignedPlan.id],
                  budgets.setCashBalance(amount: nil, currency: "USD"),
                  budgets.cashBalance(currency: "USD") == nil else { return false }
            let store = WatchlistStore(defaults: defaults)
            let symbol = SymbolID(market: .us, code: "FIXTURE")
            store.add(SymbolInfo(symbol: symbol, name: "Fixture", type: .equity), to: store.groups[0].id)
            let trade = PositionTransaction(kind: .buy, price: 100, quantity: 5)
            store.addTransaction(symbol, trade)
            _ = store.updateTransactionReview(symbol, id: trade.id, note: "Execution", review: .init(followedPlan: true, retrospective: "Review", strategy: "Fixture"))
            guard store.setTradingProfile(.init(sector: "Fixture", stopPrice: 90, targetPrice: 120), for: symbol),
                  store.setInstrumentEvent(.init(kind: .earnings, date: fixtureTime, title: "Fixture event", sourceURL: "https://example.com/event"), for: symbol) else { return false }
            let limits = SectorLimitSettings(defaults: defaults)
            guard limits.setLimit(40, for: "USD:Fixture"),
                  !limits.setLimit(.infinity, for: "USD:Fixture"),
                  !limits.setLimit(-1, for: "USD:Fixture"),
                  SectorLimitSettings(defaults: defaults).limits["USD:Fixture"] == 40 else { return false }
            let target = store.syncSnapshot()
            let files = LocalBackupStore(bundleIdentifier: "fixture", applicationSupportURL: directory)
            let record = try files.createBackup(kind: .manual, snapshot: target)
            var applied = 0
            var syncChanges = 0
            store.onLocalSyncChange = { _ in syncChanges += 1 }
            let controller = LocalBackupController(store: store, backupStore: files, defaults: defaults) {
                applied += 1
                _ = try store.restoreBackup($0)
            }
            let stale = try controller.preview(for: record)
            store.addTransaction(symbol, .init(kind: .sell, price: 110, quantity: 1))
            guard !controller.restore(record, afterReviewing: stale), applied == 0,
                  controller.lastError != nil else { return false }
            let beforeRestore = store.syncSnapshot()
            let preview = try controller.preview(for: record)
            let changesBeforeRestore = syncChanges
            guard controller.restore(record, afterReviewing: preview), applied == 1,
                  store.syncSnapshot() == target, syncChanges == changesBeforeRestore + 1 else { return false }
            let preRestore = try files.listBackups().first { $0.kind == .preRestore }
            guard let preRestore, try files.readSnapshot(for: preRestore) == beforeRestore else { return false }
            let failing = LocalBackupController(store: store, backupStore: files, defaults: defaults) { _ in
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected restore failure"])
            }
            guard !failing.restore(record, afterReviewing: try failing.preview(for: record)),
                  failing.lastError?.contains("Expected restore failure") == true,
                  store.syncSnapshot() == target else { return false }
            failing.refreshBackups()
            guard failing.lastError?.contains("Expected restore failure") == true else { return false }
            _ = try files.createDailyBackup(snapshot: store.syncSnapshot())
            failing.setEnabled(true)
            guard failing.lastError?.contains("Expected restore failure") == true else { return false }
            failing.setEnabled(false)
            let invalidURL = files.directoryURL.appendingPathComponent(record.id + ".json")
            try Data("{}".utf8).write(to: invalidURL, options: .atomic)
            guard !controller.restore(record, afterReviewing: preview), applied == 1,
                  controller.lastError != nil, store.syncSnapshot() == target else { return false }
            print("PULSE_WORKFLOW_SELFTEST passed: drag geometry and observation isolation, plan routing and currency totals, restore preview, pre-restore preservation, sync callback, failure handling")
            return true
        } catch {
            print("PULSE_WORKFLOW_SELFTEST failed: \(error)")
            return false
        }
    }

    /// The badge geometry: the grip is normalised against the source card and
    /// re-applied to the badge, so shrinking the card keeps the hold; a pointer
    /// inside the board moves the badge 1:1, and one outside clamps it back in.
    private static func dragGeometryChecks() -> Bool {
        let source = CGRect(x: 20, y: 30, width: 220, height: 84)
        let pointer = CGPoint(x: 214, y: 92)
        let grip = PositionPoolDragGeometry.grabOffset(pointer: pointer, sourceFrame: source)
        let normalized = PositionPoolDragGeometry.normalizedGrip(grip, sourceSize: source.size)
        guard grip == CGPoint(x: 194, y: 62),
              PositionPoolDragGeometry.proxyCenter(pointer: pointer, grabOffset: grip, cardSize: source.size)
                == CGPoint(x: source.midX, y: source.midY),
              // The raw grip re-applied to a 40pt badge would put it at 40,50,
              // far from the cursor: that is exactly what normalising prevents.
              PositionPoolDragGeometry.proxyCenter(pointer: pointer, grabOffset: grip, cardSize: .init(width: 40, height: 40))
                == CGPoint(x: 40, y: 50) else { return false }
        // Fixed 40pt height; width is the source width capped at 260pt.
        let badge = PositionPoolsView.DragBadge.size(forSourceWidth: source.width)
        guard PositionPoolsView.DragBadge.height == 40, badge.width == 220,
              PositionPoolsView.DragBadge.size(forSourceWidth: 400).width == 260,
              PositionPoolsView.DragBadge.size(forSourceWidth: 120).width == 120,
              PositionPoolDragGeometry.badgeGrip(normalized, badgeSize: badge)
                == PositionPoolDragGeometry.badgeGrip(.init(x: grip.x / source.width, y: grip.y / source.height), badgeSize: badge) else { return false }
        // The hold is proportional: the source's grip fraction, mapped onto the
        // badge, keeps the badge under the cursor at pickup.
        let badgeHold = PositionPoolDragGeometry.proxyCenter(
            pointer: pointer, grabOffset: PositionPoolDragGeometry.badgeGrip(normalized, badgeSize: badge),
            cardSize: badge)
        guard abs(badgeHold.x - source.midX) < 1e-9,
              abs(badgeHold.y - (pointer.y - grip.y / source.height * badge.height + badge.height / 2)) < 1e-9 else { return false }
        let moved = CGPoint(x: pointer.x + 70, y: pointer.y + 45)
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        let badgeGrip = PositionPoolDragGeometry.badgeGrip(normalized, badgeSize: badge)
        let centered = PositionPoolDragGeometry.proxyPosition(
            pointer: moved, grabOffset: badgeGrip, badgeSize: badge, viewport: viewport)
        guard badgeGrip != grip,
              centered == CGPoint(x: moved.x - badgeGrip.x + badge.width / 2,
                                  y: moved.y - badgeGrip.y + badge.height / 2),
              centered.x - badgeHold.x == moved.x - pointer.x,
              centered.y - badgeHold.y == moved.y - pointer.y,
              viewport.contains(centered),
              PositionPoolDragGeometry.proxyPosition(pointer: CGPoint(x: -400, y: 900), grabOffset: badgeGrip,
                                                     badgeSize: badge, viewport: viewport)
                == PositionPoolDragGeometry.clamp(.init(x: -400 - badgeGrip.x + badge.width / 2,
                                                        y: 900 - badgeGrip.y + badge.height / 2),
                                                  cardSize: badge, in: viewport),
              PositionPoolDragGeometry.clamp(.init(x: -30, y: 800), cardSize: .init(width: 1000, height: 1000), in: viewport)
                == CGPoint(x: viewport.midX, y: viewport.midY) else { return false }
        return true
    }

    /// The hot path must not be board state. A thousand pointer moves may touch
    /// `location`; only a target change may reach anything else.
    private static func dragObservationCheck() -> Bool {
        let motion = PositionPoolsView.PositionPoolDragMotion()
        let targetNotifications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = motion.target
        } onChange: {
            targetNotifications.withLock { $0 += 1 }
        }
        for step in 0..<1_000 {
            motion.move(to: CGPoint(x: Double(step), y: Double(step) / 2), target: nil)
        }
        guard targetNotifications.withLock({ $0 }) == 0, motion.location == CGPoint(x: 999, y: 499.5) else { return false }
        motion.move(to: CGPoint(x: 1_000, y: 500), target: .init(pool: .tactical, symbol: nil))
        guard targetNotifications.withLock({ $0 }) == 1, motion.target == .init(pool: .tactical, symbol: nil) else { return false }
        // Re-resolving the same target is not a change, and a move that keeps it
        // stays silent.
        let furtherNotifications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = motion.target
        } onChange: {
            furtherNotifications.withLock { $0 += 1 }
        }
        motion.move(to: CGPoint(x: 1_001, y: 501), target: .init(pool: .tactical, symbol: nil))
        guard furtherNotifications.withLock({ $0 }) == 0 else { return false }
        return true
    }
}
#endif
