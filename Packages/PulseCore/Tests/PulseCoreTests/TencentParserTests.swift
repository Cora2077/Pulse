import Foundation
import Testing
@testable import PulseCore

@Suite("Tencent quote parsing")
struct TencentParserTests {
    /// Excerpt from a real API response (intraday, 2026-07-03)
    static let aShareFixture = """
    v_sh600519="1~贵州茅台~600519~1191.53~1203.00~1205.24~19108~8113~10970~1191.53~3~1191.51~3~1191.48~8~1191.43~1~1191.35~1~1192.80~1~1192.84~3~1192.85~2~1192.90~1~1193.18~1~~20260703112400~-11.47~-0.95~1210.14~1190.50~1191.53/19108/2293596002~19108~229360~0.15~18.01~~1210.14~1190.50~1.63~14895.10~14895.10~6.40~1323.30~1082.70~0.80~8~1200.32~13.67~18.09~~~0.34~229359.6002~0.0000~0~ ~GP-A~-11.68~1.96~4.37~30.53~26.78~1539.98~1151.01~0.38~-3.91~-16.79~1250081601~1250081601~33.33~-15.43~1250081601";
    """

    /// Excerpts from real HK/US API responses (2026-07-21). Unlike A-shares, field 37 is already the full local-currency amount.
    static let hkShareFixture = """
    v_hk00700="100~腾讯控股~00700~474.000~477.800~478.200~21362780.0~0~0~474.000~0~0~0~0~0~0~0~0~0~474.000~0~0~0~0~0~0~0~0~0~21362780.0~2026/07/21 16:08:11~-3.800~-0.80~482.600~472.800~474.000~21362780.0~10172603239.590~0~17.31~~0~0~2.05~43098.5272~43098.5272~TENCENT~1.12~677.700~411.000~0.63~18.95~0~0~0~0~0~16.19~3.43~0.23~100~-20.16~3.90~GP~20.59~11.53~2.78~9.47~-4.95~9092516289.00~9092516289.00~16.38~5.315~476.183~-23.33~HKD~1~50";
    """

    static let usShareFixture = """
    v_usAAPL="200~苹果~AAPL.OQ~326.59~333.74~333.51~53468008~0~0~325.70~160~0~0~0~0~0~0~0~0~326.00~80~0~0~0~0~0~0~0~0~~2026-07-20 16:00:01~-7.15~-2.14~333.71~323.68~USD~53468008~17479885376~0.36~39.54~~43.78~~3.01~47937.81058~47967.43596~Apple Inc.~8.26~334.99~200.72~80~45.04~0.32~47967.43596~20.35~2.92~GP~141.47~34.91~4.46~9.59~19.66~14687356000~14678284878~1.00~33.67~1.05~326.92~~~";
    """

    @Test("Parses an A-share snapshot")
    func parseAShare() throws {
        let symbol = SymbolID(market: .sh, code: "600519")
        let quotes = TencentProvider.parseQuotes(text: Self.aShareFixture, mapping: ["sh600519": symbol])
        let quote = try #require(quotes.first)

        #expect(quote.symbol == symbol)
        #expect(quote.name == "贵州茅台")
        #expect(quote.price == 1191.53)
        #expect(quote.previousClose == 1203.00)
        #expect(quote.open == 1205.24)
        #expect(quote.high == 1210.14)
        #expect(quote.low == 1190.50)
        #expect(quote.currencyCode == "CNY")
        // The derived change percent matches the API's own figure (-0.95%)
        #expect(abs(quote.changePercent - -0.95) < 0.01)
        // A-share volume (field 36) is in lots and must be converted to shares; cross-checked against the combined field "1191.53/19108/2293596002"
        let volume = try #require(quote.volume)
        #expect(abs(volume - 1_910_800.0) < 0.5)
        // Turnover (field 37) is in units of 10,000 CNY
        let turnover = try #require(quote.turnover)
        #expect(abs(turnover - 2_293_600_000.0) < 0.5)
    }

    @Test("Parses HK turnover as a full HKD amount")
    func parseHKShare() throws {
        let symbol = SymbolID(market: .hk, code: "700")
        let quotes = TencentProvider.parseQuotes(text: Self.hkShareFixture, mapping: ["hk00700": symbol])
        let quote = try #require(quotes.first)

        #expect(quote.symbol == symbol)
        #expect(quote.currencyCode == "HKD")
        #expect(quote.volume == 21_362_780)
        #expect(quote.turnover == 10_172_603_239.590)
    }

