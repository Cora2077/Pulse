import Foundation
import XCTest
@testable import PulseCore

final class LocalBackupStoreTests: XCTestCase {
    func testDailyBackupIsOncePerLocalDateAndRoundTripsFullSnapshotPrivately() throws {
        let (support, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: support) }
        let snapshot = makeSnapshot()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 23, minute: 30))!

        let first = try XCTUnwrap(store.createDailyBackup(snapshot: snapshot, at: date, calendar: calendar))
        XCTAssertNil(try store.createDailyBackup(
            snapshot: WatchlistSyncSnapshot(items: [], groups: []),
            at: date.addingTimeInterval(15 * 60),
            calendar: calendar
        ))
        let restored = try store.readSnapshot(for: first)
        XCTAssertEqual(restored, snapshot)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.directoryURL.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let backupURL = store.directoryURL.appendingPathComponent(first.id).appendingPathExtension("json")
        let backupAttributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        XCTAssertEqual((backupAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path), [backupURL.lastPathComponent])
    }

    func testRetentionKeepsThirtyDailyAndTenManualOrPreRestoreFiles() throws {
        let (support, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: support) }
        let snapshot = makeSnapshot()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        for offset in 0...LocalBackupStore.dailyRetentionLimit {
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            _ = try store.createDailyBackup(snapshot: snapshot, at: day, calendar: calendar)
        }
        let records = try store.listBackups()
        XCTAssertEqual(records.filter { $0.kind == .daily }.count, LocalBackupStore.dailyRetentionLimit)
        XCTAssertFalse(records.contains { $0.id == "daily-2026-01-01" })

        let sameInstant = Date(timeIntervalSince1970: 1_800_000_000)
        var created: [LocalBackupRecord] = []
        for index in 0...LocalBackupStore.manualRetentionLimit {
            let kind: LocalBackupKind = index.isMultiple(of: 2) ? .manual : .preRestore
            created.append(try store.createBackup(kind: kind, snapshot: snapshot, at: sameInstant))
        }
        let afterRetention = try store.listBackups()
        let bounded = afterRetention.filter { $0.kind != .daily }
        XCTAssertEqual(bounded.count, LocalBackupStore.manualRetentionLimit)
        XCTAssertTrue(bounded.contains { $0.id == created.last?.id })
        XCTAssertFalse(bounded.contains { $0.id == created.first?.id })

        let afterClockRollback = try store.createBackup(
            kind: .preRestore, snapshot: snapshot, at: sameInstant.addingTimeInterval(-3_600)
        )
        XCTAssertEqual(try store.readSnapshot(for: afterClockRollback), snapshot)
        XCTAssertEqual(try store.listBackups().filter { $0.kind != .daily }.count, LocalBackupStore.manualRetentionLimit)
    }

    func testPreviewCountsTargetAndComparesEntriesBySymbolAndMembership() {
        let current = makeSnapshot()
        let symbol = SymbolID(market: .us, code: "TSLA")
        var target = current
        target.items[0].thesis = "Updated thesis"
        target.items.append(WatchItem(symbol: symbol, displayName: "Tesla"))
        target.groups[0].symbols.append(symbol)
        target.groups[0].manualOrder?.append(symbol)
        target.retainedHistoryItems.removeAll()

        let preview = LocalBackupPreview(current: current, target: target)
        XCTAssertTrue(preview.replacesAllData)
        XCTAssertEqual(preview.targetCounts.groups, 1)
        XCTAssertEqual(preview.targetCounts.symbols, 2)
        XCTAssertEqual(preview.targetCounts.retainedHistory, 0)
        XCTAssertEqual(preview.targetCounts.transactions, 1)
        XCTAssertEqual(preview.targetCounts.plans, 1)
        XCTAssertEqual(preview.targetCounts.drawings, 1)
        XCTAssertEqual(preview.entryChanges, LocalBackupEntryChanges(added: 1, removed: 1, changed: 1))
        XCTAssertTrue(preview.stillReviews(current: current, target: target))

        var changedAfterReview = current
        changedAfterReview.items[0].thesis = "Changed while confirmation was open"
        XCTAssertFalse(preview.stillReviews(current: changedAfterReview, target: target))
        XCTAssertFalse(preview.stillReviews(current: current, target: current))
    }

    func testUnsupportedVersionAndMalformedMembershipAreRejectedBeforeRestore() throws {
        let (support, store) = try makeStore()
        defer { try? FileManager.default.removeItem(at: support) }
        let record = try store.createBackup(kind: .manual, snapshot: makeSnapshot())
        let fileURL = store.directoryURL.appendingPathComponent(record.id).appendingPathExtension("json")

        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        envelope["version"] = 999
        try JSONSerialization.data(withJSONObject: envelope).write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.readSnapshot(for: record))

        var malformed = makeSnapshot()
        malformed.groups[0].symbols = [SymbolID(market: .us, code: "MISSING")]
        let data = try WatchlistSyncWireCodec.encode(deviceID: "pulse-local-backup", snapshot: malformed)
        try data.write(to: fileURL, options: .atomic)
        XCTAssertThrowsError(try store.readSnapshot(for: record))
    }

    func testSnapshotValidationRejectsBadTransactionAndGroupOrdering() {
        var snapshot = makeSnapshot()
        snapshot.items[0].transactions[0].price = .infinity
        XCTAssertThrowsError(try LocalBackupStore.validateSnapshot(snapshot))

        snapshot = makeSnapshot()
        snapshot.groups[0].pinnedSymbols.append(snapshot.groups[0].symbols[0])
        XCTAssertThrowsError(try LocalBackupStore.validateSnapshot(snapshot))
    }

    private func makeStore() throws -> (URL, LocalBackupStore) {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseLocalBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return (support, LocalBackupStore(bundleIdentifier: "app.pulse.test", applicationSupportURL: support))
    }

    private func makeSnapshot() -> WatchlistSyncSnapshot {
        let active = SymbolID(market: .us, code: "AAPL")
        let retained = SymbolID(market: .hk, code: "700")
        let date = Date(timeIntervalSince1970: 1_800_000_000.125)
        let transaction = PositionTransaction(
            kind: .buy,
            price: 0,
            quantity: 3,
            date: date,
            createdAt: date,
            review: PositionTransactionReview(followedPlan: false, retrospective: "Keep the opening size smaller")
        )
        let drawing = ChartDrawing(
            geometry: .horizontal(price: 240),
            createdAt: date,
            updatedAt: date
        )
        let item = WatchItem(
            symbol: active,
            displayName: "Apple",
            addedAt: date,
            lots: [CostLot(price: 10, quantity: -2, date: date)],
            transactions: [transaction],
            thesis: "Long-term",
            plans: [TradePlan(kind: .buy, price: 210, quantity: 2, createdAt: date, updatedAt: date)],
            drawings: [drawing]
        )
        let retainedItem = WatchItem(
            symbol: retained,
            displayName: "Tencent Holdings",
            addedAt: date,
            transactions: [PositionTransaction(kind: .adjustment, price: 8, quantity: 0, date: date, createdAt: date)]
        )
        let group = WatchlistGroup(
            name: "Core",
            symbols: [active],
            manualOrder: [active],
            pinnedSymbols: [active]
        )
        return WatchlistSyncSnapshot(items: [item], groups: [group], retainedHistoryItems: [retainedItem])
    }
}
