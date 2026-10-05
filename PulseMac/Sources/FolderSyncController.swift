import AppKit
import Foundation
import Observation
import PulseCore

private typealias FolderSyncPeerFile = WatchlistSyncWireCodec.File

private struct FolderSyncPeerRead: Sendable {
    var deviceID: String
    var file: FolderSyncPeerFile?
    var error: String?
    var awaitingDownload: Bool
    var requiresNewerVersion: Bool = false
}

private struct FolderSyncReadBatch: Sendable {
    var folderPath: String
    var folderIdentity: String
    var peers: [FolderSyncPeerRead]
    var ownFileExists: Bool
    var ownFileAwaitingDownload: Bool
    var renewedBookmark: Data?
}

private struct FolderSyncConflictBackup: Codable {
    var createdAt: Date
    var localDeviceID: String
    var peerDeviceID: String
    var localSnapshot: WatchlistSyncSnapshot
    var peerSnapshot: WatchlistSyncSnapshot
}

/// File coordination and security-scoped I/O stay off the main actor because
/// cloud-file providers can take time to download or upload a file.
private enum FolderSyncFileIO {
    /// iCloud keeps a file it has not downloaded yet as a hidden placeholder
    /// named `.NAME.icloud`. The listing therefore has to include hidden files,
    /// and a placeholder has to be mapped back to the real name the file
    /// provider materializes before it can be read.
    private static let placeholderSuffix = ".icloud"

    static func readPeers(bookmark: Data, ownDeviceID: String) throws -> FolderSyncReadBatch {
        try withFolder(bookmark: bookmark) { folder, renewedBookmark in
            let urls = try coordinatedContents(of: folder)
            let folderIdentity = identity(of: folder)
            var ownFileExists = false
            var ownFileAwaitingDownload = false
            var peers: [FolderSyncPeerRead] = []

            for url in urls {
                guard let peerURL = peerFileURL(for: url, in: folder),
                      let peerID = deviceID(from: peerURL) else { continue }
                let isAwaitingDownload = url.lastPathComponent.hasSuffix(placeholderSuffix)
                if peerID == ownDeviceID {
                    ownFileExists = true
                    if isAwaitingDownload {
                        requestDownload(of: peerURL)
                        ownFileAwaitingDownload = true
                    }
                    continue
                }
                // A peer file the provider has not fetched yet is not a read
                // failure the user can act on: ask for it, then let a later
                // pass pick it up once the download lands.
                if isAwaitingDownload { requestDownload(of: peerURL) }
                do {
                    let data = try coordinatedRead(peerURL)
                    let peerFile = try decodePeerFile(data, expectedDeviceID: peerID)
                    peers.append(FolderSyncPeerRead(
                        deviceID: peerID,
                        file: peerFile,
                        error: nil,
                        awaitingDownload: false
                    ))
                } catch {
                    peers.append(FolderSyncPeerRead(
                        deviceID: peerID,
                        file: nil,
                        error: isAwaitingDownload ? nil : error.localizedDescription,
                        awaitingDownload: isAwaitingDownload,
                        requiresNewerVersion: (error as? FolderSyncError) == .newerVersion
                    ))
                }
            }
            return FolderSyncReadBatch(
                folderPath: folder.path,
                folderIdentity: folderIdentity,
                peers: peers,
                ownFileExists: ownFileExists,
                ownFileAwaitingDownload: ownFileAwaitingDownload,
                renewedBookmark: renewedBookmark
            )
        }
    }

    static func readPeer(bookmark: Data, peerID: String) throws -> (FolderSyncPeerFile, Data?) {
        try withFolder(bookmark: bookmark) { folder, renewedBookmark in
            let url = folder.appendingPathComponent("Pulse-sync-\(peerID).json", isDirectory: false)
            requestDownload(of: url)
            return (try decodePeerFile(coordinatedRead(url), expectedDeviceID: peerID), renewedBookmark)
        }
    }

