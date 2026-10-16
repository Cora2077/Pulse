#if canImport(CloudKit)
import Foundation
import Testing
import CloudKit
import PulseCore
@testable import PulseSync

/// Verifies the CloudKit transport's pure, locally exercisable paths: the
/// record↔document metadata mapping and the error classification. No test
/// here performs a network request, signs in, or touches a real container —
/// `CKRecord`/`CKAsset` are used purely as local data containers.
@Suite("CloudKitSnapshotTransport mapping")
struct CloudKitTransportTests {

    private func makeRecord(
        for document: SnapshotDocument,
        assetData: Data?,
        in dir: URL
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: CloudKitSnapshotTransport.recordType,
            recordID: CKRecord.ID(recordName: CloudKitSnapshotTransport.recordName)
        )
        CloudKitSnapshotTransport.applyMetadata(of: document, to: record)
        if let assetData {
            let url = dir.appendingPathComponent("asset-\(UUID().uuidString).json", isDirectory: false)
            try assetData.write(to: url)
            record[CloudKitSnapshotTransport.assetFieldName] = CKAsset(fileURL: url)
        }
        return record
    }

    private func wireData(for document: SnapshotDocument) throws -> Data {
        try WatchlistSyncWireCodec.encode(
            deviceID: "cloudkit-transport-test",
            updatedAt: document.createdAt,
            snapshot: document.snapshot
        )
    }

    private func expectCorruptRemote(_ label: String, _ body: () throws -> RemoteSnapshotRecord) {
        do {
            _ = try body()
            Issue.record("\(label): expected corruptRemote, got a document")
        } catch let error as SnapshotTransportError {
            guard case .corruptRemote = error else {
                Issue.record("\(label): expected corruptRemote, got \(error)")
                return
            }
        } catch {
            Issue.record("\(label): expected SnapshotTransportError.corruptRemote, got \(error)")
        }
    }

    @Test("A well-formed record materializes with revision, operation, parent and payload intact")
    func materializeRoundTrip() throws {
        let dir = try Fixtures.makeTempDirectory("ck-roundtrip")
        defer { Fixtures.removeDirectory(dir) }
        let parent = UUID()
        let document = SnapshotDocument(
            parentRevision: parent,
            operationID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: Fixtures.snapshot()
        )
        let record = try makeRecord(for: document, assetData: wireData(for: document), in: dir)

        let materialized = try CloudKitSnapshotTransport.materialize(record)
        #expect(materialized.document?.revision == document.revision)
        #expect(materialized.document?.parentRevision == parent)
        #expect(materialized.document?.operationID == document.operationID)
        #expect(materialized.document?.snapshot == document.snapshot)
    }

    @Test("The first document's nil parent round-trips as an absent field")
    func nilParentRoundTrips() throws {
        let dir = try Fixtures.makeTempDirectory("ck-nil-parent")
        defer { Fixtures.removeDirectory(dir) }
        let document = SnapshotDocument(
            parentRevision: nil,
            operationID: UUID(),
            snapshot: Fixtures.snapshot()
        )
        let record = try makeRecord(for: document, assetData: wireData(for: document), in: dir)
        #expect(record[CloudKitSnapshotTransport.parentFieldName] == nil)

        let materialized = try CloudKitSnapshotTransport.materialize(record)
        #expect(materialized.document?.parentRevision == nil)
        #expect(materialized.document?.revision == document.revision)
    }

    @Test("A record missing its revision is corruption, not something to overwrite")
    func missingRevisionIsCorrupt() throws {
        let dir = try Fixtures.makeTempDirectory("ck-no-revision")
        defer { Fixtures.removeDirectory(dir) }
        let document = SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: Fixtures.snapshot())
        let record = try makeRecord(for: document, assetData: wireData(for: document), in: dir)
        record[CloudKitSnapshotTransport.revisionFieldName] = nil

        expectCorruptRemote("missing revision") {
            try CloudKitSnapshotTransport.materialize(record)
        }
    }

    @Test("A record missing its operation ID is corruption")
    func missingOperationIDIsCorrupt() throws {
        let dir = try Fixtures.makeTempDirectory("ck-no-operation")
        defer { Fixtures.removeDirectory(dir) }
        let document = SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: Fixtures.snapshot())
        let record = try makeRecord(for: document, assetData: wireData(for: document), in: dir)
        record[CloudKitSnapshotTransport.operationFieldName] = nil

        expectCorruptRemote("missing operation ID") {
            try CloudKitSnapshotTransport.materialize(record)
        }
    }

    @Test("An undecodable parent revision is corruption, never silently treated as empty")
    func undecodableParentIsCorrupt() throws {
        let dir = try Fixtures.makeTempDirectory("ck-bad-parent")
        defer { Fixtures.removeDirectory(dir) }
        let document = SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: Fixtures.snapshot())
        let record = try makeRecord(for: document, assetData: wireData(for: document), in: dir)
        record[CloudKitSnapshotTransport.parentFieldName] = "not-a-uuid" as CKRecordValue

        expectCorruptRemote("undecodable parent") {
            try CloudKitSnapshotTransport.materialize(record)
        }
    }

    @Test("A record with an undecodable or missing asset payload is corruption")
    func badAssetIsCorrupt() throws {
        let dir = try Fixtures.makeTempDirectory("ck-bad-asset")
        defer { Fixtures.removeDirectory(dir) }
        let document = SnapshotDocument(parentRevision: nil, operationID: UUID(), snapshot: Fixtures.snapshot())

        let garbage = try makeRecord(for: document, assetData: Data("not a snapshot".utf8), in: dir)
        expectCorruptRemote("garbage asset") {
            try CloudKitSnapshotTransport.materialize(garbage)
        }

        let noAsset = try makeRecord(for: document, assetData: nil, in: dir)
        expectCorruptRemote("missing asset") {
            try CloudKitSnapshotTransport.materialize(noAsset)
        }
    }

    @Test("Permission, account and container errors are configuration failures, never retryable offline")
    func errorClassificationIsHonest() {
        let configurationCodes: [CKError.Code] = [
            .notAuthenticated, .badContainer, .missingEntitlement,
            .permissionFailure, .managedAccountRestricted,
        ]
        for code in configurationCodes {
            let mapped = CloudKitSnapshotTransport.transportError(from: CKError(code))
            guard case .notConfigured = mapped else {
                Issue.record("CKError \(code) must be .notConfigured so it is never infinitely retried, got \(mapped)")
                continue
            }
            #expect(!mapped.isRetryable)
        }

        let transientCodes: [CKError.Code] = [
            .networkUnavailable, .networkFailure, .serviceUnavailable, .zoneBusy,
        ]
        for code in transientCodes {
            let mapped = CloudKitSnapshotTransport.transportError(from: CKError(code))
            guard case .offline = mapped else {
                Issue.record("CKError \(code) must be .offline, got \(mapped)")
                continue
            }
            #expect(mapped.isRetryable)
        }

        let rejectedCodes: [CKError.Code] = [
            .quotaExceeded, .limitExceeded, .serverRejectedRequest,
        ]
        for code in rejectedCodes {
            let mapped = CloudKitSnapshotTransport.transportError(from: CKError(code))
            guard case .rejected = mapped else {
                Issue.record("CKError \(code) must be .rejected, got \(mapped)")
                continue
            }
            #expect(!mapped.isRetryable)
        }
    }
}
#endif
