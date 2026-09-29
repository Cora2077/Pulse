import Foundation

/// Versioned JSON representation shared by devices syncing watchlist state.
/// Version 2 uses Codable's numeric Date representation, which preserves the
/// subsecond timestamps used by the merge algorithm. Version 1 remains readable
/// for files written with ISO-8601 dates.
public enum WatchlistSyncWireCodec {
    public static let formatIdentifier = "pulse.device-sync"
    public static let currentVersion = 2

    public struct File: Sendable, Equatable {
        public let format: String
        public let version: Int
        public let deviceID: String
        public let updatedAt: Date
        public let snapshot: WatchlistSyncSnapshot

        fileprivate init(
            format: String,
            version: Int,
            deviceID: String,
            updatedAt: Date,
            snapshot: WatchlistSyncSnapshot
        ) {
            self.format = format
            self.version = version
            self.deviceID = deviceID
            self.updatedAt = updatedAt
            self.snapshot = snapshot
        }
    }

    public enum CodecError: Error, Equatable {
        case invalidEnvelope
        case unsupportedFormat
        case unsupportedVersion(Int)
        case unexpectedDeviceID
        case duplicateGroupID(UUID)
        case duplicateItemSymbol(SymbolID)
        case duplicateCostLotID(UUID)
        case duplicateTransactionID(UUID)
        case invalidTransactionFee(UUID)
        case duplicateTradePlanID(UUID)
    }

    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct Payload: Codable {
        var format: String
        var version: Int
        var deviceID: String
        var updatedAt: Date
        var snapshot: WatchlistSyncSnapshot
    }

    /// Encodes the current wire version. Codable's deferred Date strategy
    /// stores reference-date seconds as a JSON number with round-trippable
    /// floating-point precision.
    public static func encode(
        deviceID: String,
        updatedAt: Date = .now,
        snapshot: WatchlistSyncSnapshot
    ) throws -> Data {
        let file = File(
            format: formatIdentifier,
            version: currentVersion,
            deviceID: deviceID,
            updatedAt: updatedAt,
            snapshot: snapshot
        )
        try validate(file)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(
            format: file.format,
            version: file.version,
            deviceID: file.deviceID,
            updatedAt: file.updatedAt,
            snapshot: file.snapshot
        ))
    }

    /// Decodes v1 ISO-8601 or current v2 payloads and validates IDs before a
    /// decoded snapshot can reach merge code that assumes uniqueness.
    public static func decode(_ data: Data, expectedDeviceID: String? = nil) throws -> File {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw CodecError.invalidEnvelope
        }
        guard header.format == formatIdentifier else { throw CodecError.unsupportedFormat }
        guard header.version == 1 || header.version == currentVersion else {
            throw CodecError.unsupportedVersion(header.version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = header.version == 1 ? .iso8601 : .deferredToDate
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw CodecError.invalidEnvelope
        }
        guard payload.format == formatIdentifier, payload.version == header.version else {
            throw CodecError.invalidEnvelope
        }
        if let expectedDeviceID, payload.deviceID != expectedDeviceID {
            throw CodecError.unexpectedDeviceID
        }

        let file = File(
            format: payload.format,
            version: payload.version,
            deviceID: payload.deviceID,
            updatedAt: payload.updatedAt,
            snapshot: payload.snapshot
        )
        try validate(file)
        return file
    }

    private static func validate(_ file: File) throws {
        guard file.format == formatIdentifier else { throw CodecError.unsupportedFormat }
        guard file.version == 1 || file.version == currentVersion else {
            throw CodecError.unsupportedVersion(file.version)
        }

        var groupIDs = Set<UUID>()
        for group in file.snapshot.groups {
            guard groupIDs.insert(group.id).inserted else { throw CodecError.duplicateGroupID(group.id) }
        }

        var itemSymbols = Set<SymbolID>()
        for item in file.snapshot.items + file.snapshot.retainedHistoryItems {
            guard itemSymbols.insert(item.symbol).inserted else {
                throw CodecError.duplicateItemSymbol(item.symbol)
            }
            var lotIDs = Set<UUID>()
            for lot in item.lots {
                guard lotIDs.insert(lot.id).inserted else { throw CodecError.duplicateCostLotID(lot.id) }
            }
            var transactionIDs = Set<UUID>()
            for transaction in item.transactions {
                guard transaction.hasValidFee else { throw CodecError.invalidTransactionFee(transaction.id) }
                guard transactionIDs.insert(transaction.id).inserted else {
                    throw CodecError.duplicateTransactionID(transaction.id)
                }
            }
            // The plan merge keys by id, so a payload carrying one twice would
            // silently drop an edit instead of reporting the malformed file.
            var planIDs = Set<UUID>()
            for plan in item.plans {
                guard planIDs.insert(plan.id).inserted else {
                    throw CodecError.duplicateTradePlanID(plan.id)
                }
            }
        }
    }
}