    /// The real file name behind a listing entry. Non-Pulse files, and files a
    /// provider renamed on its own (iCloud appends " 2" to a conflict copy),
    /// return nil and are ignored.
    private static func peerFileURL(for url: URL, in folder: URL) -> URL? {
        var name = url.lastPathComponent
        if name.hasSuffix(placeholderSuffix) {
            if name.hasPrefix(".") { name.removeFirst() }
            name = String(name.dropLast(placeholderSuffix.count))
        }
        guard name.hasPrefix("Pulse-sync-"),
              (name as NSString).pathExtension == "json" else { return nil }
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// A no-op unless the file provider still holds the content. The download
    /// runs in the background, so this pass may still fail to read the file.
    private static func requestDownload(of url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    static func writeOwnFile(bookmark: Data, deviceID: String, snapshot: WatchlistSyncSnapshot) throws -> (String, Data?) {
        try withFolder(bookmark: bookmark) { folder, renewedBookmark in
            let url = folder.appendingPathComponent("Pulse-sync-\(deviceID).json", isDirectory: false)
            let ownPlaceholderExists = try coordinatedContents(of: folder).contains { listedURL in
                guard listedURL.lastPathComponent.hasSuffix(placeholderSuffix),
                      let listedPeerURL = peerFileURL(for: listedURL, in: folder)
                else { return false }
                return self.deviceID(from: listedPeerURL) == deviceID
            }
            if ownPlaceholderExists {
                requestDownload(of: url)
                throw FolderSyncError.ownFilePendingDownload
            }
            let data = try WatchlistSyncWireCodec.encode(deviceID: deviceID, snapshot: snapshot)
            try coordinatedWrite(data, to: url)
            return (folder.path, renewedBookmark)
        }
    }

    private static func withFolder<T>(bookmark: Data, _ body: (URL, Data?) throws -> T) throws -> T {
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ).standardizedFileURL
        guard folder.startAccessingSecurityScopedResource() else { throw FolderSyncError.accessDenied }
        defer { folder.stopAccessingSecurityScopedResource() }
        guard let isDirectory = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
              isDirectory else { throw FolderSyncError.folderUnavailable }
        let renewedBookmark = stale
            ? try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return try body(folder, renewedBookmark)
    }

    static func folderIdentity(at folder: URL) -> String {
        let folder = folder.standardizedFileURL
        let startedAccess = folder.startAccessingSecurityScopedResource()
        defer { if startedAccess { folder.stopAccessingSecurityScopedResource() } }
        return identity(of: folder)
    }

    private static func identity(of folder: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path),
              let volume = attributes[.systemNumber],
              let inode = attributes[.systemFileNumber] else {
            return "path:\(folder.standardizedFileURL.path)"
        }
        return "file:\(volume):\(inode)"
    }

    private static func deviceID(from fileURL: URL) -> String? {
        let prefix = "Pulse-sync-"
        let name = fileURL.deletingPathExtension().lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        let rawID = String(name.dropFirst(prefix.count)).lowercased()
        return UUID(uuidString: rawID)?.uuidString.lowercased()
    }

    private static func decodePeerFile(_ data: Data, expectedDeviceID: String) throws -> FolderSyncPeerFile {
        do {
            return try WatchlistSyncWireCodec.decode(data, expectedDeviceID: expectedDeviceID)
        } catch WatchlistSyncWireCodec.CodecError.unsupportedVersion(let version)
            where version > WatchlistSyncWireCodec.currentVersion {
            throw FolderSyncError.newerVersion
        } catch {
            throw FolderSyncError.invalidPeerFile
        }
    }

    private static func coordinatedContents(of folder: URL) throws -> [URL] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<[URL], Error>?
        coordinator.coordinate(readingItemAt: folder, options: [], error: &coordinationError) { url in
            result = Result {
                // Hidden files are kept on purpose: an iCloud peer file that has
                // not been downloaded yet is listed as a `.NAME.icloud` entry.
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolderSyncError.coordinationFailed }
        return try result.get()
    }

    private static func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe]) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolderSyncError.coordinationFailed }
        return try result.get()
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result {
                // An application downgrade must not replace its restore file
                // while silently discarding fields it cannot understand.
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existing = try Data(contentsOf: coordinatedURL)
                    _ = try decodePeerFile(existing, expectedDeviceID: deviceID(from: coordinatedURL) ?? "")
                }
                try data.write(to: coordinatedURL, options: .atomic)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw FolderSyncError.coordinationFailed }
        try result.get()
    }
}

@MainActor
@Observable
final class FolderSyncController {
    struct ConflictSummary: Identifiable {
        let id: String
        let count: Int
        let examples: [String]
    }

    struct PositionAllocationConflictSummary: Identifiable {
        let peerID: String
        let symbol: SymbolID
        let local: PositionAllocation?
        let remote: PositionAllocation?
        var id: String { "\(peerID):\(symbol.description)" }
    }

