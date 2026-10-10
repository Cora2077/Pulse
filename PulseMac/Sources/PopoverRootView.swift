import AppKit
import Combine
import SwiftUI
import PulseCore

enum PopoverRoute: Hashable {
    case list
    /// Cross-symbol trade-plan overview, reached from the home bottom bar.
    /// Unlike the position flow it carries no return route: it is pushed
    /// straight off the list, so back is always the list.
    case planList
    case detail(SymbolID)
    /// Position hub: summary, trade actions, and recent transactions.
    case position(SymbolID, PositionReturnRoute)
    /// Single-trade entry form; the side is fixed by the entry point.
    case trade(SymbolID, TradeSide, PositionReturnRoute)
    /// Edit form for one recorded transaction, reached from the trade log.
    case editTrade(SymbolID, UUID, PositionReturnRoute)
    /// Full transaction log.
    case transactions(SymbolID, PositionReturnRoute)
    /// Quick set: overwrite quantity + average cost as one calibration entry.
    case calibrate(SymbolID, PositionReturnRoute)
    /// Trade plan editor. The second value is the plan being edited; nil
    /// creates a new one.
    case plan(SymbolID, UUID?, PositionReturnRoute)
    /// Full business summary, pushed from the detail page's excerpt.
    case profile(SymbolID)
    case settings
    /// Second-level list for one class of data sources; the split keeps the
    /// settings root short as sources accumulate.
    case providerList(ProviderListKind)
    case providerDetail(String)
    /// Import and export, kept off the settings list so it stays a short page.
    case dataSettings
    /// Menu bar display and market presentation, nested so the settings root stays short.
    case appearanceSettings
    /// Local MCP agent endpoint: enable toggle and connection fields.
    case mcpSettings

    /// These forms keep their source account and fields across a switch.
    var preservesAccountDraft: Bool {
        switch self {
        case .trade, .editTrade, .plan, .calibrate: true
        default: false
        }
    }
}

/// The two provider classes in settings: sources the user connects with their
/// own account, and built-ins that just work.
enum ProviderListKind: Hashable {
    case accounts
    case builtin
}

enum TradeSide: Hashable {
    case buy
    case sell
}

enum PositionReturnRoute: Hashable {
    case list
    case detail(SymbolID)
    /// The cross-symbol plan overview. The plan editor is reachable from it,
    /// and coming back from an edit has to land on the overview rather than
    /// jumping to a different page.
    case planList

    var popoverRoute: PopoverRoute {
        switch self {
        case .list:
            .list
        case .detail(let symbol):
            .detail(symbol)
        case .planList:
            .planList
        }
    }
}

