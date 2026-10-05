import Foundation

public enum LocalBackupKind: String, Sendable, CaseIterable {
    case daily
    case manual
    case preRestore = "pre-restore"
}

public struct LocalBackupRecord: Identifiable, Sendable, Equatable {
    /// File name without its `.json` extension.
    public let id: String
    public let kind: LocalBackupKind
    public let createdAt: Date
}

public struct LocalBackupCounts: Sendable, Equatable {
    public let groups: Int
    public let symbols: Int
    public let retainedHistory: Int
    public let transactions: Int
    public let plans: Int
    public let drawings: Int

    public init(snapshot: WatchlistSyncSnapshot) {
        let items = snapshot.allAccountItems
        groups = snapshot.groups.count + (snapshot.brokerageAccounts ?? []).reduce(0) { $0 + $1.groups.count }
        symbols = snapshot.items.count + (snapshot.brokerageAccounts ?? []).reduce(0) { $0 + $1.items.count }
        retainedHistory = snapshot.retainedHistoryItems.count + (snapshot.brokerageAccounts ?? []).reduce(0) { $0 + $1.retainedHistoryItems.count }
        transactions = items.reduce(0) { $0 + $1.transactions.count }
        plans = items.reduce(0) { $0 + $1.plans.count }
        drawings = items.reduce(0) { $0 + $1.drawings.count }
    }
}

public struct LocalBackupEntryChanges: Sendable, Equatable {
    public let added: Int
    public let removed: Int
    public let changed: Int
}

public struct LocalBackupPreview: Sendable, Equatable {
    public let targetCounts: LocalBackupCounts
    public let entryChanges: LocalBackupEntryChanges
    public let replacesAllData: Bool
    public let settingsChangedAccounts: [BrokerageAccountID]
    public let settingsPreservedAccounts: [BrokerageAccountID]
    let reviewedSnapshot: WatchlistSyncSnapshot
    let targetSnapshot: WatchlistSyncSnapshot

    public init(current: WatchlistSyncSnapshot, target: WatchlistSyncSnapshot) {
        targetCounts = LocalBackupCounts(snapshot: target)
        entryChanges = Self.compare(current: current, target: target)
        replacesAllData = true
        func settings(_ snapshot: WatchlistSyncSnapshot, _ id: BrokerageAccountID) -> BrokerageAccountSettings? {
            id == .unassigned ? snapshot.accountSettings : snapshot.brokerageAccounts?.first { $0.accountID == id }?.settings
        }
        settingsChangedAccounts = BrokerageAccountID.allCases.filter {
            settings(target, $0) != nil && settings(current, $0) != settings(target, $0)
        }
        settingsPreservedAccounts = BrokerageAccountID.allCases.filter {
            settings(target, $0) == nil && settings(current, $0) != nil
        }
        reviewedSnapshot = current
        targetSnapshot = target
    }

    public func stillReviews(current: WatchlistSyncSnapshot, target: WatchlistSyncSnapshot) -> Bool {
        current == reviewedSnapshot && target == targetSnapshot
    }

    private static func compare(
        current: WatchlistSyncSnapshot,
        target: WatchlistSyncSnapshot
    ) -> LocalBackupEntryChanges {
        struct Entry {
            let item: WatchItem
            let isRetained: Bool
            let memberships: Set<UUID>
        }

        func entries(_ snapshot: WatchlistSyncSnapshot) -> [SymbolID: Entry] {
            var memberships: [SymbolID: Set<UUID>] = [:]
            for group in snapshot.groups {
                for symbol in group.symbols { memberships[symbol, default: []].insert(group.id) }
            }
            var result = Dictionary(uniqueKeysWithValues: snapshot.items.map {
                ($0.symbol, Entry(item: $0, isRetained: false, memberships: memberships[$0.symbol] ?? []))
            })
            for item in snapshot.retainedHistoryItems {
                result[item.symbol] = Entry(
                    item: item,
                    isRetained: true,
                    memberships: memberships[item.symbol] ?? []
                )
            }
            return result
        }

        let before = entries(current)
        let after = entries(target)
        let symbols = Set(before.keys).union(after.keys)
        var added = 0
        var removed = 0
        var changed = 0
        for symbol in symbols {
            switch (before[symbol], after[symbol]) {
            case (nil, .some): added += 1
            case (.some, nil): removed += 1
            case (.some(let old), .some(let new)):
                if old.item != new.item || old.isRetained != new.isRetained || old.memberships != new.memberships {
                    changed += 1
                }
            case (nil, nil): break
            }
        }
        let oldAccounts = Dictionary(uniqueKeysWithValues: (current.brokerageAccounts ?? []).map { ($0.accountID, $0) })
        let newAccounts = Dictionary(uniqueKeysWithValues: (target.brokerageAccounts ?? []).map { ($0.accountID, $0) })
        for id in Set(oldAccounts.keys).union(newAccounts.keys) {
            let delta = compare(current: oldAccounts[id]?.flatSnapshot ?? .init(items: [], groups: []),
                                target: newAccounts[id]?.flatSnapshot ?? .init(items: [], groups: []))
            added += delta.added; removed += delta.removed; changed += delta.changed
        }
        return LocalBackupEntryChanges(added: added, removed: removed, changed: changed)
    }
}

