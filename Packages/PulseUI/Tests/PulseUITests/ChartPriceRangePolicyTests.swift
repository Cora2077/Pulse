import Foundation
import Testing
import PulseCore
@testable import PulseUI

struct ChartPriceRangePolicyTests {
    @Test("visible MA60 values after a price gap stay above the lower bands", arguments: [false, true])
    func movingAverageAfterGapFitsPricePane(showsMACD: Bool) {
        let closes = Array(repeating: 80.0, count: 60) + Array(repeating: 100.0, count: 60)
        let averages = ChartIndicatorMath.simpleMovingAverage(closes, period: 60)
        let visibleAveragePrices = averages[60..<120].compactMap { $0 }
        let domain = ChartPriceRangePolicy.candleYDomain(
            of: [100, 100],
            including: visibleAveragePrices,
            hasBuyMarkers: false,
            hasSellMarkers: false,
            reserveVolumeBand: true,
            reserveMACDBand: showsMACD
        )
        let bands = ChartBands(hasVolume: true, hasMACD: showsMACD)
        let pricePaneBottom = domain.lowerBound + (domain.upperBound - domain.lowerBound) * bands.bottomReserved
        #expect(!visibleAveragePrices.isEmpty)
        #expect(pricePaneBottom <= (visibleAveragePrices.min() ?? .infinity))
        #expect(domain.upperBound >= (visibleAveragePrices.max() ?? 0))
    }

    @Test("nearby plans fit while a distant plan stays outside the price domain")
    func nearbyPlanFitsAndRemotePlanDoesNot() {
        let fitted = ChartPriceRangePolicy.pricesToFit(
            [225, 100],
            naturalRange: 239...253
        )

        #expect(fitted == [225])
    }

    @Test("plan selection is stable and keeps the expanded range within the cap")
    func planSelectionIsDeterministicAndCapped() {
        let natural = 239.0...253.0
        let first = ChartPriceRangePolicy.pricesToFit(
            [270, 230, 260, 225, 260],
            naturalRange: natural
        )
        let second = ChartPriceRangePolicy.pricesToFit(
            [225, 260, 270, 230],
            naturalRange: natural
        )

        #expect(first == [225, 230, 260])
        #expect(second == first)
        #expect(260 - 225 <= (natural.upperBound - natural.lowerBound) * 3)
    }

    @Test("fit all includes remote visible plans and focused prices still require visibility")
    func fitAllAndFocusedPrice() {
        #expect(ChartPriceRangePolicy.pricesToFit(
            [225, 100], naturalRange: 239...253, fitsAll: true
        ) == [100, 225])
        #expect(ChartPriceRangePolicy.pricesToFit(
            [225], naturalRange: 239...253, focusedPrice: 100
        ) == [225])
        #expect(ChartPriceRangePolicy.pricesToFit(
            [225], naturalRange: 239...253, focusedPrice: 100, fitsAll: true
        ) == [225])
    }

    @Test("focused visible remote price is retained even beyond the normal cap")
    func focusedPriceCanExpandBeyondCap() {
        #expect(ChartPriceRangePolicy.pricesToFit(
            [100, 225], naturalRange: 239...253, focusedPrice: 100
        ) == [100, 225])
    }

    @Test("visible plan prices respect historical display and reject invalid prices")
    func visiblePlanPriceFiltering() {
        let plans = [
            TradePlan(kind: .buy, price: 240, quantity: 1),
            TradePlan(kind: .sell, price: 250, quantity: 1, status: .done),
            TradePlan(kind: .buy, price: .nan, quantity: 1),
            TradePlan(kind: .buy, price: -.infinity, quantity: 1)
        ]

        #expect(ChartPriceRangePolicy.visiblePlanPrices(plans, showsHistorical: false) == [240])
        #expect(ChartPriceRangePolicy.visiblePlanPrices(plans, showsHistorical: true) == [240, 250])
    }

    @Test("percentage changes require positive finite real prices")
    func percentageChangeValidation() {
        #expect(ChartPriceRangePolicy.percentageChange(price: 105, previousClose: 100).map { abs($0 - 5) < 1e-10 } == true)
        #expect(ChartPriceRangePolicy.percentageChange(price: 100, previousClose: 100) == 0)
        #expect(ChartPriceRangePolicy.percentageChange(price: 95, previousClose: 100).map { abs($0 + 5) < 1e-10 } == true)
        #expect(ChartPriceRangePolicy.percentageChange(price: 105, previousClose: 0) == nil)
        #expect(ChartPriceRangePolicy.percentageChange(price: 105, previousClose: .infinity) == nil)
        #expect(ChartPriceRangePolicy.percentageChange(price: .nan, previousClose: 100) == nil)
    }

    @Test("price axis tick list inserts the valid previous close for the exact zero-percent mark")
    func previousCloseTick() {
        let ticks = ChartPriceRangePolicy.priceAxisTicks(in: 80...120, including: 101)
        let baselineTick = ticks.first { $0 == 101 }
        #expect(baselineTick != nil)
        #expect(baselineTick.flatMap {
            ChartPriceRangePolicy.percentageChange(price: $0, previousClose: 101)
        } == 0)
        #expect(!ChartPriceRangePolicy.priceAxisTicks(in: 80...120, including: 0).contains(0))
    }

    @Test("exact baseline tick replaces a nearby price tick to avoid colliding labels")
    func nearbyBaselineTickReplacesNiceTick() {
        let ticks = ChartPriceRangePolicy.priceAxisTicks(in: 210...230, including: 219.6)

        #expect(ticks.contains(219.6))
        #expect(!ticks.contains(220))
        #expect(ChartPriceRangePolicy.percentageChange(price: 219.6, previousClose: 219.6) == 0)
    }

    @Test("snap chooses the closest valid candle price within eight screen points")
    func snapThresholdAndNearestChoice() {
        let chosen = ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [120, 105, 90],
            yForPrice: { CGFloat($0) }
        )
        #expect(chosen == 105)
        #expect(ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [109],
            yForPrice: { CGFloat($0) }
        ) == nil)
        #expect(ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [108],
            yForPrice: { CGFloat($0) }
        ) == 108)
    }

    @Test("intraday close-only snapping and candle OHLC snapping use their supplied prices")
    func closeOnlyAndOHLCInputs() {
        let closeOnly = ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [120],
            yForPrice: { CGFloat($0) }
        )
        let candleOHLC = ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [120, 105, 90, 130],
            yForPrice: { CGFloat($0) }
        )

        #expect(closeOnly == nil)
        #expect(candleOHLC == 105)
        #expect(ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [105],
            yForPrice: { _ in nil }
        ) == nil)
    }

    @Test("snap ignores invalid prices and nonfinite projections")
    func snapRejectsInvalidCandidates() {
        #expect(ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [.nan, .infinity, -1],
            yForPrice: { CGFloat($0) }
        ) == nil)
        #expect(ChartAnchorSnapPolicy.nearestPrice(
            atY: 100,
            candidates: [105],
            yForPrice: { _ in .infinity }
        ) == nil)
    }
}
