import Foundation
import Testing
@testable import PulseCore

/// Fuyao's routing is decided per instrument, so these cases pin the endpoint
/// each identity takes, the exact-match meta lookup, and how one failing
/// endpoint or fund leaves the rest of a batch alone. The stub answers from a
/// path table, so a test never needs live access and `quotes(for:)` picks its
/// own order.
private final class FuyaoHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body: String
    }

    private struct Plan {
        var routes: [String: Reply]
        var fallback: Reply?
        var requests: [URL] = []
        var apiKeys: [String?] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    private static let tokenHeader = "X-Pulse-Fuyao-Test"

    /// One test's stub. `routes` selects on the request's path plus its sorted
    /// query without the `thscodes`/`thscode`/`q` parameter, so one route can
    /// answer any set of codes while still being endpoint-specific.
    struct Handle {
        let token: String
        let http: HTTPClient

        var urls: [URL] {
            FuyaoHTTPStub.lock.lock()
            defer { FuyaoHTTPStub.lock.unlock() }
            return FuyaoHTTPStub.plans[token]?.requests ?? []
        }

        /// The X-api-key each recorded request carried, in request order.
        var apiKeys: [String?] {
            FuyaoHTTPStub.lock.lock()
            defer { FuyaoHTTPStub.lock.unlock() }
            return FuyaoHTTPStub.plans[token]?.apiKeys ?? []
        }

        var paths: [String] { urls.map(\.path) }
        func setReply(_ reply: Reply, for route: String) {
            FuyaoHTTPStub.lock.lock()
            defer { FuyaoHTTPStub.lock.unlock() }
            FuyaoHTTPStub.plans[token]?.routes[route] = reply
        }
        func url(_ path: String) -> URL? { urls.first { $0.path == path } }
        func urls(_ path: String) -> [URL] { urls.filter { $0.path == path } }

        func query(_ url: URL, _ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
    }

    static func install(routes: [String: Reply], fallback: Reply? = nil) -> Handle {
        let token = UUID().uuidString
        lock.lock()
        plans[token] = Plan(routes: routes, fallback: fallback)
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FuyaoHTTPStub.self]
        let session = URLSession(configuration: config)
        return Handle(
            token: token,
            http: HTTPClient(session: session, defaultHeaders: [tokenHeader: token])
        )
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let token = request.value(forHTTPHeaderField: Self.tokenHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        guard var plan = Self.plans[token] else { Self.lock.unlock(); return }
        plan.requests.append(url)
        plan.apiKeys.append(request.value(forHTTPHeaderField: "X-api-key"))
        let key = Self.routeKey(url)
        let reply = plan.routes[key] ?? plan.fallback ?? Reply(status: 404, body: "{}")
        Self.plans[token] = plan
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `path?q=…` keeping only parameters that identify *which* instrument was
    /// asked for; the batch list itself varies per test.
    static func routeKey(_ url: URL) -> String {
        let items = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "q" }
        guard !items.isEmpty else { return url.path }
        let query = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return "\(url.path)?\(query)"
    }
}

private enum FuyaoFixtures {
    static let timestamp = 1_784_275_991_000.0

    static func snapshot(_ rows: [(String, Double, Double?)], timestamp: Double? = FuyaoFixtures.timestamp) -> String {
        let stamp = timestamp.map { String(Int($0)) } ?? "null"
        let items = rows.map { code, price, prev in
            """
            {"thscode":"\(code)","last_price":\(price),"prev_price":\(prev.map { String($0) } ?? "null"),\
            "open_price":\(price),"high_price":\(price),"low_price":\(price),"volume":100,"turnover":1000}
            """
        }
        return #"{"code":0,"message":"success","data":{"timestamp":\#(stamp),"item":[\#(items.joined(separator: ","))]}}"#
    }

    static func search(_ rows: [(String, String, String)]) -> String {
        let items = rows.map { thscode, name, type in
            #"{"thscode":"\#(thscode)","name":"\#(name)","exchange":"","asset_type":"\#(type)"}"#
        }
        return #"{"code":0,"message":"success","data":{"item":[\#(items.joined(separator: ","))]}}"#
    }

    static let history = #"""
    {"code":0,"message":"success","data":{"item":[
      {"date_ms":1716220800000,"open_price":1602.0,"high_price":1620.0,"low_price":1598.0,"close_price":1610.0,"volume":2000000.0},
      {"date_ms":1716134400000,"open_price":1611.602,"high_price":1626.602,"low_price":1601.722,"close_price":1602.612,"volume":3142572.0}
    ]}}
    """#

    /// Meta route key for one exact lookup.
    static func meta(_ thscode: String) -> String { "/api/meta/tickers/search?q=\(thscode)" }

    static let moutai = SymbolID(market: .sh, code: "600519")
    static let etf = SymbolID(market: .sh, code: "510300")
    static let lof = SymbolID(market: .sz, code: "160105")
    static let pingan = SymbolID(market: .sz, code: "000001")
    static let composite = SymbolID(index: .shanghaiComposite)
    static let bank = SymbolID(sectorIndex: SectorIndexID(code: "881155", name: "银行"))
}

@Suite("Fuyao endpoint routing, meta cache and partial batches")
struct FuyaoRoutingTests {
    private func provider(_ stub: FuyaoHTTPStub.Handle) -> FuyaoProvider {
        FuyaoProvider(
            apiKey: "test-key",
            http: stub.http,
            pacing: FuyaoProvider.RequestPacing(
                minInterval: 0, sleepsWhenPaced: true
            ),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    private func standardRoutes() -> [String: FuyaoHTTPStub.Reply] {
        [
            "/api/meta/tickers/search?q=600519.SH": .init(body: FuyaoFixtures.search([("600519.SH", "贵州茅台", "a-share")])),
            "/api/meta/tickers/search?q=000001.SZ": .init(body: FuyaoFixtures.search([("000001.SZ", "平安银行", "a-share")])),
            "/api/meta/tickers/search?q=510300.SH": .init(body: FuyaoFixtures.search([("510300.SH", "沪深300ETF", "fund-etf")])),
            "/api/a-share/prices/snapshot": .init(body: FuyaoFixtures.snapshot([
                ("600519.SH", 1277.8, 1256),
                ("000001.SZ", 11.2, 11.1),
            ])),
            "/api/a-share-index/prices/snapshot": .init(body: FuyaoFixtures.snapshot([
                ("000001.SH", 3400, 3380),
                ("881155.TI", 1401.281, 1374.856),
            ])),
            "/api/fund/market/snapshot": .init(body: FuyaoFixtures.snapshot([("510300.SH", 4.012, 4.0)])),
        ]
    }

    @Test("A mixed batch splits into one request per endpoint with the contract's parameters")
    func mixedBatch() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let quotes = try await provider(stub).quotes(
            for: [FuyaoFixtures.moutai, FuyaoFixtures.pingan, FuyaoFixtures.composite,
                  FuyaoFixtures.bank, FuyaoFixtures.etf]
        )
        #expect(quotes.map(\.symbol) == [
            FuyaoFixtures.moutai, FuyaoFixtures.pingan, FuyaoFixtures.composite,
            FuyaoFixtures.bank, FuyaoFixtures.etf,
        ])

        let share = try #require(stub.url("/api/a-share/prices/snapshot"))
        #expect(stub.query(share, "thscodes") == "600519.SH,000001.SZ")
        #expect(share.host == "fuyao.aicubes.cn")
        #expect(share.scheme == "https")

        let index = try #require(stub.url("/api/a-share-index/prices/snapshot"))
        #expect(stub.query(index, "thscodes") == "000001.SH,881155.TI")

        let fund = try #require(stub.url("/api/fund/market/snapshot"))
        #expect(stub.query(fund, "thscode") == "510300.SH")
        #expect(stub.query(fund, "thscodes") == nil)
        #expect(stub.urls("/api/fund/market/snapshot").count == 1)

        // Every request carries the key and nothing else identifies a batch.
        // Three exact lookups plus three endpoint requests: semantic indices
        // and boards are known identities and are never looked up.
        #expect(stub.urls.count == 6)
        #expect(stub.urls("/api/meta/tickers/search").map { stub.query($0, "q") } == ["600519.SH", "000001.SZ", "510300.SH"])
        #expect(stub.apiKeys.allSatisfy { $0 == "test-key" })
        #expect(quotes.allSatisfy { $0.timestamp == Date(timeIntervalSince1970: 1_784_275_991) })
        // The cache now knows the stock's name; the board and index keep their own.
        let moutai = try #require(quotes.first)
        #expect(moutai.price == 1277.8)
        let bank = try #require(quotes.first { $0.symbol == FuyaoFixtures.bank })
        #expect(bank.name == "银行")
    }

    @Test("The semantic composite and the 000001.SZ share never share an identity or endpoint")
    func benchmarkVersusShare() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let quotes = try await provider(stub).quotes(for: [FuyaoFixtures.pingan, FuyaoFixtures.composite])
        #expect(Set(quotes.map(\.symbol)) == [FuyaoFixtures.pingan, FuyaoFixtures.composite])
        let share = try #require(quotes.first { $0.symbol == FuyaoFixtures.pingan })
        let index = try #require(quotes.first { $0.symbol == FuyaoFixtures.composite })
        #expect(share.price == 11.2)
        #expect(index.price == 3400)
        // Only the share needs a lookup; the composite is known to this source.
        #expect(stub.urls("/api/meta/tickers/search").map { stub.query($0, "q") } == ["000001.SZ"])
        #expect(stub.query(try #require(stub.url("/api/a-share/prices/snapshot")), "thscodes") == "000001.SZ")
        #expect(stub.query(try #require(stub.url("/api/a-share-index/prices/snapshot")), "thscodes") == "000001.SH")
    }

    @Test("Meta uses an exact thscode and only adopts an exact match")
    func exactMetaAndCaching() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let fuyao = provider(stub)
        _ = try await fuyao.quotes(for: [FuyaoFixtures.etf])
        // A prefix hit must never stand in for the instrument asked for.
        let lookups = stub.urls("/api/meta/tickers/search")
        #expect(lookups.map { stub.query($0, "q") } == ["510300.SH"])
        #expect(stub.query(try #require(lookups.first), "limit") == "1")
        // Second tick: the answer is cached for a day, no second request.
        _ = try await fuyao.quotes(for: [FuyaoFixtures.etf])
        #expect(stub.urls("/api/meta/tickers/search").count == 1)
        #expect(stub.urls("/api/fund/market/snapshot").count == 2)
    }

    @Test("A non-exact meta row never guesses a stock or fund endpoint")
    func prefixMetaDoesNotReclassify() async throws {
        // A REIT-shaped prefix hit for a fund query must not make 510300 a fund.
        let routes: [String: FuyaoHTTPStub.Reply] = [
            FuyaoFixtures.meta("510300.SH"): .init(
                body: FuyaoFixtures.search([("508000.SH", "某REIT", "fund-lof")])
            ),
            "/api/a-share/prices/snapshot": .init(body: FuyaoFixtures.snapshot([("510300.SH", 4.012, 4.0)])),
        ]
        let stub = FuyaoHTTPStub.install(routes: routes)
        let fuyao = provider(stub)
        await #expect(throws: ProviderError.self) {
            _ = try await fuyao.quotes(for: [FuyaoFixtures.etf])
        }
        #expect(stub.urls("/api/fund/market/snapshot").isEmpty)
        #expect(stub.urls("/api/a-share/prices/snapshot").isEmpty)
        // The unresolved miss is remembered: the next tick does not look it up again.
        _ = try? await fuyao.quotes(for: [FuyaoFixtures.etf])
        #expect(stub.urls("/api/meta/tickers/search").count == 1)
    }

    @Test("Search warms the classification so the first quote needs no lookup")
    func searchWarmsMeta() async throws {
        let routes: [String: FuyaoHTTPStub.Reply] = standardRoutes().merging([
            "/api/meta/tickers/search?q=沪深300ETF": .init(
                body: FuyaoFixtures.search([("510300.SH", "沪深300ETF", "fund-etf"), ("881155.TI", "银行", "a-share-index")])
            ),
        ]) { _, new in new }
        let stub = FuyaoHTTPStub.install(routes: routes)
        let fuyao = provider(stub)
        let results = try await fuyao.search("沪深300ETF")
        #expect(results.map(\.symbol) == [FuyaoFixtures.etf, FuyaoFixtures.bank])
        #expect(results[0].type == .etf)
        #expect(results[1].type == .index)
        #expect(results[1].exchangeName == SectorIndexID.exchangeName)

        _ = try await fuyao.quotes(for: [FuyaoFixtures.etf, FuyaoFixtures.bank])
        #expect(stub.urls("/api/meta/tickers/search").count == 1)
        #expect(stub.query(try #require(stub.url("/api/fund/market/snapshot")), "thscode") == "510300.SH")
    }

    @Test("A failed lookup leaves no classification behind and the retry can adopt one")
    func failedLookupIsNotCached() async throws {
        var routes = standardRoutes()
        routes[FuyaoFixtures.meta("510300.SH")] = .init(status: 500, body: "{}")
        routes["/api/a-share/prices/snapshot"] = .init(body: FuyaoFixtures.snapshot([("510300.SH", 4.012, 4.0)]))
        let stub = FuyaoHTTPStub.install(routes: routes)
        let fuyao = provider(stub)
        // A transient metadata failure must not guess the instrument's type.
        await #expect(throws: ProviderError.self) {
            _ = try await fuyao.quotes(for: [FuyaoFixtures.etf])
        }
        #expect(stub.urls("/api/fund/market/snapshot").isEmpty)
        #expect(stub.urls("/api/a-share/prices/snapshot").isEmpty)
        // Recover in the same provider: a transport error is never negative-cached.
        stub.setReply(.init(
            body: FuyaoFixtures.search([("510300.SH", "沪深300ETF", "fund-etf")])
        ), for: FuyaoFixtures.meta("510300.SH"))
        _ = try await fuyao.quotes(for: [FuyaoFixtures.etf])
        #expect(stub.query(try #require(stub.url("/api/fund/market/snapshot")), "thscode") == "510300.SH")
    }

    @Test("Share history is unadjusted; index and board history carry no adjust and stay within five years")
    func historyParameters() async throws {
        let routes: [String: FuyaoHTTPStub.Reply] = [
            "/api/meta/tickers/search?q=600519.SH": .init(body: FuyaoFixtures.search([("600519.SH", "贵州茅台", "a-share")])),
            "/api/a-share/prices/historical": .init(body: FuyaoFixtures.history),
            "/api/a-share-index/prices/historical": .init(body: FuyaoFixtures.history),
        ]
        let stub = FuyaoHTTPStub.install(routes: routes)
        let fuyao = provider(stub)
        let end = Date(timeIntervalSince1970: 1_790_000_000)

        let share = try await fuyao.candles(for: FuyaoFixtures.moutai, period: .day, count: 2)
        #expect(share.count == 2)
        let shareURL = try #require(stub.url("/api/a-share/prices/historical"))
        #expect(stub.query(shareURL, "adjust") == "none")
        _ = try await fuyao.candles(for: FuyaoFixtures.moutai, period: .day, count: 2, adjustment: .forward)
        let forwardURL = try #require(stub.urls("/api/a-share/prices/historical").last)
        #expect(stub.query(forwardURL, "adjust") == "forward")
        #expect(stub.query(shareURL, "interval") == "1d")
        #expect(stub.query(shareURL, "thscode") == "600519.SH")
        let shareStart = try #require(Int(stub.query(shareURL, "start") ?? "") ?? nil)
        let shareEnd = try #require(Int(stub.query(shareURL, "end") ?? "") ?? nil)
        #expect(shareEnd == Int(end.timeIntervalSince1970 * 1000))
        #expect(Double(shareEnd - shareStart) / 86_400_000 <= FuyaoProvider.shareHistoryMaxDays)
        #expect(Double(shareEnd - shareStart) / 86_400_000 >= 30)
        let fullWindow = FuyaoProvider.shareHistoryURL(thscode: "600519.SH", count: 3_000, end: end)
        let fullStart = try #require(Double(stub.query(fullWindow, "start") ?? ""))
        #expect((Double(shareEnd) - fullStart) / 86_400_000 > 5 * 365)

        let board = try await fuyao.candles(for: FuyaoFixtures.bank, period: .day, count: 2)
        #expect(board.count == 2)
        let boardURL = try #require(stub.url("/api/a-share-index/prices/historical"))
        #expect(stub.query(boardURL, "adjust") == nil)
        #expect(stub.query(boardURL, "thscode") == "881155.TI")
        #expect(stub.query(boardURL, "interval") == "1d")

        let indexCount = stub.urls("/api/a-share-index/prices/historical").count
        _ = try await fuyao.candles(for: FuyaoFixtures.composite, period: .day, count: 2)
        let compositeURL = try #require(stub.urls("/api/a-share-index/prices/historical").last)
        #expect(stub.urls("/api/a-share-index/prices/historical").count == indexCount + 1)
        #expect(stub.query(compositeURL, "thscode") == "000001.SH")
        #expect(stub.query(compositeURL, "adjust") == nil)
        let indexStart = try #require(Int(stub.query(compositeURL, "start") ?? "") ?? nil)
        let indexEnd = try #require(Int(stub.query(compositeURL, "end") ?? "") ?? nil)
        #expect(Double(indexEnd - indexStart) / 86_400_000 <= FuyaoProvider.indexHistoryMaxDays)
        // Nothing was asked of the share endpoint for them.
        #expect(stub.urls("/api/a-share/prices/historical").count == 2)
    }

    @Test("Fund candles are explicitly unsupported so Tencent keeps the chart")
    func fundCandlesFallBack() async throws {
        var routes = standardRoutes()
        routes[FuyaoFixtures.meta("160105.SZ")] = .init(body: FuyaoFixtures.search([("160105.SZ", "南方积配", "fund-lof")]))
        let stub = FuyaoHTTPStub.install(routes: routes)
        let fuyao = provider(stub)
        for fund in [FuyaoFixtures.etf, FuyaoFixtures.lof] {
            do {
                _ = try await fuyao.candles(for: fund, period: .day, count: 30)
                Issue.record("fund history must not be served forward-adjusted")
            } catch let error as ProviderError {
                guard case .unsupported(let capability) = error, capability == .candles else {
                    Issue.record("expected unsupported(.candles), got \(error)")
                    continue
                }
                #expect(!error.shouldTripCircuit)
            }
        }
        #expect(stub.urls("/api/a-share/prices/historical").isEmpty)
        #expect(stub.urls("/api/a-share-index/prices/historical").isEmpty)
        // A fund history endpoint, had it been called, would only be forward-adjusted.
        #expect(stub.urls("/api/fund/market/historical").isEmpty)
    }

    @Test("A zero count returns nothing without a request; week and month stay with the fallback")
    func candlePeriodAndCount() async {
        let stub = FuyaoHTTPStub.install(routes: [:])
        let fuyao = provider(stub)
        #expect((try? await fuyao.candles(for: FuyaoFixtures.moutai, period: .day, count: 0))?.isEmpty == true)
        #expect(stub.urls.isEmpty)
        for period in [CandlePeriod.minute1, .minute5, .week, .month] {
            do {
                _ = try await fuyao.candles(for: FuyaoFixtures.moutai, period: period, count: 30)
                Issue.record("\(period) must be left to the fallback")
            } catch ProviderError.unsupported(.candles) {}
            catch { Issue.record("unexpected \(error)") }
        }
        #expect(stub.urls.isEmpty)
    }

    @Test("One failing fund keeps the other funds and the whole share batch")
    func partialBatchSurvives() async throws {
        var routes = standardRoutes()
        routes[FuyaoFixtures.meta("160105.SZ")] = .init(body: FuyaoFixtures.search([("160105.SZ", "南方积配", "fund-lof")]))
        routes["/api/fund/market/snapshot"] = .init(
            status: 200,
            body: #"{"code":3001,"message":"symbol not available","data":null}"#
        )
        // The share batch keeps answering; only the funds' endpoint fails.
        let stub = FuyaoHTTPStub.install(routes: routes)
        let quotes = try await provider(stub).quotes(
            for: [FuyaoFixtures.moutai, FuyaoFixtures.etf, FuyaoFixtures.composite, FuyaoFixtures.bank, FuyaoFixtures.lof]
        )
        #expect(Set(quotes.map(\.symbol)) == [
            FuyaoFixtures.moutai, FuyaoFixtures.composite, FuyaoFixtures.bank,
        ])
        #expect(stub.urls("/api/fund/market/snapshot").count == 2)
    }

    @Test("A fund-only miss surfaces its error when nothing else answered")
    func fundOnlyFailureSurfaces() async {
        var routes = standardRoutes()
        routes["/api/fund/market/snapshot"] = .init(status: 500, body: "{}")
        let stub = FuyaoHTTPStub.install(routes: routes)
        await #expect(throws: ProviderError.self) {
            _ = try await provider(stub).quotes(for: [FuyaoFixtures.etf])
        }
    }

    @Test("A quote batch without a usable timestamp yields no quotes")
    func missingTimestampRejected() async {
        var routes = standardRoutes()
        routes["/api/a-share/prices/snapshot"] = .init(
            body: FuyaoFixtures.snapshot([("600519.SH", 1277.8, 1256)], timestamp: nil)
        )
        let stub = FuyaoHTTPStub.install(routes: routes)
        await #expect(throws: ProviderError.self) {
            _ = try await provider(stub).quotes(for: [FuyaoFixtures.moutai])
        }
    }

    @Test("Duplicate identities are asked once and answered once")
    func duplicateIdentities() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let moutai = FuyaoFixtures.moutai
        let quotes = try await provider(stub).quotes(for: [moutai, moutai, FuyaoFixtures.pingan, moutai])
        #expect(quotes.map(\.symbol) == [moutai, FuyaoFixtures.pingan])
        #expect(stub.urls("/api/a-share/prices/snapshot").count == 1)
        #expect(stub.query(try #require(stub.url("/api/a-share/prices/snapshot")), "thscodes") == "600519.SH,000001.SZ")
    }

    @Test("2004 is a client error that does not trip the circuit; 4001 stops the batch")
    func businessErrors() async {
        var routes = standardRoutes()
        routes["/api/fund/market/snapshot"] = .init(
            status: 200, body: #"{"code":2004,"message":"endpoint not in plan","data":null}"#
        )
        routes["/api/a-share-index/prices/snapshot"] = .init(
            status: 200, body: #"{"code":4001,"message":"quota exhausted","data":null}"#
        )
        let stub = FuyaoHTTPStub.install(routes: routes)

        // 2004 costs only the fund; the share batch still lands.
        let partial = try? await provider(stub).quotes(for: [FuyaoFixtures.moutai, FuyaoFixtures.etf])
        #expect(partial?.map(\.symbol) == [FuyaoFixtures.moutai])

        do {
            _ = try await provider(stub).quotes(for: [FuyaoFixtures.moutai, FuyaoFixtures.bank])
            Issue.record("a quota refusal must surface")
        } catch let error as ProviderError {
            #expect(error.shouldTripCircuit)
            if case .rateLimited = error {} else { Issue.record("4001 should be rateLimited") }
            if case .clientError(status: 403, _) = FuyaoProvider.providerError(code: 2004, message: nil, endpoint: "x") {}
            else { Issue.record("2004 should be clientError(403)") }
            #expect(!(FuyaoProvider.providerError(code: 2004, message: nil, endpoint: "x")).shouldTripCircuit)
        } catch {
            Issue.record("unexpected \(error)")
        }
        // The quota refusal stopped the batch before the fund request.
        let before = stub.urls("/api/fund/market/snapshot").count
        _ = try? await provider(stub).quotes(for: [FuyaoFixtures.moutai, FuyaoFixtures.etf, FuyaoFixtures.bank])
        #expect(stub.urls("/api/fund/market/snapshot").count == before)
    }

    @Test("Names come from the meta cache once and are reused on every tick")
    func securityNames() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let fuyao = provider(stub)
        let names = try await fuyao.securityNames(for: [FuyaoFixtures.moutai, FuyaoFixtures.composite, FuyaoFixtures.bank])
        #expect(names.first { $0.symbol == FuyaoFixtures.moutai }?.name == "贵州茅台")
        #expect(names.first { $0.symbol == FuyaoFixtures.composite }?.name == MarketIndexID.shanghaiComposite.displayName)
        #expect(names.first { $0.symbol == FuyaoFixtures.bank }?.name == "银行")
        // Only the share needed a request; index and board names are local.
        #expect(stub.urls("/api/meta/tickers/search").count == 1)

        _ = try await fuyao.securityNames(for: [FuyaoFixtures.moutai])
        #expect(stub.urls("/api/meta/tickers/search").count == 1)
        // Quotes attach the cached name without a request of their own.
        let quotes = try await fuyao.quotes(for: [FuyaoFixtures.moutai])
        #expect(quotes.first?.name == "贵州茅台")
        #expect(stub.urls("/api/meta/tickers/search").count == 1)
    }

    @Test("covers admits A-share instruments, the three benchmarks and boards only")
    func coverage() async throws {
        let fuyao = provider(FuyaoHTTPStub.install(routes: [:]))
        let covered = await fuyao.covers(FuyaoFixtures.moutai)
        let coveredFund = await fuyao.covers(FuyaoFixtures.etf)
        let coveredIndex = await fuyao.covers(FuyaoFixtures.composite)
        let coveredBoard = await fuyao.covers(FuyaoFixtures.bank)
        let hk = await fuyao.covers(SymbolID(market: .hk, code: "700"))
        let metal = await fuyao.covers(SymbolID(metal: .goldSpot))
        let malformedBoard = await fuyao.covers(SymbolID(sectorIndex: SectorIndexID(code: "12AB34", name: "x")))
        #expect(covered)
        #expect(coveredFund)
        #expect(coveredIndex)
        #expect(coveredBoard)
        #expect(!hk)
        #expect(!metal)
        #expect(!malformedBoard)
    }

    @Test("Quotes are requested at most once a second and the internal requests keep their spacing")
    func pacingHolds() async throws {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let fuyao = FuyaoProvider(
            apiKey: "test-key",
            http: stub.http,
            pacing: FuyaoProvider.RequestPacing(
                minInterval: 0.5, sleepsWhenPaced: false
            ),
            // The clock only moves when a request is recorded, which a real sleep
            // would; here the scheduler is busy, so the second request is refused.
            now: { clock }
        )
        // First request passes; the next one, within 0.5s of it, is not spent.
        do {
            _ = try await fuyao.quotes(for: [FuyaoFixtures.moutai, FuyaoFixtures.composite])
            Issue.record("the second request must not start inside the spacing window")
        } catch ProviderError.badResponse(let detail) {
            #expect(detail.contains("pacing"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(stub.urls.count == 1)
        _ = try? await fuyao.quotes(for: [FuyaoFixtures.moutai, FuyaoFixtures.composite])
        #expect(stub.urls.count == 1)
    }

    @Test("The production descriptor polls once a second for covered markets")
    func descriptorCadence() {
        let descriptor = FuyaoProvider(apiKey: "k").descriptor
        #expect(descriptor.suggestedPollInterval == 1)
        #expect(descriptor.markets == [.sh, .sz])
        #expect(descriptor.capabilities.contains(.referenceData))
        #expect(descriptor.rateLimit?.minInterval == 0.5)
    }

    @Test("A cancelled batch is cancelled, not reported as a provider failure")
    func cancellationPropagates() async {
        let stub = FuyaoHTTPStub.install(routes: standardRoutes())
        let fuyao = provider(stub)
        let task = Task {
            while !Task.isCancelled {
                _ = try? await fuyao.quotes(for: [FuyaoFixtures.moutai])
            }
        }
        task.cancel()
        await task.value
        // The provider stays usable after the cancelled call.
        #expect((try? await fuyao.quotes(for: [FuyaoFixtures.moutai]))?.count == 1)
    }
}
