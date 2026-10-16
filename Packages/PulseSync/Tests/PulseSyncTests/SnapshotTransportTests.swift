import Foundation
import Testing
import PulseCore
@testable import PulseSync

@Suite("SnapshotTransport contract")
struct SnapshotTransportTests {

    @Test("Compare-and-swap accepts a matching expectation and rejects a stale one")
    func compareAndSwapSemantics() async throws {
        let remote = InMemorySnapshotTransport()
        let first = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            snapshot: Fixtures.snapshot()
        )
        try await remote.save(first, expecting: nil)
        #expect(await remote.currentDocument()?.revision == first.revision)

        // Second write on top of the first.
        let second = SnapshotDocument(
            parentRevision: first.revision,
            operationID: UUID(),
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: first.snapshot)
        )
        try await remote.save(second, expecting: first.revision)
        #expect(await remote.currentDocument()?.revision == second.revision)

        // A writer still holding the first revision must be refused.
        let stale = SnapshotDocument(
            parentRevision: first.revision,
            operationID: UUID(),
            snapshot: first.snapshot
        )
        await #expect(throws: SnapshotTransportError.self) {
            try await remote.save(stale, expecting: first.revision)
        }
        // The remote still holds the second revision.
        #expect(await remote.currentDocument()?.revision == second.revision)
    }

    @Test("An empty remote reports a nil document rather than throwing")
    func emptyRemoteIsNotAnError() async throws {
        let remote = InMemorySnapshotTransport()
        let record = try await remote.fetch()
        #expect(record.document == nil)
        #expect(record.changeToken == nil)
    }

    @Test("Transient failures are classified as retryable and configuration failures are not")
    func errorClassification() {
        #expect(SnapshotTransportError.offline(reason: "x").isRetryable)
        #expect(!SnapshotTransportError.notConfigured(reason: "x").isRetryable)
        #expect(!SnapshotTransportError.corruptRemote(reason: "x").isRetryable)
        #expect(!SnapshotTransportError.rejected(reason: "x").isRetryable)
        let conflict = SnapshotTransportError.conflict(
            current: RemoteSnapshotRecord(document: nil, changeToken: nil),
            reason: "x"
        )
        #expect(!conflict.isRetryable, "A conflict must never be auto-retried.")
        #expect(conflict.errorDescription?.contains("conflict") == true)
    }

    @Test("A transient fetch failure does not corrupt durable state")
    func transientFetchFailureKeepsState() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("fetch-fail")
        defer { Fixtures.removeDirectory(dir) }

        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        guard case .pushed(let pushed) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        await remote.failNextFetches(1)
        let outcome = await coordinator.synchronize()
        guard case .failed(let failure) = outcome else {
            Issue.record("Expected a transient failure, got \(outcome)")
            return
        }
        #expect(failure.kind == .transient)
        // The baseline established earlier is retained.
        #expect(await coordinator.currentBaseline()?.revision == pushed.revision)
    }
}

@Suite("SyncStateStore")
struct SyncStateStoreTests {

    @Test("A stored state round-trips exactly, including a pending document")
    func roundTrip() throws {
        let dir = try Fixtures.makeTempDirectory("state-roundtrip")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)

        let baseline = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            snapshot: Fixtures.snapshot()
        )
        let pending = SnapshotDocument(
            parentRevision: baseline.revision,
            operationID: UUID(),
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: baseline.snapshot)
        )
        let state = SyncState(baseline: baseline, pending: pending, hasFetchedRemote: true)
        try store.save(state)

        let loaded = try store.load()
        #expect(loaded == state, "Durable state must round-trip without loss.")
        #expect(loaded.pending?.snapshot == pending.snapshot)
    }

    @Test("An absent state file loads as a fresh state rather than failing")
    func missingFileIsFreshState() throws {
        let dir = try Fixtures.makeTempDirectory("state-missing")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)
        let state = try store.load()
        #expect(state == SyncState())
        #expect(state.hasFetchedRemote == false, "Never-synced must differ from an empty remote.")
    }

    @Test("A corrupt state file is reported instead of silently reset")
    func corruptFileThrows() throws {
        let dir = try Fixtures.makeTempDirectory("state-corrupt")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)
        try Data("not json".utf8).write(to: store.stateURL)
        // Silently treating this as "no state" could discard an unsent change.
        #expect(throws: (any Error).self) { _ = try store.load() }
    }

    @Test("The store only claims ownership of its own files in its own directory")
    func ownershipIsNarrow() throws {
        let dir = try Fixtures.makeTempDirectory("state-ownership")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)

        #expect(store.owns(store.stateURL))
        #expect(store.owns(store.stateTempURL))
        // Anything outside, or a deeper path, is not ours.
        #expect(!store.owns(dir.appendingPathComponent("someone-elses.json")))
        #expect(!store.owns(dir.appendingPathComponent("nested/sync-state.json")))
        #expect(!store.owns(dir.deletingLastPathComponent().appendingPathComponent("sync-state.json")))
        #expect(!store.owns(URL(fileURLWithPath: "/etc/passwd")))
        #expect(!store.owns(URL(fileURLWithPath: "")))
    }

    @Test("Saving is atomic: an existing file is replaced wholly, never truncated")
    func saveReplacesWholly() throws {
        let dir = try Fixtures.makeTempDirectory("state-atomic")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)

        let first = SyncState(baseline: nil, pending: nil, hasFetchedRemote: true)
        try store.save(first)
        let second = SyncState(
            baseline: SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: Fixtures.snapshot()),
            pending: nil,
            hasFetchedRemote: true
        )
        try store.save(second)

        #expect(try store.load() == second)
        // The staging file is cleaned up and never left behind.
        #expect(!FileManager.default.fileExists(atPath: store.stateTempURL.path))
    }

    @Test("State encoding is stable for equal values, so equality is meaningful after reload")
    func encodingIsStable() throws {
        let dir = try Fixtures.makeTempDirectory("state-stable")
        defer { Fixtures.removeDirectory(dir) }
        let store = SyncStateStore(directory: dir)
        let document = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: Fixtures.snapshot()
        )
        let state = SyncState(baseline: document, pending: nil, hasFetchedRemote: true)
        try store.save(state)
        let once = try Data(contentsOf: store.stateURL)
        try store.save(try store.load())
        let twice = try Data(contentsOf: store.stateURL)
        #expect(once == twice)
    }
}
