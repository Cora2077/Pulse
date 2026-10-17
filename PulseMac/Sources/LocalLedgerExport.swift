#if DEBUG
import Foundation
import PulseCore

/// Explicit, local-only transfer aid. Runs before AppState, networking, sync,
/// backups or telemetry are initialized. Reads one financial-data key only;
/// it never exports preferences wholesale, reads credentials, or writes a ledger.
/// The caller must redirect stdout to a private local file, never a shared log.
@MainActor
enum LocalLedgerExport {
    private static let storageKey = "pulse.watchlists.v4"

    private struct StoredAccounts: Codable {
        var version: Int
        var snapshot: WatchlistSyncSnapshot
        var activeAccountID: BrokerageAccountID
        var selectedGroupIDs: [String: UUID]
    }

    private enum ExportError: Error {
        case missingLedger, invalidEnvelope
    }

    static func runIfRequested() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--local-ledger-export-selftest") {
            guard arguments == ["--local-ledger-export-selftest"] else { fail() }
            do {
                try selfTest()
                print("LOCAL_LEDGER_EXPORT_SELFTEST passed: validated, lossless, read-only, credential-free, invalid input refused")
                exit(0)
            } catch { fail() }
        }
        guard arguments.contains("--export-local-ledger") else { return }
        // Do not accidentally export real data from a demo/self-test invocation.
        guard arguments == ["--export-local-ledger"] else { fail() }
        do {
            let data = try validatedData(from: .standard)
            try FileHandle.standardOutput.write(contentsOf: data)
            exit(0)
        } catch { fail() }
    }

    private static func fail() -> Never {
        // Error descriptions may carry record identities. Keep diagnostics generic.
        let message = "Local ledger export refused: missing/invalid account ledger or incompatible arguments. No data was exported.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        exit(1)
    }

    private static func validatedData(from defaults: UserDefaults) throws -> Data {
        guard let data = defaults.data(forKey: storageKey) else { throw ExportError.missingLedger }
        let stored = try JSONDecoder().decode(StoredAccounts.self, from: data)
        guard (1...2).contains(stored.version), stored.snapshot.brokerageAccounts != nil else {
            throw ExportError.invalidEnvelope
        }
        // Same integrity boundary as the actual store's on-disk codec. Return the
        // original bytes, not a projection which might drop undisplayed fields.
        _ = try WatchlistSyncWireCodec.encode(deviceID: "local-ledger-export-check", snapshot: stored.snapshot)
        return data
    }

    private static func selfTest() throws {
        let suite = "app.pulse.local-ledger-export-selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw ExportError.invalidEnvelope }
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            _ = try validatedData(from: defaults)
            throw ExportError.invalidEnvelope
        } catch ExportError.missingLedger { }

        let symbol = SymbolID(market: .us, code: "AAPL")
        let group = WatchlistGroup(name: "Synthetic export fixture", symbols: [symbol])
        let transaction = PositionTransaction(kind: .buy, price: 100, quantity: 2,
            review: .init(retrospective: "Synthetic review", nextReviewNote: "Synthetic checkpoint"),
            fundingSource: .own, brokerageAccountID: .mengmeng)
        let item = WatchItem(symbol: symbol, displayName: "Synthetic fixture", instrumentType: .equity,
            transactions: [transaction], plans: [TradePlan(kind: .buy, price: 90, quantity: 1, fundingSource: .own)])
        let snapshot = WatchlistSyncSnapshot(items: [], groups: [], brokerageAccounts: [
            BrokerageAccountPortfolio(accountID: .financing),
            BrokerageAccountPortfolio(accountID: .mengmeng, items: [item], groups: [group])
        ])
        let stored = StoredAccounts(version: 1, snapshot: snapshot, activeAccountID: .mengmeng,
            selectedGroupIDs: [BrokerageAccountID.mengmeng.rawValue: group.id])
        let original = try JSONEncoder().encode(stored)
        defaults.set(original, forKey: storageKey)
        defaults.set("synthetic-non-ledger-canary", forKey: "unrelated.provider.configuration")
        let before = defaults.persistentDomain(forName: suite) ?? [:]
        let exported = try validatedData(from: defaults)
        let after = defaults.persistentDomain(forName: suite) ?? [:]
        guard exported == original, NSDictionary(dictionary: before).isEqual(to: after),
              !String(decoding: exported, as: UTF8.self).contains("synthetic-non-ledger-canary") else {
            throw ExportError.invalidEnvelope
        }
        let decoded = try JSONDecoder().decode(StoredAccounts.self, from: exported)
        guard decoded.snapshot == snapshot, decoded.activeAccountID == stored.activeAccountID,
              decoded.selectedGroupIDs == stored.selectedGroupIDs else { throw ExportError.invalidEnvelope }

        defaults.set(Data("{}".utf8), forKey: storageKey)
        var refused = false
        do { _ = try validatedData(from: defaults) } catch { refused = true }
        guard refused else { throw ExportError.invalidEnvelope }
        var unsupported = stored
        unsupported.version = 999
        defaults.set(try JSONEncoder().encode(unsupported), forKey: storageKey)
        refused = false
        do { _ = try validatedData(from: defaults) } catch { refused = true }
        guard refused else { throw ExportError.invalidEnvelope }
    }
}
#endif
