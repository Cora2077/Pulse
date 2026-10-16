import Foundation
import PulseCore

/// A revisioned, whole-snapshot synchronization document.
///
/// One document carries an entire `WatchlistSyncSnapshot`. Sync never sends a
/// partial delta: a batch that landed half-applied would leave trades, plans and
/// account ledgers disagreeing with each other, so the unit of transfer is the
/// complete snapshot plus the revision metadata needed to reject a stale writer.
public struct SnapshotDocument: Sendable, Equatable, Codable {
    /// Identity of this exact document version.
    public var revision: UUID
    /// The revision this document was derived from. `nil` means "created from
    /// nothing", which is how the very first write to an empty remote is
    /// expressed — and why two devices racing to create it can both present a
    /// nil parent and still be told that exactly one of them won.
    public var parentRevision: UUID?
    /// Stable identity of the local user operation that produced this document.
    /// Retries reuse it, so a transport that already committed the operation can
    /// recognize the resend instead of creating a second fact.
    public var operationID: UUID
    /// When the producing device created this revision.
    public var createdAt: Date
    /// The full payload.
    public var snapshot: WatchlistSyncSnapshot

    public init(
        revision: UUID = UUID(),
        parentRevision: UUID?,
        operationID: UUID,
        createdAt: Date = .now,
        snapshot: WatchlistSyncSnapshot
    ) {
        self.revision = revision
        self.parentRevision = parentRevision
        self.operationID = operationID
        self.createdAt = createdAt
        self.snapshot = snapshot
    }
}

/// The exact two versions a human saw in a conflict-resolution confirmation.
/// An explicit nil is meaningful, so this travels as a value rather than using
/// nil arguments to mean both "empty" and "unchecked".
public struct SnapshotConflictExpectation: Sendable, Equatable {
    public var remoteRevision: UUID?
    public var pendingRevision: UUID?
    public init(remoteRevision: UUID?, pendingRevision: UUID?) {
        self.remoteRevision = remoteRevision
        self.pendingRevision = pendingRevision
    }
}

/// What a local edit claims about the revision it was derived from.
///
/// The distinction between the two cases is the whole point: `.currentBaseline`
/// means "whatever the coordinator's baseline is at the moment the change is
/// enqueued", while `.exact` freezes the caller's knowledge — including
/// `.exact(nil)`, an explicit claim that the remote was *empty* when the edit
/// was made. An explicit claim is never silently rebased: if the confirmed
/// baseline has moved past it by the time the change is pushed, the push is
/// refused as a conflict instead of overwriting the newer remote revision.
public enum SnapshotParentExpectation: Sendable, Equatable {
    /// Derive from whatever baseline is current when the change is enqueued.
    case currentBaseline
    /// Derive from exactly this revision — `nil` asserts the remote was empty.
    /// Callers that freeze the applied baseline at the moment of the user's
    /// edit (rather than at the moment the enqueue happens to run) pass that
    /// frozen value here.
    case exact(UUID?)
}

/// What a transport reports about the remote document.
public struct RemoteSnapshotRecord: Sendable, Equatable {
    /// `nil` when the remote has never been written.
    public var document: SnapshotDocument?
    /// Opaque per-record version used for compare-and-swap. A transport
    /// implementation can map this to a CloudKit `recordChangeTag`; an
    /// in-memory transport can use the revision itself. It is deliberately not
    /// interpreted by the coordinator beyond passing it back to `save`.
    public var changeToken: String?

    public init(document: SnapshotDocument?, changeToken: String?) {
        self.document = document
        self.changeToken = changeToken
    }
}

/// Errors a transport can raise, split by what the caller should do about them.
///
/// The distinction is not cosmetic: an unreachable network is retried, a
/// conflicting writer is resolved by the user, and a misconfigured container is
/// never retried automatically because retrying cannot fix it.
public enum SnapshotTransportError: Error, Sendable, Equatable {
    /// The transport was not given the information it needs (for example no
    /// CloudKit container identifier). Retrying cannot help.
    case notConfigured(reason: String)
    /// The transport is configured but could not be reached, or the request
    /// failed transiently. Retrying the same operation is safe.
    case offline(reason: String)
    /// Another writer changed the remote between fetch and save. The caller must
    /// not retry blindly; this is a real, reported conflict.
    case conflict(current: RemoteSnapshotRecord, reason: String)
    /// The remote document exists but could not be decoded or is invalid, so
    /// writing over it would destroy data. Never auto-recovered.
    case corruptRemote(reason: String)
    /// The transport rejected data because it is not valid to send. Retrying the
    /// same bytes cannot succeed.
    case rejected(reason: String)
}

