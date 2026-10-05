import Foundation
import Observation
import PulseCore

@MainActor @Observable
final class SectorLimitSettings {
    private var storedLimits: [String: Double] = [:]
    private(set) var revision: UInt64 = 0

    private let defaults: UserDefaults
    private static let key = "pulse.sectorLimits.v1"
    private static func accountKey(_ id: BrokerageAccountID) -> String {
        "pulse.sectorLimits.accounts.v1.\(id.rawValue)"
    }

    private(set) var accountID: BrokerageAccountID = .unassigned
    @ObservationIgnored private var store: WatchlistStore?

    init(defaults: UserDefaults = .standard, accountID: BrokerageAccountID = .unassigned) {
        self.defaults = defaults
        self.accountID = accountID
        storedLimits = Self.load(defaults: defaults, accountID: accountID)
    }

    // MARK: - Attach

    @discardableResult
    func attach(to store: WatchlistStore, migrating accounts: Set<BrokerageAccountID>) -> Bool {
        guard store.brokerageAccountsEnabled else { return false }
        self.store = store
        revision &+= 1
        for id in accounts {
            // A record Core already had keeps its own sector limits, whoever
            // wrote them. Migration only fills a domain that is still absent.
            let existing = store.brokerageSettings(for: id)
            if let existing, !existing.sectorLimits.isEmpty { continue }
            let legacy = Self.load(defaults: defaults, accountID: id)
            guard !legacy.isEmpty else { continue }
            var settings = existing ?? BrokerageAccountSettings()
            settings.sectorLimits = legacy
            guard settings.isValid, store.setBrokerageSettings(settings, for: id) else { continue }
        }
        return true
    }

    func selectBrokerageAccount(_ id: BrokerageAccountID) {
        guard id != accountID else { return }
        accountID = id
        storedLimits = Self.load(defaults: defaults, accountID: id)
        revision &+= 1
    }

    // MARK: - Reads

    var limits: [String: Double] {
        if store != nil { return currentLimits() }
        _ = revision
        return storedLimits
    }

    func limits(for id: BrokerageAccountID) -> [String: Double] {
        _ = revision
        if id == accountID, store == nil { return storedLimits }
        guard let store else { return Self.load(defaults: defaults, accountID: id) }
        return store.brokerageSettings(for: id)?.sectorLimits ?? [:]
    }

    // MARK: - Writes

    @discardableResult
    func setLimit(_ value: Double?, for key: String) -> Bool {
        guard !key.isEmpty, Self.isValid(value) else { return false }
        if let store {
            var candidate = currentLimits()
            if let value { candidate[key] = value } else { candidate.removeValue(forKey: key) }
            return commit(candidate, store: store)
        }
        var candidate = storedLimits
        if let value { candidate[key] = value } else { candidate.removeValue(forKey: key) }
        guard let data = try? JSONEncoder().encode(candidate) else { return false }
        storedLimits = candidate
        defaults.set(data, forKey: Self.accountKey(accountID))
        revision &+= 1
        return true
    }

    private func commit(_ candidate: [String: Double], store: WatchlistStore) -> Bool {
        var settings = store.brokerageSettings(for: accountID) ?? BrokerageAccountSettings()
        settings.sectorLimits = candidate
        guard store.setBrokerageSettings(settings, for: accountID) else { return false }
        revision &+= 1
        return true
    }

    private func currentLimits() -> [String: Double] {
        store?.brokerageSettings(for: accountID)?.sectorLimits ?? [:]
    }

    // MARK: - Detached load


    private static func load(defaults: UserDefaults, accountID: BrokerageAccountID) -> [String: Double] {
        let data = defaults.data(forKey: accountKey(accountID))
            ?? (accountID == .unassigned ? defaults.data(forKey: key) : nil)
        let decoded = data.flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        // Malformed entries are dropped individually rather than discarding the
        // whole record: one bad ceiling should not silence the others.
        return decoded.filter { !$0.key.isEmpty && isValid($0.value) }
    }

    private static func isValid(_ value: Double?) -> Bool {
        value.map { $0.isFinite && $0 > 0 && $0 <= 100 } ?? true
    }
}
