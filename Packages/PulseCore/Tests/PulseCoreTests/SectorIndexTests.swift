import Foundation
import Testing
@testable import PulseCore

@Suite("Tonghuashun sector boards")
struct SectorIndexTests {
    // MARK: - Identity

    @Test("A board code becomes a board, not an A-share equity")
    func boardIdentity() {
        let board = SymbolID(market: .sh, code: "881155")
        #expect(board.sectorIndex?.name == "银行")
        #expect(board.market == .sh)
        #expect(board.code == "881155")
        #expect(board.indexID == nil)
        #expect(board.metalID == nil)
        #expect(board.cryptoPair == nil)
        // A calculated benchmark has no issuer to describe and no position to hold.
        #expect(board.isDescribable == false)
    }

    @Test("Ordinary A-share codes are untouched")
    func ordinaryCodesUnaffected() {
        for code in ["600519", "000001", "000858", "300750", "688981"] {
            #expect(SymbolID(market: .sh, code: code).sectorIndex == nil)
            #expect(SymbolID(market: .sz, code: code).sectorIndex == nil)
        }
        // The board range is claimed by exact membership, so a code one digit off
        // an existing board stays an ordinary symbol.
        #expect(SymbolID(market: .sh, code: "8811550").sectorIndex == nil)
        #expect(SymbolID(market: .sh, code: "881154").sectorIndex == nil)
        #expect(SymbolID(market: .sh, code: "999999").sectorIndex == nil)
    }

    @Test("The catalog covers every industry board")
    func catalogIsComplete() {
        #expect(SectorIndexCatalog.all.count == 90)
        // Every entry resolves both ways, and every code is a six-digit
        // `881xxx` industry code.
        for board in SectorIndexCatalog.all {
            #expect(SectorIndexCatalog.board(code: board.code) == board)
            #expect(SectorIndexCatalog.board(named: board.name) == board)
            #expect(board.code.count == 6)
            #expect(board.code.hasPrefix("881"))
        }
        #expect(SectorIndexCatalog.board(code: "881155")?.name == "银行")
        #expect(SectorIndexCatalog.board(named: "银行")?.code == "881155")
        // A concept board in the same family is deliberately not carried yet.
        #expect(SectorIndexCatalog.board(code: "885900") == nil)
    }

    @Test("The catalog's names are unique and non-empty")
    func catalogNamesAreUsable() {
        let names = SectorIndexCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    // MARK: - Search

    @Test("Everyday phrasings find the board")
    func searchFindsBoards() {
        let cases: [(String, String)] = [
            ("银行", "881155"), ("881155", "881155"), ("88115", "881155"),
            ("证券", "881157"), ("券商", "881157"), ("白酒", "881273"),
            ("半导体", "881121"), ("银行指数", "881155"), ("银行板块", "881155"),
            ("保险", "881156"), ("稀土", "881170"), ("PCB", "881270"),
            // A pasted provider URL form keeps working.
            ("bk_881155", "881155"), ("881155.SH", "881155"),
        ]
        for (query, expected) in cases {
            let hits = SectorIndexCatalog.search(query)
            #expect(hits.contains { $0.symbol.code == expected },
                    "\(query) did not find \(expected); got \(hits.prefix(3).map(\.symbol.code))")
        }
    }

    @Test("A board result is typed as an index and names its source")
    func searchResultShape() {
        let hit = SectorIndexCatalog.search("银行").first
        #expect(hit?.type == .index)
        #expect(hit?.name == "银行")
        #expect(hit?.exchangeName == SectorIndexID.exchangeName)
        #expect(hit?.resolvedDisplayName == "银行")
    }

    @Test("The category word lists the industry set")
    func categoryListsBoards() {
        #expect(SectorIndexCatalog.search("行业").count == 90)
        #expect(SectorIndexCatalog.search("行业板块").count == 90)
        #expect(SectorIndexCatalog.search("INDUSTRY").count == 90)
    }

