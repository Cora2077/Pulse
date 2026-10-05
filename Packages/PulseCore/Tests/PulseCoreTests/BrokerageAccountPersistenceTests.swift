import Foundation
import XCTest
@testable import PulseCore

final class BrokerageAccountPersistenceTests: XCTestCase {
    private let symbol = SymbolID(market: .sz, code: "000001")

    private func portfolio(_ id: BrokerageAccountID, transaction: PositionTransaction? = nil) -> BrokerageAccountPortfolio {
        let items = transaction.map { [WatchItem(symbol: symbol, displayName: "Fixture", transactions: [$0])] } ?? []
        return .init(accountID: id, items: items, groups: [.init(name: "Fixture", symbols: items.map(\.symbol))])
    }

    private func snapshot(_ portfolios: [BrokerageAccountPortfolio] = []) -> WatchlistSyncSnapshot {
        .init(items: [], groups: [.init(name: "Legacy")], brokerageAccounts: portfolios)
    }

    func testAccountWireRoundTripAllowsSameSymbolButKeepsIndependentLedgers() throws {
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 100, fundingSource: .margin)
        let otherBuy = PositionTransaction(kind: .buy, price: 20, quantity: 200)
        let original = snapshot([portfolio(.financing, transaction: buy), portfolio(.mengmeng, transaction: otherBuy)])
        let decoded = try WatchlistSyncWireCodec.decode(WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: original))
        XCTAssertEqual(decoded.version, 12)
        XCTAssertEqual(decoded.snapshot, original)
        XCTAssertEqual(decoded.snapshot.brokerageAccounts?[0].items[0].averageCost, 10)
        XCTAssertEqual(decoded.snapshot.brokerageAccounts?[1].items[0].averageCost, 20)
    }

    func testAccountPayloadCannotClaimOldVersionOrDuplicateIdentity() throws {
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 100)
        let original = snapshot([portfolio(.financing, transaction: buy)])
        let data = try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 11
        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot:
            snapshot([portfolio(.financing), portfolio(.financing)])))
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot:
            snapshot([portfolio(.unassigned)])))
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot:
            snapshot([portfolio(.financing, transaction: buy), portfolio(.mengmeng, transaction: buy)])))
    }

    func testInvalidInactiveAccountCannotBypassWireValidation() {
        var invalid = portfolio(.financing, transaction: .init(kind: .buy, price: 10, quantity: 100))
        invalid.items[0].transactions[0].fee = -1
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(deviceID: "fixture", snapshot: snapshot([invalid])))
        invalid = portfolio(.financing)
        invalid.groups = []
        XCTAssertThrowsError(try LocalBackupStore.validateSnapshot(snapshot([invalid])))
    }

    func testDifferentAccountsMergeWithoutConflict() {
        let base = snapshot([portfolio(.financing), portfolio(.mengmeng)])
        var local = base; var remote = base
        local.brokerageAccounts?[0] = portfolio(.financing, transaction: .init(kind: .buy, price: 10, quantity: 100))
        remote.brokerageAccounts?[1] = portfolio(.mengmeng, transaction: .init(kind: .buy, price: 20, quantity: 200))
        let merged = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        XCTAssertTrue(merged.isConflictFree)
        XCTAssertEqual(merged.snapshot.brokerageAccounts?[0], local.brokerageAccounts?[0])
        XCTAssertEqual(merged.snapshot.brokerageAccounts?[1], remote.brokerageAccounts?[1])
    }

    func testLegacyPeerCannotEraseNamedAccountHistory() {
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 100)
        let base = snapshot([portfolio(.financing, transaction: buy), portfolio(.mengmeng)])
        var local = base
        local.brokerageAccounts?[0].items[0].thesis = "local"
        var oldPeer = WatchlistSyncSnapshot(items: base.items, groups: base.groups)
        oldPeer.groups[0].name = "remote"
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: oldPeer)
        XCTAssertTrue(result.isConflictFree)
        XCTAssertEqual(result.snapshot.brokerageAccounts?[0], local.brokerageAccounts?[0])
        XCTAssertEqual(result.snapshot.groups[0].name, "remote")
    }

    func testConflictingAssignmentsRequireChoosingOneCompleteHistory() {
        let buy = PositionTransaction(kind: .buy, price: 10, quantity: 100)
        var base = snapshot([portfolio(.financing), portfolio(.mengmeng)])
        base.items = [WatchItem(symbol: symbol, displayName: "Fixture", transactions: [buy])]
        base.groups[0].symbols = [symbol]
        var local = base; var remote = base
        local.items[0].transactions = []; remote.items[0].transactions = []
        local.brokerageAccounts?[0] = portfolio(.financing, transaction: buy)
        remote.brokerageAccounts?[1] = portfolio(.mengmeng, transaction: buy)
        let result = WatchlistSyncMerge.merge(base: base, local: local, remote: remote)
        XCTAssertFalse(result.isConflictFree)
        XCTAssertNotNil(result.brokerageConflict)
        XCTAssertEqual(WatchlistSyncMerge.resolve(result, choosing: .local), local)
        XCTAssertEqual(WatchlistSyncMerge.resolve(result, choosing: .remote), remote)
    }

    func testBackupCountsAndPreviewIncludeInactiveAccounts() throws {
        let original = snapshot([portfolio(.financing, transaction: .init(kind: .buy, price: 10, quantity: 100))])
        let counts = LocalBackupCounts(snapshot: original)
        XCTAssertEqual(counts.symbols, 1)
        XCTAssertEqual(counts.transactions, 1)
        XCTAssertEqual(counts.groups, 2)
        let preview = LocalBackupPreview(current: snapshot(), target: original)
        XCTAssertEqual(preview.entryChanges.added, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backups = LocalBackupStore(bundleIdentifier: "fixture", applicationSupportURL: directory)
        let record = try backups.createBackup(kind: .manual, snapshot: original)
        XCTAssertEqual(try backups.readSnapshot(for: record), original)
    }

    func testArchiveIsAccountScopedAndVersionGated() throws {
        let archive = WatchlistArchive(lists: [.init(name: "Fixture", entries: [.init(market: .sz, code: "000001")])],
                                      brokerageAccountID: .mengmeng)
        XCTAssertEqual(archive.version, 11)
        XCTAssertEqual(try WatchlistArchive.decoded(from: archive.encoded()), archive)
        var oldClaim = archive; oldClaim.version = 10
        XCTAssertThrowsError(try WatchlistArchive.decoded(from: oldClaim.encoded()))
    }
}