    private struct PendingConflict {
        var remote: WatchlistSyncSnapshot
        var conflicts: [WatchlistSyncMerge.TransactionConflict]
        var positionAllocationConflicts: [WatchlistSyncMerge.PositionAllocationConflict]
        var brokerageConflict: WatchlistSyncMerge.BrokerageConflict?
    }

    private static let folderBookmarkKey = "pulse.folderSync.bookmark.v1"
    private static let folderScopeIDKey = "pulse.folderSync.folderScopeID.v1"
    private static let deviceIDKey = "pulse.folderSync.deviceID.v1"
    private static let peerBasesKey = "pulse.folderSync.peerBases.v1"
    private static let conflictBackupsKey = "pulse.folderSync.conflictBackups.v1"
    private static let folderScopesKey = "pulse.folderSync.folderScopes.v1"
    private static let folderScopePathsKey = "pulse.folderSync.folderScopePaths.v1"
    private static let legacyBaselineScopesKey = "pulse.folderSync.legacyBaselineScopes.v1"
    private static let pollInterval: UInt64 = 60_000_000_000

    private let store: WatchlistStore
    private let defaults: UserDefaults
    private let deviceID: String
    private(set) var selectedFolderPath: String?
    private(set) var selectedFolderScopeID: String?
    private(set) var isSyncing = false
    private(set) var lastReadAt: Date?
    private(set) var lastWriteAt: Date?
    private(set) var lastError: String?
    private(set) var conflictSummaries: [ConflictSummary] = []
    private(set) var positionAllocationConflicts: [PositionAllocationConflictSummary] = []

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var localChangeGeneration = 0
    @ObservationIgnored private var localWritePending = true
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var pendingConflicts: [String: PendingConflict] = [:]
    @ObservationIgnored private var folderSelectionGeneration = 0

    init(store: WatchlistStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults

        let savedID = defaults.string(forKey: Self.deviceIDKey).flatMap(UUID.init(uuidString:))
        let id = savedID ?? UUID()
        deviceID = id.uuidString.lowercased()
        if savedID == nil { defaults.set(deviceID, forKey: Self.deviceIDKey) }
        if let folder = Self.resolveBookmark(defaults.data(forKey: Self.folderBookmarkKey))?.standardizedFileURL {
            selectedFolderPath = folder.path
            let identity = FolderSyncFileIO.folderIdentity(at: folder)
            let savedScopeID = defaults.string(forKey: Self.folderScopeIDKey)
            let scopeID = savedScopeID ?? Self.folderScopeID(for: identity, defaults: defaults)
            if savedScopeID == nil { Self.markLegacyBaselineMigration(for: scopeID, defaults: defaults) }
            defaults.set(scopeID, forKey: Self.folderScopeIDKey)
            selectedFolderScopeID = scopeID
            Self.associateFolderIdentity(identity, with: scopeID, defaults: defaults)
        }

        store.onLocalSyncChange = { [weak self] _ in
            guard let self, !self.applyingRemote else { return }
            self.localChangeGeneration += 1
            self.localWritePending = true
            self.debounceTask?.cancel()
            self.debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        }
    }

    var isConfigured: Bool { defaults.data(forKey: Self.folderBookmarkKey) != nil }

    func start() {
        guard pollTask == nil else { return }
        if isConfigured { syncNow() }
        startPolling()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = PulseLocalization.localizedString("sync.choose.title")
        panel.prompt = PulseLocalization.localizedString("sync.choose.button")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Self.folderBookmarkKey)
            let selectedURL = url.standardizedFileURL
            folderSelectionGeneration += 1
            selectedFolderPath = selectedURL.path
            let scopeID = Self.folderScopeID(
                for: FolderSyncFileIO.folderIdentity(at: selectedURL),
                defaults: defaults
            )
            defaults.set(scopeID, forKey: Self.folderScopeIDKey)
            selectedFolderScopeID = scopeID
            lastError = nil
            lastReadAt = nil
            lastWriteAt = nil
            pendingConflicts.removeAll()
            conflictSummaries = []
            positionAllocationConflicts = []
            localWritePending = true
            if pollTask == nil { startPolling() }
            syncNow()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disableSync() {
        folderSelectionGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        debounceTask?.cancel()
        defaults.removeObject(forKey: Self.folderBookmarkKey)
        defaults.removeObject(forKey: Self.folderScopeIDKey)
        selectedFolderPath = nil
        selectedFolderScopeID = nil
        pendingConflicts.removeAll()
        conflictSummaries = []
        positionAllocationConflicts = []
        lastError = nil
        lastReadAt = nil
        lastWriteAt = nil
        rerunRequested = false
        // Keep peer files and local baselines in case the user opts in again.
    }

