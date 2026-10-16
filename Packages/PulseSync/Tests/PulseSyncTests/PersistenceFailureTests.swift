import Foundation
import Testing
import PulseCore
@testable import PulseSync

/// Proves durable-state write failures are never swallowed: no `try?` may turn
/// a failed persist into a success outcome or a cleared pending queue.
///
/// Failures are injected through `SyncStateStore.saveHook` — deterministic and
/// permission-free, so no test depends on running as root or on filesystem
/// tricks like chmod.
@Suite("Persistence failure honesty")
struct PersistenceFailureTests {

    /// Thread-safe, deterministic fault injection for the state store.
    final class SaveHook: @unchecked Sendable {
        struct Injected: Error, Equatable { let sequence: Int }
        private let lock = NSLock()
        private var remaining = 0
        private var injectedCount = 0

        func failNext(_ count: Int) {
            lock.lock()
            remaining += count
            lock.unlock()
        }

        func run() throws {
            lock.lock()
            defer { lock.unlock() }
            if remaining > 0 {
                remaining -= 1
                injectedCount += 1
                throw Injected(sequence: injectedCount)
            }
        }
    }

    private func makeCoordinator(
        _ label: String,
        remote: InMemorySnapshotTransport,
        hook: SaveHook
    ) throws -> (SnapshotCoordinator, URL) {
        let dir = try Fixtures.makeTempDirectory(label)
        let store = SyncStateStore(directory: dir, saveHook: { try hook.run() })
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote, stateStore: store)
        return (coordinator, dir)
    }

    @Test("A state write failure on enqueue throws and queues nothing")
    func enqueuePersistFailureThrows() async throws {
        let remote = InMemorySnapshotTransport()
        let hook = SaveHook()
        let (coordinator, dir) = try makeCoordinator("persist-enqueue", remote: remote, hook: hook)
        defer { Fixtures.removeDirectory(dir) }

        hook.failNext(1)
        await #expect(throws: SaveHook.Injected.self) {
            _ = try await coordinator.commit(snapshot: Fixtures.snapshot())
        }
        // Nothing was queued in memory, and nothing reached the remote.
        #expect(await coordinator.currentPending() == nil)
        #expect(await remote.currentDocument() == nil)
        #expect(await remote.saveAttempts.isEmpty)
    }

    @Test("A state write failure after a confirmed push reports failure and keeps the pending change")
    func ackPersistFailureKeepsPendingAndDoesNotReportSuccess() async throws {
        let remote = InMemorySnapshotTransport()
        let hook = SaveHook()
        let (coordinator, dir) = try makeCoordinator("persist-ack", remote: remote, hook: hook)
        defer { Fixtures.removeDirectory(dir) }

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }
        let edit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let pending = try await coordinator.enqueueLocalChange(snapshot: edit)

        // The remote save will succeed, but recording that acknowledgement on
        // disk fails. The outcome must be an honest failure, never `.pushed`.
        hook.failNext(1)
        let outcome = await coordinator.pushPending()
        guard case .failed(let failure) = outcome else {
            Issue.record("Expected a persistence failure, got \(outcome)")
            return
        }
        #expect(failure.kind == .unknown)
        #expect(failure.pending?.revision == pending.revision)

        // The in-memory picture still matches what the disk actually holds:
        // the old baseline and the still-unacknowledged pending edit.
        #expect(await coordinator.currentPending()?.revision == pending.revision)
        #expect(await coordinator.currentPending()?.snapshot == edit)
        #expect(await coordinator.currentBaseline()?.revision == base.revision)

        // The commit really did land remotely, and a later synchronize settles
        // the lost confirmation instead of resending the change.
        #expect(await remote.currentDocument()?.revision == pending.revision)
        let settled = await coordinator.synchronize()
        guard case .alreadyUpToDate(let remoteDocument) = settled else {
            Issue.record("Expected the lost confirmation to settle, got \(settled)")
            return
        }
        #expect(remoteDocument?.revision == pending.revision)
        #expect(await coordinator.currentPending() == nil)
        #expect(await coordinator.currentBaseline()?.revision == pending.revision)
        #expect(await remote.commitCount == 2, "The settled change must not be resent.")
    }

    @Test("A state write failure during synchronize is reported and state is not advanced")
    func synchronizePersistFailureIsHonest() async throws {
        let remote = InMemorySnapshotTransport()
        let hook = SaveHook()
        let (coordinator, dir) = try makeCoordinator("persist-sync", remote: remote, hook: hook)
        defer { Fixtures.removeDirectory(dir) }

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        // Another device advances the remote.
        let remoteEdit = SnapshotDocument(
            parentRevision: base.revision,
            operationID: UUID(),
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        )
        await remote.putExternally(remoteEdit)

        hook.failNext(1)
        let outcome = await coordinator.synchronize()
        guard case .failed(let failure) = outcome else {
            Issue.record("Expected a persistence failure, got \(outcome)")
            return
        }
        #expect(failure.kind == .unknown)

        // The local picture was NOT advanced to a state that was never
        // persisted: the baseline still describes what the disk holds.
        #expect(await coordinator.currentBaseline()?.revision == base.revision)

        // The next synchronize persists fine and reports the remote snapshot.
        let retry = await coordinator.synchronize()
        guard case .remoteAvailable(let document) = retry else {
            Issue.record("Expected remoteAvailable after recovery, got \(retry)")
            return
        }
        #expect(document.revision == remoteEdit.revision)
        #expect(await coordinator.currentBaseline()?.revision == remoteEdit.revision)
    }
}
