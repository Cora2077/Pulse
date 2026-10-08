import Foundation
import Testing
@testable import PulseCore

/// A session that answers nothing and records what was asked. China A-share
/// requests must be rejected *before* any of these are reached, so a recorded
/// request is itself the failure and the test needs no live Yahoo access.
///
/// A body can be installed to drive a method that really does fetch (search),
/// which keeps the production filter — not a copy of it — under test.
///
/// Swift Testing runs cases in a suite in parallel, so the stub cannot be one
/// global slot: every test owns a unique token and a handle that only sees and
/// only answers requests carrying that token. One test's setup can therefore
/// never blank another's body.
final class YahooRequestRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var seen: [String: [URL]] = [:]

    static let tokenHeader = "X-Pulse-Test-Token"

    /// One test's private view of the stub.
    final class Handle: @unchecked Sendable {
        let token: String

        init(token: String) { self.token = token }

        /// Requests this test made, in order.
        var recorded: [URL] {
            YahooRequestRecorder.lock.lock()
            defer { YahooRequestRecorder.lock.unlock() }
            return YahooRequestRecorder.seen[token] ?? []
        }
    }

    /// Claims a fresh token, optionally with a body to answer it. Call once per
    /// test, before building the provider.
    @discardableResult
    static func install(body: Data? = nil) -> Handle {
        let token = UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        seen[token] = []
        if let body { bodies[token] = body }
        return Handle(token: token)
    }

    /// An `HTTPClient` that routes every request to this recorder with `token`.
    static func httpClient(token: String) -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [YahooRequestRecorder.self]
        config.httpAdditionalHeaders = [tokenHeader: token]
        return HTTPClient(session: URLSession(configuration: config))
    }

    /// The header is attached by the session configuration, but URLProtocol only
    /// receives it on the request; this reads it back.
    private static func token(of request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: tokenHeader)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let token = Self.token(of: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        let body = Self.bodies[token]
        Self.seen[token, default: []].append(url)
        Self.lock.unlock()

        guard let body else {
            // Fail loudly: a China A request that reached the network is itself
            // the bug, and the handle's `recorded` catches it either way.
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Yahoo response parsing")
struct YahooParserTests {
    static let chartFixture = Data("""
    {"chart":{"result":[{"meta":{"currency":"HKD","symbol":"0700.HK","exchangeName":"HKG",
    "regularMarketPrice":437.2,"chartPreviousClose":444.8,"previousClose":444.8,
    "regularMarketDayHigh":440.0,"regularMarketDayLow":435.0,"regularMarketVolume":12345678,
    "regularMarketTime":1783048138,"shortName":"TENCENT","longName":"Tencent Holdings Limited"},
    "timestamp":[1782867600,1782954000,1783040400],
    "indicators":{"quote":[{"open":[440.0,442.0,null],"high":[445.0,446.0,440.0],
    "low":[438.0,440.0,435.0],"close":[444.8,441.0,437.2],"volume":[1000,2000,3000]}]}}],
    "error":null}}
    """.utf8)

    @Test("chart metadata maps to Quote")
    func chartMeta() throws {
        let decoded = try YahooProvider.decode(ChartResponse.self, from: Self.chartFixture)
        let meta = try #require(decoded.chart.result?.first?.meta)
        #expect(meta.regularMarketPrice == 437.2)
        #expect(meta.previousClose == 444.8)
        #expect(meta.longName == "Tencent Holdings Limited")
        #expect(meta.currency == "HKD")
    }

    @Test("Candle arrays parsed, null entries skipped")
    func candles() throws {
        let decoded = try YahooProvider.decode(ChartResponse.self, from: Self.chartFixture)
        let result = try #require(decoded.chart.result?.first)
        let timestamps = try #require(result.timestamp)
        let ohlc = try #require(result.indicators.quote?.first)

        var candles: [Candle] = []
        for (i, ts) in timestamps.enumerated() {
            guard let open = ohlc.open?[safe: i] ?? nil,
                  let high = ohlc.high?[safe: i] ?? nil,
                  let low = ohlc.low?[safe: i] ?? nil,
                  let close = ohlc.close?[safe: i] ?? nil else { continue }
            candles.append(Candle(time: Date(timeIntervalSince1970: TimeInterval(ts)),
                                  open: open, high: high, low: low, close: close))
        }
        // The third bar's open is null and should be skipped
        #expect(candles.count == 2)
        #expect(candles[0].close == 444.8)
        #expect(candles[1].isUp == false)
    }

    @Test("API error object is recognized")
    func apiError() throws {
        let data = Data(#"{"chart":{"result":null,"error":{"code":"Not Found","description":"No data found"}}}"#.utf8)
        let decoded = try YahooProvider.decode(ChartResponse.self, from: data)
        #expect(decoded.chart.error?.code == "Not Found")
    }

    @Test("Extended sessions compare against the latest regular close")
    func extendedSessionReferenceClose() {
        #expect(YahooProvider.referenceClose(
            for: .preMarket,
            regularPrice: 308.63,
            previousClose: 294.38,
            chartPreviousClose: 294.38
        ) == 308.63)
        #expect(YahooProvider.referenceClose(
            for: .postMarket,
            regularPrice: 308.63,
            previousClose: 294.38,
            chartPreviousClose: 294.38
        ) == 308.63)
        #expect(YahooProvider.referenceClose(
            for: .regular,
            regularPrice: 308.63,
            previousClose: 294.38,
            chartPreviousClose: nil
        ) == 294.38)
    }

    @Test("Extended sessions carry the last regular session's own result")
    func extendedSessionRegularClose() throws {
        // Post-market: today's close (333.43) against yesterday's (338.19).
        let post = try #require(YahooProvider.regularSessionClose(
            for: .postMarket,
            regularPrice: 333.43,
            previousClose: 338.19,
            chartPreviousClose: 340.08
        ))
        #expect(post.price == 333.43)
        #expect(post.previousClose == 338.19)
        #expect(post.change.map { abs($0 - -4.76) < 0.0001 } == true)

        // Pre-market: the last regular close is yesterday's; its reference is
        // the close before the 2-day chart window.
        let pre = try #require(YahooProvider.regularSessionClose(
            for: .preMarket,
            regularPrice: 338.19,
            previousClose: 338.19,
            chartPreviousClose: 340.08
        ))
        #expect(pre.price == 338.19)
        #expect(pre.previousClose == 340.08)

        // In or after regular hours without an extended print, there is no
        // separate "yesterday" to attach.
        #expect(YahooProvider.regularSessionClose(
            for: .regular, regularPrice: 333.43, previousClose: 338.19, chartPreviousClose: 340.08
        ) == nil)
        #expect(YahooProvider.regularSessionClose(
            for: .closed, regularPrice: 333.43, previousClose: 338.19, chartPreviousClose: 340.08
        ) == nil)
    }

    @Test("Regular session close derives change and guards a missing reference")
    func regularSessionCloseDerivations() {
        let known = Quote.RegularSessionClose(price: 110, previousClose: 100)
        #expect(known.change == 10)
        #expect(known.changePercent == 10)

        let unknown = Quote.RegularSessionClose(price: 110)
        #expect(unknown.change == nil)
        #expect(unknown.changePercent == nil)
    }

    @Test("Asset profile maps to a security profile")
    func assetProfile() throws {
        let fixture = Data("""
        {"quoteSummary":{"result":[{"assetProfile":{"sector":"Technology",
        "industry":"Consumer Electronics","country":"United States",
        "longBusinessSummary":"  Apple Inc. designs, manufactures, and markets smartphones.  "}}],
        "error":null}}
        """.utf8)
        let decoded = try YahooProvider.decode(QuoteSummaryResponse.self, from: fixture)
        let asset = try #require(decoded.quoteSummary?.result?.first?.assetProfile)
        #expect(asset.sector == "Technology")
        #expect(asset.industry == "Consumer Electronics")

        let profile = SecurityProfile(
            symbol: SymbolID(market: .us, code: "AAPL"),
            summary: try #require(asset.longBusinessSummary).trimmingCharacters(in: .whitespacesAndNewlines),
            sector: asset.sector,
            industry: asset.industry,
            localeIdentifier: "en"
        )
        #expect(profile.summary.hasPrefix("Apple Inc."))
        #expect(profile.classification == "Technology · Consumer Electronics")
    }

    @Test("A profile with no summary and no classification carries nothing")
    func emptyAssetProfile() throws {
        let fixture = Data(#"{"quoteSummary":{"result":[{"assetProfile":{}}],"error":null}}"#.utf8)
        let decoded = try YahooProvider.decode(QuoteSummaryResponse.self, from: fixture)
        let asset = try #require(decoded.quoteSummary?.result?.first?.assetProfile)
        #expect(asset.longBusinessSummary == nil)

        let bare = SecurityProfile(
            symbol: SymbolID(market: .us, code: "AAPL"),
            summary: "",
            localeIdentifier: "en"
        )
        #expect(bare.classification == nil)
    }

    @Test("Intraday candle resolutions map to provider-native intervals")
    func intradayChartParams() {
        #expect(YahooProvider.chartParams(for: .minute5).interval == "5m")
        #expect(YahooProvider.chartParams(for: .minute5).range == "5d")
        #expect(YahooProvider.chartParams(for: .minute15).interval == "15m")
        #expect(YahooProvider.chartParams(for: .minute30).interval == "30m")
        #expect(YahooProvider.chartParams(for: .hour1).interval == "60m")

        #expect(BinanceProvider.interval(for: .minute5) == "5m")
        #expect(BinanceProvider.interval(for: .minute15) == "15m")
        #expect(BinanceProvider.interval(for: .minute30) == "30m")
        #expect(BinanceProvider.interval(for: .hour1) == "1h")
    }

    // MARK: - China A-share exclusion
    //
    // China A stocks and indices are served by domestic providers (Tencent,
    // Sina, Eastmoney). Yahoo must neither route them nor answer for them.

    /// Every way a China A instrument can be addressed: a Shanghai/Shenzhen
    /// stock, and each canonical A-share index identity.
    static let chinaASymbols: [SymbolID] = [
        SymbolID(market: .sh, code: "600519"),
        SymbolID(market: .sh, code: "000688"),
        SymbolID(market: .sz, code: "000001"),
        SymbolID(market: .sz, code: "399001"),
        SymbolID(index: .shanghaiComposite),
        SymbolID(index: .shenzhenComponent),
        SymbolID(index: .chiNext),
    ]

    /// Markets that must stay supported, and the instruments that prove it.
    static let retainedSymbols: [(id: SymbolID, market: Market)] = [
        (SymbolID(market: .us, code: "AAPL"), .us),
        (SymbolID(index: .sp500), .us),
        (SymbolID(market: .hk, code: "700"), .hk),
        (SymbolID(index: .hangSeng), .hk),
        (SymbolID(market: .jp, code: "7203"), .jp),
        (SymbolID(market: .kr, code: "005930"), .kr),
        (SymbolID(market: .metal, code: "GC=F"), .metal),
    ]

    @Test("The descriptor drops China A from markets and from every delay it advertises")
    func descriptorExcludesChinaA() {
        let descriptor = YahooProvider().descriptor

        #expect(!descriptor.markets.contains(.sh))
        #expect(!descriptor.markets.contains(.sz))
        #expect(!descriptor.markets.contains(.metalCN))
        // The remaining coverage is intact rather than the whole set shrinking.
        #expect(descriptor.markets == [.us, .hk, .jp, .kr, .kq, .metal])
        // A stale delay entry would still advertise Shanghai/Shenzhen freshness.
        #expect(descriptor.delay[.sh] == nil)
        #expect(descriptor.delay[.sz] == nil)
        #expect(descriptor.delay[.us] == 0)
        #expect(descriptor.delay[.hk] == 900)

        // Capability negotiation is what routing actually reads.
        for capability in [Capability.quotes, .candles, .profile, .search] {
            #expect(!descriptor.supports(capability, in: .sh))
            #expect(!descriptor.supports(capability, in: .sz))
            #expect(descriptor.supports(capability, in: .us))
            #expect(descriptor.supports(capability, in: .hk))
        }
    }

    @Test(
        "Quotes, candles and profile reject China A symbols before any request",
        arguments: YahooParserTests.chinaASymbols
    )
    func rejectsChinaAWithoutNetworking(symbol: SymbolID) async {
        let recorder = YahooRequestRecorder.install()
        let provider = YahooProvider(http: YahooRequestRecorder.httpClient(token: recorder.token))

        // The capability is named in each assertion so a rejection for the wrong
        // reason (say, a network failure) cannot pass as the right one.
        await Self.expectUnsupported(.quotes) {
            _ = try await provider.quotes(for: [symbol])
        }
        await Self.expectUnsupported(.candles) {
            _ = try await provider.candles(for: symbol, period: .day, count: 30)
        }
        await Self.expectUnsupported(.profile) {
            _ = try await provider.profile(for: symbol)
        }

        // The whole point: the rejection happened up front, not after a 404.
        #expect(recorder.recorded.isEmpty)
    }

    /// Asserts the call failed with `ProviderError.unsupported(capability)`.
    /// `ProviderError` is not `Equatable`, so the case is matched by hand.
    static func expectUnsupported(
        _ capability: Capability,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("expected unsupported(\(capability)), but the call succeeded", sourceLocation: sourceLocation)
        } catch let error as ProviderError {
            guard case .unsupported(let reported) = error, reported == capability else {
                Issue.record("expected unsupported(\(capability)), got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("expected unsupported(\(capability)), got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test(
        "Every declared supported market still passes capability negotiation",
        arguments: YahooParserTests.retainedSymbols
    )
    func retainsSupportedMarkets(symbol: SymbolID, market: Market) {
        let descriptor = YahooProvider().descriptor
        #expect(descriptor.supports(.quotes, in: market))
        #expect(descriptor.supports(.candles, in: market))
        #expect(descriptor.supports(.profile, in: market))
        #expect(symbol.market == market || symbol.indexID != nil)
        // Removing China A must not have removed the symbol mapping with it.
        #expect(!YahooProvider.yahooSymbol(for: symbol).isEmpty)
    }

    /// A Yahoo search answer that mixes A-share equities and indices into
    /// otherwise valid US/HK/JP results.
    static let mixedSearchFixture = Data(#"""
    {"quotes":[
      {"symbol":"600519.SS","longname":"Kweichow Moutai Co Ltd","quoteType":"EQUITY","exchDisp":"Shanghai"},
      {"symbol":"000001.SS","shortname":"SSE Composite Index","quoteType":"INDEX","exchDisp":"Shanghai"},
      {"symbol":"399001.SZ","shortname":"Shenzhen Component","quoteType":"INDEX","exchDisp":"Shenzhen"},
      {"symbol":"399006.SZ","shortname":"ChiNext Index","quoteType":"INDEX","exchDisp":"Shenzhen"},
      {"symbol":"000688.SS","longname":"STAR 50 Index","quoteType":"INDEX","exchDisp":"Shanghai"},
      {"symbol":"AAPL","longname":"Apple Inc.","quoteType":"EQUITY","exchDisp":"NASDAQ"},
      {"symbol":"0700.HK","longname":"Tencent Holdings Limited","quoteType":"EQUITY","exchDisp":"HKSE"},
      {"symbol":"^HSI","shortname":"HANG SENG INDEX","quoteType":"INDEX","exchDisp":"HKSE"},
      {"symbol":"7203.T","longname":"Toyota Motor Corporation","quoteType":"EQUITY","exchDisp":"JPX"},
      {"symbol":"^GSPC","shortname":"S&P 500","quoteType":"INDEX","exchDisp":"SNP"}
    ]}
    """#.utf8)

    @Test("A mixed search answer keeps US/HK/JP results and drops every Chinese one")
    func searchFiltersChineseResults() async throws {
        // The real `search(_:)` runs against the fixture, so the production
        // filter is what is under test — not a copy of it.
        let recorder = YahooRequestRecorder.install(body: Self.mixedSearchFixture)
        let provider = YahooProvider(http: YahooRequestRecorder.httpClient(token: recorder.token))
        let kept = try await provider.search("tencent")

        // The endpoint was really consulted, so an empty result below would mean
        // filtering rather than a short-circuit.
        #expect(recorder.recorded.count == 1)
        #expect(recorder.recorded.first?.path.contains("/v1/finance/search") == true)

        // No Chinese instrument survives, whether it arrived as an equity or an index.
        #expect(kept.allSatisfy { !$0.symbol.market.isChinaA })
        #expect(kept.allSatisfy { $0.symbol.market != .sh && $0.symbol.market != .sz })

        // Shanghai codes must not survive as any market's file.
        for chinese in ["600519", "000688", "000001", "399001", "399006"] {
            #expect(!kept.contains { $0.symbol.code == chinese })
        }
        #expect(!kept.contains { $0.name.contains("SSE Composite") })
        #expect(!kept.contains { $0.name.contains("Shenzhen Component") })

        // The supported results are preserved, not merely the Chinese ones removed.
        let codes = Set(kept.map(\.symbol.code))
        #expect(codes.contains("AAPL"))
        #expect(codes.contains("700"))
        #expect(codes.contains("7203"))
        #expect(kept.contains { $0.symbol.indexID == .hangSeng })
        #expect(kept.contains { $0.symbol.indexID == .sp500 })
        // 5 of the 10 mixed rows are supported; the 5 Chinese ones are gone.
        #expect(kept.count == 5)
    }

    @Test("A-share index aliases still decode, but never as a Yahoo target market")
    func chinaAIndexAliasesDecodeButAreNotRouted() throws {
        // Reverse mapping is a pure string operation and stays total: the wire
        // symbol must remain decodable for provenance and round-tripping.
        #expect(YahooProvider.symbolID(fromYahoo: "000001.SS") == SymbolID(index: .shanghaiComposite))
        #expect(YahooProvider.symbolID(fromYahoo: "399001.SZ") == SymbolID(index: .shenzhenComponent))
        #expect(YahooProvider.symbolID(fromYahoo: "399006.SZ") == SymbolID(index: .chiNext))
        for raw in ["000001.SS", "399001.SZ", "399006.SZ", "600519.SS"] {
            let id = try #require(YahooProvider.symbolID(fromYahoo: raw))
            #expect(id.market.isChinaA)
            // Decoding an id is not permission to route it.
            #expect(!YahooProvider().descriptor.supports(.quotes, in: id.market))
        }
    }
}
