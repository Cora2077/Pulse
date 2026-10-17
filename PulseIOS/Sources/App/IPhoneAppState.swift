import Foundation
import Observation
import PulseCore
import PulseSync
import PulseMobile

@MainActor
@Observable
final class IPhoneAppState {
    let watchlist: WatchlistStore
    let market = MarketStore()
    let tradingEvents: TradingEventsController
    var requestedAccountSection: String?
    let provider: CompositeProvider
    let pushClient: IPhonePushBridgeClient
    let isDemo: Bool
    var selectedTab = 0
    var isForeground = true
    var errorMessage: String?
    var syncStatus = "未配置云同步 · 数据保存在本机"
    var syncConflict: ConflictReport?
    var confirmedPlanRevision: String?
    var confirmedPlanAt: Date?
    var activityStatus = "尚未授权自动关注"
    var isRefreshing = false
    var automaticTrackingEnabled: Bool
    var pausedToday: Bool {
        (defaults.object(forKey: "ios.tracking.pauseUntil") as? Date).map { $0 > .now } ?? false
    }
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var onSnapshotChanged: ((WatchlistSyncSnapshot) -> Void)?
    @ObservationIgnored var onQuotesChanged: (() -> Void)?
    @ObservationIgnored var onTrackingPreferencesChanged: (() -> Void)?
    @ObservationIgnored private var cloudSync: IPhoneCloudSyncBinding?
    @ObservationIgnored private var servicesStarted = false
    @ObservationIgnored private var activityBinding: IPhoneActivityBinding?

    init(demo: Bool = CommandLine.arguments.contains("--acceptance-demo")) {
        isDemo = demo
        if demo {
            let isolated = UserDefaults(suiteName: "app.pulse.ios.acceptance")!
            isolated.removePersistentDomain(forName: "app.pulse.ios.acceptance")
            defaults = isolated
        } else { defaults = .standard }
        automaticTrackingEnabled = defaults.bool(forKey: "ios.tracking.enabled")
            || (demo && CommandLine.arguments.contains("--acceptance-activity"))
        pushClient = IPhonePushBridgeClient(defaults: defaults, allowsRemoteConfiguration: !demo)
        watchlist = WatchlistStore(defaults: defaults)
        tradingEvents = TradingEventsController(defaults: defaults)
        provider = CompositeProvider(providers: [TencentProvider(), NaverProvider(), YahooProvider(),
            BinanceProvider(), SinaProvider(), ShanghaiGoldExchangeProvider(), EastmoneyProvider(), ThsSectorProvider()])
        if !watchlist.brokerageAccountsEnabled { watchlist.enableBrokerageAccounts() }
        if demo { seedAcceptanceData() }
        watchlist.onLocalSyncChange = { [weak self] snapshot in
            self?.syncStatus = "本机已保存 · 待同步"
            self?.onSnapshotChanged?(snapshot)
        }
    }

