import Foundation
import Testing
@testable import PulseCore

@Suite("Chart indicators")
struct ChartIndicatorsTests {

    // MARK: - Simple moving average

    @Test("SMA leaves the warm-up window empty and averages the rest")
    func simpleMovingAverageBasic() {
        let result = ChartIndicatorMath.simpleMovingAverage([1, 2, 3, 4, 5], period: 3)
        #expect(result.count == 5)
        #expect(result[0] == nil)
        #expect(result[1] == nil)
        #expect(result[2] == 2.0)
        #expect(result[3] == 3.0)
        #expect(result[4] == 4.0)
    }

    @Test("SMA of a flat series is that constant")
    func simpleMovingAverageFlat() {
        let result = ChartIndicatorMath.simpleMovingAverage([7, 7, 7, 7], period: 2)
        #expect(result[0] == nil)
        #expect(result[1] == 7.0)
        #expect(result[2] == 7.0)
        #expect(result[3] == 7.0)
    }

    @Test("SMA degrades to all-nil for empty input, a longer window, or a non-positive period")
    func simpleMovingAverageBoundaries() {
        #expect(ChartIndicatorMath.simpleMovingAverage([], period: 3).isEmpty)
        #expect(ChartIndicatorMath.simpleMovingAverage([1, 2], period: 5).allSatisfy { $0 == nil })
        #expect(ChartIndicatorMath.simpleMovingAverage([1, 2], period: 0).allSatisfy { $0 == nil })
        #expect(ChartIndicatorMath.simpleMovingAverage([1, 2], period: -1).allSatisfy { $0 == nil })
    }

    @Test("A window containing a non-finite value reports nothing for that bar")
    func simpleMovingAverageRejectsNonFinite() {
        let result = ChartIndicatorMath.simpleMovingAverage([1, .nan, 3], period: 2)
        #expect(result[0] == nil)
        #expect(result[1] == nil)
        #expect(result[2] == nil)
    }

    // MARK: - Exponential moving average

    @Test("EMA seeds from the first window's SMA and then weights the latest bar")
    func exponentialMovingAverageBasic() {
        // Seed = mean(1, 2, 3) = 2; alpha = 0.5.
        // 4 → 2 + 0.5 × (4 − 2) = 3; 5 → 3 + 0.5 × (5 − 3) = 4.
        let result = ChartIndicatorMath.exponentialMovingAverage([1, 2, 3, 4, 5], period: 3)
        #expect(result[0] == nil)
        #expect(result[1] == nil)
        #expect(result[2] == 2.0)
        #expect(result[3] == 3.0)
        #expect(result[4] == 4.0)
    }

    @Test("EMA of a flat series stays flat")
    func exponentialMovingAverageFlat() {
        let result = ChartIndicatorMath.exponentialMovingAverage([4, 4, 4, 4], period: 3)
        #expect(result[2] == 4.0)
        #expect(result[3] == 4.0)
    }

    @Test("EMA degrades to all-nil for empty input, a longer window, or a non-positive period")
    func exponentialMovingAverageBoundaries() {
        #expect(ChartIndicatorMath.exponentialMovingAverage([], period: 3).isEmpty)
        #expect(ChartIndicatorMath.exponentialMovingAverage([1, 2], period: 5).allSatisfy { $0 == nil })
        #expect(ChartIndicatorMath.exponentialMovingAverage([1, 2], period: 0).allSatisfy { $0 == nil })
    }

    // MARK: - MACD

    @Test("A flat series produces zero DIF, DEA and histogram once warmed up")
    func macdFlatSeries() {
        let closes = [Double](repeating: 10, count: 40)
        let series = ChartIndicatorMath.macd(closes)
        // DIF needs the slow window (26 bars) before it is defined.
        #expect(series.dif[24] == nil)
        #expect(series.dif[25] == 0)
        #expect(series.dif[39] == 0)
        #expect(series.dea[39] == 0)
        #expect(series.histogram[39] == 0)
    }

