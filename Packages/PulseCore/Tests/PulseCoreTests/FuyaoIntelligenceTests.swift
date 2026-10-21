import Foundation
import Testing
@testable import PulseCore

/// Per-stock intelligence: what the parsers keep, what they refuse to invent,
/// and the exact request each public method makes. Freshness rules matter most —
/// a missing vendor time stays nil, and the rank window's start is never passed
/// off as the time of the newest rank.
private final class FuyaoIntelStub: URLProtocol, @unchecked Sendable {
    private struct Plan {
        var body: String
        var status = 200
        var requests: [URL] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    private static let tokenHeader = "X-Pulse-Fuyao-Intel-Test"

    struct Handle {
        let token: String
        let http: HTTPClient

        var urls: [URL] {
            FuyaoIntelStub.lock.lock()
            defer { FuyaoIntelStub.lock.unlock() }
            return FuyaoIntelStub.plans[token]?.requests ?? []
        }

        func query(_ url: URL, _ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
    }

    static func install(body: String, status: Int = 200) -> Handle {
        let token = UUID().uuidString
        lock.lock()
        plans[token] = Plan(body: body, status: status)
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FuyaoIntelStub.self]
        return Handle(
            token: token,
            http: HTTPClient(session: URLSession(configuration: config), defaultHeaders: [tokenHeader: token])
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? ""
        Self.lock.lock()
        let plan = Self.plans[token]
        if let url = request.url { Self.plans[token]?.requests.append(url) }
        Self.lock.unlock()

        let status = plan?.status ?? 404
        let body = plan?.body ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Fuyao per-stock intelligence")
struct FuyaoIntelligenceTests {
    static let fetchedAt = Date(timeIntervalSince1970: 1_792_500_000)
    static let moutai = SymbolID(market: .sh, code: "600519")
    static let rankStock = SymbolID(market: .sz, code: "300034")

    private func provider(_ stub: FuyaoIntelStub.Handle) -> FuyaoProvider {
        FuyaoProvider(
            apiKey: "stub-key",
            http: stub.http,
            pacing: FuyaoProvider.RequestPacing(minInterval: 0, sleepsWhenPaced: true),
            now: { Self.fetchedAt }
        )
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private static let news = """
    {"code":0,"message":"success","data":{"items":[
      {"id":"n1","title":"较早","source":"来源甲","summary":"摘要一",
       "publish_time_ms":1792000000000,"jump_url":"https://news.example.com/a","pic_url":""},
      {"id":"n2","title":"较新","source":null,"summary":null,
       "publish_time_ms":1792100000000,"jump_url":"https://news.example.com/b","pic_url":null},
      {"id":"n3","title":"无时间","source":"来源丙","summary":"",
       "publish_time_ms":null,"jump_url":"javascript:alert(1)","pic_url":null},
      {"id":"n4","title":"重复","source":"来源甲","summary":"",
       "publish_time_ms":1792200000000,"jump_url":"/relative/path","pic_url":null},
      {"id":"n2","title":"重复ID","source":"","summary":"",
       "publish_time_ms":1792150000000,"jump_url":"https://news.example.com/dup","pic_url":null},
      {"title":"缺ID","publish_time_ms":1792150000000}
    ],"has_more":true,"offset":"1792100000"}}
    """

    @Test("News keeps every field, sorts newest first and puts an unknown time last")
    func newsParsing() throws {
        let timed = try FuyaoProvider.parseStockNews(data: data(Self.news), fetchedAt: Self.fetchedAt)

        #expect(timed.fetchedAt == Self.fetchedAt)
        // The timeline feed carries no response-level time, so none is invented.
        #expect(timed.dataTime == nil)
        // n1 (older) < n4 (newer); the headline with no time follows both, and
        // the repeated id plus the id-less row are dropped.
        // n1 (14th) < n2 (15th) < n4 (17th); the headline without a time follows
        // all three. The repeated id and the id-less row are dropped, and the
        // duplicate never displaces the first row that claimed its id.
        #expect(timed.value.map(\.id) == ["n4", "n2", "n1", "n3"], "news ids: \(timed.value.map { ($0.id, $0.publishedAt as Any, $0.url as Any) })")

        let older = try #require(timed.value.first(where: { $0.id == "n1" }))
        #expect(older.title == "较早")
        #expect(older.summary == "摘要一")
        #expect(older.source == "来源甲")
        #expect(older.publishedAt == Date(timeIntervalSince1970: 1_792_000_000))
        #expect(older.url == URL(string: "https://news.example.com/a"))

        let undatedRow = try #require(timed.value.first(where: { $0.id == "n2" }))
        #expect(undatedRow.title == "较新")
        #expect(undatedRow.summary == nil)
        #expect(undatedRow.source == nil)
        #expect(undatedRow.url == URL(string: "https://news.example.com/b"))

        let undated = try #require(timed.value.first(where: { $0.id == "n3" }))
        #expect(undated.publishedAt == nil)
        #expect(undated.summary == nil)
        #expect(undated.url == nil)

        let duplicate = try #require(timed.value.first(where: { $0.id == "n4" }))
        #expect(duplicate.publishedAt == Date(timeIntervalSince1970: 1_792_200_000))
        #expect(duplicate.url == nil)
    }

    @Test("Only absolute HTTP/HTTPS links survive")
    func newsURLFilter() throws {
        let json = """
        {"code":0,"data":{"items":[
          {"id":"a","title":"a","publish_time_ms":1792000000000,"jump_url":"HTTP://Upper.example.com/x"},
          {"id":"b","title":"b","publish_time_ms":1792000000000,"jump_url":"ftp://files.example.com/x"},
          {"id":"c","title":"c","publish_time_ms":1792000000000,"jump_url":"//protocol-relative.example.com/x"},
          {"id":"d","title":"d","publish_time_ms":1792000000000,"jump_url":"https://"},
          {"id":"e","title":"e","publish_time_ms":1792000000000}
        ]}}
        """
        let items = try FuyaoProvider.parseStockNews(data: data(json), fetchedAt: Self.fetchedAt).value
        // Every row is kept; only the link decision differs.
        let urls = Dictionary(items.map { ($0.id, $0.url as URL?) }, uniquingKeysWith: { first, _ in first })
        #expect(urls.count == 5, "urls: \(urls)")
        #expect(urls["a"] == URL(string: "HTTP://Upper.example.com/x"))
        // Absent-key subscripts would compare equal to nil even when the link
        // survived, so the value is unwrapped first.
        #expect(urls["b"].flatMap { $0 } == nil)
        #expect(urls["c"].flatMap { $0 } == nil)
        #expect(urls["d"].flatMap { $0 } == nil)
        #expect(urls["e"].flatMap { $0 } == nil)
    }

    private static let anomalies = """
    {"code":0,"message":"success","data":{"timestamp":1792479225718,"item":[
      {"stock_name":"贵州茅台","analysis_content":"公司股价出现异动。<b>原文保留</b>","keyword_list":["白酒","消费"],
       "thscode":"600519.SH","tag_name":"大涨"},
      {"stock_name":"平安银行","analysis_content":"另一只股票的原因","keyword_list":[],
       "thscode":"000001.SZ","tag_name":"涨停"},
      {"stock_name":"贵州茅台","analysis_content":null,"keyword_list":null,
       "thscode":"600519.SH","tag_name":"跌停"}
    ]}}
    """

    @Test("Anomalies keep source text and isolate the requested thscode")
    func anomalyParsing() throws {
        let timed = try FuyaoProvider.parseAnomalies(data: data(Self.anomalies), thscode: "600519.SH", fetchedAt: Self.fetchedAt)
        #expect(timed.dataTime == Date(timeIntervalSince1970: 1_792_479_225.718))
        #expect(timed.fetchedAt == Self.fetchedAt)
        #expect(timed.value.count == 1)
        let first = try #require(timed.value.first)
        #expect(first.thscode == "600519.SH")
        #expect(first.name == "贵州茅台")
        #expect(first.text == "公司股价出现异动。<b>原文保留</b>")
        #expect(first.keywords == ["白酒", "消费"])
        #expect(first.tag == "大涨")

        // The same payload asked for another stock never answers for this one.
        let other = try FuyaoProvider.parseAnomalies(data: data(Self.anomalies), thscode: "300750.SZ", fetchedAt: Self.fetchedAt)
        #expect(other.value.isEmpty)
        #expect(other.dataTime != nil)
    }

    private static let hotList = """
    {"code":0,"message":"success","data":{"timestamp":1792481283811,"item":[
      {"thscode":"600487.SH","ticker":"600487","name":"亨通光电","rank":4,"heat":"4409507","rank_change":-1,"rank_trend":"down"},
      {"thscode":"688836.SH","ticker":"688836","name":"宇树科技","rank":1,"heat":"7063476","rank_change":0,"rank_trend":"flat"},
      {"thscode":"002242.SZ","ticker":"002242","name":"九阳股份","rank":0,"heat":"0"},
      {"thscode":"000001.SZ","ticker":"000001","name":"平安银行","rank":-3,"heat":"0"},
      {"thscode":"600000.SH","ticker":"600000","name":"浦发银行","rank":null,"heat":"0"},
      {"thscode":"","ticker":"","name":"空代码","rank":5,"heat":"0"},
      {"thscode":"600825.SH","ticker":"600825","name":"新华传媒","rank":2,"heat":"5945292","rank_change":null,"rank_trend":null}
    ]}}
    """

    @Test("Hot stocks drop non-positive, missing or codeless ranks and keep optional fields nil")
    func hotStockParsing() throws {
        let timed = try FuyaoProvider.parseHotStocks(data: data(Self.hotList), fetchedAt: Self.fetchedAt)
        #expect(timed.dataTime == Date(timeIntervalSince1970: 1_792_481_283.811))
        #expect(timed.value.map(\.thscode) == ["688836.SH", "600825.SH", "600487.SH"])
        #expect(timed.value.map(\.rank) == [1, 2, 4])

        let flat = try #require(timed.value.first)
        #expect(flat.name == "宇树科技")
        #expect(flat.rankChange == 0)
        #expect(flat.trend == "flat")

        let partial = try #require(timed.value.first(where: { $0.thscode == "600825.SH" }))
        #expect(partial.rankChange == nil)
        #expect(partial.trend == nil)

        let down = try #require(timed.value.last)
        #expect(down.rank == 4)
        #expect(down.rankChange == -1)
        #expect(down.trend == "down")
    }

    private static let rankTrend = """
    {"code":0,"message":"success","data":{"timestamp":1781971200000,"item":[
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-22","date_ms":1782057600000,"rank":12},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-21","date_ms":1781971200000,"rank":1740},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-23","date_ms":1782144000000,"rank":0},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-23","date_ms":1782144000000,"rank":-5},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-23","date_ms":1782144000000,"rank":88},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-24","date_ms":null,"rank":7},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-27","date_ms":1782489600000,"rank":9},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-06-28","date_ms":null,"rank":5},
      {"thscode":"300034.SZ","ticker":"300034","date":"2026-13-01","date_ms":null,"rank":6},
      {"thscode":"600519.SH","ticker":"600519","date":"2026-06-22","date_ms":1782057600000,"rank":3}
    ]}}
    """

    @Test("Rank data time is the newest point, not the window-start timestamp")
    func rankTrendDataTime() throws {
        let timed = try FuyaoProvider.parseRankTrend(data: data(Self.rankTrend), thscode: "300034.SZ", fetchedAt: Self.fetchedAt)

        // Oldest first; on the 23rd only the last row with valid ranks (88)
        // survives. The 24th and 28th carry no date_ms but name their days;
        // "2026-13-01" is not a day, and the other stock never joins.
        #expect(timed.value.map(\.rank) == [1740, 12, 88, 7, 9, 5], "points: \(timed.value)")
        #expect(timed.value.map(\.date) == [
            Date(timeIntervalSince1970: 1_781_971_200),
            Date(timeIntervalSince1970: 1_782_057_600),
            Date(timeIntervalSince1970: 1_782_144_000),
            Date(timeIntervalSince1970: 1_782_230_400),
            Date(timeIntervalSince1970: 1_782_489_600),
            Date(timeIntervalSince1970: 1_782_576_000),
        ])
        #expect(timed.value.allSatisfy { $0.thscode == "300034.SZ" })

        // The newest point, never the payload's window-start timestamp.
        #expect(timed.dataTime == Date(timeIntervalSince1970: 1_782_576_000))
        #expect(timed.dataTime != Date(timeIntervalSince1970: 1_781_971_200))
        #expect(timed.fetchedAt == Self.fetchedAt)
        #expect(FuyaoProvider.millisecondDate(1e300) == nil)
    }

    @Test("An empty rank series carries no data time")
    func emptyRankTrend() throws {
        let json = #"{"code":0,"data":{"timestamp":1781971200000,"item":[]}}"#
        let timed = try FuyaoProvider.parseRankTrend(data: data(json), thscode: "300034.SZ", fetchedAt: Self.fetchedAt)
        #expect(timed.value.isEmpty)
        #expect(timed.dataTime == nil)
        #expect(timed.fetchedAt == Self.fetchedAt)
    }

    @Test("A business failure inside an HTTP 200 body is thrown, not parsed")
    func businessFailure() async throws {
        let failures = [
            #"{"code":2004,"message":"no permission","data":null}"#,
            #"{"code":4001,"message":"rate limited","data":null}"#,
            #"{"code":0,"message":"success"}"#,
        ]
        for body in failures {
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseStockNews(data: self.data(body), fetchedAt: Self.fetchedAt)
            }
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseAnomalies(data: self.data(body), thscode: "600519.SH", fetchedAt: Self.fetchedAt)
            }
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseHotStocks(data: self.data(body), fetchedAt: Self.fetchedAt)
            }
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseRankTrend(data: self.data(body), thscode: "300034.SZ", fetchedAt: Self.fetchedAt)
            }
        }

