import Foundation
import Testing
import PulseCore
@testable import PulseSync

/// Every test uses an isolated temporary directory and an in-memory transport.
/// No test performs a network request, a CloudKit call, or touches real app data.
@Suite("SnapshotCoordinator")
struct SnapshotCoordinatorTests {

    // MARK: - First create and two-device revision exchange

    @Test("A first commit creates the remote document and both devices converge on its revision")
    func firstCreateThenBothDevicesAgree() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("create-a")
        let dirB = try Fixtures.makeTempDirectory("create-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)

        // Device B looks first and finds nothing. That is "empty remote", not a
        // failure, and it must be recorded as such.
        let emptyRead = await deviceB.synchronize()
        #expect(emptyRead == .inSync(remote: nil))
        #expect(await deviceB.currentBaseline() == nil)

        // Device A creates the first revision.
        let first = Fixtures.snapshot()
        let outcomeA = try await deviceA.commit(snapshot: first)
        guard case .pushed(let pushedA) = outcomeA else {
            Issue.record("Expected first commit to be pushed, got \(outcomeA)")
            return
        }
        #expect(pushedA.parentRevision == nil, "The first document must have no parent.")

        // Device B now reads it as a new remote revision to apply.
        let readB = await deviceB.synchronize()
        guard case .remoteAvailable(let seen) = readB else {
            Issue.record("Expected remoteAvailable, got \(readB)")
            return
        }
        #expect(seen.revision == pushedA.revision)
        #expect(seen.snapshot == first)
        #expect(await deviceB.currentBaseline()?.revision == pushedA.revision)

        // Device B applies it and commits its own change on top.
        let second = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: seen.snapshot)
        let outcomeB = try await deviceB.commit(snapshot: second)
        guard case .pushed(let pushedB) = outcomeB else {
            Issue.record("Expected device B commit to be pushed, got \(outcomeB)")
            return
        }
        #expect(pushedB.parentRevision == pushedA.revision)