    @Test("Parses US turnover as a full USD amount")
    func parseUSShare() throws {
        let symbol = SymbolID(market: .us, code: "AAPL")
        let quotes = TencentProvider.parseQuotes(text: Self.usShareFixture, mapping: ["usAAPL": symbol])
        let quote = try #require(quotes.first)

        #expect(quote.symbol == symbol)
        #expect(quote.currencyCode == "USD")
        #expect(quote.volume == 53_468_008)
        #expect(quote.turnover == 17_479_885_376)
    }

    @Test("Rejects turnover with an implausible unit scale")
    func rejectsImplausibleTurnover() throws {
        let symbol = SymbolID(market: .hk, code: "700")
        let badFixture = Self.hkShareFixture.replacingOccurrences(
            of: "~10172603239.590~",
            with: "~101726032395900~"
        )
        let quotes = TencentProvider.parseQuotes(text: badFixture, mapping: ["hk00700": symbol])
        let quote = try #require(quotes.first)

        #expect(quote.turnover == nil)
    }

    @Test("Timestamps parsed in the exchange time zone")
    func timestamp() throws {
        let date = try #require(TencentProvider.parseTimestamp("20260703112400", timeZone: Market.sh.timeZone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(comps.year == 2026)
        #expect(comps.month == 7)
        #expect(comps.day == 3)
        #expect(comps.hour == 11)
        #expect(comps.minute == 24)

        // HK/US slash and dash formats must also parse
        #expect(TencentProvider.parseTimestamp("2026/07/02 16:08:00", timeZone: Market.hk.timeZone) != nil)
        #expect(TencentProvider.parseTimestamp("2026-07-02 16:00:01", timeZone: Market.us.timeZone) != nil)
    }

    @Test("A-share minute series parses and aggregates into five-minute bars")
    func minuteCandles() throws {
        let rows = [
            "0930 10.00 10 1000.00",
            "0931 11.00 13 1300.00",
            "0934 9.00 20 2000.00",
            "bad row",
            "0935 12.00 25 2500.00",
        ]

        let oneMinute = TencentProvider.parseMinuteCandles(
            date: "20260710", rows: rows, market: .sh, period: .minute1
        )
        #expect(oneMinute.count == 4)
        #expect(oneMinute.map(\.close) == [10, 11, 9, 12])
        #expect(oneMinute.compactMap(\.volume) == [1000, 300, 700, 500])

        let fiveMinute = TencentProvider.parseMinuteCandles(
            date: "20260710", rows: rows, market: .sh, period: .minute5
        )
        #expect(fiveMinute.count == 2)
        let first = try #require(fiveMinute.first)
        #expect(first.open == 10)
        #expect(first.high == 11)
        #expect(first.low == 9)
        #expect(first.close == 9)
        #expect(first.volume == 2000)
        #expect(fiveMinute.last?.close == 12)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        #expect(calendar.component(.hour, from: first.time) == 9)
        #expect(calendar.component(.minute, from: first.time) == 30)

        let now = try #require(TencentProvider.parseTimestamp("20260710104324", timeZone: Market.sh.timeZone))
        let provisional = TencentProvider.parseMinuteCandles(
            date: "20260710",
            rows: ["1044 12.50 30 3000.00"],
            market: .sh,
            period: .minute1,
            now: now
        )
        #expect(provisional.first?.time == now)
    }

    @Test("A-share hourly bars anchor to each continuous trading session")
    func hourlyCandlesRespectLunchBreak() throws {
        let rows = [
            "0930 10.00 10",
            "1029 11.00 20",
            "1030 12.00 30",
            "1130 13.00 40",
            "1300 14.00 50",
            "1359 15.00 60",
            "1400 16.00 70",
            "1500 17.00 80",
        ]

        let candles = TencentProvider.parseMinuteCandles(
            date: "20260710", rows: rows, market: .sh, period: .hour1
        )

        #expect(candles.count == 4)
        #expect(candles.map(\.open) == [10, 12, 14, 16])
        #expect(candles.map(\.close) == [11, 13, 15, 17])
        #expect(candles.compactMap(\.volume) == [2_000, 2_000, 2_000, 2_000])
    }

