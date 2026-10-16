import Foundation
import Testing
import PulseCore
@testable import PulseSync

/// Covers `SnapshotParentExpectation`: explicit parent claims are never
/// silently rebased, and the legacy API keeps its exact historical meaning.
@Suite("SnapshotParentExpectation")
struct ParentExpectationTests {

    @Test("An explicit empty parent conflicts with a remote that appeared before the push")
    func exactNilParentConflictsWithAppearedRemote() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("exact-nil-race")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        // The user creates the first-ever local content while the remote is
        // empty, and the caller freezes that fact explicitly.
        let mine = Fixtures.snapshot(groupName: "Mine")
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: mine,
            parentExpectation: .exact(nil)
        )
        #expect(pending.parentRevision == nil)

        // Another device creates the first revision before our push lands.
        let theirs = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            snapshot: Fixtures.snapshot(groupName: "Theirs")
        )
        await remote.putExternally(theirs)

        let outcome = await coordinator.pushPending()
        guard case .conflict(let report) = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(report.remote.revision == theirs.revision)
        #expect(report.localPending?.revision == pending.revision)
        // The explicit-empty claim must not overwrite the newer remote.
        #expect(await remote.currentDocument()?.revision == theirs.revision)
        #expect(await coordinator.currentPending()?.revision == pending.revision)
        #expect(await coordinator.currentPending()?.snapshot == mine)
    }

    @Test("An explicit empty parent conflicts with an existing confirmed baseline")
    func exactNilParentConflictsWithExistingBaseline() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("exact-nil-baseline")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }

        // The caller claims the edit was made against an empty remote, but the
        // confirmed base is non-empty: refusing beats guessing.
        let edit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: edit,
            parentExpectation: .exact(nil)
        )
        #expect(pending.parentRevision == nil)

        let outcome = await coordinator.pushPending()
        guard case .conflict(let report) = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(report.remote.revision == base.revision)
        #expect(report.localPending?.revision == pending.revision)
        #expect(await remote.currentDocument()?.revision == base.revision)
        #expect(await coordinator.currentPending()?.revision == pending.revision)
    }

    @Test("A stale explicit parent is refused before any network write")
    func staleParentPushIsRefusedBeforeNetwork() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("stale-parent")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }
        let firstEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        guard case .pushed(let first) = try await coordinator.commit(snapshot: firstEdit) else {
            Issue.record("Setup commit failed.")
            return
        }

        // The caller froze the pre-first-edit baseline at edit time; by push
        // time the confirmed base has moved past it.
        let secondEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: secondEdit,
            parentExpectation: .exact(base.revision)
        )
        #expect(pending.parentRevision == base.revision)

        let attemptsBefore = await remote.saveAttempts.count
        let outcome = await coordinator.pushPending()
        guard case .conflict(let report) = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(report.localPending?.revision == pending.revision)
        #expect(await remote.saveAttempts.count == attemptsBefore,
                "A locally detectable stale parent must never reach the transport.")
        // Nothing overwrote the confirmed remote document.
        #expect(await remote.currentDocument()?.revision == first.revision)
        #expect(await coordinator.currentPending()?.revision == pending.revision)
    }

    @Test("The legacy parentRevision argument behaves as an explicit exact parent")
    func legacyParentRevisionMapsToExact() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("legacy-parent")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }
        let bogusParent = UUID()
        let edit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: edit,
            parentRevision: bogusParent
        )
        #expect(pending.parentRevision == bogusParent)
        // Because it does not match the confirmed baseline, pushing refuses
        // rather than rewriting the parent to fit.
        let outcome = await coordinator.pushPending()
        guard case .conflict = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(await remote.currentDocument()?.revision == base.revision)
    }

    @Test("The default and .currentBaseline both freeze the baseline at enqueue time")
    func currentBaselineIsTheDefault() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("default-parent")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        guard case .pushed(let base) = try await coordinator.commit(snapshot: Fixtures.snapshot()) else {
            Issue.record("Setup commit failed.")
            return
        }
        let editA = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let legacyDefault = try await coordinator.enqueueLocalChange(snapshot: editA)
        #expect(legacyDefault.parentRevision == base.revision)
        try await coordinator.discardPendingChange()
        let explicit = try await coordinator.enqueueLocalChange(
            snapshot: editA,
            parentExpectation: .currentBaseline
        )
        #expect(explicit.parentRevision == base.revision)
    }

    @Test("The remote claiming our operation ID with different content is a conflict, not a settlement")
    func sameOperationIDDifferentContentOnRemoteConflicts() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("impostor-op")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        let operationID = UUID()
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: Fixtures.snapshot(groupName: "Local"),
            operationID: operationID
        )
        // The remote claims the same operation ID with different content.
        let impostor = SnapshotDocument(
            parentRevision: nil,
            operationID: operationID,
            snapshot: Fixtures.snapshot(groupName: "Remote")
        )
        await remote.putExternally(impostor)

        let outcome = await coordinator.pushPending()
        guard case .conflict(let report) = outcome else {
            Issue.record("Expected a conflict, got \(outcome)")
            return
        }
        #expect(report.remote.operationID == operationID)
        #expect(report.remote.snapshot.groups.first?.name == "Remote")
        #expect(report.localPending?.revision == pending.revision)
        // Neither side was overwritten or silently settled.
        #expect(await remote.currentDocument()?.snapshot.groups.first?.name == "Remote")
        #expect(await coordinator.currentPending()?.revision == pending.revision)
        #expect(await coordinator.currentBaseline() == nil)
    }

    @Test("A lost acknowledgement with matching ID and content still settles after the rework")
    func lostAcknowledgementWithMatchingContentSettles() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("lost-ack-match")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        let operationID = UUID()
        let pending = try await coordinator.enqueueLocalChange(
            snapshot: Fixtures.snapshot(groupName: "Same"),
            operationID: operationID
        )
        await remote.putExternally(pending)

        let outcome = await coordinator.pushPending()
        guard case .alreadyUpToDate(let remoteDocument) = outcome else {
            Issue.record("Expected alreadyUpToDate, got \(outcome)")
            return
        }
        #expect(remoteDocument?.revision == pending.revision)
        #expect(await coordinator.currentPending() == nil)
        #expect(await remote.commitCount == 0)
    }
}