extension SnapshotTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let reason): "Sync is not configured: \(reason)"
        case .offline(let reason): "Sync is temporarily unavailable: \(reason)"
        case .conflict(_, let reason): "Sync conflict: \(reason)"
        case .corruptRemote(let reason): "The remote sync data is unreadable: \(reason)"
        case .rejected(let reason): "Sync rejected the data: \(reason)"
        }
    }

    /// Only genuinely transient failures may be retried without user input.
    public var isRetryable: Bool {
        if case .offline = self { return true }
        return false
    }
}

/// A compare-and-swap remote for one whole snapshot document.
///
/// Implementations must be safe to call from any task. No implementation may
/// perform real network work in `init`: construction happens in application
/// startup paths and must stay free of side effects.
public protocol SnapshotTransport: Sendable {
    /// Reads the current remote document.
    func fetch() async throws -> RemoteSnapshotRecord

    /// Commits `document` only if the remote still holds `expectedRevision`.
    ///
    /// - Parameter expectedRevision: `nil` asserts "the remote is empty" and is
    ///   how a first write is performed and how a create race is detected.
    /// - Throws: `.conflict` when the remote moved on, carrying the current
    ///   record so the caller can reconcile without a second round trip.
    func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws
}

/// Result of committing a local change against the remote.
public enum SyncOutcome: Sendable, Equatable {
    /// Our document is now the remote document.
    case pushed(SnapshotDocument)
    /// The local change was already committed under this operation ID, and
    /// resending it is a no-op. `remote` is the document the remote holds.
    case alreadyUpToDate(remote: SnapshotDocument?)
    /// The remote moved on. Nothing local was discarded.
    case conflict(ConflictReport)
    /// The remote holds a document we have not applied yet.
    case remoteAvailable(SnapshotDocument)
    /// Nothing to do: no local change and no remote change.
    case inSync(remote: SnapshotDocument?)
    /// The attempt failed and the pending change was kept verbatim.
    case failed(SyncFailure)
}

/// A reported conflict. Deliberately conservative: the coordinator does not
/// attempt a last-writer-wins merge of two diverged snapshots.
public struct ConflictReport: Sendable, Equatable {
    /// The remote document that blocked us.
    public var remote: SnapshotDocument
    /// The local pending document we refused to discard, if there was one.
    public var localPending: SnapshotDocument?
    /// Human-readable explanation for display.
    public var reason: String
    /// The baseline the local side was derived from, for explicit resolution.
    public var localBaseline: SnapshotDocument?

    public init(
        remote: SnapshotDocument,
        localPending: SnapshotDocument?,
        reason: String,
        localBaseline: SnapshotDocument?
    ) {
        self.remote = remote
        self.localPending = localPending
        self.reason = reason
        self.localBaseline = localBaseline
    }
}

/// Why an attempt failed, in a form the caller can surface.
public struct SyncFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Transient; retrying the same operation ID is correct.
        case transient
        /// Needs configuration before it can ever succeed.
        case configuration
        /// The remote data is unreadable; automatic progress is unsafe.
        case corruptedRemote
        /// The remote rejected the payload.
        case rejected
        /// Something unexpected. Retained deliberately rather than swallowed.
        case unknown
    }

    public var kind: Kind
    public var message: String
    /// The pending document that was kept.
    public var pending: SnapshotDocument?

    public init(kind: Kind, message: String, pending: SnapshotDocument?) {
        self.kind = kind
        self.message = message
        self.pending = pending
    }
}

/// How the caller resolves a reported conflict. There is no automatic policy:
/// a human (or an explicit product decision) must pick one.
public enum ConflictResolution: Sendable, Equatable {
    /// Keep the local pending snapshot and force it to become the next
    /// revision on top of whatever the remote currently holds.
    case keepLocal
    /// Discard the local pending snapshot and adopt the remote one.
    case acceptRemote
    /// Replace the local snapshot with an explicitly chosen snapshot, which is
    /// how a merge UI's output is committed.
    case replaceLocal(with: WatchlistSyncSnapshot)
}
