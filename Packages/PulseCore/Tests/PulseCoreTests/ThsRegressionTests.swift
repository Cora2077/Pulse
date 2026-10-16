import Foundation
import Testing
@testable import PulseCore

@Suite("THS correctness regressions")
struct ThsRegressionTests {
    private let zone = Market.sh.timeZone

    @Test("Names do not participate in board identity or dictionary keys")
    func renameKeepsIdentity() throws {
        let old = SymbolID(sectorIndex: SectorIndexID(code: "881999", name: "旧名"))
        let new = SymbolID(sectorIndex: SectorIndexID(code: "881999", name: "新名"))
        #expect(old == new)
        #expect(Set([old, new]).count == 1)
        #expect([old: 1][new] == 1)
        #expect(try JSONDecoder().decode(SymbolID.self, from: JSONEncoder().encode(old)) == new)
    }

    @Test("Legacy sz rows normalize to the same sh carrier as direct construction")
    func legacyCarrier() throws {
        let json = Data(#"{"market":"sz","code":"881155"}"#.utf8)
        let decoded = try JSONDecoder().decode(SymbolID.self, from: json)
        #expect(decoded == SymbolID(market: .sz, code: "881155"))
        #expect(decoded == SymbolID(market: .sh, code: "881155"))
        #expect(decoded.market == .sh)
    }

    @Test("An actual old-shaped decoder can read a newly encoded snapshot")
    func oldReader() throws {
        struct OldSymbol: Decodable { let market: Market; let code: String }
        let symbols = [SymbolID(market: .sh, code: "881155"), SymbolID(market: .us, code: "AAPL")]
        let encoded = try JSONEncoder().encode(symbols)
        let old = try JSONDecoder().decode([OldSymbol].self, from: encoded)
        #expect(old.map(\.market) == [.sh, .us])
        #expect(old.map(\.code) == ["881155", "AAPL"])
    }

    @Test("Unsafe persisted board paths fall back without losing other snapshot rows")
    func unsafeCodeIsNotAnIdentity() throws {
        let json = Data(#"[{"market":"sh","code":"881999","sectorIndex":{"code":"../../etc","name":"invalid"}},{"market":"us","code":"AAPL"}]"#.utf8)
        let symbols = try JSONDecoder().decode([SymbolID].self, from: json)
        #expect(symbols.count == 2)
        #expect(symbols[0].sectorIndex == nil)
        #expect(symbols[1].code == "AAPL")
        #expect(!ThsSectorProvider().covers(SymbolID(sectorIndex: .init(code: "../x", name: "invalid"))))
    }

    @Test("Trend volume uses the fifth field, already shares, not the auxiliary price")
    func correctTrendVolume() {
        let bars = ThsSectorProvider.parseTrend(
            "0930,1399.054,256088160,7.617,33618926;0931,1396.175,912446730,7.359,125177114",
            date: "20261015", timeZone: zone
        )
        #expect(bars.map(\.volume) == [33618926, 125177114])
        #expect(bars.compactMap(\.volume).reduce(0, +) == 158796040)
        let zero = ThsSectorProvider.parseTrend("0932,1390,0,7.0,0", date: "20261015", timeZone: zone)
        #expect(zero.first?.volume == 0)
    }

    @Test("End-labelled five-minute bars form exact fifteen-minute OHLCV at session edges")
    func correctFifteenMinuteBuckets() throws {
        let rows = [
            "202610150935,10,12,9,11,1", "202610150940,11,15,10,14,2",
            "202610150945,14,16,13,15,3", "202610150950,15,20,14,19,4",
            "202610151120,20,22,19,21,5", "202610151125,21,24,20,23,6",
            "202610151130,23,25,22,24,7", "202610151305,30,32,29,31,8",
            "202610151310,31,34,30,33,9", "202610151315,33,35,32,34,10",
        ]
        let payload = try JSONSerialization.data(withJSONObject: ["data": rows.joined(separator: ";")])
        let bars = try ThsSectorProvider.parseCandles(payload, period: .minute15, timeZone: zone)
        #expect(bars.count == 4)
        let first = try #require(bars.first)
        #expect(first.open == 10 && first.high == 16 && first.low == 9 && first.close == 15)
        #expect(first.volume == 6)
        let fmt = DateFormatter()
        fmt.timeZone = zone
        fmt.dateFormat = "HHmm"
        #expect(bars.map { fmt.string(from: $0.time) } == ["0945", "1000", "1130", "1315"])
        #expect(bars.last?.volume == 27)
    }

    @Test("Impossible dates and non-finite OHLC or prices are not plotted")
    func malformedNumbersAndDates() throws {
        let payload = Data(#"{"data":"20260230,1,2,1,2,5;20261015,1,inf,1,2,5;20261016,nan,2,1,2,5"}"#.utf8)
        #expect(try ThsSectorProvider.parseCandles(payload, period: .day, timeZone: zone).isEmpty)
        #expect(ThsSectorProvider.parseTrend("0960,1,1,1,1;0931,inf,1,1,1", date: "20261015", timeZone: zone).isEmpty)
        #expect(ThsSectorProvider.parseTrend("0931,1,1,1,1", date: "20260230", timeZone: zone).isEmpty)
    }

    @Test("Freshness considers intraday time, lunch, pre-open and the close")
    func intradayFreshness() throws {
        let fmt = DateFormatter()
        fmt.timeZone = zone
        fmt.dateFormat = "yyyyMMddHHmm"
        func date(_ value: String) -> Date { fmt.date(from: value)! }
        func bars(_ value: String) -> [Candle] {
            [Candle(time: date(value), open: 1, high: 1, low: 1, close: 1)]
        }
        #expect(!ThsSectorProvider.reachesPresent(bars("202610151000"), period: .minute5, market: .sh, now: date("202610151420")))
        #expect(ThsSectorProvider.reachesPresent(bars("202610151420"), period: .minute5, market: .sh, now: date("202610151420")))
        #expect(ThsSectorProvider.reachesPresent(bars("202610151130"), period: .minute5, market: .sh, now: date("202610151230")))
        #expect(ThsSectorProvider.reachesPresent(bars("202610151130"), period: .minute5, market: .sh, now: date("202610151301")))
        #expect(ThsSectorProvider.reachesPresent(bars("202610151500"), period: .minute5, market: .sh, now: date("202610151700")))
        #expect(!ThsSectorProvider.reachesPresent(bars("202610141500"), period: .minute5, market: .sh, now: date("202610151700")))
        #expect(ThsSectorProvider.reachesPresent(bars("202610141500"), market: .sh, now: date("202610150800")))
    }

    @Test("Non-finite required quote values fail instead of entering portfolio caches")
    func invalidQuote() {
        let data = Data(#"{"items":{"10":"inf","6":"1401"}}"#.utf8)
        #expect(throws: ProviderError.self) {
            _ = try ThsSectorProvider.parseQuote(data, symbol: SymbolID(market: .sh, code: "881155"))
        }
    }
}

// Token-scoped plans keep parallel Swift Testing cases isolated without live HTTP.
private final class ThsHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body: String = "callback({});"
        var hold = false
    }
    private struct Plan {
        var replies: [Reply]
        var urls: [URL] = []
        let events: AsyncStream<URL>.Continuation
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]

    struct Handle {
        let token: String
        let requests: AsyncStream<URL>
        let http: HTTPClient
        var urls: [URL] {
            ThsHTTPStub.lock.lock()
            defer { ThsHTTPStub.lock.unlock() }
            return ThsHTTPStub.plans[token]?.urls ?? []
        }
    }
    static func install(_ replies: [Reply]) -> Handle {
        let token = UUID().uuidString
        let stream = AsyncStream<URL>.makeStream()
        lock.lock()
        plans[token] = Plan(replies: replies, events: stream.continuation)
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThsHTTPStub.self]
        return Handle(token: token, requests: stream.stream, http: HTTPClient(
            session: URLSession(configuration: config), defaultHeaders: ["X-THS-Test": token]
        ))
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let token = request.value(forHTTPHeaderField: "X-THS-Test") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        guard var plan = Self.plans[token] else { Self.lock.unlock(); return }
        let index = plan.urls.count
        plan.urls.append(url)
        let reply = plan.replies.indices.contains(index) ? plan.replies[index] : Reply(status: 500)
        Self.plans[token] = plan
        Self.lock.unlock()
        plan.events.yield(url)
        if reply.hold { return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("THS transport and history")
struct ThsTransportTests {
    private let board = SymbolID(market: .sh, code: "881155")
    private let quote = #"callback({"items":{"6":"1401.281","10":"1374.856","13":"3329399200","name":"银行","time":"2026-10-15 13:34:55 北京时间"}});"#

    @Test("A transient 502 retries then parses the real Quote model")
    func retryThenQuote() async throws {
        let stub = ThsHTTPStub.install([.init(status: 502), .init(body: quote)])
        let quotes = try await ThsSectorProvider(http: stub.http).quotes(for: [board])
        #expect(quotes.count == 1)
        #expect(quotes.first?.symbol == board)
        #expect(quotes.first?.price == 1374.856)
        #expect(quotes.first?.volume == 3329399200)
        #expect(stub.urls.count == 2)
        #expect(stub.urls.allSatisfy { $0.path == "/v6/realhead/bk_881155/defer/last.js" })
        #expect(stub.urls[0].query == nil)
        #expect(stub.urls[1].query?.hasPrefix("_=") == true)
    }

    @Test("Retries are bounded and 429 is respected immediately")
    func retryBudgetAndRateLimit() async {
        let failed = ThsHTTPStub.install(Array(repeating: .init(status: 502), count: 4))
        await #expect(throws: ProviderError.self) {
            _ = try await ThsSectorProvider(http: failed.http).quotes(for: [board])
        }
        #expect(failed.urls.count == 3)
        let limited = ThsHTTPStub.install([.init(status: 429), .init(body: quote)])
        await #expect(throws: ProviderError.self) {
            _ = try await ThsSectorProvider(http: limited.http).quotes(for: [board])
        }
        #expect(limited.urls.count == 1)
    }

    @Test("An invalid identity never reaches HTTP")
    func invalidPathDoesNotFetch() async {
        let stub = ThsHTTPStub.install([])
        let symbol = SymbolID(sectorIndex: .init(code: "../../x", name: "invalid"))
        await #expect(throws: ProviderError.self) {
            _ = try await ThsSectorProvider(http: stub.http).candles(for: symbol, period: .day, count: 10)
        }
        #expect(stub.urls.isEmpty)
    }

