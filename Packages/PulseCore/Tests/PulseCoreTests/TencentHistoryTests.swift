import Foundation
import Testing
@testable import PulseCore

/// Synthetic fixtures for the fqkline history endpoint. Row order on the wire is
/// `[date, open, close, high, low, volume]` — the third value is the close.
@Suite("Tencent history parsing")
struct TencentHistoryTests {
    static let star50 = SymbolID(market: .sh, code: "000688")

    /// Trimmed real response for sh000688 (daily), including a malformed trailing
    /// row and trailing per-row fields, plus the `qt` metadata that must be ignored.
    static let dayFixture = #"""
    {"code":0,"msg":"","data":{"sh000688":{"day":[["2025-09-18","1385.500","1380.350","1433.570","1351.140","17429025.000"],["2026-10-08","1512.79","1472.94","1521.46","1469.58","5619812"]],"qt":{"sh000688":["1","科创50","000688","1472.94"]}}}}
    """#

    @Test("Real index day shape keeps open, close, high, low in the right slots and converts volume")
    func parsesRealDayShape() throws {
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(Self.dayFixture.utf8),
            symbol: Self.star50,
            wireSymbol: "sh000688",
            period: .day
        )
        try #require(candles.count == 2)

        let first = candles[0]
        #expect(first.open == 1385.500)
        // Third field is the close, not the high — the classic misread here.
        #expect(first.close == 1380.350)
        #expect(first.high == 1433.570)
        #expect(first.low == 1351.140)
        // Volume arrives in lots of 100 shares and must become shares.
        #expect(first.volume == 1_742_902_500)
        #expect(candles[1].volume == 561_981_200)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let comps = calendar.dateComponents([.year, .month, .day], from: first.time)
        #expect(comps.year == 2025)
        #expect(comps.month == 9)
        #expect(comps.day == 18)
    }

    @Test("The native week and month keys are selected, not the day key")
    func selectsWeekAndMonthKeys() throws {
        let fixture = #"""
        {"code":0,"data":{"sh600519":{
          "day":[["2026-01-05","1","2","3","0.5","10"]],
          "week":[["2026-01-09","10","20","30","5","100"],["2026-01-02","5","6","7","1","200"]],
          "month":[["2026-01-30","100","200","300","50","1000"]]
        }}}
        """#
        let symbol = SymbolID(market: .sh, code: "600519")

        let week = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8), symbol: symbol, wireSymbol: "sh600519", period: .week
        )
        #expect(week.map(\.close) == [6, 20])
        #expect(week.map(\.open) == [5, 10])

        let month = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8), symbol: symbol, wireSymbol: "sh600519", period: .month
        )
        #expect(month.count == 1)
        #expect(month.first?.close == 200)
    }

    @Test("Numeric row values decode as well as the usual strings")
    func acceptsNumericRows() throws {
        let fixture = #"""
        {"code":0,"data":{"sz399001":{"day":[[20260105,10.5,11.25,12,9.5,1000]]}}}
        """#
        // A number where a date string belongs is unusable; the row drops out and
        // the error surfaces rather than an empty success.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(fixture.utf8),
                symbol: SymbolID(market: .sz, code: "399001"),
                wireSymbol: "sz399001",
                period: .day
            )
        }

        // Numeric OHLC and volume in the shape a JSON encoder would emit.
        let numeric = #"""
        {"code":0,"data":{"sz399001":{"day":[["2026-01-05",10.5,11.25,12,9.5,1000],["2026-01-06","10","11","12","9","2000"]]}}}
        """#
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(numeric.utf8),
            symbol: SymbolID(market: .sz, code: "399001"),
            wireSymbol: "sz399001",
            period: .day
        )
        #expect(candles.count == 2)
        #expect(candles[0].high == 12)
        #expect(candles[0].volume == 100_000)  // lots → shares
        #expect(candles[1].volume == 200_000)
    }

    @Test("Rows are returned oldest first and a repeated date keeps the last row")
    func sortsAndDeduplicates() throws {
        let fixture = #"""
        {"code":0,"data":{"sh000001":{"day":[
          ["2026-01-05","10","11","12","9","100"],
          ["2025-12-31","8","9","10","7","50"],
          ["2026-01-05","20","21","22","19","300"]
        ]}}}
        """#
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8),
            symbol: SymbolID(market: .sh, code: "000001"),
            wireSymbol: "sh000001",
            period: .day
        )
        #expect(candles.count == 2)
        #expect(candles[0].time < candles[1].time)
        #expect(candles[0].close == 9)
        // The newer row for the duplicated date wins.
        #expect(candles[1].open == 20)
        #expect(candles[1].close == 21)
    }

    @Test("Malformed, non-finite and self-contradicting rows are dropped, not charted")
    func dropsBadRows() throws {
        // Every row below is bad for exactly one reason, except the first two,
        // which are the controls that must survive alongside them.
        let fixture = #"""
        {"code":0,"data":{"sh600519":{"day":[
          ["2026-01-05","10","11","12","9","100"],
          ["2026-01-09","10","11","11","9","not-a-number"],
          ["2026-01-06","10","11"],
          ["2026-01-07","0","0","0","0","10"],
          ["2026-01-08","-5","-4","-3","-6","10"],
          ["2026-13-45","10","11","12","9","10"],
          ["2026-01-12","10","11","9.5","9","10"],
          ["2026-01-13","10","11","12","11","10"],
          ["2026-01-14","nan","11","12","9","10"],
          ["2026-01-15","10","11","infinity","9","10"]
        ]}}}
        """#
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )
        // Only the two controls survive; none of the eight bad rows is charted.
        try #require(candles.count == 2)
        #expect(candles.map(\.close) == [11, 11])
        #expect(candles.map(\.open) == [10, 10])

        // The surviving row with the unreadable volume keeps its price and goes nil.
        let unreadableVolume = try #require(candles.last)
        #expect(unreadableVolume.high == 11)
        #expect(unreadableVolume.low == 9)
        #expect(unreadableVolume.volume == nil)
    }

    @Test("Volume that is absent or negative becomes nil without losing the bar")
    func toleratesUnusableVolume() throws {
        let fixture = #"""
        {"code":0,"data":{"sh600519":{"day":[
          ["2026-01-05","10","11","12","9","100"],
          ["2026-01-06","10","11","12","9"],
          ["2026-01-07","10","11","12","9","-3"],
          ["2026-01-08","10","11","12","9",""],
          ["2026-01-09","10","11","12","9","0"]
        ]}}}
        """#
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )
        // The short row is still a valid bar (trailing fields are optional).
        try #require(candles.count == 5)
        #expect(candles[0].volume == 10_000)
        #expect(candles.map(\.volume) == [10_000, nil, nil, nil, 0])
    }

    @Test("A wrong symbol in the payload is isolated, not silently answered")
    func rejectsWrongSymbol() {
        // Correct symbol key but malformed JSON.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":0,"data":{"sh000688":"#.utf8),
                symbol: Self.star50,
                wireSymbol: "sh000688",
                period: .day
            )
        }

        // A non-zero code from the source is a source-side failure.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":1,"msg":"bad","data":{}}"#.utf8),
                symbol: Self.star50,
                wireSymbol: "sh000688",
                period: .day
            )
        }

        // Another instrument's payload must not be read as this symbol's history.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":0,"data":{"sh600519":{"day":[["2026-01-05","10","11","12","9","10"]]}}}"#.utf8),
                symbol: Self.star50,
                wireSymbol: "sh000688",
                period: .day
            )
        }

        // Usable-looking metadata but no rows for the requested interval.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":0,"data":{"sh000688":{"qt":{"sh000688":["1","科创50"]}}}}"#.utf8),
                symbol: Self.star50,
                wireSymbol: "sh000688",
                period: .week
            )
        }

        // Every row unusable: an error, never an empty success.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":0,"data":{"sh000688":{"day":[["2026-01-05","10","11"]]}}}"#.utf8),
                symbol: Self.star50,
                wireSymbol: "sh000688",
                period: .day
            )
        }
    }

    @Test("Interval names map to the wire spelling and intraday periods have none")
    func intervalMapping() {
        #expect(TencentProvider.historyInterval(for: .day) == "day")
        #expect(TencentProvider.historyInterval(for: .week) == "week")
        #expect(TencentProvider.historyInterval(for: .month) == "month")
        #expect(TencentProvider.historyInterval(for: .minute1) == nil)
        #expect(TencentProvider.historyInterval(for: .hour1) == nil)
        #expect(TencentProvider.historyMaxCount == 640)
    }

    @Test("A non-positive count answers empty without touching the network")
    func nonPositiveCountDoesNotNetwork() async throws {
        // The URL is unroutable, so any request would fail loudly; returning []
        // proves the guard short-circuits before networking.
        let provider = TencentProvider(
            http: HTTPClient(session: URLSession(configuration: .ephemeral))
        )
        for period in [CandlePeriod.day, .week, .month] {
            let candles = try await provider.candles(for: Self.star50, period: period, count: 0)
            #expect(candles.isEmpty)
            let negative = try await provider.candles(for: Self.star50, period: period, count: -5)
            #expect(negative.isEmpty)
        }
    }

    @Test("History is refused for markets and timeframes the provider does not serve")
    func refusesUnsupportedRequests() async {
        let provider = TencentProvider()
        await #expect(throws: ProviderError.self) {
            try await provider.candles(for: SymbolID(market: .hk, code: "700"), period: .day, count: 10)
        }
        await #expect(throws: ProviderError.self) {
            try await provider.candles(for: SymbolID(market: .us, code: "AAPL"), period: .week, count: 10)
        }
        await #expect(throws: ProviderError.self) {
            try await provider.candles(for: SymbolID(metal: .gold), period: .month, count: 10)
        }
    }

    // MARK: - Robustness of one realistic response

    /// One coherent fqkline answer, of the shape the endpoint actually returns,
    /// carrying every hazard at once: valid rows interleaved with null, object,
    /// string, empty-array and self-contradicting rows; arbitrary metadata keys
    /// before, between and after the series; trailing per-row fields; and a
    /// volume that overflows when converted from lots to shares.
    ///
    /// Only the four Chinese names are real rows. Everything else is crafted to
    /// prove the parser drops the bad and keeps the good.
    static let robustFixture = #"""
    {"code":0,"msg":"","data":{"sh600519":{
      "qt":{"sh600519":["1","贵州茅台","600519","1500.00"]},
      "prec":"1490.00",
      "version":"2.1",
      "day":[
        ["2026-01-05","1500.00","1510.00","1520.00","1495.00","12345.000"],
        null,
        ["2026-01-06","1510.00","1505.00","1515.00","1500.00","6789"],
        {"date":"2026-01-07","open":"1","close":"1","high":"1","low":"1"},
        ["2026-01-08","10","11","12","9",1e308],
        "2026-01-09,10,11,12,9,100",
        [],
        ["2026-01-12","10","11","12","9","100","trailing","extra"],
        ["2026-01-13","10","11"],
        ["2026-01-14","10","11","9.5","9","10"],
        ["2026-01-15","10","11","12","9",null],
        ["2026-01-16","0","0","0","0","10"],
        ["2026-01-19","10","11","12","9","-5"],
        ["2026-13-45","10","11","12","9","10"],
        {"unknown":"metadata"},
        ["2026-01-21","1502.00","1508.00","1512.00","1501.00","24680.000"]
      ],
      "trailing":"ignored",
      "week":[["2026-01-09","10","20","30","5","100"]]
    }}}
    """#

    @Test("Valid rows survive null, object and non-array neighbours in one response")
    func robustFixtureKeepsValidRows() throws {
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(Self.robustFixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )

        // Exactly the valid Chinese dates, oldest first, with nothing filtered
        // out by a neighbouring malformed row: the 7th (object), 9th (string),
        // 13th (short), 14th (high below the open), 16th (zero) and 19th
        // (impossible date) are gone, as are the two bare objects.
        #expect(candles.count == 7)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let days = candles.map { calendar.dateComponents([.day], from: $0.time).day }
        #expect(days == [5, 6, 8, 12, 15, 19, 21])

        // The good rows keep their OHLC, including the two that merely have a
        // corner-case field (trailing extras, missing volume).
        let first = candles[0]
        #expect(first.open == 1500.00)
        #expect(first.close == 1510.00)
        #expect(first.high == 1520.00)
        #expect(first.low == 1495.00)
        #expect(first.volume == 1_234_500)

        // Trailing per-row fields are ignored, not treated as part of the row.
        let extraFields = try #require(candles.first { calendar.dateComponents([.day], from: $0.time).day == 12 })
        #expect(extraFields.volume == 10_000)
        #expect(extraFields.close == 11)

        let last = try #require(candles.last)
        #expect(last.open == 1502.00)
        #expect(last.close == 1508.00)
        #expect(last.volume == 2_468_000)
    }

    @Test("Volume whose lot-to-share conversion overflows becomes nil, keeping the bar")
    func volumeOverflowBecomesNil() throws {
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(Self.robustFixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let overflowing = try #require(
            candles.first { calendar.dateComponents([.day], from: $0.time).day == 8 }
        )
        // 1e308 lots is finite on the wire, but 1e308 * 100 is not a Double:
        // the bar's price is real and must be charted, its volume must be nil.
        #expect(overflowing.volume == nil)
        #expect(overflowing.open == 10)
        #expect(overflowing.close == 11)
        #expect(overflowing.high == 12)
        #expect(overflowing.low == 9)

        // A nil volume alongside a present one is not a parse failure.
        let missingVolume = try #require(
            candles.first { calendar.dateComponents([.day], from: $0.time).day == 15 }
        )
        #expect(missingVolume.volume == nil)
        #expect(missingVolume.close == 11)

        // Negative volume is likewise unusable but keeps its bar.
        let negativeVolume = try #require(
            candles.first { calendar.dateComponents([.day], from: $0.time).day == 19 }
        )
        #expect(negativeVolume.volume == nil)
        #expect(negativeVolume.close == 11)

        // The finite volumes in the same response are untouched; the two
        // unusable ones are absent from the list rather than zero.
        #expect(candles.compactMap(\.volume) == [1_234_500, 678_900, 10_000, 2_468_000])
        #expect(candles.compactMap(\.volume).count == 4)
        #expect(candles.count == 7)
    }

    @Test("Metadata keys around the series never become rows")
    func metadataIsIgnored() throws {
        // `qt` is a nested object and `trailing` a string: neither decodes as
        // rows, while `week` does and must not answer a day request.
        let week = try TencentProvider.parseHistoricalCandles(
            Data(Self.robustFixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .week
        )
        #expect(week.count == 1)
        #expect(week[0].close == 20)

        // The day series is unaffected by the metadata in front of it.
        let day = try TencentProvider.parseHistoricalCandles(
            Data(Self.robustFixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )
        #expect(day.count == 7)
        #expect(day.allSatisfy { $0.volume.map { $0.isFinite } ?? true })

        // A payload that is nothing but metadata still errors rather than
        // reporting an empty success.
        #expect(throws: ProviderError.self) {
            try TencentProvider.parseHistoricalCandles(
                Data(#"{"code":0,"data":{"sh600519":{"qt":{},"prec":"1","trailing":"x"}}}"#.utf8),
                symbol: SymbolID(market: .sh, code: "600519"),
                wireSymbol: "sh600519",
                period: .day
            )
        }
    }

    @Test("A row whose date slot holds a number is unusable, not coerced")
    func numericDateRowIsDropped() throws {
        let fixture = #"""
        {"code":0,"data":{"sh600519":{"day":[
          ["2026-01-05","10","11","12","9","100"],
          [20260106,10,11,12,9,200],
          ["2026-01-07","10","11","12","9","300"]
        ]}}}
        """#
        let candles = try TencentProvider.parseHistoricalCandles(
            Data(fixture.utf8),
            symbol: SymbolID(market: .sh, code: "600519"),
            wireSymbol: "sh600519",
            period: .day
        )
        // The numeric-date row between two valid ones disappears alone.
        #expect(candles.count == 2)
        #expect(candles.map(\.volume) == [10_000, 30_000])
    }
}
