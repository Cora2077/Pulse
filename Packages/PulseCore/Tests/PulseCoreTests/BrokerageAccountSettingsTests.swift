import Foundation
import Testing
@testable import PulseCore

@Suite("Brokerage account financial settings")
struct BrokerageAccountSettingsTests {
    @Test @MainActor func settingsPersistAcrossSelectionsAndExplicitClear() throws {
        let name = "pulse.settings-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        let finance = BrokerageAccountSettings(cashBalances: ["CNY": .init(amount: 500, updatedAt: .now)],
            poolLimits: [.init(currency: "CNY", pool: .tactical, amount: 100)], sectorLimits: ["CNY:Tech": 40])
        #expect(store.setBrokerageSettings(finance, for: .financing))
        #expect(store.activeBrokerageAccountID == .unassigned)
        #expect(store.brokerageSettings(for: .mengmeng) == nil)
        store.selectBrokerageAccount(.financing)
        store.selectBrokerageAccount(.mengmeng)
        let reloaded = WatchlistStore(defaults: defaults)
        #expect(reloaded.activeBrokerageAccountID == .mengmeng)
        #expect(reloaded.brokerageSettings(for: .financing) == finance)
        #expect(reloaded.setBrokerageSettings(.init(), for: .financing))
        #expect(WatchlistStore(defaults: defaults).brokerageSettings(for: .financing) == .init())
        var invalid = finance
        invalid.cashBalances["CNY"]?.amount = -1
        let before = store.syncSnapshot()
        #expect(!store.setBrokerageSettings(invalid, for: .financing))
        #expect(store.syncSnapshot() == before)
    }

    @Test @MainActor func fullBackupRestoresMoneyWhileLegacyBackupPreservesSettings() throws {
        let name = "pulse.settings-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = WatchlistStore(defaults: defaults)
        store.enableBrokerageAccounts()
        for id in BrokerageAccountID.allCases {
            #expect(store.setBrokerageSettings(.init(cashBalances: ["CNY": .init(amount: 100, updatedAt: .now)]), for: id))
        }
        let target = store.syncSnapshot()
        let wire = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: target)
        #expect(try WatchlistSyncWireCodec.decode(wire).version == 13)
        #expect(try WatchlistSyncWireCodec.decode(wire).snapshot == target)
        #expect(store.setBrokerageSettings(.init(), for: .financing))
        #expect(try store.restoreBackup(target))
        #expect(store.syncSnapshot() == target)
        let old = WatchlistSyncSnapshot(items: target.items, groups: target.groups)
        _ = try store.restoreBackup(old)
        #expect(store.brokerageSettings(for: .financing)?.cashBalances["CNY"]?.amount == 100)
        #expect(store.brokerageSettings(for: .unassigned)?.cashBalances["CNY"]?.amount == 100)
    }

    @Test func mergesIndependentAccountsButDoesNotGuessConflictingCash() {
        let base = WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [
            .init(accountID: .financing, settings: .init()), .init(accountID: .mengmeng, settings: .init())
        ], accountSettings: .init())
        var local = base; var remote = base
        local.brokerageAccounts![0].settings!.cashBalances["CNY"] = .init(amount: 100, updatedAt: .distantPast)
        remote.brokerageAccounts![1].settings!.sectorLimits["CNY:Tech"] = 40
        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(merged.isConflictFree)
        #expect(merged.snapshot.brokerageAccounts![0].settings == local.brokerageAccounts![0].settings)
        #expect(merged.snapshot.brokerageAccounts![1].settings == remote.brokerageAccounts![1].settings)
        remote.brokerageAccounts![0].settings!.cashBalances["CNY"] = .init(amount: 200, updatedAt: .distantPast)
        let conflict = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        #expect(conflict.brokerageConflict?.accountIDs == [.financing])
        #expect(WatchlistSyncMerge.resolve(conflict, choosing: .local) == local)
        local = base; remote = base
        local.accountSettings!.sectorLimits["CNY:Tech"] = 20
        remote.accountSettings!.sectorLimits["CNY:Tech"] = 60
        #expect(WatchlistSyncMerge.merge(base: base, local: local, remote: remote).brokerageConflict?.accountIDs == [.unassigned])
    }

    @Test func oldPeerKeepsKnownCashAndOlderSchemaCannotHideFinancialFields() throws {
        let settings = BrokerageAccountSettings(cashBalances: ["CNY": .init(amount: 100, updatedAt: .distantPast)])
        let base = WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [
            .init(accountID: .financing, settings: settings)
        ], accountSettings: settings)
        var old = base
        old.accountSettings = nil; old.brokerageAccounts![0].settings = nil
        let result = WatchlistSyncMerge.merge(base: base, local: base, remote: old)
        #expect(result.isConflictFree)
        #expect(result.snapshot == base)
        let encoded = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: base)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["version"] = 12
        #expect(throws: WatchlistSyncWireCodec.CodecError.self) {
            try WatchlistSyncWireCodec.decode(JSONSerialization.data(withJSONObject: object))
        }
    }
}
