import Foundation
import XCTest
@testable import PulseCore

final class WatchlistSyncWireCodecTests: XCTestCase {
    private let deviceID = "b7e29c37-3700-48dd-9f4a-475312a2ec41"

    func testV3PreservesSubsecondDatesAcrossTheWholeSnapshot() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        var snapshot = makeSnapshot(date: date)
        let drawing = ChartDrawing(
            id: UUID(uuidString: "cd2a1d29-0a0d-48a4-9a61-29b8b1e7ac93")!,
            geometry: .trend(
                start: ChartAnchor(time: date, price: 184.25),
                end: ChartAnchor(time: date.addingTimeInterval(0.125), price: 185.5)
            ),
            scope: .candles(period: .day),
            createdAt: date,
            updatedAt: date.addingTimeInterval(0.25)
        )
        snapshot.items[0].drawings = [drawing]

        let data = try WatchlistSyncWireCodec.encode(deviceID: deviceID, updatedAt: date, snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data, expectedDeviceID: deviceID)

        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.updatedAt, date)
        XCTAssertEqual(decoded.snapshot, snapshot)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["updatedAt"] is NSNumber, "wire dates should use Codable's numeric Date representation")
    }

    func testV4PreservesTradeReview() throws {
        var snapshot = makeSnapshot(date: Date(timeIntervalSinceReferenceDate: 812_345_678.125))
        snapshot.items[0].transactions[0].review = PositionTransactionReview(
            followedPlan: false,
            retrospective: "Wait for confirmation next time"
        )

        let data = try WatchlistSyncWireCodec.encode(deviceID: deviceID, snapshot: snapshot)
        let decoded = try WatchlistSyncWireCodec.decode(data)

        XCTAssertEqual(decoded.version, 4)
        XCTAssertEqual(decoded.snapshot, snapshot)
    }

    func testInvalidAndDuplicateDrawingsAreRejected() throws {
        let symbol = SymbolID(market: .us, code: "AAPL")
        var invalidSnapshot = WatchlistSyncSnapshot(items: [WatchItem(symbol: symbol, displayName: "Apple")], groups: [])
        let invalid = ChartDrawing(geometry: .horizontal(price: 0))
        invalidSnapshot.items[0].drawings = [invalid]
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(
            deviceID: deviceID,
            snapshot: invalidSnapshot
        )) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .invalidChartDrawing(invalid.id))
        }

        var duplicateSnapshot = invalidSnapshot
        let valid = ChartDrawing(geometry: .horizontal(price: 10))
        duplicateSnapshot.items[0].drawings = [valid, valid]
        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(
            deviceID: deviceID,
            snapshot: duplicateSnapshot
        )) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .duplicateChartDrawingID(valid.id))
        }
    }

    func testV2NumericPayloadRemainsReadableWithoutDrawingFields() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)
        let snapshot = makeSnapshot(date: date)
        var payload = try v2JSON(encodePayload(
            version: 2,
            deviceID: deviceID,
            updatedAt: date,
            snapshot: snapshot,
            dateStrategy: .deferredToDate
        ))
        var encodedSnapshot = try snapshotObject(in: payload)
        var encodedItems = try XCTUnwrap(encodedSnapshot["items"] as? [[String: Any]])
        encodedItems[0].removeValue(forKey: "drawings")
        encodedSnapshot["items"] = encodedItems
        payload["snapshot"] = encodedSnapshot

        let decoded = try WatchlistSyncWireCodec.decode(jsonData(payload))

        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.snapshot, snapshot)
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

        for version in [0, WatchlistSyncWireCodec.currentVersion + 1] {
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

    func testInvalidTransactionFeeIsRejectedOnEncodeAndDecode() throws {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678)
        var snapshot = makeSnapshot(date: date)
        let original = try XCTUnwrap(snapshot.items.first?.transactions.first)
        var invalid = original
        invalid.fee = -1
        snapshot.items[0].transactions = [invalid]

        XCTAssertThrowsError(try WatchlistSyncWireCodec.encode(deviceID: deviceID, snapshot: snapshot)) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .invalidTransactionFee(original.id))
        }

        snapshot.items[0].transactions = [original]
        var payload = try v2JSON(WatchlistSyncWireCodec.encode(deviceID: deviceID, snapshot: snapshot))
        var transactionSnapshot = try snapshotObject(in: payload)
        var items = try XCTUnwrap(transactionSnapshot["items"] as? [[String: Any]])
        var encodedItem = try XCTUnwrap(items.first)
        var transactions = try XCTUnwrap(encodedItem["transactions"] as? [[String: Any]])
        transactions[0]["fee"] = -1
        encodedItem["transactions"] = transactions
        items[0] = encodedItem
        transactionSnapshot["items"] = items
        payload["snapshot"] = transactionSnapshot

        XCTAssertThrowsError(try WatchlistSyncWireCodec.decode(jsonData(payload))) { error in
            XCTAssertEqual(error as? WatchlistSyncWireCodec.CodecError, .invalidTransactionFee(original.id))
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
