import Foundation
import Testing
import PulseCore
@testable import PulseSync

/// Proves that a local edit enqueued *while* a network call is in flight is
/// never destroyed by the stale acknowledgement of the earlier call.
///
/// `SnapshotCoordinator` is an actor, so `enqueueLocalChange` can run to
/// completion during the `await` inside `pushPending`/`synchronize`. Any code
/// after that await therefore operates on a `state` that may no longer be the
/// one it read before the await. These tests hold the transport open on
/// purpose, enqueue a second, different snapshot mid-flight, and then release
/// the first call — the second snapshot must still be durable pending.
@Suite("SnapshotCoordinator reentrancy")
struct ReentrancyTests {

    // MARK: - Synchronize: fetch is in flight when the second edit arrives

    @Test("An edit enqueued while synchronize's fetch is in flight survives the older ack")
    func editDuringSynchronizeFetchSurvives() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("reentrant-fetch")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        // Establish a confirmed baseline the edits are derived from.
        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        // The gate must park at the stage this test later waits on: the fetch.
        // A mismatch used to deadlock the suite; the gate now times out loudly
        // instead, and this configuration makes the interleaving real.
        let gate = TransportGate(parkAt: .fetch)
        await remote.installGate(gate)

        let firstEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let secondEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)

        // synchronize() starts, fetch parks inside the gate holding revision
        // `base`. It has read `state` but has not yet written anything back.
        let syncTask = Task { await coordinator.synchronize() }

        // The user edits again while the first call is still awaiting.
        let secondDocument = try await RemoteEdits.enqueue(
            secondEdit,
            on: coordinator,
            waitingFor: gate,
            in: .fetch
        )

        // Release the parked fetch; it returns the document it read *before*
        // the second edit existed.
        await gate.open()

        let outcome = await syncTask.value
        await expectNoSilentLoss(
            outcome: outcome,
            secondDocument: secondDocument,
            coordinator: coordinator,
            remote: remote,
            context: "synchronize() fetch completed after a newer local edit was enqueued"
        )

        // The newer edit must be the surviving pending content.
        let pending = await coordinator.currentPending()
        #expect(pending?.revision == secondDocument.revision,
                "The older ack must not replace the newer pending document.")
        #expect(pending?.snapshot == secondEdit)
    }

    // MARK: - Push: save is in flight when the second edit arrives

    @Test("An edit enqueued while pushPending's save is in flight survives the older ack")
    func editDuringPushSaveSurvives() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("reentrant-save")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        let firstEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let secondEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)

        // Queue the first edit; it becomes the pending document.
        let firstDocument = try await coordinator.enqueueLocalChange(snapshot: firstEdit)
        #expect(await coordinator.currentPending()?.revision == firstDocument.revision)

        let gate = TransportGate()
        await remote.installGate(gate)

        // pushPending() starts and parks inside the remote's save, having
        // already read `pending == firstDocument`.
        let pushTask = Task { await coordinator.pushPending() }

        // A second, *different* edit is enqueued while the save is in flight.
        let secondDocument = try await RemoteEdits.enqueue(
            secondEdit,
            on: coordinator,
            waitingFor: gate,
            in: .save
        )
        #expect(secondDocument.revision != firstDocument.revision)
        #expect(secondDocument.snapshot != firstDocument.snapshot)

        await gate.open()

        let outcome = await pushTask.value

        // The first edit did land remotely and may legitimately be reported as
        // pushed, but the second edit must not be collateral damage.
        await expectNoSilentLoss(
            outcome: outcome,
            secondDocument: secondDocument,
            coordinator: coordinator,
            remote: remote,
            context: "pushPending() save completed after a newer local edit was enqueued"
        )
        #expect(await coordinator.currentPending()?.revision == secondDocument.revision)
        #expect(await coordinator.currentPending()?.snapshot == secondEdit)

        // The baseline describes the confirmed document, never the newer
        // unconfirmed one.
        #expect(await coordinator.currentBaseline()?.revision == firstDocument.revision)
        #expect(await coordinator.currentBaseline()?.revision != secondDocument.revision)
    }

    // MARK: - Baseline and parent bookkeeping after the race

    @Test("After the race the baseline is the confirmed document and the next parent is honest")
    func baselineTracksConfirmedDocumentAfterRace() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("reentrant-parent")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        let firstEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let secondEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)

        let firstDocument = try await coordinator.enqueueLocalChange(snapshot: firstEdit)
        let gate = TransportGate()
        await remote.installGate(gate)

        let pushTask = Task { await coordinator.pushPending() }
        let secondDocument = try await RemoteEdits.enqueue(
            secondEdit,
            on: coordinator,
            waitingFor: gate,
            in: .save
        )
        await gate.open()
        _ = await pushTask.value

        guard let baseline = await coordinator.currentBaseline() else {
            Issue.record("A baseline must exist after a confirmed commit.")
            return
        }
        // The baseline is exactly the document the remote confirmed, and it is
        // the one the remote still holds.
        #expect(baseline.revision == firstDocument.revision)
        #expect(await remote.currentDocument()?.revision == firstDocument.revision)

        let pending = await coordinator.currentPending()
        #expect(pending?.revision == secondDocument.revision)

        // The next successful push must be justified: the surviving pending
        // document must either already descend from the confirmed baseline, or
        // be refused explicitly. Silently relabelling its parent to a revision
        // the user never edited against is the failure this asserts against.
        let outcome = await coordinator.pushPending()
        switch outcome {
        case .pushed(let pushed):
            #expect(pushed.parentRevision == baseline.revision,
                    "A pushed document must descend from the confirmed baseline.")
            #expect(pushed.snapshot == secondEdit,
                    "The pushed content is the surviving local edit, byte for byte.")
        case .conflict:
            // Also acceptable: the coordinator refuses to guess at the parent.
            #expect(pending?.parentRevision != baseline.revision,
                    "A conflict here only makes sense if the parents genuinely disagree.")
            #expect(await coordinator.currentPending()?.revision == secondDocument.revision,
                    "A conflict must keep the pending edit intact.")
        case .failed(let failure):
            Issue.record("Unexpected failure: \(failure.kind) \(failure.message)")
        default:
            Issue.record("Expected the second edit to push or conflict, got \(outcome)")
        }

        // Whatever happened, the remote must never hold a revision that no
        // local edit ever produced content for.
        let remoteDocument = await remote.currentDocument()
        #expect(remoteDocument?.snapshot == secondEdit || remoteDocument?.snapshot == firstEdit,
                "The remote holds only content some edit actually produced.")
    }

    @Test("A confirmed push settles its own document and never clears a newer pending one")
    func settleIsScopedToTheAcknowledgedDocument() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("reentrant-settle")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        let gate = TransportGate()
        await remote.installGate(gate)

        let firstEdit = Fixtures.snapshot()
        let secondEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: firstEdit)

        _ = try await coordinator.enqueueLocalChange(snapshot: firstEdit)
        let pushTask = Task { await coordinator.pushPending() }
        let secondDocument = try await RemoteEdits.enqueue(
            secondEdit,
            on: coordinator,
            waitingFor: gate,
            in: .save
        )
        await gate.open()
        _ = await pushTask.value

        // The second edit is still unsent, so it must still be pending, and the
        // remote must not already contain it.
        #expect(await coordinator.currentPending()?.revision == secondDocument.revision)
        #expect(await remote.currentDocument()?.snapshot == firstEdit,
                "Only the acknowledged document may have reached the remote.")
    }

    // MARK: - Helpers

    /// The one invariant every reentrancy scenario shares: the newer edit is
    /// never lost, and the remote never holds content nobody wrote.
    private func expectNoSilentLoss(
        outcome: SyncOutcome,
        secondDocument: SnapshotDocument,
        coordinator: SnapshotCoordinator,
        remote: InMemorySnapshotTransport,
        context: String
    ) async {
        let pending = await coordinator.currentPending()
        let baseline = await coordinator.currentBaseline()

        let survivedAsPending = pending?.revision == secondDocument.revision
            && pending?.snapshot == secondDocument.snapshot
        let confirmedRemotely = await remote.currentDocument()?.revision == secondDocument.revision

        #expect(survivedAsPending || confirmedRemotely,
                "\(context): the newer edit was silently dropped. outcome=\(outcome) pending=\(String(describing: pending?.revision))")

        if confirmedRemotely {
            // If it really did land, the coordinator must know it, not keep a
            // stale or empty picture.
            #expect(baseline?.revision == secondDocument.revision || pending != nil,
                    "\(context): a remotely confirmed edit must be reflected in local state.")
        }
    }
}