    func syncNow() {
        guard isConfigured else { return }
        guard !isSyncing else {
            rerunRequested = true
            return
        }
        isSyncing = true
        rerunRequested = false
        lastError = nil
        let generation = folderSelectionGeneration
        Task { @MainActor [weak self] in await self?.performSync(generation: generation) }
    }

    func resolveConflicts(peerID: String, choosingRemote: Bool) {
        guard isConfigured, let pending = pendingConflicts[peerID] else { return }
        guard !isSyncing else { return }
        isSyncing = true
        lastError = nil
        let generation = folderSelectionGeneration
        Task { @MainActor [weak self] in
            await self?.performResolution(
                peerID: peerID,
                expected: pending,
                choosingRemote: choosingRemote,
                generation: generation
            )
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        }
    }

    private func performSync(generation: Int) async {
        defer { finishSync() }
        guard generation == folderSelectionGeneration else { return }
        guard let bookmark = defaults.data(forKey: Self.folderBookmarkKey) else { return }

        do {
            let ownDeviceID = deviceID
            let batch = try await Task.detached(priority: .utility) {
                try FolderSyncFileIO.readPeers(bookmark: bookmark, ownDeviceID: ownDeviceID)
            }.value
            guard generation == folderSelectionGeneration else { return }
            guard let folderScopeID = selectedFolderScopeID else { return }
            Self.associateFolderIdentity(batch.folderIdentity, with: folderScopeID, defaults: defaults)
            let previousFolderPath = Self.folderScopePath(for: folderScopeID, defaults: defaults)
                ?? selectedFolderPath
            if Self.needsLegacyBaselineMigration(for: folderScopeID, defaults: defaults) {
                migratePeerBases(
                    oldPaths: [previousFolderPath, batch.folderPath].compactMap { $0 },
                    folderScopeID: folderScopeID
                )
                Self.clearLegacyBaselineMigration(for: folderScopeID, defaults: defaults)
            }
            Self.rememberFolderScopePath(batch.folderPath, scopeID: folderScopeID, defaults: defaults)
            selectedFolderPath = batch.folderPath
            selectedFolderScopeID = folderScopeID
            if let renewed = batch.renewedBookmark { defaults.set(renewed, forKey: Self.folderBookmarkKey) }

            // This Mac's own file is also its restore point. Let the provider
            // finish downloading it before any sync pass can replace it.
            if batch.ownFileAwaitingDownload {
                lastError = FolderSyncError.ownFilePendingDownload.localizedDescription
                return
            }
            if batch.peers.contains(where: \.requiresNewerVersion) {
                lastError = FolderSyncError.newerVersion.localizedDescription
                return
            }

            var conflictFreePeers = Set<String>()
            let listedPeerIDs = Set(batch.peers.map(\.deviceID))
            for peer in batch.peers {
                guard let peerFile = peer.file else {
                    if peer.awaitingDownload { continue }
                    pendingConflicts.removeValue(forKey: peer.deviceID)
                    if let error = peer.error { lastError = error }
                    continue
                }
                lastReadAt = .now
                let baseline = loadPeerBase(folderScopeID: folderScopeID, peerID: peer.deviceID)
                    ?? Self.emptySnapshot
                if peerFile.snapshot == baseline {
                    pendingConflicts.removeValue(forKey: peer.deviceID)
                    continue
                }
                let local = store.syncSnapshot()
                let result = WatchlistSyncMerge.merge(base: baseline, local: local, remote: peerFile.snapshot)
                guard result.isConflictFree else {
                    pendingConflicts[peer.deviceID] = PendingConflict(
                        remote: peerFile.snapshot,
                        conflicts: result.conflicts,
                        positionAllocationConflicts: result.positionAllocationConflicts,
                        brokerageConflict: result.brokerageConflict
                    )
                    continue
                }

                conflictFreePeers.insert(peer.deviceID)
                pendingConflicts.removeValue(forKey: peer.deviceID)
                applyingRemote = true
                _ = store.applySyncSnapshot(result.snapshot)
                applyingRemote = false
                if result.snapshot != local { localWritePending = true }
                // Only a conflict-free result that has been applied advances this peer's base.
                savePeerBase(peerFile.snapshot, folderScopeID: folderScopeID, peerID: peer.deviceID)
            }

            for stalePeerID in pendingConflicts.keys.filter({ !listedPeerIDs.contains($0) }) {
                pendingConflicts.removeValue(forKey: stalePeerID)
            }
            for peerID in conflictFreePeers { pendingConflicts.removeValue(forKey: peerID) }
            refreshConflictSummaries()

            let shouldWrite = localWritePending || !batch.ownFileExists
            guard shouldWrite else { return }
            guard generation == folderSelectionGeneration else { return }
            let generationAtWriteStart = localChangeGeneration
            let currentSnapshot = store.syncSnapshot()
            let writeBookmark = defaults.data(forKey: Self.folderBookmarkKey) ?? bookmark
            let (path, renewedBookmark) = try await Task.detached(priority: .utility) {
                try FolderSyncFileIO.writeOwnFile(
                    bookmark: writeBookmark,
                    deviceID: ownDeviceID,
                    snapshot: currentSnapshot
                )
            }.value
            guard generation == folderSelectionGeneration else { return }
            selectedFolderPath = path
            if let renewedBookmark { defaults.set(renewedBookmark, forKey: Self.folderBookmarkKey) }
            lastWriteAt = .now
            if generationAtWriteStart == localChangeGeneration { localWritePending = false }
        } catch {
            if generation == folderSelectionGeneration {
                applyingRemote = false
                lastError = error.localizedDescription
            }
        }
    }

