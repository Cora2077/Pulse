import Foundation
import Testing
import PulseCore
@testable import PulseUI

struct ChartAnnotationMathTests {
    @Test("known chart indexes round trip through the plot coordinate transform")
    func indexCoordinatesRoundTrip() throws {
        let plot = CGRect(x: 31, y: 8, width: 300, height: 180)
        let domain = -1...5

        for index in 0..<5 {
            let x = try #require(ChartAnnotationMath.xCoordinate(index: index, domain: domain, plot: plot))
            #expect(ChartAnnotationMath.nearestIndex(atX: x, domain: domain, plot: plot, count: 5) == index)
        }
    }

    @Test("price projection uses the real plot bounds")
    func priceCoordinateRoundTrip() throws {
        let plot = CGRect(x: 17, y: 23, width: 260, height: 160)
        let domain = 40.0...80.0
        for price in [40.0, 51.25, 80.0] {
            let y = try #require(ChartAnnotationMath.yCoordinate(price: price, domain: domain, plot: plot))
            #expect(ChartAnnotationMath.price(atY: y, domain: domain, plot: plot) == price)
        }
    }

    @Test("reserved volume band is excluded from annotation hit and draw coordinates")
    func pricePaneExcludesVolumeBand() {
        let plot = CGRect(x: 11, y: 5, width: 300, height: 200)
        let pane = ChartAnnotationMath.pricePane(plot: plot, reservesVolume: true, volumeFraction: 0.2)
        #expect(pane.minY == plot.minY)
        #expect(pane.maxY == plot.maxY - 40)
        #expect(ChartAnnotationMath.pricePane(plot: plot, reservesVolume: false, volumeFraction: 0.2) == plot)
    }

    @Test("anchor lookup accepts archive millisecond rounding but rejects missing samples")
    func exactSampleLookup() {
        let sample = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ChartAnnotationMath.exactIndex(for: sample.addingTimeInterval(0.0008), sampleTimes: [sample]) == 0)
        #expect(ChartAnnotationMath.exactIndex(for: sample.addingTimeInterval(0.01), sampleTimes: [sample]) == nil)
    }

    @Test("plan labels stay in the pane and separate overlapping prices")
    func planLabelsAreSeparated() {
        let first = planGroup(price: 100, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = planGroup(price: 101, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let result = ChartAnnotationMath.placePlanLabels(
            [PlanLabelCandidate(group: first, anchorY: 45, desiredY: 45),
             PlanLabelCandidate(group: second, anchorY: 46, desiredY: 46)],
            bounds: 10...70,
            gap: 21
        )
        #expect(result.count == 2)
        #expect(result[1].labelY - result[0].labelY >= 21)
        #expect(result.allSatisfy { $0.labelY >= 10 && $0.labelY <= 70 })
    }

    private func planGroup(price: Double, id: UUID) -> PlanGroup {
        let plan = TradePlan(id: id, kind: .buy, price: price, quantity: 10)
        return PlanGroup(key: PlanGroupKey(kind: .buy, price: price), plans: [plan])
    }
}