/// Helper to enqueue the second edit only once the first call is provably
/// parked inside the transport, so the interleaving is deterministic rather
/// than timing-dependent.
enum RemoteEdits {
    /// Enqueues `snapshot` after `gate` reports the requested stage is entered.
    ///
    /// The enqueue itself is what the test needs to observe; waiting for the
    /// stage makes the order deterministic without a sleep.
    @discardableResult
    static func enqueue(
        _ snapshot: WatchlistSyncSnapshot,
        on coordinator: SnapshotCoordinator,
        waitingFor gate: TransportGate,
        in stage: TransportGate.Stage
    ) async throws -> SnapshotDocument {
        let entered = await gate.waitUntilEntered(stage, timeout: 10)
        guard entered else {
            // The gate never parked at this stage, so the interleaving the test
            // asserts against never happened. Failing loudly beats hanging or,
            // worse, proceeding and testing nothing.
            Issue.record("Timed out waiting for the transport to park at \(stage); the gate was configured for a different stage.")
            throw GateNeverParked(stage: stage)
        }
        return try await coordinator.enqueueLocalChange(snapshot: snapshot)
    }
}

/// The gate was configured for a different stage than the test waited on, so
/// the deterministic interleaving never occurred.
struct GateNeverParked: Error {
    let stage: TransportGate.Stage
}
