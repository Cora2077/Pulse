import Foundation
import Testing
@testable import PulseCore

/// 板块目录、成分股、成分股报价与相对强弱：重点是日期对齐、缺基期、
/// 最新日缺失、无效价格与重复行，以及 HTTP 200 里的业务失败。
private final class FuyaoBoardStub: URLProtocol, @unchecked Sendable {
    private struct Plan {
        /// 依次用于第 1、2、3… 个请求；最后一个重复使用。
        var bodies: [String]
        var status: Int
        var requests: [URL] = []
        var cursor = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var plans: [String: Plan] = [:]
    private static let tokenHeader = "X-Pulse-Fuyao-Board-Test"

    struct Handle {
        let token: String
        let http: HTTPClient

        var urls: [URL] {
            FuyaoBoardStub.lock.lock()
            defer { FuyaoBoardStub.lock.unlock() }
            return FuyaoBoardStub.plans[token]?.requests ?? []
        }

        func query(_ url: URL, _ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
    }

    static func install(bodies: [String], status: Int = 200) -> Handle {
        let token = UUID().uuidString
        lock.lock()
        plans[token] = Plan(bodies: bodies, status: status)
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FuyaoBoardStub.self]
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
        var plan = Self.plans[token]
        if let url = request.url { plan?.requests.append(url) }
        let index = plan.map { min($0.cursor, $0.bodies.count - 1) } ?? 0
        let nextCursor = (plan?.cursor ?? 0) + 1
        plan?.cursor = nextCursor
        Self.plans[token] = plan
        Self.lock.unlock()

        let status = plan?.status ?? 404
        let body = plan?.bodies[index] ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Fuyao boards, constituents and relative strength")
struct FuyaoBoardsTests {
    static let fetchedAt = Date(timeIntervalSince1970: 1_792_500_000)
    static let snapshotTime = Date(timeIntervalSince1970: 1_792_475_991)
    static let snapshotTimeMs = 1_792_475_991_000.0

