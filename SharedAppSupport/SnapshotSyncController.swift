import Foundation
import Observation
import PulseCore
import PulseSync

/// Shared application adapter. It serializes queue operations, not user edits:
/// the latter remain synchronously durable in WatchlistStore. Each edit freezes
/// the revision actually applied to the UI before any asynchronous work begins.
@MainActor
@Observable
final class AppSnapshotSyncController {
    private(set) var statusText = "云同步未配置 · 本机数据可用"
    private(set) var conflict: ConflictReport?
    private(set) var confirmedRevision: UUID?
    private(set) var confirmedAt: Date?
    private(set) var hasPending = false
    var onStateChanged: (() -> Void)?
    var onRemoteApplied: (() -> Void)?

    private let store: WatchlistStore
    private let coordinator: SnapshotCoordinator
    private let directory: URL
    private let configured: Bool
    private var applied: AppliedState
    private var generation = 0
    private var conflictGeneration = 0
    private var chain: Task<Void, Never>?
    private var started = false
    private enum ParentAnchor { case remote(UUID?), localOperation(UUID) }
    private var localAnchor: ParentAnchor = .remote(nil)
    private var assignedLocalRevisions: [UUID: UUID] = [:]

    private struct AppliedState: Codable {
        var revision: UUID?
        var snapshot: WatchlistSyncSnapshot?
        var confirmedAt: Date?
    }
    private struct ConflictBackup: Codable {
        var createdAt: Date
        var local: WatchlistSyncSnapshot
        var remote: SnapshotDocument
    }

    init(store: WatchlistStore, coordinator: SnapshotCoordinator,
         metadataDirectory: URL, isConfigured: Bool) throws {
        self.store = store
        self.coordinator = coordinator
        directory = URL(fileURLWithPath: metadataDirectory.standardizedFileURL.path, isDirectory: true)
        configured = isConfigured
        guard directory.isFileURL, directory.path != "/",
              directory.resolvingSymlinksInPath().path == directory.path else {
            throw SnapshotTransportError.rejected(reason: "Invalid dedicated sync metadata directory")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("applied.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path else {
                throw SnapshotTransportError.rejected(reason: "Unsafe sync metadata path")
            }
            applied = try JSONDecoder().decode(AppliedState.self, from: Data(contentsOf: url))
        } else { applied = AppliedState() }
        confirmedRevision = applied.revision
        confirmedAt = applied.confirmedAt
        localAnchor = .remote(applied.revision)
    }

    func start() {
        guard !started else { return }
        started = true
        append { [weak self] in await self?.recover() }
    }
    func localChange(_ snapshot: WatchlistSyncSnapshot) {
        generation += 1
        hasPending = true
        // Consecutive local edits can descend from an already-enqueued LOCAL
        // operation. Freeze that identity, not a baseline fetched in the future.
        // Its assigned revision is stable even if the acknowledgement is late.
        let anchor = localAnchor
        let operationID = UUID()
        localAnchor = .localOperation(operationID)
        statusText = configured ? "本机已保存 · 待同步" : "本机已保存 · 云同步未配置"
        onStateChanged?()
        append { [weak self] in
            guard let self else { return }
            do {
                let parent: UUID?
                switch anchor {
                case .remote(let revision): parent = revision
                case .localOperation(let predecessor):
                    guard let revision = self.assignedLocalRevisions[predecessor] else {
                        throw SnapshotTransportError.rejected(reason: "前一份本机改动尚未可靠入队，请保留草稿并重试同步")
                    }
                    parent = revision
                }
                let document = try await self.coordinator.enqueueLocalChange(snapshot: snapshot,
                    operationID: operationID, parentExpectation: .exact(parent))
                self.assignedLocalRevisions[operationID] = document.revision
                self.conflict = nil // refresh both sides after a new local version
                await self.performSync()
            } catch { self.fail(error) }
        }
    }
    func synchronize() { append { [weak self] in await self?.performSync() } }
    func waitForPendingWork() async { await chain?.value }
    func resolveKeepingLocal() { resolve(.keepLocal) }
    func resolveAcceptingRemote() { resolve(.acceptRemote) }