/// Atomic, private local files containing the same full snapshot used by folder sync.
public struct LocalBackupStore: Sendable {
    public static let dailyRetentionLimit = 30
    public static let manualRetentionLimit = 10
    private static let deviceID = "pulse-local-backup"

    public let directoryURL: URL

    public init(
        bundleIdentifier: String,
        applicationSupportURL: URL? = nil
    ) {
        let support = applicationSupportURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = support
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// Writes at most one backup for the calendar's local date. An existing day's file is kept.
    @discardableResult
    public func createDailyBackup(
        snapshot: WatchlistSyncSnapshot,
        at date: Date = .now,
        calendar: Calendar = .current
    ) throws -> LocalBackupRecord? {
        guard date.timeIntervalSince1970.isFinite else { throw BackupError.invalidDate }
        try prepareDirectory()
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw BackupError.invalidDate
        }
        let id = String(format: "daily-%04d-%02d-%02d", year, month, day)
        let destination = fileURL(for: id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        try write(snapshot, to: destination, modificationDate: date)
        try pruneBackups(keeping: id)
        return LocalBackupRecord(id: id, kind: .daily, createdAt: date)
    }

    @discardableResult
    public func createBackup(
        kind: LocalBackupKind,
        snapshot: WatchlistSyncSnapshot,
        at date: Date = .now
    ) throws -> LocalBackupRecord {
        guard kind != .daily else { throw BackupError.invalidKind }
        guard date.timeIntervalSince1970.isFinite,
              abs(date.timeIntervalSince1970) < Double(Int64.max) / 1_000_000 else {
            throw BackupError.invalidDate
        }
        try prepareDirectory()
        let prefix = kind == .manual ? "manual" : "pre-restore"
        let timestamp = nextTimestamp(at: date)
        let id = "\(prefix)-\(String(format: "%016lld", timestamp))-\(UUID().uuidString.lowercased())"
        try write(snapshot, to: fileURL(for: id), modificationDate: date)
        try pruneBackups(keeping: id)
        return LocalBackupRecord(id: id, kind: kind, createdAt: date)
    }

    public func listBackups() throws -> [LocalBackupRecord] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let kind = kind(for: url.deletingPathExtension().lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let createdAt = values.contentModificationDate else { return nil }
            return LocalBackupRecord(
                id: url.deletingPathExtension().lastPathComponent,
                kind: kind,
                createdAt: createdAt
            )
        }
        .sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            let lhs = Self.creationSequence($0.id)
            let rhs = Self.creationSequence($1.id)
            return lhs == rhs ? $0.id > $1.id : lhs > rhs
        }
    }

    /// The sync wire decoder rejects unsupported versions and malformed snapshot invariants.
    public func readSnapshot(for backup: LocalBackupRecord) throws -> WatchlistSyncSnapshot {
        guard kind(for: backup.id) == backup.kind else { throw BackupError.invalidRecord }
        let data = try Data(contentsOf: fileURL(for: backup.id), options: [.mappedIfSafe])
        let snapshot = try WatchlistSyncWireCodec.decode(data, expectedDeviceID: Self.deviceID).snapshot
        try Self.validateSnapshot(snapshot)
        return snapshot
    }

    private enum BackupError: LocalizedError {
        case invalidDate
        case invalidKind
        case invalidRecord
        case invalidSnapshot(String)

        var errorDescription: String? {
            switch self {
            case .invalidDate: "The local date could not be read."
            case .invalidKind: "This backup type cannot be created manually."
            case .invalidRecord: "The selected backup file is invalid."
            case .invalidSnapshot(let reason): reason
            }
        }
    }

    private func kind(for id: String) -> LocalBackupKind? {
        guard !id.contains("/"), !id.contains("\\"), !id.contains("..") else { return nil }
        if id.range(of: #"^daily-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return .daily }
        if id.range(of: #"^manual-\d{16}-[0-9a-f-]{36}$"#, options: .regularExpression) != nil { return .manual }
        if id.range(of: #"^pre-restore-\d{16}-[0-9a-f-]{36}$"#, options: .regularExpression) != nil { return .preRestore }
        return nil
    }

    private func fileURL(for id: String) -> URL {
        directoryURL.appendingPathComponent(id, isDirectory: false).appendingPathExtension("json")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func write(_ snapshot: WatchlistSyncSnapshot, to destination: URL, modificationDate: Date) throws {
        try Self.validateSnapshot(snapshot)
        let data = try WatchlistSyncWireCodec.encode(
            deviceID: Self.deviceID,
            updatedAt: modificationDate,
            snapshot: snapshot
        )
        let staging = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }
        try data.write(to: staging, options: .atomic)
        try FileManager.default.setAttributes([
            .posixPermissions: 0o600,
            .modificationDate: modificationDate
        ], ofItemAtPath: staging.path)
        // A same-directory move publishes complete contents atomically and fails if the name exists.
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func pruneBackups(keeping newID: String) throws {
        let records = try listBackups()
        let daily = records.filter { $0.kind == .daily }.sorted {
            if $0.id == newID { return true }
            if $1.id == newID { return false }
            return $0.id > $1.id
        }
        let other = records.filter { $0.kind != .daily }
            .sorted {
                if $0.id == newID { return true }
                if $1.id == newID { return false }
                return $0.createdAt == $1.createdAt
                    ? Self.creationSequence($0.id) > Self.creationSequence($1.id)
                    : $0.createdAt > $1.createdAt
            }
        let expired = Array(daily.dropFirst(Self.dailyRetentionLimit))
            + Array(other.dropFirst(Self.manualRetentionLimit))
        for record in expired {
            try FileManager.default.removeItem(at: fileURL(for: record.id))
        }
    }

    private func nextTimestamp(at date: Date) -> Int64 {
        let requested = Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
        let latest = (try? listBackups())?.map { Self.creationSequence($0.id) }.max() ?? 0
        return max(requested, latest + 1)
    }

    private static func creationSequence(_ id: String) -> Int64 {
        let prefix = id.hasPrefix("pre-restore-") ? "pre-restore-" : "manual-"
        guard id.hasPrefix(prefix),
              let separator = id.dropFirst(prefix.count).firstIndex(of: "-"),
              let value = Int64(id.dropFirst(prefix.count)[..<separator]) else { return 0 }
        return value
    }

    public static func validateSnapshot(_ snapshot: WatchlistSyncSnapshot) throws {
        func invalid(_ reason: String) -> BackupError { .invalidSnapshot(reason) }
        guard !snapshot.groups.isEmpty else { throw invalid("The snapshot has no watchlist groups.") }
        for account in snapshot.brokerageAccounts ?? [] {
            try validateSnapshot(account.flatSnapshot)
        }

        let activeSymbols = Set(snapshot.items.map(\.symbol))
        for group in snapshot.groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("A watchlist group has no name.")
            }
            let members = Set(group.symbols)
            guard members.count == group.symbols.count, members.isSubset(of: activeSymbols) else {
                throw invalid("A watchlist group contains duplicate or missing symbols.")
            }
            guard Set(group.pinnedSymbols).count == group.pinnedSymbols.count,
                  Set(group.pinnedSymbols).isSubset(of: members) else {
                throw invalid("A watchlist group contains invalid pinned symbols.")
            }
            if let order = group.manualOrder {
                guard Set(order).count == order.count, Set(order).isSubset(of: members) else {
                    throw invalid("A watchlist group contains an invalid manual order.")
                }
            }
        }

        for item in snapshot.items + snapshot.retainedHistoryItems {
            guard item.addedAt.timeIntervalSince1970.isFinite else {
                throw invalid("A watchlist symbol has an invalid date.")
            }
            for lot in item.lots where !lot.price.isFinite || lot.price < 0
                || !lot.quantity.isFinite
                || !(lot.date?.timeIntervalSince1970.isFinite ?? true) {
                throw invalid("A position lot has invalid values.")
            }
            for transaction in item.transactions {
                let validKind: Bool
                switch transaction.kind {
                case .buy:
                    validKind = transaction.price.isFinite && transaction.price >= 0
                        && transaction.quantity.isFinite && transaction.quantity > 0
                case .sell:
                    validKind = transaction.price.isFinite && transaction.price > 0
                        && transaction.quantity.isFinite && transaction.quantity > 0
                case .adjustment:
                    validKind = transaction.price.isFinite && transaction.price >= 0
                        && transaction.quantity.isFinite
                }
                guard validKind,
                      transaction.date.timeIntervalSince1970.isFinite,
                      transaction.createdAt.timeIntervalSince1970.isFinite,
                      transaction.hasValidFee else {
                    throw invalid("A position transaction has invalid values.")
                }
            }
            for plan in item.plans where !plan.price.isFinite || plan.price <= 0
                || !plan.quantity.isFinite || plan.quantity <= 0
                || !plan.createdAt.timeIntervalSince1970.isFinite
                || !plan.updatedAt.timeIntervalSince1970.isFinite {
                throw invalid("A trade plan has invalid values.")
            }
        }
    }
}