    private func performResolution(
        peerID: String,
        expected: PendingConflict,
        choosingRemote: Bool,
        generation: Int
    ) async {
        defer { finishSync() }
        guard generation == folderSelectionGeneration,
              let folderScopeID = selectedFolderScopeID,
              let bookmark = defaults.data(forKey: Self.folderBookmarkKey) else { return }

        do {
            // Publish the local side to this Mac's own file before resolving. The
            // peer's file remains untouched, so both source snapshots stay available.
            let localBefore = store.syncSnapshot()
            let ownDeviceID = deviceID
            let (_, renewedAfterWrite) = try await Task.detached(priority: .utility) {
                try FolderSyncFileIO.writeOwnFile(bookmark: bookmark, deviceID: ownDeviceID, snapshot: localBefore)
            }.value
            guard generation == folderSelectionGeneration else { return }
            if let renewedAfterWrite { defaults.set(renewedAfterWrite, forKey: Self.folderBookmarkKey) }
            lastWriteAt = .now

            let readBookmark = defaults.data(forKey: Self.folderBookmarkKey) ?? bookmark
            let (freshPeerFile, renewedAfterRead) = try await Task.detached(priority: .utility) {
                try FolderSyncFileIO.readPeer(
                    bookmark: readBookmark,
                    peerID: peerID
                )
            }.value
            guard generation == folderSelectionGeneration else { return }
            if let renewedAfterRead { defaults.set(renewedAfterRead, forKey: Self.folderBookmarkKey) }
            guard freshPeerFile.snapshot == expected.remote else {
                lastError = PulseLocalization.localizedString("sync.conflict.changed")
                rerunRequested = true
                return
            }

            let local = store.syncSnapshot()
            let baseline = loadPeerBase(folderScopeID: folderScopeID, peerID: peerID) ?? Self.emptySnapshot
            let latest = WatchlistSyncMerge.merge(base: baseline, local: local, remote: freshPeerFile.snapshot)
            if latest.isConflictFree {
                applyingRemote = true
                _ = store.applySyncSnapshot(latest.snapshot)
                applyingRemote = false
                localChangeGeneration += 1
                localWritePending = true
                savePeerBase(freshPeerFile.snapshot, folderScopeID: folderScopeID, peerID: peerID)
                pendingConflicts.removeValue(forKey: peerID)
                refreshConflictSummaries()
                lastError = nil
                rerunRequested = true
                return
            }
            guard latest.conflicts == expected.conflicts,
                  latest.positionAllocationConflicts == expected.positionAllocationConflicts,
                  latest.brokerageConflict == expected.brokerageConflict else {
                pendingConflicts[peerID] = PendingConflict(
                    remote: freshPeerFile.snapshot, conflicts: latest.conflicts,
                    positionAllocationConflicts: latest.positionAllocationConflicts,
                    brokerageConflict: latest.brokerageConflict
                )
                refreshConflictSummaries()
                lastError = PulseLocalization.localizedString("sync.conflict.changed")
                return
            }
            guard saveConflictBackup(local: local, remote: freshPeerFile.snapshot, peerID: peerID) else {
                throw FolderSyncError.conflictBackupFailed
            }
            let resolution: WatchlistSyncMerge.ConflictResolution = choosingRemote ? .remote : .local
            let resolved = WatchlistSyncMerge.resolve(latest, choosing: resolution)
            applyingRemote = true
            _ = store.applySyncSnapshot(resolved)
            applyingRemote = false
            localChangeGeneration += 1
            localWritePending = true
            savePeerBase(freshPeerFile.snapshot, folderScopeID: folderScopeID, peerID: peerID)
            pendingConflicts.removeValue(forKey: peerID)
            refreshConflictSummaries()
            lastError = nil
            rerunRequested = true
        } catch {
            if generation == folderSelectionGeneration {
                applyingRemote = false
                lastError = error.localizedDescription
            }
        }
    }