    private func provider(_ stub: FuyaoBoardStub.Handle) -> FuyaoProvider {
        FuyaoProvider(
            apiKey: "stub-key",
            http: stub.http,
            pacing: FuyaoProvider.RequestPacing(minInterval: 0, sleepsWhenPaced: true),
            now: { Self.fetchedAt }
        )
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private static func beijing(_ day: Int, month: Int = 6, year: Int = 2026, hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = FuyaoProvider.beijingTimeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func candle(_ day: Date, _ close: Double) -> Candle {
        Candle(time: day, open: close, high: close, low: close, close: close)
    }

    /// 25 个北京时间整日收盘，价格 = 100、101、…；可选覆盖某天的价格。
    private static func series(from day: Int, closes: [Double]) -> [Candle] {
        closes.enumerated().map { offset, close in
            candle(beijing(day + offset), close)
        }
    }

    // MARK: - 解析

    private static let catalog = """
    {"code":0,"message":"success","data":{"timestamp":1748102400000,"item":[
      {"thscode":"886042.TI","name":"白酒概念"},
      {"thscode":"886041.TI","name":"新能源车"},
      {"thscode":"886042.TI","name":"白酒概念（重复）"},
      {"thscode":"881155.TI","name":"银行"},
      {"thscode":"000001.SH","name":"上证指数"},
      {"thscode":"88604.TI","name":"五位代码"},
      {"thscode":"776042.TI","name":"非88开头"},
      {"thscode":"88604A.TI","name":"含字母"},
      {"thscode":"886042.SH","name":"错误后缀"},
      {"name":"缺代码"},
      {"thscode":"  ","name":"空白代码"}
    ]}}
    """

    @Test("目录只保留合法 88 开头的 .TI 代码并去重")
    func catalogFiltering() throws {
        let timed = try FuyaoProvider.parseBoardCatalog(data: data(Self.catalog), fetchedAt: Self.fetchedAt)
        #expect(timed.value.map(\.thscode) == ["886042.TI", "886041.TI", "881155.TI"])
        #expect(timed.value.map(\.name) == ["白酒概念", "新能源车", "银行"])
        #expect(timed.value.map(\.id) == timed.value.map(\.thscode))
        #expect(timed.value.allSatisfy { $0.symbol != nil })
        let first = try #require(timed.value.first)
        #expect(first.symbol == SymbolID(sectorIndex: SectorIndexID(code: "886042", name: "白酒概念")))
        // 名称是来源值，不因本地目录是否收录而改变身份。
        #expect(first.symbol?.sectorIndex?.code == "886042")
        #expect(timed.dataTime == Date(timeIntervalSince1970: 1_748_102_400))
        #expect(timed.fetchedAt == Self.fetchedAt)
    }

    @Test("目录缺少上游时间时 dataTime 为 nil，不写成 now")
    func catalogWithoutTimestamp() throws {
        let json = #"{"code":0,"data":{"item":[{"thscode":"886042.TI","name":"白酒概念"}]}}"#
        let timed = try FuyaoProvider.parseBoardCatalog(data: data(json), fetchedAt: Self.fetchedAt)
        #expect(timed.dataTime == nil)
        #expect(timed.value.count == 1)
        #expect(timed.fetchedAt == Self.fetchedAt)
    }

    private static let constituents = """
    {"code":0,"message":"success","data":{"timestamp":1748102400000,"item":[
      {"thscode":"600519.SH","ticker":"600519","name":"贵州茅台"},
      {"thscode":"000858.SZ","ticker":"000858","name":"五粮液"},
      {"thscode":"600519.SH","ticker":"600519","name":"贵州茅台（重复）"},
      {"thscode":"830799.BJ","ticker":"830799","name":"艾融软件"},
      {"thscode":"60051.SH","ticker":"60051","name":"五位代码"},
      {"thscode":"600519.HK","ticker":"600519","name":"错误后缀"},
      {"thscode":"","ticker":"","name":"空代码"}
    ]}}
    """

    @Test("成分股保留 BJ 但 symbol 为 nil，并去重")
    func constituentParsing() throws {
        let timed = try FuyaoProvider.parseBoardConstituents(data: data(Self.constituents), fetchedAt: Self.fetchedAt)
        #expect(timed.value.map(\.thscode) == ["600519.SH", "000858.SZ", "830799.BJ"])
        let moutai = try #require(timed.value.first)
        #expect(moutai.name == "贵州茅台")
        #expect(moutai.symbol == SymbolID(market: .sh, code: "600519"))
        #expect(timed.value[1].symbol == SymbolID(market: .sz, code: "000858"))
        // 本项目没有北京市场：代码保留，身份缺失。
        #expect(timed.value[2].symbol == nil)
        #expect(timed.value[2].name == "艾融软件")
        #expect(timed.dataTime == Date(timeIntervalSince1970: 1_748_102_400))
        #expect(timed.value.allSatisfy { $0.id == $0.thscode })
    }

    // MARK: - 请求形态与业务失败

    @Test("目录与成分股走文档端点，业务失败即使 HTTP 200 也抛出")
    func requestShapes() async throws {
        let stub = FuyaoBoardStub.install(bodies: [Self.catalog, Self.catalog, Self.constituents])
        let provider = provider(stub)

        let industry = try await provider.boardCatalog(industry: true)
        let concept = try await provider.boardCatalog(industry: false)
        let list = try await provider.boardConstituents(thscode: " 886042.ti ")
        #expect(industry.value.map(\.thscode) == ["886042.TI", "886041.TI", "881155.TI"])
        #expect(concept.value.count == 3)
        #expect(list.value.count == 3)

        let urls = stub.urls
        #expect(urls.count == 3)
        #expect(urls[0].path == "/api/a-share-index/catalog/ths-index-list")
        #expect(stub.query(urls[0], "tag") == "industry")
        #expect(urls[1].path == "/api/a-share-index/catalog/ths-index-list")
        #expect(stub.query(urls[1], "tag") == "cn_concept")
        #expect(urls[2].path == "/api/a-share-index/constituents/ths-stock-list")
        #expect(stub.query(urls[2], "thscode") == "886042.TI")
    }

    @Test("HTTP 200 携带业务错误码时抛 ProviderError")
    func businessFailure() async throws {
        let failures = [
            #"{"code":2004,"message":"no permission","data":null}"#,
            #"{"code":4001,"message":"rate limited","data":null}"#,
            #"{"code":0,"message":"success"}"#,
        ]
        for body in failures {
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseBoardCatalog(data: self.data(body), fetchedAt: Self.fetchedAt)
            }
            #expect(throws: ProviderError.self) {
                _ = try FuyaoProvider.parseBoardConstituents(data: self.data(body), fetchedAt: Self.fetchedAt)
            }
        }

        let stub = FuyaoBoardStub.install(bodies: [#"{"code":2004,"message":"no permission","data":null}"#])
        let provider = provider(stub)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.boardCatalog(industry: true)
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.boardConstituents(thscode: "886042.TI")
        }
    }

    @Test("非法的成分股 thscode 不触网")
    func invalidConstituentRequest() async throws {
        let stub = FuyaoBoardStub.install(bodies: [Self.constituents])
        let provider = provider(stub)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.boardConstituents(thscode: "   ")
        }
        await #expect(throws: ProviderError.self) {
            _ = try await provider.boardConstituents(thscode: "886042.TI,881155.TI")
        }
        #expect(stub.urls.isEmpty)
    }