    @Test("Search does not claim unrelated queries")
    func searchStaysExact() {
        // A company name that merely contains an industry word is not a board.
        #expect(SectorIndexCatalog.search("招商银行").isEmpty)
        #expect(SectorIndexCatalog.search("贵州茅台").isEmpty)
        #expect(SectorIndexCatalog.search("").isEmpty)
        // One latin letter is noise; one CJK character is a word.
        #expect(SectorIndexCatalog.search("a").isEmpty)
        #expect(!SectorIndexCatalog.search("煤").isEmpty)
    }

    @Test("An exact name outranks a partial one")
    func searchRanksExactFirst() {
        // "保险" is a board; it must precede any board whose name merely
        // contains it, and "银行" must precede "银行" anything.
        let bank = SectorIndexCatalog.search("银行")
        #expect(bank.first?.name == "银行")
        #expect(bank.count == 1)
    }

    // MARK: - Routing

    @Test("The board source covers boards and nothing else")
    func providerCoverageIsExclusive() {
        let provider = ThsSectorProvider()
        #expect(provider.covers(SymbolID(market: .sh, code: "881155")) == true)
        #expect(provider.covers(SymbolID(market: .sh, code: "600519")) == false)
        #expect(provider.covers(SymbolID(market: .sz, code: "000858")) == false)
        #expect(provider.covers(SymbolID(index: .shanghaiComposite)) == false)
    }

    @Test("Exchange sources never claim a board")
    func exchangeProvidersDoNotClaimBoards() {
        // The default `covers` is what every pre-existing source inherits, and it
        // is what stops a board from being dispatched to a source whose failure
        // would trip the circuit breaker shared with real stocks.
        let board = SymbolID(market: .sh, code: "881155")
        #expect(TencentProvider().covers(board) == false)
        #expect(YahooProvider().covers(board) == false)
        #expect(SinaProvider().covers(board) == false)
        #expect(EastmoneyProvider().covers(board) == false)
        // And they still cover what they always did.
        #expect(TencentProvider().covers(SymbolID(market: .sh, code: "600519")) == true)
    }

    @Test("Coverage is dispatched through the protocol, not statically")
    func coverageDispatchesDynamically() {
        // Routing holds providers as `any QuoteProvider`. A member declared only
        // in a protocol extension is dispatched statically, so the default would
        // run even for a source that overrides it — and routing would think no
        // source can price a board. Asserting through the existential is what
        // catches that; calling on the concrete type does not.
        let board = SymbolID(market: .sh, code: "881155")
        let stock = SymbolID(market: .sh, code: "600519")
        let providers: [any QuoteProvider] = [ThsSectorProvider(), TencentProvider()]
        #expect(providers[0].covers(board))
        #expect(providers[0].covers(stock) == false)
        #expect(providers[1].covers(board) == false)
        #expect(providers[1].covers(stock))
    }

