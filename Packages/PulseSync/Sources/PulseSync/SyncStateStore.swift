import Foundation

/// The on-disk state a coordinator keeps: its last known remote baseline, the
/// local change that has not been confirmed as committed, and the operation ID
/// that change belongs to.
struct SyncState: Sendable, Equatable {
    /// Last revision this installation knows the remote held.
    var baseline: SnapshotDocument?
    /// The local change waiting to be committed. Retained on every failure.
    var pending: SnapshotDocument?
    /// False until the first successful fetch, so "never synced" is
    /// distinguishable from "remote is empty".
    var hasFetchedRemote: Bool

    init(baseline: SnapshotDocument? = nil, pending: SnapshotDocument? = nil, hasFetchedRemote: Bool = false) {
        self.baseline = baseline
        self.pending = pending
        self.hasFetchedRemote = hasFetchedRemote
    }
}

/// Crash-safe persistence for `SyncState` inside one caller-owned directory.
///
/// Every write is atomic (`Data.write(options: .atomic)` stages a sibling temp
/// file and renames it), so a crash leaves either the previous complete state or
/// the new complete state — never a truncated file. The coordinator therefore
/// re-reads a consistent state after a restart, including a pending change that
/// had not yet reached the remote.
///
/// This type never touches any path outside the directory it was created with.
struct SyncStateStore: Sendable {
    /// Files this store owns. Anything else in the directory is left alone.
    static let stateFileName = "sync-state.json"
    static let stateTempFileName = "sync-state.json.tmp"

    let directoryURL: URL

    /// Test-only fault injection: when set, every `save` runs this first and
    /// propagates its error, so tests can simulate a disk write failure
    /// deterministically without relying on filesystem permissions or root.
    /// Never set in production code paths.
    var saveHook: (@Sendable () throws -> Void)?

    init(directory: URL, saveHook: (@Sendable () throws -> Void)? = nil) {
        // Resolve once so later path comparisons are against a concrete,
        // normalized absolute path rather than a possibly relative input.
        self.directoryURL = directory.standardizedFileURL
        self.saveHook = saveHook
    }

    var stateURL: URL { directoryURL.appendingPathComponent(Self.stateFileName, isDirectory: false) }
    var stateTempURL: URL { directoryURL.appendingPathComponent(Self.stateTempFileName, isDirectory: false) }

    /// True only if `candidate` is a file this store is allowed to unlink:
    /// an absolute, resolved path inside our own directory naming one of our
    /// own files. Guards every removal.
    func owns(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, !candidate.path.isEmpty else { return false }
        let resolved = candidate.standardizedFileURL
        guard resolved.path.hasPrefix(directoryURL.path + "/") else { return false }
        let parent = resolved.deletingLastPathComponent().path
        guard parent == directoryURL.path else { return false }
        let name = resolved.lastPathComponent
        return name == Self.stateFileName || name == Self.stateTempFileName
    }

    func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return SyncState() }
        let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        return try decoded.state()
    }

    func save(_ state: SyncState) throws {
        try saveHook?()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        // Deterministic key order. Swift's `Hasher` is randomly seeded per
        // process, so Codable's synthesized key order varies between runs; the
        // same state would then serialize to different bytes on every launch.
        // Stable bytes make the durable file reproducible and diffable, which is
        // what lets a bug in it be diagnosed at all.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PersistedState(state: state))
        // `.atomic` is the crash-safety guarantee: a partially written state
        // file would make the coordinator misread whether a change was already
        // committed, which is exactly the case this feature exists to avoid.
        try data.write(to: stateURL, options: [.atomic])
        removeStaleTempFileIfOwned()
    }

    /// Removes only our own staging file, and only after verifying it is one.
    private func removeStaleTempFileIfOwned() {
        let temp = stateTempURL
        guard owns(temp), FileManager.default.fileExists(atPath: temp.path) else { return }
        try? FileManager.default.removeItem(at: temp)
    }

    private struct PersistedState: Codable {
        var payloadVersion: Int
        var baseline: SnapshotDocument?
        var pending: SnapshotDocument?
        var hasFetchedRemote: Bool

        init(state: SyncState) {
            payloadVersion = SyncStateStore.currentPayloadVersion
            baseline = state.baseline
            pending = state.pending
            hasFetchedRemote = state.hasFetchedRemote
        }

        func state() throws -> SyncState {
            guard payloadVersion <= SyncStateStore.currentPayloadVersion, payloadVersion >= 1 else {
                throw SyncStateStoreError.unsupportedStateVersion(payloadVersion)
            }
            return SyncState(
                baseline: baseline,
                pending: pending,
                hasFetchedRemote: hasFetchedRemote
            )
        }
    }

    static let currentPayloadVersion = 1
}

enum SyncStateStoreError: Error, Equatable {
    /// A state file written by a newer build. Refusing to read it is safer than
    /// guessing at its meaning and risking a duplicate or lost commit.
    case unsupportedStateVersion(Int)
}