    // MARK: - 成分股报价

    private static func snapshotBody(_ items: String, timestamp: Double? = snapshotTimeMs) -> String {
        let stamp = timestamp.map { String($0) } ?? "null"
        return #"{"code":0,"message":"success","data":{"timestamp":\#(stamp),"item":[\#(items)]}}"#
    }

    private static let moutaiRow =
        #"{"thscode":"600519.SH","last_price":1500,"prev_price":1490,"open_price":1495,"high_price":1505,"low_price":1488,"volume":100,"turnover":150000}"#

    @Test("成分股报价按完整 thscode 去重，只请求 SH/SZ，时间取快照 timestamp")
    func constituentQuotesJoin() async throws {
        let items = """
        \(Self.moutaiRow),
        {"thscode":"000001.SZ","last_price":12.5,"prev_price":12.4},
        {"thscode":"300750.SZ","last_price":null,"prev_price":200}
        """
        let stub = FuyaoBoardStub.install(bodies: [Self.snapshotBody(items)])
        let provider = provider(stub)
        let constituents = [
            FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台"),
            FuyaoConstituent(thscode: "830799.BJ", name: "艾融软件"),
            FuyaoConstituent(thscode: "600519.SH", name: "重复"),
            FuyaoConstituent(thscode: "000001.SZ", name: "平安银行"),
            FuyaoConstituent(thscode: "300750.SZ", name: "宁德时代"),
        ]
        let quotes = try await provider.constituentQuotes(constituents)

        let urls = stub.urls
        #expect(urls.count == 1)
        #expect(urls[0].path == "/api/a-share/prices/snapshot")
        // BJ 与重复代码都不进入请求。
        #expect(stub.query(urls[0], "thscodes") == "600519.SH,000001.SZ,300750.SZ")

        #expect(quotes.map(\.symbol) == [
            SymbolID(market: .sh, code: "600519"),
            SymbolID(market: .sz, code: "000001"),
        ])
        let moutai = try #require(quotes.first)
        #expect(moutai.name == "贵州茅台")
        #expect(moutai.price == 1500)
        #expect(moutai.previousClose == 1490)
        #expect(moutai.currencyCode == "CNY")
        // 接口就绪时间，而不是 fetchedAt / now。
        #expect(moutai.timestamp == Self.snapshotTime)
        #expect(moutai.timestamp != Self.fetchedAt)
        #expect(quotes.allSatisfy { $0.price > 0 && $0.price.isFinite })
    }

    @Test("600519.SH 与 000001.SZ 按完整 thscode 隔离")
    func fullThscodeIsolation() async throws {
        // 同一 6 位数字出现在两个市场：只有完整代码相同才是同一身份。
        let items = #"{"thscode":"600519.SH","last_price":10,"prev_price":9}"#
        let stub = FuyaoBoardStub.install(bodies: [Self.snapshotBody(items)])
        let provider = provider(stub)
        let quotes = try await provider.constituentQuotes([
            FuyaoConstituent(thscode: "600519.SZ", name: "另一个市场"),
            FuyaoConstituent(thscode: "000001.SZ", name: "平安银行"),
        ])
        #expect(quotes.isEmpty)
        #expect(stub.urls.count == 1)
    }

