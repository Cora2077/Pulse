import SwiftUI
import PulseCore
import PulseUI

/// The global pages the sidebar can show. It is `internal` rather than private
/// to this file because the sidebar has to render the current one: the entry
/// list and the page it highlights are the same vocabulary, so they share one
/// type instead of agreeing by convention on six loose closures.
enum MainWorkspacePage: String, CaseIterable, Identifiable, Hashable {
    case accounts
    case workbench
    case positionPools
    case holdings
    case plans
    case events
    case journal

    var id: String { rawValue }

    /// Which purpose group the sidebar files this entry under.
    ///
    /// `allCases` order is the sidebar's within-group order, so `.accounts`
    /// leads 资金: an overview of every account is what the money group is
    /// about, and the single-account pages below it are the detail.
    var group: SidebarGroup {
        switch self {
        case .workbench: .today
        case .accounts, .positionPools, .holdings: .capital
        case .plans, .events: .planAndEvent
        case .journal: .review
        }
    }

    /// The sidebar entry title. Reuses the page's own title key where one
    /// already exists, so the entry and the page it opens can never disagree.
    var title: String {
        switch self {
        case .accounts:
            MainWorkspacePage.copy("账号总览", "Accounts")
        case .workbench:
            MainWorkspacePage.copy("今日工作台", "Today")
        case .positionPools:
            MainWorkspacePage.copy("仓位池", "Position Pools")
        case .holdings:
            PulseLocalization.localizedString("main.holdings.title")
        case .plans:
            PulseLocalization.localizedString("plan.list.title")
        case .events:
            MainWorkspacePage.copy("事件日历", "Events")
        case .journal:
            MainWorkspacePage.copy("交易复盘", "Journal")
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "building.columns.2"
        case .workbench: "square.grid.2x2"
        case .positionPools: "rectangle.stack"
        case .holdings: "briefcase"
        case .plans: "scope"
        case .events: "calendar"
        case .journal: "book.closed"
        }
    }

    /// The two languages the app UI is written in for strings that live in the
    /// source rather than the string tables — the same helper the position-pool
    /// board uses for its own local copy.
    static func copy(_ chinese: String, _ english: String) -> String {
        PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") ? chinese : english
    }

    /// The sidebar's purpose groups, declared here so `group` and the sidebar's
    /// rendering order cannot drift apart.
    enum SidebarGroup: String, CaseIterable, Identifiable {
        case today
        case capital
        case planAndEvent
        case review

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today:
                MainWorkspacePage.copy("今日", "Today")
            case .capital:
                MainWorkspacePage.copy("资金", "Capital")
            case .planAndEvent:
                MainWorkspacePage.copy("计划与事件", "Plans & Events")
            case .review:
                MainWorkspacePage.copy("复盘", "Review")
            }
        }

        var pages: [MainWorkspacePage] {
            MainWorkspacePage.allCases.filter { $0.group == self }
        }
    }
}