    /// Excerpt from a real `hf_` response (international futures, 2026-08-19).
    /// Fourteen comma-separated fields, no volume, timestamps in Beijing time.
    static let metalFixture = """
    v_hf_GC="4413.61,-0.16,4412.90,4413.30,4417.20,4378.00,16:53:00,4420.60,4391.40,0,2,2,2026-08-19,纽约黄金";
    v_hf_XPD="1292.30,-0.10,1291.50,1293.00,1295.00,1279.50,16:51:36,1293.60,1289.50,0,4,3,2026-08-19,纽约钯金";
    """

    @Test("Parses an international metal snapshot")
    func parseMetal() throws {
        let gold = SymbolID(metal: .gold)
        let palladium = SymbolID(metal: .palladium)
        let quotes = TencentProvider.parseQuotes(
            text: Self.metalFixture,
            mapping: ["hf_GC": gold, "hf_XPD": palladium]
        )
        #expect(quotes.count == 2)

        let quote = try #require(quotes.first { $0.symbol == gold })
        #expect(quote.name == "纽约黄金")
        #expect(quote.price == 4413.61)
        #expect(quote.previousClose == 4420.60)
        #expect(quote.open == 4391.40)
        #expect(quote.high == 4417.20)
        #expect(quote.low == 4378.00)
        #expect(quote.currencyCode == "USD")
        // The derived change percent matches the API's own figure (-0.16%)
        #expect(abs(quote.changePercent - -0.16) < 0.01)
        // The channel reports open interest and bid/ask sizes, never traded volume.
        #expect(quote.volume == nil)
        #expect(quote.turnover == nil)

        // Date and time are stamped in Beijing time whatever the contract's exchange.
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = beijing.dateComponents([.year, .month, .day, .hour, .minute], from: quote.timestamp)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 19)
        #expect(parts.hour == 16)
        #expect(parts.minute == 53)
    }

    @Test("A metal payload without a usable reference still quotes its price")
    func parseMetalWithoutPreviousClose() throws {
        let fixture = #"v_hf_SI="63.29,0.00,63.29,63.30,0.00,0.00,00:00:00,0.00,0.00,0,0,0,2026-08-19,纽约白银";"#
        let silver = SymbolID(metal: .silver)
        let quote = try #require(
            TencentProvider.parseQuotes(text: fixture, mapping: ["hf_SI": silver]).first
        )
        #expect(quote.price == 63.29)
        #expect(quote.previousClose == 63.29)
        #expect(quote.changePercent == 0)
        #expect(quote.open == nil)
        #expect(quote.high == nil)
        #expect(quote.low == nil)
    }

    @Test("Tencent candle coverage spans A-share intraday and daily history, and no other market")
    func candleCoverage() {
        let descriptor = TencentProvider().descriptor
        #expect(descriptor.supports(candles: .minute1, in: .sh))
        #expect(descriptor.supports(candles: .minute5, in: .sz))
        #expect(descriptor.supports(candles: .minute15, in: .sh))
        #expect(descriptor.supports(candles: .minute30, in: .sz))
        #expect(descriptor.supports(candles: .hour1, in: .sh))
        #expect(descriptor.supports(candles: .day, in: .sh))
        #expect(descriptor.supports(candles: .week, in: .sz))
        #expect(descriptor.supports(candles: .month, in: .sh))
        #expect(descriptor.candlePeriods == Set(CandlePeriod.allCases))
        // Other markets keep only quoting: no HK/US history is advertised here.
        #expect(!descriptor.supports(candles: .day, in: .hk))
        #expect(!descriptor.supports(candles: .minute1, in: .hk))
        #expect(!descriptor.supports(candles: .week, in: .us))
        #expect(descriptor.candleMarkets == [.sh, .sz])
    }

    /// Excerpt from a real smartbox response (query: Tencent's Chinese name); the real API returns names in \uXXXX escaped form
    static let smartboxFixture = #"v_hint="sh~000847~腾讯济安~txja~ZS^hk~00700~腾讯控股~txkg~GP^us~tcehy.ps~腾讯控股(adr)~txkgadr~GP^us~tme.n~腾讯音乐~txyl~GP^bk~123456~板块~bk~BK""#

    @Test("smartbox search parsing")
    func parseSearch() throws {
        let results = TencentProvider.parseSearch(text: Self.smartboxFixture)

        // Sector (bk) entries should be filtered out
        #expect(results.count == 4)

        let tencent = try #require(results.first { $0.symbol == SymbolID(market: .hk, code: "700") })
        #expect(tencent.name == "腾讯控股")
        #expect(tencent.type == .equity)

        // US codes have their exchange suffix stripped and are uppercased
        #expect(results.contains { $0.symbol == SymbolID(market: .us, code: "TME") })
        #expect(results.contains { $0.symbol == SymbolID(market: .us, code: "TCEHY") })

        // Index type recognition
        let index = try #require(results.first { $0.symbol == SymbolID(market: .sh, code: "000847") })
        #expect(index.type == .index)
    }

    @Test("Unicode unescaping")
    func unescape() {
        // "\\u817e\\u8baf..." is the literal escaped form returned by the real API; it should decode to the Chinese name
        #expect(TencentProvider.unescapeUnicode("\\u817e\\u8baf\\u63a7\\u80a1") == "腾讯控股")
        #expect(TencentProvider.unescapeUnicode("AAPL") == "AAPL")
        #expect(TencentProvider.unescapeUnicode("\\u817e\\u8baf\\u63a7\\u80a1(adr)") == "腾讯控股(adr)")
    }

    @Test("smartbox escaped names parsed end to end")
    func parseSearchEscaped() throws {
        // The name field is \uXXXX-escaped (matching the real API) and should decode back to Chinese
        let fixture = "v_hint=\"hk~00700~\\u817e\\u8baf\\u63a7\\u80a1~txkg~GP\""
        let results = TencentProvider.parseSearch(text: fixture)
        let tencent = try #require(results.first)
        #expect(tencent.name == "腾讯控股")
        #expect(tencent.symbol == SymbolID(market: .hk, code: "700"))
    }

    @Test("Bad lines and unrequested keys are ignored")
    func garbage() {
        let text = """
        v_sh600519="1~贵州茅台~600519";
        v_unknown="1~x~y~1.0~1.0~1.0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~20260703112400~0~0~1~1~x~0~0~0";
        garbage line without equals
        """
        let quotes = TencentProvider.parseQuotes(
            text: text,
            mapping: ["sh600519": SymbolID(market: .sh, code: "600519")]
        )
        #expect(quotes.isEmpty)
    }

    /// Two US lines from the real `qt.gtimg.cn` snapshot body, GBK-decoded to
    /// Swift strings: the second code answers with an empty name field, and
    /// `usMSFT` was never requested.
    static let securityNamesFixture = """
    v_usPDD="200~拼多多~PDD.OQ~120.55~118.20~119.00~3481200~0~0~120.50~10~0~0~0~0~0~0~0~0~120.60~10~0~0~0~0~0~0~0~0~~2026-07-20 16:00:01~2.35~1.99~121.30~118.10~USD~3481200~419867600~0.30~12.40~~14.10~~2.10~1100.20~1102.40~PDD Holdings Inc.~1.20~122.00~80.00~50~15.20~0.20~1102.40~3.10~0.90~GP~20.10~10.20~1.10~2.30~4.50~1200000~1190000~1.00~2.10~0.50~120.70~~~";
    v_usTSLA="200~~TSLA.OQ~250.10~248.00~249.00~1000000~0~0~250.00~5~0~0~0~0~0~0~0~0~250.20~5~0~0~0~0~0~0~0~0~~2026-07-20 16:00:01~2.10~0.85~251.00~247.00~USD~1000000~250100000~0.20~60.00~~70.00~~1.50~2000.00~2000.00~Tesla, Inc.~2.00~260.00~150.00~40~30.00~0.50~2000.00~5.00~1.00~GP~40.00~20.00~2.00~3.00~5.00~900000~890000~1.00~3.00~0.80~250.00~~~";
    v_usMSFT="200~微软~MSFT.OQ~420.00~418.00~419.00~2000000~0~0~420.00~5~0~0~0~0~0~0~0~0~420.20~5~0~0~0~0~0~0~0~0~~2026-07-20 16:00:01~2.00~0.48~421.00~417.00~USD~2000000~840000000~0.30~35.00~~40.00~~1.20~3000.00~3000.00~Microsoft Corporation~1.50~430.00~300.00~60~20.00~0.40~3000.00~4.00~0.90~GP~30.00~15.00~1.50~2.50~3.50~1500000~1490000~1.00~2.50~0.60~420.00~~~";
    """

    @Test("Reference names come from the equity snapshot's name field")
    func parseSecurityNames() throws {
        let pdd = SymbolID(market: .us, code: "PDD")
        let tesla = SymbolID(market: .us, code: "TSLA")
        let names = TencentProvider.parseSecurityNames(
            text: Self.securityNamesFixture,
            mapping: ["usPDD": pdd, "usTSLA": tesla]
        )

        // The code with a real name is answered, in Simplified Chinese.
        let pddName = try #require(names.first { $0.symbol == pdd })
        #expect(pddName.name == "拼多多")
        #expect(pddName.localeIdentifier == "zh-Hans")

        // A name-less entry is skipped rather than returned as an empty name.
        #expect(names.count == 1)
        #expect(!names.contains { $0.symbol == tesla })

        // A code absent from the body is silently omitted: that is not an error.
        #expect(!names.contains { $0.symbol == SymbolID(market: .us, code: "MSFT") })
    }

    @Test("Reference names ignore the international-futures channel and unrequested keys")
    func parseSecurityNamesSkipsOtherChannels() throws {
        let gold = SymbolID(metal: .gold)
        let names = TencentProvider.parseSecurityNames(
            text: Self.metalFixture,
            mapping: ["hf_GC": gold, "usAAPL": SymbolID(market: .us, code: "AAPL")]
        )
        // `hf_` payloads are comma-separated and never name an equity.
        #expect(names.isEmpty)

        // An empty request body is not an error either.
        #expect(TencentProvider.parseSecurityNames(text: "", mapping: [:]).isEmpty)
    }

    /// The real endpoint names part of the US board in Latin script: these are
    /// the literal field-1 values `usIBM`, `usMETA` and `usLITE` answer with.
    static let latinNameFixture = """
    v_usIBM="200~IBM~IBM.N~280.10~278.00~279.00~1000000~0~0~280.00~5~0~0~0~0~0~0~0~0~280.20~5~0~0~0~0~0~0~0~0~~2026-07-20 16:00:01~2.10~0.76~281.00~277.00~USD~1000000~280100000~0.20~25.00~~30.00~~1.50~2000.00~2000.00~International Business Machines~2.00~290.00~200.00~40~20.00~0.50~2000.00~5.00~1.00~GP~40.00~20.00~2.00~3.00~5.00~900000~890000~1.00~3.00~0.80~280.00~~~";
    v_usMETA="200~Meta Platforms~META.OQ~620.00~618.00~619.00~1000000~0~0~620.00~5~0~0~0~0~0~0~0~0~620.20~5~0~0~0~0~0~0~0~~2026-07-20 16:00:01~2.00~0.32~621.00~617.00~USD~1000000~620000000~0.30~30.00~~35.00~~1.20~3000.00~3000.00~Meta Platforms, Inc.~1.50~630.00~500.00~60~20.00~0.40~3000.00~4.00~0.90~GP~30.00~15.00~1.50~2.50~3.50~1500000~1490000~1.00~2.50~0.60~620.00~~~";
    """

    @Test("A Latin listing name is not returned as a Chinese reference name")
    func parseSecurityNamesRejectsLatinNames() throws {
        let ibm = SymbolID(market: .us, code: "IBM")
        let meta = SymbolID(market: .us, code: "META")
        let names = TencentProvider.parseSecurityNames(
            text: Self.latinNameFixture,
            mapping: ["usIBM": ibm, "usMETA": meta]
        )

        // Neither is Chinese, so neither may be stamped `zh-Hans`: accepting them
        // would replace a stored English name on the strength of provenance the
        // source never supplied, and the row would keep its Latin name anyway.
        #expect(names.isEmpty)

        // The detector itself, both ways.
        #expect(SecurityName.isChineseName("苹果"))
        #expect(SecurityName.isChineseName("IBM国际商业机器"))
        #expect(!SecurityName.isChineseName("IBM"))
        #expect(!SecurityName.isChineseName("Meta Platforms"))
        #expect(!SecurityName.isChineseName(""))
        #expect(!SecurityName.isChineseName("600519"))
    }

    @Test("A names-only decode failure cannot trip the quote circuit")
    func undecodableNameResponseDoesNotTripCircuit() {
        // Name resolution is best-effort: prices must keep flowing when only the
        // label lookup fails. Quotes are the product and still trip the circuit
        // for a real outage; a missing label must not take prices down with it.
        let failure = ProviderError.clientError(status: 200, detail: "tencent: undecodable name response")
        #expect(!failure.shouldTripCircuit)

        // Guard the distinction the other way too, so this cannot be "fixed" by
        // making every Tencent error non-tripping.
        #expect(ProviderError.badResponse("x").shouldTripCircuit)
        #expect(ProviderError.network(underlying: "timed out").shouldTripCircuit)
    }
}
