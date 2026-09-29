import Foundation
import XCTest
@testable import PulseCore

final class WatchlistSyncWireCodecTests: XCTestCase {
    private let deviceID = "b7e29c37-3700-48dd-9f4a-475312a2ec41"

    func testV2PreservesSubsecondDatesAcrossTheWholeSnapshot() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let snapshot = makeSnapshot(date: date)

        let data = try WatchlistSyncWireCodec.encode(deviceID: deviceID, updatedAt: date, snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data, expectedDeviceID: deviceID)

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.updatedAt, date)
        XCTAssertEqual(decoded.snapshot, snapshot)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["updatedAt"] is NSNumber, "v2 dates should use Codable's numeric Date representation")
    }

    func testV1ISO8601PayloadRemainsReadable() throws {
        let date = Date(timeIntervalSince1970: 1_704_067_200)
        let snapshot = makeSnapshot(date: date)
        let data = try encodeV1(deviceID: deviceID, snapshot: snapshot)

        let decoded = try WatchlistSyncWireCodec.decode(data, expectedDeviceID: deviceID)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.updatedAt, date)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    func testUnsupportedVersionsIncludingZeroAreRejected() throws {
        let snapshot = WatchlistSyncSnapshot(items: [], groups: [])

        for version in [0, 3] {
            let data = try encodePayload(
                version: version,
                deviceID: deviceID,
                updatedAt: Date(timeIntervalSince1970: 1_704_067_200),
                snapshot: snapshot,
                dateStrategy: .iso8601
            )
            XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(data)) { error in
                XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .unsupportedVersion(version))
            }
        }
    }

    func testMalformedPayloadsWithDuplicateIDsAreRejected() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let original = try WatchlistSyncWireCodec.encode(
            deviceID: deviceID,
            updatedAt: date,
            snapshot: makeSnapshot(date: date)
        )
        let snapshot = makeSnapshot(date: date)
        let groupID = try XCTUnwrap(snapshot.groups.first?.id)
        let item = try XCTUnwrap(snapshot.items.first)

        var duplicateGroups = try v2JSON(original)
        var groupSnapshot = try snapshotObject(in: duplicateGroups)
        let encodedGroup = try XCTUnwrap((groupSnapshot["groups"] as? [[String: Any]])?.first)
        groupSnapshot["groups"] = [encodedGroup, encodedGroup]
        duplicateGroups["snapshot"] = groupSnapshot
        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(try jsonData(duplicateGroups))) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .duplicateGroupID(groupID))
        }

        var duplicateTransactions = try v2JSON(original)
        var transactionSnapshot = try snapshotObject(in: duplicateTransactions)
        var encodedItems = try XCTUnwrap(transactionSnapshot["items"] as? [[String: Any]])
        var encodedItem = try XCTUnwrap(encodedItems.first)
        let encodedTransaction = try XCTUnwrap((encodedItem["transactions"] as? [[String: Any]])?.first)
        encodedItem["transactions"] = [encodedTransaction, encodedTransaction]
        encodedItems[0] = encodedItem
        transactionSnapshot["items"] = encodedItems
        duplicateTransactions["snapshot"] = transactionSnapshot
        let transactionID = try XCTUnwrap(item.transactions.first?.id)
        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(try jsonData(duplicateTransactions))) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .duplicateTransactionID(transactionID))
        }

        var duplicateLots = try v2JSON(original)
        var lotSnapshot = try snapshotObject(in: duplicateLots)
        var lotItems = try XCTUnwrap(lotSnapshot["items"] as? [[String: Any]])
        var lotItem = try XCTUnwrap(lotItems.first)
        let encodedLot = try XCTUnwrap((lotItem["lots"] as? [[String: Any]])?.first)
        lotItem["lots"] = [encodedLot, encodedLot]
        lotItems[0] = lotItem
        lotSnapshot["items"] = lotItems
        duplicateLots["snapshot"] = lotSnapshot
        let lotID = try XCTUnwrap(item.lots.first?.id)
        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(try jsonData(duplicateLots))) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .duplicateCostLotID(lotID))
        }
    }

    private func makeSnapshot(date: Date) -> WatchlistSyncSnapshot {
        let symbol = SymbolID(market: .us, code: "AAPL")
        let transaction = PositionTransaction(
            id: UUID(uuidString: "36c69cc4-a31b-46ec-a05c-9920952f4f43")!,
            kind: .buy,
            price: 184.25,
            quantity: 3,
            date: date,
            createdAt: date,
            note: "fractional timestamp"
        )
        let item = WatchItem(
            symbol: symbol,
            displayName: "Apple",
            addedAt: date,
            lots: [CostLot(
                id: UUID(uuidString: "c9b672ea-603b-4602-94bb-dbe17b39b3cf")!,
                price: 180.5,
                quantity: 2,
                date: date
            )],
            transactions: [transaction]
        )
        let group = WatchlistGroup(
            id: UUID(uuidString: "4b77ba5e-ad90-42ad-a02c-8df3bb805a21")!,
            name: "Core",
            symbols: [symbol]
        )
        return WatchlistSyncSnapshot(items: [item], groups: [group])
    }

    private func encodeV1(deviceID: String, snapshot: WatchlistSyncSnapshot) throws -> Data {
        try encodePayload(
            version: 1,
            deviceID: deviceID,
            updatedAt: Date(timeIntervalSince1970: 1_704_067_200),
            snapshot: snapshot,
            dateStrategy: .iso8601
        )
    }

    private func encodePayload(
        version: Int,
        deviceID: String,
        updatedAt: Date,
        snapshot: WatchlistSyncSnapshot,
        dateStrategy: JSONEncoder.DateEncodingStrategy
    ) throws -> Data {
        struct LegacyPayload: Encodable {
            var format: String
            var version: Int
            var deviceID: String
            var updatedAt: Date
            var snapshot: WatchlistSyncSnapshot
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = dateStrategy
        return try encoder.encode(LegacyPayload(
            format: WatchlistSyncWireCodec.formatIdentifier,
            version: version,
            deviceID: deviceID,
            updatedAt: updatedAt,
            snapshot: snapshot
        ))
    }

    private func v2JSON(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func snapshotObject(in payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(payload["snapshot"] as? [String: Any])
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