/// Where an instrument was opened from, so the full-instrument overlay can name
/// the page it returns to.
struct OverviewPageReturn: Hashable {
    let page: MainWorkspacePage
    let symbol: SymbolID
}

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedSymbol: SymbolID?
    @State private var route: PopoverRoute?
    @State private var deferredAlert: BrokerageAlertTarget?
    @State private var overview: MainWorkspacePage?
    /// The page that asked to inspect a symbol, kept so returning from the full
    /// instrument can say where it returns to.
    @State private var overviewReturn: OverviewPageReturn?
    /// The symbol whose summary inspector is open over the origin page. While
    /// this is set the origin page stays in the hierarchy and keeps its own
    /// state: filters, sort order, scroll position, and list selection.
    @State private var summarySymbol: SymbolID?
    /// Whether the full instrument is showing *over* the origin page rather
    /// than as a page of its own. Only the overlay form offers 返回来源; a
    /// watchlist row or a `.detail` route keeps the existing push behaviour.
    @State private var instrumentOverlay = false
    @State private var refreshGeneration = 0
    @State private var showRiskCalculator = false
    @State private var positionPoolsPreparationError: String?
    /// Whether the classification sheet is open over the current page.
    @State private var showAccountClassification = false
    /// Rebuilds account-specific financial pages after a switch. The shared
    /// watchlist and chart keep their identities and current selection.
    @State private var accountGeneration = 0
    @AppStorage("pulse.mainWindow.selectedSymbol.v1") private var selectedSymbolStorage = ""

    /// The page the sidebar should mark as current.
    ///
    /// The summary inspector is a panel *on* its page — the page is still on
    /// screen and still owns the user's filter, sort and scroll — so it stays
    /// highlighted there. The full instrument is a different surface, so it
    /// clears the highlight: opening a position from 资金 must not leave 资金
    /// lit while the instrument covers it.
    private var currentPage: MainWorkspacePage? {
        guard !instrumentOverlay else { return nil }
        return overview
    }

    init() {}

    #if DEBUG
    /// Lets the primary agent synthesise a specific global page for native
    /// rendering. It only seeds the same `@State` the normal path writes, so
    /// the production `init()` above is untouched.
    init(initialPage: MainWorkspacePage, inspectedSymbol: SymbolID? = nil, fullInstrument: Bool = false) {
        _overview = State(initialValue: initialPage)
        _summarySymbol = State(initialValue: inspectedSymbol)
        _selectedSymbol = State(initialValue: inspectedSymbol)
        _instrumentOverlay = State(initialValue: fullInstrument)
        _overviewReturn = State(initialValue: inspectedSymbol.map { .init(page: initialPage, symbol: $0) })
    }
    #endif

    var body: some View {
        HStack(spacing: 0) {
            MainWatchlistSidebar(
                selectedSymbol: sidebarSelection,
                currentPage: currentPage,
                onShowPage: showOverview
            )
            // Watch groups, search and selection belong to the shared market list.
            VStack(spacing: 0) {
                if hasDataIssue { dataIssueBanner }
                instrumentLayer
                    .id(overview == nil ? "watch-instrument" : overview == .positionPools && !instrumentOverlay ? "position-pools" : "instrument-\(accountGeneration)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .environment(\.pulseHost, .mainWindow)
        .environment(\.mainRefreshGeneration, refreshGeneration)
        .frame(minWidth: 960, minHeight: 680)
        .onAppear {
            restoreSelectedSymbol()
            openPendingAlert()
        }
        .onChange(of: appState.pendingPlanAlertTarget) { _, _ in openPendingAlert() }
        .onChange(of: appState.pendingJournalTransactionID) { _, id in
            if id != nil { showOverview(.journal) }
        }
        .onChange(of: appState.watchlist.activeBrokerageAccountID) { _, _ in
            accountChanged()
        }
        .onChange(of: selectedSymbol) { _, symbol in
            storeSelectedSymbol(symbol)
            // While the instrument covers a page, the route is left alone: the
            // overlay's own return button is the way back, and clearing the
            // route here would discard the page's editor state underneath it.
            if symbol != nil, !instrumentOverlay, summarySymbol == nil { route = nil }
        }
        .sheet(isPresented: $showRiskCalculator) {
            TradeRiskCalculatorView(initialSymbol: selectedSymbol)
        }
        .sheet(isPresented: $showAccountClassification) {
            BrokerageAccountClassificationSheet { _ in }
        }
        .toolbar {
            if appState.watchlist.brokerageAccountsEnabled, let overview,
               overview != .positionPools, overview != .accounts, overview != .holdings, !instrumentOverlay {
                ToolbarItem(placement: .navigation) {
                    accountToolbarMenu
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showRiskCalculator = true } label: {
                    Label(PulseLocalization.localizedString("workspace.risk"), systemImage: "shield.lefthalf.filled")
                }.help(PulseLocalization.localizedString("workspace.risk.help"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.engine.poke()
                    refreshGeneration &+= 1
                } label: {
                    Label(PulseLocalization.localizedString("action.refreshNow"), systemImage: "arrow.clockwise")
                }
                .help(PulseLocalization.localizedString("action.refreshNow"))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        dismissOverlay()
                        overview = .workbench
                        route = nil
                    } label: {
                        Label(PulseLocalization.localizedString("main.dashboard"), systemImage: "chart.xyaxis.line")
                    }
                    Divider()
                    Button {
                        openRoutedPage(.settings)
                    } label: {
                        Label(PulseLocalization.localizedString("main.settings"), systemImage: "gearshape")
                    }
                    Button {
                        openRoutedPage(.dataSettings)
                    } label: {
                        Label(PulseLocalization.localizedString("main.data"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        openRoutedPage(.appearanceSettings)
                    } label: {
                        Label(PulseLocalization.localizedString("settings.section.appearance"), systemImage: "paintpalette")
                    }
                } label: {
                    Label(PulseLocalization.localizedString("main.settings"), systemImage: "gearshape")
                }
                .menuIndicator(.hidden)
            }
        }
    }

    private var hasDataIssue: Bool {
        appState.watchlist.hasUnreadableBrokerageData || appState.localBackups.lastError != nil || appState.folderSync.lastError != nil
            || !appState.folderSync.conflictSummaries.isEmpty
    }

    private var dataIssueBanner: some View {
        let chinese = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
        let backupFailed = appState.localBackups.lastError != nil
        let syncFailed = appState.folderSync.lastError != nil
        let title = appState.watchlist.hasUnreadableBrokerageData
            ? (chinese ? "证券账号数据读取失败，原始数据已保留" : "Account data could not be read; the original data was preserved")
            : backupFailed && syncFailed
            ? (chinese ? "备份与同步需要处理" : "Backup and sync need attention")
            : backupFailed ? (chinese ? "本地备份需要处理" : "Local backup needs attention")
            : syncFailed ? (chinese ? "文件夹同步需要处理" : "Folder sync needs attention")
            : (chinese ? "同步数据有冲突，请核对后选择" : "Review the conflicting sync data")
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(title).font(.caption)
            Spacer(minLength: 4)
            Button(chinese ? "查看并处理" : "Review") {
                openRoutedPage(.dataSettings)
            }
            .controlSize(.small)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Account scope

    /// The toolbar account selector: a small native `Menu` naming the current
    /// account and offering the three ledgers, plus one divider and a door to
    /// 账号总览.
    ///
    /// It replaces the older chip-and-popover pair. The popover carried per-account
    /// summaries and a management row, which made a scope selector read as a
    /// dashboard; here the toolbar states the scope and changes it, and nothing
    /// else. 账号总览 is navigation and takes no checkmark, because it is a page
    /// rather than a place money is kept; the three accounts carry the checkmark
    /// for the current one. Choosing one keeps the existing behaviour through
    /// `selectBrokerageAccount`, which owns the migration, budgets and refresh.
    private var accountToolbarMenu: some View {
        let current = appState.watchlist.activeBrokerageAccountID
        return Menu {
            ForEach(BrokerageAccountID.allCases, id: \.self) { account in
                Button {
                    _ = appState.selectBrokerageAccount(account)
                } label: {
                    if account == current {
                        Label(AccountIdentity.title(account), systemImage: "checkmark")
                    } else {
                        Text(AccountIdentity.title(account))
                    }
                }
                .accessibilityLabel(MainWorkspacePage.copy("切换到\(AccountIdentity.title(account))",
                                                            "Switch to \(AccountIdentity.title(account))"))
            }
            Divider()
            Button {
                showOverview(.accounts)
            } label: {
                Text(MainWorkspacePage.copy("账户总览", "Accounts"))
            }
        } label: {
            Label(AccountIdentity.title(current),
                  systemImage: AccountIdentity.symbolName(current))
        }
        .controlSize(.small)
        .menuIndicator(.hidden)
        .disabled(classificationIsBlocked)
        .help(MainWorkspacePage.copy("当前资金账户；自选列表和行情共用",
                                     "Current financial account; watchlists and market data are shared"))
        .accessibilityLabel(MainWorkspacePage.copy("当前账号：\(AccountIdentity.title(current))，打开账号菜单",
                                                   "Current account: \(AccountIdentity.title(current)); open account menu"))
    }

    /// Disabled when enabling the feature could not take its pre-migration
    /// backup: from then on the store is in a state the app promised to be able
    /// to restore, so the selector stops offering to move between accounts.
    private var classificationIsBlocked: Bool {
        !appState.isMainWindowDemo && !appState.localBackups.isAvailable
    }

    /// Idle financial pages refresh for the new ledger; editors retain their
    /// source, fields, and view identity until saved or explicitly cancelled.
    private func accountChanged() {
        if route?.preservesAccountDraft == true || instrumentOverlay || overview == nil {
            refreshGeneration &+= 1
            return
        }
        accountGeneration &+= 1
        if overview == .positionPools, deferredAlert == nil {
            // The pool board owns all-account filters and source-scoped drafts.
            // Changing a draft's source keeps the board and its scroll position.
            refreshGeneration &+= 1
            return
        }
        let watchedSymbol = overview == nil ? selectedSymbol : nil
        dismissOverlay()
        route = nil
        selectedSymbol = watchedSymbol
        showRiskCalculator = false
        showAccountClassification = false
        positionPoolsPreparationError = nil
        refreshGeneration &+= 1
        if let target = deferredAlert, target.accountID == appState.watchlist.activeBrokerageAccountID {
            deferredAlert = nil
            openAlert(target)
        }
    }

    // MARK: - Content

    /// The origin page, its summary inspector, and — above both — the full
    /// instrument. Layering rather than replacing is the whole point: the page
    /// below is the same view instance throughout, so its filter, sort, scroll
    /// offset and selection survive every open and close. Nothing here caches an
    /// enum and rebuilds a page from it.
    private var instrumentLayer: some View {
        ZStack(alignment: .trailing) {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(!instrumentOverlay)
                .accessibilityHidden(instrumentOverlay)

            if let summarySymbol, !instrumentOverlay {
                HStack(spacing: 0) {
                    Divider()
                    InstrumentSummaryInspector(
                        symbol: summarySymbol,
                        onClose: closeInspector,
                        onOpenInstrument: { openInstrumentOverlay(summarySymbol) }
                    )
                    .frame(width: 360)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if instrumentOverlay, let summarySymbol {
                fullInstrumentOverlay(symbol: summarySymbol)
            }
        }
    }

    @ViewBuilder private var detailContent: some View {
        if case .some(.plan(let symbol, let planID, let returnRoute)) = route {
            PlanEditorView(
                symbol: symbol,
                planID: planID,
                returnRoute: returnRoute,
                route: routeBinding,
                account: appState.watchlist.activeBrokerageAccountID
            )
        } else if overview == .accounts {
            BrokerageAccountOverviewView(
                onSelect: { inspect($0, from: .accounts) },
                onShowPage: showOverview
            )
        } else if overview == .holdings {
            MainHoldingsView(onSelect: { inspect($0, from: .holdings) })
        } else if overview == .plans {
            // The list inspects in place, so opening a symbol from here keeps
            // the page and its filter/sort/scroll instead of tearing it down.
            MainPlanListView(route: routeBinding, onInspect: { inspect($0, from: .plans) })
        } else if overview == .journal {
            TradeJournalView(onSelect: { inspect($0, from: .journal) })
        } else if overview == .workbench {
            TradingWorkbenchView(onSelect: { inspect($0, from: .workbench) },
                onShowPlans: { showOverview(.plans) },
                onShowJournal: { showOverview(.journal) },
                onShowEvents: { showOverview(.events) },
                onShowPools: { showOverview(.positionPools) })
        } else if overview == .events {
            TradingEventsView(onSelect: { inspect($0, from: .events) })
        } else if overview == .positionPools {
            VStack(spacing: 0) {
                if let error = positionPoolsPreparationError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button(PulseLocalization.localizedString("workspace.retry"), action: preparePositionPools)
                    }
                    .font(.caption).foregroundStyle(.orange).padding(12)
                }
                PositionPoolsView(onSelect: { inspect($0, from: .positionPools) },
                                  onShowPlans: { showOverview(.plans) })
            }
            .onAppear(perform: preparePositionPools)
        } else {
            routedDetailContent
        }
    }

    private func fullInstrumentOverlay(symbol: SymbolID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: closeInstrumentOverlay) {
                    Label(
                        MainWorkspacePage.copy(
                            "返回\(originPageTitle)",
                            "Back to \(originPageTitle)"
                        ),
                        systemImage: "chevron.left"
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Text(appState.displayName(for: symbol))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            MainInstrumentView(symbol: symbol)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .transition(.opacity)
    }

    /// Names the page the instrument was opened from.
    private var originPageTitle: String {
        (overviewReturn?.page ?? overview ?? .workbench).title
    }

    @ViewBuilder private var routedDetailContent: some View {
        switch route {
        case .some(.settings):
            SettingsView(route: routeBinding)
        case .some(.dataSettings):
            DataSettingsView(route: routeBinding)
        case .some(.appearanceSettings):
            AppearanceSettingsView(route: routeBinding)
        case .some(.providerList(let kind)):
            ProviderListView(kind: kind, route: routeBinding)
        case .some(.providerDetail(let id)):
            if let descriptor = appState.providerDescriptors.first(where: { $0.id == id }) {
                ProviderDetailView(descriptor: descriptor, route: routeBinding)
            } else {
                emptyDetail
            }
        case .some(.mcpSettings):
            MCPSettingsView(route: routeBinding)
        case .some(.planList):
            MainPlanListView(route: routeBinding)
        case .some, .none:
            if let selectedSymbol {
                MainInstrumentView(symbol: selectedSymbol)
            } else {
                emptyDetail
            }
        }
    }

    private func preparePositionPools() {
        if !appState.preparePositionAllocations() {
            positionPoolsPreparationError = PulseLocalization.localizedString("workspace.backupRequired")
            return
        }
        positionPoolsPreparationError = nil
    }

    private var routeBinding: Binding<PopoverRoute> {
        Binding(
            get: { route ?? .settings },
            set: { newRoute in
                switch newRoute {
                case .detail(let symbol):
                    selectSymbol(symbol)
                case .planList:
                    dismissOverlay()
                    overview = .plans
                    route = nil
                case .plan:
                    dismissOverlay()
                    overview = .plans
                    route = newRoute
                case .list:
                    overview = nil
                    route = nil
                default:
                    dismissOverlay()
                    overview = nil
                    route = newRoute
                }
            }
        )
    }

    private var sidebarSelection: Binding<SymbolID?> {
        Binding(
            get: { overview == nil || instrumentOverlay ? selectedSymbol : nil },
            set: { symbol in
                if let symbol { selectSymbol(symbol) }
                else { overview = nil; route = nil }
            }
        )
    }

    /// A watchlist row opens the instrument itself; it never leaves a global
    /// page behind it, so no stale page can stay highlighted.
    private func selectSymbol(_ symbol: SymbolID) {
        dismissOverlay()
        selectedSymbol = symbol
        storeSelectedSymbol(symbol)
        overview = nil
        route = nil
    }

    /// A list inside a global page asks to inspect a symbol instead of leaving:
    /// the page stays put and the summary inspector opens beside it.
    private func inspect(_ symbol: SymbolID, from page: MainWorkspacePage) {
        overview = page
        route = nil
        overviewReturn = OverviewPageReturn(page: page, symbol: symbol)
        selectedSymbol = symbol
        storeSelectedSymbol(symbol)
        instrumentOverlay = false
        summarySymbol = symbol
    }

    private func closeInspector() {
        summarySymbol = nil
        overviewReturn = nil
    }

    private func openInstrumentOverlay(_ symbol: SymbolID) {
        selectedSymbol = symbol
        storeSelectedSymbol(symbol)
        instrumentOverlay = true
    }

    private func closeInstrumentOverlay() {
        instrumentOverlay = false
    }

    private func dismissOverlay() {
        instrumentOverlay = false
        summarySymbol = nil
        overviewReturn = nil
    }

    private func showOverview(_ value: MainWorkspacePage) {
        dismissOverlay()
        overview = value
        route = nil
    }

    /// Settings and the other routed pages are pushed over nothing: they clear
    /// the overview and any overlay, so their own back affordance has a defined
    /// destination rather than landing on a hidden page.
    private func openRoutedPage(_ value: PopoverRoute) {
        dismissOverlay()
        overview = nil
        route = value
    }

    private func openPendingAlert() {
        guard let target = appState.pendingPlanAlertTarget else { return }
        appState.pendingPlanAlertTarget = nil
        if target.accountID != appState.watchlist.activeBrokerageAccountID {
            deferredAlert = target
            if !appState.selectBrokerageAccount(target.accountID) { deferredAlert = nil }
        } else { openAlert(target) }
    }

    private func openAlert(_ target: BrokerageAlertTarget) {
        guard target.accountID == appState.watchlist.activeBrokerageAccountID else { return }
        if let id = target.planID, appState.watchlist.item(for: target.symbol)?.plans.contains(where: { $0.id == id }) == true {
            showOverview(.plans)
            route = .plan(target.symbol, id, .planList)
        } else { selectSymbol(target.symbol) }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(PulseLocalization.localizedString("main.empty.selection"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func restoreSelectedSymbol() {
        guard selectedSymbol == nil else { return }
        guard !selectedSymbolStorage.isEmpty,
              let data = Data(base64Encoded: selectedSymbolStorage),
              let symbol = try? JSONDecoder().decode(SymbolID.self, from: data) else {
            selectedSymbol = appState.sharedWatchlist.items.first?.symbol
            return
        }
        selectedSymbol = appState.sharedWatchlist.item(for: symbol) != nil ? symbol : appState.sharedWatchlist.items.first?.symbol
    }

    private func storeSelectedSymbol(_ symbol: SymbolID?) {
        guard let symbol, let data = try? JSONEncoder().encode(symbol) else {
            selectedSymbolStorage = ""
            return
        }
        selectedSymbolStorage = data.base64EncodedString()
    }
}

/// The summary inspector shown beside a global page: who the instrument is,
/// what it costs right now, what is held, and which plans concern it. Every
/// number is read live from the store, and the call to action hands off to the
/// full instrument rather than replacing this page.
struct InstrumentSummaryInspector: View {
    @Environment(AppState.self) private var appState

    let symbol: SymbolID
    let onClose: () -> Void
    let onOpenInstrument: () -> Void

    private var quote: Quote? { appState.market.quote(for: symbol) }
    private var item: WatchItem? {
        appState.watchlist.item(for: symbol) ?? appState.watchlist.retainedHistoryItem(for: symbol)
    }
    private var plans: [TradePlan] {
        (item?.plans ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }
    private var name: String {
        // `Quote.name` is optional, so an unnamed quote falls back to the
        // store's own name rather than rendering an empty title.
        if let quoted = quote?.name, !quoted.isEmpty { return quoted }
        return appState.displayName(for: symbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    quoteSection
                    positionSection
                    planSection
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy("标的摘要", "Instrument summary"))
    }

    private func copy(_ chinese: String, _ english: String) -> String {
        MainWorkspacePage.copy(chinese, english)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(symbol.displayCode)
                        .font(.system(size: 10, design: .monospaced))
                    Text(symbol.currencyCode)
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(PulseLocalization.localizedString("action.backHelp"))
            .accessibilityLabel(copy("关闭", "Close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The quote always carries its own timestamp, so a stale reading can never
    /// be mistaken for a live one.
    private var quoteSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(copy("报价", "Quote"))
            if let quote {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(PriceFormatter.price(quote.price, market: symbol.market))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    Text(PriceFormatter.percent(quote.changePercent))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(appState.palette.color(for: quote.change))
                }
                Text(copy("时点 ", "At ") + Self.timestamp(quote.timestamp))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if !TradingQuoteHealth.isCurrent(quote) {
                    Text(copy("参考行情 · 非盘中实时", "Reference quote · not live"))
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            } else {
                Text(copy("暂无报价", "No quote"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(copy("持仓", "Position"))
            factLine(
                PulseLocalization.localizedString("position.quantity"),
                item.map { PriceFormatter.quantity($0.positionQuantity) }
                    ?? copy("无", "None")
            )
            if let item, item.hasPositionHistory {
                factLine(copy("成交笔数", "Trades"), "\(item.transactions.count)")
            }
        }
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                sectionTitle(copy("相关计划", "Related plans"))
                Spacer(minLength: 0)
                Text("\(plans.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if plans.isEmpty {
                Text(copy("该标的暂无计划", "No plans for this instrument"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(plans) { plan in
                    planRow(plan)
                }
            }
            Button(action: onOpenInstrument) {
                Label(copy("打开完整标的", "Open full instrument"), systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private func planRow(_ plan: TradePlan) -> some View {
        let entry = TradePlanEntry(symbol: symbol, plan: plan, transactions: item?.transactions ?? [])
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(PulseLocalization.localizedString(plan.kind == .buy ? "plan.kind.buy" : "plan.kind.sell"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PlanSideStyle.color(for: plan.kind))
                Text("\(PriceFormatter.price(plan.price, market: symbol.market)) × \(PriceFormatter.quantity(plan.quantity))")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text(planIntentTitle(entry))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(copy(
                    "已成 \(PriceFormatter.quantity(entry.filledQuantity)) · 待执行 \(PriceFormatter.quantity(entry.remainingQuantity))",
                    "Filled \(PriceFormatter.quantity(entry.filledQuantity)) · open \(PriceFormatter.quantity(entry.remainingQuantity))"
                ))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func factLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = PulseLocalization.currentLocale
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct PulseCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(PulseLocalization.localizedString("main.openWindow")) {
                openWindow(id: MainWindow.id)
                MainWindow.activate()
            }
            .keyboardShortcut("1", modifiers: .command)
        }
    }
}