        // Device A sees B's revision as a clean, non-conflicting update.
        let readA = await deviceA.synchronize()
        guard case .remoteAvailable(let seenByA) = readA else {
            Issue.record("Expected remoteAvailable on A, got \(readA)")
            return
        }
        #expect(seenByA.revision == pushedB.revision)
        #expect(seenByA.snapshot.items.count == 2)
        #expect(await remote.commitCount == 2)
    }

    @Test("Two devices racing to create the first revision: exactly one wins and the other is told")
    func concurrentFirstCreateIsDetected() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("race-a")
        let dirB = try Fixtures.makeTempDirectory("race-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)

        // Both devices independently conclude the remote is empty.
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        let outcomeA = try await deviceA.commit(snapshot: Fixtures.snapshot(groupName: "FromA"))
        let outcomeB = try await deviceB.commit(snapshot: Fixtures.snapshot(groupName: "FromB"))

        guard case .pushed = outcomeA else {
            Issue.record("Device A should have won the create race, got \(outcomeA)")
            return
        }
        guard case .conflict(let report) = outcomeB else {
            Issue.record("Device B should have been told about the race, got \(outcomeB)")
            return
        }
        // The loser keeps its data and learns exactly what blocked it.
        #expect(report.localPending != nil)
        #expect(report.remote.snapshot.groups.first?.name == "FromA")
        #expect(await remote.commitCount == 1, "Only one create may land.")
        // Crucially, the loser's pending write is still intact.
        #expect(await deviceB.currentPending()?.snapshot.groups.first?.name == "FromB")
    }

    // MARK: - Offline retry

    @Test("A failed push retains the pending snapshot, and retrying the same operation ID does not duplicate")
    func offlineRetryKeepsPendingAndDoesNotDuplicate() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("offline")
        defer { Fixtures.removeDirectory(dir) }

        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        await remote.failNextSaves(1)
        let snapshot = Fixtures.snapshot()
        let operationID = UUID()
        let attempt1 = try await coordinator.commit(snapshot: snapshot, operationID: operationID)

        guard case .failed(let failure) = attempt1 else {
            Issue.record("Expected a transient failure, got \(attempt1)")
            return
        }
        #expect(failure.kind == .transient)
        #expect(failure.pending?.operationID == operationID)
        // The change is kept, not dropped.
        #expect(await coordinator.currentPending()?.operationID == operationID)
        #expect(await remote.commitCount == 0)

        // Retry with the SAME operation ID and identical content.
        let attempt2 = await coordinator.pushPending()
        guard case .pushed(let pushed) = attempt2 else {
            Issue.record("Expected the retry to succeed, got \(attempt2)")
            return
        }
        #expect(pushed.operationID == operationID)
        #expect(await remote.commitCount == 1)
        #expect(await coordinator.currentPending() == nil)

        // Retrying again after success must not create a second revision.
        let attempt3 = await coordinator.pushPending()
        #expect(attempt3 == .inSync(remote: pushed))
        #expect(await remote.commitCount == 1, "A settled operation must not be resent.")
    }

    @Test("A commit confirmed remotely but not locally settles rather than resending")
    func lostConfirmationSettlesAsAlreadyUpToDate() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("lost-ack")
        defer { Fixtures.removeDirectory(dir) }

        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        // Fail the save *after* the remote has recorded it, simulating a lost
        // acknowledgement: the document is on the server but the caller saw an
        // error. We emulate it by writing externally with our own operation ID.
        let operationID = UUID()
        let snapshot = Fixtures.snapshot()
        let pending = try await coordinator.enqueueLocalChange(snapshot: snapshot, operationID: operationID)
        await remote.putExternally(pending)

        let outcome = await coordinator.pushPending()
        guard case .alreadyUpToDate(let remoteDocument) = outcome else {
            Issue.record("Expected alreadyUpToDate, got \(outcome)")
            return
        }
        #expect(remoteDocument?.revision == pending.revision)
        #expect(await coordinator.currentPending() == nil)
        #expect(await remote.commitCount == 0, "Nothing new should have been written.")
    }

    @Test("The same operation ID with different content is refused, not silently accepted")
    func sameOperationIDDifferentContentIsRejected() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("same-id-diff-content")
        defer { Fixtures.removeDirectory(dir) }

        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        let operationID = UUID()
        _ = try await coordinator.enqueueLocalChange(
            snapshot: Fixtures.snapshot(groupName: "First"),
            operationID: operationID
        )

        // A different payload on the same ID is a caller bug; accepting it as
        // idempotent would silently discard the second edit.
        await #expect(throws: CoordinatorError.operationIDReusedWithDifferentContent(operationID: operationID)) {
            try await coordinator.enqueueLocalChange(
                snapshot: Fixtures.snapshot(groupName: "Second"),
                operationID: operationID
            )
        }
        // The original pending content is untouched.
        #expect(await coordinator.currentPending()?.snapshot.groups.first?.name == "First")
    }

    @Test("Re-enqueuing the identical operation and content is an idempotent no-op")
    func identicalReenqueueIsIdempotent() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("idempotent")
        defer { Fixtures.removeDirectory(dir) }

        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        let operationID = UUID()
        let snapshot = Fixtures.snapshot()

        let first = try await coordinator.enqueueLocalChange(snapshot: snapshot, operationID: operationID)
        let second = try await coordinator.enqueueLocalChange(snapshot: snapshot, operationID: operationID)
        #expect(first == second, "An identical retry must reuse the same document, not make a new revision.")
    }

    // MARK: - Crash recovery

    @Test("A pending change survives a process restart because it is persisted before it is sent")
    func pendingSurvivesRestart() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("restart")
        defer { Fixtures.removeDirectory(dir) }

        let snapshot = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC)
        let operationID = UUID()
        let firstRevision: UUID
        do {
            let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
            _ = await coordinator.synchronize()
            await remote.failNextSaves(1)
            let outcome = try await coordinator.commit(snapshot: snapshot, operationID: operationID)
            guard case .failed = outcome else {
                Issue.record("Expected the offline save to fail, got \(outcome)")
                return
            }
            firstRevision = await coordinator.currentPending()!.revision
        }

        // The previous coordinator is gone. A fresh instance must recover the
        // unsent change from disk, with the same operation ID and content.
        let restored = try SnapshotCoordinator(directory: dir, transport: remote)
        let pending = await restored.currentPending()
        #expect(pending?.operationID == operationID)
        #expect(pending?.revision == firstRevision)
        #expect(pending?.snapshot == snapshot, "The recovered snapshot must be byte-identical.")

        // And it can still be delivered.
        let outcome = await restored.pushPending()
        guard case .pushed(let pushed) = outcome else {
            Issue.record("Expected the recovered change to push, got \(outcome)")
            return
        }
        #expect(pushed.snapshot == snapshot)
        #expect(await remote.currentDocument()?.snapshot == snapshot)
    }

    @Test("The baseline also survives a restart, so a later commit has the right parent")
    func baselineSurvivesRestart() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("restart-baseline")
        defer { Fixtures.removeDirectory(dir) }

        let committed: SnapshotDocument
        do {
            let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
            _ = await coordinator.synchronize()
            let outcome = try await coordinator.commit(snapshot: Fixtures.snapshot())
            guard case .pushed(let document) = outcome else {
                Issue.record("Expected a push, got \(outcome)")
                return
            }
            committed = document
        }

        let restored = try SnapshotCoordinator(directory: dir, transport: remote)
        #expect(await restored.currentBaseline()?.revision == committed.revision)
        #expect(await restored.currentPending() == nil)

        let next = try await restored.commit(snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB))
        guard case .pushed(let second) = next else {
            Issue.record("Expected a push after restart, got \(next)")
            return
        }
        #expect(second.parentRevision == committed.revision,
                "The restored baseline must be used as the parent revision.")
    }

    @Test("A state file from a newer build is refused rather than guessed at")
    func unsupportedStateVersionIsRefused() async throws {
        let dir = try Fixtures.makeTempDirectory("bad-state")
        defer { Fixtures.removeDirectory(dir) }
        // A payload version this build does not understand must not be read as
        // if it were version 1; guessing could lose or duplicate a commit.
        let state = """
        {"payloadVersion":99,"hasFetchedRemote":true}
        """
        try Data(state.utf8).write(to: dir.appendingPathComponent("sync-state.json"))
        #expect(throws: (any Error).self) {
            _ = try SnapshotCoordinator(directory: dir, transport: InMemorySnapshotTransport())
        }
    }

    // MARK: - Conflict handling

    @Test("A remote change does not overwrite a local pending snapshot; it is reported as a conflict")
    func remoteConflictDoesNotOverwriteLocalPending() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("conflict-a")
        let dirB = try Fixtures.makeTempDirectory("conflict-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        // Shared starting point.
        let baseOutcome = try await deviceA.commit(snapshot: Fixtures.snapshot())
        guard case .pushed(let base) = baseOutcome else { return }
        _ = await deviceB.synchronize()

        // Device B edits locally but goes offline.
        await remote.failNextSaves(1)
        let localEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        let bOutcome = try await deviceB.commit(snapshot: localEdit)
        guard case .failed = bOutcome else {
            Issue.record("Expected B's save to fail, got \(bOutcome)")
            return
        }
        let pendingBefore = await deviceB.currentPending()
        #expect(pendingBefore?.snapshot == localEdit)

        // Meanwhile device A commits on top of the same base.
        let aEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)
        let aOutcome = try await deviceA.commit(snapshot: aEdit)
        guard case .pushed = aOutcome else {
            Issue.record("Expected A to push, got \(aOutcome)")
            return
        }

        // Device B syncs. It must NOT adopt A's snapshot over its own edit.
        let bSync = await deviceB.synchronize()
        guard case .conflict(let report) = bSync else {
            Issue.record("Expected a conflict on B, got \(bSync)")
            return
        }
        #expect(report.localPending?.snapshot == localEdit)
        #expect(report.remote.snapshot == aEdit)
        #expect(report.localBaseline?.revision == base.revision)
        // The local pending content is still exactly what the user entered.
        #expect(await deviceB.currentPending()?.snapshot == localEdit)
        // And the remote is untouched by the conflicting device.
        #expect(await remote.currentDocument()?.snapshot == aEdit)
        #expect(await remote.commitCount == 2)
    }

    @Test("Resolving with keepLocal preserves local content and rebases it onto the remote revision")
    func explicitKeepLocalResolution() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("resolve-keep-a")
        let dirB = try Fixtures.makeTempDirectory("resolve-keep-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        guard case .pushed(let base) = try await deviceA.commit(snapshot: Fixtures.snapshot()) else { return }
        _ = await deviceB.synchronize()

        await remote.failNextSaves(1)
        let localEdit = Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        _ = try await deviceB.commit(snapshot: localEdit)

        guard case .pushed(let remoteEdit) = try await deviceA.commit(
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)
        ) else { return }

        guard case .conflict = await deviceB.synchronize() else {
            Issue.record("Expected a conflict before resolution.")
            return
        }

        // The explicit human choice: keep what this device has.
        let resolved = try await deviceB.resolveConflict(.keepLocal)
        guard case .pushed(let finalDocument) = resolved else {
            Issue.record("Expected keepLocal to push, got \(resolved)")
            return
        }
        #expect(finalDocument.parentRevision == remoteEdit.revision,
                "The kept local content must now descend from the remote revision.")
        #expect(finalDocument.snapshot == localEdit, "The user's local content is preserved exactly.")
        #expect(await deviceB.currentPending() == nil)
        #expect(await remote.currentDocument()?.snapshot == localEdit)
    }

    @Test("Resolving with acceptRemote is the only path that discards a local pending snapshot")
    func explicitAcceptRemoteResolution() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("resolve-remote-a")
        let dirB = try Fixtures.makeTempDirectory("resolve-remote-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        guard case .pushed(let base) = try await deviceA.commit(snapshot: Fixtures.snapshot()) else { return }
        _ = await deviceB.synchronize()

        await remote.failNextSaves(1)
        _ = try await deviceB.commit(
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        )
        guard case .pushed(let remoteEdit) = try await deviceA.commit(
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)
        ) else { return }

        guard case .conflict = await deviceB.synchronize() else {
            Issue.record("Expected a conflict.")
            return
        }

        let resolved = try await deviceB.resolveConflict(.acceptRemote)
        guard case .remoteAvailable(let adopted) = resolved else {
            Issue.record("Expected acceptRemote to yield the remote snapshot, got \(resolved)")
            return
        }
        #expect(adopted.revision == remoteEdit.revision)
        #expect(await deviceB.currentPending() == nil, "acceptRemote is an explicit discard.")
        #expect(await deviceB.currentBaseline()?.revision == remoteEdit.revision)
        // The local edit really is gone, because a human chose that.
        #expect(await deviceB.currentBaseline()?.snapshot == remoteEdit.snapshot)
    }

    @Test("Resolving with replaceLocal commits an explicitly merged snapshot")
    func explicitReplaceLocalResolution() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("resolve-merge-a")
        let dirB = try Fixtures.makeTempDirectory("resolve-merge-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        guard case .pushed(let base) = try await deviceA.commit(snapshot: Fixtures.snapshot()) else { return }
        _ = await deviceB.synchronize()

        await remote.failNextSaves(1)
        _ = try await deviceB.commit(
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolB, base: base.snapshot)
        )
        guard case .pushed(let remoteEdit) = try await deviceA.commit(
            snapshot: Fixtures.snapshotWithAddedSymbol(Fixtures.symbolC, base: base.snapshot)
        ) else { return }

        guard case .conflict(let report) = await deviceB.synchronize() else {
            Issue.record("Expected a conflict.")
            return
        }

        // A caller-supplied merge: both edits survive, committed as one revision.
        let merged = Fixtures.snapshot(
            symbols: [Fixtures.symbolA, Fixtures.symbolB, Fixtures.symbolC]
        )
        let resolved = try await deviceB.resolveConflict(.replaceLocal(with: merged))
        guard case .pushed(let document) = resolved else {
            Issue.record("Expected replaceLocal to push, got \(resolved)")
            return
        }
        #expect(document.snapshot == merged)
        #expect(document.parentRevision == remoteEdit.revision)
        #expect(report.remote.revision == remoteEdit.revision)
    }

    // MARK: - Transaction identity

    @Test("Same price and size with different transaction IDs are two distinct facts")
    func identicalTradesWithDifferentIDsAreDistinct() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("trades-a")
        let dirB = try Fixtures.makeTempDirectory("trades-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        // Two independently recorded fills of the same price and size.
        let firstFill = Fixtures.transaction(price: 100, quantity: 10)
        let secondFill = Fixtures.transaction(price: 100, quantity: 10)
        #expect(firstFill.id != secondFill.id)

        let snapshotA = Fixtures.snapshot(transactions: [Fixtures.symbolA: [firstFill]])
        guard case .pushed(let pushedFirst) = try await deviceA.commit(snapshot: snapshotA) else { return }

        // The second device appends its own distinct fill.
        _ = await deviceB.synchronize()
        let snapshotB = Fixtures.snapshot(
            transactions: [Fixtures.symbolA: [firstFill, secondFill]]
        )
        let outcomeB = try await deviceB.commit(snapshot: snapshotB)
        guard case .pushed = outcomeB else {
            Issue.record("Expected the second fill to commit, got \(outcomeB)")
            return
        }

        let final = await remote.currentDocument()?.snapshot
        let transactions = final?.items.first(where: { $0.symbol == Fixtures.symbolA })?.transactions ?? []
        #expect(transactions.count == 2,
                "Two same-price same-size fills with different IDs are two facts, not one.")
        #expect(Set(transactions.map(\.id)) == Set([firstFill.id, secondFill.id]))
        #expect(pushedFirst.snapshot.items.first?.transactions.count == 1)
    }

    // MARK: - Atomicity and validation

    @Test("Validation runs before a snapshot is sent, and an invalid one is never queued")
    func invalidSnapshotIsRefusedBeforeQueueing() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("invalid")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)

        // A group referencing a symbol with no matching item fails the same
        // ledger validation the rest of the app uses.
        let bogus = WatchlistSyncSnapshot(
            items: [],
            groups: [WatchlistGroup(name: "Main", symbols: [Fixtures.symbolA])]
        )
        await #expect(throws: (any Error).self) {
            try await coordinator.enqueueLocalChange(snapshot: bogus)
        }
        #expect(await coordinator.currentPending() == nil, "An invalid snapshot must not be queued.")
        #expect(await remote.saveAttempts.isEmpty, "An invalid snapshot must never reach the transport.")
    }

    @Test("The snapshot commits as one document, so a rejected commit leaves no partial remote state")
    func commitIsAtomic() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("atomic")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        // A three-symbol, multi-group snapshot representing trades, plans and
        // accounts together. It is either fully committed or absent.
        let rich = WatchlistSyncSnapshot(
            items: [
                WatchItem(symbol: Fixtures.symbolA, displayName: "Apple",
                          transactions: [Fixtures.transaction(price: 190, quantity: 3)]),
                WatchItem(symbol: Fixtures.symbolB, displayName: "Microsoft"),
                WatchItem(symbol: Fixtures.symbolC, displayName: "NVIDIA"),
            ],
            groups: [
                WatchlistGroup(name: "Main", symbols: [Fixtures.symbolA, Fixtures.symbolB]),
                WatchlistGroup(name: "Watch", symbols: [Fixtures.symbolC]),
            ]
        )
        let outcome = try await coordinator.commit(snapshot: rich)
        guard case .pushed = outcome else {
            Issue.record("Expected the rich snapshot to commit, got \(outcome)")
            return
        }
        let stored = await remote.currentDocument()?.snapshot
        #expect(stored == rich, "The whole snapshot must be present, not a subset.")
        #expect(stored?.items.count == 3)
        #expect(stored?.groups.count == 2)
        #expect(await remote.commitCount == 1, "One snapshot is one commit.")
    }

    @Test("An unreadable remote document is reported as corruption and is never overwritten")
    func corruptRemoteIsNotOverwritten() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("corrupt")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        // Stand in for a remote snapshot that fails local ledger validation.
        let corrupt = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            snapshot: WatchlistSyncSnapshot(
                items: [],
                groups: [WatchlistGroup(name: "Main", symbols: [Fixtures.symbolA])]
            )
        )
        await remote.putExternally(corrupt)

        let outcome = await coordinator.synchronize()
        guard case .failed(let failure) = outcome else {
            Issue.record("Expected a corruption failure, got \(outcome)")
            return
        }
        #expect(failure.kind == .corruptedRemote)
        // It was not applied, and it is still there — not deleted or replaced.
        #expect(await coordinator.currentBaseline() == nil)
        #expect(await remote.currentDocument()?.revision == corrupt.revision)
    }

    @Test("An unconfigured transport is reported as configuration, not as a transient retry")
    func unconfiguredTransportIsConfigurationFailure() async throws {
        let dir = try Fixtures.makeTempDirectory("unconfigured")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: UnconfiguredTransport())
        let outcome = await coordinator.synchronize()
        guard case .failed(let failure) = outcome else {
            Issue.record("Expected a configuration failure, got \(outcome)")
            return
        }
        #expect(failure.kind == .configuration)
        #expect(failure.pending == nil)
    }

    @Test("Clearing a pending change is a separate explicit act, not an error path")
    func discardPendingIsExplicit() async throws {
        let remote = InMemorySnapshotTransport()
        let dir = try Fixtures.makeTempDirectory("discard")
        defer { Fixtures.removeDirectory(dir) }
        let coordinator = try SnapshotCoordinator(directory: dir, transport: remote)
        _ = await coordinator.synchronize()

        await remote.failNextSaves(1)
        let outcome = try await coordinator.commit(snapshot: Fixtures.snapshot())
        guard case .failed = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(await coordinator.currentPending() != nil)
        try await coordinator.discardPendingChange()
        #expect(await coordinator.currentPending() == nil)
        #expect(await remote.currentDocument() == nil)
    }

    @Test("Sharing one directory is not required for isolation: two coordinators keep separate state")
    func separateDirectoriesKeepSeparateState() async throws {
        let remote = InMemorySnapshotTransport()
        let dirA = try Fixtures.makeTempDirectory("iso-a")
        let dirB = try Fixtures.makeTempDirectory("iso-b")
        defer { Fixtures.removeDirectory(dirA); Fixtures.removeDirectory(dirB) }

        let deviceA = try SnapshotCoordinator(directory: dirA, transport: remote)
        let deviceB = try SnapshotCoordinator(directory: dirB, transport: remote)
        _ = await deviceA.synchronize()
        _ = await deviceB.synchronize()

        await remote.failNextSaves(1)
        _ = try await deviceA.commit(snapshot: Fixtures.snapshot(groupName: "OnlyA"))

        #expect(await deviceA.currentPending() != nil)
        #expect(await deviceB.currentPending() == nil,
                "One device's unsent change must not appear in another's state.")
    }
}

/// A transport that is never configured, used to prove the coordinator
/// distinguishes a configuration error from a transient one.
private struct UnconfiguredTransport: SnapshotTransport {
    func fetch() async throws -> RemoteSnapshotRecord {
        throw SnapshotTransportError.notConfigured(reason: "No container was supplied.")
    }

    func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws {
        throw SnapshotTransportError.notConfigured(reason: "No container was supplied.")
    }
}
