#if canImport(CloudKit)
import Foundation
import PulseCore
import CloudKit

/// CloudKit private-database transport for one whole snapshot document.
///
/// Storage shape: **one** record in the user's private database, holding the
/// snapshot as a single `CKAsset`. That shape is deliberate:
///
/// - A snapshot spans watchlist items, trade plans and per-account ledgers. If
///   they were split across records, a partially saved batch would leave the
///   remote internally inconsistent, and there is no cross-record transaction
///   available to fix it. One record makes the batch atomic by construction.
/// - CloudKit gives one `recordChangeTag` per record, which is exactly the
///   compare-and-swap token an optimistic-concurrency protocol needs.
/// - An asset keeps the record small; a JSON snapshot of a real ledger can
///   exceed the inline record size budget.
///
/// **Not claimed:** this type does not, and cannot, tell you that the user has
/// granted iCloud account access, that their private database is reachable, or
/// that their quota allows the write. Those are only knowable by performing a
/// real request against a real account, which this package never does. Callers
/// must surface the actual `CKError` they receive rather than reporting success
/// from configuration alone.
public struct CloudKitSnapshotTransport: SnapshotTransport {
    /// Identity of the single record this transport owns.
    public static let recordType = "PulseSyncSnapshot"
    public static let recordName = "pulse-sync-snapshot-v1"
    public static let assetFieldName = "snapshotAsset"
    public static let revisionFieldName = "revision"
    public static let operationFieldName = "operationID"
    /// The revision the stored document was derived from. Absent on the record
    /// means a nil parent (the first write); a present but undecodable value is
    /// corruption.
    public static let parentFieldName = "parentRevision"
    /// CloudKit rejects record keys beginning with `cloudkit`/`CK`.
    public static let schemaVersion = 1

    public let containerIdentifier: String
    public let databaseScope: CKDatabase.Scope

    private let container: CKContainer
    private let database: CKDatabase
    private let workingDirectory: URL