    private func append(_ action: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await action()
        }
    }
    private func recover() async {
        guard generation == 0 else { return } // queued user edits own recovery now
        let baseline = await coordinator.currentBaseline()
        let pending = await coordinator.currentPending()
        guard generation == 0 else { return }
        let local = store.syncSnapshot()
        if applied.snapshot == nil, pending == nil, baseline?.snapshot == local {
            do { if let baseline { try confirm(baseline) } } catch { fail(error); return }
        }
        // Recover a local-store write that preceded enqueue before a crash.
        // A pristine empty installation must pull, not erase, an existing cloud.
        let differsFromApplied = applied.snapshot.map { $0 != local } ?? Self.hasContent(local)
        if differsFromApplied, pending?.snapshot != local {
            do {
                _ = try await coordinator.enqueueLocalChange(snapshot: local,
                    parentExpectation: .exact(applied.revision))
            } catch { fail(error); return }
        }
        hasPending = await coordinator.currentPending() != nil
        await performSync()
    }
    private func performSync() async {
        guard configured else {
            statusText = hasPending ? "本机已保存 · 云同步未配置" : "云同步未配置 · 不会访问 iCloud"
            onStateChanged?(); return
        }
        guard conflict == nil else { statusText = "两端有冲突 · 等待你核对"; onStateChanged?(); return }
        let capturedGeneration = generation
        let before = store.syncSnapshot()
        statusText = "正在核对云端版本…"; onStateChanged?()
        let outcome = await coordinator.synchronize()
        await consume(outcome, generation: capturedGeneration, before: before)
    }
    private func consume(_ outcome: SyncOutcome, generation captured: Int,
                         before: WatchlistSyncSnapshot) async {
        do {
            switch outcome {
            case .pushed(let document): try confirm(document)
            case .alreadyUpToDate(let document): if let document { try confirm(document) }
            case .inSync(let document):
                if let document, document.snapshot == store.syncSnapshot() { try confirm(document) }
            case .remoteAvailable(let document):
                guard generation == captured, store.syncSnapshot() == before else {
                    statusText = "已保留新的本机修改 · 云端快照暂未应用"
                    hasPending = true; onStateChanged?(); return
                }
                try LocalBackupStore.validateSnapshot(document.snapshot)
                _ = store.applySyncSnapshot(document.snapshot)
                guard store.syncSnapshot() == document.snapshot else {
                    throw SnapshotTransportError.rejected(reason: "远端快照未完整应用，请核对版本；本机数据没有被自动上传覆盖")
                }
                try confirm(document)
                localAnchor = .remote(document.revision)
                assignedLocalRevisions.removeAll()
                onRemoteApplied?()
            case .conflict(let report):
                conflict = report; conflictGeneration = generation
                statusText = "两端有冲突 · 双方版本均保留，未自动覆盖"
            case .failed(let failure): statusText = "同步未完成：\(failure.message)"
            }
            let pending = await coordinator.currentPending()
            let current = store.syncSnapshot()
            let unconfirmedUI = applied.snapshot.map { $0 != current } ?? Self.hasContent(current)
            hasPending = generation != captured || pending != nil || unconfirmedUI
            if conflict == nil {
                switch outcome {
                case .pushed, .alreadyUpToDate, .inSync, .remoteAvailable:
                    statusText = hasPending ? "本机已保存 · 待同步" : "已同步"
                default: break
                }
            }
            onStateChanged?()
        } catch { fail(error) }
    }
    private func confirm(_ document: SnapshotDocument) throws {
        let next = AppliedState(revision: document.revision, snapshot: document.snapshot, confirmedAt: .now)
        try write(next, named: "applied.json")
        applied = next
        // Only retire local ancestry when this confirmation describes the UI's
        // current state; newer queued edits still refer to their predecessor.
        if case .localOperation(let head) = localAnchor, head == document.operationID {
            localAnchor = .remote(document.revision)
            assignedLocalRevisions.removeAll()
        } else if case .remote = localAnchor, store.syncSnapshot() == document.snapshot {
            localAnchor = .remote(document.revision)
        }
        confirmedRevision = next.revision; confirmedAt = next.confirmedAt
    }
    private func resolve(_ choice: ConflictResolution) {
        guard let report = conflict else { return }
        let expectedGeneration = generation
        guard conflictGeneration == expectedGeneration,
              report.localPending?.snapshot == store.syncSnapshot() else {
            conflict = nil
            statusText = "本机数据又有改动，请重新同步后再核对冲突"
            synchronize(); return
        }
        append { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            do {
                // Back up BOTH versions before an explicit destructive choice.
                try self.write(ConflictBackup(createdAt: .now, local: self.store.syncSnapshot(), remote: report.remote),
                    named: "conflict-\(UUID().uuidString).json")
                let before = self.store.syncSnapshot()
                let outcome = try await self.coordinator.resolveConflict(choice,
                    expecting: SnapshotConflictExpectation(remoteRevision: report.remote.revision,
                        pendingRevision: report.localPending?.revision),
                    validateConfirmation: { @MainActor [weak self] in
                        self?.generation == expectedGeneration && self?.store.syncSnapshot() == before
                    })
                self.conflict = nil
                await self.consume(outcome, generation: expectedGeneration, before: before)
            } catch { self.fail(error) }
        }
    }
    private func write<T: Encodable>(_ value: T, named name: String) throws {
        let target = directory.appendingPathComponent(name).standardizedFileURL
        guard target.deletingLastPathComponent().path == directory.path,
              target.resolvingSymlinksInPath().deletingLastPathComponent().path == directory.path else {
            throw SnapshotTransportError.rejected(reason: "Unsafe owned sync file path")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #if os(iOS)
        try encoder.encode(value).write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try encoder.encode(value).write(to: target, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    private func fail(_ error: Error) {
        statusText = "同步未完成：\(error.localizedDescription)"
        onStateChanged?()
    }
    private static func hasContent(_ snapshot: WatchlistSyncSnapshot) -> Bool {
        !snapshot.allAccountItems.isEmpty || snapshot.hasAccountSettings
            || snapshot.groups.contains { !$0.symbols.isEmpty }
    }
}