    var accountID: BrokerageAccountID { watchlist.activeBrokerageAccountID }
    var activeItems: [WatchItem] { watchlist.allItems }
    var planEntries: [TradePlanEntry] {
        TradePlanOverview.ordered(watchlist.tradePlanEntries.map {
            TradePlanEntry(symbol: $0.symbol, plan: $0.plan,
                transactions: watchlist.transactionsForPlan($0.symbol, account: accountID, planID: $0.plan.id), accountID: accountID)
        }, currentPrice: { self.freshPrice($0) })
    }
    var historyItems: [WatchItem] { watchlist.tradeHistoryItems }
    var dayKey: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: .now)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func accountName(_ id: BrokerageAccountID) -> String {
        switch id { case .unassigned: "待归属"; case .financing: "融资账户"; case .mengmeng: isDemo ? "示例现金账户" : "现金账户" }
    }
    func displayName(_ symbol: SymbolID) -> String {
        watchlist.item(for: symbol)?.resolvedDisplayName ?? symbol.indexID?.displayName
            ?? symbol.sectorIndex?.displayName ?? KoreanSecurityCatalog.displayName(for: symbol)
            ?? market.quote(for: symbol)?.name ?? symbol.displayCode
    }
    func quote(_ symbol: SymbolID) -> Quote? { market.quote(for: symbol) }
    func freshPrice(_ symbol: SymbolID) -> Double? {
        guard let quote = quote(symbol), quote.price.isFinite, quote.price > 0,
              quote.previousClose.isFinite, quote.previousClose > 0,
              (quote.sourceDelay ?? 0) < 300,
              (0...300).contains(Date.now.timeIntervalSince(quote.timestamp)) else { return nil }
        return quote.price
    }
    func selectAccount(_ id: BrokerageAccountID) { watchlist.selectBrokerageAccount(id) }
    func setGroup(_ id: UUID) { watchlist.selectGroup(id) }
    func saveWatchlistOrder(_ symbols: [SymbolID], expectedGroup: WatchlistGroup,
                           account: BrokerageAccountID) throws {
        guard accountID == account else { throw WorkbenchError.accountChanged }
        guard watchlist.group(for: expectedGroup.id) == expectedGroup else { throw WorkbenchError.staleDraft }
        guard watchlist.applyCustomOrder(symbols, in: expectedGroup.id) else { throw WorkbenchError.rejected }
    }
    func add(_ info: SymbolInfo) { watchlist.add(info); Task { await refresh() } }
    func remove(_ symbol: SymbolID) { watchlist.remove(symbol) }
    func search(_ query: String) async throws -> [SymbolInfo] {
        if isDemo {
            let catalog = KoreanSecurityCatalog.search(query) + SectorIndexCatalog.search(query)
            let local = activeItems.filter { $0.resolvedDisplayName.localizedCaseInsensitiveContains(query) || $0.symbol.description.contains(query.uppercased()) }
                .map { SymbolInfo(symbol: $0.symbol, name: $0.resolvedDisplayName, type: $0.resolvedInstrumentType ?? .equity) }
            var seen: Set<SymbolID> = []
            let searchOnlyFixture = SymbolInfo(symbol: SymbolID(market: .us, code: "TSLA"),
                name: "特斯拉（验收）", type: .equity)
            let remoteFixture = query.uppercased() == "TSLA" ? [searchOnlyFixture] : []
            return (catalog + local + remoteFixture).filter { seen.insert($0.symbol).inserted }
        }
        return try await provider.search(query)
    }
    func candles(_ symbol: SymbolID, period: CandlePeriod) async throws -> [Candle] {
        if isDemo { return Self.demoCandles() }
        return try await provider.candles(for: symbol, period: period, count: 180)
    }
    func setAutomaticTracking(_ enabled: Bool) {
        automaticTrackingEnabled = enabled
        defaults.set(enabled, forKey: "ios.tracking.enabled")
        if enabled { defaults.removeObject(forKey: "ios.tracking.pauseUntil") }
        activityStatus = enabled ? "本机自动关注 · 后台推送尚未配置" : "自动关注已关闭"
        onTrackingPreferencesChanged?()
    }
    func keepLocalSyncVersion() { cloudSync?.keepLocal() }
    func acceptRemoteSyncVersion() { cloudSync?.acceptRemote() }
    func synchronizeNow() { cloudSync?.synchronize() }
    func pauseTrackingToday() {
        let market = activeItems.first(where: { $0.hasPosition || $0.plans.contains { $0.status == .active } })?.symbol.market ?? .sh
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        if let until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) {
            defaults.set(until, forKey: "ios.tracking.pauseUntil")
        }
        activityStatus = "今日已暂停"
        onTrackingPreferencesChanged?()
    }
    func refresh() async {
        guard !isRefreshing else { return }
        guard !isDemo else { onQuotesChanged?(); return }
        let symbols = watchlist.quoteSymbols
        guard !symbols.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let quotes = try await provider.quotes(for: symbols)
            try Task.checkCancellation()
            market.apply(quotes: quotes)
            errorMessage = nil
            onQuotesChanged?()
        } catch is CancellationError { }
        catch { market.reportError(error.localizedDescription); errorMessage = "行情暂不可用：\(error.localizedDescription)" }
    }
    private func startServicesIfNeeded() {
        guard !servicesStarted else { return }
        servicesStarted = true
        do {
            let binding = try IPhoneCloudSyncBinding(app: self)
            cloudSync = binding
            onSnapshotChanged = { [weak self, weak binding] snapshot in
                binding?.localChange(snapshot)
                self?.activityBinding?.reconcile()
            }
            binding.start()
        } catch { syncStatus = "同步底座启动失败：\(error.localizedDescription)" }
        let activity = IPhoneActivityBinding(app: self)
        activityBinding = activity
        onQuotesChanged = { [weak activity] in activity?.reconcile() }
        onTrackingPreferencesChanged = { [weak activity] in activity?.changedByUser() }
        pushClient.onConfigurationChanged = { [weak activity] in activity?.reconcile() }
        activity.reconcile()
        if pushClient.isConfigured && automaticTrackingEnabled {
            Task { await pushClient.checkStatus() }
        }
    }
    func runForegroundPolling() async {
        startServicesIfNeeded()
        var cycle = 0
        while !Task.isCancelled {
            if isForeground {
                await refresh()
                if cycle % 3 == 0 { cloudSync?.synchronize() }
                cycle += 1
            }
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
        }
    }

    // The UI always passes its frozen original/account; the mobile workflows
    // add stable identities and retry verification over shared checked writes.
    private func accepted<D: Sendable, V: Sendable>(_ outcome: MobileWorkflowOutcome<D, V>) throws -> V {
        switch outcome {
        case .written(let value): return value
        case .refused(let error, _):
            switch error {
            case .accountChanged: throw WorkbenchError.accountChanged
            case .stalePlanRevision, .staleTransactionRecord: throw WorkbenchError.staleDraft
            case .fillPriceRequired, .fillQuantityRequired, .invalidFillValues: throw WorkbenchError.invalidValues
            default: throw WorkbenchError.workflow(error.localizedDescription)
            }
        }
    }
    func savePlan(_ plan: TradePlan, symbol: SymbolID, expected: TradePlan?, account: BrokerageAccountID,
                  newSymbolInfo: SymbolInfo? = nil) throws {
        let draft = PlanDraft(planID: expected?.id, symbol: symbol, kind: plan.kind,
            price: plan.price, quantity: plan.quantity, note: plan.note,
            conditions: plan.conditions ?? [], positionPool: plan.positionPool,
            positionPortionID: plan.positionPortionID, fundingSource: plan.fundingSource,
            executionAccountID: plan.executionAccountID,
            accountFreeze: AccountFreeze(account: account, brokerageAccountsEnabled: watchlist.brokerageAccountsEnabled),
            revision: expected.map(PlanRevisionStamp.init(of:)),
            allocationRevision: nil, newPlanID: expected == nil ? plan.id : nil)
        _ = try accepted(PlanWorkflow(store: watchlist).save(draft, newSymbolInfo: newSymbolInfo))
    }
    func transitionPlan(_ entry: TradePlanEntry, to status: TradePlan.Status) throws {
        guard entry.accountID == accountID else { throw WorkbenchError.accountChanged }
        if status == .done {
            guard let draft = PlanDraft.editing(entry, in: watchlist) else { throw WorkbenchError.staleDraft }
            _ = try accepted(PlanWorkflow(store: watchlist).setStatus(.done, on: draft))
        } else if status == .cancelled {
            _ = try accepted(PlanWorkflow(store: watchlist).abandon(entry))
        } else { _ = try accepted(PlanWorkflow(store: watchlist).revive(entry)) }
    }
    func deletePlan(_ entry: TradePlanEntry) throws {
        guard entry.accountID == accountID else { throw WorkbenchError.accountChanged }
        try watchlist.deleteTradePlan(entry.plan, for: entry.symbol, account: accountID)
    }
    @discardableResult
    func recordTrade(_ trade: PositionTransaction, symbol: SymbolID, account: BrokerageAccountID,
                     plan: TradePlan? = nil, original: PositionTransaction? = nil,
                     planSourceAccount: BrokerageAccountID? = nil,
                     sourceAccount: BrokerageAccountID? = nil) throws -> UUID {
        let source = sourceAccount ?? planSourceAccount ?? accountID
        guard accountID == source else { throw WorkbenchError.accountChanged }
        guard trade.price.isFinite, trade.price > 0, trade.quantity.isFinite, trade.quantity > 0,
              (trade.price * trade.quantity).isFinite else { throw WorkbenchError.invalidValues }
        guard account != .unassigned else { throw WorkbenchError.chooseAccount }
        if let original {
            var draft = TransactionEditDraft.editing(original, symbol: symbol, account: account, in: watchlist)
            draft.price = trade.price; draft.quantity = trade.quantity
            draft.date = trade.date; draft.fee = trade.fee; draft.note = trade.note
            draft.fundingSource = trade.fundingSource; draft.review = trade.review
            let stored = try accepted(TransactionWorkflow(store: watchlist).save(draft))
            return stored.id
        }
        let intent: FillIntent = plan.map { $0.status == .done ? .planBackfill : .planFill } ?? .unlinked
        let draft = FillDraft(symbol: symbol, intent: intent, planID: plan?.id,
            kind: trade.kind, price: trade.price, quantity: trade.quantity, date: trade.date,
            fee: trade.fee, note: trade.note, fundingSource: trade.fundingSource,
            destinationAccount: account, planRevision: plan.map(PlanRevisionStamp.init(of:)),
            accountFreeze: AccountFreeze(account: source, brokerageAccountsEnabled: watchlist.brokerageAccountsEnabled),
            transactionID: trade.id)
        let stored = try accepted(FillWorkflow(store: watchlist).submit(draft))
        return stored.id
    }
    func deleteTrade(_ original: PositionTransaction, symbol: SymbolID, account: BrokerageAccountID) throws {
        _ = try accepted(TransactionWorkflow(store: watchlist).delete(symbol: symbol, transaction: original, account: account))
    }
    func saveReview(_ review: PositionTransactionReview?, note: String?, original: PositionTransaction,
                    symbol: SymbolID, account: BrokerageAccountID) throws {
        let draft = ReviewDraft(symbol: symbol, transactionID: original.id, note: note,
            review: try review?.normalizedForPersistence(), expected: TransactionRevisionStamp(record: original))
        _ = try accepted(TransactionWorkflow(store: watchlist).saveReview(draft, account: account))
    }

    private func seedAcceptanceData() {
        if CommandLine.arguments.contains("--acceptance-a-shares") {
            seedAShareWorkbenchAcceptanceData()
            return
        }
        let samsung = SymbolID(market: .kr, code: "005930")
        let bank = SymbolID(market: .sh, code: "881155")
        let hynix = SymbolID(market: .kr, code: "000660")
        let stock = WatchItem(symbol: samsung, displayName: "三星电子", instrumentType: .equity,
            transactions: [PositionTransaction(kind: .buy, price: 220000, quantity: 100,
                date: .now.addingTimeInterval(-86400), fundingSource: .own, brokerageAccountID: .mengmeng)],
            plans: [TradePlan(kind: .buy, price: 210000, quantity: 300, note: "仅为模拟器验收示例",
                conditions: [TradePlanCondition(title: "手工条件待复核", kind: .manual)],
                fundingSource: .own, executionAccountID: .mengmeng)])
        let items = [stock, WatchItem(symbol: bank, displayName: "银行", instrumentType: .index),
            WatchItem(symbol: hynix, displayName: "SK海力士", instrumentType: .equity),
            WatchItem(symbol: SymbolID(index: .kospi), displayName: "韩国综合指数", instrumentType: .index)]
        let group = WatchlistGroup(name: "跟踪", symbols: items.map(\.symbol))
        let portfolio = BrokerageAccountPortfolio(accountID: .mengmeng, items: items, groups: [group])
        _ = watchlist.applySyncSnapshot(WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [
            portfolio, BrokerageAccountPortfolio(accountID: .financing)]))
        watchlist.selectBrokerageAccount(.mengmeng)
        market.apply(quotes: [Quote(symbol: samsung, name: "三星电子", price: 208000, previousClose: 232000, sourceID: "demo", timestamp: .now),
            Quote(symbol: bank, name: "银行", price: 1386.064, previousClose: 1401.281, sourceID: "demo", timestamp: .now),
            Quote(symbol: hynix, name: "SK海力士", price: 1244000, previousClose: 1419000, sourceID: "demo", timestamp: .now)])
        // The OS-activity smoke test must not start failing when Korea closes.
        // A synthetic, pinned 24/7 instrument exercises real ActivityKit while
        // preserving production market-hours rules. No network or real ledger.
        if CommandLine.arguments.contains("--acceptance-activity") {
            let crypto = SymbolID(market: .crypto, code: "BTCUSDT")
            watchlist.add(SymbolInfo(symbol: crypto, name: "活动验收用标的", type: .crypto))
            _ = watchlist.setPinned(crypto, pinned: true)
            market.apply(quotes: [Quote(symbol: crypto, name: "活动验收用标的", price: 50000,
                previousClose: 49000, sourceID: "demo", timestamp: .now)])
        }
    }
    /// Synthetic only, reached exclusively from the isolated demo initializer.
    /// Quiet preparation plan, intraday condition, today's review, and global
    /// reference indices exercise different work stages without real account data.
    private func seedAShareWorkbenchAcceptanceData() {
        let quiet = SymbolID(market: .sh, code: "600000")
        let follow = SymbolID(market: .sz, code: "000001")
        let now = Date.now
        let today = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let items = [
            WatchItem(symbol: quiet, displayName: "准备计划（合成）", instrumentType: .equity,
                transactions: [PositionTransaction(kind: .buy, price: 10, quantity: 100,
                    date: yesterday, fundingSource: .own, brokerageAccountID: .mengmeng)],
                plans: [TradePlan(kind: .buy, price: 9, quantity: 100, fundingSource: .own)]),
            WatchItem(symbol: follow, displayName: "成交复盘（合成）", instrumentType: .equity,
                transactions: [PositionTransaction(kind: .buy, price: 12, quantity: 100,
                    date: today, fundingSource: .own, brokerageAccountID: .mengmeng)],
                plans: [TradePlan(kind: .buy, price: 11, quantity: 100,
                    conditions: [TradePlanCondition(title: "合成条件待核对", kind: .manual)], fundingSource: .own)]),
            WatchItem(symbol: SymbolID(index: .hangSeng), displayName: "恒生指数", instrumentType: .index),
            WatchItem(symbol: SymbolID(index: .sp500), displayName: "标普500指数", instrumentType: .index)
        ]
        let group = WatchlistGroup(name: "A 股合成验收", symbols: items.map(\.symbol))
        _ = watchlist.applySyncSnapshot(WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [
            BrokerageAccountPortfolio(accountID: .mengmeng, items: items, groups: [group]),
            BrokerageAccountPortfolio(accountID: .financing)
        ]))
        watchlist.selectBrokerageAccount(.mengmeng)
        market.apply(quotes: [
            Quote(symbol: quiet, name: "准备计划（合成）", price: 10, previousClose: 9.8, sourceID: "demo", timestamp: now),
            Quote(symbol: follow, name: "成交复盘（合成）", price: 12, previousClose: 11.8, sourceID: "demo", timestamp: now)
        ])
    }

    private static func demoCandles() -> [Candle] {
        (0..<80).map { index in
            let close = 1300 + Double(index) * 1.15 + sin(Double(index) * 0.6) * 18
            return Candle(time: Date.now.addingTimeInterval(Double(index - 79) * 86400),
                open: close - sin(Double(index)) * 8, high: close + 12, low: close - 14,
                close: close, volume: Double(1000000 + index * 10000))
        }
    }
}

enum WorkbenchError: LocalizedError {
    case accountChanged, staleDraft, invalidValues, chooseAccount, rejected
    case workflow(String)
    var errorDescription: String? {
        switch self {
        case .accountChanged: "账户已切换。请回到原账户或重新打开表单，草稿未保存。"
        case .staleDraft: "记录已在其他窗口或设备变更，请重新核对，当前草稿仍保留。"
        case .invalidValues: "请填写有效的实际成交价和数量。"
        case .chooseAccount: "请明确选择实际成交账户。"
        case .rejected: "共享账本校验未通过，本次没有写入，请核对表单。"
        case .workflow(let reason): "没有保存，草稿仍保留：\(reason)"
        }
    }
}
