import AppKit
import Foundation
import Observation
import PulseCore
import PulseUI
import UserNotifications

struct BrokerageAlertTarget: Equatable {
    var accountID: BrokerageAccountID
    var symbol: SymbolID
    var planID: UUID?
}

@MainActor
@Observable
final class PlanAlertController: NSObject, UNUserNotificationCenterDelegate {
    private(set) var enabled: Bool
    private(set) var sectorEnabled: Bool
    private(set) var status = PulseLocalization.localizedString("alerts.status.off")
    private(set) var lastError: String?
    @ObservationIgnored private let store: WatchlistStore
    @ObservationIgnored private let market: MarketStore
    @ObservationIgnored private let sectorLimits: SectorLimitSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isOffline: Bool
    @ObservationIgnored private var ledgers: [String: PlanAlertLedger]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var pendingSectors: Set<String> = []
    @ObservationIgnored private var deliveredSectors: [String: String]
    @ObservationIgnored var onOpen: ((BrokerageAlertTarget) -> Void)?
    private static let stateKey = "pulse.planAlerts.accounts.delivery.v1"
    private static let legacyStateKey = "pulse.planAlerts.delivery.v1"
    private static let enabledKey = "pulse.planAlerts.enabled.v1"
    private static let sectorEnabledKey = "pulse.sectorAlerts.enabled.v1"
    private static let sectorDeliveryKey = "pulse.sectorAlerts.accounts.delivery.v1"
    private static let category = "pulse.planReached"
    private static let snoozeAction = "pulse.planSnooze15"

