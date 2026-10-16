import Foundation

/// A deterministic, in-process `SnapshotTransport` for tests and previews.
///
/// It models a single shared remote slot with real compare-and-swap semantics,
/// so a test can reproduce a two-device race, a dropped connection, or a
/// conflicting writer without any network. It is an actor, so concurrent calls
/// from two coordinators serialize exactly as a remote service would.
///
/// It performs no network work in `init` and touches no files on disk.
public actor InMemorySnapshotTransport: SnapshotTransport {
    /// The single shared remote record.
    private var record: RemoteSnapshotRecord = RemoteSnapshotRecord(document: nil, changeToken: nil)

    /// When set, the next fetch throws this and then clears itself, which lets a
    /// test simulate a transient outage without disabling the remote.
    private var fetchFailuresRemaining: Int = 0
    private var saveFailuresRemaining: Int = 0
    private var failure: SnapshotTransportError = .offline(reason: "Simulated outage.")

    /// Every save attempt that reached the remote, in order, for assertions.
    public private(set) var saveAttempts: [SnapshotDocument] = []
    /// Number of successful commits.
    public private(set) var commitCount: Int = 0

    /// Optional park point, used by tests that need a call to be provably
    /// in flight (and reentrancy to be possible) before they proceed.
    private var gate: TransportGate?

    public init() {}

    /// Parks the next matching call inside the transport until the gate opens.
    ///
    /// A test uses this to make an interleaving deterministic: it starts a
    /// coordinator call in a task, waits for the stage to be entered, performs
    /// the competing action, and only then lets the parked call finish.
    public func installGate(_ gate: TransportGate?) {
        self.gate = gate
    }

    /// Makes the next `count` fetches fail with a transient error.
    public func failNextFetches(_ count: Int, error: SnapshotTransportError = .offline(reason: "Simulated outage.")) {
        fetchFailuresRemaining = count
        failure = error
    }

    /// Makes the next `count` saves fail with a transient error.
    public func failNextSaves(_ count: Int, error: SnapshotTransportError = .offline(reason: "Simulated outage.")) {
        saveFailuresRemaining = count
        failure = error
    }

    /// Simulates a failure mode that is not transient, to check that the
    /// coordinator distinguishes it rather than retrying blindly.
    public func failNextFetchesPermanently(_ error: SnapshotTransportError) {
        failure = error
        fetchFailuresRemaining = 1
    }

    /// Inspects the current remote document.
    public func currentDocument() -> SnapshotDocument? { record.document }
    public func currentRecord() -> RemoteSnapshotRecord { record }

    /// Overwrites the remote from outside the coordinator, standing in for a
    /// second device writing directly.
    public func putExternally(_ document: SnapshotDocument?) {
        record = RemoteSnapshotRecord(document: document, changeToken: document.map { $0.revision.uuidString } ?? nil)
    }

    public func fetch() async throws -> RemoteSnapshotRecord {
        await gate?.park(.fetch)
        if fetchFailuresRemaining > 0 {
            fetchFailuresRemaining -= 1
            throw failure
        }
        return record
    }

    public func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws {
        await gate?.park(.save)
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw failure
        }
        saveAttempts.append(document)

        let current = record.document?.revision
        guard current == expectedRevision else {
            // Exactly the CloudKit `serverRecordChanged` case: someone else
            // committed in between, so our expectation is stale.
            throw SnapshotTransportError.conflict(
                current: record,
                reason: "Expected \(expectedRevision?.uuidString ?? "an empty remote") but found \(current?.uuidString ?? "an empty remote")."
            )
        }
        record = RemoteSnapshotRecord(document: document, changeToken: document.revision.uuidString)
        commitCount += 1
    }
}