    @Test("MACD follows the documented formula on a short known series")
    func macdKnownSeries() {
        // fast 2 / slow 3 / signal 2 over 1…5.
        //   EMA2 = [nil, 1.5, 2.5, 3.5, 4.5]
        //   EMA3 = [nil, nil, 2, 3, 4]
        //   DIF  = [nil, nil, 0.5, 0.5, 0.5]
        //   DEA  = EMA2 of [0.5, 0.5, 0.5] = [nil, 0.5, 0.5]  → placed from bar 2
        //   histogram = 2 × (DIF − DEA) = 0
        let series = ChartIndicatorMath.macd(
            [1, 2, 3, 4, 5],
            parameters: MACDParameters(fastPeriod: 2, slowPeriod: 3, signalPeriod: 2)
        )
        #expect(series.dif[0] == nil)
        #expect(series.dif[1] == nil)
        #expect(series.dif[2] == 0.5)
        #expect(series.dif[4] == 0.5)
        #expect(series.dea[2] == nil)
        #expect(series.dea[3] == 0.5)
        #expect(series.dea[4] == 0.5)
        #expect(series.histogram[3] == 0)
        #expect(series.histogram[4] == 0)
    }

    @Test("A straight-line advance pins DIF at a constant, so the histogram flattens to zero")
    func macdLinearSeriesFlattensHistogram() {
        // An EMA lags a linear ramp by (1 − α) / α. Fast (12) lags 5.5 bars, slow (26) lags
        // 12.5, so DIF settles at 12.5 − 5.5 = 7 and its own signal EMA tracks it exactly.
        let closes = (1...40).map(Double.init)
        let series = ChartIndicatorMath.macd(closes)
        guard let dif = series.dif[39], let histogram = series.histogram[39] else {
            Issue.record("expected defined MACD values once warmed up")
            return
        }
        #expect(abs(dif - 7) < 1e-9)
        #expect(abs(histogram) < 1e-9)
    }

    @Test("An accelerating advance pulls DIF above DEA, so the histogram turns positive")
    func macdAcceleratingAdvanceIsPositive() {
        // A convex ramp widens the fast/slow gap as it goes, which is what a real
        // strengthening trend looks like.
        let closes = (1...40).map { Double($0 * $0) }
        let series = ChartIndicatorMath.macd(closes)
        guard let dif = series.dif[39], let dea = series.dea[39], let histogram = series.histogram[39] else {
            Issue.record("expected defined MACD values once warmed up")
            return
        }
        #expect(dif > dea)
        #expect(histogram > 0)
        #expect(abs(histogram - 2 * (dif - dea)) < 1e-9)
    }

    @Test("MACD degrades to all-nil for empty input or a non-positive window")
    func macdBoundaries() {
        let empty = ChartIndicatorMath.macd([])
        #expect(empty.dif.isEmpty && empty.dea.isEmpty && empty.histogram.isEmpty)

        let invalid = ChartIndicatorMath.macd(
            [1, 2, 3],
            parameters: MACDParameters(fastPeriod: 0, slowPeriod: 26, signalPeriod: 9)
        )
        #expect(invalid.dif.count == 3)
        #expect(invalid.dif.allSatisfy { $0 == nil })

        let tooShort = ChartIndicatorMath.macd([1, 2, 3])
        #expect(tooShort.dif.count == 3)
        #expect(tooShort.histogram.allSatisfy { $0 == nil })
    }

    // MARK: - Candle convenience

    @Test("Closing prices are taken in bar order")
    func closesInBarOrder() {
        let candles = [
            Candle(time: Date(timeIntervalSince1970: 0), open: 1, high: 2, low: 0.5, close: 1.5),
            Candle(time: Date(timeIntervalSince1970: 60), open: 1.5, high: 3, low: 1, close: 2.5)
        ]
        #expect(ChartIndicatorMath.closes(of: candles) == [1.5, 2.5])
    }

    @Test("Moving-average windows expose their period and label")
    func movingAverageWindowMetadata() {
        #expect(MovingAveragePeriod.allCases.map(\.period) == [5, 10, 20, 60])
        #expect(MovingAveragePeriod.ma20.label == "MA20")
    }

    /// The indicator menu stores the user's selection as one `Int`, so the bits must be
    /// distinct, combine to `allMask`, and stay addressable one window at a time.
    @Test("Moving-average windows mask into a single selection integer")
    func movingAverageWindowMasks() {
        let masks = MovingAveragePeriod.allCases.map(\.mask)
        #expect(Set(masks).count == MovingAveragePeriod.allCases.count)
        #expect(MovingAveragePeriod.allMask == masks.reduce(0, |))

        // Turning one window off leaves the others untouched.
        let withoutMA10 = MovingAveragePeriod.allMask & ~MovingAveragePeriod.ma10.mask
        let enabled = MovingAveragePeriod.allCases.filter { withoutMA10 & $0.mask != 0 }
        #expect(enabled == [.ma5, .ma20, .ma60])
        #expect(withoutMA10 & MovingAveragePeriod.ma10.mask == 0)
    }
}
