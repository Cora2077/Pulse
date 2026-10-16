import Foundation
import PulseCore

/// Durable, conflict-explicit coordinator for whole-snapshot synchronization.
///
/// The coordinator owns exactly one caller-provided directory. It is the only
/// thing that decides whether a local change has been committed, and it never
/// overwrites a local pending snapshot with a remote one without an explicit
/// resolution.
///
/// Guarantees, in the order they matter:
/// 1. **No silent loss.** A pending local snapshot survives offline failures,
///    conflicts and process restarts. Nothing clears it except an explicit
///    resolution or a confirmed commit — and a commit is only treated as
///    confirmed for the exact document the remote acknowledged, never for a
///    newer edit enqueued while the network call was in flight.
/// 2. **Explicit conflict.** If the remote revision is no longer the revision
///    the local change was derived from, the coordinator reports a conflict and
///    stops. It does not merge, and it does not pick a winner.
/// 3. **Atomicity.** The snapshot is committed as one document. A commit is
///    observed as complete or not at all; there is no partial state in which
///    trades landed but plans did not.
/// 4. **Honest retries.** Reusing an operation ID is only treated as "already
///    committed" when the content also matches. Same operation ID with different
///    content is an error, not an idempotent success.
/// 5. **Honest persistence.** A state write that fails is reported as a
///    failure; it never silently coexists with a success outcome, and it never
///    clears a pending change it failed to record.
public actor SnapshotCoordinator {
    private let directory: URL
    private let store: SyncStateStore
    private var transport: SnapshotTransport
    private var state: SyncState
    private var lastFailure: SyncFailure?

    /// Creates a coordinator bound to `directory`.
    ///
    /// The directory is created on first use. Nothing is written and no network
    /// call is made here beyond reading any previously persisted state, so this
    /// is safe to call during application startup.
    ///
    /// - Parameters:
    ///   - directory: A directory dedicated to this coordinator. The caller
    ///     owns it; it is never a shared or generic location.
    ///   - transport: The compare-and-swap remote. Constructing the transport
    ///     must not perform network work.
    public init(directory: URL, transport: SnapshotTransport) throws {
        try self.init(directory: directory, transport: transport, stateStore: SyncStateStore(directory: directory))
    }

    /// Test-only entry point: allows injecting a store with a failure hook so
    /// persistence failures can be simulated deterministically.
    init(directory: URL, transport: SnapshotTransport, stateStore: SyncStateStore) throws {
        self.directory = directory.standardizedFileURL
        self.store = stateStore
        self.transport = transport
        // A crash between "wrote pending" and "wrote committed" must not lose the
        // pending change, so durable state is the source of truth at startup.
        self.state = try stateStore.load()
    }

    /// Swaps the transport, e.g. after the user reconfigures a container.
    /// Existing durable state is untouched.
    public func setTransport(_ transport: SnapshotTransport) {
        self.transport = transport
    }

    public func currentBaseline() -> SnapshotDocument? { state.baseline }
    public func currentPending() -> SnapshotDocument? { state.pending }
    public func mostRecentFailure() -> SyncFailure? { lastFailure }
    public var workingDirectory: URL { directory }

    /// Records a local edit: the caller edited the snapshot and wants it synced.
    ///
    /// - Parameters:
    ///   - snapshot: The complete new snapshot. It is validated before being
    ///     accepted, so an invalid candidate never becomes a pending change.
    ///   - operationID: Stable across retries of the *same* user operation.
    ///     Reuse it when retrying; generate a fresh one for a new edit.
    ///   - parentExpectation: What the edit claims to descend from.
    ///     `.currentBaseline` freezes the baseline as it is right now;
    ///     `.exact` freezes a caller-supplied revision — including
    ///     `.exact(nil)`, an explicit claim that the remote was empty when the
    ///     user made the edit. An explicit claim is never silently rebased:
    ///     if the confirmed base has moved by push time, the push conflicts.
    /// - Returns: The pending document now held durably.
    @discardableResult
    public func enqueueLocalChange(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentExpectation: SnapshotParentExpectation,
        createdAt: Date = .now
    ) throws -> SnapshotDocument {
        let parent: UUID?
        switch parentExpectation {
        case .currentBaseline:
            parent = state.baseline?.revision
        case .exact(let frozenRevision):
            parent = frozenRevision
        }
        return try enqueue(snapshot: snapshot, operationID: operationID, parent: parent, createdAt: createdAt)
    }

    /// Compatibility form of `enqueueLocalChange(snapshot:operationID:parentExpectation:createdAt:)`.
    ///
    /// `parentRevision: nil` keeps the historical meaning of "whatever the
    /// baseline is now" (i.e. `.currentBaseline`); a non-nil value is an
    /// explicit claim equivalent to `.exact(parentRevision)`.
    @discardableResult
    public func enqueueLocalChange(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentRevision: UUID? = nil,
        createdAt: Date = .now
    ) throws -> SnapshotDocument {
        let expectation: SnapshotParentExpectation = parentRevision.map { .exact($0) } ?? .currentBaseline
        return try enqueueLocalChange(
            snapshot: snapshot,
            operationID: operationID,
            parentExpectation: expectation,
            createdAt: createdAt
        )
    }

    private func enqueue(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID,
        parent: UUID?,
        createdAt: Date
    ) throws -> SnapshotDocument {
        try Self.validate(snapshot)

        // Re-enqueuing the identical operation is a no-op, so a caller that
        // retries after an ambiguous failure does not manufacture a new
        // revision. Different content under the same operation ID is refused:
        // it is a caller bug, and treating it as idempotent would silently drop
        // the second edit.
        if let existing = state.pending, existing.operationID == operationID {
            if existing.snapshot == snapshot, existing.parentRevision == parent {
                return existing
            }
            throw CoordinatorError.operationIDReusedWithDifferentContent(operationID: operationID)
        }

        let document = SnapshotDocument(
            parentRevision: parent,
            operationID: operationID,
            createdAt: createdAt,
            snapshot: snapshot
        )
        var next = state
        next.pending = document
        // A pending change that cannot be persisted must not be queued at all:
        // throwing here means the caller keeps its draft and nothing pretends
        // to be durable that is not.
        try store.save(next)
        state = next
        return document
    }

    /// Fetches the remote document and reconciles it with local durable state.
    ///
    /// This is the read half of sync: it applies nothing to the app. It returns
    /// which remote snapshots are available for the caller to apply, and reports
    /// conflicts rather than resolving them.
    ///
    /// Reentrancy rule: only the pending change this call already saw when it
    /// started may be settled or pushed by its completion. An edit enqueued
    /// while the fetch was in flight is left durable pending for the caller's
    /// own push path; this call neither discards it nor commits a change it
    /// never saw.
    public func synchronize() async -> SyncOutcome {
        let entryPendingRevision = state.pending?.revision
        let remote: RemoteSnapshotRecord
        do {
            remote = try await transport.fetch()
        } catch {
            return recordFailure(error)
        }

        // Whether the pending queue changed while the fetch was in flight. An
        // acknowledgement for the old world must never clear or commit an edit
        // that arrived after this call began.
        func pendingChangedInFlight() -> Bool {
            state.pending?.revision != entryPendingRevision
        }

        guard let remoteDocument = remote.document else {
            // Remote is empty. Anything pending is still ours to create, and the
            // create must be attempted with a nil expectation so a racing device
            // is detected by the compare-and-swap rather than overwritten.
            var next = state
            next.hasFetchedRemote = true
            next.baseline = nil
            do {
                try store.save(next)
            } catch {
                return persistFailure(error)
            }
            state = next
            if state.pending != nil, !pendingChangedInFlight() {
                return await pushPending()
            }
            return .inSync(remote: nil)
        }

        // A remote document whose content fails local validation is never
        // applied and never overwritten; it is reported as corruption.
        do {
            try Self.validate(remoteDocument.snapshot)
        } catch {
            return recordFailure(SnapshotTransportError.corruptRemote(
                reason: "The remote snapshot failed local validation: \(error)"
            ))
        }

        if let pending = state.pending {
            if pending.operationID == remoteDocument.operationID, pending.snapshot == remoteDocument.snapshot {
                // Our write actually landed; the confirmation was lost. Settle
                // the operation rather than resending it. This matches on the
                // *current* pending document's own identity, so a newer edit
                // enqueued mid-flight — which has a different operation and
                // content — can never reach this branch and be cleared by it.
                var next = state
                next.baseline = remoteDocument
                next.pending = nil
                next.hasFetchedRemote = true
                do {
                    try store.save(next)
                } catch {
                    return persistFailure(error)
                }
                state = next
                lastFailure = nil
                return .alreadyUpToDate(remote: remoteDocument)
            }
            if pending.operationID == remoteDocument.operationID {
                // Same operation, different content: refuse rather than guess.
                // Reporting a conflict keeps the local bytes intact and visible.
                lastFailure = nil
                return .conflict(ConflictReport(
                    remote: remoteDocument,
                    localPending: pending,
                    reason: "The remote revision claims this operation ID with different content.",
                    localBaseline: state.baseline
                ))
            }
            if pending.parentRevision != remoteDocument.revision {
                // The remote moved on underneath us. Keep everything, report.
                lastFailure = nil
                return .conflict(ConflictReport(
                    remote: remoteDocument,
                    localPending: pending,
                    reason: "The remote revision changed since this device last synced.",
                    localBaseline: state.baseline
                ))
            }
            // The pending change descends from the current remote revision.
            var next = state
            next.baseline = remoteDocument
            next.hasFetchedRemote = true
            do {
                try store.save(next)
            } catch {
                return persistFailure(error)
            }
            state = next
            if pendingChangedInFlight() {
                // The edit arrived while the fetch was in flight; synchronize
                // is the read half of sync and must not commit a change it
                // never saw at entry. It stays durable pending for the
                // caller's explicit push.
                return .inSync(remote: remoteDocument)
            }
            return await pushPending()
        }

        var next = state
        next.hasFetchedRemote = true
        next.baseline = remoteDocument
        do {
            try store.save(next)
        } catch {
            return persistFailure(error)
        }
        state = next
        lastFailure = nil
        return .remoteAvailable(remoteDocument)
    }

    /// Commits the pending local change to the remote.
    ///
    /// Fails closed: on any error the pending document is retained byte for byte
    /// and the queue is never pruned automatically.
    ///
    /// The compare-and-swap expectation is always the pending document's own
    /// recorded `parentRevision` — the revision the user actually edited
    /// against — never whatever the baseline happens to be now. If the two
    /// disagree, the local change descends from a revision the remote no longer
    /// holds, and that is reported as a conflict instead of being pushed with a
    /// silently rewritten parent.
    @discardableResult
    public func pushPending() async -> SyncOutcome {
        guard let pending = state.pending else {
            return .inSync(remote: state.baseline)
        }
        // Re-validate immediately before sending. The snapshot was validated on
        // enqueue, but a different build or a restored file could have changed
        // the rules; sending unvalidated data would let one device apply
        // something the receiving device cannot ledgers-check.
        do {
            try Self.validate(pending.snapshot)
        } catch {
            return recordFailure(SnapshotTransportError.rejected(
                reason: "The pending snapshot is not valid to send: \(error)"
            ))
        }

        // The pending change must descend from the last confirmed base. If the
        // baseline has moved since the edit was recorded, pushing with the
        // current baseline's revision would silently relabel the edit's parent
        // — claiming the user edited against content they never saw. Refuse
        // explicitly instead; the caller can rebase via resolveConflict.
        guard pending.parentRevision == state.baseline?.revision else {
            lastFailure = nil
            return .conflict(ConflictReport(
                remote: state.baseline ?? pending,
                localPending: pending,
                reason: "This change was made against a revision that is no longer the confirmed base; it needs an explicit rebase, not an overwrite.",
                localBaseline: state.baseline
            ))
        }

        let expected = pending.parentRevision
        do {
            try await transport.save(pending, expecting: expected)
        } catch let error as SnapshotTransportError {
            if case .conflict(let current, _) = error {
                lastFailure = nil
                if current.document?.operationID == pending.operationID,
                   current.document?.snapshot == pending.snapshot {
                    // The write did land; the conflict report is a stale tag.
                    // Settle only the document this call actually sent: a newer
                    // pending edit enqueued during the await is kept.
                    var next = state
                    next.baseline = current.document
                    if next.pending?.revision == pending.revision {
                        next.pending = nil
                    }
                    do {
                        try store.save(next)
                    } catch {
                        return persistFailure(error)
                    }
                    state = next
                    return .alreadyUpToDate(remote: current.document)
                }
                return .conflict(ConflictReport(
                    remote: current.document ?? pending,
                    localPending: pending,
                    reason: "The remote was changed by another device during this save.",
                    localBaseline: state.baseline
                ))
            }
            return recordFailure(error)
        } catch {
            return recordFailure(error)
        }

        // The remote confirmed this exact document. Re-read state: a newer
        // local edit may have been enqueued while the save was in flight, and
        // this older acknowledgement must never clear it.
        var next = state
        next.baseline = pending
        if next.pending?.revision == pending.revision {
            next.pending = nil
        }
        do {
            try store.save(next)
        } catch {
            // The commit landed remotely but the acknowledgement could not be
            // persisted. Reporting success would make an undurable state look
            // settled; instead report the failure and keep the pending change,
            // which a later synchronize() settles via the lost-confirmation
            // path (same operation ID, same content).
            return persistFailure(error)
        }
        state = next
        lastFailure = nil
        return .pushed(pending)
    }

    /// Enqueues and pushes in one step, used when the caller knows the new
    /// snapshot and wants it sent.
    @discardableResult
    public func commit(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentExpectation: SnapshotParentExpectation
    ) async throws -> SyncOutcome {
        _ = try enqueueLocalChange(
            snapshot: snapshot,
            operationID: operationID,
            parentExpectation: parentExpectation
        )
        return await pushPending()
    }

    /// Compatibility form of `commit(snapshot:operationID:parentExpectation:)`.
    /// `parentRevision: nil` means `.currentBaseline`.
    @discardableResult
    public func commit(
        snapshot: WatchlistSyncSnapshot,
        operationID: UUID = UUID(),
        parentRevision: UUID? = nil
    ) async throws -> SyncOutcome {
        _ = try enqueueLocalChange(
            snapshot: snapshot,
            operationID: operationID,
            parentRevision: parentRevision
        )
        return await pushPending()
    }

    /// Resolves a reported conflict. This is the only path that may discard a
    /// local pending snapshot.
    ///
    /// - Parameter resolution: The explicit choice. There is no default.
    /// - Returns: The outcome of applying that choice.
    @discardableResult
    public func resolveConflict(_ resolution: ConflictResolution,
                                expecting expectation: SnapshotConflictExpectation? = nil,
                                validateConfirmation: (@Sendable () async -> Bool)? = nil) async throws -> SyncOutcome {
        let entryPendingRevision = state.pending?.revision
        // A resolution is made against the remote as it is right now, so read it
        // fresh rather than trusting a possibly stale report.
        let remote: RemoteSnapshotRecord
        do {
            remote = try await transport.fetch()
        } catch {
            return recordFailure(error)
        }
        let confirmationStillValid = await validateConfirmation?() ?? true
        if !confirmationStillValid || state.pending?.revision != entryPendingRevision
            || expectation.map({ $0.remoteRevision != remote.document?.revision
                || $0.pendingRevision != state.pending?.revision }) == true {
            guard let document = remote.document else {
                return recordFailure(SnapshotTransportError.rejected(reason: "The versions shown in the confirmation changed; nothing was resolved."))
            }
            return .conflict(ConflictReport(remote: document, localPending: state.pending,
                reason: "The versions shown in the confirmation changed. Review both sides again.", localBaseline: state.baseline))
        }
        guard let remoteDocument = remote.document else {
            // The remote was cleared underneath us. The local pending change is
            // still valid; recreating it is the only non-destructive option.
            // Because the revision it was derived from no longer exists
            // remotely, the pending change is explicitly rebased onto an empty
            // remote — a deliberate part of this resolution, never a silent
            // relabel.
            var next = state
            next.baseline = nil
            if var pending = next.pending, pending.parentRevision != nil {
                pending.parentRevision = nil
                next.pending = pending
            }
            try store.save(next)
            state = next
            return await pushPending()
        }
        do {
            try Self.validate(remoteDocument.snapshot)
        } catch {
            return recordFailure(SnapshotTransportError.corruptRemote(
                reason: "The remote snapshot failed local validation: \(error)"
            ))
        }

        switch resolution {
        case .acceptRemote:
            // Adopting remote is a deliberate discard of the local pending edit.
            var next = state
            next.baseline = remoteDocument
            next.pending = nil
            next.hasFetchedRemote = true
            try store.save(next)
            state = next
            lastFailure = nil
            return .remoteAvailable(remoteDocument)

        case .keepLocal:
            guard var pending = state.pending ?? state.baseline else {
                return .inSync(remote: remoteDocument)
            }
            // Rebase: the local content is preserved exactly, but it now descends
            // from the remote revision so the compare-and-swap can succeed. The
            // operation ID is kept, because this is still the same user
            // operation being made durable.
            pending.parentRevision = remoteDocument.revision
            pending.revision = UUID()
            var next = state
            next.baseline = remoteDocument
            next.pending = pending
            try store.save(next)
            state = next
            return await pushPending()

        case .replaceLocal(let snapshot):
            try Self.validate(snapshot)
            let operationID = state.pending?.operationID ?? UUID()
            let document = SnapshotDocument(
                parentRevision: remoteDocument.revision,
                operationID: operationID,
                snapshot: snapshot
            )
            var next = state
            next.baseline = remoteDocument
            next.pending = document
            try store.save(next)
            state = next
            return await pushPending()
        }
    }

    /// Clears a pending change without sending it.
    ///
    /// Separate from `resolveConflict` on purpose: discarding unsynced user data
    /// is destructive and must be an explicit, separately named act, so no
    /// automatic error path can reach it.
    public func discardPendingChange() throws {
        var next = state
        next.pending = nil
        try store.save(next)
        state = next
    }

    /// Reads the remote without changing local state, for diagnostics.
    public func peekRemote() async throws -> SnapshotDocument? {
        try await transport.fetch().document
    }

    private func recordFailure(_ error: Error) -> SyncOutcome {
        let failure = Self.failure(from: error, pending: state.pending)
        // Retained, never cleared, and never reordered: the queue is not pruned
        // on failure so no local edit can disappear because a network call had a
        // bad day.
        lastFailure = failure
        return .failed(failure)
    }

    /// A durable-state write failed. The in-memory state is left untouched —
    /// it still describes what the disk actually holds — and the pending change
    /// is never cleared. The outcome is an honest failure, not a success that
    /// would make an undurable state look settled.
    private func persistFailure(_ error: Error) -> SyncOutcome {
        let failure = SyncFailure(
            kind: .unknown,
            message: "Local sync state could not be persisted: \(error)",
            pending: state.pending
        )
        lastFailure = failure
        return .failed(failure)
    }

    static func failure(from error: Error, pending: SnapshotDocument?) -> SyncFailure {
        if let transportError = error as? SnapshotTransportError {
            switch transportError {
            case .notConfigured(let reason):
                return SyncFailure(kind: .configuration, message: reason, pending: pending)
            case .offline(let reason):
                return SyncFailure(kind: .transient, message: reason, pending: pending)
            case .corruptRemote(let reason):
                return SyncFailure(kind: .corruptedRemote, message: reason, pending: pending)
            case .rejected(let reason):
                return SyncFailure(kind: .rejected, message: reason, pending: pending)
            case .conflict(_, let reason):
                return SyncFailure(kind: .unknown, message: reason, pending: pending)
            }
        }
        if let coordinatorError = error as? CoordinatorError {
            return SyncFailure(
                kind: .rejected,
                message: coordinatorError.localizedDescription,
                pending: pending
            )
        }
        // An unclassified error is reported as unknown rather than assumed
        // transient, so a bug is not hidden behind an infinite retry loop.
        return SyncFailure(
            kind: .unknown,
            message: String(describing: error),
            pending: pending
        )
    }

    /// The ledger and wire checks the rest of the app already trusts. Sync does
    /// not get to bypass them, so a snapshot that cannot be encoded for the wire
    /// or fails the ledger invariants is refused here rather than at the peer.
    static func validate(_ snapshot: WatchlistSyncSnapshot) throws {
        _ = try WatchlistSyncWireCodec.encode(deviceID: "pulse-sync-validation", snapshot: snapshot)
        try LocalBackupStore.validateSnapshot(snapshot)
    }
}

/// Errors raised by the coordinator itself (as opposed to the transport).
public enum CoordinatorError: Error, Equatable, LocalizedError {
    /// The same operation ID was presented with different content. Treating
    /// this as an idempotent success would silently drop the second edit.
    case operationIDReusedWithDifferentContent(operationID: UUID)

    public var errorDescription: String? {
        switch self {
        case .operationIDReusedWithDifferentContent(let id):
            "Operation \(id.uuidString) was retried with different content. Retrying the same operation must send identical content."
        }
    }
}
