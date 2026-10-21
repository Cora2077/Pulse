import Foundation
import Testing
import PulseCore
@testable import PulseUI

struct IntradaySparklineFreshnessTests {
    private let symbol = SymbolID(market: .sh, code: "000688")
    private func at(_ hour: Int, _ minute: Int = 0, second: Int = 0, day: Int = 21) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = Market.sh.timeZone
        return calendar.date(from: .init(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }
    private func bar(_ time: Date, price: Double = 100) -> Candle {
        .init(time: time, open: 99, high: 101, low: 98, close: price, volume: 123)
    }
    private func quote(_ time: Date, price: Double = 105, state: MarketState? = .regular) -> Quote {
        .init(symbol: symbol, price: price, previousClose: 99, volume: 999_999, timestamp: time, marketState: state)
    }
    private func geometry(_ bars: [Candle], _ sample: Quote?, now: Date? = nil, aligned: Bool = false) -> IntradaySparklineGeometry {
        .init(candles: bars, market: .sh,
              sharedAxis: aligned ? IntradaySharedAxis(markets: [.sh, .kr], referenceDate: at(10)) : nil,
              liveQuote: sample, now: now ?? sample?.timestamp ?? at(10))
    }

    @Test("A quote advances the actual drawn endpoint without waiting for historical candles")
    func quoteDrivesEndpoint() {
        let history = [bar(at(10)), bar(at(10, 1))]
        let first = geometry(history, quote(at(10, 1, second: 10), price: 102))
        let second = geometry(history, quote(at(10, 1, second: 11), price: 103))
        #expect(first.points.last?.price == 102); #expect(second.points.last?.price == 103)
        #expect(second.points.last?.time == at(10, 1, second: 11))
        #expect((second.xFraction(for: second.points.last!.time) ?? 0) > (first.xFraction(for: first.points.last!.time) ?? 1))
        #expect(second.candles == history) // No fabricated OHLC or cumulative-volume bars.
    }

    @Test("A stale historical response cannot move the quote endpoint backward")
    func historyCannotEraseQuote() {
        let fresh = quote(at(10, 5), price: 110)
        let result = geometry([bar(at(10)), bar(at(10, 1))], fresh)
        #expect(result.points.last?.time == fresh.timestamp)
        #expect(result.points.last?.price == fresh.price)
    }

    @Test("A source with an unchanged timestamp does not manufacture time progress")
    func sourceTimestampIsPreserved() {
        let sample = quote(at(10, 1))
        let a = geometry([bar(at(10))], sample, now: at(10, 2))
        let b = geometry([bar(at(10))], sample, now: at(10, 5))
        #expect(a.points == b.points)
    }

    @Test("An older quote cannot replace newer historical prices")
    func oldQuoteIgnored() {
        let result = geometry([bar(at(10)), bar(at(10, 2))], quote(at(10, 1)))
        #expect(result.quotePoint == nil)
        #expect(result.points.last?.time == at(10, 2))
    }

    @Test("The new day's first quote starts its own session, rather than bridging yesterday")
    func newDayAndColdStart() {
        let result = geometry([bar(at(14, 59, day: 20))], quote(at(9, 31)))
        #expect(result.candles.isEmpty); #expect(result.points.count == 1)
        #expect(result.quotePoint?.time == at(9, 31))
        let empty = geometry([], quote(at(10)))
        #expect(empty.points.count == 1)
    }

    @Test("Invalid, future, after-hours and lunchtime samples cannot extend a regular curve")
    func invalidSamples() {
        let history = [bar(at(10))]
        let samples = [quote(at(10, 1), price: .nan), quote(at(10, 1), price: -1),
                       quote(at(12)), quote(at(16)), quote(at(10, 1), state: .postMarket),
                       quote(at(10, 5))]
        for sample in samples.dropLast() { #expect(geometry(history, sample).quotePoint == nil) }
        #expect(geometry(history, samples.last!, now: at(10, 1)).quotePoint == nil)
    }

    @Test("A fresh afternoon quote does not draw a line through Chinese lunch")
    func lunchBoundary() {
        let result = geometry([bar(at(11, 29)), bar(at(11, 30))], quote(at(13, 0, second: 1)), aligned: true)
        #expect(result.segments.count == 2)
        #expect(result.segments[1].points.count == 1)
    }

    @Test("A same-time quote does not duplicate points or rewrite the official bar")
    func equalTimeSample() {
        let history = [bar(at(10)), bar(at(10, 1))]
        let result = geometry(history, quote(at(10, 1), price: 106))
        #expect(result.points.count == 2)
        #expect(result.points.last?.price == 106)
        #expect(result.candles.last?.close == 100)
    }
}
