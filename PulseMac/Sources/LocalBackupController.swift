import Foundation
import Observation
import PulseCore

@MainActor
@Observable
final class LocalBackupController {
    private static let enabledKey = "pulse.localBackups.enabled.v1"
    private static let checkInterval: UInt64 = 15 * 60 * 1_000_000_000

    let isAvailable: Bool
    private(set) var isEnabled: Bool
    private(set) var backups: [LocalBackupRecord] = []
    private(set) var lastError: String?
    private(set) var lastBackupAt: Date?

    @ObservationIgnored private let watchlist: WatchlistStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backupStore: LocalBackupStore
    @ObservationIgnored private let applySnapshot: (WatchlistSyncSnapshot) throws -> Void
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var listingError: String?

    init(
        store: WatchlistStore,
        backupStore: LocalBackupStore = LocalBackupStore(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.pulse.mac"
        ),
        defaults: UserDefaults = .standard,
        isAvailable: Bool = true,
        applySnapshot: @escaping (WatchlistSyncSnapshot) throws -> Void
    ) {
        self.watchlist = store
        self.backupStore = backupStore
        self.defaults = defaults
        self.isAvailable = isAvailable
        self.isEnabled = isAvailable && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true)
        self.applySnapshot = applySnapshot
        if isAvailable { refreshBackups() }
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    func refreshBackups() {
        guard isAvailable else {
            backups = []
            return
        }
        do {
            backups = try backupStore.listBackups()
            lastBackupAt = backups.first?.createdAt
            // Opening settings must not dismiss a failed backup or restore.
            if let listingError, lastError == listingError { lastError = nil }
            listingError = nil
        } catch {
            listingError = errorMessage(error)
            lastError = listingError
        }
    }

    @discardableResult
    func createManualBackup() -> Bool {
        guard isAvailable else { return false }
        do {
            let snapshot = watchlist.syncSnapshot()
            let record = try backupStore.createBackup(kind: .manual, snapshot: snapshot)
            guard try backupStore.readSnapshot(for: record) == snapshot else {
                throw NSError(domain: "PulseBackup", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "备份完整性校验失败。"
                ])
            }
            lastBackupAt = record.createdAt
            lastError = nil
            refreshBackups()
            return true
        } catch {
            lastError = errorMessage(error)
            return false
        }
    }

    func preview(for record: LocalBackupRecord) throws -> LocalBackupPreview {
        guard isAvailable else { throw ControllerError.unavailable }
        do {
            let target = try backupStore.readSnapshot(for: record)
            lastError = nil
            return LocalBackupPreview(current: watchlist.syncSnapshot(), target: target)
        } catch {
            lastError = errorMessage(error)
            throw error
        }
    }

    /// Applies only the exact current snapshot the user reviewed. A changed
    /// watchlist refreshes the preview and requires another explicit confirmation.
    @discardableResult
    func restore(_ record: LocalBackupRecord, afterReviewing preview: LocalBackupPreview) -> Bool {
        guard isAvailable else { return false }
        do {
            let target = try backupStore.readSnapshot(for: record)
            let current = watchlist.syncSnapshot()
            guard preview.stillReviews(current: current, target: target) else {
                lastError = PulseLocalization.currentLanguageIdentifier.hasPrefix("zh")
                    ? "预览后自选数据已变化，请重新选择备份并核对预览后再确认。"
                    : "Your watchlist changed after this preview. Select the backup again, review the updated counts, and confirm."
                return false
            }

            // Keep an independent pre-restore file before the destructive callback can run.
            let preRestore = try backupStore.createBackup(kind: .preRestore, snapshot: current)
            guard try backupStore.readSnapshot(for: preRestore) == current else {
                throw NSError(domain: "PulseBackup", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "无法确认恢复前备份完整，已停止恢复。"
                ])
            }
            try applySnapshot(target)
            lastBackupAt = preRestore.createdAt
            lastError = nil
            refreshBackups()
            return true
        } catch {
            let message = errorMessage(error)
            refreshBackups()
            lastError = message
            return false
        }
    }

    private func start() {
        guard isAvailable, isEnabled, checkTask == nil else { return }
        createDailyBackupIfNeeded()
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.checkInterval)
                guard !Task.isCancelled else { return }
                self?.createDailyBackupIfNeeded()
            }
        }
    }

    private func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    private enum ControllerError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Local backups are unavailable in this preview." }
    }

    private func errorMessage(_ error: Error) -> String {
        guard PulseLocalization.currentLanguageIdentifier.hasPrefix("zh") else {
            return error.localizedDescription
        }
        if let codecError = error as? WatchlistSyncWireCodec.CodecError {
            if case .unsupportedVersion = codecError {
                return "此备份由较新版本的 FFF 创建，请更新应用后再恢复。"
            }
            return "备份文件无法通过完整性校验，请选择其他备份。"
        }
        return "本地备份操作失败：\(error.localizedDescription)"
    }

    private func createDailyBackupIfNeeded() {
        guard isAvailable, isEnabled else { return }
        do {
            let record = try backupStore.createDailyBackup(snapshot: watchlist.syncSnapshot())
            if let record {
                lastBackupAt = record.createdAt
                lastError = nil
            }
            refreshBackups()
        } catch {
            lastError = errorMessage(error)
        }
    }
}
