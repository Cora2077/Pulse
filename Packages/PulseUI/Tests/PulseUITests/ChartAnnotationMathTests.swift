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

    @Test("a tag pushed aside by its neighbour clears the bars instead of landing back on them")
    func stackingNeverUndoesObstacleAvoidance() {
        // The bug Cora hit on the daily chart: tags dodged the bars, then the stacking pass
        // used `max()` to push them apart without consulting the bars at all, shoving the
        // second tag straight back onto the candle block the first had just stepped off.
        let first = planGroup(price: 100, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!)
        let second = planGroup(price: 101, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!)
        let block: ClosedRange<CGFloat> = 100...200
        let result = ChartAnnotationMath.placePlanLabels(
            [PlanLabelCandidate(group: first, anchorY: 95, desiredY: 95),
             PlanLabelCandidate(group: second, anchorY: 92, desiredY: 92)],
            bounds: 0...400,
            gap: 24,
            inset: 10.5,
            obstacles: [block]
        )
        #expect(result.count == 2)
        let half: CGFloat = 10.5
        for placement in result {
            let coversBlock = block.lowerBound < placement.labelY + half
                && block.upperBound > placement.labelY - half
            #expect(!coversBlock)
        }
        #expect(result[1].labelY - result[0].labelY >= 24)
    }

    @Test("separate candle blocks leave their gap usable as a tag position")
    func tagsUseGapsBetweenCandleBlocks() {
        let group = planGroup(price: 100, id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!)
        // Two blocks with a real gap between them; the tag's price sits inside the gap.
        let upper: ClosedRange<CGFloat> = 0...80
        let lower: ClosedRange<CGFloat> = 160...300
        let result = ChartAnnotationMath.placePlanLabels(
            [PlanLabelCandidate(group: group, anchorY: 120, desiredY: 120)],
            bounds: 0...400,
            gap: 24,
            inset: 10.5,
            obstacles: [upper, lower]
        )
        // The gap is free, so the tag stays exactly where its price is.
        #expect(result.count == 1)
        #expect(result[0].labelY == 120)
    }

    @Test("overlapping candle spans merge but keep genuinely separate blocks apart")
    func candleSpansMergeOnlyWhenTheyTouch() {
        let merged = ChartAnnotationMath.mergingOverlapping([
            10...20, 25...40, 38...55, 60...70, 69...80
        ])
        #expect(merged.count == 3)
        #expect(merged[0] == 10...20)
        #expect(merged[1] == 25...55)
        #expect(merged[2] == 60...80)
        // A dense run of touching candles collapses, which is the only case where the tag has
        // no vertical room and has to fall back.
        #expect(ChartAnnotationMath.mergingOverlapping([0...10, 10...20, 20...30]).count == 1)
    }

    @Test("a fully blocked pane still yields every tag rather than dropping one")
    func blockedPaneStillPlacesEveryTag() {
        let groups = (0..<3).map { index in
            planGroup(price: Double(100 + index),
                      id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000000E%d", index))!)
        }
        let candidates = groups.enumerated().map { index, group in
            PlanLabelCandidate(group: group, anchorY: CGFloat(150 + index), desiredY: CGFloat(150 + index))
        }
        // One block covering the whole pane: nothing can be avoided, but every tag must still
        // come back so no plan silently disappears from the chart.
        let result = ChartAnnotationMath.placePlanLabels(candidates, bounds: 0...400, gap: 24,
                                                         inset: 10.5, obstacles: [0...400])
        #expect(result.count == 3)
        #expect(result.allSatisfy { $0.labelY >= 0 && $0.labelY <= 400 })
        for index in 1..<result.count {
            #expect(result[index].labelY > result[index - 1].labelY)
        }
    }

    @Test("a trend line extends to both price pane edges")
    func trendLineExtendsToPaneEdges() {
        let pane = CGRect(x: 0, y: 0, width: 200, height: 100)
        let extended = ChartAnnotationMath.extendedLine(through: CGPoint(x: 50, y: 50),
                                                        and: CGPoint(x: 100, y: 50),
                                                        within: pane)
        #expect(extended.start == CGPoint(x: 0, y: 50))
        #expect(extended.end == CGPoint(x: 200, y: 50))
    }

    @Test("the extension preserves the slope of a diagonal line")
    func diagonalLineKeepsSlope() {
        let pane = CGRect(x: 0, y: 0, width: 100, height: 100)
        let extended = ChartAnnotationMath.extendedLine(through: CGPoint(x: 40, y: 40),
                                                        and: CGPoint(x: 60, y: 60),
                                                        within: pane)
        #expect(extended.start == CGPoint(x: 0, y: 0))
        #expect(extended.end == CGPoint(x: 100, y: 100))
    }

    @Test("degenerate and fully outside lines keep the user's two points")
    func degenerateAndOutsideLinesStayPut() {
        let pane = CGRect(x: 0, y: 0, width: 100, height: 100)
        let degenerate = ChartAnnotationMath.extendedLine(through: CGPoint(x: 20, y: 20),
                                                          and: CGPoint(x: 20, y: 20),
                                                          within: pane)
        #expect(degenerate.start == CGPoint(x: 20, y: 20))
        #expect(degenerate.end == CGPoint(x: 20, y: 20))

        // Parallel to the pane and above it: nothing of it can be shown.
        let outside = ChartAnnotationMath.extendedLine(through: CGPoint(x: 10, y: -30),
                                                       and: CGPoint(x: 60, y: -30),
                                                       within: pane)
        #expect(outside.start == CGPoint(x: 10, y: -30))
        #expect(outside.end == CGPoint(x: 60, y: -30))
    }

    private func planGroup(price: Double, id: UUID) -> PlanGroup {
        let plan = TradePlan(id: id, kind: .buy, price: price, quantity: 10)
        return PlanGroup(key: PlanGroupKey(kind: .buy, price: price), plans: [plan])
    }
}