    @Test("The composite routes a board to the board source alone")
    func compositeRoutesBoardsOnlyToItsSource() async {
        let board = SymbolID(market: .sh, code: "881155")
        let stock = SymbolID(market: .sh, code: "600519")
        let composite = CompositeProvider(providers: [TencentProvider(), ThsSectorProvider()])

        let routing = await composite.quoteRouting(for: [board, stock])
        // A board is this source's alone; the stock is never handed to it.
        #expect(routing[ThsSectorProvider.providerID] == [board])
        #expect(routing["tencent"] == [stock])
        #expect(routing.values.flatMap { $0 }.contains(board) == false
                || routing[ThsSectorProvider.providerID]?.contains(board) == true)
    }

    @Test("A board with no board source fails cleanly instead of tripping a breaker")
    func noBoardSourceFailsCleanly() async throws {
        // Without the board source, nothing can price a board — and the exchange
        // sources must not be asked, because their failure would open the circuit
        // the user's real quotes depend on. An empty answer is the honest one:
        // the board has no source rather than a source that failed.
        let board = SymbolID(market: .sh, code: "881155")
        let composite = CompositeProvider(providers: [TencentProvider()])
        let quotes = try await composite.quotes(for: [board])
        #expect(quotes.isEmpty)
        #expect(await composite.healthReport()["tencent"] == "healthy")

        // A chart is where missing coverage surfaces, since candles cannot answer
        // with "nothing" without drawing an empty panel.
        await #expect(throws: ProviderError.self) {
            _ = try await composite.candles(for: board, period: .day, count: 60)
        }
        #expect(await composite.healthReport()["tencent"] == "healthy")
    }

    @Test("The board source declares the periods its endpoints actually serve")
    func descriptorCoverage() {
        let descriptor = ThsSectorProvider().descriptor
        #expect(descriptor.id == ThsSectorProvider.providerID)
        #expect(descriptor.markets == [.sh])
        #expect(descriptor.supports(.quotes, in: .sh))
        #expect(descriptor.supports(.candles, in: .sh))
        #expect(descriptor.supports(.search, in: .sh))
        // Every resolution the chart can ask for is answered, one way or another.
        for period in CandlePeriod.allCases {
            #expect(descriptor.supports(candles: period, in: .sh), "\(period) unsupported")
        }
        // It must not claim the markets it cannot address.
        #expect(descriptor.supports(.quotes, in: .us) == false)
        #expect(descriptor.supports(.quotes, in: .hk) == false)
    }

    @Test("The wire paths match the endpoint contract")
    func wirePaths() {
        let board = SectorIndexCatalog.board(code: "881155")!
        #expect(ThsSectorProvider.wireCode(for: board) == "bk_881155")
        #expect(ThsSectorProvider.linePath(for: .day, board: board)
            == "v6/line/bk_881155/02/last.js")
        #expect(ThsSectorProvider.linePath(for: .week, board: board)
            == "v6/line/bk_881155/10/last.js")
        #expect(ThsSectorProvider.linePath(for: .month, board: board)
            == "v6/line/bk_881155/20/last.js")
        #expect(ThsSectorProvider.linePath(for: .minute5, board: board)
            == "v6/line/bk_881155/32/last.js")
        #expect(ThsSectorProvider.linePath(for: .minute30, board: board)
            == "v6/line/bk_881155/42/last.js")
        #expect(ThsSectorProvider.linePath(for: .hour1, board: board)
            == "v6/line/bk_881155/52/last.js")
        // No 15-minute file exists, so it is folded out of the 5-minute series.
        #expect(ThsSectorProvider.linePath(for: .minute15, board: board)
            == "v6/line/bk_881155/32/last.js")
        // The trend line comes from the per-minute series, not a K-line file.
        #expect(ThsSectorProvider.linePath(for: .minute1, board: board) == nil)
    }

    @Test("Nothing but a board is asked of this source")
    func nonBoardsAreRejected() async {
        let provider = ThsSectorProvider()
        await #expect(throws: ProviderError.self) {
            _ = try await provider.quotes(for: [SymbolID(market: .sh, code: "600519")])
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.candles(
                for: SymbolID(market: .sh, code: "600519"), period: .day, count: 10
            )
        }
    }

    @Test("Names come from the catalog, not the wire")
    func namesAreLocal() async throws {
        let symbol = SymbolID(market: .sh, code: "881155")
        let names = try await ThsSectorProvider().securityNames(for: [symbol])
        #expect(names.count == 1)
        #expect(names.first?.name == "银行")
        #expect(names.first?.symbol == symbol)
        // An ordinary symbol is not this source's to name.
        await #expect(throws: ProviderError.self) {
            _ = try await ThsSectorProvider().securityNames(for: [SymbolID(market: .sh, code: "600519")])
        }
    }

    // MARK: - Instrument type

    @Test("A board resolves to an index everywhere and can hold no position")
    func boardIsAnIndex() {
        let symbol = SymbolID(market: .sh, code: "881155")
        #expect(WatchItem.normalizedInstrumentType(nil, for: symbol) == .index)
        // Even when the stored/inferred type disagrees, identity wins.
        #expect(WatchItem.normalizedInstrumentType(.equity, for: symbol) == .index)
        let item = WatchItem(symbol: symbol, displayName: "ignored")
        #expect(item.resolvedInstrumentType == .index)
        #expect(item.supportsPosition == false)
        #expect(item.resolvedDisplayName == "银行")
    }

    // MARK: - Parsing

    @Test("Quotes parse from the real payload shape")
    func parsesQuote() async throws {
        let payload = Data(#"""
        bk_881155({"items":{"6":"1401.281","7":"1399.054","8":"1417.920","9":"1373.083",
        "10":"1374.856","13":"3329399200.000","19":"25798262000.000","name":"银行",
        "199112":"-1.890","time":"2026-10-15 13:34:55 北京时间"}});
        """#.utf8)
        let inner = try #require(ThsSectorProvider.jsonPayload(from: payload))
        struct Response: Decodable { let items: [String: ThsSectorProvider.FieldValue]? }
        let response = try JSONDecoder().decode(Response.self, from: inner)
        let items = try #require(response.items)
        #expect(items["10"]?.doubleValue == 1374.856)
        #expect(items["6"]?.doubleValue == 1401.281)
        #expect(items["13"]?.doubleValue == 3329399200)
        #expect(items["name"]?.stringValue == "银行")

        let stamp = try #require(ThsSectorProvider.parseTimestamp(items["time"]?.stringValue))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        #expect(calendar.component(.hour, from: stamp) == 13)
        #expect(calendar.component(.minute, from: stamp) == 34)
    }

    @Test("A JSONP envelope is required, and empty bodies fail it")
    func jsonPayloadEnvelope() {
        #expect(ThsSectorProvider.jsonPayload(from: Data("bk_1({});".utf8)) != nil)
        #expect(ThsSectorProvider.jsonPayload(from: Data("bk_1({})".utf8)) != nil)
        // A 502 body is an HTML error page, not a payload.
        #expect(ThsSectorProvider.jsonPayload(from: Data("<html>502</html>".utf8)) == nil)
        #expect(ThsSectorProvider.jsonPayload(from: Data()) == nil)
        #expect(ThsSectorProvider.jsonPayload(from: Data("()".utf8)) == nil)
    }

    @Test("Daily rows parse from the real field order")
    func parsesDailyCandles() throws {
        // Field order is timestamp, open, high, low, close, volume, turnover,
        // then trailing empty fields. The timestamp is `yyyyMMdd` for daily.
        let rows = [
            "20261013,1391.686,1401.569,1386.153,1401.281,2836012200,21733913000,,,,",
            "20261014,1398.554,1409.463,1389.108,1401.281,3792556100,28925136000,,,,",
        ].joined(separator: ";")
        let payload = Data(#"{"data":"\#(rows)"}"#.utf8)
        let candles = try ThsSectorProvider.parseCandles(
            payload, period: .day, timeZone: Market.sh.timeZone
        )
        #expect(candles.count == 2)
        let last = try #require(candles.last)
        #expect(last.open == 1398.554)
        #expect(last.high == 1409.463)
        #expect(last.low == 1389.108)
        #expect(last.close == 1401.281)
        #expect(last.volume == 3792556100)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        #expect(calendar.component(.day, from: last.time) == 14)
    }

    @Test("A malformed row is dropped rather than drawn")
    func malformedRowsAreDropped() throws {
        // Out-of-order high/low cannot describe a real bar, and a non-numeric
        // timestamp is not a date. An empty series is the honest answer.
        let payload = Data(#"{"data":"20261013,10,5,20,11,100,,,,,;garbage,1,2,3,4,5"}"#.utf8)
        let candles = try ThsSectorProvider.parseCandles(
            payload, period: .day, timeZone: Market.sh.timeZone
        )
        #expect(candles.isEmpty)
    }

    @Test("The trend series parses as one point per minute")
    func parsesTrend() {
        // `HHMM,price,minuteTurnover,minuteVolume,minuteAmount` — the amounts are
        // per minute, and this series is what the one-minute chart draws.
        let series = "0930,1399.054,256088160,7.617,33618926;0931,1396.175,912446730,7.359,125177114"
        let candles = ThsSectorProvider.parseTrend(
            series, date: "20261015", timeZone: Market.sh.timeZone
        )
        #expect(candles.count == 2)
        #expect(candles.first?.close == 1399.054)
        #expect(candles.last?.close == 1396.175)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let first = candles[0].time
        #expect(calendar.component(.hour, from: first) == 9)
        #expect(calendar.component(.minute, from: first) == 30)
    }

    @Test("A stale series is detected so a second request is made")
    func stalenessIsDetected() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        // Mid-session on a trading day: yesterday's last bar is stale.
        let midSession = date(2026, 10, 15, 11, 0)
        let todayBar = Candle(time: date(2026, 10, 15, 10, 30), open: 1, high: 1, low: 1, close: 1)
        let yesterdayBar = Candle(time: date(2026, 10, 14, 15, 0), open: 1, high: 1, low: 1, close: 1)
        #expect(ThsSectorProvider.reachesPresent([todayBar], market: .sh, now: midSession))
        #expect(ThsSectorProvider.reachesPresent([yesterdayBar], market: .sh, now: midSession) == false)
        #expect(ThsSectorProvider.reachesPresent([], market: .sh, now: midSession) == false)
        // Before the open there is nothing newer to wait for.
        let preOpen = date(2026, 10, 15, 8, 0)
        #expect(ThsSectorProvider.reachesPresent([yesterdayBar], market: .sh, now: preOpen))
    }
}

@Suite("Sector board persistence")
struct SectorIndexPersistenceTests {
    @Test("A board round-trips through JSON")
    func roundTrip() throws {
        let board = SymbolID(market: .sh, code: "881155")
        let encoded = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(SymbolID.self, from: encoded)
        #expect(decoded == board)
        #expect(decoded.sectorIndex?.name == "银行")
        #expect(decoded.market == .sh)
    }

    @Test("The stored form stays readable to the preceding app version")
    func backwardCompatibility() throws {
        let encoded = try JSONEncoder().encode(SymbolID(market: .sh, code: "881155"))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // The market must stay one an older build knows: an unknown value fails
        // the entire snapshot, which would cost the user their whole watchlist on
        // a downgrade. `sh` degrades to "an A-share symbol I cannot price" — the
        // exact behaviour that build already had for `881155`.
        #expect(object["market"] as? String == "sh")
        #expect(object["code"] as? String == "881155")

        // And the old build's reading of that JSON is an ordinary security that
        // still decodes — there is no key it has to understand.
        let asLegacy = Data(#"{"market":"sh","code":"881155"}"#.utf8)
        let legacy = try JSONDecoder().decode(SymbolID.self, from: asLegacy)
        #expect(legacy.code == "881155")
    }

    @Test("The identity key survives a name-only change in the catalog")
    func identityIsCodeBased() throws {
        // Decoding resolves through the code, so a board whose published name is
        // corrected still reads back as the same instrument.
        let json = Data(#"{"market":"sh","code":"881155","sectorIndex":{"code":"881155","name":"旧名"}}"#.utf8)
        let decoded = try JSONDecoder().decode(SymbolID.self, from: json)
        #expect(decoded.sectorIndex?.code == "881155")
        #expect(decoded.sectorIndex?.name == "银行")
    }

    @Test("A board from a newer build still loads")
    func unknownBoardSurvives() throws {
        // A code this build does not carry must not fail the snapshot, and must
        // keep the name it was saved with.
        let json = Data(#"{"market":"sh","code":"881999","sectorIndex":{"code":"881999","name":"未来行业"}}"#.utf8)
        let decoded = try JSONDecoder().decode(SymbolID.self, from: json)
        #expect(decoded.sectorIndex?.code == "881999")
        #expect(decoded.sectorIndex?.name == "未来行业")
        #expect(decoded.market == .sh)
    }

    @Test("A board saved before this identity existed is repaired on load")
    func legacyRowIsRepaired() throws {
        // An older snapshot holds `881155` as a plain Shanghai code, which no
        // source can price. Loading it must recognise the board.
        let json = Data(#"{"market":"sh","code":"881155"}"#.utf8)
        let decoded = try JSONDecoder().decode(SymbolID.self, from: json)
        #expect(decoded.sectorIndex?.name == "银行")
        #expect(decoded == SymbolID(market: .sh, code: "881155"))
    }

    @Test("Decoding the same identity is stable across the two spellings")
    func spellingsAgree() throws {
        let direct = SymbolID(market: .sh, code: "881155")
        let viaKey = try JSONDecoder().decode(
            SymbolID.self,
            from: Data(#"{"market":"sh","code":"881155","sectorIndex":{"code":"881155","name":"银行"}}"#.utf8)
        )
        #expect(direct == viaKey)
        #expect(direct.hashValue == viaKey.hashValue)
    }
}
