#if DEBUG
import AppKit
import Security
import SwiftUI
import PulseCore

/// Debug-only harness for the position-pools tactical board.
///
/// It runs the *real* view, the *real* projection calculator, and the *real*
/// store, against a throwaway `UserDefaults` suite, and writes native renders to
/// `build/artifacts/tactical/`. Everything in here is fictional fixture data;
/// nothing reads the developer's defaults, keychain, quotes, or account.
///
/// Usage (must be paired with `--main-window-demo`, which selects the isolated
/// offline defaults path inside `AppState.init`):
///
///     "FFF.app/Contents/MacOS/FFF" --main-window-demo --tactical-board-selftest
@MainActor
enum TacticalBoardSelfTest {
    private static var failures: [String] = []

    /// A render that produced a structurally empty image. Reported as a failure
    /// so a blank board can never be delivered as if it had passed.
    private enum TacticalRenderError: LocalizedError {
        case boardRegionBlank(String)

        var errorDescription: String? {
            switch self {
            case .boardRegionBlank(let detail):
                "board region did not render: \(detail)"
            }
        }
    }

    // MARK: - Entry point

    static func run() -> Bool {
        failures = []
        let outputDirectory = URL(fileURLWithPath: "build/artifacts/tactical", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            report("output-directory", "cannot create \(outputDirectory.path): \(error)")
            return finish()
        }

        let appState = AppState()
        if CommandLine.arguments.contains("--plan-status-only") {
            guard CommandLine.arguments.contains("--main-window-demo") else {
                report("plan-status", "isolated demo required"); return finish()
            }
            renderPlanStatuses(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--buy-source-only") {
            guard CommandLine.arguments.contains("--main-window-demo") else {
                report("buy-source", "isolated demo required")
                return finish()
            }
            renderBuySources(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--live-sort-only") {
            renderLiveSorting(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--reconciliation-only") {
            renderReconciliationForm(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--journal-account-only") {
            renderJournalAccounts(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--plan-buy-only") {
            guard CommandLine.arguments.contains("--main-window-demo") else {
                report("plan-buy", "isolated demo required")
                return finish()
            }
            renderPlanBuyForms(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--trade-buy-only") {
            renderBuyAccountForms(appState: appState, into: outputDirectory)
            return finish()
        }
        // Must run before `seedFixture`: the whole point is to render the
        // untouched isolated demo books, so no other fixture may bleed in.
        if CommandLine.arguments.contains("--holdings-account-only") {
            guard CommandLine.arguments.contains("--main-window-demo") else {
                report("holdings-account", "--holdings-account-only requires --main-window-demo for the isolated throwaway defaults")
                return finish()
            }
            renderHoldingsAccounts(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--shared-watchlist-only") {
            renderSharedWatchlist(appState: appState, into: outputDirectory)
            return finish()
        }
        let symbols = seedFixture(into: appState)
        if CommandLine.arguments.contains("--portion-sale-only") {
            renderPortionSales(appState: appState, symbols: symbols, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--plan-create-only") {
            renderPlanCreation(appState: appState, symbols: symbols, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--pool-transfer-only") {
            renderPoolTransferForms(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--pool-header-only") {
            renderPoolHeaders(appState: appState, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--audit-ui-only") {
            renderAuditArtifacts(appState: appState, symbols: symbols, into: outputDirectory)
            return finish()
        }
        if CommandLine.arguments.contains("--account-cards-only") {
            renderAccountTags(appState: appState, into: outputDirectory)
            return finish()
        }

        assertProjectionMath(appState: appState, symbols: symbols)
        assertFixtureCoversBoard(appState: appState, symbols: symbols)
        assertLineage(appState: appState, symbols: symbols)
        assertPendingPlans(appState: appState, symbols: symbols)
        assertPreviewDoesNotMutate(appState: appState, symbols: symbols)
        assertSelectionAndHighlight(appState: appState, symbols: symbols)
        assertMissingKnowledgeIsHonest(appState: appState, symbols: symbols)
        assertQuoteCurrencyCannotOverride(appState: appState, symbols: symbols)
        assertSheetPolicyBlocksWrites()
        assertPoolShares()
        assertFundingCoverage()
        expect(abs(PoolTrackGauge.fraction(6_400, scale: 80_000) - 0.08) < 1e-9,
               "resource-track", "6400 planned against 80000 cash must occupy 8%, not the whole track")
        expect(PoolTrackGauge.fraction(0, scale: 80_000) == 0
               && PoolTrackGauge.fraction(.infinity, scale: 80_000) == 0
               && PoolTrackGauge.fraction(10, scale: 0) == 0,
               "resource-track", "empty or invalid values must not paint a filled track")

        assertBrokerageAccounts(appState: appState, symbols: symbols)
        assertAccountOverview(appState: appState, symbols: symbols)

        renderArtifacts(appState: appState, symbols: symbols, into: outputDirectory)
        renderSystemArtifacts(appState: appState, symbols: symbols, into: outputDirectory)
        renderTwoPoolArtifacts(appState: appState, into: outputDirectory)
        renderBrokerageAccountArtifacts(appState: appState, into: outputDirectory)
        renderAccountOverviewArtifacts(appState: appState, into: outputDirectory)

        return finish()
    }

    /// Recorded prices, historical recovery, and the real source-link editor.
    private static func renderBuySources(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        _ = appState.selectBrokerageAccount(.unassigned)
        let symbol = SymbolID(market: .us, code: "SOURCEQA")
        store.add(SymbolInfo(symbol: symbol, name: "虚构成交来源"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let buys = [110.0, 120.0, 130.0].enumerated().map { offset, price in
            PositionTransaction(kind: .buy, price: price, quantity: 200,
                date: date.addingTimeInterval(Double(offset) * 86_400))
        }
        for buy in buys { store.addTransaction(symbol, buy) }
        var snapshot = store.syncSnapshot()
        guard let index = snapshot.items.firstIndex(where: { $0.symbol == symbol }),
              var allocation = snapshot.items[index].positionAllocation else {
            report("buy-source", "missing fictional allocation"); return
        }
        let targetID = allocation.portions[0].id
        let recoveredID = allocation.portions[2].id
        var previous = allocation.portions
        for i in previous.indices {
            previous[i].pool = .tactical
            previous[i].brokerageAccountID = .financing
            if i < 2 { previous[i].origin = .init(kind: .snapshot, date: date.addingTimeInterval(4 * 86_400)) }
        }
        allocation.portions = previous.map { part in
            var copy = part
            copy.origin = .init(kind: .snapshot, date: date.addingTimeInterval(4 * 86_400))
            return copy
        }
        allocation.changes = [.init(kind: .sourceInvalidated, reason: "Synthetic legacy source reset",
            previousPortions: previous, resultingPortions: allocation.portions)]
        snapshot.items[index].positionAllocation = allocation
        _ = store.applySyncSnapshot(snapshot)
        let original = store.syncSnapshot()
        guard let item = store.item(for: symbol), let current = item.positionAllocation,
              let target = current.portions.first(where: { $0.id == targetID }) else {
            report("buy-source", "fixture load failed"); return
        }
        expect(current.resolvedBuyOrigins(for: item)[recoveredID]?.price == 130,
               "buy-source", "same-id historical source must recover the recorded price")
        expect(current.resolvedBuyOrigins(for: item)[targetID] == nil,
               "buy-source", "equal-sized buys cannot identify an old snapshot")
        expect(current.availableBuySources(for: targetID, item: item).map(\.id) == [buys[1].id, buys[0].id],
               "buy-source", "a historically recovered card reserves its source quantity")
        expect(PositionPoolsView.Sheet.isMutating(.buySource(.init(symbol: symbol, portionID: targetID))),
               "buy-source", "source linking must be blocked in preview")
        do {
            for scheme in [ColorScheme.light, .dark] {
                let style = scheme == .light ? "light" : "dark"
                let cards = VStack(spacing: 10) {
                    ForEach(current.portions) { part in
                        PortionCardFace(card: .init(item: item, portion: part, needsReview: false), compact: false,
                            onSelect: {}, onWholeTransfer: { _ in }, onPartialTransfer: { _ in }, onMarkFunding: {},
                            onEditVerification: {}, onDragChanged: { _, _ in }, onDragEnded: { _ in },
                            isDraggable: true, isPlaceholder: false)
                    }
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).environment(appState).environment(\.colorScheme, scheme)
                try renderInOffscreenWindow(view: cards, width: 360, height: 400,
                    to: directory.appendingPathComponent("buy-source-cards-\(style).png"), scheme: scheme, requiresBoardBand: false)
                let form = PositionBuySourceSheet(item: item, portion: target, allocation: current, account: .unassigned,
                    onCancel: {}, onSuccess: {}).environment(appState).environment(\.colorScheme, scheme)
                try renderInOffscreenWindow(view: form, width: 460, height: 330,
                    to: directory.appendingPathComponent("buy-source-editor-\(style).png"), scheme: scheme, requiresBoardBand: false)
            }
            expect(store.syncSnapshot() == original, "buy-source", "display and recovery must never write")
            if CommandLine.arguments.contains("--interactive-buy-source") {
                var timedOut = false
                let view = BuySourceInteractiveFixture(symbol: symbol, portionID: targetID).environment(appState)
                try renderInOffscreenWindow(view: view, width: 560, height: 400,
                    to: directory.appendingPathComponent("buy-source-linked-interactive.png"), scheme: .light,
                    requiresBoardBand: false, inspect: { hosting in
                        guard let window = hosting.window else { return }
                        window.title = "FFF · 虚构成交来源验证"
                        window.setFrameOrigin(NSPoint(x: 260, y: 180))
                        NSApp.finishLaunching()
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        print("BUY_SOURCE_INTERACTIVE_READY"); fflush(stdout)
                        let stop: @MainActor @Sendable () -> Void = {
                            NSApp.stop(nil)
                            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                        }
                        let monitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                            MainActor.assumeIsolated {
                                if store.item(for: symbol)?.positionAllocation?.portions.first(where: { $0.id == targetID })?.origin.transactionID == buys[1].id { stop() }
                            }
                        }
                        let timeout = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { _ in
                            MainActor.assumeIsolated { timedOut = true; stop() }
                        }
                        NSApp.run(); monitor.invalidate(); timeout.invalidate()
                        for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                    })
                expect(!timedOut, "buy-source", "interactive source linking must complete")
                if let updated = store.item(for: symbol) {
                    expect(updated.transactions == item.transactions && updated.plans == item.plans,
                           "buy-source", "linking must leave transactions and plans intact")
                    expect(updated.positionQuantity == item.positionQuantity && updated.costBasis == item.costBasis,
                           "buy-source", "linking must preserve held quantity and cost")
                    expect(updated.positionAllocation?.portions.first(where: { $0.id == targetID })?.origin.price == 120,
                           "buy-source", "the selected recorded price must appear on the card")
                }
            }
        } catch { report("buy-source", error.localizedDescription) }
    }

    private struct BuySourceInteractiveFixture: View {
        @Environment(AppState.self) private var appState
        let symbol: SymbolID
        let portionID: UUID
        @State private var showingSource = false

        var body: some View {
            if let item = appState.watchlist.item(for: symbol), let allocation = item.positionAllocation,
               let portion = allocation.portions.first(where: { $0.id == portionID }) {
                PortionCardFace(card: .init(item: item, portion: portion, needsReview: false), compact: false,
                    onSelect: {}, onWholeTransfer: { _ in }, onPartialTransfer: { _ in }, onMarkFunding: {},
                    onEditVerification: {}, onLinkBuySource: { showingSource = true },
                    onDragChanged: { _, _ in }, onDragEnded: { _ in }, isDraggable: true, isPlaceholder: false)
                    .frame(width: 340).padding(24)
                    .sheet(isPresented: $showingSource) {
                        PositionBuySourceSheet(item: item, portion: portion, allocation: allocation, account: .unassigned,
                            onCancel: { showingSource = false }, onSuccess: { showingSource = false })
                    }
            }
        }
    }

    /// Keeps one native view alive while quotes change, proving that sorting
    /// reacts to the market store rather than just to a new view being built.
    private static func renderLiveSorting(appState: AppState, into directory: URL) {
        let suite = "FFF.LiveSort.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite),
              let groupID = appState.watchlist.createGroup(named: "虚构排序") else {
            report("live-sort", "missing isolated defaults or group"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SymbolID(market: .us, code: "SORTA")
        let second = SymbolID(market: .us, code: "SORTB")
        for (symbol, name, quantity) in [(first, "虚构甲", 100.0), (second, "虚构乙", 80.0)] {
            appState.watchlist.add(SymbolInfo(symbol: symbol, name: name), to: groupID)
            appState.watchlist.addTransaction(symbol, .init(kind: .buy, price: 100, quantity: quantity,
                date: Calendar.current.startOfDay(for: .now).addingTimeInterval(-86_400)))
        }
        appState.sharedWatchlist.selectGroup(groupID)
        appState.sharedWatchlist.reorder([first, second])
        appState.settings.prioritizeOpenMarkets = false
        appState.settings.watchRowMetricMode = .changePercent
        defaults.set(WatchlistOrderMode.automatic.rawValue, forKey: "pulse.watchlist.orderMode.v1")
        defaults.set(WatchlistSortOption.marketValue.rawValue, forKey: "pulse.watchlist.sortOption.v1")
        let snapshot = appState.watchlist.syncSnapshot()
        let timestamp = Date.now
        var quoteRound = 0
        func quotes(secondBatch: Bool) -> [Quote] {
            [Quote(symbol: first, price: secondBatch ? 90 : 110, previousClose: 100,
                   sourceID: "fictional-sort", timestamp: timestamp.addingTimeInterval(Double(quoteRound * 2) + (secondBatch ? 1 : 0)), marketState: .regular),
             Quote(symbol: second, price: secondBatch ? 130 : 105, previousClose: 100,
                   sourceID: "fictional-sort", timestamp: timestamp.addingTimeInterval(Double(quoteRound * 2) + (secondBatch ? 1 : 0)), marketState: .regular)]
        }
        func order(_ option: WatchlistSortOption?, bypass: Bool = false) -> [SymbolID] {
            WatchlistDisplayOrder.items(from: appState.sharedWatchlist, prioritizeOpenMarkets: false,
                bypass: bypass, sortValue: option.map { value in
                    { item in WatchlistDisplayOrder.value(for: item, option: value, appState: appState) }
                }).map(\.symbol)
        }
        func captureBefore(_ host: NSView, name: String) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { return }
            if CommandLine.arguments.contains("--export-render-base64") {
                print("PULSE_RENDER_BASE64 \(name) \(data.base64EncodedString())"); fflush(stdout)
            } else { try? data.write(to: directory.appendingPathComponent(name)) }
        }
        do {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                for sidebar in [false, true] {
                    quoteRound += 1
                    appState.market.apply(quotes: quotes(secondBatch: false))
                    for option in WatchlistSortOption.allCases {
                        expect(order(option) == [first, second], "live-sort-before", "all four metrics must use the first quote batch")
                    }
                    let view: AnyView = sidebar
                        ? AnyView(MainWatchlistSidebar(selectedSymbol: .constant(first), currentPage: nil,
                            onShowPage: { _ in }).environment(appState).defaultAppStorage(defaults))
                        : AnyView(WatchlistView(route: .constant(.list), searchSession: .constant(SearchSession()))
                            .environment(appState).defaultAppStorage(defaults))
                    let width: CGFloat = sidebar ? 281 : 340
                    let name = "live-sort-\(sidebar ? "sidebar" : "popover")"
                    try renderInOffscreenWindow(view: view, width: width, height: 650,
                        to: directory.appendingPathComponent("\(name)-after-\(suffix).png"),
                        scheme: scheme, requiresBoardBand: false, inspect: { host in
                            captureBefore(host, name: "\(name)-before-\(suffix).png")
                            appState.market.applyStreamed(quotes(secondBatch: true))
                            for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.12)) }
                            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        })
                }
            }
            for option in WatchlistSortOption.allCases {
                expect(order(option) == [second, first], "live-sort-after", "all four metrics must use the updated quotes")
            }
            expect(order(nil) == [first, second] && order(.marketValue, bypass: true) == [first, second],
                   "live-sort-manual", "custom order and reorder bypass must stay unchanged")
            expect(appState.watchlist.syncSnapshot() == snapshot, "live-sort-persistence",
                   "live sorting must not write holdings, plans, group order or manual order")
        } catch { report("live-sort", error.localizedDescription) }
    }

    /// Real cards, editor and execution form, using fictional accounts only.
    private static func renderPortionSales(appState: AppState, symbols: Fixture, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        let fixtureAccount = store.activeBrokerageAccountID
        let otherAccountID: BrokerageAccountID = fixtureAccount == .financing ? .mengmeng : .financing
        guard let original = store.item(for: symbols.tactical),
              let portion = original.positionAllocation?.portions.first(where: { $0.pool == .tactical }) else {
            report("portion-sale", "missing fixture portion"); return
        }
        for plan in original.plans { store.deleteTradePlan(plan.id, for: symbols.tactical) }
        let otherAccount = store.brokeragePortfolio(for: otherAccountID)
        let baseline = store.syncSnapshot()
        do {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                try renderInOffscreenWindow(view: PlanEditorView(symbol: symbols.tactical, planID: nil,
                    returnRoute: .planList, route: .constant(.planList), account: fixtureAccount,
                    positionPortionID: portion.id).environment(appState), width: 520, height: 520,
                    to: directory.appendingPathComponent("portion-sale-editor-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
            }
            expect(store.syncSnapshot() == baseline, "portion-sale-render", "rendering a new draft must not mutate holdings or plans")
            let sample = TradePlan(kind: .sell, price: 12.5, quantity: 100, positionPool: .tactical, positionPortionID: portion.id)
            expect(store.setTradePlan(sample, for: symbols.tactical), "portion-sale-fixture", "valid card plan must save")
            // Legacy labels may differ from the owning ledger. A plan must
            // neither duplicate that holding nor borrow a lookalike elsewhere.
            let beforeLabel = PoolBudgetInput(appState: appState, currencyFilter: "USD", allAccounts: true).calculate()
            if let allocation = store.item(for: symbols.tactical)?.positionAllocation {
                let labelled = try store.setPositionBrokerageAccount(symbol: symbols.tactical,
                    portionID: portion.id, accountID: .financing, expectedRevision: allocation.revision)
                let afterLabel = PoolBudgetInput(appState: appState, currencyFilter: "USD", allAccounts: true).calculate()
                expect(beforeLabel.currencies.first?.holdingsBefore == afterLabel.currencies.first?.holdingsBefore
                       && beforeLabel.currencies.first?.holdingsAfter == afterLabel.currencies.first?.holdingsAfter,
                       "portion-sale-label", "cross-labelled source must preserve total holdings before and after projection")
                expect(!afterLabel.overSellWarnings.contains(where: { $0.planID == sample.id }),
                       "portion-sale-label", "the exact source must remain available in its attributed group")
                _ = try store.setPositionBrokerageAccount(symbol: symbols.tactical,
                    portionID: portion.id, accountID: .unassigned, expectedRevision: labelled.revision)
            }
            guard let linked = store.item(for: symbols.tactical) else { return }
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let cards = HStack(alignment: .top, spacing: 12) {
                    ForEach(linked.positionAllocation?.portions ?? []) { value in
                        PortionCardFace(card: .init(item: linked, portion: value, needsReview: false),
                            compact: false, onSelect: {}, onWholeTransfer: { _ in }, onPartialTransfer: { _ in },
                            onMarkFunding: {}, onEditVerification: {}, onDragChanged: { _, _ in },
                            onDragEnded: { _ in }, isDraggable: true, isPlaceholder: false)
                            .frame(width: 220)
                    }
                }.padding(16).environment(appState)
                try renderInOffscreenWindow(view: cards, width: 490, height: 270,
                    to: directory.appendingPathComponent("portion-sale-cards-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
                if let entry = store.tradePlanEntries.first(where: { $0.id == sample.id }) {
                    try renderInOffscreenWindow(view: PlanExecutionSheet(entry: entry, account: fixtureAccount, onClose: {})
                        .environment(appState), width: 520, height: 590,
                        to: directory.appendingPathComponent("portion-sale-fill-\(suffix).png"),
                        scheme: scheme, requiresBoardBand: false)
                }
            }
            let historyCards = HStack(alignment: .top, spacing: 12) {
                ForEach(["filled", "abandoned", "unrecorded", "partial-stopped"], id: \.self) { state in
                    let variant = portionSaleDisplayFixture(linked, plan: sample, state: state)
                    PortionCardFace(card: .init(item: variant, portion: portion, needsReview: false),
                        compact: false, onSelect: {}, onWholeTransfer: { _ in }, onPartialTransfer: { _ in },
                        onMarkFunding: {}, onEditVerification: {}, onDragChanged: { _, _ in },
                        onDragEnded: { _ in }, isDraggable: true, isPlaceholder: false)
                        .frame(width: 250)
                }
            }.padding(16).environment(appState)
            for scheme in [ColorScheme.light, .dark] {
                try renderInOffscreenWindow(view: historyCards, width: 1_100, height: 330,
                    to: directory.appendingPathComponent("portion-sale-history-\(scheme == .dark ? "dark" : "light").png"),
                    scheme: scheme, requiresBoardBand: false)
            }
            store.deleteTradePlan(sample.id, for: symbols.tactical)
            guard CommandLine.arguments.contains("--portion-sale-interactive") else { return }
            var timedOut = false
            let view = PositionPoolsView(onSelect: { _ in }).environment(appState)
            try renderInOffscreenWindow(view: view, width: 1_240, height: 800,
                to: directory.appendingPathComponent("portion-sale-interactive-result.png"),
                scheme: .light, requiresBoardBand: false, inspect: { host in
                    guard let window = host.window else { return }
                    window.styleMask = [.titled, .closable]
                    window.title = "虚构仓位卖出计划测试"
                    window.setFrameOrigin(NSPoint(x: 100, y: 100))
                    NSApp.finishLaunching()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    print("PORTION_SALE_INTERACTIVE_READY"); fflush(stdout)
                    let stop: @MainActor @Sendable () -> Void = {
                        NSApp.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                    }
                    let monitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            if store.item(for: symbols.tactical)?.transactions.contains(where: { $0.kind == .sell }) == true { stop() }
                        }
                    }
                    let timeout = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
                        MainActor.assumeIsolated { timedOut = true; stop() }
                    }
                    NSApp.run(); monitor.invalidate(); timeout.invalidate()
                    for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                })
            expect(!timedOut, "portion-sale-ui", "interactive creation and fill must finish")
            let saved = store.item(for: symbols.tactical)
            let plan = saved?.plans.first(where: { $0.positionPortionID == portion.id })
            expect(plan?.kind == .sell && plan?.price == 12.5 && plan?.quantity == 100,
                   "portion-sale-ui", "right-click must save the exact portion's target-price plan")
            expect(saved?.positionAllocation?.portions.first(where: { $0.id == portion.id })?.quantity == portion.quantity - 50,
                   "portion-sale-ui", "recording 50 must reduce only the source card")
            let sibling = original.positionAllocation?.portions.filter { $0.id != portion.id }
            expect(saved?.positionAllocation?.portions.filter { $0.id != portion.id } == sibling,
                   "portion-sale-ui", "other cards must stay untouched")
            expect(store.brokeragePortfolio(for: otherAccountID) == otherAccount,
                   "portion-sale-ui", "another ledger must stay untouched")
        } catch { report("portion-sale", error.localizedDescription) }
    }

    /// View-only copies of a fictional card; never persisted or accounted as a
    /// trade. Actual store allocation and fill behavior has separate core tests.
    private static func portionSaleDisplayFixture(_ item: WatchItem, plan: TradePlan, state: String) -> WatchItem {
        var copy = item
        var displayed = plan
        displayed.status = state == "filled" ? .active : state == "abandoned" ? .cancelled : .done
        copy.plans = [displayed]
        if state == "filled" || state == "partial-stopped" {
            copy.transactions.append(PositionTransaction(kind: .sell, price: 12, quantity: state == "filled" ? plan.quantity : 40,
                date: .now, planExecution: .init(planID: plan.id, configuration: .init(plan: displayed))))
        }
        return copy
    }

    private static func renderPlanStatuses(appState: AppState, into directory: URL) {
        // This regression exercises the comfortable card's visible record action.
        // The separate usability self-test verifies both density modes.
        appState.settings.compactPlanCards = false
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        _ = appState.selectBrokerageAccount(.financing)
        // This branch is reachable only with the isolated offline demo suite.
        for item in store.allItems {
            for plan in item.plans { store.deleteTradePlan(plan.id, for: item.symbol) }
            store.remove(item.symbol)
        }
        let symbol = SymbolID(market: .us, code: "PLANQA")
        store.add(SymbolInfo(symbol: symbol, name: "虚构计划验证"))
        let pending = TradePlan(kind: .buy, price: 110, quantity: 100)
        let waitingSale = TradePlan(kind: .sell, price: 140, quantity: 50)
        let completed = TradePlan(kind: .buy, price: 100, quantity: 200)
        let abandoned = TradePlan(kind: .buy, price: 90, quantity: 100, status: .cancelled)
        let stopped = TradePlan(kind: .buy, price: 80, quantity: 100, status: .done)
        let partial = TradePlan(kind: .buy, price: 102, quantity: 100)
        let abandonedPartial = TradePlan(kind: .buy, price: 95, quantity: 100)
        let stoppedPartial = TradePlan(kind: .buy, price: 85, quantity: 100)
        for plan in [pending, waitingSale, completed, abandoned, stopped, partial, abandonedPartial, stoppedPartial] {
            expect(store.setTradePlan(plan, for: symbol), "plan-status", "fixture plan must save")
        }
        do {
            _ = try store.recordTradePlanFill(symbol: symbol, planID: completed.id, price: 98,
                quantity: 200, date: Calendar.current.startOfDay(for: .now).addingTimeInterval(-86_400),
                fee: 0, note: "fictional status fill", fundingSource: .own, brokerageAccountID: .financing)
            for (plan, quantity) in [(partial, 40.0), (abandonedPartial, 25.0), (stoppedPartial, 20.0)] {
                _ = try store.recordTradePlanFill(symbol: symbol, planID: plan.id, price: plan.price - 1,
                    quantity: quantity, date: .now, fee: 0, note: "fictional partial fill",
                    fundingSource: .own, brokerageAccountID: .financing)
            }
            for (plan, status) in [(abandonedPartial, TradePlan.Status.cancelled), (stoppedPartial, .done)] {
                if var saved = store.item(for: symbol)?.plans.first(where: { $0.id == plan.id }) {
                    saved.status = status
                    expect(store.setTradePlan(saved, for: symbol), "plan-status", "partial decision must save")
                }
            }
        } catch { report("plan-status", error.localizedDescription); return }
        appState.market.apply(quotes: [Quote(symbol: symbol, name: "虚构计划验证", price: 105, previousClose: 100,
            sourceID: "fictional-status", timestamp: .now, marketState: .regular)])
        let baseline = store.syncSnapshot()
        do {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                for scope in [PlanListView.Scope.waiting, .history] {
                    try renderInOffscreenWindow(view: PlanListView(route: .constant(.planList), initialScope: scope).environment(appState),
                        width: 340, height: 620, to: directory.appendingPathComponent("plans-compact-\(scope.rawValue)-\(suffix).png"),
                        scheme: scheme, requiresBoardBand: false)
                }
                try renderInOffscreenWindow(view: MainPlanListView(route: .constant(.planList), initialFilter: .all).environment(appState),
                    width: 1_240, height: 660, to: directory.appendingPathComponent("plans-main-all-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
            }
            try renderInOffscreenWindow(view: MainPlanListView(route: .constant(.planList), initialFilter: .done).environment(appState),
                width: 1_240, height: 660, to: directory.appendingPathComponent("plans-main-filled.png"),
                scheme: .light, requiresBoardBand: false)
            try renderInOffscreenWindow(view: MainInstrumentView(symbol: symbol, initialShowsPlans: true).environment(appState),
                width: 1_240, height: 760, to: directory.appendingPathComponent("plans-instrument-light.png"),
                scheme: .light, requiresBoardBand: false)
            try renderInOffscreenWindow(view: DetailView(symbol: symbol, route: .constant(.detail(symbol))).environment(appState),
                width: 340, height: 740, to: directory.appendingPathComponent("plans-detail-light.png"),
                scheme: .light, requiresBoardBand: false)
            try renderInOffscreenWindow(view: PlanWorkflowDetailView(symbol: symbol, planID: completed.id, account: .financing).environment(appState),
                width: 650, height: 600, to: directory.appendingPathComponent("plans-filled-workflow-light.png"),
                scheme: .light, requiresBoardBand: false)
            try renderInOffscreenWindow(view: PlanEditorView(symbol: symbol, planID: pending.id,
                returnRoute: .planList, route: .constant(.planList), account: .financing).environment(appState),
                width: 520, height: 500, to: directory.appendingPathComponent("plans-pending-editor-light.png"),
                scheme: .light, requiresBoardBand: false)
            expect(store.syncSnapshot() == baseline, "plan-status", "browsing/rendering statuses must not write data")
            guard CommandLine.arguments.contains("--interactive-plan-status")
                || CommandLine.arguments.contains("--automated-plan-status") else { return }
            var timedOut = false
            try renderInOffscreenWindow(view: PlanListView(route: .constant(.planList)).environment(appState),
                width: 360, height: 620, to: directory.appendingPathComponent("plans-status-interactive-result.png"),
                scheme: .light, requiresBoardBand: false, inspect: { host in
                    guard let window = host.window else { return }
                    if CommandLine.arguments.contains("--automated-plan-status") {
                        NSApp.finishLaunching()
                        window.makeKey()
                        exerciseNativePlanFill(in: host)
                        return
                    }
                    window.styleMask = [.titled, .closable]
                    window.title = "FFF · 虚构计划状态验证"
                    window.setFrameOrigin(NSPoint(x: 340, y: 150))
                    NSApp.finishLaunching(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    print("PLAN_STATUS_INTERACTIVE_READY"); fflush(stdout)
                    let stop: @MainActor @Sendable () -> Void = {
                        NSApp.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                    }
                    let monitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            if store.tradePlanEntries.first(where: { $0.plan.id == pending.id })?.displayState == .filled { stop() }
                        }
                    }
                    let timeout = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
                        MainActor.assumeIsolated { timedOut = true; stop() }
                    }
                    NSApp.run(); monitor.invalidate(); timeout.invalidate()
                })
            expect(!timedOut, "plan-status-ui", "native record-fill interaction must complete")
            let result = store.tradePlanEntries.first { $0.plan.id == pending.id }
            expect(result?.displayState == .filled && result?.averageFillPrice == 106 && result?.filledQuantity == 100,
                "plan-status-ui", "recorded price must move pending plan into filled history")
            expect(store.tradePlanEntries.count == 8, "plan-status-ui", "no duplicate plans")
            try renderInOffscreenWindow(view: PlanListView(route: .constant(.planList), initialScope: .history).environment(appState),
                width: 340, height: 620, to: directory.appendingPathComponent("plans-history-after-fill.png"),
                scheme: .light, requiresBoardBand: false)
        } catch { report("plan-status-render", error.localizedDescription) }
    }

    /// Uses AppKit's accessibility actions against the real SwiftUI controls,
    /// inside this process and the offline fixture only. No desktop automation
    /// permissions and no real account or broker connection are involved.
    private static func exerciseNativePlanFill(in host: NSView) {
        // SwiftUI AX nodes implement the Objective-C selectors without always
        // declaring NSAccessibilityProtocol conformance. Keep those nodes too.
        func elements(_ root: AnyObject) -> [AnyObject] {
            var result: [AnyObject] = []
            var seen = Set<ObjectIdentifier>()
            func visit(_ element: AnyObject, depth: Int) {
                guard depth < 40, seen.insert(ObjectIdentifier(element)).inserted else { return }
                result.append(element)
                for child in element.accessibilityChildren?() ?? [] {
                    visit(child as AnyObject, depth: depth + 1)
                }
                if let view = element as? NSView {
                    for child in view.subviews { visit(child, depth: depth + 1) }
                }
            }
            visit(root, depth: 0)
            return result
        }
        func text(_ element: AnyObject, _ selector: String) -> String? {
            guard let object = element as? NSObject, object.responds(to: NSSelectorFromString(selector)) else { return nil }
            return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? String
        }
        func settle() {
            for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        func hasTitle(_ element: AnyObject, _ title: String) -> Bool {
            text(element, "accessibilityLabel") == title || text(element, "accessibilityTitle") == title
                || text(element, "accessibilityValue") == title
        }
        func click(_ view: NSView, at point: NSPoint) {
            guard let window = view.window else { return }
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
        }
        let buttonTitle = PulseLocalization.localizedString("plans.action.recordFill")
        if let button = elements(host).first(where: { text($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue && hasTitle($0, buttonTitle) }) {
            expect(button.accessibilityPerformPress?() == true, "plan-status-ui", "record-fill button must press")
        } else {
            // Offscreen SwiftUI may not publish AX children without an external
            // accessibility client. Send native events to the known fixture's
            // first row button instead; this never clicks the real desktop.
            click(host, at: NSPoint(x: host.bounds.width - 54, y: host.isFlipped ? 137 : host.bounds.height - 137))
        }
        settle()
        guard let sheet = host.window?.attachedSheet, let form = sheet.contentView else {
            report("plan-status-ui", "record-fill sheet did not open")
            return
        }
        if let field = elements(form).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "110" }) {
            field.stringValue = "106"
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        } else if let price = elements(form).first(where: {
            text($0, "accessibilityRole") == NSAccessibility.Role.textField.rawValue && text($0, "accessibilityValue") == "110"
        }) {
            price.setAccessibilityValue?("106")
        } else {
            report("plan-status-ui", "actual-price field not available")
            return
        }
        settle()
        if let save = elements(form).first(where: {
            text($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue && hasTitle($0, PulseLocalization.localizedString("plan.execution.record"))
        }) {
            expect(save.isAccessibilityEnabled?() == true && save.accessibilityPerformPress?() == true,
                "plan-status-ui", "save-fill button must be enabled and press")
        } else {
            click(form, at: NSPoint(x: form.bounds.width - 129, y: form.isFlipped ? form.bounds.height - 24 : 24))
        }
        settle()
        expect(host.window?.attachedSheet == nil, "plan-status-ui", "saved sheet must dismiss")
        // The caller checks the real stored price/quantity/state and captures
        // this same host after dismissal for the lead's native visual review.
    }

    /// Runs creation from the real list against isolated accounts. Selecting a
    /// symbol or cancelling a draft must leave all ledgers unchanged.
    private static func renderPlanCreation(appState: AppState, symbols: Fixture, into directory: URL) {
        var interactionAllowed: DarwinBoolean = true
        expect(SecKeychainGetUserInteractionAllowed(&interactionAllowed) == errSecSuccess
               && !interactionAllowed.boolValue,
               "development-keychain-policy", "local app must disable automatic Keychain prompts before initialization")
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        _ = appState.selectBrokerageAccount(.unassigned)
        let originalAccount = store.brokeragePortfolio(for: .unassigned)
        let financeAccount = store.brokeragePortfolio(for: .financing)
        guard let sourceItem = store.item(for: symbols.tactical) else {
            report("plan-create", "fixture symbol missing")
            return
        }
        let info = SymbolInfo(symbol: sourceItem.symbol, name: sourceItem.resolvedDisplayName,
                              type: sourceItem.resolvedInstrumentType ?? .equity)
        do {
            try renderInOffscreenWindow(
                view: MainPlanListView(route: .constant(.planList)).environment(appState),
                width: 1_240, height: 740,
                to: directory.appendingPathComponent("plan-list-create-light.png"),
                scheme: .light, requiresBoardBand: false)
            _ = appState.selectBrokerageAccount(.mengmeng)
            let baseline = store.syncSnapshot()
            try renderInOffscreenWindow(
                view: MainPlanListView(route: .constant(.planList)).environment(appState),
                width: 760, height: 640,
                to: directory.appendingPathComponent("plan-list-empty-create-dark.png"),
                scheme: .dark, requiresBoardBand: false)
            try renderInOffscreenWindow(
                view: PlanListView(route: .constant(.planList)).environment(appState),
                width: 340, height: 470,
                to: directory.appendingPathComponent("plan-compact-create-light.png"),
                scheme: .light, requiresBoardBand: false)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                try renderInOffscreenWindow(
                    view: NewTradePlanSheet(account: .mengmeng, onCreated: { _ in }, onClose: {})
                        .environment(appState),
                    width: 520, height: 560,
                    to: directory.appendingPathComponent("plan-create-choose-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
                try renderInOffscreenWindow(
                    view: NewTradePlanSheet(account: .mengmeng, initialSymbol: info,
                                           onCreated: { _ in }, onClose: {})
                        .environment(appState),
                    width: 520, height: 560,
                    to: directory.appendingPathComponent("plan-create-editor-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
            }
            expect(store.syncSnapshot() == baseline, "plan-create-render",
                   "opening the chooser or editor must not create a watch item or a plan")

            guard CommandLine.arguments.contains("--plan-create-interactive") else { return }
            var timedOut = false
            let view = MainPlanListView(route: .constant(.planList)).environment(appState)
            try renderInOffscreenWindow(view: view, width: 1_140, height: 740,
                to: directory.appendingPathComponent("plan-create-interactive-result.png"),
                scheme: .light, requiresBoardBand: false, inspect: { host in
                    guard let window = host.window else { return }
                    window.styleMask = [.titled, .closable]
                    window.title = "虚构新增计划入口测试"
                    window.setFrameOrigin(NSPoint(x: 260, y: 180))
                    NSApp.finishLaunching()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    print("PLAN_CREATE_INTERACTIVE_READY")
                    fflush(stdout)
                    let stop: @MainActor @Sendable () -> Void = {
                        NSApp.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                    }
                    let monitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            if !store.tradePlanEntries.isEmpty { stop() }
                        }
                    }
                    let timeout = Timer.scheduledTimer(withTimeInterval: 240, repeats: false) { _ in
                        MainActor.assumeIsolated { timedOut = true; stop() }
                    }
                    NSApp.run()
                    monitor.invalidate()
                    timeout.invalidate()
                    for _ in 0..<3 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                })
            expect(!timedOut, "plan-create-ui", "interactive creation must finish")
            let created = store.tradePlanEntries
            expect(created.count == 1 && created.first?.symbol == symbols.tactical,
                   "plan-create-ui", "the selected fictional symbol must own the only new plan")
            expect(created.first?.plan.price == 12.5 && created.first?.plan.quantity == 100
                   && created.first?.plan.kind == .buy && created.first?.plan.fundingSource == .own,
                   "plan-create-ui", "saved values and ordinary funding in Mengmeng must be preserved")
            expect(store.activeBrokerageAccountID == .mengmeng,
                   "plan-create-ui", "creation must keep its destination account")
            let savedItems = store.brokeragePortfolio(for: .mengmeng).items
            expect(savedItems.count == 1 && savedItems.first?.transactions.isEmpty == true,
                   "plan-create-ui", "cancelled drafts must leave no items, and plans must not record fills")
            expect(store.brokeragePortfolio(for: .unassigned) == originalAccount
                   && store.brokeragePortfolio(for: .financing) == financeAccount,
                   "plan-create-ui", "creation must not mutate other accounts")
        } catch { report("plan-create", error.localizedDescription) }
    }

    /// The production reconciliation form, including a real synthetic save.
    private static func renderReconciliationForm(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        _ = appState.selectBrokerageAccount(.unassigned)
        let symbol = SymbolID(market: .us, code: "RECONTEST")
        store.add(SymbolInfo(symbol: symbol, name: "虚构：核对交互样本"))
        store.addTransaction(symbol, .init(kind: .buy, price: 10, quantity: 12))
        var snapshot = store.syncSnapshot()
        guard let index = snapshot.items.firstIndex(where: { $0.symbol == symbol }) else {
            report("reconciliation", "missing fixture")
            return
        }
        let portions = (0..<4).map { index in
            PositionPortion(quantity: 4, pool: index == 1 ? .strategic : .tactical,
                origin: index < 2 ? .init(kind: .snapshot)
                    : .init(kind: .buy, transactionID: UUID(), date: .now, price: 10, quantity: 4),
                note: "Synthetic row \(index + 1)", fundingSource: index < 2 ? nil : .own,
                brokerageAccountID: index == 3 ? .unassigned : .financing)
        }
        snapshot.items[index].positionAllocation = .init(
            basisFingerprint: PositionAllocation.basisFingerprint(for: snapshot.items[index]), portions: portions)
        _ = store.applySyncSnapshot(snapshot)
        guard let item = store.item(for: symbol), let allocation = item.positionAllocation else {
            report("reconciliation", "fixture allocation missing")
            return
        }
        let baselineTrades = item.transactions
        let otherAccount = store.brokeragePortfolio(for: .mengmeng)
        let interactive = CommandLine.arguments.contains("--reconciliation-interactive")
        var didSave = false
        let view = PoolReconciliationSheet(item: item, allocation: allocation, account: .unassigned,
            onCancel: {}, onSuccess: {
                didSave = true
                if interactive {
                    NSApp.stop(nil)
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                }
            }).environment(appState)
        do {
            try renderInOffscreenWindow(view: view, width: 500, height: 540,
                to: directory.appendingPathComponent("reconciliation-editable.png"),
                scheme: .light, requiresBoardBand: false,
                inspect: { host in
                    guard interactive, let window = host.window else { return }
                    // The ordinary render window is deliberately inert. Give
                    // this interactive fixture a title bar so it can take keys.
                    window.styleMask = [.titled, .closable]
                    window.title = "虚构核对表单测试"
                    window.setFrameOrigin(NSPoint(x: 300, y: 250))
                    NSApp.finishLaunching()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    print("RECONCILIATION_INTERACTIVE_READY")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                        NSApp.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                    }
                    NSApp.run()
                })
            if interactive {
                expect(didSave, "reconciliation", "quantity edit with empty optional reason must save")
                let saved = store.item(for: symbol)
                expect(saved?.transactions == baselineTrades, "reconciliation", "reconciling must not modify trades")
                expect(saved?.positionQuantity == 12, "reconciliation", "ledger quantity must stay 12")
                expect(saved?.positionAllocation?.portions.count == 3, "reconciliation", "zero row must be removed")
                expect(saved?.positionAllocation?.portions.reduce(0, { $0 + $1.quantity }) == 12,
                       "reconciliation", "allocation total must become 12")
                expect(saved?.positionAllocationNeedsReconciliation == false, "reconciliation", "warning must clear after save")
                expect(saved?.positionAllocation?.changes.last?.reason.isEmpty == false,
                       "reconciliation", "optional reason must still create an audit description")
                expect(store.brokeragePortfolio(for: .mengmeng) == otherAccount,
                       "reconciliation", "another account must remain unchanged")
            }
        } catch { report("reconciliation", error.localizedDescription) }
    }

    /// Journal scope and reconciliation labels across synthetic accounts.
    private static func renderJournalAccounts(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        let symbol = SymbolID(market: .sh, code: "600000")
        store.withBrokerageAccount(.unassigned) {
            store.add(SymbolInfo(symbol: symbol, name: "虚构：账户核对样本"))
            store.addTransaction(symbol, .init(kind: .buy, price: 10, quantity: 600))
        }
        do {
            let fill = try store.recordBuyTransaction(symbol,
                .init(kind: .buy, price: 12, quantity: 100, fundingSource: .margin), account: .financing)
            _ = try store.recordBuyTransaction(symbol,
                .init(kind: .buy, price: 15, quantity: 200, fundingSource: .own), account: .mengmeng)
            _ = appState.selectBrokerageAccount(.mengmeng)
            let baseline = store.syncSnapshot()
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let view = TradeJournalView(onSelect: { _ in }, initialTransactionID: fill.id)
                    .environment(appState).environment(\.locale, PulseLocalization.currentLocale)
                try renderInOffscreenWindow(view: view, width: 1140, height: 900,
                    to: directory.appendingPathComponent("journal-accounts-\(suffix).png"),
                    scheme: scheme, requiresBoardBand: false)
            }
            expect(store.syncSnapshot() == baseline, "journal-accounts", "render must not mutate any ledger")
            expect(store.activeBrokerageAccountID == .mengmeng, "journal-accounts", "opening a financing review must not change global selection")

            // A stale card total must stay distinct from the real ledger quantity.
            var snapshot = store.syncSnapshot()
            if let index = snapshot.items.firstIndex(where: { $0.symbol == symbol }) {
                snapshot.items[index].positionAllocation?.portions[0].quantity = 800
                snapshot.items[index].positionAllocation?.portions[0].origin = .init(kind: .snapshot)
                _ = store.applySyncSnapshot(snapshot)
            }
            let pools = PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "CNY", mode: .symbol, showsPlanRail: false))
                .environment(appState)
            try renderInOffscreenWindow(view: pools, width: 1440, height: 900,
                to: directory.appendingPathComponent("pool-reconciliation-reasons.png"),
                scheme: .light, requiresBoardBand: false)
            let index = SymbolID(market: .sh, code: "000688")
            store.withBrokerageAccount(.unassigned) {
                store.add(SymbolInfo(symbol: index, name: "虚构：跨账户指数", type: .index))
            }
            expect(store.item(for: index) == nil && appState.sharedWatchlist.item(for: index)?.supportsPosition == false,
                   "index-identity", "the active empty ledger must retain shared index identity")
            let beforeIndexRender = store.syncSnapshot()
            try renderInOffscreenWindow(view: MainInstrumentView(symbol: index).environment(appState),
                width: 1140, height: 800, to: directory.appendingPathComponent("index-empty-account.png"),
                scheme: .light, requiresBoardBand: false)
            expect(store.syncSnapshot() == beforeIndexRender, "index-identity", "viewing an index must not create a holding")
        } catch { report("journal-accounts", error.localizedDescription) }
    }

    private static func renderPlanBuyForms(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        let symbol = SymbolID(market: .sz, code: "300223")
        let plan = TradePlan(kind: .buy, price: 125, quantity: 100, note: "Synthetic account fixture",
                             positionPool: .tactical, fundingSource: .margin)
        for account in BrokerageAccountID.allCases {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: symbol, name: "Synthetic instrument"))
                store.setTradePlan(plan, for: symbol)
            }
        }
        for account in BrokerageAccountID.allCases {
            _ = appState.selectBrokerageAccount(account)
            guard let entry = store.tradePlanEntries.first(where: { $0.plan.id == plan.id }) else {
                report("plan-buy", "stored fixture plan missing")
                continue
            }
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let baseline = store.syncSnapshot()
                let interactive = account == .unassigned && scheme == .dark
                    && CommandLine.arguments.contains("--plan-buy-interactive")
                let view = PlanExecutionSheet(entry: entry, account: account) {
                    if interactive {
                        print("PLAN_BUY_INTERACTIVE_SAVED")
                        fflush(stdout)
                        NSApp.stop(nil)
                        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                    }
                }.environment(appState).environment(\.locale, PulseLocalization.currentLocale)
                    .environment(\.colorScheme, scheme).frame(width: 470, height: 560)
                do {
                    try renderInOffscreenWindow(view: view, width: 470, height: 560,
                        to: directory.appendingPathComponent("plan-buy-\(account.rawValue)-\(suffix).png"),
                        scheme: scheme, requiresBoardBand: false, inspect: { host in
                            if interactive, let window = host.window {
                                window.styleMask = [.titled, .closable]
                                window.title = "虚构账户买入测试"
                                window.setFrameOrigin(NSPoint(x: 300, y: 250))
                                NSApp.finishLaunching()
                                window.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                                print("PLAN_BUY_INTERACTIVE_READY")
                                fflush(stdout)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                                    NSApp.stop(nil)
                                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(event, atStart: true) }
                                }
                                NSApp.run()
                            }
                        })
                    if interactive {
                        let source = store.brokeragePortfolio(for: .unassigned).items.first { $0.symbol == symbol }
                        let destination = store.brokeragePortfolio(for: .mengmeng).items.first { $0.symbol == symbol }
                        expect(source?.positionQuantity == 0 && destination?.positionQuantity == 100,
                               "plan-buy-ui", "the selected destination must own the actual fill")
                        expect(destination?.transactions.last?.fundingSource == .own
                            && destination?.transactions.last?.planExecution?.sourceAccountID == .unassigned,
                               "plan-buy-ui", "UI must clear margin and preserve source plan linkage")
                    } else {
                        expect(store.syncSnapshot() == baseline, "plan-buy-render", "drawing a form must not write a fill")
                    }
                    print("PLAN_BUY_RENDER \(account.rawValue) \(suffix)")
                } catch { report("plan-buy-render", error.localizedDescription) }
            }
        }
    }

    /// Production buy forms, rendered with disposable offline ledgers only.
    private static func renderBuyAccountForms(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        let info = MainWindowDemo.infos[0]
        for account in BrokerageAccountID.allCases {
            store.withBrokerageAccount(account) { store.add(info) }
        }
        for account in BrokerageAccountID.allCases {
            _ = appState.selectBrokerageAccount(account)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                let route = Binding<PopoverRoute>(get: { .trade(info.symbol, .buy, .list) }, set: { _ in })
                let view = TradeEntryView(symbol: info.symbol, side: .buy,
                    returnRoute: .list, route: route, account: account)
                    .environment(appState).environment(\.locale, PulseLocalization.currentLocale)
                    .environment(\.colorScheme, scheme).frame(width: 340, height: 390)
                let baseline = store.syncSnapshot()
                do {
                    try renderInOffscreenWindow(view: view, width: 340, height: 390,
                        to: directory.appendingPathComponent("trade-buy-\(account.rawValue)-\(suffix).png"),
                        scheme: scheme, requiresBoardBand: false,
                        inspect: { host in
                            if account == .financing && scheme == .dark,
                               CommandLine.arguments.contains("--trade-buy-interactive"), let window = host.window {
                                window.setFrameOrigin(NSPoint(x: 300, y: 250))
                                NSApp.finishLaunching()
                                window.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                                print("TRADE_BUY_INTERACTIVE_READY")
                                fflush(stdout)
                                // A short-lived synthetic window for native UI automation.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 80) {
                                    NSApp.stop(nil)
                                    if let event = NSEvent.otherEvent(with: .applicationDefined,
                                        location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                                        NSApp.postEvent(event, atStart: true)
                                    }
                                }
                                NSApp.run()
                                window.orderOut(nil)
                                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                            }
                        })
                    print("TRADE_BUY_RENDER \(account.rawValue) \(suffix)")
                } catch { report("trade-buy-render", error.localizedDescription) }
                expect(store.syncSnapshot() == baseline && store.activeBrokerageAccountID == account,
                       "trade-buy-render", "rendering must not change transactions or account selection")
            }
        }
    }

    private static func renderSharedWatchlist(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        store.enableBrokerageAccounts()
        guard let first = appState.sharedWatchlist.groups.first else {
            report("shared-watchlist", "fixture has no group")
            return
        }
        appState.sharedWatchlist.selectGroup(first.id)
        let baselineGroups = appState.sharedWatchlist.groups
        let baselineSymbols = appState.sharedWatchlist.items.map(\.symbol)
        for account in BrokerageAccountID.allCases {
            _ = appState.selectBrokerageAccount(account)
            let beforeRead = store.syncSnapshot()
            expect(appState.sharedWatchlist.groups == baselineGroups
                && appState.sharedWatchlist.items.map(\.symbol) == baselineSymbols,
                "shared-watchlist", "switching a financial account changed the watched list")
            expect(store.syncSnapshot() == beforeRead && store.activeBrokerageAccountID == account,
                "shared-watchlist", "reading the shared list changed a financial record")
            let view = PopoverRootView()
                .environment(appState).environment(\.pulseHost, .menuBar)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.colorScheme, .dark)
                .frame(width: 380, height: 600)
            do {
                try renderInOffscreenWindow(view: view, width: 380, height: 600,
                    to: directory.appendingPathComponent("shared-watchlist-\(account.rawValue).png"),
                    scheme: .dark, requiresBoardBand: false)
                print("SHARED_WATCHLIST_RENDER \(account.rawValue)")
            } catch { report("shared-watchlist-render", "\(error)") }
        }
        let symbol = SymbolID(market: .us, code: "ZZGLOBAL")
        for (account, quantity) in [(BrokerageAccountID.unassigned, 3.0), (.financing, 1.0), (.mengmeng, 2.0)] {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: symbol, name: "Global metric fixture"))
                store.addTransaction(symbol, .init(kind: .buy, price: 100, quantity: quantity))
            }
        }
        let quote = Quote(symbol: symbol, price: 150, previousClose: 145, timestamp: .now, marketState: .regular)
        let records = appState.sharedWatchlist.records(for: symbol)
        guard let item = records.first else { report("shared-metric", "missing fixture"); return }
        let amount = WatchRowMetricDisplay.resolve(quote: quote, metrics: nil, mode: .totalPnL,
            item: item, records: records)
        expect(amount.colorValue == 300, "shared-metric", "account amounts must sum without mixing trades")
        expect(records.map(\.positionQuantity) == [3, 1, 2],
               "shared-metric", "shared presentation must preserve independent ledgers")
    }

    private static func renderPoolTransferForms(appState: AppState, into directory: URL) {
        guard let original = appState.watchlist.allItems.first(where: { ($0.positionAllocation?.portions.first?.quantity ?? 0) >= 50 }),
              let originalAllocation = original.positionAllocation else {
            report("pool-transfer", "synthetic allocation missing")
            return
        }
        expect(PositionPoolsView.holdingTransferDestinations(from: .strategic) == [.tactical]
               && PositionPoolsView.holdingTransferDestinations(from: .tactical) == [.strategic]
               && PositionPoolsView.holdingTransferDestinations(from: .unassigned) == [.strategic, .tactical]
               && PositionPoolsView.holdingTransferDestinations(from: .observation) == [.strategic, .tactical],
               "pool-transfer", "holding destinations must be actual roles different from the source")
        let cases: [(String, PositionPool, PositionPool?, ColorScheme)] = [
            ("transfer-strategic-choose-light", .strategic, nil, .light),
            ("transfer-tactical-choose-dark", .tactical, nil, .dark),
            ("transfer-legacy-choose-light", .unassigned, nil, .light),
            ("transfer-invalid-unassigned-light", .strategic, .unassigned, .light),
            ("transfer-tactical-selected-light", .strategic, .tactical, .light),
            ("transfer-strategic-selected-dark", .tactical, .strategic, .dark)
        ]
        let baseline = appState.watchlist.syncSnapshot()
        for (name, source, destination, scheme) in cases {
            var item = original
            var allocation = originalAllocation
            allocation.portions[0].pool = source
            item.positionAllocation = allocation
            let view = PoolTransferSheet(item: item, portion: allocation.portions[0], allocation: allocation,
                initialDestination: destination, onCancel: {}, onSuccess: { _, _ in }, initialAmount: "25")
                .environment(appState).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: 460, height: 360)
            do {
                try renderInOffscreenWindow(view: view, width: 460, height: 360,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme, requiresBoardBand: false)
                print("TACTICAL_BOARD_RENDER \(name)")
            } catch { report("pool-transfer-render", error.localizedDescription) }
        }
        expect(appState.watchlist.syncSnapshot() == baseline,
               "pool-transfer-render", "rendering transfer choices must not change stored data")
    }

    private static func renderPoolHeaders(appState: AppState, into directory: URL) {
        guard let item = appState.watchlist.allItems.first(where: { $0.positionAllocation != nil }) else {
            report("pool-header", "synthetic allocation missing")
            return
        }
        let cases: [(String, CGFloat, ColorScheme, Bool, PositionPoolsView.Stance)] = [
            ("pool-header-wide-light-undo", 1440, .light, true, .current),
            ("pool-header-threshold-light-undo", 1180, .light, true, .current),
            ("pool-header-wide-dark-undo", 1440, .dark, true, .current),
            ("pool-header-narrow-light-undo", 1000, .light, true, .current),
            ("pool-header-wide-light-no-undo", 1440, .light, false, .current),
            ("pool-header-preview-dark-undo", 1180, .dark, true, .preview)
        ]
        let baseline = appState.watchlist.syncSnapshot()
        for (name, width, scheme, showsUndo, stance) in cases {
            let pools = PositionPoolsView(onSelect: { _ in }, tactical: .init(stance: stance, currencyFilter: "USD"))
            let view = (showsUndo ? pools.withUndoRenderFixture(item) : pools)
                .environment(appState).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: width, height: 900)
            do {
                try renderInOffscreenWindow(view: view, width: width, height: 900,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme)
                print("TACTICAL_BOARD_RENDER \(name)")
            } catch { report("pool-header-render", error.localizedDescription) }
        }
        expect(appState.watchlist.syncSnapshot() == baseline,
               "pool-header-render", "rendering the header must not change stored data")
    }

    private static func renderAccountTags(appState: AppState, into directory: URL) {
        appState.watchlist.enableBrokerageAccounts()
        let items = appState.watchlist.allItems.filter { $0.positionQuantity > 0 && $0.positionAllocation != nil }
        for (index, item) in items.enumerated() {
            guard let allocation = item.positionAllocation, let portion = allocation.portions.first else { continue }
            do {
                var current = allocation
                if index == 0, portion.quantity > 1 {
                    current = try appState.watchlist.transferPositionPortion(symbol: item.symbol, portionID: portion.id,
                        quantity: portion.quantity / 2, to: portion.pool == .tactical ? .strategic : .tactical,
                        reason: "", expectedRevision: current.revision)
                }
                for (offset, part) in current.portions.enumerated() {
                    current = try appState.watchlist.setPositionBrokerageAccount(symbol: item.symbol, portionID: part.id,
                        accountID: (index + offset) % 2 == 0 ? .financing : .mengmeng, expectedRevision: current.revision)
                    if part.fundingSource != .own {
                        current = try appState.watchlist.markPositionFundingSource(symbol: item.symbol,
                            portionID: part.id, quantity: part.quantity, source: .own,
                            reason: "Synthetic funding display", expectedRevision: current.revision)
                    }
                }
            } catch { report("account-tags", error.localizedDescription) }
        }
        let cases: [(String, CGFloat, ColorScheme, BrokerageAccountID?)] = [
            ("account-tags-all", 1440, .dark, nil),
            ("account-tags-financing", 1440, .dark, .financing),
            ("account-tags-narrow-light", 1000, .light, nil)
        ]
        let baseline = appState.watchlist.syncSnapshot()
        for (name, width, scheme, account) in cases {
            let view = PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD", accountFilter: account))
                .environment(appState).environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: width, height: 900)
            do {
                try renderInOffscreenWindow(view: view, width: width, height: 900,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme)
                print("TACTICAL_BOARD_RENDER \(name)")
            } catch { report("account-tags-render", error.localizedDescription) }
        }
        expect(appState.watchlist.syncSnapshot() == baseline,
               "account-tags-render", "rendering account-specific funding must not change stored data")
    }

    // MARK: - Fixture

    private static func assertPendingPlans(appState: AppState, symbols: Fixture) {
        guard let partial = appState.watchlist.tradePlanEntries.first(where: { $0.symbol == symbols.tactical }) else {
            report("pending-plans", "partial-fill fixture missing"); return
        }
        var done = partial.plan
        done.id = UUID()
        done.status = .done
        var cancelled = done
        cancelled.id = UUID()
        cancelled.status = .cancelled
        var filled = partial.plan
        filled.id = UUID()
        let fill = PositionTransaction(kind: .buy, price: filled.price, quantity: filled.quantity,
            planExecution: .init(planID: filled.id, configuration: .init(plan: filled)))
        let pending = PositionPoolsView.plans(in: .tactical, from: [partial,
            .init(symbol: symbols.tactical, plan: done),
            .init(symbol: symbols.tactical, plan: cancelled),
            .init(symbol: symbols.tactical, plan: filled, transactions: [fill])])
        expect(pending.map(\.id) == [partial.id] && pending.first?.remainingQuantity == 600,
               "pending-plans", "only the unfilled remainder may appear in pending; completed history must stay out")
    }

    /// Exercise the rendered shares with real buy/sell projections, including
    /// an unquoted future buy in the same pool as a priced holding.
    private static func assertPoolShares() {
        expect(!CapitalPanel.hasContent(.init(code: "USD"))
               && CapitalPanel.hasContent(.init(code: "USD", cashBalance: 0))
               && CapitalPanel.hasContent(.init(code: "USD", unvaluableQuantity: 1)),
               "pool-shares", "empty watched currencies must disappear while recorded zero cash and unknown holdings stay visible")
        let symbol = SymbolID(market: .us, code: "ZZSHARE")
        let unquoted = SymbolID(market: .us, code: "ZZFUTURE")
        let position = PoolBudgetProjection.Position(symbol: symbol, name: "Fictional share check",
            quantity: 100, price: 10, currencyCode: "USD",
            poolQuantities: [.strategic: 40, .tactical: 60])
        var buy = TradePlan(kind: .buy, price: 8, quantity: 50)
        buy.positionPool = .tactical
        var sell = TradePlan(kind: .sell, price: 12, quantity: 20)
        sell.positionPool = .strategic
        let result = PoolBudgetProjection.calculate(positions: [position], entries: [
            TradePlanEntry(symbol: symbol, plan: buy), TradePlanEntry(symbol: symbol, plan: sell)
        ], cash: ["USD": 0])
        guard let usd = result.currency("USD"),
              let strategic = usd.pools.first(where: { $0.pool == .strategic }),
              let tactical = usd.pools.first(where: { $0.pool == .tactical }) else {
            report("pool-shares", "fictional currency/pools missing"); return
        }
        expect(PoolBudgetGauge.currentShare(strategic, currency: usd) == 0.4
               && abs((PoolBudgetGauge.previewShare(strategic, currency: usd) ?? -1) - 200.0 / 1300) < 1e-9
               && abs((PoolBudgetGauge.previewShare(tactical, currency: usd) ?? -1) - 1100.0 / 1300) < 1e-9
               && tactical.limit == nil && usd.availableCash == -400,
               "pool-shares", "shares need independent before/after denominators, no cap, and no unsettled sell cash")

        var future = TradePlan(kind: .buy, price: 7, quantity: 10)
        future.positionPool = .strategic
        let incomplete = PoolBudgetProjection.calculate(positions: [position], entries: [
            TradePlanEntry(symbol: unquoted, plan: future)
        ])
        if let row = incomplete.currency("USD"), let pool = row.pools.first(where: { $0.pool == .strategic }) {
            expect(PoolBudgetGauge.currentShare(pool, currency: row) == 0.4
                   && PoolBudgetGauge.previewShare(pool, currency: row) == nil,
                   "pool-shares", "unquoted future buy must preserve the same pool's priced current share")
            var overflow = row
            overflow.hasOverflow = true
            expect(PoolBudgetGauge.currentShare(pool, currency: overflow) == nil
                   && PoolBudgetGauge.previewShare(pool, currency: overflow) == nil,
                   "pool-shares", "overflow must never produce percentages")
        } else { report("pool-shares", "missing unquoted-future result") }

        let missing = PoolBudgetProjection.Position(symbol: unquoted, name: "Fictional unquoted holding",
            quantity: 10, price: nil, currencyCode: "USD", poolQuantities: [.tactical: 10])
        if let row = PoolBudgetProjection.calculate(positions: [position, missing], entries: []).currency("USD"),
           let pool = row.pools.first(where: { $0.pool == .strategic }) {
            expect(PoolBudgetGauge.currentShare(pool, currency: row) == nil,
                   "pool-shares", "missing current price must not masquerade as a complete percentage")
        } else { report("pool-shares", "missing unquoted-holding result") }

        sell.positionPool = nil
        if let row = PoolBudgetProjection.calculate(positions: [position], entries: [
            TradePlanEntry(symbol: symbol, plan: sell)
        ]).currency("USD"), let pool = row.pools.first(where: { $0.pool == .strategic }) {
            expect(PoolBudgetGauge.currentShare(pool, currency: row) == 0.4
                   && PoolBudgetGauge.previewShare(pool, currency: row) == nil
                   && row.holdingsAfter == 800,
                   "pool-shares", "unknown future sale allocation must preserve current share and valid total value")
        } else { report("pool-shares", "missing unspecified sale result") }

        let empty = PoolBudgetProjection.Position(symbol: symbol, name: "Fictional first entry",
            quantity: 0, price: 10, currencyCode: "USD")
        if let row = PoolBudgetProjection.calculate(positions: [empty], entries: [
            TradePlanEntry(symbol: symbol, plan: buy)
        ]).currency("USD"), let pool = row.pools.first(where: { $0.pool == .tactical }) {
            expect(PoolBudgetGauge.currentShare(pool, currency: row) == nil
                   && PoolBudgetGauge.previewShare(pool, currency: row) == 1,
                   "pool-shares", "a first planned buy must show a preview share without inventing a current percentage")
        } else { report("pool-shares", "missing first-entry result") }

        let allStrategic = PoolBudgetProjection.Position(symbol: symbol, name: "Fictional liquidation",
            quantity: 100, price: 10, currencyCode: "USD", poolQuantities: [.strategic: 100])
        sell.quantity = 100
        sell.positionPool = .strategic
        if let row = PoolBudgetProjection.calculate(positions: [allStrategic], entries: [
            TradePlanEntry(symbol: symbol, plan: sell)
        ]).currency("USD"), let pool = row.pools.first(where: { $0.pool == .strategic }) {
            expect(PoolBudgetGauge.previewShare(pool, currency: row) == 0,
                   "pool-shares", "full liquidation must visibly become zero share")
        } else { report("pool-shares", "missing liquidation result") }
    }

    private struct Fixture {
        var groupID: WatchlistGroup.ID
        var tactical: SymbolID          // buy 1000 @10, filled 400, 200 split out
        var oversell: SymbolID          // asks to sell more than it holds
        var unpriced: SymbolID          // an active plan with no quote at all
        var noLimit: SymbolID           // held, but no pool limit configured
        var dualCurrency: SymbolID      // HKD holding in a USD-dominated pool
    }

    private static func assertFundingCoverage() {
        let usd = SymbolID(market: .us, code: "ZZFUND")
        let unknown = SymbolID(market: .us, code: "ZZUNKNOWN")
        let hkd = SymbolID(market: .hk, code: "ZZFUNHK")
        func card(_ symbol: SymbolID, _ quantity: Double, _ funding: PositionFundingSource?, review: Bool = false) -> PositionPoolsView.PortionCard {
            .init(item: .init(symbol: symbol, displayName: "Fictional funding"),
                portion: .init(quantity: quantity, pool: .tactical,
                    origin: .init(kind: .snapshot, quantity: quantity), fundingSource: funding), needsReview: review)
        }
        let cards = [card(usd, 2, .margin), card(usd, 8, .own), card(unknown, 4, .own),
                     card(usd, 5, .margin, review: true), card(hkd, 10, .margin)]
        let totals = PositionPoolsView.fundingSummaries(cards: cards, price: { $0 == unknown ? nil : 10 })
        let result = totals.first { $0.currency == "USD" }
        expect(result?.marketValue == 20 && result?.pricedDenominator == 100 && result?.share == 0.2
               && result?.unpricedCount == 1 && result?.reviewCount == 1,
               "funding-coverage", "unknown/review shares must be excluded and reported, including own-capital coverage")
        expect(totals.first { $0.currency == "HKD" }?.marketValue == 100,
               "funding-coverage", "funding currency totals cannot be added together")
    }

    /// The acceptance fixture from the spec, plus the honesty fixtures.
    ///
    /// `tactical`: plan buy 1000 @ 10 into the tactical pool. Record a 400 fill,
    /// then split 200 of that 400 to the strategic pool. The verified book must
    /// therefore read tactical 200 / strategic 200, with 600 still planned.
    private static func seedFixture(into state: AppState) -> Fixture {
        let tactical = SymbolID(market: .us, code: "ZZTAC")
        let oversell = SymbolID(market: .us, code: "ZZOVER")
        let unpriced = SymbolID(market: .us, code: "ZZNOPX")
        let noLimit = SymbolID(market: .us, code: "ZZNOLIM")
        let dualCurrency = SymbolID(market: .hk, code: "ZZHK")

        guard let groupID = state.watchlist.selectedGroup?.id else {
            report("fixture", "no selected group to seed into")
            return Fixture(groupID: UUID(), tactical: tactical, oversell: oversell,
                           unpriced: unpriced, noLimit: noLimit, dualCurrency: dualCurrency)
        }

        // `AppState` is constructed with `--main-window-demo`, which seeds its own
        // demo instruments during init. Those live in memory, not just in
        // defaults, so the isolated suite must be emptied through the store's own
        // APIs before the acceptance fixture is added — otherwise the board is
        // mostly unrelated demo plans and the tactical case is not the subject of
        // the render. Wiping through `remove`/`deleteTradePlan` keeps history and
        // allocation bookkeeping consistent, and the demo isolation flag itself
        // is untouched.
        for item in state.watchlist.allItems {
            for plan in item.plans {
                _ = state.watchlist.deleteTradePlan(plan.id, for: item.symbol)
            }
            state.watchlist.remove(item.symbol)
        }

        for (symbol, name) in [
            (tactical, "Fictional Tactical Co"),
            (oversell, "Fictional Oversell Co"),
            (unpriced, "Fictional Unquoted Co"),
            (noLimit, "Fictional Unbounded Co"),
            (dualCurrency, "Fictional Harbour Co"),
        ] {
            state.watchlist.add(SymbolInfo(symbol: symbol, name: name), to: groupID)
        }

        // The plan under test: 1000 shares at 10, assigned to the tactical pool.
        var plan = TradePlan(kind: .buy, price: 10, quantity: 1_000, note: "fictional tactical entry")
        plan.positionPool = .tactical
        _ = state.watchlist.setTradePlan(plan, for: tactical)

        // Record the 400 fill through the real store path so the plan's
        // execution link and the allocation revision move exactly as they do in
        // the app.
        if let stored = state.watchlist.item(for: tactical)?.plans.first(where: { $0.id == plan.id }) {
            do {
                try state.watchlist.recordTradePlanFill(
                    symbol: tactical,
                    planID: stored.id,
                    price: 10,
                    quantity: 400,
                    date: .now,
                    fee: 0,
                    note: "fictional partial fill",
                    transactionID: UUID(),
                    expectedPlanUpdatedAt: stored.updatedAt
                )
            } catch {
                report("fixture", "recordTradePlanFill failed: \(error)")
            }
        }

        // Split 200 of the verified 400 into the strategic pool, using the real
        // transfer API so the lineage reflects a genuine allocation.
        if let item = state.watchlist.item(for: tactical),
           let portion = item.positionAllocation?.portions.first(where: { $0.pool == .tactical }),
           let allocation = item.positionAllocation {
            do {
                try state.watchlist.transferPositionPortion(
                    symbol: tactical,
                    portionID: portion.id,
                    quantity: 200,
                    to: .strategic,
                    reason: "fictional strategy split",
                    expectedRevision: allocation.revision
                )
            } catch {
                report("fixture", "transferPositionPortion failed: \(error)")
            }
        }

        // Oversell fixture: a sell plan larger than the holding. The buy is
        // reconciled as a verified portion so the pool actually renders a card
        // for it instead of only warning.
        state.watchlist.addTransaction(oversell, PositionTransaction(kind: .buy, price: 20, quantity: 100, date: .now))
        reconcileAllocation(state, symbol: oversell, into: .unassigned)
        var sellPlan = TradePlan(kind: .sell, price: 25, quantity: 500, note: "fictional oversell")
        sellPlan.positionPool = .tactical
        _ = state.watchlist.setTradePlan(sellPlan, for: oversell)

        // Unpriced fixture: an active plan for a symbol with no quote at all.
        var unpricedPlan = TradePlan(kind: .buy, price: 7, quantity: 300, note: "fictional unquoted plan")
        unpricedPlan.positionPool = .unassigned
        unpricedPlan.conditions = [
            TradePlanCondition(title: "虚构：等季报确认后再加仓", kind: .manual, state: .needsReview)
        ]
        _ = state.watchlist.setTradePlan(unpricedPlan, for: unpriced)

        // No-limit fixture: a real holding, deliberately left without a pool
        // limit so the capacity bar must not appear for it. It is reconciled so
        // it renders as a real card, and its amount is kept well away from the
        // acceptance figures so it cannot mask a tactical/strategic error.
        state.watchlist.addTransaction(noLimit, PositionTransaction(kind: .buy, price: 12, quantity: 250, date: .now))
        reconcileAllocation(state, symbol: noLimit, into: .unassigned)

        // A second currency in the same pools, so the per-currency header lines
        // are exercised: a pool holding both USD and HKD must show two rows and
        // must never add them together.
        state.watchlist.addTransaction(dualCurrency, PositionTransaction(kind: .buy, price: 30, quantity: 100, date: .now))
        reconcileAllocation(state, symbol: dualCurrency, into: .strategic)
        var dualPlan = TradePlan(kind: .buy, price: 32, quantity: 200, note: "fictional second-currency buy")
        dualPlan.positionPool = .strategic
        _ = state.watchlist.setTradePlan(dualPlan, for: dualCurrency)

        // Conditions on the acceptance plan, so the condition chip and the
        // plan card's condition list have something real to show.
        if let stored = state.watchlist.item(for: tactical)?.plans.first(where: { $0.id == plan.id }) {
            var withConditions = stored
            withConditions.conditions = [
                TradePlanCondition(title: "虚构：回踩 9.5 再加", kind: .logic, state: .pending),
                TradePlanCondition(title: "虚构：财报后复核", kind: .manual, state: .needsReview,
                                   reviewDate: Date().addingTimeInterval(-86_400)),
            ]
            _ = state.watchlist.setTradePlan(withConditions, for: tactical)
        }

        // Quotes for everything except `unpriced`, which must stay unknown.
        state.market.apply(quotes: [
            Quote(symbol: tactical, name: "Fictional Tactical Co", price: 12, previousClose: 11.8,
                  open: 11.9, high: 12.1, low: 11.7, volume: 10_000, turnover: 120_000,
                  currencyCode: "USD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now),
            Quote(symbol: oversell, name: "Fictional Oversell Co", price: 22, previousClose: 21,
                  open: 21.5, high: 22.5, low: 21.2, volume: 4_000, turnover: 88_000,
                  currencyCode: "USD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now),
            Quote(symbol: noLimit, name: "Fictional Unbounded Co", price: 12, previousClose: 12,
                  open: 12, high: 12.2, low: 11.8, volume: 2_000, turnover: 24_000,
                  currencyCode: "USD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now),
            Quote(symbol: dualCurrency, name: "Fictional Harbour Co", price: 31, previousClose: 30.5,
                  open: 30.8, high: 31.4, low: 30.6, volume: 3_000, turnover: 93_000,
                  currencyCode: "HKD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now),
        ])

        // Cash and limits, written through the real settings store. USD is left
        // deliberately short so the quantified "缺口" chip has a real amount to
        // print. HKD is fully funded so the two states can be compared, and the
        // no-limit pool is left unset on purpose.
        let settings = state.poolBudgets
        settings.setCashBalance(amount: 2_000, currency: "USD")
        settings.setCashBalance(amount: 80_000, currency: "HKD")
        settings.setPoolLimit(amount: 5_000, currency: "USD", pool: .tactical)
        settings.setPoolLimit(amount: 4_000, currency: "USD", pool: .strategic)
        settings.setPoolLimit(amount: 90_000, currency: "HKD", pool: .strategic)

        return Fixture(groupID: groupID, tactical: tactical, oversell: oversell,
                       unpriced: unpriced, noLimit: noLimit, dualCurrency: dualCurrency)
    }

    /// Moves a freshly recorded buy out of `.unassigned` into a real pool, so the
    /// position has a verified allocation to draw. Without this the pool shows
    /// the reconciliation notice instead of a card. Each transfer runs through
    /// the real store API, so the revision and origins stay consistent.
    private static func reconcileAllocation(_ state: AppState, symbol: SymbolID, into pool: PositionPool) {
        guard pool != .unassigned else { return }
        // Re-read the allocation each pass: every transfer mints a new revision.
        var guardCount = 0
        while guardCount < 8,
              let item = state.watchlist.item(for: symbol),
              let allocation = item.positionAllocation,
              let portion = allocation.portions.first(where: { $0.pool == .unassigned }) {
            guardCount += 1
            do {
                try state.watchlist.transferPositionPortion(
                    symbol: symbol,
                    portionID: portion.id,
                    quantity: portion.quantity,
                    to: pool,
                    reason: "fictional reconciliation",
                    expectedRevision: allocation.revision
                )
            } catch {
                report("fixture", "reconcile \(symbol.displayCode) failed: \(error)")
                return
            }
        }
    }

    // MARK: - Assertions

    /// The calculator is the single source of truth, so assert on its result
    /// directly rather than on any view code.
    private static func assertProjectionMath(appState: AppState, symbols: Fixture) {
        let input = PoolBudgetInput(appState: appState, currencyFilter: "*")
        let result = input.calculate()

        guard let usd = result.currency("USD") else {
            report("projection", "USD projection missing entirely")
            return
        }
        guard let tactical = usd.pools.first(where: { $0.pool == .tactical }) else {
            report("projection", "tactical pool projection missing")
            return
        }
        guard let strategic = usd.pools.first(where: { $0.pool == .strategic }) else {
            report("projection", "strategic pool projection missing")
            return
        }

        // Verified book: 200 tactical + 200 strategic, and 600 still planned.
        expect(abs(tactical.heldAmount - 2_400) < 0.01,
               "projection", "tactical held should be 200 shares × 12 = 2400, got \(tactical.heldAmount)")
        expect(abs(strategic.heldAmount - 2_400) < 0.01,
               "projection", "strategic held should be 200 shares × 12 = 2400, got \(strategic.heldAmount)")
        expect(abs(tactical.plannedBuyAmount - 6_000) < 0.01,
               "projection", "tactical planned buys should be 600 × 10 = 6000, got \(tactical.plannedBuyAmount)")

        // Unpriced plans must be counted, never valued at zero.
        expect(result.unvaluablePriceCount > 0,
               "projection", "expected at least one unpriced plan, calculator reported none")

        // The oversell must be warned about, not silently turned into a short.
        expect(result.overSellWarnings.contains { $0.symbol == symbols.oversell },
               "projection", "expected an oversell warning for \(symbols.oversell.displayCode)")
    }

    /// Lineage: the fills under the tactical plan, and the split that moved 200
    /// of them to the strategic pool.
    private static func assertLineage(appState: AppState, symbols: Fixture) {
        guard let item = appState.watchlist.item(for: symbols.tactical) else {
            report("lineage", "tactical item vanished")
            return
        }
        let allocation = item.positionAllocation
        expect(allocation != nil, "lineage", "expected an allocation after recording a fill")

        let tacticalPortions = allocation?.portions.filter { $0.pool == .tactical } ?? []
        let strategicPortions = allocation?.portions.filter { $0.pool == .strategic } ?? []
        let tacticalQuantity = tacticalPortions.reduce(0) { $0 + $1.quantity }
        let strategicQuantity = strategicPortions.reduce(0) { $0 + $1.quantity }

        expect(abs(tacticalQuantity - 200) < 1e-6,
               "lineage", "tactical portion should be 200, got \(tacticalQuantity)")
        expect(abs(strategicQuantity - 200) < 1e-6,
               "lineage", "strategic portion should be 200, got \(strategicQuantity)")

        // Both portions must trace back to a real transaction: the split keeps
        // the originating fill rather than inventing a new source.
        let origins = Set((allocation?.portions ?? []).compactMap(\.origin.transactionID))
        expect(!origins.isEmpty, "lineage", "portions should keep a transaction origin")

        // The plan's own execution link must point at a real ledger entry.
        guard let entry = appState.watchlist.tradePlanEntries.first(where: { $0.symbol == symbols.tactical && $0.id == planID(in: appState, symbol: symbols.tactical) }) else {
            report("lineage", "tactical plan entry missing from tradePlanEntries")
            return
        }
        expect(abs(entry.filledQuantity - 400) < 1e-6,
               "lineage", "filled quantity should be 400, got \(entry.filledQuantity)")
        expect(abs(entry.remainingQuantity - 600) < 1e-6,
               "lineage", "remaining quantity should be 600, got \(entry.remainingQuantity)")

        // A `TradePlanEntry` carries only the plan and its progress — no
        // transactions. The lineage reaches the real fills through the item,
        // matching on the plan execution link or the legacy fill id, exactly as
        // `PositionPoolsView.lineage(for:)` does.
        let matched = item.materializedTransactions().filter { transaction in
            transaction.planExecution?.planID == entry.id
                || (entry.plan.filledTransactionID != nil && entry.plan.filledTransactionID == transaction.id)
        }
        expect(matched.count == 1,
               "lineage", "expected exactly one matched fill for the plan, got \(matched.count)")
        expect(abs((matched.first?.quantity ?? 0) - 400) < 1e-6,
               "lineage", "the matched fill should be the 400-share buy, got \(matched.first?.quantity ?? 0)")

        // The split portion must trace back to that same matched fill.
        let originIDs = Set((allocation?.portions ?? []).compactMap(\.origin.transactionID))
        expect(!originIDs.isDisjoint(with: Set(matched.map(\.id))),
               "lineage", "the split portion should originate from the matched fill")
    }

    /// The renders are only meaningful if the fixture actually populates the
    /// board: an empty or demo-dominated watchlist produced the first review's
    /// blank/irrelevant images. Assert the acceptance setup directly.
    private static func assertFixtureCoversBoard(appState: AppState, symbols: Fixture) {
        let items = appState.watchlist.allItems
        expect(items.count == 5,
               "fixture", "expected exactly the five fictional instruments, got \(items.count)")

        for symbol in [symbols.tactical, symbols.oversell, symbols.unpriced,
                       symbols.noLimit, symbols.dualCurrency] {
            expect(appState.watchlist.item(for: symbol) != nil,
                   "fixture", "\(symbol.displayCode) missing from the watchlist")
        }

        // Every pool the board draws must have something in it, otherwise a
        // column renders as "-" and the review cannot judge the card layout.
        let result = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        for code in ["USD", "HKD"] {
            guard let currency = result.currency(code) else {
                report("fixture", "\(code) projection missing")
                continue
            }
            let populated = currency.pools.filter { $0.heldAmount > 0 || $0.plannedBuyAmount > 0 }
            expect(!populated.isEmpty,
                   "fixture", "\(code) has no pool with a holding or a plan to render")
        }

        // Two currencies must coexist so the per-currency header lines are
        // exercised rather than theoretical.
        expect(result.currencies.count >= 2,
               "fixture", "expected at least two currencies, got \(result.currencies.count)")

        // A quantified shortfall and an unknown balance must both be present, so
        // the two gap labels can be told apart in the render.
        if let usd = result.currency("USD") {
            expect(usd.cashBalance != nil, "fixture", "USD cash should be recorded for the shortfall case")
            expect(usd.cashShortfall > 0, "fixture", "USD should be short so the gap chip carries an amount")
        }
    }

    /// The rehearsal is read-only: entering preview, ticking plans, and lighting
    /// highlights must leave the ledger and the allocation byte-identical.
    private static func assertPreviewDoesNotMutate(appState: AppState, symbols: Fixture) {
        let beforeTransactions = appState.watchlist.item(for: symbols.tactical)?.materializedTransactions() ?? []
        let beforeAllocation = appState.watchlist.item(for: symbols.tactical)?.positionAllocation
        let beforeStoreRevision = beforeAllocation?.revision
        let beforePlanPool = appState.watchlist.item(for: symbols.tactical)?.plans.first?.positionPool

        // Recompute the projection over an explicit subset — this is what the
        // preview does — and confirm no write occurred.
        let planIDs = Set(appState.watchlist.tradePlanEntries.map(\.id))
        let previewInput = PoolBudgetInput(appState: appState, currencyFilter: "*", planIDs: planIDs)
        _ = previewInput.calculate()

        let afterTransactions = appState.watchlist.item(for: symbols.tactical)?.materializedTransactions() ?? []
        let afterAllocation = appState.watchlist.item(for: symbols.tactical)?.positionAllocation
        let afterPlanPool = appState.watchlist.item(for: symbols.tactical)?.plans.first?.positionPool

        expect(afterTransactions.count == beforeTransactions.count,
               "preview", "preview changed the transaction count")
        expect(afterAllocation?.revision == beforeStoreRevision,
               "preview", "preview changed the allocation revision")
        expect(afterAllocation?.portions.count == beforeAllocation?.portions.count,
               "preview", "preview changed the portion count")
        expect(afterPlanPool == beforePlanPool,
               "preview", "preview moved a plan between pools")
    }

    /// The preview selection is the whole point of the rehearsal, so exercise the
    /// shared input the board actually uses: the same `planIDs` argument
    /// `PositionPoolsView.boardInput` passes. The previous version filtered an
    /// unrelated array and recalculated identical inputs, so it could not fail.
    private static func assertSelectionAndHighlight(appState: AppState, symbols: Fixture) {
        let entries = appState.watchlist.tradePlanEntries
        guard let tacticalEntry = entries.first(where: { $0.symbol == symbols.tactical }) else {
            report("selection", "no tactical plan entry to select")
            return
        }

        func usdBuy(_ result: PoolBudgetProjection.Result) -> Double {
            result.currency("USD")?.pools.reduce(0) { $0 + $1.plannedBuyAmount } ?? 0
        }

        // Every active plan: both buys are counted.
        let all = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        expect(abs(usdBuy(all) - 8_100) < 0.01,
               "selection", "all active USD buys should total 8100, got \(usdBuy(all))")

        // Only the tactical plan: the strategic plan must drop out. This is the
        // subset the preview passes through the same argument the view uses.
        let tacticalOnly = PoolBudgetInput(appState: appState, currencyFilter: "*",
                                           planIDs: [tacticalEntry.id]).calculate()
        expect(abs(usdBuy(tacticalOnly) - 6_000) < 0.01,
               "selection", "tactical-only USD buys should total 6000, got \(usdBuy(tacticalOnly))")

        // Explicitly empty is a real answer, not "all": the subset must not fall
        // back to the full board.
        let empty = PoolBudgetInput(appState: appState, currencyFilter: "*", planIDs: []).calculate()
        expect(abs(usdBuy(empty)) < 0.01,
               "selection", "an explicit empty selection must project no buys, got \(usdBuy(empty))")

        // The same result object feeds the value row, the gauge and the capital
        // panel, so consuming it must not change it.
        expect(abs(usdBuy(tacticalOnly) - 6_000) < 0.01,
               "selection", "re-reading the shared result altered it")

        // The rehearsal reads the store: none of the above may persist.
        let after = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        expect(currencyTotals(after) == currencyTotals(all),
               "selection", "selecting a preview subset changed the stored plans")
        expect(abs(usdBuy(after) - 8_100) < 0.01,
               "selection", "the store's plan set changed after a preview calculation")

        assertPendingSummaryFollowsSelection(appState: appState,
                                             tacticalEntry: tacticalEntry,
                                             symbols: symbols)
        assertVisiblePoolsHidesOnlyEmptyUnassigned()
    }

    private static func assertVisiblePoolsHidesOnlyEmptyUnassigned() {
        let symbol = SymbolID(market: .us, code: "ZZVIS")
        let item = WatchItem(symbol: symbol, displayName: "Fictional Visibility Co")
        let card = PositionPoolsView.PortionCard(
            item: item,
            portion: PositionPortion(quantity: 100, pool: .unassigned,
                                     origin: .init(kind: .snapshot)),
            needsReview: false)
        var plan = TradePlan(kind: .buy, price: 10, quantity: 100)
        func pools(_ entries: [TradePlanEntry]) -> [PositionPool] {
            PositionPoolsView.visiblePools(cards: [], entries: entries)
        }
        expect(pools([]) == [.strategic, .tactical],
               "visiblePools", "empty unassigned must hide; other pools must remain")
        expect(PositionPoolsView.visiblePools(cards: [card], entries: []).count == 3,
               "visiblePools", "an unassigned holding must keep its column")
        expect(pools([TradePlanEntry(symbol: symbol, plan: plan)]).count == 2,
               "visiblePools", "a nil-pool plan belongs in the library, not the unassigned pool")
        plan.positionPool = .unassigned
        expect(pools([TradePlanEntry(symbol: symbol, plan: plan)]).count == 3,
               "visiblePools", "an explicitly unassigned plan must keep its column")
        plan.status = .done
        expect(pools([TradePlanEntry(symbol: symbol, plan: plan)]).count == 2,
               "visiblePools", "an inactive plan must not keep unassigned")
        plan.status = .active
        plan.positionPool = .strategic
        expect(pools([TradePlanEntry(symbol: symbol, plan: plan)]).count == 2,
               "visiblePools", "plans elsewhere must not resurrect unassigned")
        expect(PositionPoolsView.visiblePools(cards: [], entries: [], dragSourcePool: .unassigned).count == 3,
               "visiblePools", "an outgoing drag must retain its source until settlement")
    }

    /// The pool header's pending summary must describe the *budget-selected* set,
    /// not every card on the board. The board deliberately keeps excluded cards
    /// visible in preview, so reading the summary off the card list made a
    /// tactical-only rehearsal still announce the unselected HKD, unquoted and
    /// sell plans.
    ///
    /// This drives the same two helpers the view calls — `plans(in:from:)` over
    /// `PoolBudgetInput.entries`, then `planTotals` — so it fails if the wiring
    /// regresses to the card list.
    private static func assertPendingSummaryFollowsSelection(appState: AppState,
                                                            tacticalEntry: TradePlanEntry,
                                                            symbols: Fixture) {
        func headerSummary(_ input: PoolBudgetInput,
                           pool: PositionPool) -> (buy: Double, sell: Double, currencies: [String]) {
            let selected = PositionPoolsView.plans(in: pool, from: input.entries)
            let groups = PositionPoolsView.planTotals(selected, currency: { $0.currencyCode.uppercased() })
            return (groups.reduce(0) { $0 + $1.buy },
                    groups.reduce(0) { $0 + $1.sell },
                    groups.map(\.currency))
        }

        // Explicit empty preview: no pending lines at all. A fallback to the
        // board's cards would produce figures here.
        let emptyInput = PoolBudgetInput(appState: appState, currencyFilter: "*", planIDs: [])
        for pool in PositionPool.activeCases {
            let summary = headerSummary(emptyInput, pool: pool)
            expect(summary.buy == 0 && summary.sell == 0 && summary.currencies.isEmpty,
                   "summary", "empty preview still summarised \(pool.title): \(summary)")
        }

        // Tactical-only preview: the tactical column reports its 6000 buy and
        // nothing else — no HKD buy, no unquoted buy, no sell proceeds.
        let tacticalInput = PoolBudgetInput(appState: appState, currencyFilter: "*",
                                            planIDs: [tacticalEntry.id])
        let tactical = headerSummary(tacticalInput, pool: .tactical)
        expect(abs(tactical.buy - 6_000) < 0.01,
               "summary", "tactical-only preview should show 6000 pending, got \(tactical.buy)")
        expect(tactical.currencies == ["USD"],
               "summary", "tactical-only preview leaked currencies: \(tactical.currencies)")

        // No other column may claim a pending amount while it is unselected.
        for pool in PositionPool.activeCases where pool != .tactical {
            let summary = headerSummary(tacticalInput, pool: pool)
            expect(summary.buy == 0 && summary.sell == 0,
                   "summary", "unselected \(pool.title) still showed a pending total: \(summary)")
        }

        // The sell fixture asks for 500 of a 100-share position, so the
        // calculator flags it. Selecting only it must never make the header
        // report its plan-priced amount as recoverable proceeds — the view drops
        // warned sells from the "拟回收" figure before formatting.
        let oversellEntry = appState.watchlist.tradePlanEntries
            .first { $0.symbol == symbols.oversell }
        if let oversellEntry {
            let oversellInput = PoolBudgetInput(appState: appState, currencyFilter: "*",
                                                planIDs: [oversellEntry.id])
            let result = oversellInput.calculate()
            expect(result.overSellWarnings.contains { $0.planID == oversellEntry.id },
                   "summary", "the oversell fixture should be flagged by the calculator")

            // Apply the view's own deliverability rule to the same entries.
            let warned = Set(result.overSellWarnings.map(\.planID))
            let deliverable = PositionPoolsView.plans(in: .tactical, from: oversellInput.entries)
                .filter { !warned.contains($0.id) }
            let groups = PositionPoolsView.planTotals(deliverable,
                                                      currency: { $0.currencyCode.uppercased() })
            expect(groups.allSatisfy { $0.sell == 0 },
                   "summary", "a flagged oversell was totalled as sell proceeds: \(groups)")
            expect(oversellEntry.remainingEstimatedAmount > 0,
                   "summary", "fixture sanity: the oversell plan should have a plan-priced amount")
        } else {
            report("summary", "no oversell plan entry in the isolated suite")
        }
    }

    /// Honesty checks for the states the spec calls out by name.
    private static func assertMissingKnowledgeIsHonest(appState: AppState, symbols: Fixture) {
        let result = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()

        // No limit configured ⇒ the calculator must not invent one.
        let settings = appState.poolBudgets
        let limit = settings.poolLimit(currency: "USD", pool: .observation)
        expect(limit == nil, "honesty", "expected no configured observation limit in the isolated suite")

        // An unpriced symbol must be reported as unpriced, not as zero value.
        expect(result.unvaluablePriceCount > 0,
               "honesty", "unpriced plans must be counted, never valued at zero")

        // Unknown cash must stay unknown rather than defaulting to a number.
        // `cashBalance` returns nil for "never recorded", which is not zero.
        let recordedCash = settings.cashBalance(currency: "USD")
        expect(settings.setCashBalance(amount: nil, currency: "USD"),
               "honesty", "could not clear the isolated cash fixture")
        let unknownCash = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        expect(unknownCash.currency("USD")?.cashBalance == nil,
               "honesty", "unrecorded USD cash must stay unknown in the actual board input")
        expect(settings.setCashBalance(amount: recordedCash?.amount, currency: "USD"),
               "honesty", "could not restore the isolated cash fixture")

        // An oversell is a warning with a shortfall, never a negative position.
        if let warning = result.overSellWarnings.first(where: { $0.symbol == symbols.oversell }) {
            expect(warning.shortfall > 0,
                   "honesty", "oversell warning should carry a positive shortfall, got \(warning.shortfall)")
            expect(warning.requested > warning.available,
                   "honesty", "oversell warning should request more than is available")
        } else {
            report("honesty", "expected an oversell warning for \(symbols.oversell.displayCode)")
        }
    }

    /// The board must group money by the instrument's own currency, which is what
    /// the calculator uses. A provider reporting a different quote currency must
    /// not move a row into another currency's totals.
    private static func assertQuoteCurrencyCannotOverride(appState: AppState, symbols: Fixture) {
        let symbol = symbols.tactical
        guard let original = appState.market.quote(for: symbol) else {
            report("currency", "no quote to perturb for \(symbol.displayCode)")
            return
        }

        let before = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        let beforeUsd = before.currency("USD")?.pools.reduce(0) { $0 + $1.plannedBuyAmount } ?? 0

        // A deliberately wrong quote currency, applied then restored.
        var wrong = original
        wrong.currencyCode = "HKD"
        appState.market.apply(quotes: [wrong])
        let during = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        let duringUsd = during.currency("USD")?.pools.reduce(0) { $0 + $1.plannedBuyAmount } ?? 0
        appState.market.apply(quotes: [original])

        expect(abs(duringUsd - beforeUsd) < 0.01,
               "currency", "a wrong quote currency moved USD buys: \(beforeUsd) -> \(duringUsd)")
        expect(symbol.currencyCode == "USD",
               "currency", "the instrument's authoritative currency should stay USD")

        let restored = PoolBudgetInput(appState: appState, currencyFilter: "*").calculate()
        expect(currencyTotals(restored) == currencyTotals(before),
               "currency", "restoring the quote did not restore the projection")
    }

    /// The central preview guard is the only thing standing between a rehearsal
    /// and a real write, so assert its policy directly rather than re-deriving it.
    private static func assertSheetPolicyBlocksWrites() {
        expect(PositionPoolsView.Sheet.isMutating(.verification(.init(symbol: SymbolID(market: .us, code: "ZZTAC"), portionID: UUID()))),
               "sheets", "verification editing must be blocked during preview")
        // Every sheet that can reach the store must be refused in preview. The
        // cases needing an associated value are reached through the same
        // central policy the view consults.
        expect(PositionPoolsView.Sheet.isMutating(.plan(SymbolID(market: .us, code: "ZZTAC"), UUID())),
               "guard", "the plan editor writes and must be refused")
        expect(PositionPoolsView.Sheet.isMutating(.execution(SymbolID(market: .us, code: "ZZTAC"), UUID())),
               "guard", "recording a fill writes to the ledger and must be refused")
        expect(PositionPoolsView.Sheet.isMutating(.reconcile(SymbolID(market: .us, code: "ZZTAC"))),
               "guard", "reconciling rewrites the allocation and must be refused")
        expect(PositionPoolsView.Sheet.isMutating(.syncConflict("peer")),
               "guard", "resolving a conflict writes and must be refused")
        // The workflow sheet edits a plan's conditions and writes it back, so it
        // is a write path even though it reads like an inspector.
        expect(PositionPoolsView.Sheet.isMutating(.workflow(SymbolID(market: .us, code: "ZZTAC"), UUID())),
               "guard", "the workflow sheet edits conditions and must be refused in preview")
        // The scenario sheet stores names, not money, and stays available.
        expect(!PositionPoolsView.Sheet.isMutating(.scenario),
               "guard", "saving a scenario must stay allowed in preview")
    }

    // MARK: - Renders

    private static func renderAuditArtifacts(appState: AppState, symbols: Fixture, into directory: URL) {
        let language = PulseLocalization.currentLanguageIdentifier
        for page in [MainWorkspacePage.workbench, .events, .holdings, .positionPools] {
            let view = MainWindowView(initialPage: page)
                .environment(appState).environment(\.locale, PulseLocalization.currentLocale)
                .environment(\.colorScheme, .dark)
                .frame(width: 1200, height: 820)
            do {
                try renderInOffscreenWindow(view: view, width: 1200, height: 820,
                    to: directory.appendingPathComponent("audit-\(language)-\(page.rawValue).png"),
                    scheme: .dark, requiresBoardBand: false)
                print("AUDIT_UI_RENDER \(language) \(page.rawValue)")
            } catch { report("audit-render", "\(language) \(page.rawValue): \(error)") }
        }
        _ = appState.watchlist.enableBrokerageAccounts()
        _ = appState.selectBrokerageAccount(.financing)
        let route = Binding<PopoverRoute>(get: { .trade(symbols.tactical, .buy, .list) }, set: { _ in })
        let forms: [(String, AnyView)] = [
            ("trade-notice", AnyView(TradeEntryView(symbol: symbols.tactical, side: .buy,
                returnRoute: .list, route: route, account: .unassigned))),
            ("plan-notice", AnyView(PlanEditorView(symbol: symbols.tactical,
                planID: appState.watchlist.draftItem(for: symbols.tactical, account: .unassigned)?.plans.first?.id,
                returnRoute: .list, route: route, account: .unassigned)))
        ]
        for (name, form) in forms {
            let view = form.environment(appState).environment(\.locale, PulseLocalization.currentLocale)
                .environment(\.colorScheme, .dark).frame(width: 340, height: 470)
            do {
                try renderInOffscreenWindow(view: view, width: 340, height: 470,
                    to: directory.appendingPathComponent("audit-\(language)-\(name).png"),
                    scheme: .dark, requiresBoardBand: false)
                print("AUDIT_UI_RENDER \(language) \(name)")
            } catch { report("audit-render", "\(language) \(name): \(error)") }
        }
    }

    private static func renderSystemArtifacts(appState: AppState, symbols: Fixture, into directory: URL) {
        guard let renderDefaults = UserDefaults(suiteName: MainWindowDemo.userDefaultsSuite) else {
            report("system-fixture", "isolated render defaults unavailable"); return
        }
        // Extend the isolated fixture only after the original financial checks.
        if let allocation = appState.watchlist.item(for: symbols.tactical)?.positionAllocation,
           let portion = allocation.portions.first(where: { $0.pool == .tactical }) {
            do {
                _ = try appState.watchlist.markPositionFundingSource(symbol: symbols.tactical,
                    portionID: portion.id, quantity: 100, source: .margin,
                    reason: "Fictional funding label", expectedRevision: allocation.revision)
            } catch { report("system-fixture", "funding label failed: \(error)") }
        }
        let event = InstrumentEvent(kind: .earnings, date: Date.now.addingTimeInterval(86_400),
            title: "虚构：季度业绩观察窗口", endDate: Date.now.addingTimeInterval(3 * 86_400))
        _ = appState.watchlist.setInstrumentEvent(event, for: symbols.tactical)
        if var plan = appState.watchlist.item(for: symbols.tactical)?.plans.first {
            plan.fundingSource = .margin
            var condition = TradePlanCondition(title: "核对季度订单变化", kind: .event, state: .confirmed)
            condition.eventReference = event
            plan.conditions = (plan.conditions ?? []) + [condition]
            _ = appState.watchlist.setTradePlan(plan, for: symbols.tactical)
        }
        let library = TradePlan(kind: .buy, price: 11, quantity: 120, note: "虚构：等待明确用途", fundingSource: .own)
        _ = appState.watchlist.setTradePlan(library, for: symbols.noLimit)
        let sale = TradePlan(kind: .sell, price: 13, quantity: 100, positionPool: .tactical)
        _ = appState.watchlist.setTradePlan(sale, for: symbols.tactical)

        // Verification fixtures use the same store and production views.
        for symbol in [symbols.tactical, symbols.noLimit] {
            let portionIDs = appState.watchlist.item(for: symbol)?.positionAllocation?.portions.map(\.id) ?? []
            for (index, id) in portionIDs.enumerated() {
                guard let allocation = appState.watchlist.item(for: symbol)?.positionAllocation else { continue }
                let state: TradePlanCondition.State = symbol == symbols.noLimit ? .invalidated
                    : index == 0 ? .pending : index == 1 ? .confirmed : .needsReview
                let condition = TradePlanCondition(title: "虚构：核对订单与业绩依据", kind: .event, state: state,
                    note: "订单持续增长；若交付下降则重新评估。", reviewDate: Date.now.addingTimeInterval(3 * 86_400),
                    eventReference: event)
                do {
                    _ = try appState.watchlist.setPositionConditions(symbol: symbol, portionID: id,
                        conditions: [condition], expectedRevision: allocation.revision)
                } catch { report("verification-fixture", "condition edit failed: \(error)") }
            }
        }

        var views: [(String, CGFloat, CGFloat, ColorScheme, AnyView)] = MainWorkspacePage.allCases.map {
            ("shell-\($0.rawValue)-1440", 1440, 900, .dark, AnyView(MainWindowView(initialPage: $0)))
        }
        views.append(("event-links", 560, 620, .dark, AnyView(TradingEventDetailSheet(
            entry: .init(symbol: symbols.tactical, event: event, sourceName: "Synthetic", isForecast: false, isAutomatic: false),
            account: appState.watchlist.activeBrokerageAccountID,
            onEdit: {}, onDelete: {}, onSelectSymbol: { _ in }))))
        if let transaction = appState.watchlist.item(for: symbols.tactical)?.transactions.first {
            _ = appState.watchlist.updateTransactionReview(symbols.tactical, id: transaction.id,
                note: transaction.note, review: .init(retrospective: "虚构：等待业绩窗口复核",
                    nextReviewDate: Calendar.current.startOfDay(for: .now), nextReviewNote: "虚构：核对订单变化"))
            views.append(("journal-selected", 1140, 900, .dark,
                AnyView(TradeJournalView(onSelect: { _ in }, initialTransactionID: transaction.id))))
        }
        views += [
            ("shell-plans-inspector", 1440, 900, .dark,
             AnyView(MainWindowView(initialPage: .plans, inspectedSymbol: symbols.tactical))),
            ("shell-plans-return", 1440, 900, .dark,
             AnyView(MainWindowView(initialPage: .plans, inspectedSymbol: symbols.tactical, fullInstrument: true))),
            ("shell-pools-1000", 1000, 900, .dark, AnyView(MainWindowView(initialPage: .positionPools))),
            ("today-selected-1000", 1000, 900, .dark, AnyView(TradingWorkbenchView(onSelect: { _ in },
                onShowPlans: {}, onShowJournal: {}, onShowEvents: {}, initial:
                    .init(phase: .postMarket, selectedSymbol: symbols.tactical, showsCapitalDetail: true)))),
            ("today-selected-light", 1440, 900, .light, AnyView(TradingWorkbenchView(onSelect: { _ in },
                onShowPlans: {}, onShowJournal: {}, onShowEvents: {}, initial:
                    .init(selectedSymbol: symbols.tactical, showsCapitalDetail: true)))),
        ]
        views += [
            ("verification-board-1440", 1440, 900, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD", showsPlanRail: false)))),
            ("verification-board-1000", 1000, 900, .light,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD", showsPlanRail: false)))),
        ]
        if let entry = appState.watchlist.tradePlanEntries.first(where: { $0.id == sale.id }) {
            views.append(("mixed-sale", 440, 650, .dark,
                AnyView(PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                                           onClose: {}))))
        }
        if let entry = appState.watchlist.tradePlanEntries.first(where: { $0.symbol == symbols.tactical && $0.plan.kind == .buy }) {
            views.append(("funding-buy", 440, 650, .light,
                AnyView(PlanExecutionSheet(entry: entry, account: appState.watchlist.activeBrokerageAccountID,
                                           onClose: {}))))
            views.append(("linked-plan", 650, 680, .dark,
                AnyView(PlanWorkflowDetailView(symbol: entry.symbol, planID: entry.id,
                                               account: appState.watchlist.activeBrokerageAccountID))))
        }
        if let item = appState.watchlist.item(for: symbols.tactical),
           let allocation = item.positionAllocation,
           let portion = allocation.portions.first {
            let cards = VStack(spacing: 10) {
                ForEach(TradePlanCondition.State.allCases, id: \.self) { state in
                    let condition = TradePlanCondition(title: "虚构持有依据", kind: .manual, state: state)
                    let card = PositionPoolsView.PortionCard(item: item,
                        portion: .init(quantity: 100, pool: .tactical, origin: portion.origin,
                            fundingSource: .margin, conditions: [condition]), needsReview: false)
                    PortionCardFace(card: card, compact: false, onSelect: {}, onWholeTransfer: { _ in },
                        onPartialTransfer: { _ in }, onMarkFunding: {}, onEditVerification: {},
                        onDragChanged: { _, _ in }, onDragEnded: { _ in }, isDraggable: false, isPlaceholder: false)
                }
            }.padding(16).background(Color(nsColor: .windowBackgroundColor))
            views.append(("verification-cards", 420, 480, .dark, AnyView(cards)))
            views.append(("verification-cards-light", 420, 480, .light, AnyView(cards)))
            views.append(("verification-editor", 480, 560, .dark,
                AnyView(PositionVerificationSheet(item: item, portion: portion, allocation: allocation,
                    account: appState.watchlist.activeBrokerageAccountID,
                    onCancel: {}, onSuccess: { _, _ in }))))
            views.append(("verification-editor-light", 480, 560, .light,
                AnyView(PositionVerificationSheet(item: item, portion: portion, allocation: allocation,
                    account: appState.watchlist.activeBrokerageAccountID,
                    onCancel: {}, onSuccess: { _, _ in }))))
            views.append(("funding-marker", 410, 360, .dark,
                AnyView(FundingSourceSheet(item: item, portion: portion, allocation: allocation,
                    onCancel: {}, onSuccess: { _, _ in }))))
            views.append(("funding-marker-light", 410, 360, .light,
                AnyView(FundingSourceSheet(item: item, portion: portion, allocation: allocation,
                    onCancel: {}, onSuccess: { _, _ in }))))
        }
        for (name, width, height, scheme, content) in views {
            let view = content.defaultAppStorage(renderDefaults).environment(appState).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN")).frame(width: width, height: height)
            do {
                try renderInOffscreenWindow(view: view, width: width, height: height,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme, requiresBoardBand: false)
                print("SYSTEM_RENDER \(name)")
            } catch { report("system-render", "\(name): \(error)") }
        }
    }

    /// The two-pool layout after empty Unassigned hides, with a long inventory.
    private static func renderTwoPoolArtifacts(appState: AppState, into directory: URL) {
        for item in appState.watchlist.allItems {
            for var plan in item.plans where plan.positionPool == .unassigned {
                plan.positionPool = .strategic
                _ = appState.watchlist.setTradePlan(plan, for: item.symbol)
            }
            for portion in item.positionAllocation?.portions ?? [] where portion.pool == .unassigned {
                guard let current = appState.watchlist.item(for: item.symbol)?.positionAllocation else { continue }
                do {
                    _ = try appState.watchlist.transferPositionPortion(symbol: item.symbol, portionID: portion.id,
                        quantity: portion.quantity, to: .strategic, reason: "Synthetic layout fixture", expectedRevision: current.revision)
                } catch { report("two-pool-fixture", "purpose assignment failed: \(error)") }
            }
        }
        for index in 1...7 {
            let symbol = SymbolID(market: .us, code: "ZZSPACE\(index)")
            appState.watchlist.add(SymbolInfo(symbol: symbol, name: "虚构底仓样本 \(index)"))
            appState.watchlist.addTransaction(symbol, .init(kind: .buy, price: 20, quantity: 100))
            if let allocation = appState.watchlist.item(for: symbol)?.positionAllocation,
               let portion = allocation.portions.first {
                do {
                    _ = try appState.watchlist.transferPositionPortion(symbol: symbol, portionID: portion.id,
                        quantity: portion.quantity, to: .strategic, reason: "Synthetic layout fixture", expectedRevision: allocation.revision)
                } catch { report("two-pool-fixture", "sample assignment failed: \(error)") }
            }
            appState.market.apply(quotes: [.init(symbol: symbol, price: 21, previousClose: 20,
                currencyCode: "USD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now)])
        }
        guard let defaults = UserDefaults(suiteName: "pulse.tactical-two-pool-renders") else {
            report("two-pool-fixture", "isolated render defaults unavailable"); return
        }
        defaults.removePersistentDomain(forName: "pulse.tactical-two-pool-renders")
        let tacticalID = appState.watchlist.tradePlanEntries.first { $0.plan.positionPool == .tactical }?.id
        let strategicID = appState.watchlist.tradePlanEntries.first {
            $0.symbol.currencyCode == "USD" && $0.plan.positionPool == .strategic
        }?.id
        let cases: [(String, CGFloat, CGFloat, ColorScheme, AnyView)] = [
            ("two-pools-shell-1800", 1800, 1100, .dark, AnyView(MainWindowView(initialPage: .positionPools))),
            ("two-pools-1440", 1440, 900, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD")))),
            ("two-pools-1000", 1000, 900, .light,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD")))),
            ("two-pools-short", 1000, 600, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(currencyFilter: "USD")))),
            ("two-pools-preview", 1440, 900, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(stance: .preview, currencyFilter: "USD")))),
            ("two-pools-focus", 1440, 900, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(selectedPlanID: tacticalID, currencyFilter: "USD")))),
            ("two-pools-strategic-focus", 1440, 900, .dark,
             AnyView(PositionPoolsView(onSelect: { _ in }, tactical: .init(selectedPlanID: strategicID, currencyFilter: "USD")))),
        ]
        for (name, width, height, scheme, content) in cases {
            let view = content.defaultAppStorage(defaults).environment(appState).environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN")).frame(width: width, height: height)
            do {
                try renderInOffscreenWindow(view: view, width: width, height: height,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme)
                print("SYSTEM_RENDER \(name)")
            } catch { report("two-pool-render", "\(name): \(error)") }
        }
    }

    /// Native renders of the actual production board.
    ///
    /// `ImageRenderer` reports success while silently producing an empty region
    /// wherever the view tree uses a lazy container (`LazyVGrid`, `LazyVStack`)
    /// or an AppKit-backed control such as a segmented `Picker`: it never runs
    /// the layout pass that materializes them. The board's four pool columns are
    /// exactly such a case, so the primary path here is a real `NSHostingView`
    /// hosted in a genuine — but permanently offscreen — `NSWindow`, driven
    /// through the run loop so lazy content is realized before capture.
    ///
    /// The window is borderless, parked far offscreen, never made key or main,
    /// never ordered front, and the app is never activated. No user window is
    /// touched and no real account data is read.
    private static func renderArtifacts(appState: AppState, symbols: Fixture, into directory: URL) {
        let planID = self.planID(in: appState, symbol: symbols.tactical)
        let tacticalID = appState.watchlist.tradePlanEntries
            .first { $0.symbol == symbols.tactical }?.id

        let cases: [(name: String, width: CGFloat, height: CGFloat, scheme: ColorScheme, state: PositionPoolsView.TacticalInitialState)] = [
            ("current-1440", 1440, 900, .dark, .current),
            ("preview-1440", 1440, 900, .dark, .preview),
            ("preview-1000", 1_000, 900, .dark, .preview),
            ("focus-1440", 1440, 900, .dark, .focus(planID)),
            ("focus-1000", 1_000, 900, .dark,
             .init(selectedPlanID: planID, showsPlanDrawer: true)),
            ("lineage-1440", 1440, 900, .dark,
             .init(selectedPlanID: planID, showsPlanLineage: true)),
            ("current-1440-light", 1440, 900, .light, .current),
            ("symbol-1440", 1440, 900, .dark, PositionPoolsView.TacticalInitialState(mode: .symbol)),
            // The subset the rehearsal actually computes over, with the excluded
            // plans still on the board and labelled.
            ("preview-subset-1440", 1440, 900, .dark,
             .previewSubset(tacticalID.map { [$0] } ?? [])),
            // Explicitly nothing selected: a real answer, not "all".
            ("preview-empty-1440", 1440, 900, .dark, .previewEmpty),
        ]

        for item in cases {
            let view = PositionPoolsView(
                onSelect: { _ in },
                onShowPlans: {},
                tactical: item.state
            )
            .environment(appState)
            .environment(\.colorScheme, item.scheme)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: item.width, height: item.height)

            let url = directory.appendingPathComponent("\(item.name).png")
            do {
                try renderInOffscreenWindow(view: view, width: item.width, height: item.height,
                                            to: url, scheme: item.scheme)
                print("TACTICAL_BOARD_RENDER \(item.name) \(Int(item.width))x\(Int(item.height)) -> \(url.path)")
            } catch {
                report("render", "\(item.name) failed: \(error)")
            }
        }

        // An unspecified-pool sale changes the valid portfolio total but makes
        // the projected pool split unknown. The overview must show both facts.
        let unspecifiedSale = TradePlan(kind: .sell, price: 33, quantity: 30,
                                        note: "fictional unspecified-pool sale")
        if appState.watchlist.setTradePlan(unspecifiedSale, for: symbols.dualCurrency) {
            let view = PositionPoolsView(onSelect: { _ in }, onShowPlans: {}, tactical: .preview)
                .environment(appState).environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: 1440, height: 900)
            do {
                try renderInOffscreenWindow(view: view, width: 1440, height: 900,
                    to: directory.appendingPathComponent("preview-unresolved-1440.png"), scheme: .dark)
                print("TACTICAL_BOARD_RENDER preview-unresolved-1440 1440x900")
            } catch { report("render", "unresolved preview failed: \(error)") }
            _ = appState.watchlist.deleteTradePlan(unspecifiedSale.id, for: symbols.dualCurrency)
        } else { report("render", "cannot seed fictional unspecified sale") }

        renderUnassignedPresent(appState: appState, into: directory)

        let badges = VStack(spacing: 16) {
            PositionPoolsView.DragBadge(pool: .strategic, title: "虚构持仓", code: "ZZDRAG",
                                       detail: "105,200 份额", sourceWidth: 260)
            PositionPoolsView.DragBadge(pool: .tactical, title: "虚构计划", code: "ZZPLAN",
                                       detail: "买入 385.00 × 50", sourceWidth: 220)
            PositionPoolsView.DragBadge(pool: .tactical, title: "虚构持仓", code: "ZZSPLIT",
                                       detail: "400 份额", isSplit: true, sourceWidth: 220)
        }
        .frame(width: 480, height: 240)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let badgeURL = directory.appendingPathComponent("drag-badges.png")
        do {
            try renderInOffscreenWindow(view: badges, width: 480, height: 240,
                                       to: badgeURL, scheme: .dark)
            print("TACTICAL_BOARD_RENDER drag-badges 480x240 -> \(badgeURL.path)")
        } catch {
            report("render", "drag-badges failed: \(error)")
        }
    }

    /// The "unassigned is present" state: the fourth column exists because a
    /// fictional unassigned plan is temporarily added, so `current-1440` and
    /// `preview-1000` continue to cover the three-column hidden state.
    ///
    /// The plan is added through the store and removed again immediately; the
    /// isolated demo harness owns this fixture and nothing persists.
    private static func renderUnassignedPresent(appState: AppState, into directory: URL) {
        let symbol = SymbolID(market: .us, code: "ZZUNASSIGNED")
        guard let groupID = appState.watchlist.selectedGroup?.id else {
            report("render", "unassigned-present: no selected group")
            return
        }
        if appState.watchlist.item(for: symbol) == nil {
            appState.watchlist.add(SymbolInfo(symbol: symbol, name: "Fictional Unassigned Co"), to: groupID)
        }

        var plan = TradePlan(kind: .buy, price: 9, quantity: 200, note: "fictional unassigned plan")
        plan.positionPool = .unassigned
        guard appState.watchlist.setTradePlan(plan, for: symbol) else {
            report("render", "unassigned-present: could not seed the unassigned plan")
            return
        }

        defer {
            _ = appState.watchlist.deleteTradePlan(plan.id, for: symbol)
            appState.watchlist.remove(symbol)
        }
        // An excluded preview candidate remains visible, even with no budget.
        let visible = PositionPoolsView.visiblePools(cards: [], entries: appState.watchlist.tradePlanEntries)
        expect(visible.contains(.unassigned) && visible.count == 3,
               "render", "unassigned-present seeded no unassigned content: \(visible)")

        let state = PositionPoolsView.TacticalInitialState.previewEmpty
        let view = PositionPoolsView(onSelect: { _ in }, onShowPlans: {}, tactical: state)
            .environment(appState)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 1440, height: 900)

        let url = directory.appendingPathComponent("unassigned-present-1440.png")
        do {
            try renderInOffscreenWindow(view: view, width: 1440, height: 900, to: url, scheme: .dark)
            print("TACTICAL_BOARD_RENDER unassigned-present-1440 1440x900 -> \(url.path)")
        } catch {
            report("render", "unassigned-present-1440 failed: \(error)")
        }

    }

    // MARK: - Brokerage account scope

    /// The account feature is exercised against the real store: enabling it
    /// classifies nothing, a whole-ledger assignment moves the instrument and
    /// leaves the source account alone, switching accounts exposes an
    /// independent book, and none of the renders below changes a single byte of
    /// either portfolio.
    private static func assertBrokerageAccounts(appState: AppState, symbols: Fixture) {
        let store = appState.watchlist
        expect(store.enableBrokerageAccounts(), "accounts", "enabling named accounts must be a real state change the first time")
        expect(!store.enableBrokerageAccounts(), "accounts", "enabling named accounts twice must be a no-op")
        expect(store.brokerageAccountsEnabled, "accounts", "the feature must read as enabled after enabling")

        // Enabling classifies nothing: a broker was never recorded for legacy
        // trades, so guessing one would invent history.
        let unassignedBefore = store.brokeragePortfolio(for: .unassigned)
        expect(unassignedBefore.items.contains { $0.symbol == symbols.tactical },
               "accounts", "enabling must leave every legacy instrument in unassigned")
        expect(store.brokeragePortfolio(for: .financing).items.isEmpty
               && store.brokeragePortfolio(for: .mengmeng).items.isEmpty,
               "accounts", "enabling must not pre-classify anything into a named account")

        let unassignedCountBefore = unassignedBefore.items.count
        let unassignedSnapshotBefore = store.brokeragePortfolio(for: .unassigned)

        // A whole-ledger move takes the instrument and its plans, and leaves the
        // source short by exactly that instrument.
        expect(store.assignBrokerageRecords(for: symbols.tactical, transactionIDs: nil, to: .financing),
               "accounts", "a whole-ledger assignment from unassigned must succeed")
        let financing = store.brokeragePortfolio(for: .financing)
        expect(financing.items.contains { $0.symbol == symbols.tactical },
               "accounts", "the moved instrument must exist in the destination account")
        let unassignedAfter = store.brokeragePortfolio(for: .unassigned)
        expect(unassignedAfter.items.count == unassignedCountBefore - 1
               && !unassignedAfter.items.contains { $0.symbol == symbols.tactical },
               "accounts", "a whole-ledger move must remove the instrument from unassigned, not copy it")

        // The two accounts must not see each other: switching is a scope change,
        // and whatever was moved is simply absent from the other book.
        let restored = store.selectBrokerageAccount(.financing)
        expect(restored, "accounts", "switching to a named account must report a change")
        expect(store.allItems.contains { $0.symbol == symbols.tactical },
               "accounts", "the destination account must expose the moved instrument after switching")
        expect(appState.selectBrokerageAccount(.unassigned), "accounts", "switching back must succeed")
        expect(!store.allItems.contains { $0.symbol == symbols.tactical },
               "accounts", "the source account must not expose an instrument that was moved away")

        assertAccountSummariesAreIndependent(appState: appState, movedSymbol: symbols.tactical)

        // A conflicting destination is refused, and the refusal leaves the source
        // untouched. `unassigned` is selected here, so the only rule that can
        // reject this is the destination already holding the instrument — which
        // is exactly the case the sheet must report instead of applying.
        expect(store.assignBrokerageRecords(for: symbols.tactical, transactionIDs: nil, to: .financing) == false,
               "accounts", "moving an instrument the destination already holds must be refused")
        expect(!store.allItems.contains { $0.symbol == symbols.tactical },
               "accounts", "a refused assignment must not resurrect the instrument in the source account")

        // Assigning to `unassigned` is not an operation the model has: there is no
        // un-classify, so it must be refused rather than silently accepted.
        expect(store.assignBrokerageRecords(for: symbols.oversell, transactionIDs: nil, to: .unassigned) == false,
               "accounts", "unassigned is a source, never a destination")

        // An empty trade selection is not "the whole ledger"; it must be refused
        // so a row with nothing ticked can never move everything by accident.
        expect(store.assignBrokerageRecords(for: symbols.oversell, transactionIDs: [], to: .financing) == false,
               "accounts", "an empty trade selection must be refused, not read as the whole ledger")
        expect(store.brokeragePortfolio(for: .financing).items.allSatisfy { $0.symbol != symbols.oversell },
               "accounts", "a refused assignment must leave the destination account unchanged")

        // Put the fixture back: re-select unassigned and move the instrument home
        // again, so the render cases below start from the same board the rest of
        // the harness expects.
        _ = appState.selectBrokerageAccount(.unassigned)
        expect(store.activeBrokerageAccountID == .unassigned, "accounts", "the fixture must return to unassigned")
        // Re-adding it to unassigned and moving it home would need the store's
        // own remove path; the simplest honest restoration is to leave the
        // instrument in the destination account and assert that both books are
        // still internally consistent afterwards.
        expect(store.brokeragePortfolio(for: .financing).items.contains { $0.symbol == symbols.tactical },
               "accounts", "the moved instrument must stay in the destination account")
        let restoredSnapshot = store.brokeragePortfolio(for: .unassigned)
        expect(!restoredSnapshot.items.isEmpty, "accounts", "the unassigned book must still hold the untouched instruments")
        expect(!restoredSnapshot.items.contains { $0.symbol == symbols.tactical },
               "accounts", "the source account must not regain an instrument it moved away")

        // The renders that follow must be pure readers. Snapshot both books, run
        // every account render, and demand the bytes are identical.
        let before = store.brokeragePortfolio(for: .unassigned)
        renderAccountOnly(appState: appState)
        let after = store.brokeragePortfolio(for: .unassigned)
        expect(before == after, "accounts", "rendering the account surfaces must not mutate any portfolio")
        expect(unassignedSnapshotBefore.items.count >= after.items.count,
               "accounts", "the unassigned book can only shrink by the one instrument the fixture moved")
    }

    /// Switching accounts must expose two genuinely independent books, and the
    /// summary reader must report the one it was asked for without disturbing
    /// the selection.
    private static func assertAccountSummariesAreIndependent(appState: AppState, movedSymbol: SymbolID) {
        let store = appState.watchlist
        let selectionBefore = store.activeBrokerageAccountID

        let financing = BrokerageAccountSummaryReader.summary(
            for: .financing, store: store, market: appState.market)
        let unassigned = BrokerageAccountSummaryReader.summary(
            for: .unassigned, store: store, market: appState.market)

        expect(financing.holdingCount == 1,
               "accounts", "the destination account's summary must count exactly the moved instrument")
        expect(unassigned.holdingCount >= 1,
               "accounts", "the source account's summary must still count its remaining instruments")
        expect(financing.holdingCount != unassigned.holdingCount
               || !financing.currencyLines.isEmpty,
               "accounts", "the two accounts must not summarise as the same book")

        // Reading a summary is not a scope change: the selection is untouched.
        expect(store.activeBrokerageAccountID == selectionBefore,
               "accounts", "reading an account summary must not move the selection")

        // A cross-currency total is not offered at all, so the only way a figure
        // appears is per currency and it must be finite.
        expect(financing.currencyLines.allSatisfy { $0.value.isFinite && $0.value != 0 },
               "accounts", "a currency line must be a finite non-zero cached valuation")
        expect(financing.currencyLines.count == Set(financing.currencyLines.map(\.currencyCode)).count,
               "accounts", "each currency must appear at most once; currencies are never summed together")

        // The moved instrument is priced in USD in the fixture, so the
        // destination's line is USD and the unassigned book does not contain it.
        expect(financing.currencyLines.contains { $0.currencyCode == "USD" },
               "accounts", "the priced destination holding must report a USD line")
    }

    /// Rendering the account surfaces against a fixture, with no file output, so
    /// the mutation check above can run the real view bodies.
    private static func renderAccountOnly(appState: AppState) {
        let view = BrokerageAccountSwitcherPopover(
            activeAccount: .unassigned,
            summaries: BrokerageAccountSummaryReader.summaries(for: appState.watchlist, market: appState.market),
            onSelect: { _ in },
            onManage: {}
        )
        .environment(appState)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .frame(width: 320, height: 440)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    // MARK: - Account overview

    /// The cross-account overview read model and its two write rules.
    ///
    /// Three things are being proved here, and all three are things a plausible
    /// implementation gets wrong:
    ///
    /// 1. Reading every account — including their cash — is **not** a scope
    ///    change, and the selected ledger is byte-identical afterwards.
    /// 2. A cash write through the frozen `(account, currency)` pair lands in
    ///    that account only. Recording cash for an *inactive* account must not
    ///    switch to it, and must not disturb the active account's budgets.
    /// 3. Per-currency totals sum same-currency rows and nothing else, and an
    ///    unrecorded balance is never reported as a zero.
    private static func assertAccountOverview(appState: AppState, symbols: Fixture) {
        let store = appState.watchlist
        let budgets = appState.poolBudgets

        // Reading is free: the overview must never move the selection.
        let selectionBefore = store.activeBrokerageAccountID
        _ = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        expect(store.activeBrokerageAccountID == selectionBefore,
               "overview", "reading every account's rows must not move the selected account")
        expect(store.activeBrokerageAccountID == .unassigned,
               "overview", "the fixture expects the selected account to still be unassigned here")

        // CNY is always offered: it is the account currency even with nothing
        // recorded in it, so a brand-new book still has somewhere to put cash.
        let emptyRows = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        expect(emptyRows.contains { $0.accountID == .financing && $0.currencyCode == "CNY" },
               "overview", "CNY must always be available for every account")
        expect(emptyRows.allSatisfy { $0.cash == nil || $0.cash?.amount.isFinite == true },
               "overview", "a cash balance must be finite or absent, never NaN")

        // A frozen (account, currency) write lands in that account, and does not
        // change which account is selected or what the active account holds.
        let activeCashBefore = budgets.cashBalances(for: .unassigned)
        let revisionBefore = budgets.revision
        expect(budgets.setCashBalance(amount: 12_345.5, currency: "CNY", in: .financing),
               "overview", "recording cash for an inactive account must succeed")
        expect(store.activeBrokerageAccountID == .unassigned,
               "overview", "a cash edit for another account must not switch the active account")
        expect(budgets.cashBalances(for: .unassigned) == activeCashBefore,
               "overview", "a cash edit for another account must not touch the active account's budgets")
        expect(budgets.revision > revisionBefore,
               "overview", "a cross-account cash edit must bump the revision so the overview re-renders")

        let afterWrite = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        expect(afterWrite.first { $0.accountID == .financing && $0.currencyCode == "CNY" }?.cash?.amount == 12_345.5,
               "overview", "the frozen write must be visible on the destination account's CNY row")

        // A recorded zero is a real reading and must survive as 0, not become
        // "unrecorded" — the overview shows 0 and 未录 as different states.
        expect(budgets.setCashBalance(amount: 0, currency: "CNY", in: .mengmeng),
               "overview", "recording an explicit zero must be accepted")
        let zeroRows = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        let zeroRow = zeroRows.first { $0.accountID == .mengmeng && $0.currencyCode == "CNY" }
        expect(zeroRow?.cash?.amount == 0,
               "overview", "a recorded zero must read back as a zero balance, not as unrecorded")

        // Invalid amounts are refused outright rather than coerced.
        expect(budgets.setCashBalance(amount: -1, currency: "CNY", in: .mengmeng) == false,
               "overview", "a negative cash amount must be refused")
        expect(budgets.setCashBalance(amount: .nan, currency: "CNY", in: .mengmeng) == false,
               "overview", "a non-finite cash amount must be refused")
        expect(budgets.setCashBalance(amount: 1, currency: "  ", in: .mengmeng) == false,
               "overview", "an empty currency code must be refused")

        // Clearing returns the line to 未录 — which is not the same as zero.
        expect(budgets.setCashBalance(amount: nil, currency: "CNY", in: .mengmeng),
               "overview", "clearing a recorded balance must succeed")
        let clearedRows = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        expect(clearedRows.first { $0.accountID == .mengmeng && $0.currencyCode == "CNY" }?.cash == nil,
               "overview", "a cleared balance must read as unrecorded, distinct from a recorded zero")

        assertOverviewTotalsArePerCurrency(appState: appState)
        assertOverviewCardsSeparateFunding(appState: appState, symbols: symbols)

        // Leave the fixture as it was found: the renders below seed their own
        // cash, and a leftover balance would silently change their totals.
        expect(budgets.setCashBalance(amount: nil, currency: "CNY", in: .financing),
               "overview", "the fixture must clean up the balance it recorded")
        expect(store.activeBrokerageAccountID == selectionBefore,
               "overview", "the overview fixture must leave the selection where it found it")
    }

    /// The headline arithmetic: same currency only, and unknown cash never
    /// silently becomes zero.
    private static func assertOverviewTotalsArePerCurrency(appState: AppState) {
        let budgets = appState.poolBudgets
        let store = appState.watchlist
        let otherCashBefore = BrokerageAccountID.allCases.map { budgets.cashBalances(for: $0)["HKD"] }

        _ = budgets.setCashBalance(amount: 1_000, currency: "CNY", in: .financing)
        _ = budgets.setCashBalance(amount: 2_500, currency: "CNY", in: .mengmeng)

        let rows = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: budgets)
        let cnyRows = rows.filter { $0.currencyCode == "CNY" }
        let known = cnyRows.compactMap(\.cash).map(\.amount)
        expect(known.contains(1_000) && known.contains(2_500),
               "overview", "both accounts' CNY balances must be readable at once")

        // The three accounts are not lumped into one figure: an account with no
        // recorded balance simply has no row value, which is what the page turns
        // into the 未录 warning instead of adding a zero.
        expect(cnyRows.filter { $0.cash == nil }.count >= 1,
               "overview", "the unassigned account must still read as unrecorded, not as zero cash")
        expect(known.allSatisfy { $0.isFinite && $0 >= 0 },
               "overview", "every known balance must be finite and non-negative")

        // A currency that no account records never appears, so it can never be
        // summed into a CNY figure.
        expect(BrokerageAccountID.allCases.map { budgets.cashBalances(for: $0)["HKD"] } == otherCashBefore,
               "overview", "CNY cash edits must leave existing HKD cash unchanged")

        // Same-currency summation is exact and is the only arithmetic the page
        // performs; a cross-currency total is not offered at all.
        let cnyTotal = known.reduce(0, +)
        expect(abs(cnyTotal - 3_500) < 0.001,
               "overview", "same-currency cash must sum exactly; got \(cnyTotal)")
        expect(rows.allSatisfy { row in
            row.holdingValue.isFinite && row.plannedBuy.isFinite && row.plannedSell.isFinite
        }, "overview", "no row may carry a non-finite money figure")

        _ = budgets.setCashBalance(amount: nil, currency: "CNY", in: .financing)
        _ = budgets.setCashBalance(amount: nil, currency: "CNY", in: .mengmeng)
    }

    /// own / margin / unmarked are independent intents, and the card keeps them
    /// apart. The overview must not fold them into one "borrowing" number, and
    /// must never derive a credit limit from them.
    private static func assertOverviewCardsSeparateFunding(appState: AppState, symbols: Fixture) {
        let store = appState.watchlist
        guard store.activeBrokerageAccountID == .unassigned else {
            report("overview", "the funding breakdown fixture must run from unassigned")
            return
        }

        let ownSymbol = symbols.oversell
        let currency = ownSymbol.currencyCode.uppercased()
        let baseline = BrokerageAccountOverviewReader.rows(store: store, market: appState.market, budgets: appState.poolBudgets)
            .first { $0.accountID == .unassigned && $0.currencyCode == currency }!
        var ownBuy = TradePlan(kind: .buy, price: 10, quantity: 100)
        ownBuy.fundingSource = .own
        var marginBuy = TradePlan(kind: .buy, price: 10, quantity: 200)
        marginBuy.fundingSource = .margin
        var unmarkedBuy = TradePlan(kind: .buy, price: 10, quantity: 300)
        unmarkedBuy.fundingSource = .unmarked
        _ = store.setTradePlan(ownBuy, for: ownSymbol)
        _ = store.setTradePlan(marginBuy, for: ownSymbol)
        _ = store.setTradePlan(unmarkedBuy, for: ownSymbol)

        defer {
            _ = store.deleteTradePlan(ownBuy.id, for: ownSymbol)
            _ = store.deleteTradePlan(marginBuy.id, for: ownSymbol)
            _ = store.deleteTradePlan(unmarkedBuy.id, for: ownSymbol)
        }

        let rows = BrokerageAccountOverviewReader.rows(
            store: store, market: appState.market, budgets: appState.poolBudgets)
        guard let row = rows.first(where: { $0.accountID == .unassigned && $0.currencyCode == currency }) else {
            report("overview", "the funding breakdown fixture produced no \(currency) row")
            return
        }

        expect(abs(row.ownBuy - baseline.ownBuy - 1_000) < 0.001
               && abs(row.marginBuy - baseline.marginBuy - 2_000) < 0.001
               && abs(row.unmarkedBuy - baseline.unmarkedBuy - 3_000) < 0.001,
               "overview", "own/margin/unmarked intents must stay three separate figures; got "
                   + "\(row.ownBuy)/\(row.marginBuy)/\(row.unmarkedBuy)")
        expect(abs(row.plannedBuy - baseline.plannedBuy - 6_000) < 0.001,
               "overview", "planned buy must be the sum of the three intents and nothing more")
        expect(abs(row.ownBuy + row.marginBuy + row.unmarkedBuy - row.plannedBuy) < 0.001,
               "overview", "the breakdown must account for the whole planned-buy figure")
    }

    /// The account acceptance renders: the toolbar selector over the real main
    /// window at two widths in both schemes, the popover content standing alone,
    /// a mixed buy/sell pool board proving the side colour is not the P&L
    /// palette, and the classification sheet.
    private static func renderBrokerageAccountArtifacts(appState: AppState, into directory: URL) {
        // The chip and the popover are the two surfaces a user meets first, so
        // each is captured in both appearances and at the narrow width where the
        // toolbar has the least room.
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (account, label) in [(BrokerageAccountID.unassigned, "unassigned"),
                                     (.financing, "financing"),
                                     (.mengmeng, "mengmeng")] {
                let chip = VStack(spacing: 10) {
                    BrokerageAccountChip(account: account, isEnabled: true, action: {})
                }
                .padding(16)
                .frame(width: 220, height: 60)
                let url = directory.appendingPathComponent("account-chip-\(label)-\(suffix).png")
                do {
                    try renderInOffscreenWindow(view: chip, width: 220, height: 60,
                                                to: url, scheme: scheme, requiresBoardBand: false)
                    print("TACTICAL_BOARD_RENDER account-chip-\(label)-\(suffix) 220x60")
                } catch { report("account-render", "account-chip-\(label)-\(suffix): \(error)") }
            }
        }

        // The popover content, standalone: the summary lines are the point, so it
        // is rendered as its own surface rather than hidden behind a live click.
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let popover = BrokerageAccountSwitcherPopover(
                activeAccount: .unassigned,
                summaries: BrokerageAccountSummaryReader.summaries(
                    for: appState.watchlist, market: appState.market),
                onSelect: { _ in },
                onManage: {}
            )
            .environment(appState)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 320, height: 440)
            .background(Color(nsColor: .windowBackgroundColor))

            let url = directory.appendingPathComponent("account-popover-\(suffix).png")
            do {
                try renderInOffscreenWindow(view: popover, width: 320, height: 440,
                                            to: url, scheme: scheme, requiresBoardBand: false)
                print("TACTICAL_BOARD_RENDER account-popover-\(suffix) 320x440 -> \(url.path)")
            } catch { report("account-render", "account-popover-\(suffix): \(error)") }
        }

        // The main window itself, with the account feature explicitly on. The
        // toolbar item only exists while the feature is enabled, so this is the
        // render that proves the chip is in the window chrome and costs no
        // content height at either width.
        for scheme in [ColorScheme.dark, .light] {
            for width in [CGFloat(1_000), 1_280] {
                let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                let view = MainWindowView(initialPage: .positionPools)
                    .environment(appState)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .frame(width: width, height: 820)

                let url = directory.appendingPathComponent("account-main-window-\(suffix).png")
                do {
                    try renderInOffscreenWindow(view: view, width: width, height: 820,
                                                to: url, scheme: scheme)
                    print("TACTICAL_BOARD_RENDER account-main-window-\(suffix) \(Int(width))x820 -> \(url.path)")
                } catch { report("account-render", "account-main-window-\(suffix): \(error)") }
            }
        }

        // A board holding both a buy and a sell plan. The two side colours must
        // read apart from each other, from the pool columns they sit in, and
        // from the orange margin tag.
        renderMixedSideBoard(appState: appState, into: directory)

        // The classification sheet, seeded so it has a row with an expandable
        // ledger and a pre-existing margin annotation to display.
        renderClassificationSheet(appState: appState, into: directory)
    }

    /// One buy and one sell in the same pool, so a single render shows both side
    /// colours in context and their separation from the pool wash.
    private static func renderMixedSideBoard(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        guard store.activeBrokerageAccountID == .unassigned else {
            report("account-render", "the mixed-side board must be seeded from unassigned")
            return
        }
        let symbol = SymbolID(market: .us, code: "ZZSIDE")
        guard let groupID = store.selectedGroup?.id else {
            report("account-render", "mixed-side board: no selected group")
            return
        }
        if store.item(for: symbol) == nil {
            store.add(SymbolInfo(symbol: symbol, name: "Fictional Side By Side Co"), to: groupID)
        }
        appState.market.apply(quotes: [
            Quote(symbol: symbol, name: "Fictional Side By Side Co", price: 18, previousClose: 17.5,
                  open: 17.6, high: 18.4, low: 17.4, volume: 5_000, turnover: 90_000,
                  currencyCode: "USD", sourceID: "fictional", sourceName: "Fictional", timestamp: .now),
        ])

        var buy = TradePlan(kind: .buy, price: 17, quantity: 300, note: "fictional side buy")
        buy.positionPool = .strategic
        buy.fundingSource = .margin
        var sell = TradePlan(kind: .sell, price: 21, quantity: 100, note: "fictional side sell")
        sell.positionPool = .strategic
        _ = store.setTradePlan(buy, for: symbol)
        _ = store.setTradePlan(sell, for: symbol)

        defer {
            _ = store.deleteTradePlan(buy.id, for: symbol)
            _ = store.deleteTradePlan(sell.id, for: symbol)
            store.remove(symbol)
        }

        // Render the actual card faces together so both direction colors are
        // visible even when the complete board's plans fall below the fold.
        for scheme in [ColorScheme.dark, .light] {
            let pair = VStack(spacing: 10) {
                ForEach([buy, sell], id: \.id) { plan in
                    PoolPlanCardFace(entry: .init(symbol: symbol, plan: plan), inPool: true,
                        isSelected: false, isPlaceholder: false, onSelect: {}, onEdit: {},
                        onRecord: {}, onInspect: {}, onAssign: { _ in }, onDragChanged: { _ in },
                        onDragEnded: { _ in }, isDraggable: false, tracksFrame: false)
                }
            }
            .padding(18)
            .environment(appState)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 540, height: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            let name = "account-side-cards-\(scheme == .dark ? "dark" : "light")"
            do {
                try renderInOffscreenWindow(view: pair, width: 540, height: 340,
                    to: directory.appendingPathComponent("\(name).png"), scheme: scheme, requiresBoardBand: false)
            } catch { report("account-render", "\(name): \(error)") }
        }

        for state in [PositionPoolsView.TacticalInitialState.current, .preview] {
            let name = state.stance == .preview ? "account-sides-preview" : "account-sides-current"
            let view = PositionPoolsView(onSelect: { _ in }, onShowPlans: {}, tactical: state)
                .environment(appState)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: 1_440, height: 900)
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try renderInOffscreenWindow(view: view, width: 1_440, height: 900, to: url, scheme: .dark)
                print("TACTICAL_BOARD_RENDER \(name) 1440x900 -> \(url.path)")
            } catch { report("account-render", "\(name): \(error)") }
        }

        // The side colours must survive the 红涨绿跌 switch untouched. If they
        // were still the ChangePalette, these two renders would differ.
        let original = appState.settings.redUp
        defer { appState.settings.redUp = original }
        var renderedSidePairs: [(Color, Color)] = []
        for redUp in [true, false] {
            appState.settings.redUp = redUp
            renderedSidePairs.append((PlanSideStyle.buy, PlanSideStyle.sell))
        }
        let view = PositionPoolsView(onSelect: { _ in }, onShowPlans: {}, tactical: .current)
            .environment(appState)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 1_440, height: 900)
        let url = directory.appendingPathComponent("account-sides-redup-off.png")
        do {
            try renderInOffscreenWindow(view: view, width: 1_440, height: 900, to: url, scheme: .dark)
            print("TACTICAL_BOARD_RENDER account-sides-redup-off 1440x900 -> \(url.path)")
        } catch { report("account-render", "account-sides-redup-off: \(error)") }

        // Resolving the two adaptive colours is a value comparison, not a pixel
        // one: the token is one static, so the only way it could track the
        // palette is if it read the palette at all. It does not.
        expect(PlanSideStyle.buy != PlanSideStyle.sell,
               "accounts", "a buy and a sell must never share a side colour")
        expect(renderedSidePairs.count == 2
               && renderedSidePairs[0].0 == renderedSidePairs[1].0
               && renderedSidePairs[0].1 == renderedSidePairs[1].1,
               "accounts", "the side token must be identical under both 红涨绿跌 settings")
    }

    /// The classification sheet with one expanded row, so the per-trade rows and
    /// an existing margin annotation are both on screen.
    private static func renderClassificationSheet(appState: AppState, into directory: URL) {
        let view = BrokerageAccountClassificationSheet(onAssigned: { _ in })
            .environment(appState)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 560, height: 520)
            .background(Color(nsColor: .windowBackgroundColor))

        let url = directory.appendingPathComponent("account-classification-sheet.png")
        do {
            try renderInOffscreenWindow(view: view, width: 560, height: 520,
                                        to: url, scheme: .dark, requiresBoardBand: false)
            print("TACTICAL_BOARD_RENDER account-classification-sheet 560x520 -> \(url.path)")
        } catch { report("account-render", "account-classification-sheet: \(error)") }
    }

    /// The cross-account overview renders.
    ///
    /// The fixture is built inside this function and torn down at the end: the
    /// 44 cases that ran before it must see exactly the board they were written
    /// against, so nothing here is allowed to survive.
    private static func renderAccountOverviewArtifacts(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        let budgets = appState.poolBudgets
        guard store.activeBrokerageAccountID == .unassigned else {
            report("overview-render", "the overview fixture must be seeded from unassigned")
            return
        }

        // Two named accounts with both holdings and cash, plus the legacy book
        // the earlier account fixture left behind — the exact shape the page was
        // specified for.
        let financingSymbol = SymbolID(market: .us, code: "ZZOVFIN")
        let mengmengSymbol = SymbolID(market: .hk, code: "ZZOVMM")
        let staleSymbol = SymbolID(market: .us, code: "ZZOVSTALE")
        let missingSymbol = SymbolID(market: .us, code: "ZZOVNOPX")
        let cnySymbol = SymbolID(market: .sz, code: "009997")

        func seed(_ symbol: SymbolID, name: String, quantity: Double, price: Double?, currency: String,
                  ageSeconds: TimeInterval = 0) {
            if store.item(for: symbol) == nil {
                guard let groupID = store.selectedGroup?.id else { return }
                store.add(SymbolInfo(symbol: symbol, name: name), to: groupID)
            }
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: price ?? 10, quantity: quantity))
            // A quote whose timestamp is pushed past the freshness window still
            // values the holding and must carry the 旧价 badge; a symbol with no
            // quote at all must be excluded and counted as 缺价.
            guard let price else { return }
            appState.market.apply(quotes: [Quote(
                symbol: symbol, name: name, price: price, previousClose: price * 0.98,
                open: price * 0.99, high: price * 1.01, low: price * 0.98,
                volume: 1_000, turnover: price * 1_000, currencyCode: currency,
                sourceID: "fictional", sourceName: "Fictional",
                timestamp: Date.now.addingTimeInterval(-ageSeconds)
            )])
        }

        seed(financingSymbol, name: "虚构融资账号持仓", quantity: 100, price: 40, currency: "USD")
        seed(mengmengSymbol, name: "虚构萌萌账号持仓", quantity: 200, price: 30, currency: "HKD")
        seed(staleSymbol, name: "虚构旧价持仓", quantity: 50, price: 20, currency: "USD", ageSeconds: 86_400)
        seed(missingSymbol, name: "虚构缺价持仓", quantity: 10, price: nil, currency: "USD")

        // own / margin / unmarked intents, so the card breakdown is on screen as
        // three distinct figures rather than one folded number.
        var marginPlan = TradePlan(kind: .buy, price: 38, quantity: 20, note: "虚构融资买入")
        marginPlan.fundingSource = .margin
        var ownPlan = TradePlan(kind: .buy, price: 36, quantity: 10, note: "虚构普通买入")
        ownPlan.fundingSource = .own
        var unmarkedPlan = TradePlan(kind: .buy, price: 35, quantity: 5, note: "虚构未标注买入")
        unmarkedPlan.fundingSource = .unmarked
        var sellPlan = TradePlan(kind: .sell, price: 46, quantity: 15, note: "虚构卖出")
        _ = store.setTradePlan(marginPlan, for: financingSymbol)
        _ = store.setTradePlan(ownPlan, for: financingSymbol)
        _ = store.setTradePlan(unmarkedPlan, for: financingSymbol)
        _ = store.setTradePlan(sellPlan, for: financingSymbol)

        // Move both seeded books into their named accounts, so the grid has two
        // real cards rather than only the legacy collapse.
        _ = store.assignBrokerageRecords(for: financingSymbol, transactionIDs: nil, to: .financing)
        _ = store.assignBrokerageRecords(for: staleSymbol, transactionIDs: nil, to: .financing)
        _ = store.assignBrokerageRecords(for: missingSymbol, transactionIDs: nil, to: .financing)
        _ = store.assignBrokerageRecords(for: mengmengSymbol, transactionIDs: nil, to: .mengmeng)

        _ = budgets.setCashBalance(amount: 25_000, currency: "USD", in: .financing)
        _ = budgets.setCashBalance(amount: 80_000, currency: "HKD", in: .mengmeng)
        // A shared CNY symbol is intentionally held in both independent books.
        for account in [BrokerageAccountID.financing, .mengmeng] {
            store.withBrokerageAccount(account) {
                store.add(SymbolInfo(symbol: cnySymbol, name: "虚构人民币持仓"))
                store.addTransaction(cnySymbol, PositionTransaction(kind: .buy, price: 20,
                    quantity: account == .financing ? 150 : 200))
                var plan = TradePlan(kind: account == .financing ? .buy : .sell,
                    price: account == .financing ? 20 : 25, quantity: 50)
                plan.fundingSource = account == .financing ? .margin : .own
                _ = store.setTradePlan(plan, for: cnySymbol)
            }
            _ = budgets.setCashBalance(amount: account == .financing ? 10_000 : 20_000,
                currency: "CNY", in: account)
        }
        appState.market.apply(quotes: [Quote(symbol: cnySymbol, name: "虚构人民币持仓",
            price: 22, previousClose: 21, sourceName: "Fictional", timestamp: .now)])
        // The active account deliberately has no recorded cash, so the 未录
        // warning and the "N 账号未录现金" line are both exercised.
        let mengmengCashBefore = budgets.cashBalances(for: .mengmeng)

        defer {
            _ = budgets.setCashBalance(amount: nil, currency: "USD", in: .financing)
            _ = budgets.setCashBalance(amount: nil, currency: "HKD", in: .mengmeng)
            for account in [BrokerageAccountID.financing, .mengmeng] {
                _ = budgets.setCashBalance(amount: nil, currency: "CNY", in: account)
                store.withBrokerageAccount(account) { store.remove(cnySymbol) }
            }
            // The instruments now live in named accounts, so each is removed
            // from whichever book holds it. `remove` is the store's own public
            // path, which keeps the ledger bookkeeping consistent rather than
            // reaching around it.
            for symbol in [financingSymbol, mengmengSymbol, staleSymbol, missingSymbol] {
                for account in BrokerageAccountID.allCases {
                    let portfolio = store.brokeragePortfolio(for: account)
                    let present = (portfolio.items + portfolio.retainedHistoryItems)
                        .contains { $0.symbol == symbol }
                    guard present else { continue }
                    store.withBrokerageAccount(account) { store.remove(symbol) }
                }
            }
            _ = store.selectBrokerageAccount(.unassigned)
        }

        let render: (String, CGFloat, CGFloat, ColorScheme, BrokerageAccountOverviewView) -> Void = {
            name, width, height, scheme, content in
            let view = content
                .environment(appState)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: width, height: height)
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try renderInOffscreenWindow(view: view, width: width, height: height,
                                            to: url, scheme: scheme, requiresBoardBand: false)
                print("TACTICAL_BOARD_RENDER \(name) \(Int(width))x\(Int(height)) -> \(url.path)")
            } catch { report("overview-render", "\(name): \(error)") }
        }

        func overview(filter: BrokerageAccountOverviewView.AccountFilter,
                      currency: String?) -> BrokerageAccountOverviewView {
            BrokerageAccountOverviewView(onSelect: { _ in }, onShowPage: { _ in },
                                         filter: filter, currencyCode: currency)
        }

        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for width in [CGFloat(1_000), 1_280] {
                render("overview-\(Int(width))-\(suffix)", width, 900, scheme, overview(filter: .all, currency: "USD"))
            }
        }
        render("overview-hkd-1280", 1_280, 900, .dark, overview(filter: .all, currency: "HKD"))
        render("overview-cny-1280", 1_280, 900, .dark, overview(filter: .all, currency: "CNY"))
        render("overview-filter-financing", 1_280, 900, .dark, overview(filter: .financing, currency: "USD"))
        render("overview-filter-unassigned", 1_280, 900, .dark,
               overview(filter: .unassigned, currency: "USD"))

        // The whole shell at both widths, proving the new page and its sidebar
        // entry fit the real window chrome.
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            for width in [CGFloat(1_000), 1_280] {
                let name = "overview-shell-\(Int(width))-\(suffix)"
                let view = MainWindowView(initialPage: .accounts)
                    .environment(appState)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .frame(width: width, height: 900)
                let url = directory.appendingPathComponent("\(name).png")
                do {
                    try renderInOffscreenWindow(view: view, width: width, height: 900,
                                                to: url, scheme: scheme, requiresBoardBand: false)
                    print("TACTICAL_BOARD_RENDER \(name) \(Int(width))x900 -> \(url.path)")
                } catch { report("overview-render", "\(name): \(error)") }
            }
        }

        // The cash editor over the frozen pair, and the fact that opening it and
        // cancelling changes nothing.
        let cashBefore = budgets.cashBalances(for: .financing)
        let sheet = AccountCashEditorSheet(target: .init(accountID: .financing, currencyCode: "USD"))
            .environment(appState)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(width: 420, height: 260)
            .background(Color(nsColor: .windowBackgroundColor))
        let sheetURL = directory.appendingPathComponent("overview-cash-editor.png")
        do {
            try renderInOffscreenWindow(view: sheet, width: 420, height: 260,
                                        to: sheetURL, scheme: .dark, requiresBoardBand: false)
            print("TACTICAL_BOARD_RENDER overview-cash-editor 420x260 -> \(sheetURL.path)")
        } catch { report("overview-render", "overview-cash-editor: \(error)") }
        expect(budgets.cashBalances(for: .financing) == cashBefore,
               "overview-render", "opening and rendering the cash editor must not write anything")
        expect(budgets.cashBalances(for: .mengmeng) == mengmengCashBefore,
               "overview-render", "rendering the overview must not write another account's cash")

        // The overview is a reader: the portfolios it displayed are unchanged.
        expect(store.brokeragePortfolio(for: .financing).items.contains { $0.symbol == financingSymbol },
               "overview-render", "rendering the overview must not move records out of an account")
    }

    // MARK: - Holdings by active account

    /// Renders the production holdings page under each real active account
    /// selection and proves the render is a pure reader.
    ///
    /// The three cases are the actual selections the page can be opened in:
    /// `unassigned` with the demo's seeded holdings, `financing` genuinely
    /// empty, and `mengmeng` with exactly one synthetic instrument. Nothing
    /// here fabricates rows, labels, or charts: the images are whatever the
    /// production view draws for the real store.
    private static func renderHoldingsAccounts(appState: AppState, into directory: URL) {
        let store = appState.watchlist
        guard store.enableBrokerageAccounts() || store.brokerageAccountsEnabled else {
            report("holdings-account", "named accounts could not be enabled in the isolated suite")
            return
        }

        // A distinct, fictional instrument plus a deterministic synthetic
        // quote. The quote only adds a price; the row must be listed from the
        // position alone, so removing it would not hide the holding.
        let symbol = SymbolID(market: .us, code: "ZZHLDMENG")
        let name = "虚构萌萌持仓"
        let syntheticQuantity = 7.0
        let syntheticPrice = 100.0
        let quotePrice = 123.0

        let unassignedQuantities = quantityMap(store.brokeragePortfolio(for: .unassigned))
        let unassignedHoldings = unassignedQuantities.filter { $0.value > 0 }.count
        expect(unassignedHoldings > 0,
               "holdings-account", "the inline demo must seed unassigned with current holdings")
        print("HOLDINGS_ACCOUNT_BASELINE unassigned holdings=\(unassignedHoldings)")
        fflush(stdout)

        // Seed the one synthetic holding out of band, with the selection pinned
        // back to unassigned afterwards, so the renders below start from the
        // baseline books.
        store.withBrokerageAccount(.mengmeng) {
            store.add(SymbolInfo(symbol: symbol, name: name))
            store.addTransaction(symbol, PositionTransaction(kind: .buy, price: syntheticPrice, quantity: syntheticQuantity))
        }
        appState.market.apply(quotes: [Quote(symbol: symbol, name: name, price: quotePrice,
                                             previousClose: syntheticPrice, timestamp: .now,
                                             marketState: .regular)])
        _ = appState.selectBrokerageAccount(.unassigned)
        expect(store.activeBrokerageAccountID == .unassigned,
               "holdings-account", "the synthetic fixture must leave unassigned selected")

        let mengmengQuantities = quantityMap(store.brokeragePortfolio(for: .mengmeng))
        expect(mengmengQuantities[symbol] == syntheticQuantity,
               "holdings-account", "mengmeng must hold exactly the synthetic quantity")
        let financingQuantities = quantityMap(store.brokeragePortfolio(for: .financing))
        expect(!financingQuantities.values.contains { $0 > 0 },
               "holdings-account", "financing must start with no current holdings")
        expect(store.brokeragePortfolio(for: .financing).items.isEmpty,
               "holdings-account", "financing must start with an empty book")

        let cases: [(account: BrokerageAccountID, file: String)] = [
            (.unassigned, "holdings-account-unassigned.png"),
            (.financing, "holdings-account-financing-empty.png"),
            (.mengmeng, "holdings-account-mengmeng.png"),
        ]
        for item in cases {
            _ = appState.selectBrokerageAccount(item.account)
            expect(store.activeBrokerageAccountID == item.account,
                   "holdings-account", "\(item.account.rawValue) must be the active selection before its render")

            // Pinned readers, taken before the view exists.
            let snapshot = store.syncSnapshot()
            let quantities = quantityMap(store.brokeragePortfolio(for: item.account))
            let unassignedNow = quantityMap(store.brokeragePortfolio(for: .unassigned))
            let expectedHoldings = quantities.filter { $0.value > 0 }.count
            expect(unassignedNow == unassignedQuantities,
                   "holdings-account", "the seeded unassigned quantities changed before the \(item.account.rawValue) render")

            let view = MainHoldingsView(onSelect: { _ in })
                .environment(appState)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.colorScheme, .dark)
                .frame(width: 1_200, height: 820)

            do {
                try renderInOffscreenWindow(view: view, width: 1_200, height: 820,
                    to: directory.appendingPathComponent(item.file),
                    scheme: .dark, requiresBoardBand: false)
                print("HOLDINGS_ACCOUNT_RENDER \(item.account.rawValue) file=\(item.file) holdings=\(expectedHoldings)")
                fflush(stdout)
            } catch {
                report("holdings-account-render", "\(item.account.rawValue) render failed: \(error)")
                continue
            }

            // A real render must be a pure reader of every book.
            expect(store.activeBrokerageAccountID == item.account,
                   "holdings-account", "rendering \(item.account.rawValue) moved the active selection")
            expect(store.syncSnapshot() == snapshot,
                   "holdings-account", "rendering \(item.account.rawValue) changed the compatibility snapshot")
            expect(quantityMap(store.brokeragePortfolio(for: item.account)) == quantities,
                   "holdings-account", "rendering \(item.account.rawValue) changed its own portfolio")
            expect(quantityMap(store.brokeragePortfolio(for: .unassigned)) == unassignedQuantities,
                   "holdings-account", "rendering \(item.account.rawValue) changed the seeded unassigned quantities")
        }

        // Pure snapshot checks, independent of any render.
        expect(!quantityMap(store.brokeragePortfolio(for: .financing)).values.contains { $0 > 0 },
               "holdings-account", "financing must still have no current holdings")
        expect(store.brokeragePortfolio(for: .financing).items.allSatisfy { $0.positionQuantity <= 0 },
               "holdings-account", "financing must expose no positive-position holding")
        expect(quantityMap(store.brokeragePortfolio(for: .mengmeng))[symbol] == syntheticQuantity,
               "holdings-account", "mengmeng must still hold exactly the synthetic quantity")
        expect(quantityMap(store.brokeragePortfolio(for: .unassigned)) == unassignedQuantities,
               "holdings-account", "the unassigned seeded quantities must be unchanged throughout")
    }

    /// Symbol → position quantity for one book, so a comparison names the
    /// symbol instead of relying on row order.
    private static func quantityMap(_ portfolio: BrokerageAccountPortfolio) -> [SymbolID: Double] {
        var quantities: [SymbolID: Double] = [:]
        for item in portfolio.items {
            quantities[item.symbol, default: 0] += item.positionQuantity
        }
        return quantities
    }

    /// Renders `view` through a real offscreen `NSWindow`.
    ///
    /// A hosting view that is merely laid out in isolation does not get the
    /// window-attached, run-loop-driven layout that lazy SwiftUI containers
    /// require, so the pools stay unrealized and the capture comes back empty.
    /// Attaching to a borderless window parked at a large negative origin gives
    /// SwiftUI the real window/display cycle it needs while remaining completely
    /// invisible to the user.
    private static func renderInOffscreenWindow<V: View>(view: V, width: CGFloat, height: CGFloat,
                                                        to url: URL,
                                                        scheme: ColorScheme,
                                                        requiresBoardBand: Bool = true,
                                                        inspect: ((NSView) -> Void)? = nil) throws {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = frame

        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        // Offscreen and inert: no title bar, no shadow, not key, not main.
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.appearance = window.appearance
        // Match the captured scheme so any area the view does not paint blends
        // instead of showing a black band in the light render.
        window.backgroundColor = scheme == .dark ? .black : .white
        window.alphaValue = 1
        window.contentView = hosting
        // Park the window beyond any real display so nothing can be seen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // `orderBack` (never `orderFront`/`makeKeyAndOrderFront`) is enough for
        // AppKit to run the layout/display cycle lazy containers wait on, without
        // the window ever coming forward or stealing focus.
        window.orderBack(nil)

        // Several run-loop turns: SwiftUI lays out, then realizes lazy rows, then
        // settles. A single pass captures before the grid exists.
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        inspect?(hosting)
        // An interaction may dismiss a sheet, change a filter and update lazy
        // rows in separate layout passes. Flush the live post-action host too,
        // not only the pre-interaction layout above, before caching its pixels.
        if inspect != nil {
            for _ in 0..<6 {
                hosting.layoutSubtreeIfNeeded()
                hosting.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
        }

        defer { window.orderOut(nil) }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ShareImageError.renderingFailed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        // Guard against the failure mode this harness was rewritten to fix:
        // a "successful" capture whose board region is empty. A board with four
        // pool columns necessarily has ink across the middle band; if that band
        // is essentially uniform, the lazy content never materialized and the
        // image must not be reported as a pass.
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShareImageError.encodingFailed
        }
        try data.write(to: url)
        // Synthetic artifacts only. Export through stdout for review when the
        // app sandbox owns the render directory and the host cannot read it.
        if CommandLine.arguments.contains("--export-render-base64") {
            print("PULSE_RENDER_BASE64 \(url.lastPathComponent) \(data.base64EncodedString())")
            fflush(stdout)
        }
        // Compact sheets may legitimately leave the middle band empty. Check
        // their full frame, while retaining the stricter pool-board check.
        if let blank = blankRegionReport(rep: rep, width: width, height: height, boardBand: requiresBoardBand) {
            throw TacticalRenderError.boardRegionBlank(blank)
        }
    }

    /// Returns a description when the pool-board band looks empty, else nil.
    ///
    /// The band spans the middle of the frame, below the header/action bar and
    /// above the bottom drawer. Distinct colors there mean the columns rendered.
    private static func blankRegionReport(rep: NSBitmapImageRep,
                                          width: CGFloat, height: CGFloat,
                                          boardBand: Bool = true) -> String? {
        let pxW = rep.pixelsWide
        let pxH = rep.pixelsHigh
        guard pxW > 0, pxH > 0 else { return "bitmap has no pixels" }

        // Sample the board band: 45%..80% of the height, 4%..96% of the width.
        let y0 = Int(Double(pxH) * (boardBand ? 0.45 : 0.04))
        let y1 = Int(Double(pxH) * (boardBand ? 0.80 : 0.96))
        let x0 = Int(Double(pxW) * 0.04), x1 = Int(Double(pxW) * 0.96)
        guard y1 > y0, x1 > x0 else { return nil }
        let colorSpace = rep.colorSpace

        var samples = Set<UInt32>()
        var total = 0
        var row = y0
        while row < y1 {
            var col = x0
            while col < x1 {
                if let color = rep.colorAt(x: col, y: row)?.usingColorSpace(colorSpace) {
                    let r = UInt32(color.redComponent * 255)
                    let g = UInt32(color.greenComponent * 255)
                    let b = UInt32(color.blueComponent * 255)
                    samples.insert(r << 16 | g << 8 | b)
                    total += 1
                }
                col += 4
            }
            row += 4
        }
        guard total > 0 else { return "no sampleable pixels in the board band" }
        // A rendered board shows card backgrounds, pool tints, borders and text,
        // which cannot collapse to a handful of flat colors.
        if samples.count < 12 {
            return "board band looks blank (\(samples.count) distinct colors over \(total) samples)"
        }
        return nil
    }

    // MARK: - Helpers

    private static func planID(in state: AppState, symbol: SymbolID) -> UUID? {
        state.watchlist.item(for: symbol)?.plans.first { $0.kind == .buy && $0.status == .active }?.id
    }

    private static func currencyTotals(_ result: PoolBudgetProjection.Result) -> [String: Double] {
        var totals: [String: Double] = [:]
        for currency in result.currencies {
            totals[currency.code] = currency.pools.reduce(0) {
                $0 + $1.heldAmount + $1.plannedBuyAmount
            }
        }
        return totals
    }

    private static func expect(_ condition: Bool, _ scope: String, _ message: String) {
        if !condition { report(scope, message) }
    }

    private static func report(_ scope: String, _ message: String) {
        failures.append("[\(scope)] \(message)")
    }

    private static func finish() -> Bool {
        if failures.isEmpty {
            print("PULSE_TACTICAL_BOARD_SELFTEST passed")
            fflush(stdout)
            return true
        }
        for failure in failures { print("PULSE_TACTICAL_BOARD_SELFTEST failure \(failure)") }
        print("PULSE_TACTICAL_BOARD_SELFTEST failed count=\(failures.count)")
        fflush(stdout)
        return false
    }
}
#endif
