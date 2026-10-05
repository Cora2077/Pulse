import Foundation
import Observation
import PulseCore

typealias CashBalance = BrokerageCashBalance
typealias PoolBudgetScenario = BrokeragePoolBudgetScenario

@MainActor @Observable
final class PoolBudgetSettings {
    private var storedCashBalances: [String: CashBalance] = [:]
    private var storedPoolLimits: [String: [PositionPool: Double]] = [:]
    private var storedScenarios: [PoolBudgetScenario] = []

    private(set) var revision: UInt64 = 0

    private let defaults: UserDefaults
    private static let legacyKey = "pulse.poolBudgets.v1"
    private(set) var accountID: BrokerageAccountID = .unassigned

    @ObservationIgnored private var store: WatchlistStore?

    private var key: String { "pulse.poolBudgets.accounts.v1.\(accountID.rawValue)" }
    private static func accountKey(_ id: BrokerageAccountID) -> String {
        "pulse.poolBudgets.accounts.v1.\(id.rawValue)"
    }

    private struct Stored: Codable {
        var cashBalances: [String: CashBalance]
        var poolLimits: [BrokeragePoolLimit]
        var scenarios: [PoolBudgetScenario]
    }

    // MARK: - Lifetime

    init(defaults: UserDefaults = .standard, accountID: BrokerageAccountID = .unassigned) {
        self.defaults = defaults
        self.accountID = accountID
        loadAccount()
    }

    // MARK: - Attach

    @discardableResult
    func attach(to store: WatchlistStore, migrating accounts: Set<BrokerageAccountID>) -> Bool {
        guard store.brokerageAccountsEnabled else { return false }
        self.store = store
        revision &+= 1
        for id in BrokerageAccountID.allCases where accounts.contains(id) {
            migrateLegacyRecord(for: id, store: store)
        }
        return true
    }

    private func migrateLegacyRecord(for id: BrokerageAccountID, store: WatchlistStore) {
        guard let stored = storedAccount(id),
              !stored.cashBalances.isEmpty || !stored.poolLimits.isEmpty || !stored.scenarios.isEmpty else {
            return
        }
        store.setBrokerageSettings(Self.applying(stored, to: store.brokerageSettings(for: id)), for: id)
    }

    // MARK: - Account scope

    func selectBrokerageAccount(_ id: BrokerageAccountID) {
        guard id != accountID else { return }
        accountID = id
        loadAccount()
    }

    // MARK: - Reads

    var cashBalances: [String: CashBalance] {
        if store != nil { return currentSettings()?.cashBalances ?? [:] }
        _ = revision
        return storedCashBalances
    }

    var poolLimits: [String: [PositionPool: Double]] {
        if store != nil { return Self.grouped(currentSettings()?.poolLimits ?? []) }
        _ = revision
        return storedPoolLimits
    }

    var scenarios: [PoolBudgetScenario] {
        if store != nil { return currentSettings()?.scenarios ?? [] }
        _ = revision
        return storedScenarios
    }

    func cashBalance(currency: String) -> CashBalance? {
        cashBalances[Self.normalizedCurrency(currency)]
    }

    func poolLimit(currency: String, pool: PositionPool) -> Double? {
        poolLimits[Self.normalizedCurrency(currency)]?[pool]
    }

    func cashBalances(for id: BrokerageAccountID) -> [String: CashBalance] {
        _ = revision
        if id == accountID, store == nil { return storedCashBalances }
        guard let store else { return storedAccount(id)?.cashBalances ?? [:] }
        return store.brokerageSettings(for: id)?.cashBalances ?? [:]
    }

    // MARK: - Writes

    @discardableResult
    func setCashBalance(amount: Double?, currency: String) -> Bool {
        let code = Self.normalizedCurrency(currency)
        guard Self.isValidCurrency(code), Self.isValidAmount(amount) else { return false }
        var candidate = cashBalances
        if let amount {
            candidate[code] = CashBalance(amount: amount, updatedAt: .now)
        } else {
            candidate.removeValue(forKey: code)
        }
        return commit(cashBalances: candidate, poolLimits: poolLimits, scenarios: scenarios)
    }

    @discardableResult
    func setCashBalance(amount: Double?, currency: String, in id: BrokerageAccountID) -> Bool {
        if id == accountID { return setCashBalance(amount: amount, currency: currency) }
        let code = Self.normalizedCurrency(currency)
        guard Self.isValidCurrency(code), Self.isValidAmount(amount) else { return false }
        guard let store else {
            var stored = storedAccount(id) ?? Self.emptyStored
            if let amount { stored.cashBalances[code] = CashBalance(amount: amount, updatedAt: .now) }
            else { stored.cashBalances.removeValue(forKey: code) }
            guard Self.isValid(stored), let data = try? JSONEncoder().encode(stored) else { return false }
            defaults.set(data, forKey: Self.accountKey(id))
            revision &+= 1
            return true
        }
        // Editing another account must not move the selection, so the write goes
        // through the store's (account, ...) form rather than a switch.
        var balance = store.brokerageSettings(for: id)?.cashBalances ?? [:]
        if let amount { balance[code] = CashBalance(amount: amount, updatedAt: .now) }
        else { balance.removeValue(forKey: code) }
        guard commitOther(cashBalances: balance, id: id, store: store) else { return false }
        revision &+= 1
        return true
    }

    @discardableResult
    func setPoolLimit(amount: Double?, currency: String, pool: PositionPool) -> Bool {
        let code = Self.normalizedCurrency(currency)
        guard Self.isValidCurrency(code), Self.isValidAmount(amount) else { return false }
        var candidate = poolLimits
        if let amount {
            candidate[code, default: [:]][pool] = amount
        } else {
            candidate[code]?.removeValue(forKey: pool)
            if candidate[code]?.isEmpty == true { candidate.removeValue(forKey: code) }
        }
        return commit(cashBalances: cashBalances, poolLimits: candidate, scenarios: scenarios)
    }