    @Test("超过 100 只成分股分多批，单批失败保留其余批次")
    func batchingAndPartialFailure() async throws {
        let first = (0..<100).map { String(format: #"{"thscode":"6%05d.SH","last_price":10,"prev_price":9}"#, $0) }.joined(separator: ",")
        let second = #"{"thscode":"000001.SZ","last_price":12,"prev_price":11}"#
        let stub = FuyaoBoardStub.install(bodies: [
            Self.snapshotBody(first),
            #"{"code":2004,"message":"no permission","data":null}"#,
            Self.snapshotBody(second),
        ])
        let provider = provider(stub)
        let constituents = (0..<100).map { FuyaoConstituent(thscode: String(format: "6%05d.SH", $0), name: "A\($0)")
        } + [FuyaoConstituent(thscode: "000001.SZ", name: "平安银行")]

        let quotes = try await provider.constituentQuotes(constituents)
        #expect(stub.urls.count == 2)
        let firstCodes = try #require(stub.urls.first.flatMap { stub.query($0, "thscodes") })
        #expect(firstCodes.split(separator: ",").count == 100)
        // 第 2 批失败，第 1 批结果保留。
        #expect(quotes.count == 100)
        #expect(quotes.allSatisfy { $0.timestamp == Self.snapshotTime })
    }

    @Test("限流后停止后续批次，已成功批次照常返回")
    func quotaStopsFanOut() async throws {
        let first = #"{"thscode":"600000.SH","last_price":10,"prev_price":9}"#
        let stub = FuyaoBoardStub.install(bodies: [
            Self.snapshotBody(first),
            #"{"code":4001,"message":"rate limited","data":null}"#,
        ])
        let provider = provider(stub)
        let constituents = (0..<250).map { FuyaoConstituent(thscode: String(format: "6%05d.SH", $0), name: "A") }

        let quotes = try await provider.constituentQuotes(constituents)
        // 第 1 批成功、第 2 批限流即停，第 3 批从未发出。
        #expect(stub.urls.count == 2)
        #expect(quotes.count == 1)
        #expect(quotes.first?.symbol == SymbolID(market: .sh, code: "600000"))
    }

    @Test("全部批次失败时抛出；限流错误原样抛出")
    func allBatchesFail() async throws {
        let stub = FuyaoBoardStub.install(bodies: [#"{"code":2004,"message":"no permission","data":null}"#])
        let provider = provider(stub)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.constituentQuotes([
                FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台"),
            ])
        }

        let quota = FuyaoBoardStub.install(bodies: [#"{"code":4001,"message":"rate limited","data":null}"#])
        let quotaProvider = self.provider(quota)
        do {
            _ = try await quotaProvider.constituentQuotes([
                FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台"),
            ])
            Issue.record("限流时应当抛出")
        } catch ProviderError.rateLimited {
            // 符合预期。
        } catch {
            Issue.record("期望 rateLimited，实际 \(error)")
        }
    }

    @Test("快照缺少时间或全部无效时不把 now 当时间")
    func snapshotWithoutTimestamp() async throws {
        let stub = FuyaoBoardStub.install(bodies: [Self.snapshotBody(Self.moutaiRow, timestamp: nil)])
        let provider = provider(stub)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.constituentQuotes([FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台")])
        }

        let nanStub = FuyaoBoardStub.install(bodies: [
            Self.snapshotBody(#"{"thscode":"600519.SH","last_price":0,"prev_price":9}"#),
        ])
        let nanProvider = self.provider(nanStub)
        let quotes = try await nanProvider.constituentQuotes([FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台")])
        #expect(quotes.isEmpty)
        #expect(nanStub.urls.count == 1)
    }

    @Test("空输入不发请求；全部不可映射时返回空")
    func emptyAndUnmappable() async throws {
        let stub = FuyaoBoardStub.install(bodies: [Self.snapshotBody("")])
        let provider = provider(stub)
        #expect(try await provider.constituentQuotes([]).isEmpty)
        #expect(try await provider.constituentQuotes([
            FuyaoConstituent(thscode: "830799.BJ", name: "艾融软件"),
            FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台", symbol: nil),
        ]).isEmpty)
        #expect(stub.urls.isEmpty)
    }

    // MARK: - 相对强弱

    @Test("按基准最新日对齐，5/20 日取基准自身基期，不压缩日期交集")
    func alignmentAndBasePeriod() throws {
        // 基准：6/1 起 100、101、…、124（25 个交易日）。
        // 板块缺少 6/1..6/3 与 6/10，且只到 6/24。
        // 若把交集压缩成 5/20 日，5 日基期会落在板块交集上，结果就不同了。
        var benchmark = Self.series(from: 1, closes: (0..<25).map { 100 + Double($0) })
        var board = Self.series(from: 4, closes: (0..<21).map { 200 + Double($0) * 2 })
        board.removeAll { $0.time == Self.beijing(10) }

        // 同日收盘：锚点 6/25 板块缺失 -> 用完整日期的板块。
        let result = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        // 板块最新 6/24，基准锚点 6/25：最新日不同。
        #expect(result.dataTime == Self.beijing(25))
        #expect(result.fiveDay == nil)
        #expect(result.twentyDay == nil)

        board.append(Self.candle(Self.beijing(25), 250))
        benchmark.append(Self.candle(Self.beijing(25), 125))
        let aligned = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(aligned.dataTime == Self.beijing(25))
        // 基准第 25 行之前第 5 个是 6/20（第 20 行，收盘 119），第 20 个是 6/5（第 5 行，收盘 104）。
        let base5 = (125.0 - 119) / 119 * 100
        // 板块 6/20 收盘 = 200 + (20 - 4) * 2 = 232；6/25 为 250。
        let board5 = (250.0 - 232) / 232 * 100
        #expect(abs((aligned.fiveDay ?? .nan) - (board5 - base5)) < 1e-9)
        #expect(abs((aligned.boardFiveDay ?? .nan) - board5) < 1e-9)

        let base20 = (125.0 - 104) / 104 * 100
        // 板块 6/5 收盘 = 200 + (5 - 4) * 2 = 202。
        let board20 = (250.0 - 202) / 202 * 100
        #expect(abs((aligned.twentyDay ?? .nan) - (board20 - base20)) < 1e-9)
        #expect(abs((aligned.boardTwentyDay ?? .nan) - board20) < 1e-9)
        // 相对强弱单位为百分点：板块涨幅减基准涨幅。
        #expect(abs((aligned.fiveDay ?? .nan) - (aligned.boardFiveDay! - base5)) < 1e-9)
    }

    @Test("缺基期返回 nil，不擅自换旧日")
    func missingBasePeriod() throws {
        // 基准只有 10 个交易日：20 日基期不存在。
        let benchmark = Self.series(from: 1, closes: (0..<10).map { 100 + Double($0) })
        let board = Self.series(from: 1, closes: (0..<10).map { 50 + Double($0) })
        let result = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(result.dataTime == Self.beijing(10))
        #expect(result.fiveDay != nil)
        #expect(result.boardFiveDay != nil)
        #expect(result.twentyDay == nil)
        #expect(result.boardTwentyDay == nil)
    }

    @Test("基准基期那天板块没有数据时返回 nil")
    func boardMissingBaseDay() throws {
        var benchmark = Self.series(from: 1, closes: (0..<10).map { 100 + Double($0) })
        var board = Self.series(from: 1, closes: (0..<10).map { 50 + Double($0) })
        // 板块缺 6/6：基准第 10 行之前第 5 个交易日是 6/5，仍在；缺 6/5 则 5 日 nil。
        board.removeAll { $0.time == Self.beijing(5) }
        let missingFive = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(missingFive.fiveDay == nil)
        #expect(missingFive.boardFiveDay == nil)
        // 20 日仍缺基期。
        #expect(missingFive.twentyDay == nil)

        // 基准基期日无有效收盘：同样 nil。
        benchmark[4] = Self.candle(Self.beijing(5), .nan)
        let invalidBase = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(invalidBase.dataTime == Self.beijing(10))
        #expect(invalidBase.fiveDay == nil)
    }

    @Test("板块最新日缺失时不用更旧末日冒充")
    func boardMissingLatestDay() throws {
        let benchmark = Self.series(from: 1, closes: (0..<10).map { 100 + Double($0) })
        var board = Self.series(from: 1, closes: (0..<9).map { 50 + Double($0) })
        // 板块最新为 6/9，基准锚点为 6/10。
        let result = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(result.dataTime == Self.beijing(10))
        #expect(result.fiveDay == nil)
        #expect(result.boardFiveDay == nil)

        // 板块最新日存在但价格无效：同样不能回退到 6/9。
        board.append(Self.candle(Self.beijing(10), .nan))
        let invalid = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(invalid.dataTime == Self.beijing(10))
        #expect(invalid.fiveDay == nil)

        board.removeAll { $0.time == Self.beijing(10) }
        board.append(Self.candle(Self.beijing(10), 0))
        #expect(FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark).fiveDay == nil)
    }

    @Test("无效价格与非有限结果返回 nil")
    func invalidPrices() throws {
        let benchmark = Self.series(from: 1, closes: (0..<10).map { 100 + Double($0) })
        var board = Self.series(from: 1, closes: (0..<10).map { 50 + Double($0) })
        // 基期价格无效：5 日段 nil，但日期照实给出。
        board[4] = Self.candle(Self.beijing(5), -1)
        let negative = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(negative.dataTime == Self.beijing(10))
        #expect(negative.fiveDay == nil)

        var infinite = Self.series(from: 1, closes: (0..<10).map { 50 + Double($0) })
        infinite[9] = Self.candle(Self.beijing(10), .infinity)
        #expect(FuyaoRelativeStrength.calculate(board: infinite, benchmark: benchmark).fiveDay == nil)

        let emptyBenchmark: [Candle] = []
        #expect(FuyaoRelativeStrength.calculate(board: board, benchmark: emptyBenchmark) == .empty)
    }

    @Test("重复行按交易日保留最后一行，两侧收盘不在同一时区也不影响对齐")
    func duplicateRowsAndTimeZone() throws {
        var benchmark = Self.series(from: 1, closes: (0..<10).map { 100 + Double($0) })
        var board = Self.series(from: 1, closes: (0..<10).map { 50 + Double($0) })
        // 6/10 重复行：后者是修正值，应以修正值为准。
        benchmark.append(Self.candle(Self.beijing(10), 200))
        board.append(Candle(
            // UTC 时间点落在北京时间 6/10 中午，同一交易日。
            time: Date(timeIntervalSince1970: 1_781_069_600),
            open: 90, high: 90, low: 90, close: 90
        ))
        let result = FuyaoRelativeStrength.calculate(board: board, benchmark: benchmark)
        #expect(result.dataTime == Self.beijing(10))
        let base5 = (200.0 - 104) / 104 * 100
        let board5 = (90.0 - 54) / 54 * 100
        #expect(abs((result.boardFiveDay ?? .nan) - board5) < 1e-9)
        #expect(abs((result.fiveDay ?? .nan) - (board5 - base5)) < 1e-9)
    }

    @Test("模型可构造且值可比较")
    func modelConstruction() throws {
        let board = FuyaoBoard(thscode: "886042.TI", name: "白酒概念")
        #expect(board == FuyaoBoard(thscode: "886042.TI", name: "白酒概念", symbol: board.symbol))
        #expect(board.symbol?.sectorIndex == SectorIndexID(code: "886042", name: "白酒概念"))
        #expect(FuyaoBoard(thscode: "8860.TI", name: "x").symbol == nil)
        #expect(FuyaoBoard(thscode: "776042.TI", name: "x").symbol == nil)
        let bj = FuyaoConstituent(thscode: "830799.BJ", name: "艾融软件")
        #expect(bj.symbol == nil)
        #expect(FuyaoConstituent(thscode: "600519.SH", name: "贵州茅台").symbol == SymbolID(market: .sh, code: "600519"))
        let strength = FuyaoRelativeStrength(
            dataTime: Self.beijing(10), fiveDay: 1, twentyDay: 2, boardFiveDay: 3, boardTwentyDay: 4
        )
        #expect(strength.fiveDay == 1)
        #expect(FuyaoRelativeStrength.empty.dataTime == nil)
    }
}