    /// Creates a transport for one explicit container.
    ///
    /// - Parameters:
    ///   - containerIdentifier: The caller's container, never inferred and never
    ///     defaulted from entitlements. Passing an empty value is a
    ///     configuration error.
    ///   - workingDirectory: A directory this transport owns, used only for the
    ///     temporary files backing `CKAsset`. It must be dedicated to this
    ///     transport; the transport never reads or deletes anything else here.
    ///   - databaseScope: Defaults to `.private`. Sharing a snapshot between
    ///     different iCloud accounts is not supported by this transport.
    /// - Throws: `SnapshotTransportError.notConfigured` when no identifier is
    ///   supplied. No network request is made.
    public init(
        containerIdentifier: String,
        workingDirectory: URL,
        databaseScope: CKDatabase.Scope = .private
    ) throws {
        let trimmed = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SnapshotTransportError.notConfigured(
                reason: "A CloudKit container identifier must be supplied by the caller."
            )
        }
        guard workingDirectory.isFileURL, !workingDirectory.path.isEmpty else {
            throw SnapshotTransportError.notConfigured(reason: "A working directory is required.")
        }
        self.containerIdentifier = trimmed
        self.databaseScope = databaseScope
        self.container = CKContainer(identifier: trimmed)
        self.database = container.database(with: databaseScope)
        self.workingDirectory = workingDirectory.standardizedFileURL
    }

    /// Reads the record and materializes its asset.
    ///
    /// Deliberately performs no writes, no creates and no repairs: a `fetch` that
    /// silently created or fixed a record could hide a configuration problem and
    /// would make a read-only check destructive.
    public func fetch() async throws -> RemoteSnapshotRecord {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: Self.recordName))
            return try Self.materialize(record)
        } catch let error as CKError {
            if error.code == .unknownItem {
                // The record has never been created. This is a legitimate empty
                // remote, not a failure.
                return RemoteSnapshotRecord(document: nil, changeToken: nil)
            }
            // Every other error goes through the shared mapping, so an account
            // or permission problem is never mislabeled as a retryable
            // transient outage.
            throw Self.transportError(from: error)
        }
    }

    /// Commits `document` only when the record's change tag still matches what
    /// the caller last observed.
    ///
    /// CloudKit has no conditional-write parameter, so the precondition is
    /// enforced by reading the current record, comparing it to the expected
    /// revision, and saving with `.ifServerRecordUnchanged`. A racing writer
    /// causes `serverRecordChanged`, which is mapped to a real conflict
    /// carrying the current record.
    ///
    /// An existing record is always fully materialized — metadata *and* asset
    /// payload decoded and checked — before any overwrite is attempted. A
    /// record that cannot be read back consistently is reported as
    /// `.corruptRemote` and is never silently replaced by new content.
    public func save(_ document: SnapshotDocument, expecting expectedRevision: UUID?) async throws {
        let existing: CKRecord?
        do {
            existing = try await database.record(for: CKRecord.ID(recordName: Self.recordName))
        } catch let error as CKError where error.code == .unknownItem {
            existing = nil
        } catch let error as CKError {
            throw Self.transportError(from: error)
        }

        if let existing {
            // Materialize *before* deciding anything: a record whose metadata
            // or payload is unreadable must surface as corruption, never be
            // overwritten by newer content it might still be the only copy of.
            // A corrupt remote throws here and the save refuses to proceed.
            let current = try Self.materialize(existing)
            let remoteRevision = current.document?.revision
            guard remoteRevision == expectedRevision else {
                throw SnapshotTransportError.conflict(
                    current: current,
                    reason: "The remote holds revision \(remoteRevision?.uuidString ?? "none"); this device expected \(expectedRevision?.uuidString ?? "none")."
                )
            }
        } else if expectedRevision != nil {
            // We expected to overwrite something and it is gone. Report rather
            // than silently re-creating.
            throw SnapshotTransportError.conflict(
                current: RemoteSnapshotRecord(document: nil, changeToken: nil),
                reason: "The remote document was removed by another device."
            )
        }

        // The asset file must exist for the duration of the save, then be
        // removed. The URL comes only from our own asset staging call.
        let assetURL = try writeAssetFile(for: document)
        defer { removeIfOwned(assetURL) }

        let record = existing ?? CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(recordName: Self.recordName)
        )
        Self.applyMetadata(of: document, to: record)
        record[Self.assetFieldName] = CKAsset(fileURL: assetURL)

        do {
            // Always `.ifServerRecordUnchanged`, and `atomically: true`: a create
            // and an update both require that the server record is exactly what
            // we last observed. Using a policy that overwrote unconditionally
            // would defeat the optimistic concurrency this transport exists to
            // provide, and a non-atomic batch could persist a record the server
            // never agreed to.
            let results = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: CKModifyRecordsOperation.RecordSavePolicy.ifServerRecordUnchanged,
                atomically: true
            )
            // `modifyRecords` reports failures per record and only throws for
            // the whole batch, so the per-record result must be inspected or a
            // rejected save would look like a success.
            if let outcome = results.saveResults[record.recordID] {
                switch outcome {
                case .success:
                    break
                case .failure(let error):
                    throw error
                }
            }
        } catch let error as CKError {
            if error.code == .serverRecordChanged {
                // The canonical optimistic-concurrency race. Report the current
                // server record so the coordinator can reconcile. A server
                // record that cannot be materialized is corruption, not a
                // mergeable conflict; swallowing its decode error would turn
                // "the remote is unreadable" into "the remote is empty".
                if let serverRecord = error.serverRecord {
                    let current = try Self.materialize(serverRecord)
                    throw SnapshotTransportError.conflict(
                        current: current,
                        reason: "Another device changed the remote during this save."
                    )
                }
                let current = try await fetch()
                throw SnapshotTransportError.conflict(
                    current: current,
                    reason: "Another device changed the remote during this save."
                )
            }
            throw Self.transportError(from: error)
        }
    }

    // MARK: - Asset staging

    /// Writes the snapshot JSON to a fresh file in this transport's own
    /// directory and returns verified absolute path.
    private func writeAssetFile(for document: SnapshotDocument) throws -> URL {
        let data: Data
        do {
            data = try WatchlistSyncWireCodec.encode(
                deviceID: "pulse-cloudkit-transport",
                updatedAt: document.createdAt,
                snapshot: document.snapshot
            )
        } catch {
            throw SnapshotTransportError.rejected(reason: "The snapshot cannot be encoded: \(error)")
        }
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        let url = workingDirectory
            .appendingPathComponent("snapshot-\(document.revision.uuidString).json", isDirectory: false)
        guard owns(url) else {
            throw SnapshotTransportError.rejected(reason: "Refusing to write outside the transport directory.")
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw SnapshotTransportError.offline(reason: "The asset file could not be written: \(error)")
        }
        return url
    }

    /// True only for a resolved absolute path that is one of this transport's
    /// own staging files. Every removal is gated on this.
    ///
    /// The check is deliberately structural: containment in our directory, a
    /// direct child (no further traversal), and the exact filename prefix we
    /// generate. A symlink or a `..` segment cannot satisfy all three.
    func owns(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, !candidate.path.isEmpty else { return false }
        let resolved = candidate.standardizedFileURL
        guard resolved.path.hasPrefix(workingDirectory.path + "/") else { return false }
        guard resolved.deletingLastPathComponent().path == workingDirectory.path else { return false }
        return resolved.lastPathComponent.hasPrefix("snapshot-")
            && resolved.pathExtension == "json"
    }

    private func removeIfOwned(_ url: URL) {
        guard owns(url), !url.path.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Record <-> document mapping

    /// Writes the document's identity metadata onto a record. Internal and
    /// static so tests can verify the exact field mapping without any network.
    static func applyMetadata(of document: SnapshotDocument, to record: CKRecord) {
        record[revisionFieldName] = document.revision.uuidString as CKRecordValue
        record[operationFieldName] = document.operationID.uuidString as CKRecordValue
        if let parent = document.parentRevision {
            record[parentFieldName] = parent.uuidString as CKRecordValue
        } else {
            record[parentFieldName] = nil
        }
    }

    /// Decodes a fetched record into a document, checking every piece of
    /// metadata the protocol relies on.
    ///
    /// A record whose revision, operation ID or payload cannot be read back
    /// consistently is corruption: it is reported as `.corruptRemote` so the
    /// caller refuses to overwrite what might be the only copy, rather than
    /// guessing at identities with fabricated UUIDs.
    static func materialize(_ record: CKRecord) throws -> RemoteSnapshotRecord {
        guard let revisionString = record[revisionFieldName] as? String,
              let revision = UUID(uuidString: revisionString) else {
            throw SnapshotTransportError.corruptRemote(
                reason: "The remote record is missing a valid revision."
            )
        }
        guard let operationString = record[operationFieldName] as? String,
              let operationID = UUID(uuidString: operationString) else {
            throw SnapshotTransportError.corruptRemote(
                reason: "The remote record is missing a valid operation ID."
            )
        }
        // A nil parent is stored as an absent field; a present but undecodable
        // one is corruption, because we can no longer say what the document
        // was derived from.
        let parentRevision: UUID?
        if let parentString = record[parentFieldName] as? String {
            guard let parent = UUID(uuidString: parentString) else {
                throw SnapshotTransportError.corruptRemote(
                    reason: "The remote record carries an undecodable parent revision."
                )
            }
            parentRevision = parent
        } else if record[parentFieldName] != nil {
            throw SnapshotTransportError.corruptRemote(
                reason: "The remote record carries an undecodable parent revision."
            )
        } else {
            parentRevision = nil
        }
        guard let asset = record[assetFieldName] as? CKAsset, let fileURL = asset.fileURL else {
            throw SnapshotTransportError.corruptRemote(
                reason: "The remote record has no snapshot asset."
            )
        }
        // CloudKit materializes the asset into a temporary file it owns; we only
        // ever read it here and never move or delete it.
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw SnapshotTransportError.corruptRemote(reason: "The remote asset could not be read: \(error)")
        }
        let file: WatchlistSyncWireCodec.File
        do {
            file = try WatchlistSyncWireCodec.decode(data)
        } catch {
            throw SnapshotTransportError.corruptRemote(reason: "The remote snapshot could not be decoded: \(error)")
        }
        let document = SnapshotDocument(
            revision: revision,
            parentRevision: parentRevision,
            operationID: operationID,
            createdAt: file.updatedAt,
            snapshot: file.snapshot
        )
        return RemoteSnapshotRecord(
            document: document,
            changeToken: record.recordChangeTag
        )
    }

    // MARK: - Error mapping

    /// Maps a `CKError` to the transport's error taxonomy. Static and pure so
    /// the classification is testable without any network access.
    ///
    /// The classification is the contract callers rely on: account, permission,
    /// entitlement and container problems are `.notConfigured` — retrying can
    /// never sign a user in or fix a provisioning profile, so they must not be
    /// reported as a retryable `.offline`.
    static func transportError(from error: CKError) -> SnapshotTransportError {
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable,
             .operationCancelled:
            return .offline(reason: describe(error))
        case .notAuthenticated, .managedAccountRestricted, .missingEntitlement,
             .badContainer, .invalidArguments, .permissionFailure:
            return .notConfigured(reason: describe(error))
        case .quotaExceeded, .limitExceeded, .partialFailure, .serverRejectedRequest,
             .constraintViolation, .serverResponseLost:
            return .rejected(reason: describe(error))
        default:
            return .offline(reason: describe(error))
        }
    }

    private static func describe(_ error: CKError) -> String {
        "CloudKit \(error.code.rawValue): \(error.localizedDescription)"
    }
}
#endif