    @Test("Year top-ups merge without replacing the recent session or duplicating dates")
    func historyMerge() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.sh.timeZone
        let now = Date.now
        let fmt = DateFormatter()
        fmt.timeZone = Market.sh.timeZone
        fmt.dateFormat = "yyyyMMdd"
        let today = fmt.string(from: now)
        let yesterday = fmt.string(from: calendar.date(byAdding: .day, value: -1, to: now)!)
        let earlier = fmt.string(from: calendar.date(byAdding: .day, value: -2, to: now)!)
        let year = calendar.component(.year, from: now)
        func body(_ rows: [String]) -> String {
            "callback(" + String(data: try! JSONSerialization.data(withJSONObject: ["data": rows.joined(separator: ";")]), encoding: .utf8)! + ");"
        }
        let stub = ThsHTTPStub.install([
            .init(body: body(["\(yesterday),10,12,9,11,1", "\(today),11,13,10,12,2"])),
            .init(body: "callback({\"bk_881155\":{\"1\":\"\(today)\",\"7\":11,\"8\":14,\"9\":10,\"11\":13,\"13\":4}});"),
            .init(body: body(["\(earlier),8,10,7,9,3", "\(today),10,12,9,11,9"])),
            .init(body: body(["\(year-1)0102,1,2,1,2,1", "\(year-1)0103,2,3,2,3,1"])),
        ])
        let bars = try await ThsSectorProvider(http: stub.http).candles(for: board, period: .day, count: 4)
        #expect(bars.count == 4)
        #expect(Set(bars.map(\.time)).count == 4)
        #expect(bars.last?.close == 13)
        #expect(bars.last?.volume == 4)
        #expect(stub.urls.count == 4)
    }

    @Test("Cancellation during an optional year top-up is not swallowed")
    func cancelHistory() async throws {
        let fmt = DateFormatter()
        fmt.timeZone = Market.sh.timeZone
        fmt.dateFormat = "yyyyMMdd"
        let stamp = fmt.string(from: .now)
        let rolling = "callback({\"data\":\"\(stamp),1,2,1,2,5\"});"
        let snapshot = "callback({\"bk_881155\":{\"1\":\"\(stamp)\",\"7\":1,\"8\":2,\"9\":1,\"11\":2,\"13\":5}});"
        let stub = ThsHTTPStub.install([.init(body: rolling), .init(body: snapshot), .init(hold: true)])
        let task = Task { try await ThsSectorProvider(http: stub.http).candles(for: board, period: .day, count: 5) }
        var requests = stub.requests.makeAsyncIterator()
        _ = await requests.next()
        _ = await requests.next()
        _ = await requests.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation was swallowed")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(stub.urls.count == 3)
    }
}