    private func finishSync() {
        isSyncing = false
        if rerunRequested {
            rerunRequested = false
            Task { @MainActor [weak self] in self?.syncNow() }
        }
    }

    private func refreshConflictSummaries() {
        positionAllocationConflicts = pendingConflicts.keys.sorted().flatMap { peerID in
            (pendingConflicts[peerID]?.positionAllocationConflicts ?? []).map {
                PositionAllocationConflictSummary(peerID: peerID, symbol: $0.symbol, local: $0.local, remote: $0.remote)
            }
        }
        conflictSummaries = pendingConflicts.keys.sorted().compactMap { peerID in
            guard let conflict = pendingConflicts[peerID] else { return nil }
            let accountExamples = conflict.brokerageConflict == nil ? [] : ["证券账号账本或资金设置冲突 · 选择将保留所选设备的全部账号数据（含现金、预算、板块上限）"]
            let examples = accountExamples + conflict.conflicts.prefix(3).map {
                "\($0.symbol.displayCode) · \($0.transactionID.uuidString.prefix(8))"
            } + conflict.positionAllocationConflicts.prefix(3).map { "\($0.symbol.displayCode) · 仓位分账" }
            return ConflictSummary(
                id: peerID, count: conflict.conflicts.count + conflict.positionAllocationConflicts.count + (conflict.brokerageConflict == nil ? 0 : 1),
                examples: Array(examples.prefix(3))
            )
        }
    }

    private static var emptySnapshot: WatchlistSyncSnapshot {
        WatchlistSyncSnapshot(items: [], groups: [], retainedHistoryItems: [])
    }