struct PopoverRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pulseHost) private var host
    @State private var route: PopoverRoute
    @State private var draftRouteAccount: BrokerageAccountID?
    /// The standalone window animates this staged value alongside route motion.
    /// Owning the height explicitly keeps the lower-edge resize predictable while
    /// the retained watchlist preserves its title-bar safe area during exit.
    @State private var pinnedPresentedHeight: CGFloat?
    /// Search UI state lives at the root so pushing a detail page and coming back
    /// preserves the query, active state, and cached results.
    @State private var searchSession = SearchSession()
    /// Live size during a grip drag, persisted only on release and discarded if
    /// the panel closes mid-gesture.
    @State private var transientHeight: CGFloat?
    /// The menu-bar panel's window, kept for screen-budget math and for resizing
    /// the real window from the grip.
    @State private var hostWindow: NSWindow?
    /// Screen budget is observable so display changes also relayout the pages.
    @State private var menuBarMaximumHeight: CGFloat = 900

    init(initialRoute: PopoverRoute = .list) {
        _route = State(initialValue: initialRoute)
    }

    private static let minHeight: CGFloat = 300
    private static let minListHeight: CGFloat = 220
    private static let maxHeight: CGFloat = 600
    private static let searchHeight: CGFloat = 480
    private static let listChromeHeight: CGFloat = 110
    /// The brand-and-actions row plus the stack spacing below it.
    private static let headerRowHeight: CGFloat = 33
    private static let listRowHeight: CGFloat = 48

    /// Children push in from the trailing edge and pop back out the same way
    /// (spatial consistency: a screen exits along the path it entered).
    private var pushTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
    }

    /// A child route whose symbol has been removed from the watchlist resolves
    /// back to the list; the stale `route` value is overwritten by the next push.
    private var displayRoute: PopoverRoute {
        if route.preservesAccountDraft { return route }
        switch route {
        case .position(let symbol, _), .trade(let symbol, _, _),
             .transactions(let symbol, _), .calibrate(let symbol, _):
            return appState.watchlist.item(for: symbol) == nil ? .list : route
        case .plan(let symbol, let planID, let returnRoute):
            // A plan deleted out from under the editor (or a symbol leaving the
            // watchlist) falls back to the page it was opened from.
            guard let item = appState.watchlist.item(for: symbol) else { return .list }
            guard let planID else { return route }
            return item.plans.contains(where: { $0.id == planID })
                ? route
                : returnRoute.popoverRoute
        case .editTrade(let symbol, let id, let returnRoute):
            // A transaction deleted out from under the edit page (or a symbol
            // leaving the watchlist) falls back to the log it came from.
            guard let item = appState.watchlist.item(for: symbol) else { return .list }
            return item.transactions.contains(where: { $0.id == id })
                ? route
                : .transactions(symbol, returnRoute)
        default:
            return route
        }
    }

    var body: some View {
        // ZStack lets the outgoing and incoming routes overlap during the push/pop
        // instead of stacking; one transaction drives both the swap and the height.
        // Each route is pinned to its own target height: while the container height
        // animates, the per-frame cost is clipping/compositing only — without the
        // pin, both live view trees would relayout on every frame of the resize,
        // which is what made pushes stutter.
        ZStack(alignment: .top) {
            // The list is the navigation root and stays mounted while children
            // sit on top of it, so its List scroll position survives the round
            // trip. Covered, it is disabled and nudged out along the leading
            // edge, tracing the same path its old removal transition drew.
            WatchlistView(route: $route, searchSession: $searchSession)
                .frame(height: height(for: .list))
                .opacity(displayRoute == .list ? 1 : 0)
                .offset(x: displayRoute == .list || reduceMotion ? 0 : -24)
                .disabled(displayRoute != .list)

            switch displayRoute {
            case .list:
                EmptyView()
            case .planList:
                PlanListView(route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .detail(let symbol):
                DetailView(symbol: symbol, route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .position(let symbol, let returnRoute):
                PositionHubView(symbol: symbol, returnRoute: returnRoute, route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .trade(let symbol, let side, let returnRoute):
                TradeEntryView(symbol: symbol, side: side, returnRoute: returnRoute, route: $route,
                               account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .editTrade(let symbol, let id, let returnRoute):
                if let transaction = draftItem(for: symbol)?
                    .transactions.first(where: { $0.id == id }) {
                    TradeEntryView(
                        symbol: symbol,
                        editing: transaction,
                        returnRoute: returnRoute,
                        route: $route,
                        account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID
                    )
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
                }
            case .transactions(let symbol, let returnRoute):
                TransactionListView(symbol: symbol, returnRoute: returnRoute, route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .plan(let symbol, let planID, let returnRoute):
                PlanEditorView(
                    symbol: symbol,
                    planID: planID,
                    returnRoute: returnRoute,
                    route: $route,
                    account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID
                )
                .frame(height: height(for: displayRoute))
                .transition(pushTransition)
            case .calibrate(let symbol, let returnRoute):
                let account = draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID
                VStack(spacing: 0) {
                    // The panel's compact editor has Cancel at the bottom. In a window,
                    // every pushed page also needs the same visible navigation row as
                    // the rest of the position flow.
                    if host == .pinnedWindow {
                        PositionPageHeader(
                            symbol: symbol,
                            title: nil,
                            accountCaption: AccountIdentity.title(account),
                            onBack: { route = .position(symbol, returnRoute) }
                        )
                    }
                    AccountDraftNotice(account: account).padding(.horizontal, 12)
                    if let item = draftItem(for: symbol) {
                        PositionEditorView(
                            item: item,
                            quote: appState.market.quote(for: symbol),
                            palette: appState.palette,
                            onCancel: { route = .position(symbol, returnRoute) },
                            onSave: { quantity, cost in
                                guard appState.watchlist.activeBrokerageAccountID == account else { return }
                                appState.watchlist.calibratePosition(symbol, quantity: quantity, averageCost: cost)
                                route = .position(symbol, returnRoute)
                            },
                            onClear: {
                                guard appState.watchlist.activeBrokerageAccountID == account else { return }
                                appState.watchlist.clearPosition(symbol)
                                route = .position(symbol, returnRoute)
                            }
                        )
                    }
                }
                .frame(height: height(for: displayRoute))
                .transition(pushTransition)
            case .profile(let symbol):
                ProfileView(symbol: symbol, route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .settings:
                SettingsView(route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .dataSettings:
                DataSettingsView(route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .appearanceSettings:
                AppearanceSettingsView(route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .mcpSettings:
                MCPSettingsView(route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .providerList(let kind):
                ProviderListView(kind: kind, route: $route)
                    .frame(height: height(for: displayRoute))
                    .transition(pushTransition)
            case .providerDetail(let id):
                Group {
                    if id == LongbridgeProvider.providerID {
                        LongbridgeSetupView(route: $route)
                    } else if id == FuyaoProvider.providerID {
                        FuyaoSetupView(route: $route)
                    } else if let descriptor = appState.providerDescriptors.first(where: { $0.id == id }) {
                        ProviderDetailView(descriptor: descriptor, route: $route)
                    }
                }
                .frame(height: height(for: displayRoute))
                .transition(pushTransition)
            }
        }
        .frame(width: panelWidth, height: presentedHeight, alignment: .top)
        // The panel's own window, needed to read its screen budget and to resize it
        // from the footer. Reading it off the view hierarchy avoids matching
        // SwiftUI's private `MenuBarExtra` panel class by name.
        .background {
            HostWindowReader { window in
                guard host == .menuBar else { return }
                // Do not publish state from an NSView layout/update callback.
                DispatchQueue.main.async {
                    hostWindow = window
                    refreshMenuBarScreenBudget()
                }
            }
        }
        .modifier(MenuBarResizeFooter(
            isEnabled: host == .menuBar,
            height: PopoverPanelSizing.gripHeight,
            currentHeight: presentedHeight,
            minimumHeight: { resolvedMinimumHeight(for: displayRoute) },
            maximumHeight: { availableMaximumHeight() },
            onChange: { height in
                guard host == .menuBar else { return }
                // Dragging has to feel attached to the pointer: no implicit
                // animation, and no route animation re-entering the size.
                withoutResizeAnimation {
                    transientHeight = height
                }
            },
            onCommit: { height in
                guard host == .menuBar else { return }
                // Re-clamp at commit time: the window may have moved to a display
                // with less room between the last drag event and the release.
                let committed = PopoverPanelSizing.resolveHeight(
                    preferred: height,
                    automatic: automaticHeight(for: displayRoute),
                    minimum: resolvedMinimumHeight(for: displayRoute),
                    maximum: availableMaximumHeight()
                )
                withoutResizeAnimation {
                    appState.settings.setMenuBarPanelHeight(committed)
                    transientHeight = nil
                }
                resizePanelWindow(to: committed)
            },
            onReset: {
                guard host == .menuBar else { return }
                withoutResizeAnimation {
                    appState.settings.setMenuBarPanelHeight(nil)
                    transientHeight = nil
                }
                resizePanelWindow(to: resolvedMenuBarHeight)
            }
        ))
        // Keep one title-bar skeleton mounted for the lifetime of the pinned
        // window. Route-specific views contribute actions, but an actionless page
        // no longer collapses the bar from 52pt to the empty 32pt window strip.
        .toolbar {
            if host == .pinnedWindow {
                FlexibleToolbarSpacer()
            }
        }
        .background {
            EscapeBackMonitor {
                guard let previousRoute = previousRoute(for: displayRoute) else { return false }
                route = previousRoute
                return true
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.28), value: displayRoute)
        .animation(.snappy(duration: 0.28), value: searchSession.isActive)
        // Height changes from the grip use a disabled-animation transaction.
        .onAppear {
            if host == .pinnedWindow {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pinnedPresentedHeight = height(for: displayRoute)
                }
            }
            if host == .menuBar { refreshMenuBarScreenBudget() }
            appState.setHostVisible(host, true)
            // Product analytics counts panel opens only; the pinned window stays up for
            // hours at a time and would otherwise read as a single enormous session.
            if host == .menuBar { PulseTelemetry.signal(.popoverOpened) }
        }
        .onChange(of: hostWindow) { _, _ in
            refreshMenuBarScreenBudget()
        }
        .onDisappear {
            appState.setHostVisible(host, false)
            // A panel closed mid-drag must not leave a half-finished gesture behind
            // that the next presentation would commit.
            var cancelTransaction = Transaction(animation: nil)
            cancelTransaction.disablesAnimations = true
            withTransaction(cancelTransaction) {
                transientHeight = nil
            }
            // Closing the host ends the current search presentation.
            // Keep the result cache warm, but reopen on the normal watchlist.
            searchSession.text = ""
            searchSession.isActive = false
            // SwiftUI retains a closed Window scene and its @State. Without an
            // explicit reset, re-pinning can resurrect the detail/settings route
            // that happened to be open when the user closed the window.
            if host == .pinnedWindow {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    route = .list
                    pinnedPresentedHeight = height(for: .list)
                }
            }
        }
        .onChange(of: height(for: displayRoute)) { _, targetHeight in
            guard host == .pinnedWindow else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                pinnedPresentedHeight = targetHeight
            }
        }
        .onChange(of: presentedHeight) { _, _ in
            guard host == .menuBar else { return }
            DispatchQueue.main.async { resizePanelWindow(to: presentedHeight) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            guard let changed = note.object as? NSWindow, changed === hostWindow else { return }
            refreshMenuBarScreenBudget()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshMenuBarScreenBudget()
        }
        .onChange(of: appState.watchlist.quoteSymbols) { _, _ in
            appState.watchlistSymbolsChanged()
        }
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            guard route != .list else { return }
            if route.preservesAccountDraft { return }
            // The shared market detail can contain an in-place thesis draft.
            if case .detail = route { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                route = .list
                searchSession = SearchSession()
                pinnedPresentedHeight = height(for: .list)
            }
        }
        .onChange(of: route) { _, newRoute in
            draftRouteAccount = newRoute.preservesAccountDraft
                ? appState.watchlist.activeBrokerageAccountID : nil
            // Reframe the panel for the route just entered (or for its automatic
            // size when a manual height is stored). Deferred: the route's body has
            // to be installed before the window is measured.
            DispatchQueue.main.async { refreshMenuBarScreenBudget() }
        }
        .onChange(of: appState.sharedWatchlist.groups.map(\.id)) { _, _ in
            appState.watchlistGroupsChanged()
        }
    }

    private func draftItem(for symbol: SymbolID) -> WatchItem? {
        appState.watchlist.draftItem(for: symbol,
            account: draftRouteAccount ?? appState.watchlist.activeBrokerageAccountID)
    }

    /// The pinned window animates this value alongside the page transition.
    /// Menu-bar panels resolve the same value through the resizer: a drag first,
    /// then the stored manual height, then the route's automatic size.
    private var presentedHeight: CGFloat {
        switch host {
        case .pinnedWindow:
            pinnedPresentedHeight ?? height(for: displayRoute)
        case .menuBar:
            resolvedMenuBarHeight
        case .mainWindow:
            height(for: displayRoute)
        }
    }

    /// Menu-bar panel height: live drag, then the explicit user height, then the
    /// route's automatic height. Total content points, grip included.
    private var resolvedMenuBarHeight: CGFloat {
        PopoverPanelSizing.resolveHeight(
            preferred: transientHeight ?? appState.settings.menuBarPanelHeight,
            automatic: automaticHeight(for: displayRoute),
            minimum: layoutMinimumHeight(for: displayRoute),
            maximum: availableMaximumHeight()
        )
    }

    /// A compact automatic watchlist keeps its old size until a manual drag.
    private func layoutMinimumHeight(for route: PopoverRoute) -> CGFloat {
        let minimum = resolvedMinimumHeight(for: route)
        guard transientHeight == nil && appState.settings.menuBarPanelHeight == nil else { return minimum }
        return min(automaticHeight(for: route), minimum)
    }

    /// Existing automatic budgets remain the default; manual sizing adds space
    /// to the actual page, not a blank area below its fixed-height scroll view.
    private func automaticHeight(for route: PopoverRoute) -> CGFloat {
        pageBudget(for: route) + (host == .menuBar ? PopoverPanelSizing.gripHeight : 0)
    }

    private func height(for route: PopoverRoute) -> CGFloat {
        guard host == .menuBar else { return pageBudget(for: route) }
        let total = PopoverPanelSizing.resolveHeight(
            preferred: transientHeight ?? appState.settings.menuBarPanelHeight,
            automatic: automaticHeight(for: route),
            minimum: layoutMinimumHeight(for: route),
            maximum: availableMaximumHeight()
        )
        return max(0, total - PopoverPanelSizing.gripHeight)
    }

    private func availableMaximumHeight() -> CGFloat { menuBarMaximumHeight }

    /// Smallest total height this route may be dragged to. Scrolling pages can
    /// shrink to the shared floor; fixed forms and detail keep the budget they
    /// need to lay out, so the shrink can never clip their fields.
    private func resolvedMinimumHeight(for route: PopoverRoute) -> CGFloat {
        let total = automaticHeight(for: route)
        guard host == .menuBar else { return total }
        if Self.isScrollable(route) {
            return min(PopoverPanelSizing.minimumHeight, availableMaximumHeight())
        }
        return min(total, availableMaximumHeight())
    }

    /// Routes whose height is a window onto scrolling content rather than a budget
    /// for a fixed form: these can shrink to the shared minimum.
    private static func isScrollable(_ route: PopoverRoute) -> Bool {
        switch route {
        case .list, .planList, .transactions, .settings, .providerList, .providerDetail,
             .dataSettings, .appearanceSettings, .mcpSettings, .profile, .plan:
            true
        case .position, .trade, .editTrade, .calibrate, .detail:
            false
        }
    }

    /// Grows or shrinks the real panel window from its top-left corner, which is
    /// what keeps the header and the menu-bar anchor fixed while the bottom edge
    /// moves. Width is never touched.
    private func resizePanelWindow(to height: CGFloat) {
        guard host == .menuBar, let window = hostWindow else { return }
        let overhead = window.frame.height - window.contentLayoutRect.height
        let target = max(0, height + max(0, overhead))
        guard target.isFinite, target > 0 else { return }
        if abs(window.frame.height - target) < 0.5 { return }
        var frame = window.frame
        frame.origin.y = frame.maxY - target
        frame.size.height = target
        window.setFrame(frame, display: true)
    }

    /// Re-asks the screen how much room the panel has. The window moves between
    /// displays (and the displays change), so a remembered height may need
    /// clamping — without rewriting the stored preference just because a smaller
    /// screen could not show all of it.
    private func refreshMenuBarScreenBudget() {
        guard host == .menuBar, let window = hostWindow else { return }
        let maximum = PopoverPanelSizing.maximumHeight(for: window)
        withoutResizeAnimation {
            menuBarMaximumHeight = maximum
        }
        resizePanelWindow(to: resolvedMenuBarHeight)
    }

    private func withoutResizeAnimation(_ updates: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, updates)
    }

    /// The pinned window lifts the watchlist's brand-and-actions row into its title bar,
    /// so the list page there is exactly that row shorter.
    private var listChromeHeight: CGFloat {
        host == .pinnedWindow ? Self.listChromeHeight - Self.headerRowHeight : Self.listChromeHeight
    }

    private func previousRoute(for route: PopoverRoute) -> PopoverRoute? {
        switch route {
        case .list:
            nil
        case .detail:
            .list
        case .position(_, let returnRoute):
            returnRoute.popoverRoute
        case .trade(let symbol, _, let returnRoute),
             .transactions(let symbol, let returnRoute),
             .calibrate(let symbol, let returnRoute):
            .position(symbol, returnRoute)
        case .plan(_, _, let returnRoute):
            returnRoute.popoverRoute
        case .editTrade(let symbol, _, let returnRoute):
            // Editing is launched from the trade log, so Escape goes back to it.
            .transactions(symbol, returnRoute)
        case .profile(let symbol):
            .detail(symbol)
        case .settings, .planList:
            .list
        case .providerList, .dataSettings, .appearanceSettings, .mcpSettings:
            .settings
        case .providerDetail(let id):
            .providerList(appState.providerListKind(for: id))
        }
    }

    /// The menu bar panel is pinned to the width its popover needs. A pinned
    /// window is a real window the user leaves open, so it opens wider. The
    /// watchlist measures its title and metric columns rather than scaling
    /// them, so the extra width lands in the sparkline between them.
    private var panelWidth: CGFloat {
        host == .pinnedWindow ? 520 : 340
    }

    /// The detail page is a fixed-height stack with one flexible block (the
    /// chart) in the middle, so anything added to it comes out of the chart.
    /// The trade-plan block is measured by `PlanSection` and granted here, up
    /// to the host's own ceiling; without this the block would simply push the
    /// thesis section past the bottom edge, where it gets clipped.
    private func detailHeight(for symbol: SymbolID) -> CGFloat {
        guard plansApply(to: symbol) else { return 560 }
        let planCount = appState.watchlist.item(for: symbol)?.plans.count ?? 0
        return min(Self.maxHeight, 560 + PlanSection.sectionHeight(planCount: planCount))
    }

    /// Mirrors `DetailView.symbolSupportsPosition`: an index is a calculated
    /// benchmark and a metal quote is a futures contract whose size Pulse does
    /// not model, so neither can hold a position — or a plan for one.
    private func plansApply(to symbol: SymbolID) -> Bool {
        if symbol.indexID != nil || symbol.metalID != nil { return false }
        guard let item = appState.sharedWatchlist.item(for: symbol)
            ?? appState.watchlist.item(for: symbol) else { return true }
        return item.supportsPosition
    }

    /// The list page height adapts to the watchlist size (chrome, row height, bottom bar, and padding),
    /// clamped between the min and max. This is the page's own budget: the
    /// menu-bar panel adds the resize footer strip on top of it in `height(for:)`.
    private func pageBudget(for route: PopoverRoute) -> CGFloat {
        let noticeHeight: CGFloat = route.preservesAccountDraft
            && draftRouteAccount != nil
            && draftRouteAccount != appState.watchlist.activeBrokerageAccountID ? 54 : 0
        switch route {
        case .list:
            // The search panel needs room for results/recents regardless of list size.
            if searchSession.isActive { return Self.searchHeight }
            let content = listChromeHeight + CGFloat(appState.sharedWatchlist.items.count) * Self.listRowHeight
            let minimum = appState.sharedWatchlist.items.isEmpty ? Self.minHeight : Self.minListHeight
            return min(max(content, minimum), Self.maxHeight)
        case .detail(let symbol):
            return detailHeight(for: symbol)
        case .profile:
            return 440
        case .position(let symbol, _):
            // Summary + trade actions + recent trades once anything has been
            // traded; only a symbol with no history at all gets the compact
            // pitch for recording a first trade. The held-position page is now
            // budgeted from the measured height above the trade rows plus one
            // row per trade, so it neither leaves the old 40pt of dead space
            // nor crowds the rows it shows.
            guard let item = appState.watchlist.item(for: symbol) else { return 360 }
            if item.hasPosition {
                let rows = min(
                    item.ledger?.entries.count ?? 0,
                    PositionHubView.visibleTransactionCount
                )
                return PositionHubView.summaryHeightAboveTrades
                    + CGFloat(rows) * PositionHubView.transactionRowHeight
            }
            // A closed position stacks fewer blocks; it still uses the older
            // fixed heights until it is measured the same way.
            return item.transactions.isEmpty ? 300 : 380
        case .trade(_, .buy, _):
            // Account and buy method each have a labelled row before the
            // confirmation; leave room for both in the menu-bar panel.
            return (host == .pinnedWindow ? 420 : 390) + noticeHeight
        case .trade, .editTrade:
            // The entry form is a stack of labelled fields. The panel gets the
            // tightest budget that still fits them; a pinned window can afford
            // the room to breathe.
            return (host == .pinnedWindow ? 420 : 330) + noticeHeight
        case .transactions:
            return 500
        case .planList:
            // A scrolling page, so the height is a window rather than a
            // budget: the same order of magnitude as the trade log above.
            return host == .pinnedWindow ? 520 : 460
        case .calibrate:
            return 370 + noticeHeight
        case .plan:
            // A labelled form: kind, two input cells, note, status, amount.
            // The pinned window has the room to breathe.
            return (host == .pinnedWindow ? 420 : 380) + noticeHeight
        case .settings:
            // Root is an index of destinations; keep it short so agents and data stay on-screen.
            return 460
        case .providerList, .providerDetail, .dataSettings, .appearanceSettings, .mcpSettings:
            return 540
        }
    }
}

/// `MenuBarExtra` closes its window before SwiftUI's exit-command handlers
/// receive Escape. Monitor the host window directly so child routes can consume
/// Escape as back, while events in nested popovers and the root list retain
/// their normal system behavior.
private struct EscapeBackMonitor: NSViewRepresentable {
    let onEscape: () -> Bool

    func makeNSView(context: Context) -> EscapeBackMonitorView {
        let view = EscapeBackMonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: EscapeBackMonitorView, context: Context) {
        view.onEscape = onEscape
    }

    static func dismantleNSView(_ view: EscapeBackMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

@MainActor
private final class EscapeBackMonitorView: NSView {
    var onEscape: () -> Bool = { false }
    private var monitor: Any?
    private var isConsumingEscape = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let hostWindow = window else { return }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]
        ) { [weak self, weak hostWindow] event in
            guard event.keyCode == 53, event.window === hostWindow, let self else {
                return event
            }

            if event.type == .keyUp {
                guard self.isConsumingEscape else { return event }
                self.isConsumingEscape = false
                return nil
            }
            if event.isARepeat {
                return self.isConsumingEscape ? nil : event
            }
            guard self.onEscape() else { return event }
            self.isConsumingEscape = true
            return nil
        }
    }

    func removeMonitor() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        isConsumingEscape = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// The child pages reserve this strip in their resolved frame heights, so the
/// bottom-aligned footer is outside scrolling content, never on top of actions.
private struct MenuBarResizeFooter: ViewModifier {
    let isEnabled: Bool
    let height: CGFloat
    let currentHeight: CGFloat
    let minimumHeight: () -> CGFloat
    let maximumHeight: () -> CGFloat
    let onChange: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void
    let onReset: () -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if isEnabled {
                PopoverResizeGrip(
                    currentHeight: { currentHeight },
                    minimumHeight: minimumHeight,
                    maximumHeight: maximumHeight,
                    onChange: onChange,
                    onEnd: onCommit,
                    onReset: onReset
                )
                .frame(height: height)
            }
        }
    }
}