    @discardableResult
    func saveScenario(name: String, planIDs: [UUID]) -> PoolBudgetScenario? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, cleanName.count <= 80, !planIDs.isEmpty,
              Set(planIDs).count == planIDs.count else { return nil }
        let scenario = PoolBudgetScenario(id: UUID(), name: cleanName, planIDs: planIDs)
        guard commit(cashBalances: cashBalances, poolLimits: poolLimits,
                     scenarios: scenarios + [scenario]) else { return nil }
        return scenario
    }

    @discardableResult
    func deleteScenario(id: UUID) -> Bool {
        guard scenarios.contains(where: { $0.id == id }) else { return false }
        return commit(cashBalances: cashBalances, poolLimits: poolLimits,
                      scenarios: scenarios.filter { $0.id != id })
    }

    // MARK: - Commit

    private func commit(
        cashBalances: [String: CashBalance],
        poolLimits: [String: [PositionPool: Double]],
        scenarios: [PoolBudgetScenario]
    ) -> Bool {
        let records = Self.records(poolLimits)
        if let store {
            let settings = BrokerageAccountSettings(
                cashBalances: cashBalances,
                poolLimits: records,
                scenarios: scenarios,
                sectorLimits: currentSettings()?.sectorLimits ?? [:]
            )
            guard store.setBrokerageSettings(settings, for: accountID) else { return false }
        } else {
            let stored = Stored(cashBalances: cashBalances, poolLimits: records, scenarios: scenarios)
            guard Self.isValid(stored), let data = try? JSONEncoder().encode(stored),
                  let decoded = try? JSONDecoder().decode(Stored.self, from: data), Self.isValid(decoded) else {
                return false
            }
            storedCashBalances = cashBalances
            storedPoolLimits = poolLimits
            storedScenarios = scenarios
            defaults.set(data, forKey: key)
        }
        revision &+= 1
        return true
    }

    private func commitOther(cashBalances: [String: CashBalance], id: BrokerageAccountID,
                             store: WatchlistStore) -> Bool {
        let existing = store.brokerageSettings(for: id)
        let settings = BrokerageAccountSettings(
            cashBalances: cashBalances,
            poolLimits: existing?.poolLimits ?? [],
            scenarios: existing?.scenarios ?? [],
            sectorLimits: existing?.sectorLimits ?? [:]
        )
        return store.setBrokerageSettings(settings, for: id)
    }

    // MARK: - Detached load


    private func loadAccount() {
        storedCashBalances = [:]; storedPoolLimits = [:]; storedScenarios = []
        guard let stored = storedAccount(accountID) else { return }
        storedCashBalances = stored.cashBalances
        storedPoolLimits = Self.grouped(stored.poolLimits)
        storedScenarios = stored.scenarios
    }

    private func currentSettings() -> BrokerageAccountSettings? {
        store?.brokerageSettings(for: accountID)
    }

    private func storedAccount(_ id: BrokerageAccountID) -> Stored? {
        let data = defaults.data(forKey: Self.accountKey(id))
            ?? (id == .unassigned ? defaults.data(forKey: Self.legacyKey) : nil)
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data),
              Self.isValid(stored) else { return nil }
        return stored
    }

    // MARK: - Merge

    private static func applying(_ stored: Stored, to existing: BrokerageAccountSettings?) -> BrokerageAccountSettings {
        var settings = existing ?? BrokerageAccountSettings()
        settings.cashBalances = stored.cashBalances
        settings.scenarios = stored.scenarios
        settings.poolLimits = stored.poolLimits.sorted { ($0.currency, $0.pool.rawValue) < ($1.currency, $1.pool.rawValue) }
        return settings
    }

    // MARK: - Shape

    private static var emptyStored: Stored {
        Stored(cashBalances: [:], poolLimits: [], scenarios: [])
    }

    private static func grouped(_ records: [BrokeragePoolLimit]) -> [String: [PositionPool: Double]] {
        Dictionary(grouping: records, by: \.currency).mapValues {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.pool, $0.amount) })
        }
    }

    private static func records(_ limits: [String: [PositionPool: Double]]) -> [BrokeragePoolLimit] {
        limits.flatMap { currency, pools in
            pools.map { BrokeragePoolLimit(currency: currency, pool: $0.key, amount: $0.value) }
        }
        .sorted { ($0.currency, $0.pool.rawValue) < ($1.currency, $1.pool.rawValue) }
    }

    private static func isValidAmount(_ amount: Double?) -> Bool {
        amount.map { $0.isFinite && $0 >= 0 } ?? true
    }

    private static func isValid(_ stored: Stored) -> Bool {
        stored.cashBalances.allSatisfy { currency, balance in
            isValidCurrency(currency) && balance.amount.isFinite && balance.amount >= 0
                && balance.updatedAt.timeIntervalSince1970.isFinite
        }
        && stored.poolLimits.allSatisfy {
            isValidCurrency($0.currency) && $0.amount.isFinite && $0.amount >= 0
        }
        && Set(stored.poolLimits.map { "\($0.currency)|\($0.pool.rawValue)" }).count == stored.poolLimits.count
        && Set(stored.scenarios.map(\.id)).count == stored.scenarios.count
        && stored.scenarios.allSatisfy {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.name.count <= 80 && !$0.planIDs.isEmpty && Set($0.planIDs).count == $0.planIDs.count
        }
    }

    private static func normalizedCurrency(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func isValidCurrency(_ value: String) -> Bool {
        (2...12).contains(value.count) && value.utf8.allSatisfy { (65...90).contains($0) }
    }
}