        let stub = FuyaoIntelStub.install(body: #"{"code":2004,"message":"no permission","data":null}"#)
        try await #require(throws: ProviderError.self) {
            _ = try await self.provider(stub).hotStocks()
        }
    }

    @Test("Each method asks its documented endpoint with its exact query")
    func requestShapes() async throws {
        let stub = FuyaoIntelStub.install(body: #"{"code":0,"message":"success","data":{"items":[],"item":[],"timestamp":1792481283811}}"#)
        let provider = provider(stub)

        let news = try await provider.stockNews(for: Self.moutai)
        let anomaly = try await provider.anomalies(for: Self.moutai)
        let hot = try await provider.hotStocks()
        let rank = try await provider.rankTrend(
            for: Self.rankStock,
            // 15:00 Beijing on the 21st to 15:00 Beijing on the 22nd: one UTC
            // calendar day apart, two Beijing days apart.
            start: Date(timeIntervalSince1970: 1_781_971_200 + 15 * 3600),
            end: Date(timeIntervalSince1970: 1_781_971_200 + 39 * 3600)
        )

        #expect(news.value.isEmpty)
        #expect(news.dataTime == nil)
        #expect(anomaly.value.isEmpty)
        #expect(anomaly.dataTime == Date(timeIntervalSince1970: 1_792_481_283.811))
        #expect(hot.value.isEmpty)
        #expect(rank.value.isEmpty)
        #expect(rank.dataTime == nil)

        let urls = stub.urls
        #expect(urls.count == 4)
        #expect(urls.allSatisfy { $0.host == "fuyao.aicubes.cn" && $0.scheme == "https" })

        let timeline = try #require(urls.first { $0.path == "/api/news/stock/timeline-list" })
        #expect(stub.query(timeline, "thscode") == "600519.SH")
        #expect(stub.query(timeline, "offset") == "first")
        #expect(stub.query(timeline, "size") == "20")

        let analysis = try #require(urls.first { $0.path == "/api/a-share/special-data/anomaly-analysis-stock" })
        #expect(stub.query(analysis, "thscodes") == "600519.SH")

        let list = try #require(urls.first { $0.path == "/api/a-share/special-data/hot-stock-list" })
        #expect(stub.query(list, "period") == "day")
        #expect(stub.query(list, "limit") == "100")

        let trend = try #require(urls.first { $0.path == "/api/a-share/special-data/hot-stock-rank-trend" })
        #expect(stub.query(trend, "thscode") == "300034.SZ")
        // Dates follow the Beijing calendar day, not the device's zone.
        #expect(stub.query(trend, "start_date") == "2026-06-21")
        #expect(stub.query(trend, "end_date") == "2026-06-22")
    }

    @Test("An unmappable identity never reaches the network")
    func unmappableSymbol() async throws {
        let stub = FuyaoIntelStub.install(body: #"{"code":0,"data":{}}"#)
        let provider = provider(stub)
        let crypto = SymbolID(cryptoPair: CryptoPair(baseAsset: "BTC", quoteAsset: "USDT"))
        try await #require(throws: ProviderError.self) {
            _ = try await provider.stockNews(for: crypto)
        }
        try await #require(throws: ProviderError.self) {
            _ = try await provider.rankTrend(for: crypto, start: Self.fetchedAt, end: Self.fetchedAt)
        }
        #expect(stub.urls.isEmpty)
    }

    @Test("Models are constructible and value-comparable")
    func modelConstruction() throws {
        let url = try #require(URL(string: "https://news.example.com/x"))
        let item = FuyaoNewsItem(id: "1", title: "t", summary: nil, source: "s", publishedAt: nil, url: url)
        #expect(item == FuyaoNewsItem(id: "1", title: "t", summary: nil, source: "s", publishedAt: nil, url: url))
        let timed = FuyaoTimed(value: [item], dataTime: nil, fetchedAt: Self.fetchedAt)
        #expect(timed.value == [item])
        #expect(FuyaoAnomaly(thscode: "600519.SH", name: "n", text: "x", keywords: [], tag: "t").keywords.isEmpty)
        #expect(FuyaoHotStock(thscode: "600519.SH", name: "n", rank: 1).rankChange == nil)
        #expect(FuyaoRankPoint(thscode: "600519.SH", date: Self.fetchedAt, rank: 1).rank == 1)
    }
}