@Suite("THS current-day daily candle")
struct ThsDailySnapshotTests {
    private let bank = SymbolID(market: .sh, code: "881155")
    private var afterClose: Date { date("202610151550") }
    private let today = #"callback({"bk_881155":{"1":"20261015","7":"1399.054","8":"1399.054","9":"1372.647","11":"1386.064","13":4692219500,"19":"37398859000.000","dt":"1549"}});"#
    private let oldHistory = #"callback({"data":"20261013,1415.473,1416.948,1397.530,1401.887,4073590400;20261014,1401.257,1417.920,1398.435,1401.281,3792556100"});"#
    private let quoteToday = #"callback({"items":{"time":"2026-10-15 15:50:26 北京时间","7":"1399.054","8":"1399.054","9":"1372.647","10":"1386.064","13":"4692219500.000"}});"#

    private func date(_ stamp: String) -> Date {
        let fmt = DateFormatter()
        fmt.timeZone = Market.sh.timeZone
        fmt.dateFormat = "yyyyMMddHHmm"
        return fmt.date(from: stamp)!
    }

    @Test("A yesterday-only rolling window still returns today's official candle after close")
    func yesterdayWindowGetsToday() async throws {
        let stub = ThsHTTPStub.install([
            .init(body: oldHistory), .init(body: oldHistory), .init(body: oldHistory), .init(body: today),
        ])
        let fixedNow = afterClose
        let composite = CompositeProvider(providers: [ThsSectorProvider(http: stub.http, now: { fixedNow })])
        let bars = try await composite.candles(for: bank, period: .day, count: 2)
        #expect(bars.count == 2)
        let last = try #require(bars.last)
        #expect(last.time == date("202610150000"))
        #expect(last.open == 1399.054 && last.high == 1399.054)
        #expect(last.low == 1372.647 && last.close == 1386.064)
        #expect(last.volume == 4692219500)
        #expect(stub.urls.last?.path == "/v6/line/bk_881155/01/today.js")
        #expect(stub.urls.count == 4)
    }

