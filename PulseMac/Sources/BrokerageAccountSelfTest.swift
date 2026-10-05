#if DEBUG
import Foundation
import MCP
import PulseCore

/// Disposable fixtures for account-scoped MCP and account-local budget settings.
@MainActor
enum BrokerageAccountSelfTest {
    static func run() async -> Bool {
        let suite = "pulse.brokerage-selftest.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        let symbol = SymbolID(market: .sz, code: "000001")
        for account in [BrokerageAccountID.financing, .mengmeng] {
            store.withBrokerageAccount(account) { store.add(SymbolInfo(symbol: symbol, name: "Fixture")) }
        }
        let adapter = MCPToolAdapter(commands: AgentWatchlistCommands(store: store), poke: {})
        func body(_ result: CallTool.Result) -> String {
            result.content.compactMap { if case .text(let text, _, _) = $0 { return text }; return nil }.joined()
        }
        let baseline = store.syncSnapshot()
        let missing = await adapter.call(.init(name: "record_trade", arguments: [
            "symbol": .object(["market": "sz", "code": "000001"]),
            "kind": "buy", "quantity": 100, "price": 10, "date": "2026-10-04"
        ]))
        guard missing.isError == true, body(missing).contains("account_required"),
              store.syncSnapshot() == baseline else { print("BROKERAGE_SELFTEST missing-account failed"); return false }
        let invalid = await adapter.call(.init(name: "list_positions", arguments: ["account_id": "unknown"]))
        guard invalid.isError == true, body(invalid).contains("invalid_account") else { return false }
        for (account, quantity, price) in [("financing", 100.0, 10.0), ("mengmeng", 200.0, 20.0)] {
            let result = await adapter.call(.init(name: "record_trade", arguments: [
                "account_id": .string(account), "symbol": .object(["market": "sz", "code": "000001"]),
                "kind": "buy", "quantity": .double(quantity), "price": .double(price), "date": "2026-10-04"
            ]))
            guard result.isError != true else { print("BROKERAGE_SELFTEST scoped-write \(body(result))"); return false }
        }
        guard store.activeBrokerageAccountID == .unassigned,
              store.brokeragePortfolio(for: .financing).items.first?.positionQuantity == 100,
              store.brokeragePortfolio(for: .mengmeng).items.first?.positionQuantity == 200 else { return false }
        let beforeRead = store.syncSnapshot()
        let read = await adapter.call(.init(name: "list_positions", arguments: ["account_id": "financing"]))
        guard read.isError != true, body(read).contains("100"), store.syncSnapshot() == beforeRead,
              store.activeBrokerageAccountID == .unassigned else { return false }
        let accountList = await adapter.call(.init(name: "list_brokerage_accounts"))
        guard accountList.isError != true, body(accountList).contains("mengmeng") else { return false }

        let budgets = PoolBudgetSettings(defaults: defaults)
        guard budgets.setCashBalance(amount: 1000, currency: "CNY"),
              budgets.setPoolLimit(amount: 500, currency: "CNY", pool: .strategic) else { return false }
        budgets.selectBrokerageAccount(.financing)
        guard budgets.cashBalance(currency: "CNY") == nil, budgets.poolLimit(currency: "CNY", pool: .strategic) == nil,
              budgets.setCashBalance(amount: 2000, currency: "CNY") else { return false }
        budgets.selectBrokerageAccount(.mengmeng)
        guard budgets.cashBalance(currency: "CNY") == nil,
              budgets.setCashBalance(amount: 3000, currency: "CNY") else { return false }
        budgets.selectBrokerageAccount(.unassigned)
        guard budgets.cashBalance(currency: "CNY")?.amount == 1000,
              budgets.poolLimit(currency: "CNY", pool: .strategic) == 500,
              PoolBudgetSettings(defaults: defaults, accountID: .financing).cashBalance(currency: "CNY")?.amount == 2000,
              PoolBudgetSettings(defaults: defaults, accountID: .mengmeng).cashBalance(currency: "CNY")?.amount == 3000 else { return false }
        // Editing the overview's other account cash never changes the working ledger.
        guard budgets.setCashBalance(amount: 3500, currency: "CNY", in: .mengmeng),
              budgets.accountID == .unassigned, budgets.cashBalance(currency: "CNY")?.amount == 1000,
              budgets.cashBalances(for: .mengmeng)["CNY"]?.amount == 3500 else { return false }
        guard budgets.setCashBalance(amount: nil, currency: "CNY", in: .mengmeng),
              budgets.cashBalances(for: .mengmeng)["CNY"] == nil else { return false }
        let market = MarketStore()
        market.apply(quotes: [Quote(symbol: symbol, price: 15, previousClose: 14,
                                   sourceName: "Fixture", timestamp: .now)])
        store.withBrokerageAccount(.financing) {
            var plan = TradePlan(kind: .buy, price: 5, quantity: 100)
            plan.fundingSource = .margin
            _ = store.setTradePlan(plan, for: symbol)
        }
        store.withBrokerageAccount(.mengmeng) {
            var plan = TradePlan(kind: .buy, price: 6, quantity: 100)
            plan.fundingSource = .own
            _ = store.setTradePlan(plan, for: symbol)
        }
        let beforeOverview = store.syncSnapshot()
        let rows = BrokerageAccountOverviewReader.rows(store: store, market: market, budgets: budgets)
        guard let finance = rows.first(where: { $0.accountID == .financing && $0.currencyCode == "CNY" }),
              let mengmeng = rows.first(where: { $0.accountID == .mengmeng && $0.currencyCode == "CNY" }),
              finance.holdingValue == 1500, finance.cash?.amount == 2000,
              finance.plannedBuy == 500, finance.marginBuy == 500, finance.ownBuy == 0,
              mengmeng.holdingValue == 3000, mengmeng.cash == nil,
              mengmeng.plannedBuy == 600, mengmeng.ownBuy == 600, mengmeng.marginBuy == 0,
              mengmeng.recordedFunds == nil, finance.recordedFunds == 3500,
              store.syncSnapshot() == beforeOverview, store.activeBrokerageAccountID == .unassigned else { return false }
        let limits = SectorLimitSettings(defaults: defaults)
        guard limits.setLimit(40, for: "CNY:Fixture") else { return false }
        let migrationAccounts = Set(BrokerageAccountID.allCases)
        guard budgets.attach(to: store, migrating: migrationAccounts),
              limits.attach(to: store, migrating: migrationAccounts),
              store.brokerageSettings(for: .unassigned)?.cashBalances["CNY"]?.amount == 1000,
              store.brokerageSettings(for: .financing)?.cashBalances["CNY"]?.amount == 2000,
              limits.limits(for: .financing).isEmpty,
              limits.limits["CNY:Fixture"] == 40 else { return false }
        let financialBackup = store.syncSnapshot()
        guard budgets.setCashBalance(amount: nil, currency: "CNY", in: .financing),
              limits.setLimit(60, for: "CNY:Fixture"),
              budgets.cashBalances(for: .financing).isEmpty else { return false }
        do { _ = try store.restoreBackup(financialBackup) } catch { return false }
        guard budgets.cashBalances(for: .financing)["CNY"]?.amount == 2000,
              limits.limits["CNY:Fixture"] == 40 else { return false }
        var sync = financialBackup
        sync.brokerageAccounts?[0].settings = .init()
        _ = store.applySyncSnapshot(sync)
        guard budgets.cashBalances(for: .financing).isEmpty else { return false }
        // Existing settings arriving from a peer must win over old local defaults.
        guard budgets.attach(to: store, migrating: []),
              budgets.cashBalances(for: .financing).isEmpty else { return false }
        let sharedPlan = TradePlan(kind: .buy, price: 20, quantity: 100)
        for account in [BrokerageAccountID.financing, .mengmeng] {
            store.withBrokerageAccount(account) { _ = store.setTradePlan(sharedPlan, for: symbol) }
        }
        let alerts = PlanAlertController(store: store, market: market, defaults: defaults,
                                         isOffline: true, sectorLimits: limits)
        let financeAlert = PlanAlertController.notificationID(account: .financing, planID: sharedPlan.id)
        let mengmengAlert = PlanAlertController.notificationID(account: .mengmeng, planID: sharedPlan.id)
        let current = Quote(symbol: symbol, price: 15, previousClose: 14,
                            timestamp: .now, marketState: .regular)
        guard alerts.target(for: financeAlert)?.accountID == .financing,
              alerts.target(for: mengmengAlert)?.accountID == .mengmeng,
              alerts.target(for: sharedPlan.id.uuidString) == nil,
              alerts.notificationIsDue(sharedPlan, account: .financing, quote: current),
              alerts.notificationIsDue(sharedPlan, account: .mengmeng, quote: current) else { return false }
        alerts.snooze(sharedPlan, account: .financing)
        guard !alerts.notificationIsDue(sharedPlan, account: .financing, quote: current),
              alerts.notificationIsDue(sharedPlan, account: .mengmeng, quote: current),
              store.activeBrokerageAccountID == .unassigned else { return false }
        let legacySuite = "pulse.alert-upgrade-selftest.\(UUID())"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else { return false }
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
        var legacyLedger = PlanAlertLedger()
        legacyLedger.markDelivered(sharedPlan)
        legacyDefaults.set(try? JSONEncoder().encode(legacyLedger), forKey: "pulse.planAlerts.delivery.v1")
        let upgradedAlerts = PlanAlertController(store: store, market: market, defaults: legacyDefaults,
                                                 isOffline: true, sectorLimits: limits)
        guard !upgradedAlerts.notificationIsDue(sharedPlan, account: .financing, quote: current),
              !upgradedAlerts.notificationIsDue(sharedPlan, account: .mengmeng, quote: current) else { return false }
        guard assertCardAccountBoard() else { print("BROKERAGE_SELFTEST card-attribution failed"); return false }
        print("BROKERAGE_ACCOUNT_SELFTEST_PASSED mcp-account-required scoped-ledgers selection-restore budget-isolation settings-migration sync-restore all-account-alerts snooze-isolation")
        return true
    }
    private static func assertCardAccountBoard() -> Bool {
        guard CommandLine.arguments.contains("--main-window-demo") else { return false }
        let app = AppState()
        let store = app.watchlist
        _ = store.applySyncSnapshot(.init(items: [], groups: [], brokerageAccounts: [
            .init(accountID: .financing, settings: .init()), .init(accountID: .mengmeng, settings: .init())
        ], accountSettings: .init()))
        store.enableBrokerageAccounts()
        _ = app.poolBudgets.attach(to: store, migrating: [])
        let symbol = SymbolID(market: .sz, code: "000001")
        store.add(SymbolInfo(symbol: symbol, name: "账户标签测试"))
        store.addTransaction(symbol, .init(kind: .buy, price: 100, quantity: 10, date: .now))
        do {
            guard let allocation = store.item(for: symbol)?.positionAllocation, let first = allocation.portions.first else { return false }
            let split = try store.transferPositionPortion(symbol: symbol, portionID: first.id, quantity: 5,
                to: .tactical, reason: "", expectedRevision: allocation.revision)
            guard let original = split.portions.first(where: { $0.id == first.id }),
                  let second = split.portions.first(where: { $0.id != first.id }) else { return false }
            let labelled = try store.setPositionBrokerageAccount(symbol: symbol, portionID: original.id,
                accountID: .financing, expectedRevision: split.revision)
            _ = try store.setPositionBrokerageAccount(symbol: symbol, portionID: second.id,
                accountID: .mengmeng, expectedRevision: labelled.revision)
            for account in [BrokerageAccountID.financing, .mengmeng] {
                store.withBrokerageAccount(account) {
                    store.add(SymbolInfo(symbol: symbol, name: "账户标签测试"))
                    _ = store.setTradePlan(.init(kind: .buy, price: 100, quantity: 5), for: symbol)
                }
                _ = app.poolBudgets.setCashBalance(amount: account == .financing ? 100 : 1000, currency: "CNY", in: account)
            }
            app.market.apply(quotes: [.init(symbol: symbol, price: 100, previousClose: 100, sourceName: "Fixture", timestamp: .now)])
            let baseline = store.syncSnapshot()
            let total = PoolBudgetInput(appState: app, currencyFilter: "CNY", allAccounts: true).calculate()
            let finance = PoolBudgetInput(appState: app, currencyFilter: "CNY", accountFilter: .financing, allAccounts: true).calculate()
            let mengmeng = PoolBudgetInput(appState: app, currencyFilter: "CNY", accountFilter: .mengmeng, allAccounts: true).calculate()
            let overview = BrokerageAccountOverviewReader.rows(store: store, market: app.market, budgets: app.poolBudgets)
            guard total.currency("CNY")?.holdingsBefore == 1000,
                  total.currency("CNY")?.cashBalance == 1100, total.currency("CNY")?.cashShortfall == 400,
                  finance.currency("CNY")?.holdingsBefore == 500, finance.currency("CNY")?.cashShortfall == 400,
                  mengmeng.currency("CNY")?.holdingsBefore == 500, mengmeng.currency("CNY")?.cashShortfall == 0,
                  overview.first(where: { $0.accountID == .financing && $0.currencyCode == "CNY" })?.holdingValue == 500,
                  overview.first(where: { $0.accountID == .mengmeng && $0.currencyCode == "CNY" })?.holdingValue == 500,
                  store.syncSnapshot() == baseline, store.activeBrokerageAccountID == .unassigned else { return false }
            return true
        } catch { print("BROKERAGE_SELFTEST card-attribution \(error)"); return false }
    }

}
#endif