    init(store: WatchlistStore, market: MarketStore, defaults: UserDefaults, isOffline: Bool,
         sectorLimits: SectorLimitSettings) {
        self.store = store
        self.market = market
        self.sectorLimits = sectorLimits
        self.defaults = defaults
        self.isOffline = isOffline
        enabled = defaults.bool(forKey: Self.enabledKey)
        sectorEnabled = defaults.bool(forKey: Self.sectorEnabledKey)
        deliveredSectors = defaults.dictionary(forKey: Self.sectorDeliveryKey) as? [String: String] ?? [:]
        ledgers = defaults.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode([String: PlanAlertLedger].self, from: $0) } ?? [:]
        if defaults.data(forKey: Self.stateKey) == nil, let legacy = defaults.data(forKey: Self.legacyStateKey)
            .flatMap({ try? JSONDecoder().decode(PlanAlertLedger.self, from: $0) }) {
            for account in store.brokerageAccountsEnabled ? BrokerageAccountID.allCases : [.unassigned] {
                let portfolio = store.brokeragePortfolio(for: account)
                var accountLedger = legacy
                accountLedger.prune(keeping: Set(portfolio.items.flatMap(\.plans).map(\.id)))
                ledgers[account.rawValue] = accountLedger
            }
        }
        if deliveredSectors.isEmpty,
           let legacy = defaults.dictionary(forKey: "pulse.sectorAlerts.delivery.v1") as? [String: String] {
            deliveredSectors = Dictionary(uniqueKeysWithValues: legacy.map { ("unassigned:\($0.key)", $0.value) })
        }
        super.init()
    }

    func start() {
        guard !isOffline, task == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [UNNotificationAction(identifier: Self.snoozeAction,
                                           title: PulseLocalization.localizedString("alerts.snooze.title"), options: [])],
            intentIdentifiers: [], options: []
        )])
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    func setEnabled(_ value: Bool) async {
        guard !isOffline else { status = PulseLocalization.localizedString("alerts.status.demo"); return }
        lastError = nil
        if value {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                    status = PulseLocalization.localizedString("alerts.status.permissionDenied")
                    return
                }
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if !value {
            let ids = accountIDs.flatMap { account in
                entries(in: account).flatMap { [Self.notificationID(account: account, planID: $0.id), $0.id.uuidString] }
            }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
        await evaluate()
    }

    func setSectorEnabled(_ value: Bool) async {
        guard !isOffline else { status = PulseLocalization.localizedString("alerts.status.demo"); return }
        do {
            if value {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                    status = PulseLocalization.localizedString("alerts.status.permissionDenied"); return
                }
            }
            sectorEnabled = value
            defaults.set(value, forKey: Self.sectorEnabledKey)
            lastError = nil
            await evaluate()
        } catch { lastError = error.localizedDescription }
    }

    private func evaluate() async {
        guard enabled || sectorEnabled else { status = PulseLocalization.localizedString("alerts.status.off"); return }
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings()
        guard enabled || sectorEnabled else { return }
        guard permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional else {
            status = PulseLocalization.localizedString("alerts.status.permissionDenied")
            return
        }
        status = PulseLocalization.localizedString("alerts.status.on")
        for account in accountIDs {
            let entries = entries(in: account)
            ledgers[account.rawValue, default: PlanAlertLedger()].prune(keeping: Set(entries.map(\.id)))
            for entry in entries where enabled {
                let requestID = Self.notificationID(account: account, planID: entry.id)
                guard let quote = market.quote(for: entry.symbol),
                      notificationIsDue(entry.plan, account: account, quote: quote),
                      pending.insert(requestID).inserted else { continue }
                let content = UNMutableNotificationContent()
                let item = items(in: account).first { $0.symbol == entry.symbol }
                content.title = PulseLocalization.localizedString("alerts.plan.title",
                                    AccountIdentity.title(account),
                                    item?.resolvedDisplayName ?? entry.symbol.displayCode)
                let side = entry.plan.kind == .buy
                    ? PulseLocalization.localizedString("plan.kind.buy")
                    : PulseLocalization.localizedString("plan.kind.sell")
                let price = PriceFormatter.price(entry.plan.price, market: entry.symbol.market)
                let current = PriceFormatter.price(quote.price, market: entry.symbol.market)
                content.body = PulseLocalization.localizedString("alerts.plan.body", side, price, current)
                content.categoryIdentifier = Self.category
                content.userInfo = ["account_id": account.rawValue]
                content.sound = .default
                content.interruptionLevel = .active
                do {
                    try await center.add(.init(identifier: requestID, content: content, trigger: nil))
                    ledgers[account.rawValue, default: PlanAlertLedger()].markDelivered(entry.plan)
                    saveLedger()
                    lastError = nil
                } catch { lastError = error.localizedDescription }
                pending.remove(requestID)
            }
            if sectorEnabled { await evaluateSectors(center, account: account) }
        }
    }

    private var accountIDs: [BrokerageAccountID] {
        store.brokerageAccountsEnabled ? BrokerageAccountID.allCases : [.unassigned]
    }

    private func items(in account: BrokerageAccountID) -> [WatchItem] {
        let portfolio = store.brokeragePortfolio(for: account)
        return portfolio.items
    }

    func entries(in account: BrokerageAccountID) -> [TradePlanEntry] {
        let portfolio = store.brokeragePortfolio(for: account)
        let followed = Set(portfolio.groups.flatMap(\.symbols))
        return portfolio.items.filter { followed.contains($0.symbol) }.flatMap { item in
            item.plans.map { TradePlanEntry(symbol: item.symbol, plan: $0, transactions: store.transactionsForPlan(item.symbol, account: account)) }
        }
    }

    func notificationIsDue(_ plan: TradePlan, account: BrokerageAccountID, quote: Quote, now: Date = .now) -> Bool {
        ledgers[account.rawValue, default: PlanAlertLedger()].shouldNotify(plan: plan, quote: quote, now: now)
    }

    static func notificationID(account: BrokerageAccountID, planID: UUID) -> String {
        "plan:\(account.rawValue):\(planID.uuidString)"
    }

    /// Old UUID-only notifications are opened only if their owner is unambiguous.
    func target(for identifier: String) -> BrokerageAlertTarget? {
        let parts = identifier.split(separator: ":").map(String.init)
        if parts.count == 3, parts[0] == "plan", let account = BrokerageAccountID(rawValue: parts[1]),
           let id = UUID(uuidString: parts[2]), let entry = entries(in: account).first(where: { $0.id == id }) {
            return .init(accountID: account, symbol: entry.symbol, planID: id)
        }
        guard let id = UUID(uuidString: identifier) else { return nil }
        let matches = accountIDs.flatMap { account in
            entries(in: account).filter { $0.id == id }.map {
                BrokerageAlertTarget(accountID: account, symbol: $0.symbol, planID: id)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func evaluateSectors(_ center: UNUserNotificationCenter, account: BrokerageAccountID) async {
        let items = items(in: account).filter { $0.supportsPosition && $0.positionQuantity != 0 }
        let quotes = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (SymbolID, Quote)? in
            market.quote(for: item.symbol).map { (item.symbol, $0) }
        })
        let incompleteCurrencies = Set(items.filter { item in
            quotes[item.symbol].map { !TradingQuoteHealth.isCurrent($0) } ?? true
        }.map { $0.symbol.currencyCode })
        let allocation = PortfolioAllocation.calculate(positions: items.map { item in
            .init(symbol: item.symbol, name: item.resolvedDisplayName, quantity: item.positionQuantity,
                  price: quotes[item.symbol]?.price, currencyCode: item.symbol.currencyCode)
        })
        let sectors = SectorExposure.make(allocation: allocation, sectors: Dictionary(uniqueKeysWithValues:
            items.map { ($0.symbol, $0.tradingProfile?.sector ?? "") }))
        let day = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayKey = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        for sector in sectors where !incompleteCurrencies.contains(sector.currencyCode) {
            guard sectorEnabled, let limit = sectorLimits.limits(for: account)[sector.id], sector.percent > limit else { continue }
            let deliveryKey = "\(account.rawValue):\(sector.id):\(limit)"
            guard deliveredSectors[deliveryKey] != dayKey,
                  pendingSectors.insert(deliveryKey).inserted else { continue }
            defer { pendingSectors.remove(deliveryKey) }
            let content = UNMutableNotificationContent()
            content.title = PulseLocalization.localizedString("alerts.sector.title",
                                AccountIdentity.title(account), sector.name)
            content.body = PulseLocalization.localizedString("alerts.sector.body",
                              sector.currencyCode,
                              String(format: "%.1f", sector.percent),
                              String(format: "%g", limit))
            content.sound = .default
            if let symbol = sector.holdings.first?.symbol, let data = try? JSONEncoder().encode(symbol) {
                content.userInfo = ["symbol": data.base64EncodedString(), "account_id": account.rawValue]
            }
            do {
                try await center.add(.init(identifier: "sector:\(account.rawValue):\(sector.id)", content: content, trigger: nil))
                deliveredSectors = deliveredSectors.filter { $0.value == dayKey }
                deliveredSectors[deliveryKey] = dayKey
                defaults.set(deliveredSectors, forKey: Self.sectorDeliveryKey)
            } catch { lastError = error.localizedDescription }
        }
    }

    func snooze(_ plan: TradePlan, account: BrokerageAccountID? = nil) {
        let account = account ?? store.activeBrokerageAccountID
        ledgers[account.rawValue, default: PlanAlertLedger()].snooze(plan, until: .now.addingTimeInterval(900))
        saveLedger()
        if !isOffline {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID(account: account, planID: plan.id), plan.id.uuidString])
        }
    }

    private func saveLedger() {
        if let data = try? JSONEncoder().encode(ledgers) { defaults.set(data, forKey: Self.stateKey) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) { completionHandler([.banner, .sound]) }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        let accountRaw = response.notification.request.content.userInfo["account_id"] as? String
        let encodedSectorSymbol = response.notification.request.content.userInfo["symbol"] as? String
        Task { @MainActor [weak self] in
            if let self, id.hasPrefix("sector:"), action == UNNotificationDefaultActionIdentifier,
               let encoded = encodedSectorSymbol,
               let data = Data(base64Encoded: encoded), let symbol = try? JSONDecoder().decode(SymbolID.self, from: data) {
                let account = accountRaw.flatMap(BrokerageAccountID.init(rawValue:)) ?? .unassigned
                guard self.items(in: account).contains(where: { $0.symbol == symbol }) else {
                    completionHandler(); return
                }
                self.onOpen?(.init(accountID: account, symbol: symbol))
                AppDelegate.reopenHandler?()
                MainWindow.activate()
                completionHandler(); return
            }
            guard let self, let target = self.target(for: id),
                  let entry = self.entries(in: target.accountID).first(where: { $0.id == target.planID }) else {
                completionHandler(); return
            }
            if action == Self.snoozeAction { self.snooze(entry.plan, account: target.accountID) }
            else if action == UNNotificationDefaultActionIdentifier {
                self.onOpen?(target)
                AppDelegate.reopenHandler?()
                MainWindow.activate()
            }
            completionHandler()
        }
    }
}
