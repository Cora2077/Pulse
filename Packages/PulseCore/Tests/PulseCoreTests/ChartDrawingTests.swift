import Foundation
import Testing
@testable import PulseCore

@Suite("Chart drawing models")
struct ChartDrawingTests {
    @Test("Drawing geometry and chart scope must agree")
    func geometryScopeValidation() {
        let start = ChartAnchor(time: Date(timeIntervalSince1970: 100), price: 10)
        let end = ChartAnchor(time: Date(timeIntervalSince1970: 100), price: 12)

        #expect(ChartDrawing(geometry: .horizontal(price: 10)).isValid)
        #expect(!ChartDrawing(
            geometry: .horizontal(price: 10),
            scope: .candles(period: .day)
        ).isValid)
        #expect(ChartDrawing(
            geometry: .trend(start: start, end: end),
            scope: .candles(period: .day)
        ).isValid)
        #expect(!ChartDrawing(
            geometry: .trend(start: start, end: end),
            scope: .all
        ).isValid)
        #expect(!ChartDrawing(geometry: .horizontal(price: .infinity)).isValid)
        #expect(!ChartDrawing(geometry: .horizontal(price: 0)).isValid)
        #expect(!ChartDrawing(
            geometry: .trend(start: start, end: start),
            scope: .intraday(day: start.time)
        ).isValid)
    }

    @Test("Measurement counts distinct actual samples inclusively in either direction")
    func measurementUsesActualSampleTimes() throws {
        let first = Date(timeIntervalSince1970: 100)
        let middle = Date(timeIntervalSince1970: 160)
        let last = Date(timeIntervalSince1970: 220)
        let outside = Date(timeIntervalSince1970: 221)
        let measurement = try #require(ChartMeasurement(
            start: ChartAnchor(time: last, price: 10),
            end: ChartAnchor(time: first, price: 12),
            sampleTimes: [first, middle, middle, last, outside]
        ))

        #expect(measurement.priceChange == 2)
        #expect(measurement.priceChangePercent == 20)
        #expect(measurement.elapsedSeconds == 120)
        #expect(measurement.pointCount == 3)

        let singlePoint = try #require(ChartMeasurement(
            start: ChartAnchor(time: middle, price: 12),
            end: ChartAnchor(time: middle, price: 12),
            sampleTimes: [middle, middle]
        ))
        #expect(singlePoint.pointCount == 1)
        #expect(singlePoint.elapsedSeconds == 0)
        #expect(ChartMeasurement(
            start: ChartAnchor(time: first, price: 0),
            end: ChartAnchor(time: last, price: 1),
            sampleTimes: [first, last]
        ) == nil)
    }

    @Test("Drawing codec preserves scope, style, note, and tombstone dates")
    func drawingCodableRoundTrip() throws {
        let start = ChartAnchor(time: Date(timeIntervalSince1970: 100.125), price: 12.5)
        let end = ChartAnchor(time: Date(timeIntervalSince1970: 160.875), price: 13.25)
        let drawing = ChartDrawing(
            id: UUID(uuidString: "f1d35d45-4d73-4b31-ae5f-089bedaff067")!,
            geometry: .trend(start: start, end: end),
            scope: .candles(period: .minute15),
            style: ChartDrawingStyle(color: .purple, lineWidth: 2.25),
            note: "test level",
            isLocked: true,
            createdAt: Date(timeIntervalSince1970: 90.125),
            updatedAt: Date(timeIntervalSince1970: 170.75),
            deletedAt: Date(timeIntervalSince1970: 180.625)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate

        let decoded = try decoder.decode(ChartDrawing.self, from: encoder.encode(drawing))

        #expect(decoded == drawing)
        #expect(decoded.isDeleted)
        #expect(decoded.isValid)
    }
}