    private static func resolveBookmark(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func loadPeerBase(folderScopeID: String, peerID: String) -> WatchlistSyncSnapshot? {
        guard let data = defaults.data(forKey: Self.peerBasesKey),
              let values = try? JSONDecoder().decode([String: WatchlistSyncSnapshot].self, from: data)
        else { return nil }
        return values[Self.peerBaseKey(folderScopeID: folderScopeID, peerID: peerID)]
    }

    private func savePeerBase(_ snapshot: WatchlistSyncSnapshot, folderScopeID: String, peerID: String) {
        var values = defaults.data(forKey: Self.peerBasesKey)
            .flatMap { try? JSONDecoder().decode([String: WatchlistSyncSnapshot].self, from: $0) } ?? [:]
        values[Self.peerBaseKey(folderScopeID: folderScopeID, peerID: peerID)] = snapshot
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: Self.peerBasesKey) }
    }

    private func migratePeerBases(oldPaths: [String], folderScopeID: String) {
        guard var values = defaults.data(forKey: Self.peerBasesKey)
            .flatMap({ try? JSONDecoder().decode([String: WatchlistSyncSnapshot].self, from: $0) }) else { return }
        var changed = false
        for oldPath in Set(oldPaths) {
            let prefix = oldPath + "\u{1f}"
            for oldKey in values.keys.filter({ $0.hasPrefix(prefix) }) {
                guard let snapshot = values[oldKey] else { continue }
                let peerID = String(oldKey.dropFirst(prefix.count))
                let newKey = Self.peerBaseKey(folderScopeID: folderScopeID, peerID: peerID)
                if values[newKey] == nil { values[newKey] = snapshot }
                values.removeValue(forKey: oldKey)
                changed = true
            }
        }
        if changed, let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: Self.peerBasesKey)
        }
    }

    private func saveConflictBackup(local: WatchlistSyncSnapshot, remote: WatchlistSyncSnapshot, peerID: String) -> Bool {
        let backup = FolderSyncConflictBackup(
            createdAt: .now,
            localDeviceID: deviceID,
            peerDeviceID: peerID,
            localSnapshot: local,
            peerSnapshot: remote
        )
        guard let backupData = try? JSONEncoder().encode(backup) else { return false }
        var backups = defaults.data(forKey: Self.conflictBackupsKey)
            .flatMap { try? JSONDecoder().decode([Data].self, from: $0) } ?? []
        backups.append(backupData)
        backups = Array(backups.suffix(8))
        guard let data = try? JSONEncoder().encode(backups) else { return false }
        defaults.set(data, forKey: Self.conflictBackupsKey)
        return true
    }

    private static func folderScopeID(for identity: String, defaults: UserDefaults) -> String {
        var scopes = defaults.dictionary(forKey: Self.folderScopesKey) as? [String: String] ?? [:]
        if let existing = scopes[identity] { return existing }
        let scopeID = UUID().uuidString.lowercased()
        scopes[identity] = scopeID
        defaults.set(scopes, forKey: Self.folderScopesKey)
        return scopeID
    }

    private static func associateFolderIdentity(_ identity: String, with scopeID: String, defaults: UserDefaults) {
        var scopes = defaults.dictionary(forKey: Self.folderScopesKey) as? [String: String] ?? [:]
        if scopes[identity] == scopeID { return }
        scopes[identity] = scopeID
        defaults.set(scopes, forKey: Self.folderScopesKey)
    }

    private static func needsLegacyBaselineMigration(for scopeID: String, defaults: UserDefaults) -> Bool {
        (defaults.stringArray(forKey: Self.legacyBaselineScopesKey) ?? []).contains(scopeID)
    }

    private static func markLegacyBaselineMigration(for scopeID: String, defaults: UserDefaults) {
        var pending = Set(defaults.stringArray(forKey: Self.legacyBaselineScopesKey) ?? [])
        pending.insert(scopeID)
        defaults.set(pending.sorted(), forKey: Self.legacyBaselineScopesKey)
    }

    private static func clearLegacyBaselineMigration(for scopeID: String, defaults: UserDefaults) {
        let pending = (defaults.stringArray(forKey: Self.legacyBaselineScopesKey) ?? [])
            .filter { $0 != scopeID }
        defaults.set(pending, forKey: Self.legacyBaselineScopesKey)
    }

    private static func folderScopePath(for scopeID: String, defaults: UserDefaults) -> String? {
        (defaults.dictionary(forKey: Self.folderScopePathsKey) as? [String: String])?[scopeID]
    }

    private static func rememberFolderScopePath(_ path: String, scopeID: String, defaults: UserDefaults) {
        var paths = defaults.dictionary(forKey: Self.folderScopePathsKey) as? [String: String] ?? [:]
        paths[scopeID] = path
        defaults.set(paths, forKey: Self.folderScopePathsKey)
    }

    private static func peerBaseKey(folderScopeID: String, peerID: String) -> String {
        "scope:\(folderScopeID)\u{1f}\(peerID)"
    }
}

private enum FolderSyncError: LocalizedError, Equatable {
    case accessDenied
    case folderUnavailable
    case invalidPeerFile
    case coordinationFailed
    case conflictBackupFailed
    case ownFilePendingDownload
    case newerVersion

    var errorDescription: String? {
        switch self {
        case .accessDenied: PulseLocalization.localizedString("sync.error.accessDenied")
        case .folderUnavailable: PulseLocalization.localizedString("sync.error.folderUnavailable")
        case .invalidPeerFile: PulseLocalization.localizedString("sync.error.invalidFile")
        case .coordinationFailed: PulseLocalization.localizedString("sync.error.coordination")
        case .conflictBackupFailed: PulseLocalization.localizedString("sync.error.backupFailed")
        case .ownFilePendingDownload: PulseLocalization.localizedString("sync.error.ownFilePendingDownload")
        case .newerVersion: PulseLocalization.localizedString("sync.error.newerVersion")
        }
    }
}