    @Test("Today's newer snapshot replaces an existing daily candle, never duplicates it")
    func snapshotReplacesSameDay() async throws {
        let rolling = #"callback({"data":"20261014,1401.257,1417.920,1398.435,1401.281,3792556100;20261015,1399.054,1399.054,1380,1390,100"});"#
        let stub = ThsHTTPStub.install([.init(body: rolling), .init(body: today)])
        let fixedNow = afterClose
        let bars = try await ThsSectorProvider(http: stub.http, now: { fixedNow }).candles(for: bank, period: .day, count: 2)
        #expect(bars.count == 2)
        #expect(Set(bars.map(\.time)).count == 2)
        #expect(bars.last?.close == 1386.064)
        #expect(bars.last?.low == 1372.647)
    }

    @Test("Official quote OHLC fills today when the standalone snapshot is missing")
    func quoteFallback() async throws {
        let stub = ThsHTTPStub.install([
            .init(body: oldHistory), .init(body: oldHistory), .init(body: oldHistory),
            .init(body: "callback({});"), .init(body: quoteToday),
        ])
        let fixedNow = afterClose
        let bars = try await ThsSectorProvider(http: stub.http, now: { fixedNow }).candles(for: bank, period: .day, count: 2)
        #expect(bars.last?.time == date("202610150000"))
        #expect(bars.last?.close == 1386.064)
        #expect(stub.urls.count == 5)
    }

    @Test("A holiday or pre-open snapshot keeps its actual source date")
    func noInventedHolidayCandle() async throws {
        let friday = #"callback({"data":"20261015,10,12,9,11,100;20261016,11,13,10,12,200"});"#
        let fridaySnapshot = #"callback({"bk_881155":{"1":20261016,"7":11,"8":13,"9":10,"11":12,"13":200}});"#
        let stub = ThsHTTPStub.install([.init(body: friday), .init(body: fridaySnapshot)])
        let saturday = date("202610171200")
        let bars = try await ThsSectorProvider(http: stub.http, now: { saturday }).candles(for: bank, period: .day, count: 2)
        #expect(bars.last?.time == date("202610160000"))
        #expect(bars.count == 2)
        #expect(stub.urls.count == 2)
    }

    @Test("Unusable snapshots cannot create a dated candle from an absent timestamp")
    func invalidSnapshots() throws {
        let board = try #require(bank.sectorIndex)
        let future = Data(#"{"bk_881155":{"1":"20261016","7":10,"8":12,"9":9,"11":11}}"#.utf8)
        #expect(try ThsSectorProvider.parseDailySnapshot(future, board: board, now: afterClose) == nil)
        let missingTime = Data(#"{"items":{"7":10,"8":12,"9":9,"10":11}}"#.utf8)
        #expect(try ThsSectorProvider.parseDailyQuote(missingTime, now: afterClose) == nil)
        let impossibleOHLC = Data(#"{"bk_881155":{"1":"20261015","7":10,"8":5,"9":20,"11":11}}"#.utf8)
        #expect(try ThsSectorProvider.parseDailySnapshot(impossibleOHLC, board: board, now: afterClose) == nil)
    }

    @Test("Cancellation during the daily snapshot is propagated")
    func snapshotCancellation() async throws {
        let rolling = #"callback({"data":"20261015,10,12,9,11,100"});"#
        let stub = ThsHTTPStub.install([.init(body: rolling), .init(hold: true)])
        let fixedNow = afterClose
        let task = Task { try await ThsSectorProvider(http: stub.http, now: { fixedNow }).candles(for: bank, period: .day, count: 1) }
        var events = stub.requests.makeAsyncIterator()
        _ = await events.next()
        _ = await events.next()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Snapshot cancellation was swallowed")
        } catch { #expect(error is CancellationError) }
        #expect(stub.urls.count == 2)
    }
}
