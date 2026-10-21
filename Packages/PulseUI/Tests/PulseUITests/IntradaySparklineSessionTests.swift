import Foundation
import Testing
import PulseCore
@testable import PulseUI

struct IntradaySparklineSessionTests {
    private func time(_ hour: Int, _ minute: Int = 0, market: Market = .sh) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = market.timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour, minute: minute))!
    }
    private func bars(_ times: [Date]) -> [Candle] {
        times.enumerated().map { .init(time: $0.element, open: 100, high: 102, low: 99, close: 100 + Double($0.offset), volume: 100) }
    }
    private func axis(_ markets: [Market]) throws -> IntradaySharedAxis {
        try #require(IntradaySharedAxis(markets: markets, referenceDate: time(10)))
    }

    @Test("The actual renderer places Chinese and Korean opening points on the group ruler")
    func groupOpeningCoordinates() throws {
        let shared = try axis([.sh, .kr])
        let china = IntradaySparklineGeometry(candles: bars([time(9, 30), time(10)]), market: .sh, sharedAxis: shared)
        let korea = IntradaySparklineGeometry(candles: bars([time(8), time(10)]), market: .kr, sharedAxis: shared)
        #expect(abs((china.xFraction(for: time(9, 30)) ?? -1) - 90.0 / 420) < 0.000001)
        #expect(korea.xFraction(for: time(8)) == 0)
        #expect(china.xFraction(for: time(10)) == korea.xFraction(for: time(10)))
        #expect(china.xFraction(for: time(10)) == shared.fraction(for: time(10)))
    }

    @Test("Hong Kong widens one shared frame for all rows, including rows with no data")
    func hongKongUnionAndMissingData() throws {
        let shared = try axis([.sh, .kr, .hk])
        let china = IntradaySparklineGeometry(candles: bars([time(9, 30), time(10)]), market: .sh, sharedAxis: shared)
        let korea = IntradaySparklineGeometry(candles: [], market: .kr, sharedAxis: shared)
        #expect(shared.startMinute == 480); #expect(shared.endMinute == 960)
        #expect(china.xFraction(for: time(14, 12)) == korea.xFraction(for: time(14, 12)))
        #expect(china.xFraction(for: time(14, 12)) == shared.fraction(for: time(14, 12)))
        #expect(korea.candles.isEmpty)
    }

    @Test("Synchronized China breaks across lunch while Korea remains continuous")
    func lunchSegments() throws {
        let shared = try axis([.sh, .kr])
        let china = IntradaySparklineGeometry(candles: bars([time(11, 29), time(11, 30), time(12), time(13), time(13, 1)]), market: .sh, sharedAxis: shared)
        let korea = IntradaySparklineGeometry(candles: bars((0...90).map { time(11, 30).addingTimeInterval(Double($0) * 60) }), market: .kr, sharedAxis: shared)
        #expect(china.segments.count == 2)
        #expect(china.candles.count == 4)
        #expect(china.segments[0].points.last?.time == time(11, 30))
        #expect(china.segments[1].points.first?.time == time(13))
        #expect(korea.segments.count == 1)
        let lunch = try #require(shared.lunchFractions)
        #expect(lunch.lowerBound == china.xFraction(for: time(11, 30)))
        #expect(lunch.upperBound == korea.xFraction(for: time(13)))
    }

    @Test("Synchronization off retains lunch compression, rather than changing the old chart")
    func independentChinaUsesTradingMinutes() {
        let chart = IntradaySparklineGeometry(candles: bars([time(11, 30), time(13), time(13, 1)]), market: .sh)
        #expect(chart.xFraction(for: time(11, 30)) == 0.5)
        #expect(chart.xFraction(for: time(13)) == 0.5)
        #expect(chart.segments.count == 1)
        #expect(chart.axis == nil)
    }

    @Test("Out of bounds data is omitted instead of falling back to an unrelated axis")
    func noFallbackAtEdges() throws {
        let shared = try axis([.sh, .kr])
        let geometry = IntradaySparklineGeometry(candles: bars([time(9, 30), time(10)]), market: .sh, sharedAxis: shared)
        #expect(geometry.xFraction(for: time(7, 59)) == nil)
        #expect(geometry.xFraction(for: time(15, 1)) == nil)
    }

    @Test("Unsupported US rows keep independent regular and extended sessions")
    func usWingsRemainIndependent() throws {
        let shared = try axis([.sh, .kr])
        let chart = IntradaySparklineGeometry(candles: bars([time(4, market: .us), time(20, market: .us)]), market: .us, includesExtendedHours: true, sharedAxis: shared)
        #expect(chart.axis == nil)
        #expect(abs((chart.xFraction(for: time(9, 30, market: .us)) ?? -1) - 0.15) < 0.000001)
        #expect(abs((chart.xFraction(for: time(16, market: .us)) ?? -1) - 0.85) < 0.000001)
        #expect(chart.xFraction(for: time(4, market: .us)) == 0)
        #expect(chart.xFraction(for: time(20, market: .us)) == 1)
    }

    @Test("Narrow ruler labels do not collide or change tick positions")
    func rulerDensity() throws {
        let shared = try axis([.sh, .kr])
        for width in [80.0, 100, 160, 260, 348] {
            let ticks = IntradayAxisRuler.visibleTicks(axis: shared, width: width)
            #expect(ticks.contains(570)); #expect(ticks.last == shared.endMinute)
            let positions = ticks.map { min(max(width * (shared.fraction(minute: $0) ?? 0), 13), width - 13) }
            for (a, b) in zip(positions, positions.dropFirst()) { #expect(b - a >= 28) }
        }
        #expect(IntradayAxisRuler.visibleTicks(axis: shared, width: 348).contains(570))
        #expect(IntradayAxisRuler.visibleTicks(axis: shared, width: 40) == [570])
        #expect(!shared.tickMinutes.contains(540)) // No 09:00 tick masquerading as 09:30.
    }

    @Test("Unsupported-only groups do not create a misleading Asian clock")
    func unsupportedGroup() {
        #expect(IntradaySharedAxis(markets: [.us, .crypto, .metal], referenceDate: time(10)) == nil)
    }
}
